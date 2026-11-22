import Foundation
import VimeuDict
import VimeuEngine
import VimeuUserDict

/// The conversion engine for one process: the mmap'ed system dictionary plus
/// the user's edits. Linux counterpart of `VimeuIME/ConversionService.swift`,
/// without the bundle lookup and the background queue (fcitx5 calls in from
/// its single event-loop thread; DESIGN.md §8).
public final class Engine: @unchecked Sendable {
    private let system: DicReader?
    private let store: UserDictionaryStore
    private let lock = NSLock()
    private var editorStorage: DictionaryEditor?
    public let boundaryRules: PartialCommitBoundaryRules?
    /// Why the dictionary is unavailable, when it is. Kana input still works.
    public let loadFailure: String?

    /// - Parameters:
    ///   - dictionaryPath: `vimeu.dic`. Nil or unreadable leaves the engine in
    ///     kana-only mode, like the macOS IME without a bundled dictionary.
    ///   - userDirectory: where `user_*.tsv` live; nil for the XDG default.
    public init(dictionaryPath: String?, userDirectory: String? = nil) {
        store = UserDictionaryStore(directory: userDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? UserDictionaryStore.defaultDirectory())
        var failure: String?
        var reader: DicReader?
        if let path = dictionaryPath {
            do { reader = try DicReader(path: path) } catch { failure = "\(error)" }
        } else {
            failure = "vimeu.dic not found"
        }
        system = reader
        loadFailure = failure
        boundaryRules = reader.map { PartialCommitBoundaryRules(dictionary: $0) }
        editorStorage = reader.map { DictionaryEditor(system: $0, store: store) }
    }

    public var isReady: Bool { editor != nil }

    public var userDirectory: URL { store.directory }

    public var editor: DictionaryEditor? {
        lock.lock()
        defer { lock.unlock() }
        return editorStorage
    }

    /// Re-read the user's TSV files (after vimeu-tune or a hand edit). The
    /// effective dictionary is replaced wholesale, as an edit does upstream.
    public func reloadUserDictionary() {
        guard let system else { return }
        let fresh = DictionaryEditor(system: system, store: store)
        lock.lock()
        editorStorage = fresh
        lock.unlock()
    }

    public func convert(reading: String, limit: Int, previousRightID: Int? = nil) -> [Candidate] {
        guard let editor else { return [] }
        return Converter(dictionary: editor.dictionary)
            .convert(reading: reading, limit: limit, previousRightID: previousRightID)
    }

    /// Where to look for the dictionary when the host does not say:
    /// `$VIMEU_DIC`, `$XDG_DATA_HOME/vimeu/vimeu.dic`, `/usr/share/vimeu/vimeu.dic`.
    public static func defaultDictionaryPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        var paths: [String] = []
        if let p = env["VIMEU_DIC"], !p.isEmpty { paths.append(p) }
        let dataHome = env["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? (NSHomeDirectory() + "/.local/share")
        paths.append(dataHome + "/vimeu/vimeu.dic")
        paths.append("/usr/share/vimeu/vimeu.dic")
        return paths.first { FileManager.default.isReadableFile(atPath: $0) }
    }
}
