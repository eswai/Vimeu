import Foundation
import VimeuDict
import VimeuEngine
import VimeuUserDict
import os.log

/// Owns the conversion engine for the whole process and keeps it off the main
/// thread.
///
/// Conversion of a long reading takes a few milliseconds — short enough that the
/// Space path just waits for it, long enough that doing it on every keystroke on
/// the main thread would be felt. Live conversion therefore goes through a
/// serial background queue with coalescing (see `LiveConversionCoordinator`).
///
/// Loading is cheap by construction: the dictionary is `mmap`ed, so opening it
/// parses nothing and the pages fault in as conversion touches them.
final class ConversionService: @unchecked Sendable {
    static let shared = ConversionService()

    private let queue = DispatchQueue(label: "dev.vimeu.conversion", qos: .userInitiated)
    private let lock = NSLock()
    /// Owns the user's edits and hands out the effective dictionary. Nil until
    /// the bundled dictionary has been opened.
    private var editorStorage: DictionaryEditor?
    private var loadFailure: String?

    private init() {}

    /// Open the dictionary bundled at `Contents/Resources/dict/vimeu.dic`.
    /// Safe to call more than once; only the first call does work.
    func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard editorStorage == nil, loadFailure == nil else { return }

        guard let url = Bundle.main.url(forResource: "vimeu", withExtension: "dic", subdirectory: "dict") else {
            loadFailure = "vimeu.dic missing from the app bundle"
            logger.error("\(self.loadFailure!, privacy: .public)")
            return
        }
        do {
            let dictionary = try DicReader(path: url.path)
            let store = UserDictionaryStore(directory: UserDictionaryStore.defaultDirectory())
            let editor = DictionaryEditor(system: dictionary, store: store)
            editorStorage = editor
            let stats = editor.dictionary.statistics
            logger.info("""
                dictionary loaded: \(stats.readings) readings, \(stats.tokens) tokens, \
                \(stats.posCount) POS ids; user edits: \(stats.userWordEdits) words \
                (\(store.directory.path, privacy: .public))
                """)
        } catch {
            loadFailure = "\(error)"
            logger.error("dictionary load failed: \(self.loadFailure!, privacy: .public)")
        }
    }

    var isReady: Bool { editor != nil }

    /// The user dictionary, for the tuning window. Nil before the bundled
    /// dictionary has been opened.
    var editor: DictionaryEditor? {
        lock.lock()
        defer { lock.unlock() }
        return editorStorage
    }

    /// Convert now, on the calling thread. Used for the Space key, where the
    /// user is waiting for the candidate window anyway.
    ///
    /// A `Converter` is built per call rather than cached: it is a reference to
    /// the effective dictionary, which an edit in the tuning window replaces
    /// wholesale, and rebuilding it is how the next conversion picks the edit up.
    func convertNow(reading: String, limit: Int) -> [Candidate] {
        guard let editor else { return [] }
        return Converter(dictionary: editor.dictionary).convert(reading: reading, limit: limit)
    }

    /// Convert on the background queue and deliver the result on the main actor.
    func convert(
        reading: String,
        limit: Int,
        completion: @escaping @MainActor ([Candidate], String) -> Void
    ) {
        queue.async { [weak self] in
            let candidates = self?.convertNow(reading: reading, limit: limit) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(candidates, reading) }
            }
        }
    }
}

/// Coalesces live-conversion requests so keystrokes never pile up.
///
/// Only one conversion runs at a time and only the newest reading is ever
/// queued: typing faster than the engine simply skips intermediate readings
/// rather than building a backlog. Results for a reading that is no longer
/// current are dropped, so the inline text can't flash back to an older
/// conversion.
///
/// There is no debounce timer. The predecessor needed one because every
/// keystroke meant a gRPC round trip to another process; in-process conversion
/// is cheap enough that delaying it would only add lag.
///
/// All state is touched on the main thread, matching the controller — which is
/// what the `@unchecked Sendable` stands on. It is needed because the result
/// callback is handed across to the conversion queue and back.
final class LiveConversionCoordinator: @unchecked Sendable {
    private let service: ConversionService
    private var latestReading = ""
    private var inFlight = false

    /// Called on the main actor with (candidates, reading) for the newest
    /// reading only.
    var onResult: (@MainActor ([Candidate], String) -> Void)?

    init(service: ConversionService = .shared) {
        self.service = service
    }

    func submit(reading: String) {
        latestReading = reading
        pumpIfIdle()
    }

    /// Drop the pending reading so an in-flight completion won't re-fire.
    /// Call when leaving the composing state.
    func reset() {
        latestReading = ""
    }

    private func pumpIfIdle() {
        guard !inFlight else { return }  // the in-flight completion re-pumps
        pump()
    }

    private func pump() {
        let reading = latestReading
        guard !reading.isEmpty else { return }
        inFlight = true
        service.convert(reading: reading, limit: 1) { [weak self] candidates, converted in
            guard let self else { return }
            self.inFlight = false
            if converted == self.latestReading, !candidates.isEmpty {
                self.onResult?(candidates, converted)
            }
            // A newer reading arrived while this one was running.
            if self.latestReading != converted { self.pump() }
        }
    }
}
