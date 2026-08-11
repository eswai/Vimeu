import Foundation

/// User-visible preferences. Sandboxed input methods lose direct access to their
/// own preferences domain, which is why `Vimeu.entitlements` carries the
/// `shared-preference` and `home-relative-path` exceptions for this bundle id.
enum Settings {
    private static let liveConversionKey = "liveConversion"

    static var liveConversion: Bool {
        get {
            // Default on: live conversion is the point of a sentence-level engine.
            if UserDefaults.standard.object(forKey: liveConversionKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: liveConversionKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: liveConversionKey) }
    }
}
