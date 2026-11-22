import CVimeu
import Foundation
import VimeuInput
import VimeuSession

// C ABI over VimeuSession for the fcitx5 addon (Sources/CVimeu/include/vimeu.h).
// Every entry point is called from fcitx5's event-loop thread. Nothing here may
// trap: a Swift crash takes the whole fcitx5 process (every app's input) down.

// MARK: - Handles

final class EngineBox {
    let engine: Engine
    let failure: UnsafeMutablePointer<CChar>?
    let userDir: UnsafeMutablePointer<CChar>

    init(engine: Engine) {
        self.engine = engine
        failure = engine.loadFailure.map { strdup($0) }
        userDir = strdup(engine.userDirectory.path)
    }

    deinit {
        free(failure)
        free(userDir)
    }
}

/// Bridges `SessionClient` to the C callback table.
final class CallbackClient: SessionClient {
    let cb: vimeu_callbacks
    init(_ cb: vimeu_callbacks) { self.cb = cb }

    func setPreedit(_ text: String, converting: Bool) {
        text.withCString { cb.set_preedit?(cb.user_data, $0, converting) }
    }

    func commit(_ text: String) {
        text.withCString { cb.commit?(cb.user_data, $0) }
    }

    func showCandidates(_ candidates: [String], selected: Int) {
        guard let show = cb.show_candidates else { return }
        let cStrings: [UnsafeMutablePointer<CChar>?] = candidates.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        cStrings.map { UnsafePointer($0) }.withUnsafeBufferPointer { buf in
            show(cb.user_data, buf.baseAddress, Int32(clamping: buf.count), Int32(clamping: selected))
        }
    }

    func selectCandidate(_ index: Int) {
        cb.select_candidate?(cb.user_data, Int32(clamping: index))
    }

    func hideCandidates() {
        cb.hide_candidates?(cb.user_data)
    }

    func surroundingText() -> SurroundingText? {
        guard let fn = cb.surrounding_text else { return nil }
        var text: UnsafePointer<CChar>?
        var cursor: Int32 = 0
        var anchor: Int32 = 0
        guard fn(cb.user_data, &text, &cursor, &anchor), let text else { return nil }
        return SurroundingText(text: String(cString: text), cursor: Int(cursor), anchor: Int(anchor))
    }

    func deleteBeforeCursor(_ count: Int) {
        cb.delete_before_cursor?(cb.user_data, Int32(clamping: count))
    }

    func startTimer(_ timer: SessionTimer, milliseconds: Int) {
        cb.start_timer?(cb.user_data, timer.rawValue, Int32(clamping: milliseconds))
    }

    func cancelTimer(_ timer: SessionTimer) {
        cb.cancel_timer?(cb.user_data, timer.rawValue)
    }

    func openTuner(reading: String?) {
        guard let fn = cb.open_tuner else { return }
        if let reading {
            reading.withCString { fn(cb.user_data, $0) }
        } else {
            fn(cb.user_data, nil)
        }
    }
}

final class SessionBox {
    let client: CallbackClient
    let session: Session
    // Keeps the engine alive for as long as a session uses it.
    let engineBox: EngineBox

    init(engineBox: EngineBox, callbacks: vimeu_callbacks) {
        self.engineBox = engineBox
        client = CallbackClient(callbacks)
        session = Session(engine: engineBox.engine, client: client)
    }
}

@inline(__always)
private func engineBox(_ p: OpaquePointer?) -> EngineBox? {
    p.map { Unmanaged<EngineBox>.fromOpaque(UnsafeRawPointer($0)).takeUnretainedValue() }
}

@inline(__always)
private func sessionBox(_ p: OpaquePointer?) -> SessionBox? {
    p.map { Unmanaged<SessionBox>.fromOpaque(UnsafeRawPointer($0)).takeUnretainedValue() }
}

private func string(_ p: UnsafePointer<CChar>?) -> String? {
    guard let p else { return nil }
    let s = String(cString: p)
    return s.isEmpty ? nil : s
}

// MARK: - Settings

private extension SessionSettings {
    init(_ c: vimeu_settings) {
        self.init(
            liveConversion: c.live_conversion,
            liveConversionDelayMilliseconds: Int(c.live_conversion_delay_ms),
            autoCommitEnabled: c.auto_commit,
            autoCommitDelayMilliseconds: Int(c.auto_commit_delay_ms),
            partialCommit: PartialCommitSettings(
                enabled: c.partial_commit,
                length: Int(c.partial_commit_length),
                mode: c.partial_commit_mode == 1 ? .reading : .converted,
                requiresStableCandidate: c.partial_commit_requires_stable,
                stableLength: Int(c.partial_commit_stable_length)
            ),
            reconvertOnBackspace: c.reconvert_on_backspace
        )
    }

    var c: vimeu_settings {
        vimeu_settings(
            live_conversion: liveConversion,
            live_conversion_delay_ms: Int32(clamping: liveConversionDelayMilliseconds),
            auto_commit: autoCommitEnabled,
            auto_commit_delay_ms: Int32(clamping: autoCommitDelayMilliseconds),
            partial_commit: partialCommit.enabled,
            partial_commit_length: Int32(clamping: partialCommit.length),
            partial_commit_mode: partialCommit.mode == .reading ? 1 : 0,
            partial_commit_requires_stable: partialCommit.requiresStableCandidate,
            partial_commit_stable_length: Int32(clamping: partialCommit.stableLength),
            reconvert_on_backspace: reconvertOnBackspace
        )
    }
}

