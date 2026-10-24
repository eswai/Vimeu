import AppKit
import Carbon.HIToolbox
import InputMethodKit
import VimeuEngine
import VimeuInput
import VimeuUI

// MARK: - State

/// Converting: a fixed list of whole-sentence candidates with one selected.
private struct ConvertingState {
    var reading: String
    var candidates: [String]
    var selected: Int
    var previousRightID: Int?
}

/// Live conversion of the reading being composed, shown inline as marked text.
private struct LiveState {
    var reading: String
    var candidates: [String]
}

private enum KanaKind { case hiragana, katakana }

// MARK: - Controller

/// The ObjC name must match `InputMethodServerControllerClass` in Info.plist.
///
/// State machine (DESIGN.md §4.1):
///
///     Direct ──かな──▶ Composing ──Space──▶ Converting
///
/// Esc rewinds one level at a time rather than clearing everything.
/// `@unchecked Sendable` because IMK hands the controller to callbacks that
/// Swift cannot see are all main-thread; every method here runs on the main
/// thread, and the MainActor state it reaches goes through `mainSync`.
@objc(VimeuInputController)
final class VimeuInputController: IMKInputController, @unchecked Sendable {
    private var buffer = InputBuffer()
    private var converting: ConvertingState?
    private var liveState: LiveState?
    private var autoCommitWork: DispatchWorkItem?
    private var partialCommitStability = PartialCommitStability()
    /// Valid only for the immutable POS table loaded for this process. Kept
    /// within the current composition, never persisted or learned.
    private var previousRightID: Int?
    /// The commit made by the latest key, for the one-shot Backspace reconversion.
    private var commitUndo = CommitUndo()

    /// Coalesces inline/partial-commit work; results arrive on the main actor.
    private lazy var coordinator: LiveConversionCoordinator = {
        let c = LiveConversionCoordinator()
        c.onResult = { [weak self] candidates, reading in
            self?.handleConversionResult(candidates: candidates, reading: reading)
        }
        return c
    }()

    /// Ask for every candidate the n-best search can enumerate. The search has
    /// its own expansion safety valve because the number of lattice paths can
    /// be exponential; using the same value here removes the former UI-only
    /// nine-candidate truncation without weakening that guard.
    private static let candidateLimit = NBest.maxExpansions

    /// ASCII punctuation typed directly maps to Japanese punctuation.
    static let punctuation: [Character: String] = [
        ",": "、",
        ".": "。",
        "/": "・",
        "-": "ー",
    ]

    /// One panel for the whole process, shared by every controller instance
    /// (IMK creates a new controller per client / CapsLock toggle).
    @MainActor private static let sharedPanel = CandidatePanel()

    // The panel is MainActor state reached from nonisolated IMK callbacks; see
    // MainSync.swift for why these hops are synchronous.
    private func panelShow(_ candidates: [String], selected: Int, anchor: NSRect?) {
        mainSync { Self.sharedPanel.show(candidates: candidates, selected: selected, anchor: anchor) }
    }

    private func panelUpdate(_ candidates: [String], selected: Int, anchor: NSRect?) {
        mainSync { Self.sharedPanel.update(candidates: candidates, selected: selected, anchor: anchor) }
    }

    private func panelHide() {
        mainSync { Self.sharedPanel.hide() }
    }

    // MARK: - Lifecycle

