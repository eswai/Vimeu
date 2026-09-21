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

    /// Coalesces live-conversion work; results arrive on the main actor.
    private lazy var coordinator: LiveConversionCoordinator = {
        let c = LiveConversionCoordinator()
        c.onResult = { [weak self] candidates, reading in
            self?.handleLiveResult(candidates: candidates, reading: reading)
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
    }

    // The client is going away. Commit what is on screen — silently dropping the
    // marked text would lose whatever the user had typed.
    override func deactivateServer(_ sender: Any!) {
        endSession(client: sender, commit: true)
        super.deactivateServer(sender)
    }

    // IMK's own end-of-composition hook (e.g. the user clicks elsewhere in the
    // text field). Same contract as deactivation: commit, don't discard.
    override func commitComposition(_ sender: Any!) {
        endSession(client: sender, commit: true)
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
        // Turning it off mid-composition drops the inline conversion back to
        // raw kana rather than leaving a stale one on screen.
        if !Settings.liveConversion {
            liveState = nil
            coordinator.reset()
            updateMarkedText(client: client())
        }
    }

    // MARK: - Key dispatch

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard event.type == .keyDown else { return false }

        // Control+J / Control+K: force the current reading to hiragana / katakana.
        let mods = event.modifierFlags
        if mods.contains(.control), !mods.contains(.command) {
            switch Int(event.keyCode) {
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
        return handleDirect(event: event, client: sender)
    }

    // MARK: - Direct

    private func handleDirect(event: NSEvent, client: Any?) -> Bool {
        guard let ch = event.characters?.first else { return false }
        if let punct = Self.punctuation[ch] {
            buffer.acceptKana(punct)
            submitLive()
            updateMarkedText(client: client)
            return true
        }
        guard ch.isLetter else { return false }
        buffer.accept(Character(ch.lowercased()))
        submitLive()
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
            buffer.deleteLast()
            if buffer.isEmpty {
                clearComposing(client: client)
            } else {
                submitLive()
                updateMarkedText(client: client)
            }
            return true

        case kVK_Escape:
            clearComposing(client: client)
            return true

        default:
            if let ch = event.characters?.first {
                if ch.isLetter {
                    buffer.accept(Character(ch.lowercased()))
                    submitLive()
                    updateMarkedText(client: client)
                    return true
                }
                if let punct = Self.punctuation[ch] {
                    buffer.acceptKana(punct)
                    submitLive()
                    updateMarkedText(client: client)
                    return true
                }
            }
            // Non-alpha key: commit what we have, then pass the key through.
            commitCurrentComposition(client: client)
            return false
        }
    }

    /// Ask for a live conversion of the current reading. No-op when the feature
    /// is off. The pending romaji fragment is never sent — the engine only ever
    /// sees finished kana.
    private func submitLive() {
        guard Settings.liveConversion else { return }
        coordinator.submit(reading: buffer.reading, delayMilliseconds: LiveConversionSettings.delayMilliseconds)
    }

    /// A live conversion came back: refresh the inline marked text.
    @MainActor
    private func handleLiveResult(candidates: [Candidate], reading: String) {
        guard Settings.liveConversion, converting == nil else { return }
        guard buffer.reading == reading else { return }  // stale
        liveState = LiveState(reading: reading, candidates: candidates.map(\.text))
        updateMarkedText(client: client())
    }

    /// Commit the composition exactly as displayed: the live conversion plus any
    /// kana typed after it, or the raw reading when no live result applies.
    /// Named to stay clear of `IMKInputController.commitComposition(_:)`.
    private func commitCurrentComposition(client: Any?) {
        // Flush first: a half-typed "n" has to become ん before it is committed,
        // which is exactly what the display string does *not* do (it shows the
        // pending romaji as-is while the user is still typing it).
        let reading = buffer.flushForConversion()
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
    }

    /// Discard the composition entirely (Esc / backspace-to-empty).
    private func clearComposing(client: Any?) {
        teardownComposing()
        clearMarkedText(client: client)
    }

    private func teardownComposing() {
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
        let reading = buffer.flushForConversion()
        guard !reading.isEmpty else { return false }
        teardownComposing()

        var candidates = ConversionService.shared
            .convertNow(reading: reading, limit: Self.candidateLimit)
            .map(\.text)
        if candidates.isEmpty { candidates = [reading] }
        // Always offer the plain kana forms as a fallback at the end of the list.
        for kana in [reading, Self.hiraganaToKatakana(reading)]
        where !candidates.contains(kana) {
            candidates.append(kana)
        }

        enterConverting(reading: reading, candidates: candidates, selected: 0, client: client)
        return true
    }

    private func enterConverting(reading: String, candidates: [String], selected: Int, client: Any?) {
        converting = ConvertingState(reading: reading, candidates: candidates, selected: selected)
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
                // Letter or punctuation: commit, then start a new composition.
                if ch.isLetter {
                    doCommit(conv: conv, client: client)
                    buffer.accept(Character(ch.lowercased()))
                    submitLive()
                    updateMarkedText(client: client)
                    return true
                }
                if let punct = Self.punctuation[ch] {
                    doCommit(conv: conv, client: client)
                    buffer.acceptKana(punct)
                    submitLive()
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
        // Re-anchor on every selection change: candidates differ in length, so
        // the composing text — and with it the caret — moves as the user cycles.
        panelUpdate(conv.candidates, selected: conv.selected, anchor: caretRect(client: client))
    }

    private func doCommit(conv: ConvertingState, client: Any?) {
        let text = conv.candidates[conv.selected]
        recordLastConversionReading(conv.reading)
        converting = nil
        clearMarkedText(client: client)
        panelHide()
        insertText(text, client: client)
    }

    private func doCancel(conv: ConvertingState, client: Any?) {
        converting = nil
        clearMarkedText(client: client)
        panelHide()
    }

    /// Esc / backspace during conversion: rewind to Composing, keeping the
    /// reading so the user doesn't have to retype it.
    private func revertToComposing(conv: ConvertingState, client: Any?) {
        converting = nil
        panelHide()
        buffer = InputBuffer()
        buffer.reading = conv.reading
        liveState = nil
        coordinator.reset()
        updateMarkedText(client: client)
    }

    // MARK: - Kana conversion (Ctrl+J / Ctrl+K)

    /// Force the current reading to hiragana or katakana, entering Converting
    /// with both forms so the user can toggle and commit.
    private func handleKanaConversion(kind: KanaKind, client: Any?) -> Bool {
        let reading: String
        if let conv = converting {
            reading = conv.reading
        } else if !buffer.isEmpty {
            reading = buffer.flushForConversion()
        } else {
            return false  // nothing to convert; let the key pass through
        }
        guard !reading.isEmpty else { return false }

        teardownComposing()
        enterConverting(
            reading: reading,
            candidates: [reading, Self.hiraganaToKatakana(reading)],
            selected: kind == .hiragana ? 0 : 1,
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

    /// Where the composing text is on screen, or nil if the client won't say.
    private func caretRect(client: Any?) -> NSRect? {
        guard let c = client as? IMKTextInput else { return nil }
        // Prefer the marked (composing) range: that's where the user is looking.
        var range = c.markedRange()
        if range.location == NSNotFound { range = c.selectedRange() }
        if range.location == NSNotFound { range = NSRange(location: 0, length: 0) }

        // `firstRect(forCharacterRange:actualRange:)` is unreliable through the
        // IMK client proxy from Swift (it hands back uninitialized memory), so
        // ask for the line-height rectangle instead — the documented way to
        // locate the caret, and it fills the rect via an out-parameter.
        var rect = NSRect.zero
        _ = c.attributes(forCharacterIndex: range.location, lineHeightRectangle: &rect)
        if !isUsable(rect) {
            rect = .zero
            _ = c.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        }
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
