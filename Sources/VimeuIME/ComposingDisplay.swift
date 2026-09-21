import Foundation

/// Builds the marked text for a composing buffer while a live conversion is
/// available. The live result is intentionally reusable while another
/// conversion request is in flight; falling back to the raw reading would
/// make the marked text flash between kana and kanji.
struct ComposingDisplay {
    static func text(
        liveConversionEnabled: Bool,
        reading: String,
        pendingRomaji: String,
        liveReading: String?,
        liveText: String?
    ) -> String {
        if liveConversionEnabled,
           let liveReading,
           let liveText,
           reading.hasPrefix(liveReading) {
            return liveText + reading.dropFirst(liveReading.count) + pendingRomaji
        }
        return reading + pendingRomaji
    }
}
