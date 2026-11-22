import VimeuEngine
import VimeuInput

/// One input context's state machine (DESIGN.md §4.1), independent of any
/// input-method framework:
///
///     Direct ──かな──▶ Composing ──Space──▶ Converting
///
/// Esc rewinds one level at a time rather than clearing everything.
///
/// This is the platform-neutral port of `VimeuIME/VimeuInputController.swift`.
/// Behaviour is meant to be identical; the differences are mechanical:
/// - key events arrive as `SessionKey` + `SessionModifiers`,
/// - conversion runs synchronously on the caller's thread (fcitx5 has a
///   single event loop; a sentence converts in well under a millisecond),
///   and idle delays are host timers (`SessionClient.startTimer`),
/// - reconversion checks the client's surrounding text instead of IMK ranges.
///
/// Not thread-safe: call everything from the thread that delivers keys.
public final class Session {
    private struct ConvertingState {
        var reading: String
        var candidates: [String]
        var selected: Int
        var previousRightID: Int?
    }

    private struct LiveState {
        var reading: String
        var candidates: [String]
    }

    private enum KanaKind { case hiragana, katakana }

    public let engine: Engine
    public unowned let client: SessionClient
    public var settings: SessionSettings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }

    private var buffer = InputBuffer()
    private var converting: ConvertingState?
    private var liveState: LiveState?
    private var partialCommitStability = PartialCommitStability()
    /// Valid only for the immutable POS table loaded for this process. Kept
    /// within the current composition, never persisted or learned.
    private var previousRightID: Int?
    /// The commit made by the latest key, for the one-shot Backspace reconversion.
    private var commitUndo = CommitUndo()
    /// A live conversion waiting for its idle timer.
    private var pendingLive: (reading: String, previousRightID: Int?)?
    /// The reading the auto-commit timer was armed for.
    private var autoCommitReading: String?
    /// The reading of the latest conversion, for opening the tuner after commit.
    public private(set) var lastConversionReading: String?

    /// Ask for every candidate the n-best search can enumerate (its own
    /// expansion limit is the safety valve), as the macOS IME does.
    public static let candidateLimit = NBest.maxExpansions

    /// ASCII punctuation typed directly maps to Japanese punctuation.
    public static let punctuation: [Character: String] = [
        ",": "、",
        ".": "。",
        "/": "・",
        "-": "ー",
    ]

    public init(engine: Engine, client: SessionClient, settings: SessionSettings = SessionSettings()) {
        self.engine = engine
        self.client = client
        self.settings = settings
    }

    /// True while the session owns marked text (composing or converting).
    public var isComposing: Bool { converting != nil || !buffer.isEmpty }

    // MARK: - Lifecycle

    /// Focus moved to another client. What is held belongs to the previous
    /// one, so it is discarded rather than committed into the new client.
    public func activate() {
        endSession(commit: false)
        commitUndo.clear()
    }

    /// Focus left / the host reset the context. Commit what is on screen —
    /// silently dropping the marked text would lose what the user typed.
    public func deactivate(commit: Bool = true) {
        endSession(commit: commit)
        commitUndo.clear()
    }

    private func endSession(commit: Bool) {
        if let conv = converting {
            if commit { doCommit(conv: conv) } else { doCancel() }
            return
        }
        if !buffer.isEmpty {
            if commit { commitCurrentComposition() } else { clearComposing() }
        }
        client.hideCandidates()
    }

    // MARK: - Actions (status-area menu)

    public func toggleLiveConversion() {
        settings.liveConversion.toggle()
    }

    /// The reading to seed the tuning window with.
    public var tunerSeed: String? {
        converting?.reading ?? (buffer.isEmpty ? lastConversionReading : buffer.reading)
    }

    public func openTuner() {
        client.openTuner(reading: tunerSeed)
    }

    private func settingsChanged(from old: SessionSettings) {
        guard old.liveConversion != settings.liveConversion else { return }
        partialCommitStability.reset()
        cancelAutoCommit()
        cancelLive()
        liveState = nil
        guard converting == nil, !buffer.isEmpty else { return }
        submitConversion()
        updateMarkedText()
    }

    // MARK: - Key dispatch

    /// Feed a key press. Returns true when the session consumed it; false
    /// means the host should pass it to the application.
    @discardableResult
    public func handle(_ key: SessionKey, modifiers mods: SessionModifiers = []) -> Bool {
        // Only the key right after a commit may undo it. A key passed through
        // to the client may move the caret, so it forgets even a commit it
        // caused itself.
        let undoable = commitUndo.entry
        commitUndo.clear()
        let handled = dispatch(key, mods: mods, undoable: undoable)
        if !handled { commitUndo.clear() }
        return handled
    }

    private func dispatch(_ key: SessionKey, mods: SessionModifiers, undoable: CommitUndo.Entry?) -> Bool {
        if mods.contains(.control), !mods.contains(.command) {
            switch key {
            case .character(";") where !mods.contains(.alt) && !mods.contains(.shift):
                openTuner()
                return true
            case .character("m"), .character("M"):
                guard isComposing else { return false }
                endSession(commit: true)
                return true
            case .character("j"), .character("J"): return handleKanaConversion(kind: .hiragana)
            case .character("k"), .character("K"): return handleKanaConversion(kind: .katakana)
            case .backspace where !mods.contains(.alt) && !isComposing:
                return reconvertCommitted(undoable)
            default: break
            }
        }

        // Command / Control combos always pass through.
        if mods.contains(.command) || mods.contains(.control) { return false }

        // Alt+Space always types a full-width space (Mozc's `InsertFullSpace`).
        if key == .space, mods.contains(.alt) { return insertFullWidthSpace() }
        // Other Alt combos belong to the application / desktop.
        if mods.contains(.alt) {
            if isComposing { endSession(commit: true) }
            return false
        }

        if converting != nil { return handleConverting(key) }
        if !buffer.isEmpty { return handleComposing(key) }
        return handleDirect(key, undoable: undoable)
    }

    // MARK: - Timers

    public func timerFired(_ timer: SessionTimer) {
        switch timer {
        case .liveConversion:
            guard let pending = pendingLive else { return }
            pendingLive = nil
            guard converting == nil, buffer.reading == pending.reading else { return }
            runLiveConversion(reading: pending.reading, previousRightID: pending.previousRightID)
        case .autoCommit:
            guard let reading = autoCommitReading else { return }
            autoCommitReading = nil
            guard settings.liveConversion, settings.autoCommitEnabled,
                  converting == nil,
                  buffer.reading == reading,
                  buffer.converter.pending.isEmpty,
                  liveState?.reading == reading else { return }
            commitCurrentComposition()
        }
    }

    // MARK: - Full-width space

    private func insertFullWidthSpace() -> Bool {
        if let conv = converting {
            doCommit(conv: conv)
        } else if buffer.isEmpty {
            client.commit(InputBuffer.fullWidthSpace)
            return true
        }
        buffer.acceptKana(InputBuffer.fullWidthSpace)
        submitConversion()
        updateMarkedText()
        return true
    }

    // MARK: - Direct

    private func handleDirect(_ key: SessionKey, undoable: CommitUndo.Entry?) -> Bool {
        switch key {
        case .backspace:
            // Backspace right after a commit brings it back as a conversion.
            guard settings.reconvertOnBackspace else { return false }
            return reconvertCommitted(undoable)
        case .character(let ch):
            if let punct = Self.punctuation[ch] {
                buffer.acceptKana(punct)
                submitConversion()
                updateMarkedText()
                return true
            }
            guard InputBuffer.isComposingCharacter(ch) else { return false }
            buffer.accept(Character(ch.lowercased()))
            submitConversion()
            updateMarkedText()
            return true
        default:
            return false
        }
    }

    // MARK: - Composing

    private func handleComposing(_ key: SessionKey) -> Bool {
        switch key {
        case .space:
            return startConverting()

        case .enter:
            commitCurrentComposition()
            return true

        case .backspace:
            partialCommitStability.reset()
            buffer.deleteLast()
            if buffer.isEmpty {
                clearComposing()
            } else {
                submitConversion()
                updateMarkedText()
            }
            return true

        case .escape:
            clearComposing()
            return true

        case .character(let ch):
            if InputBuffer.isComposingCharacter(ch) {
                buffer.accept(Character(ch.lowercased()))
                submitConversion()
                updateMarkedText()
                return true
            }
            if let punct = Self.punctuation[ch] {
                buffer.acceptKana(punct)
                submitConversion()
                updateMarkedText()
                return true
            }
            commitCurrentComposition()
            return false

        default:
            // Other keys: commit what we have, then pass the key through.
            commitCurrentComposition()
            return false
        }
    }

    /// Convert for inline display or to commit the prefix of a long reading.
    /// Inline conversion, stability observations, and partial commits share the
    /// idle delay, even when live conversion is off. Pending romaji stays in
    /// the buffer and is never sent to the engine.
    private func submitConversion() {
        cancelAutoCommit()
        cancelLive()
        let pc = settings.partialCommit
        let partialCommitNeeded = pc.isNeeded(reading: buffer.reading)
        if !pc.observesStability { partialCommitStability.reset() }
        guard settings.liveConversion || partialCommitNeeded || pc.observesStability else { return }
        let reading = buffer.reading
        guard !reading.isEmpty else { return }
        let delay = settings.liveConversionDelayMilliseconds
        if delay <= 0 {
            runLiveConversion(reading: reading, previousRightID: previousRightID)
        } else {
            pendingLive = (reading, previousRightID)
            client.startTimer(.liveConversion, milliseconds: delay)
        }
    }

    private func cancelLive() {
        if pendingLive != nil {
            pendingLive = nil
            client.cancelTimer(.liveConversion)
        }
    }

    private func runLiveConversion(reading: String, previousRightID: Int?) {
        let candidates = engine.convert(reading: reading, limit: 1, previousRightID: previousRightID)
        handleConversionResult(candidates: candidates, reading: reading)
    }

    /// A conversion came back: commit an old prefix, or refresh the inline text.
    private func handleConversionResult(candidates: [Candidate], reading: String) {
        guard converting == nil, buffer.reading == reading else { return }
        let pc = settings.partialCommit
        let stablePrefixScalarCount = partialCommitStability.observe(
            reading: reading, candidate: candidates.first, settings: pc
        )
        if let boundaryRules = engine.boundaryRules,
           let prefix = PartialCommit(boundaryRules: boundaryRules, reading: reading, candidate: candidates.first,
                                      settings: pc, liveConversion: settings.liveConversion,
                                      stablePrefixScalarCount: stablePrefixScalarCount) {
            cancelAutoCommit()
            partialCommitStability.reset()
            client.commit(prefix.text)
            // Composition continues after a prefix, so it is never undoable.
            commitUndo.clear()
            buffer.reading = prefix.remainingReading
            previousRightID = prefix.previousRightID
            // Keep the exact remainder of the displayed best path until its
            // fresh conversion arrives. The pending syllable is untouched.
            liveState = settings.liveConversion && !candidates.isEmpty
                ? LiveState(reading: prefix.remainingReading, candidates: [prefix.remainingText]) : nil
            if !candidates.isEmpty, pc.converts(liveConversion: settings.liveConversion) {
                recordLastConversionReading(reading)
            }
            updateMarkedText()
            submitConversion()
            return
        }
        guard settings.liveConversion else { return }
        liveState = LiveState(reading: reading, candidates: candidates.map(\.text))
        updateMarkedText()
        scheduleAutoCommit(reading: reading)
    }

    private func cancelAutoCommit() {
        if autoCommitReading != nil {
            autoCommitReading = nil
            client.cancelTimer(.autoCommit)
        }
    }

    /// Start counting only after the converted text is visible.
    private func scheduleAutoCommit(reading: String) {
        cancelAutoCommit()
        guard settings.liveConversion, settings.autoCommitEnabled,
              liveState?.candidates.first != nil,
              buffer.converter.pending.isEmpty else { return }
        autoCommitReading = reading
        client.startTimer(.autoCommit, milliseconds: settings.autoCommitDelayMilliseconds)
    }

    /// Commit the composition exactly as displayed: the live conversion plus any
    /// kana typed after it, or the raw reading when no live result applies.
    private func commitCurrentComposition() {
        // Flush first: a half-typed "n" has to become ん before it is committed.
        let reading = buffer.flushForConversion()
        let context = previousRightID
        var output = reading
        if settings.liveConversion,
           let live = liveState, let best = live.candidates.first,
           reading.hasPrefix(live.reading) {
            recordLastConversionReading(reading)
            output = best + reading.dropFirst(live.reading.count)
        }
        teardownComposing()
        commitText(output)
        commitUndo.record(text: output, reading: reading, previousRightID: context)
    }

    /// Discard the composition entirely (Esc / backspace-to-empty).
    private func clearComposing() {
        teardownComposing()
        client.setPreedit("", converting: false)
    }

    private func teardownComposing() {
        cancelAutoCommit()
        cancelLive()
        partialCommitStability.reset()
        previousRightID = nil
        buffer = InputBuffer()
        liveState = nil
    }

    // MARK: - Converting

    /// Space: convert and show the candidates. If the dictionary is unavailable
    /// the kana forms still let the user commit something.
    private func startConverting() -> Bool {
        cancelAutoCommit()
        let reading = buffer.flushForConversion()
        guard !reading.isEmpty else { return false }
        let context = previousRightID
        teardownComposing()

        let converted = engine.convert(reading: reading, limit: Self.candidateLimit, previousRightID: context)
            .map(\.text)
        let candidates = Self.conversionCandidates(reading: reading, converted: converted)
        enterConverting(reading: reading, candidates: candidates, selected: 0, previousRightID: context)
        return true
    }

    /// Width choices are UI alternatives, like the plain kana fallback. Keep
    /// the engine's ordering and costs, and place each full-width form directly
    /// after its original so it remains reachable in a long candidate list.
    public static func conversionCandidates(reading: String, converted: [String]) -> [String] {
        var candidates: [String] = []
        var seen: Set<String> = []
        for text in converted + [reading, hiraganaToKatakana(reading)] {
            let fullWidth = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
                if scalar.value >= 0x30, scalar.value <= 0x39, let wide = Unicode.Scalar(scalar.value + 0xFEE0) {
                    return wide
                }
                return scalar
            }))
            for form in [text, fullWidth] where seen.insert(form).inserted {
                candidates.append(form)
            }
        }
        return candidates
    }

    private func enterConverting(reading: String, candidates: [String], selected: Int, previousRightID: Int?) {
        guard candidates.indices.contains(selected) else { return }
        converting = ConvertingState(reading: reading, candidates: candidates, selected: selected,
                                     previousRightID: previousRightID)
        client.setPreedit(candidates[selected], converting: true)
        client.showCandidates(candidates, selected: selected)
    }

    private func handleConverting(_ key: SessionKey) -> Bool {
        guard var conv = converting else { return false }
        let count = conv.candidates.count

        switch key {
        case .up:
            conv.selected = max(0, conv.selected - 1)
            updateConvertingSelection(conv)
            return true

        case .down, .space:
            conv.selected = min(count - 1, conv.selected + 1)
            updateConvertingSelection(conv)
            return true

        case .enter:
            doCommit(conv: conv)
            return true

        case .backspace, .escape:
            revertToComposing(conv: conv)
            return true

        case .character(let ch):
            // Number key direct selection (1–9), relative to the visible page.
            if let n = ch.wholeNumberValue, n >= 1, n <= 9, ch.isASCII {
                let index = Self.pageStart(selected: conv.selected) + n - 1
                if index < count {
                    conv.selected = index
                    doCommit(conv: conv)
                    return true
                }
            }
            // Letter, unassigned digit or punctuation: start a new composition.
            if InputBuffer.isComposingCharacter(ch) {
                doCommit(conv: conv)
                buffer.accept(Character(ch.lowercased()))
                submitConversion()
                updateMarkedText()
                return true
            }
            if let punct = Self.punctuation[ch] {
                doCommit(conv: conv)
                buffer.acceptKana(punct)
                submitConversion()
                updateMarkedText()
                return true
            }
            doCommit(conv: conv)
            return false

        default:
            // Anything else: commit first so the marked text isn't lost, then
            // let the key through to the client.
            doCommit(conv: conv)
            return false
        }
    }

    /// Candidates are shown ten to a page (DESIGN.md §4.1).
    public static let pageSize = 10

    static func pageStart(selected: Int) -> Int { selected / pageSize * pageSize }

    /// The host's candidate list was clicked.
    public func selectCandidate(at index: Int) {
        guard var conv = converting, conv.candidates.indices.contains(index) else { return }
        conv.selected = index
        doCommit(conv: conv)
    }

    /// The host's candidate list paged or moved the cursor itself.
    public func highlightCandidate(at index: Int) {
        guard var conv = converting, conv.candidates.indices.contains(index) else { return }
        conv.selected = index
        updateConvertingSelection(conv)
    }

    private func updateConvertingSelection(_ conv: ConvertingState) {
        converting = conv
        client.setPreedit(conv.candidates[conv.selected], converting: true)
        client.selectCandidate(conv.selected)
    }

    private func doCommit(conv: ConvertingState) {
        let text = conv.candidates[conv.selected]
        recordLastConversionReading(conv.reading)
        converting = nil
        teardownComposing()
        client.hideCandidates()
        commitText(text)
        commitUndo.record(text: text, reading: conv.reading, previousRightID: conv.previousRightID)
    }

    private func doCancel() {
        converting = nil
        teardownComposing()
        client.setPreedit("", converting: false)
        client.hideCandidates()
    }

    /// Esc / backspace during conversion: rewind to Composing, keeping the
    /// reading so the user doesn't have to retype it.
    private func revertToComposing(conv: ConvertingState) {
        partialCommitStability.reset()
        converting = nil
        client.hideCandidates()
        buffer = InputBuffer()
        buffer.reading = conv.reading
        previousRightID = conv.previousRightID
        liveState = nil
        cancelLive()
        updateMarkedText()
    }

    // MARK: - Kana conversion (Ctrl+J / Ctrl+K)

    private func handleKanaConversion(kind: KanaKind) -> Bool {
        let reading: String
        let context: Int?
        if let conv = converting {
            reading = conv.reading
            context = conv.previousRightID
        } else if !buffer.isEmpty {
            reading = buffer.flushForConversion()
            context = previousRightID
        } else {
            return false  // nothing to convert; let the key pass through
        }
        guard !reading.isEmpty else { return false }

        converting = nil
        teardownComposing()
        enterConverting(
            reading: reading,
            candidates: [reading, Self.hiraganaToKatakana(reading)],
            selected: kind == .hiragana ? 0 : 1,
            previousRightID: context
        )
        return true
    }

    public static func hiraganaToKatakana(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            // The hiragana block (ぁ–ゖ) maps to katakana by a fixed +0x60 offset.
            if scalar.value >= 0x3041, scalar.value <= 0x3096,
               let kata = Unicode.Scalar(scalar.value + 0x60) {
                out.append(kata)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: - Client I/O

    private func recordLastConversionReading(_ reading: String) {
        guard !reading.isEmpty else { return }
        lastConversionReading = reading
    }

    private func updateMarkedText() {
        client.setPreedit(composingDisplayString, converting: false)
    }

    /// The live conversion when there is one, plus any kana typed since it was
    /// requested and the pending romaji. Keeping the older conversion rather
    /// than falling back to raw kana stops the inline text from flickering.
    var composingDisplayString: String {
        if settings.liveConversion,
           let live = liveState, let best = live.candidates.first,
           buffer.reading.hasPrefix(live.reading) {
            return best + buffer.reading.dropFirst(live.reading.count) + buffer.converter.pending
        }
        return buffer.displayString
    }

    private func commitText(_ text: String) {
        if text.isEmpty {
            client.setPreedit("", converting: false)
        } else {
            client.commit(text)
        }
    }

    /// Turn the text just committed back into a conversion of its reading,
    /// with the committed candidate selected. Returns false (normal Backspace)
    /// when there is nothing to undo or the client cannot confirm the
    /// committed text is right before the cursor.
    private func reconvertCommitted(_ entry: CommitUndo.Entry?) -> Bool {
        guard let entry,
              let count = CommitUndo.scalarsToDelete(for: entry.text, surrounding: client.surroundingText())
        else { return false }
        let converted = engine.convert(reading: entry.reading, limit: Self.candidateLimit,
                                       previousRightID: entry.previousRightID).map(\.text)
        let restored = CommitUndo.reconversionCandidates(
            committed: entry.text,
            candidates: Self.conversionCandidates(reading: entry.reading, converted: converted)
        )
        client.deleteBeforeCursor(count)
        enterConverting(reading: entry.reading, candidates: restored.candidates, selected: restored.selected,
                        previousRightID: entry.previousRightID)
        return true
    }
}
