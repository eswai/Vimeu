import Foundation

/// Shared preference contract for the IME and adjustment window.
public enum LiveConversionSettings {
    public static let delayKey = "liveConversionDelayMilliseconds"
    public static let defaultDelay = 0
    public static let delayRange = 0...60_000

    public static let autoCommitEnabledKey = "liveConversionAutoCommitEnabled"
    public static let autoCommitDelayKey = "liveConversionAutoCommitDelayMilliseconds"
    public static let defaultAutoCommitDelay = 3_000
    public static let autoCommitDelayRange = 100...60_000

    public static func clamp(_ value: Int) -> Int {
        min(max(value, delayRange.lowerBound), delayRange.upperBound)
    }

    public static var delayMilliseconds: Int {
        clamp(UserDefaults.standard.integer(forKey: delayKey))
    }

    public static var autoCommitEnabled: Bool {
        UserDefaults.standard.bool(forKey: autoCommitEnabledKey)
    }

    public static func clampAutoCommitDelay(_ value: Int) -> Int {
        min(max(value, autoCommitDelayRange.lowerBound), autoCommitDelayRange.upperBound)
    }

    public static var autoCommitDelayMilliseconds: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: autoCommitDelayKey) != nil else {
            return defaultAutoCommitDelay
        }
        return clampAutoCommitDelay(defaults.integer(forKey: autoCommitDelayKey))
    }
}
