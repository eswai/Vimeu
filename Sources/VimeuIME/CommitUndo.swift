import Foundation

/// Remembers the text just committed, with the reading it came from, so that
/// the very next Backspace can bring it back as a conversion. One shot: any
/// key, including that Backspace, forgets it.
struct CommitUndo {
    struct Entry: Equatable {
        let text: String
        let reading: String
        /// Left context the conversion used, restored with the reading.
        let previousRightID: Int?
    }

    private(set) var entry: Entry?

    mutating func record(text: String, reading: String, previousRightID: Int?) {
        entry = text.isEmpty || reading.isEmpty
            ? nil : Entry(text: text, reading: reading, previousRightID: previousRightID)
    }

    mutating func clear() { entry = nil }

    /// The UTF-16 range holding the committed text, or nil to let Backspace
    /// behave normally. Only when the caret sits right after the committed
    /// text with nothing selected, checked against the client's own text: the
    /// caret may have moved (a click) without the input method seeing it.
    static func range(for text: String?, selectedRange: NSRange,
                      textIn: (NSRange) -> String?) -> NSRange? {
        guard let text, !text.isEmpty,
              selectedRange.location != NSNotFound, selectedRange.length == 0 else { return nil }
        let length = text.utf16.count
        guard selectedRange.location >= length else { return nil }
        let range = NSRange(location: selectedRange.location - length, length: length)
        guard textIn(range) == text else { return nil }
        return range
    }

    /// How the committed range becomes marked text again.
    enum RestoreMethod: Equatable {
        /// `setMarkedText` with the committed range as the replacement range.
        case replaceRange
        /// Pass the Backspace on, letting the client delete the last
        /// character itself, then make the rest marked with `setMarkedText`
        /// and a replacement range once that key is done. (An empty
        /// `insertText(replacementRange:)` deletes nothing there.) For Chromium-based clients, which send the keydown to
        /// the page before any composition the input method starts: a web
        /// editor (Claude desktop's composer, 2026-10-24) then runs its own
        /// Backspace against the text being reconverted, and the committed
        /// text showed twice, whether the range was composed over or deleted
        /// first within the same key.
        case deleteThenMark
    }

    /// Chromium browsers and Electron apps. Matched by bundle identifier: the
    /// sandbox keeps the input method from reading other apps' bundles, and
    /// Chromium answers the text-input queries the same way WebKit does.
    static let chromiumBundlePrefixes = [
        "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.anthropic.claudefordesktop", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", // Cursor
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "md.obsidian", "notion.id",
        "com.github.GitHubClient",
    ]

    /// What is left of the committed range once the client's Backspace has
    /// deleted its last character (one grapheme, as Backspace does).
    static func rangeLeftAfterBackspace(_ range: NSRange, text: String) -> NSRange {
        let last = text.last.map { String($0).utf16.count } ?? 0
        return NSRange(location: range.location, length: max(0, range.length - last))
    }

    static func restoreMethod(bundleIdentifier: String?) -> RestoreMethod {
        guard let id = bundleIdentifier else { return .replaceRange }
        return chromiumBundlePrefixes.contains { id.hasPrefix($0) } ? .deleteThenMark : .replaceRange
    }

    /// Candidates for the restored conversion, starting on the committed text.
    /// Kept first-found order; the committed text goes in front only when the
    /// fresh conversion no longer lists it (e.g. a kana form forced by Ctrl+J).
    static func reconversionCandidates(committed: String, candidates: [String]) -> (candidates: [String], selected: Int) {
        if let i = candidates.firstIndex(of: committed) { return (candidates, i) }
        return ([committed] + candidates, 0)
    }
}
