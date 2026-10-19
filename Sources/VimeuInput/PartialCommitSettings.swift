import Foundation

/// Shared preferences for length-based prefix commits. Automatic conversion
/// uses the shared idle timer. A snapshot keeps each decision consistent.
public struct PartialCommitSettings: Sendable, Equatable {
    public enum Mode: String, CaseIterable, Sendable {
        case converted
        case reading
    }

    public static let enabledKey = "partialCommitEnabled"
    public static let lengthKey = "partialCommitLength"
    public static let modeKey = "partialCommitMode"
    public static let requiresStableCandidateKey = "partialCommitRequiresStableCandidate"
    public static let stableLengthKey = "partialCommitStableLength"
    public static let defaultLength = 40
    public static let lengthRange = 2...1_000
    public static let defaultMode: Mode = .converted
    public static let defaultStableLength = 5
    public static let defaultRequiresStableCandidate = true
    public static let stableLengthRange = 1...1_000

    public let enabled: Bool
    public let length: Int
    public let mode: Mode
    public let requiresStableCandidate: Bool
    public let stableLength: Int

    public init(
        enabled: Bool = true, length: Int = defaultLength, mode: Mode = defaultMode,
        requiresStableCandidate: Bool = defaultRequiresStableCandidate, stableLength: Int = defaultStableLength
    ) {
        self.enabled = enabled
        self.length = Self.clampLength(length)
        self.mode = mode
        self.requiresStableCandidate = requiresStableCandidate
        self.stableLength = Self.clampStableLength(stableLength)
    }

    public init(defaults: UserDefaults) {
        self.init(
            enabled: defaults.object(forKey: Self.enabledKey) == nil
                ? true : defaults.bool(forKey: Self.enabledKey),
            length: defaults.object(forKey: Self.lengthKey) == nil
                ? Self.defaultLength : defaults.integer(forKey: Self.lengthKey),
            mode: Mode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? Self.defaultMode,
            requiresStableCandidate: defaults.object(forKey: Self.requiresStableCandidateKey) == nil
                ? Self.defaultRequiresStableCandidate : defaults.bool(forKey: Self.requiresStableCandidateKey),
            stableLength: defaults.object(forKey: Self.stableLengthKey) == nil
                ? Self.defaultStableLength : defaults.integer(forKey: Self.stableLengthKey)
        )
    }

    public static var current: Self { Self(defaults: .standard) }

    public static func clampLength(_ value: Int) -> Int {
        min(max(value, lengthRange.lowerBound), lengthRange.upperBound)
    }

    public static func clampStableLength(_ value: Int) -> Int {
        min(max(value, stableLengthRange.lowerBound), stableLengthRange.upperBound)
    }

    /// Stability needs observations before the total-length threshold, too.
    public var observesStability: Bool { enabled && requiresStableCandidate }

    /// Keep recent input editable, even for small configured thresholds.
    public var retainedLength: Int { length / 2 }

    public func isNeeded(reading: String) -> Bool {
        enabled && reading.count >= length
    }

    public func converts(liveConversion: Bool) -> Bool {
        liveConversion || mode == .converted
    }
}
