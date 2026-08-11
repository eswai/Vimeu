import Foundation
import VimeuDict
import VimeuUserDict

/// One row of the tuning UI's word list.
public struct WordKnob: Sendable, Identifiable, Equatable {
    public let reading: String
    public let surface: String
    /// The cost conversion is using right now. **Lower is more likely.**
    public let cost: Int32
    /// What `vimeu.dic` says, or nil for a word the user added.
    public let baseCost: Int32?
    /// POS of the system entry, cheapest token first — empty for a user-added
    /// word. Mozc keys entries by POS, and the same spelling under two POS ids
    /// is two entries, so the list has to say which is which.
    public let posNames: [String]
    /// A user edit is in force — "リセット" will undo it.
    public let userOverride: Bool
    /// Hidden from conversion — "復活" will bring it back.
    public let deleted: Bool

    public var id: String { reading + "\t" + surface }
}

/// Owns the user's dictionary: applies edits, persists them, and hands out the
/// effective dictionary to convert with.
///
/// Every edit is written through to disk immediately. vimeu has no automatic
/// learning, so an edit is always something the user deliberately asked for, and
/// there is no batch to defer. The undo path is "リセット" (drop the edit) and
/// "復活" (unhide), not an unsaved buffer.
public final class DictionaryEditor: @unchecked Sendable {
    private let system: DicReader
    private let store: UserDictionaryStore
    private let lock = NSLock()

    private var snapshot: UserDictionaryStore.Snapshot
    private var overlay: OverlaidDictionary

    /// Raised when persisting fails, so the UI can say so rather than silently
    /// losing the user's work.
    public private(set) var lastError: String?

    public init(system: DicReader, store: UserDictionaryStore) {
        self.system = system
        self.store = store
        let loaded = (try? store.load()) ?? UserDictionaryStore.Snapshot()
        self.snapshot = loaded
        self.overlay = OverlaidDictionary(system: system, edits: loaded)
    }

    /// The effective dictionary. Replaced wholesale after each edit, so a
    /// conversion already running keeps reading a consistent snapshot.
    public var dictionary: OverlaidDictionary {
        lock.lock()
        defer { lock.unlock() }
        return overlay
    }

    // MARK: - Word edits

    public func setWordCost(reading: String, surface: String, cost: Int32) {
        let key = WordKey(reading: reading, surface: surface)
        mutateWords { words in
            words[key] = WordEdit(
                reading: reading, surface: surface,
                cost: cost, disabled: words[key]?.disabled ?? false
            )
        }
    }

    /// 強める / 弱める. Relative on the way in, absolute once stored: the step is
    /// resolved against the value in force *now* so that rebuilding `vimeu.dic`
    /// later cannot move an edit the user already tuned by eye.
    ///
    /// `steps > 0` means "more likely", so it *lowers* the cost — the UI says
    /// 強める and the number goes down, which is the whole reason this method
    /// exists rather than exposing the raw value.
    public func boostWord(reading: String, surface: String, steps: Int) {
        let current = effectiveWordCost(reading: reading, surface: surface) ?? 0
        setWordCost(
            reading: reading, surface: surface,
            cost: UserDict.clampCost(current - Int32(steps) * UserDict.costStep)
        )
    }

    /// Hide a word from conversion.
    ///
    /// A system word is hidden (`disabled`), which is reversible. A user-added
    /// word is removed outright — there is no earlier value to come back to, so
    /// keeping a tombstone would only be clutter.
    public func deleteWord(reading: String, surface: String) {
        let key = WordKey(reading: reading, surface: surface)
        let inSystem = !system.tokens(reading: reading, surface: surface).isEmpty
        mutateWords { words in
            guard inSystem else {
                words[key] = nil
                return
            }
            words[key] = WordEdit(
                reading: reading, surface: surface,
                cost: words[key]?.cost, disabled: true
            )
        }
    }

    /// Undo a delete, keeping any cost the user had set.
    ///
    /// Clearing just the hidden flag is lossless and still lands on a state the
    /// composition rules cover; making 復活 identical to リセット would throw away
    /// a cost the user had tuned before hiding the word. If there was no cost,
    /// the row has nothing left to say and is dropped.
    public func reviveWord(reading: String, surface: String) {
        let key = WordKey(reading: reading, surface: surface)
        mutateWords { words in
            guard let existing = words[key] else { return }
            guard let cost = existing.cost else {
                words[key] = nil
                return
            }
            words[key] = WordEdit(reading: reading, surface: surface, cost: cost, disabled: false)
        }
    }

    /// Drop the edit entirely. A system word returns to its `vimeu.dic` value
    /// (and is un-hidden); a user-added word disappears.
    public func resetWord(reading: String, surface: String) {
        mutateWords { $0[WordKey(reading: reading, surface: surface)] = nil }
    }

