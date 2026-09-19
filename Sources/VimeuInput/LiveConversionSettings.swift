import Foundation

/// Shared preference contract for the IME and adjustment window.
public enum LiveConversionSettings {
    public static let delayKey = "liveConversionDelayMilliseconds"
    public static let defaultDelay = 0
    public static let delayRange = 0...60_000

    public static func clamp(_ value: Int) -> Int {
        min(max(value, delayRange.lowerBound), delayRange.upperBound)
    }

    public static var delayMilliseconds: Int {
        clamp(UserDefaults.standard.integer(forKey: delayKey))
    }
}
