import VimeuInput

/// A key as the session sees it. Platform adapters (fcitx5 KeySym, macOS
/// kVK_*) translate into this, so the state machine never sees raw key codes.
public enum SessionKey: Equatable, Sendable {
    /// A printable key, with the text it produces (already shifted).
    case character(Character)
    case space
    case enter
    case backspace
    case escape
    case up
    case down
    /// Anything else (arrows, Tab, function keys, ...). Commits and passes through.
    case other
}

public struct SessionModifiers: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let shift = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 2)
    /// Option on macOS, Alt (Mod1) on Linux.
    public static let alt = Self(rawValue: 1 << 3)
    /// Command on macOS, Super on Linux.
    public static let command = Self(rawValue: 1 << 6)
}

/// The client's text around the cursor, as fcitx5 reports it. Offsets are in
/// Unicode scalars. `cursor == anchor` means no selection.
public struct SurroundingText: Equatable, Sendable {
    public let text: String
    public let cursor: Int
    public let anchor: Int
    public init(text: String, cursor: Int, anchor: Int) {
        self.text = text
        self.cursor = cursor
        self.anchor = anchor
    }
}

/// Every preference the session reads, as one snapshot. The macOS IME reads
/// these from UserDefaults; on Linux the fcitx5 addon owns them (its config
/// file) and pushes a snapshot whenever they change.
public struct SessionSettings: Equatable, Sendable {
    public var liveConversion: Bool
    public var liveConversionDelayMilliseconds: Int
    public var autoCommitEnabled: Bool
    public var autoCommitDelayMilliseconds: Int
    public var partialCommit: PartialCommitSettings
    public var reconvertOnBackspace: Bool

    public init(
        liveConversion: Bool = true,
        liveConversionDelayMilliseconds: Int = LiveConversionSettings.defaultDelay,
        autoCommitEnabled: Bool = false,
        autoCommitDelayMilliseconds: Int = LiveConversionSettings.defaultAutoCommitDelay,
        partialCommit: PartialCommitSettings = PartialCommitSettings(),
        reconvertOnBackspace: Bool = ReconversionSettings.defaultBackspace
    ) {
        self.liveConversion = liveConversion
        self.liveConversionDelayMilliseconds = LiveConversionSettings.clamp(liveConversionDelayMilliseconds)
        self.autoCommitEnabled = autoCommitEnabled
        self.autoCommitDelayMilliseconds = LiveConversionSettings.clampAutoCommitDelay(autoCommitDelayMilliseconds)
        self.partialCommit = partialCommit
        self.reconvertOnBackspace = reconvertOnBackspace
    }
}

/// Timers the session asks its host to run. The host calls
/// `Session.timerFired(_:)` on the same thread that delivers keys.
public enum SessionTimer: Int32, Sendable {
    case liveConversion = 1
    case autoCommit = 2
}

/// What the session does to the outside world. All calls happen synchronously
/// on the thread that called into the session.
public protocol SessionClient: AnyObject {
    /// Show `text` as the composition. `converting` marks a candidate being
    /// selected (highlighted) rather than plain composing text.
    func setPreedit(_ text: String, converting: Bool)
    /// Insert `text` and end the composition shown so far.
    func commit(_ text: String)
    /// Show a new candidate list. Called once per conversion; moving the
    /// selection afterwards goes through `selectCandidate(_:)`.
    func showCandidates(_ candidates: [String], selected: Int)
    func selectCandidate(_ index: Int)
    func hideCandidates()
    /// The client's surrounding text, or nil if it does not provide it.
    func surroundingText() -> SurroundingText?
    /// Delete `count` Unicode scalars before the cursor.
    func deleteBeforeCursor(_ count: Int)
    func startTimer(_ timer: SessionTimer, milliseconds: Int)
    func cancelTimer(_ timer: SessionTimer)
    /// Control+; / the "調整..." action. `reading` is what was being composed.
    func openTuner(reading: String?)
}