    // MARK: - Collocation edits

    /// Register "these two words go together".
    ///
    /// No cost to choose: a pair is worth `UserDict.collocationBonus` or it is
    /// not registered. Re-adding an existing pair only refreshes its timestamp,
    /// which moves it to the top of the list — the same thing the user would
    /// mean by adding it twice.
    public func addCollocation(left: String, right: String) {
        let left = left.trimmingCharacters(in: .whitespaces)
        let right = right.trimmingCharacters(in: .whitespaces)
        guard !left.isEmpty, !right.isEmpty else { return }
        mutateCollocations { pairs in
            let edit = CollocationEdit(left: left, right: right)
            pairs[edit.key] = edit
        }
    }

    /// Pairs have no "disabled" state. A word edit keeps a tombstone because
    /// there is a system value underneath it to come back to; a pair is entirely
    /// the user's own, so removing it leaves nothing behind to describe.
    public func removeCollocation(left: String, right: String) {
        mutateCollocations { $0[CollocationKey(left: left, right: right)] = nil }
    }

    public var collocations: [CollocationEdit] { dictionary.allCollocations }

    /// The words the 共起 pane offers in its two menus: every content word in
    /// any candidate, in the order they were first seen.
    ///
    /// Pooled across *all* candidates, not just the selected one — the whole
    /// point of registering a pair is that the words are currently spread over
    /// candidates that lost. For `かわをむく` the shipped dictionary puts `皮` in
    /// the second candidate and `剥く` in the ninth, and a menu built from one
    /// candidate could never offer both.
    public func collocationChoices(for candidates: [Candidate]) -> [String] {
        let overlay = dictionary
        var seen = Set<String>()
        var choices: [String] = []
        for candidate in candidates {
            for index in Collocation.contentWordIndices(
                of: candidate.segments, dictionary: overlay
            ) {
                let surface = candidate.segments[index].surface
                if seen.insert(surface).inserted { choices.append(surface) }
            }
        }
        return choices
    }

    private func effectiveWordCost(reading: String, surface: String) -> Int32? {
        dictionary.effectiveCost(reading: reading, surface: surface)
            ?? dictionary.wordEdit(reading: reading, surface: surface)?.cost
    }

    // MARK: - Knobs

    /// The word rows for a conversion: every entry the candidates were built
    /// from, plus any the user has hidden whose reading occurs in this sentence.
    ///
    /// The hidden ones matter — a deleted word produces no candidate, so without
    /// surfacing it here there would be no way to reach "復活" from the sentence
    /// that made the user want it back.
    public func wordKnobs(for candidates: [Candidate], reading: String) -> [WordKnob] {
        let overlay = dictionary
        var seen = Set<WordKey>()
        var knobs: [WordKnob] = []

        for candidate in candidates {
            for segment in candidate.segments {
                let key = WordKey(reading: segment.reading, surface: segment.surface)
                guard seen.insert(key).inserted else { continue }
                knobs.append(knob(reading: segment.reading, surface: segment.surface, overlay: overlay))
            }
        }

        for edit in overlay.allWordEdits where edit.disabled {
            let key = edit.key
            guard !seen.contains(key), reading.contains(edit.reading) else { continue }
            seen.insert(key)
            knobs.append(knob(reading: edit.reading, surface: edit.surface, overlay: overlay))
        }
        // Cheapest first — the order the lattice itself prefers them in.
        return knobs.sorted { $0.cost != $1.cost ? $0.cost < $1.cost : $0.id < $1.id }
    }

    private func knob(reading: String, surface: String, overlay: OverlaidDictionary) -> WordKnob {
        let edit = overlay.wordEdit(reading: reading, surface: surface)
        let base = overlay.systemCost(reading: reading, surface: surface)
        return WordKnob(
            reading: reading,
            surface: surface,
            cost: edit?.cost ?? base ?? 0,
            baseCost: base,
            posNames: overlay.systemPOSIDs(reading: reading, surface: surface).map(overlay.posName),
            userOverride: edit?.cost != nil,
            deleted: edit?.disabled ?? false
        )
    }

    // MARK: - Plumbing

    private func mutateWords(_ body: (inout [WordKey: WordEdit]) -> Void) {
        lock.lock()
        body(&snapshot.words)
        let words = snapshot.words
        overlay = OverlaidDictionary(system: system, edits: snapshot)
        lock.unlock()
        record { try store.saveWords(words) }
    }

    private func mutateCollocations(_ body: (inout [CollocationKey: CollocationEdit]) -> Void) {
        lock.lock()
        body(&snapshot.collocations)
        let pairs = snapshot.collocations
        overlay = OverlaidDictionary(system: system, edits: snapshot)
        lock.unlock()
        record { try store.saveCollocations(pairs) }
    }

    private func record(_ work: () throws -> Void) {
        do {
            try work()
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }
}