    // IMK hands a controller to a new client (app switch, CapsLock toggle, focus
    // change). Anything still held here belongs to the *previous* client, so it
    // is discarded rather than committed into the new one.
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        MemoryWatchdog.checkAtSessionStart()
        endSession(client: sender, commit: false)
        commitUndo.clear()
    }

    // The client is going away. Commit what is on screen — silently dropping the
    // marked text would lose whatever the user had typed.
    override func deactivateServer(_ sender: Any!) {
        endSession(client: sender, commit: true)
        commitUndo.clear()
        super.deactivateServer(sender)
    }

    // IMK's own end-of-composition hook (e.g. the user clicks elsewhere in the
    // text field). Same contract as deactivation: commit, don't discard.
    override func commitComposition(_ sender: Any!) {
        endSession(client: sender, commit: true)
        // The caret is likely moving elsewhere (a click), so no undo.
        commitUndo.clear()
    }

    /// Single teardown path shared by all three hooks above.
    private func endSession(client: Any?, commit: Bool) {
        if let conv = converting {
            if commit {
                doCommit(conv: conv, client: client)
            } else {
                doCancel(conv: conv, client: client)
            }
            return
        }
        if !buffer.isEmpty {
            if commit {
                commitCurrentComposition(client: client)
            } else {
                clearComposing(client: client)
            }
        }
        // Nothing in flight, but a stale panel can outlive its client.
        panelHide()
    }

    // MARK: - Menu

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "Vimeu")
        let live = NSMenuItem(
            title: "ライブ変換",
            action: #selector(toggleLiveConversion(_:)),
            keyEquivalent: ""
        )
        live.target = self
        live.state = Settings.liveConversion ? .on : .off
        menu.addItem(live)

        menu.addItem(.separator())

        let adjust = NSMenuItem(
            title: "調整...",
            action: #selector(openAdjustmentWindow(_:)),
            keyEquivalent: ""
        )
        adjust.target = self
        menu.addItem(adjust)
        return menu
    }

    /// Open the tuning window on whatever is being composed right now, so the
    /// sentence that prompted the visit is already loaded. If composition has
    /// already been committed, the window supplies the latest conversion
    /// reading remembered by the process.
    @objc private func openAdjustmentWindow(_ sender: Any?) {
        let seed = converting?.reading ?? (buffer.isEmpty ? nil : buffer.reading)
        let editor = ConversionService.shared.editor
        mainSync { AdjustmentWindowController.shared.open(editor: editor, reading: seed) }
    }

    @objc private func toggleLiveConversion(_ sender: Any?) {
        Settings.liveConversion.toggle()
        partialCommitStability.reset()
        cancelAutoCommit()
        liveState = nil
        coordinator.reset()
        guard converting == nil else { return }
        submitConversion()
        updateMarkedText(client: client())
    }

    // MARK: - Key dispatch

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard event.type == .keyDown else { return false }
        // Only the key right after a commit may undo it. A key passed through
        // to the client (arrows, Tab, ...) may move the caret, so it forgets
        // even a commit it caused itself.
        let undoable = commitUndo.entry
        commitUndo.clear()
        let handled = dispatch(event, client: sender, undoable: undoable)
        if !handled { commitUndo.clear() }
        return handled
    }

    private func dispatch(_ event: NSEvent, client sender: Any?, undoable: CommitUndo.Entry?) -> Bool {

        // Control+M commits like Return (also sent by Ishizuki before Unicode
        // insertion). With no composition, leave the shortcut to the client.
        // Control+J / Control+K force the reading to hiragana / katakana.
        let mods = event.modifierFlags
        if mods.contains(.control), !mods.contains(.command) {
            switch Int(event.keyCode) {
            case kVK_ANSI_M:
                guard converting != nil || !buffer.isEmpty else { return false }
                endSession(client: sender, commit: true)
                return true
            case kVK_ANSI_J: return handleKanaConversion(kind: .hiragana, client: sender)
            case kVK_ANSI_K: return handleKanaConversion(kind: .katakana, client: sender)
            default: break
            }
        }

        // Command / Control combos always pass through.
        if mods.contains(.command) || mods.contains(.control) { return false }

        // Swallow non-space keys that produce a space character
        // (the international / eisu / kana keys do).
        if Int(event.keyCode) != kVK_Space, event.characters == " " { return true }

        if converting != nil {
            return handleConverting(event: event, client: sender)
        }
        if !buffer.isEmpty {
            return handleComposing(event: event, client: sender)
        }
        return handleDirect(event: event, client: sender, undoable: undoable)
    }

    // MARK: - Direct

    private func handleDirect(event: NSEvent, client: Any?, undoable: CommitUndo.Entry?) -> Bool {
        // Backspace right after a commit brings it back as a conversion.
        // Option+Backspace keeps the client's own word deletion.
        if Int(event.keyCode) == kVK_Delete, !event.modifierFlags.contains(.option),
           ReconversionSettings.backspaceEnabled {
            return reconvertCommitted(undoable, client: client)
        }
        guard let ch = event.characters?.first else { return false }
        if let punct = Self.punctuation[ch] {
            buffer.acceptKana(punct)
            submitConversion()
            updateMarkedText(client: client)
            return true
        }
        guard InputBuffer.isComposingCharacter(ch) else { return false }
        buffer.accept(Character(ch.lowercased()))
        submitConversion()
        updateMarkedText(client: client)
        return true
    }

    // MARK: - Composing

    private func handleComposing(event: NSEvent, client: Any?) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Space:
            return startConverting(client: client)

        case kVK_Return:
            commitCurrentComposition(client: client)
            return true

        case kVK_Delete:
            partialCommitStability.reset()
            buffer.deleteLast()
            if buffer.isEmpty {
                clearComposing(client: client)
            } else {
                submitConversion()
                updateMarkedText(client: client)
            }
            return true

        case kVK_Escape:
            clearComposing(client: client)
            return true

        default:
            if let ch = event.characters?.first {
                if InputBuffer.isComposingCharacter(ch) {
                    buffer.accept(Character(ch.lowercased()))
                    submitConversion()
                    updateMarkedText(client: client)
                    return true
                }
                if let punct = Self.punctuation[ch] {
                    buffer.acceptKana(punct)
                    submitConversion()
                    updateMarkedText(client: client)
                    return true
                }
            }
            // Other keys: commit what we have, then pass the key through.
            commitCurrentComposition(client: client)
            return false
        }
    }

    /// Convert for inline display or to commit the prefix of a long reading.
    /// Inline conversion, stability observations, and partial commits share the
    /// idle delay, even when live conversion is off. Pending romaji stays in
    /// the buffer and is never sent to the engine.
    private func submitConversion() {
        cancelAutoCommit()
        let settings = PartialCommitSettings.current
        let partialCommitNeeded = settings.isNeeded(reading: buffer.reading)
        if !settings.observesStability { partialCommitStability.reset() }
        guard Settings.liveConversion || partialCommitNeeded || settings.observesStability else {
            coordinator.reset()
            return
        }
        coordinator.submit(
            reading: buffer.reading,
            delayMilliseconds: LiveConversionSettings.delayMilliseconds,
            previousRightID: previousRightID
        )
    }

    /// A conversion came back: commit an old prefix, or refresh the inline text.
    @MainActor
    private func handleConversionResult(candidates: [Candidate], reading: String) {
        guard converting == nil else { return }
        guard buffer.reading == reading else { return }  // stale
        let settings = PartialCommitSettings.current
        let stablePrefixScalarCount = partialCommitStability.observe(
            reading: reading, candidate: candidates.first, settings: settings
        )
        if let boundaryRules = ConversionService.shared.boundaryRules,
           let prefix = PartialCommit(boundaryRules: boundaryRules, reading: reading, candidate: candidates.first,
                                      settings: settings, liveConversion: Settings.liveConversion,
                                      stablePrefixScalarCount: stablePrefixScalarCount),
           let client = client() {
            cancelAutoCommit()
            coordinator.reset()
            partialCommitStability.reset()
            // Replace the old marked range with just the committed prefix,
            // then open a new marked range for the suffix, synchronously.
            clearMarkedText(client: client)
            insertText(prefix.text, client: client)
            // Composition continues after a prefix, so it is never undoable.
            commitUndo.clear()
            buffer.reading = prefix.remainingReading
            previousRightID = prefix.previousRightID
            // Keep the exact remainder of the displayed best path until its
            // fresh conversion arrives. The pending syllable is untouched.
            liveState = Settings.liveConversion && !candidates.isEmpty
                ? LiveState(reading: prefix.remainingReading, candidates: [prefix.remainingText]) : nil
            if !candidates.isEmpty, settings.converts(liveConversion: Settings.liveConversion) {
                recordLastConversionReading(reading)
            }
            updateMarkedText(client: client)
            submitConversion()
            return
        }
        guard Settings.liveConversion else { return }
        liveState = LiveState(reading: reading, candidates: candidates.map(\.text))
        updateMarkedText(client: client())
        scheduleAutoCommit(reading: reading)
    }

    private func cancelAutoCommit() {
        autoCommitWork?.cancel()
        autoCommitWork = nil
    }

    /// Start counting only after the converted text is visible. A new key or
    /// explicit candidate selection cancels this work before it can commit.
    private func scheduleAutoCommit(reading: String) {
        cancelAutoCommit()
        guard Settings.liveConversion, LiveConversionSettings.autoCommitEnabled,
              liveState?.candidates.first != nil,
              buffer.converter.pending.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  Settings.liveConversion,
                  LiveConversionSettings.autoCommitEnabled,
                  self.converting == nil,
                  self.buffer.reading == reading,
                  self.buffer.converter.pending.isEmpty,
                  self.liveState?.reading == reading,
                  let client = self.client() else { return }
            self.commitCurrentComposition(client: client)
        }
        autoCommitWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(LiveConversionSettings.autoCommitDelayMilliseconds),
            execute: work
        )
    }

    /// Commit the composition exactly as displayed: the live conversion plus any
    /// kana typed after it, or the raw reading when no live result applies.
    /// Named to stay clear of `IMKInputController.commitComposition(_:)`.
    private func commitCurrentComposition(client: Any?) {
        // Flush first: a half-typed "n" has to become ん before it is committed,
        // which is exactly what the display string does *not* do (it shows the
        // pending romaji as-is while the user is still typing it).
        let reading = buffer.flushForConversion()
        let context = previousRightID
        var output = reading
        if Settings.liveConversion,
           let live = liveState, let best = live.candidates.first,
           reading.hasPrefix(live.reading) {
            recordLastConversionReading(reading)
            output = best + reading.dropFirst(live.reading.count)
        }
        teardownComposing()
        clearMarkedText(client: client)
        if !output.isEmpty { insertText(output, client: client) }
        commitUndo.record(text: output, reading: reading, previousRightID: context)
    }

    /// Discard the composition entirely (Esc / backspace-to-empty).
    private func clearComposing(client: Any?) {
        teardownComposing()
        clearMarkedText(client: client)
    }

    private func teardownComposing() {
        cancelAutoCommit()
        partialCommitStability.reset()
        previousRightID = nil
        resetBuffer()
        liveState = nil
        coordinator.reset()
    }

    // MARK: - Converting

    /// Space: convert and show the candidate window.
    ///
    /// Runs the engine synchronously — the user pressed a key and is waiting for
    /// the window, and a conversion costs a few milliseconds. (Live conversion,
    /// which runs on every keystroke, goes through the background queue instead.)
    /// If the dictionary is unavailable the kana forms still let the user commit
    /// something rather than losing the input.
    private func startConverting(client: Any?) -> Bool {
        cancelAutoCommit()
        let reading = buffer.flushForConversion()
        guard !reading.isEmpty else { return false }
        let context = previousRightID
        teardownComposing()

        let converted = ConversionService.shared
            .convertNow(reading: reading, limit: Self.candidateLimit, previousRightID: context)
            .map(\.text)
        let candidates = Self.conversionCandidates(reading: reading, converted: converted)

        enterConverting(reading: reading, candidates: candidates, selected: 0, previousRightID: context, client: client)
        return true
    }

    /// Width choices are UI alternatives, like the plain kana fallback. Keep
    /// the engine's ordering and costs, and place each full-width form directly
    /// after its original so it remains reachable in a long candidate list.
    static func conversionCandidates(reading: String, converted: [String]) -> [String] {
        var candidates: [String] = []
        var seen: Set<String> = []
        for text in converted + [reading, hiraganaToKatakana(reading)] {
            let fullWidth = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
                if scalar.value >= 0x30, scalar.value <= 0x39 {
                    return Unicode.Scalar(scalar.value + 0xFEE0)!
                }
                return scalar
            }))
            for form in [text, fullWidth] where seen.insert(form).inserted {
                candidates.append(form)
            }
        }
        return candidates
    }

    private func enterConverting(reading: String, candidates: [String], selected: Int, previousRightID: Int?, client: Any?) {
        converting = ConvertingState(reading: reading, candidates: candidates, selected: selected, previousRightID: previousRightID)
        // Set the marked text first: the caret rectangle we anchor to is only
        // meaningful once the client has the composing text.
        updateMarkedText(with: candidates[selected], client: client)
        panelShow(candidates, selected: selected, anchor: caretRect(client: client))
    }

    private func handleConverting(event: NSEvent, client: Any?) -> Bool {
        guard var conv = converting else { return false }
        let count = conv.candidates.count

        switch Int(event.keyCode) {
        case kVK_UpArrow:
            conv.selected = max(0, conv.selected - 1)
            updateConvertingSelection(conv, client: client)
            return true

        case kVK_DownArrow, kVK_Space:
            conv.selected = min(count - 1, conv.selected + 1)
            updateConvertingSelection(conv, client: client)
            return true

        case kVK_Return:
            doCommit(conv: conv, client: client)
            return true

        case kVK_Delete:
            // Backspace during conversion: back to composing with the raw kana.
            revertToComposing(conv: conv, client: client)
            return true

        case kVK_Escape:
            revertToComposing(conv: conv, client: client)
            return true

        default:
            if let ch = event.characters?.first {
                // Number key direct selection (1–9).
                if let n = ch.wholeNumberValue, n >= 1, n <= 9, n - 1 < count {
                    var sel = conv
                    sel.selected = n - 1
                    doCommit(conv: sel, client: client)
                    return true
                }
                // Letter, unassigned digit or punctuation: start a new composition.
                if InputBuffer.isComposingCharacter(ch) {
                    doCommit(conv: conv, client: client)
                    buffer.accept(Character(ch.lowercased()))
                    submitConversion()
                    updateMarkedText(client: client)
                    return true
                }
                if let punct = Self.punctuation[ch] {
                    doCommit(conv: conv, client: client)
                    buffer.acceptKana(punct)
                    submitConversion()
                    updateMarkedText(client: client)
                    return true
                }
            }
            // Anything else: commit first so the marked text isn't lost, then
            // let the key through to the client.
            doCommit(conv: conv, client: client)
            return false
        }
    }

    private func updateConvertingSelection(_ conv: ConvertingState, client: Any?) {
        converting = conv
        updateMarkedText(with: conv.candidates[conv.selected], client: client)
        // Re-anchor on every selection change. The anchor is the start of the
        // composing text, so it stays put while cycling; re-reading it only
        // follows the client if it scrolled or reflowed.
        panelUpdate(conv.candidates, selected: conv.selected, anchor: caretRect(client: client))
    }

    private func doCommit(conv: ConvertingState, client: Any?) {
        let text = conv.candidates[conv.selected]
        recordLastConversionReading(conv.reading)
        converting = nil
        teardownComposing()
        clearMarkedText(client: client)
        panelHide()
        insertText(text, client: client)
        commitUndo.record(text: text, reading: conv.reading, previousRightID: conv.previousRightID)
    }

    private func doCancel(conv: ConvertingState, client: Any?) {
        converting = nil
        teardownComposing()
        clearMarkedText(client: client)
        panelHide()
    }

    /// Esc / backspace during conversion: rewind to Composing, keeping the
    /// reading so the user doesn't have to retype it.
    private func revertToComposing(conv: ConvertingState, client: Any?) {
        partialCommitStability.reset()
        converting = nil
        panelHide()
        buffer = InputBuffer()
        buffer.reading = conv.reading
        previousRightID = conv.previousRightID
        liveState = nil
        coordinator.reset()
        updateMarkedText(client: client)
    }

    // MARK: - Kana conversion (Ctrl+J / Ctrl+K)

    /// Force the current reading to hiragana or katakana, entering Converting
    /// with both forms so the user can toggle and commit.
    private func handleKanaConversion(kind: KanaKind, client: Any?) -> Bool {
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

        teardownComposing()
        enterConverting(
            reading: reading,
            candidates: [reading, Self.hiraganaToKatakana(reading)],
            selected: kind == .hiragana ? 0 : 1,
            previousRightID: context,
            client: client
        )
        return true
    }

    private static func hiraganaToKatakana(_ s: String) -> String {
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
    //
    // `setMarkedText` and `insertText` are blocking and must run synchronously on
    // the main thread; every path into them here is already MainActor-isolated.

    private func resetBuffer() { buffer = InputBuffer() }

    /// Keep this process-wide because IMK may replace the controller when the
    /// focused client changes. The adjustment window is the shared owner of
    /// this small piece of cross-client context.
    private func recordLastConversionReading(_ reading: String) {
        guard !reading.isEmpty else { return }
        mainSync {
            AdjustmentWindowController.recordLastConversion(reading: reading)
        }
    }

    private func updateMarkedText(client: Any?) {
        setMarked(composingDisplayString, client: client)
    }

    /// What the composing state shows: the live conversion when there is one,
    /// plus any kana typed since it was requested and the pending romaji.
    ///
    /// Keeping the older conversion and appending the new suffix — rather than
    /// falling back to raw kana while a fresh result is in flight — is what stops
    /// the inline text from flickering between kanji and hiragana on every
    /// keystroke.
    private var composingDisplayString: String {
        if Settings.liveConversion,
           let live = liveState, let best = live.candidates.first,
           buffer.reading.hasPrefix(live.reading) {
            return best + buffer.reading.dropFirst(live.reading.count) + buffer.converter.pending
        }
        return buffer.displayString
    }

    private func updateMarkedText(with text: String, client: Any?) {
        setMarked(text, client: client)
    }

    private func setMarked(_ text: String, client: Any?) {
        guard let c = client as? IMKTextInput else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        c.setMarkedText(
            NSAttributedString(string: text, attributes: attrs),
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private func clearMarkedText(client: Any?) {
        (client as? IMKTextInput)?.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private func insertText(_ text: String, client: Any?) {
        (client as? IMKTextInput)?.insertText(
            text,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    /// Turn the text just committed back into a conversion of its reading,
    /// with the committed candidate selected. Returns false (normal Backspace)
    /// when there is nothing to undo or the client cannot confirm the
    /// committed text is right before the caret.
    ///
    /// `setMarkedText` with a replacement range (the call reconversion uses)
    /// makes the committed range marked again. Clients that ignore the range
    /// (Firefox and Ghostty in the user's check, 2026-10-24) cannot be told
    /// apart afterwards, so those already rejected by the check stay normal.
    private func reconvertCommitted(_ entry: CommitUndo.Entry?, client: Any?) -> Bool {
        guard let entry, let c = client as? IMKTextInput else { return false }
        let text = entry.text
        let app = c.bundleIdentifier() ?? "?"
        let selected = c.selectedRange()
        var source = "none"
        let range = CommitUndo.range(for: text, selectedRange: selected) { r in
            if let s = c.attributedSubstring(from: r)?.string {
                source = "attributedSubstring(len=\(s.utf16.count))"
                if s == text { return s }
            }
            var actual = NSRange(location: NSNotFound, length: 0)
            if let s = c.string(from: r, actualRange: &actual) {
                source += " string(len=\(s.utf16.count) actual=\(NSStringFromRange(actual)))"
                return s
            }
            return nil
        }
        logger.info("""
            commitUndo app=\(app, privacy: .public) selected=\(NSStringFromRange(selected), privacy: .public) \
            committedLen=\(text.utf16.count, privacy: .public) read=\(source, privacy: .public) \
            match=\(range != nil, privacy: .public)
            """)
        guard let range else { return false }

        let attrs: [NSAttributedString.Key: Any] = [.underlineStyle: NSUnderlineStyle.single.rawValue]
        c.setMarkedText(
            NSAttributedString(string: text, attributes: attrs),
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: range
        )
        let converted = ConversionService.shared
            .convertNow(reading: entry.reading, limit: Self.candidateLimit, previousRightID: entry.previousRightID)
            .map(\.text)
        let restored = CommitUndo.reconversionCandidates(
            committed: text,
            candidates: Self.conversionCandidates(reading: entry.reading, converted: converted)
        )
        enterConverting(reading: entry.reading, candidates: restored.candidates, selected: restored.selected,
                        previousRightID: entry.previousRightID, client: c)
        return true
    }

    /// Where the composing text is on screen, or nil if the client won't say.
    private func caretRect(client: Any?) -> NSRect? {
        guard let c = client as? IMKTextInput else { return nil }
        // `firstRect(forCharacterRange:actualRange:)` is unreliable through the
        // IMK client proxy from Swift (it hands back uninitialized memory), so
        // ask for the line-height rectangle instead — the documented way to
        // locate the caret, and it fills the rect via an out-parameter.
        //
        // The index is relative to the marked text, not the document: 0 is
        // the start of the composing text (macSKK, Squirrel and azooKey all
        // pass 0). Passing `markedRange().location` — a document offset —
        // pointed past the marked text, and clients answered that differently
        // (clamped to its end, the line start, or garbage), so the panel moved
        // around depending on the app and on how far into the document the
        // caret was. Anchoring to the start also keeps the panel still while
        // cycling candidates of different lengths.
        var rect = NSRect.zero
        _ = c.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        guard isUsable(rect), rect.origin != .zero else { return nil }
        return rect
    }

    /// Guard against the garbage rects some IMK clients produce.
    private func isUsable(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && abs(rect.origin.x) < 1_000_000 && abs(rect.origin.y) < 1_000_000
            && rect.size.height >= 0
    }
}