@_cdecl("vimeu_settings_default")
public func vimeu_settings_default(_ out: UnsafeMutablePointer<vimeu_settings>?) {
    out?.pointee = SessionSettings().c
}

// MARK: - Engine

@_cdecl("vimeu_engine_open")
public func vimeu_engine_open(_ dictionaryPath: UnsafePointer<CChar>?, _ userDir: UnsafePointer<CChar>?) -> OpaquePointer? {
    let engine = Engine(dictionaryPath: string(dictionaryPath) ?? Engine.defaultDictionaryPath(),
                        userDirectory: string(userDir))
    return OpaquePointer(Unmanaged.passRetained(EngineBox(engine: engine)).toOpaque())
}

@_cdecl("vimeu_engine_close")
public func vimeu_engine_close(_ p: OpaquePointer?) {
    guard let p else { return }
    Unmanaged<EngineBox>.fromOpaque(UnsafeRawPointer(p)).release()
}

@_cdecl("vimeu_engine_load_failure")
public func vimeu_engine_load_failure(_ p: OpaquePointer?) -> UnsafePointer<CChar>? {
    engineBox(p)?.failure.map { UnsafePointer($0) }
}

@_cdecl("vimeu_engine_user_dir")
public func vimeu_engine_user_dir(_ p: OpaquePointer?) -> UnsafePointer<CChar>? {
    engineBox(p).map { UnsafePointer($0.userDir) }
}

@_cdecl("vimeu_engine_reload_user_dict")
public func vimeu_engine_reload_user_dict(_ p: OpaquePointer?) {
    engineBox(p)?.engine.reloadUserDictionary()
}

// MARK: - Session

@_cdecl("vimeu_session_new")
public func vimeu_session_new(_ engine: OpaquePointer?, _ callbacks: UnsafePointer<vimeu_callbacks>?) -> OpaquePointer? {
    guard let box = engineBox(engine), let callbacks else { return nil }
    let s = SessionBox(engineBox: box, callbacks: callbacks.pointee)
    return OpaquePointer(Unmanaged.passRetained(s).toOpaque())
}

@_cdecl("vimeu_session_free")
public func vimeu_session_free(_ p: OpaquePointer?) {
    guard let p else { return }
    Unmanaged<SessionBox>.fromOpaque(UnsafeRawPointer(p)).release()
}

@_cdecl("vimeu_session_set_settings")
public func vimeu_session_set_settings(_ p: OpaquePointer?, _ settings: UnsafePointer<vimeu_settings>?) {
    guard let s = sessionBox(p), let settings else { return }
    s.session.settings = SessionSettings(settings.pointee)
}

@_cdecl("vimeu_session_get_settings")
public func vimeu_session_get_settings(_ p: OpaquePointer?, _ out: UnsafeMutablePointer<vimeu_settings>?) {
    guard let s = sessionBox(p), let out else { return }
    out.pointee = s.session.settings.c
}

@_cdecl("vimeu_session_key")
public func vimeu_session_key(_ p: OpaquePointer?, _ key: Int32, _ codepoint: UInt32, _ modifiers: UInt32) -> Bool {
    guard let s = sessionBox(p) else { return false }
    let sessionKey: SessionKey
    switch Int(key) {
    case Int(VIMEU_KEY_CHAR):
        guard let scalar = Unicode.Scalar(codepoint) else { return false }
        sessionKey = .character(Character(scalar))
    case Int(VIMEU_KEY_SPACE): sessionKey = .space
    case Int(VIMEU_KEY_ENTER): sessionKey = .enter
    case Int(VIMEU_KEY_BACKSPACE): sessionKey = .backspace
    case Int(VIMEU_KEY_ESCAPE): sessionKey = .escape
    case Int(VIMEU_KEY_UP): sessionKey = .up
    case Int(VIMEU_KEY_DOWN): sessionKey = .down
    default: sessionKey = .other
    }
    return s.session.handle(sessionKey, modifiers: SessionModifiers(rawValue: modifiers))
}

@_cdecl("vimeu_session_timer_fired")
public func vimeu_session_timer_fired(_ p: OpaquePointer?, _ timer: Int32) {
    guard let s = sessionBox(p), let t = SessionTimer(rawValue: timer) else { return }
    s.session.timerFired(t)
}

@_cdecl("vimeu_session_activate")
public func vimeu_session_activate(_ p: OpaquePointer?) {
    sessionBox(p)?.session.activate()
}

@_cdecl("vimeu_session_deactivate")
public func vimeu_session_deactivate(_ p: OpaquePointer?, _ commit: Bool) {
    sessionBox(p)?.session.deactivate(commit: commit)
}

@_cdecl("vimeu_session_is_composing")
public func vimeu_session_is_composing(_ p: OpaquePointer?) -> Bool {
    sessionBox(p)?.session.isComposing ?? false
}

@_cdecl("vimeu_session_select_candidate")
public func vimeu_session_select_candidate(_ p: OpaquePointer?, _ index: Int32) {
    sessionBox(p)?.session.selectCandidate(at: Int(index))
}

@_cdecl("vimeu_session_highlight_candidate")
public func vimeu_session_highlight_candidate(_ p: OpaquePointer?, _ index: Int32) {
    sessionBox(p)?.session.highlightCandidate(at: Int(index))
}

@_cdecl("vimeu_session_toggle_live_conversion")
public func vimeu_session_toggle_live_conversion(_ p: OpaquePointer?) {
    sessionBox(p)?.session.toggleLiveConversion()
}

@_cdecl("vimeu_session_open_tuner")
public func vimeu_session_open_tuner(_ p: OpaquePointer?) {
    sessionBox(p)?.session.openTuner()
}
