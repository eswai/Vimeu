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

/// One row of the tuning UI's connection list: a transition of the selected
/// candidate, plus whether the user has moved it.
///
/// Identified by position in the path, not by the POS pair, because a candidate
/// can cross the same pair twice (`… の … の …`) and the pane lists the path in
/// order. The two rows then edit the same cell and move together, which is the
/// truth of what a connection edit does.
public struct ConnectionKnob: Sendable, Identifiable, Equatable {
    /// Index of the boundary in the candidate, 0 being the BOS transition.
    public let index: Int
    /// Surface of the left word, nil at the sentence start.
    public let left: String?
    /// Surface of the right word, nil at the sentence end.
    public let right: String?
    /// The ids the cell is addressed by: `left.rid` and `right.lid`, 0 for BOS/EOS.
    public let rid: Int
    public let lid: Int
    public let leftPOS: String
    public let rightPOS: String
    /// The cost conversion is using right now. **Lower is more likely.**
    public let cost: Int32
    /// What Mozc's matrix says.
    public let baseCost: Int32
    public let userOverride: Bool
    /// The user asked for this transition not to be used — cost is pinned at
    /// `UserDict.forbiddenConnectionCost` and 復活 undoes it.
    public let disabled: Bool

    public var id: Int { index }
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

    /// Register a relation between two words.
    ///
    /// A positive pair is directional and worth `UserDict.collocationBonus`; a
    /// negative pair is unordered and excludes candidates containing both
    /// words. Re-adding an existing relation refreshes its timestamp, which
    /// moves it to the top of the list.
    public func addCollocation(
        left: String, right: String, polarity: CollocationPolarity = .positive
    ) {
        let left = left.trimmingCharacters(in: .whitespaces)
        let right = right.trimmingCharacters(in: .whitespaces)
        guard !left.isEmpty, !right.isEmpty else { return }
        mutateCollocations { pairs in
            // A negative relation is mutual exclusion, so store it in a stable
            // order and prevent the same two words from being both positive and
            // negative at once. A new explicit relation replaces the old one.
            let storedKey = polarity == .negative
                ? CollocationKey.unordered(left, right)
                : CollocationKey(left: left, right: right)
            for (key, existing) in pairs where
                existing.polarity != polarity &&
                (key.isUnorderedMatch(storedKey) || storedKey.isUnorderedMatch(key)) {
                pairs[key] = nil
            }
            let edit = CollocationEdit(
                left: storedKey.left, right: storedKey.right, polarity: polarity
            )
            pairs[edit.key] = edit
        }
    }

    public func addPositiveCollocation(left: String, right: String) {
        addCollocation(left: left, right: right, polarity: .positive)
    }

    public func addNegativeCollocation(left: String, right: String) {
        addCollocation(left: left, right: right, polarity: .negative)
    }

    /// Pairs have no "disabled" state. A word edit keeps a tombstone because
    /// there is a system value underneath it to come back to; a pair is entirely
    /// the user's own, so removing it leaves nothing behind to describe.
    public func removeCollocation(left: String, right: String) {
        let key = CollocationKey(left: left, right: right)
        mutateCollocations { pairs in
            pairs[key] = nil
            // Negative relations are unordered, so removing either display
            // order removes the stored relation.
            for (storedKey, edit) in pairs where
                edit.polarity == .negative && storedKey.isUnorderedMatch(key) {
                pairs[storedKey] = nil
            }
        }
    }

    public var collocations: [CollocationEdit] { dictionary.allCollocations }

    public var positiveCollocations: [CollocationEdit] {
        collocations.filter { $0.polarity == .positive }
    }

    public var negativeCollocations: [CollocationEdit] {
        collocations.filter { $0.polarity == .negative }
    }

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

    // MARK: - Connection edits

    /// Override one cell of the connection matrix.
    ///
    /// Takes POS **ids** because that is what the caller has — they come off the
    /// lattice nodes of the candidate being explained — and stores names, because
    /// that is what survives a dictionary rebuild (see `ConnectionKey`).
    public func setConnectionCost(rid: Int, lid: Int, cost: Int32) {
        let key = dictionary.connectionKey(rid, lid)
        mutateConnections { connections in
            connections[key] = ConnectionEdit(
                left: key.left, right: key.right,
                cost: cost, disabled: false
            )
        }
    }

    /// 強める / 弱める for a transition. Same sign convention and same ∓500 step
    /// as `boostWord`: `steps > 0` means "more likely", so the cost goes down.
    ///
    /// Resolved against the value in force now and stored absolute, so the edit
    /// does not drift when `vimeu.dic` is rebuilt.
    public func boostConnection(rid: Int, lid: Int, steps: Int) {
        let current = dictionary.transitionCost(rid, lid)
        setConnectionCost(
            rid: rid, lid: lid,
            cost: UserDict.clampCost(current - Int32(steps) * UserDict.costStep)
        )
    }

    /// "この接続を使わない" — the transition keeps a finite cost
    /// (`UserDict.forbiddenConnectionCost`) so the lattice still spans the input;
    /// it just loses to anything else. Reversible, like hiding a word.
    ///
    /// Any cost the user had set is kept, so 復活 lands back on it rather than on
    /// Mozc's value.
    public func disableConnection(rid: Int, lid: Int) {
        let key = dictionary.connectionKey(rid, lid)
        mutateConnections { connections in
            connections[key] = ConnectionEdit(
                left: key.left, right: key.right,
                cost: connections[key]?.cost, disabled: true
            )
        }
    }

    public func reviveConnection(rid: Int, lid: Int) {
        let key = dictionary.connectionKey(rid, lid)
        mutateConnections { connections in
            guard let existing = connections[key] else { return }
            guard let cost = existing.cost else {
                connections[key] = nil
                return
            }
            connections[key] = ConnectionEdit(
                left: key.left, right: key.right, cost: cost, disabled: false
            )
        }
    }

    /// Back to Mozc's own value for this cell.
    public func resetConnection(rid: Int, lid: Int) {
        let key = dictionary.connectionKey(rid, lid)
        mutateConnections { $0[key] = nil }
    }

    public var connectionEdits: [ConnectionEdit] { dictionary.allConnectionEdits }

    /// The connection rows for one candidate: its transitions in path order,
    /// BOS first and EOS last.
    ///
    /// Only the selected candidate's, unlike the word list which pools every
    /// candidate. A transition is a fact about one path — the same POS pair in
    /// another candidate is a different boundary between different words — and
    /// the pane exists to say why *this* candidate scored what it did.
    public func connectionKnobs(for candidate: Candidate) -> [ConnectionKnob] {
        let overlay = dictionary
        return candidate.boundaries.map { boundary in
            let edit = overlay.connectionEdit(boundary.rid, boundary.lid)
            return ConnectionKnob(
                index: boundary.index,
                left: boundary.left?.surface,
                right: boundary.right?.surface,
                rid: boundary.rid,
                lid: boundary.lid,
                leftPOS: overlay.posName(boundary.rid),
                rightPOS: overlay.posName(boundary.lid),
                cost: boundary.cost,
                baseCost: overlay.systemTransitionCost(boundary.rid, boundary.lid),
                userOverride: edit?.cost != nil,
                disabled: edit?.disabled ?? false
            )
        }
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

    private func mutateConnections(_ body: (inout [ConnectionKey: ConnectionEdit]) -> Void) {
        lock.lock()
        body(&snapshot.connections)
        let connections = snapshot.connections
        overlay = OverlaidDictionary(system: system, edits: snapshot)
        lock.unlock()
        record { try store.saveConnections(connections) }
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
