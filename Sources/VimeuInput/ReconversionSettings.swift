import Foundation

/// Shared preference contract for the IME and adjustment window.
public enum ReconversionSettings {
    /// Backspace right after a commit turns it back into a conversion.
    public static let backspaceKey = "reconvertOnBackspaceAfterCommit"
    public static let defaultBackspace = true

    public static var backspaceEnabled: Bool { backspaceEnabled(in: .standard) }

    public static func backspaceEnabled(in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: backspaceKey) != nil else { return defaultBackspace }
        return defaults.bool(forKey: backspaceKey)
    }
}
