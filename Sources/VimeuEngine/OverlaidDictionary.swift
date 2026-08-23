import Foundation
import VimeuDict
import VimeuUserDict

/// The packed dictionary with the user's edits layered on top — the *effective*
/// dictionary conversion actually reads.
///
/// The edits cannot be merged into the system dictionary: `vimeu.dic` is a
/// memory mapping of an immutable file, and copying a million entries into the
/// heap to change a dozen of them is exactly what the mmap design exists to
/// avoid. So the edits stay in a small side table and are applied as the search
/// reads through.
///
/// Composition rules (DESIGN.md §2.4):
///
///     user row                  | in vimeu.dic  | effective result
///     --------------------------+---------------+-------------------------
///     (none)                    |      yes      | system value
///     cost, disabled = false    |      yes      | override
///     cost, disabled = false    |      no       | user-added word
///     disabled = true           |      yes      | excluded (revivable)
///     disabled = true           |      no       | no-op
///
/// Provenance — which of those rows applies — is settled once, here, by asking
/// the system dictionary whether it has the key. Nothing records the system's
/// own value, which is what lets `vimeu.dic` be rebuilt and swapped underneath
/// without invalidating a single edit.
///
/// An override applies to **every token** of the `(reading, surface)` pair. Mozc
/// registers one spelling under several POS ids, and the user is editing "this
/// word", not "this word as a proper noun" — see `WordEdit`.
///
/// Immutable: an edit produces a new instance (see `DictionaryEditor`), so a
/// conversion in flight on the background queue keeps reading a consistent
/// dictionary.
public final class OverlaidDictionary: DictionarySource, @unchecked Sendable {
    private let system: DicReader
    private let words: [WordKey: WordEdit]

    /// Surfaces mentioned by *any* word edit.
    ///
    /// The lookup path gets the surface for free but would have to decode the
    /// reading from its alphabet codes to form a `WordKey`, and doing that for
    /// every token of every lattice position would cost an allocation per hit.
    /// Users edit a handful of surfaces, so this set turns almost every hit into
    /// one failed set lookup and no allocation at all.
    private let editedSurfaces: Set<String>

    /// User-added words — those whose key is *not* in the system dictionary —
    /// grouped by reading length, because the mapped trie cannot find them and
    /// the lattice has to probe for them separately.
    private let addedByLength: [Int: [String: [(surface: String, cost: Int32)]]]

    /// POS given to a word the user added. Mozc's own `unknown_id`
    /// (名詞,サ変接続) — the same class it gives to words its dictionary cannot
    /// explain, which is exactly what a user-added word is.
    private let addedPOSID: Int

    /// The user's registered word pairs, read by `Converter` after the search.
    /// Unlike the word edits these never touch the lattice — they re-rank a
    /// finished n-best (see `Collocation`) — but they belong to the same
    /// snapshot, so an edit swaps them in as one consistent unit.
    public let collocations: Set<CollocationKey>

    /// The user's mutually exclusive pairs. These are kept separate from the
    /// positive set because a negative pair is a hard filter, not a score.
    public let negativeCollocations: Set<CollocationKey>

    private let collocationEdits: [CollocationKey: CollocationEdit]

    /// The user's connection edits, resolved from POS names onto the cell index
    /// `rid * posCount + lid` the matrix is addressed by.
    ///
    /// Flattened to one integer key because `transitionCost` is the hottest call
    /// in the decoder — once per lattice edge examined — and a two-field key
    /// would hash two fields there. Empty for every user who has not edited a
    /// transition, which is the case the guard below keeps free.
    private let connections: [Int: Int32]

    /// `editedRIDs[rid]` — does any edited cell sit in this row?
    ///
    /// Without it, a single connection edit made `transitionCost` hash on every
    /// call and cost 36% of conversion throughput. A `posCount`-wide flag array
    /// is 2,672 bytes and turns almost every call back into a load and a branch.
    /// Measured on `corpus/testset.tsv` (13,804 sentences, release, Apple M4,
    /// median of three), with one edit loaded:
    ///
    ///     overlay, no edits at all   3,625 sentences/s
    ///     one edit, this gate        3,486
    ///     one edit, hash every call  2,310
    private let editedRIDs: [Bool]

    private let connectionEdits: [ConnectionKey: ConnectionEdit]

    public init(system: DicReader, edits: UserDictionaryStore.Snapshot) {
        self.system = system
        self.words = edits.words
        self.collocations = Set(edits.collocations.values
            .filter { $0.polarity == .positive }
            .map(\.key))
        self.negativeCollocations = Set(edits.collocations.values
            .filter { $0.polarity == .negative }
            .map(\.key))
        self.collocationEdits = edits.collocations
        self.connectionEdits = edits.connections
        self.editedSurfaces = Set(edits.words.keys.map(\.surface))
        self.addedPOSID = system.unknownPOSID

        // Names are resolved against *this* dictionary, so the ids never have to
        // be right in the file (see `ConnectionKey`). Building the reverse map
        // materialises 2,672 strings, so it only happens when there is something
        // to resolve — the overlay is rebuilt on every edit.
        var cells: [Int: Int32] = [:]
        var rows = [Bool]()
        if !edits.connections.isEmpty {
            var idOf: [String: Int] = [:]
            idOf.reserveCapacity(system.posCount)
            for id in 0..<system.posCount { idOf[system.posName(id)] = id }
            rows = [Bool](repeating: false, count: system.posCount)
            for (key, edit) in edits.connections {
                guard let cost = edit.effectiveCost,
                      let rid = idOf[key.left], let lid = idOf[key.right] else { continue }
                cells[rid * system.posCount + lid] = cost
                rows[rid] = true
            }
        }
        self.connections = cells
        self.editedRIDs = rows

        var added: [Int: [String: [(surface: String, cost: Int32)]]] = [:]
        for (key, edit) in edits.words {
            guard let cost = edit.cost, !edit.disabled else { continue }
            // In the system dictionary this is an override, handled on the way
            // through; only genuinely new keys need their own lattice probe.
            guard system.tokens(reading: key.reading, surface: key.surface).isEmpty else { continue }
            let length = key.reading.unicodeScalars.count
            guard length > 0, length <= DicFormat.maxReadingLength else { continue }
            added[length, default: [:]][key.reading, default: []].append((key.surface, cost))
        }
        for length in added.keys {
            for reading in added[length]!.keys {
                added[length]![reading]!.sort {
                    $0.cost != $1.cost ? $0.cost < $1.cost : utf8Less($0.surface, $1.surface)
                }
            }
        }
        self.addedByLength = added
    }

    // MARK: - DictionarySource

    public func encode(_ reading: String) -> [UInt8] { system.encode(reading) }

    public func forEachToken(
        codes: [UInt8],
        from: Int,
        _ body: (_ length: Int, _ surface: String, _ cost: Int32, _ lid: Int, _ rid: Int) -> Void
    ) {
        // Decoding the reading is only ever needed for an edited surface or a
        // user-added probe, so it is done lazily and cached for this position.
        var decoded: [Int: String] = [:]
        func reading(length: Int) -> String {
            if let cached = decoded[length] { return cached }
            let text = system.decode(codes[from..<(from + length)])
            decoded[length] = text
            return text
        }

        system.forEachToken(codes: codes, from: from) { length, surface, cost, lid, rid in
            guard editedSurfaces.contains(surface) else {
                body(length, surface, cost, lid, rid)
                return
            }
            let key = WordKey(reading: reading(length: length), surface: surface)
            guard let edit = words[key] else {
                body(length, surface, cost, lid, rid)
                return
            }
            if edit.disabled { return }  // hidden by the user
            body(length, surface, edit.cost ?? cost, lid, rid)
        }

        guard !addedByLength.isEmpty else { return }
        let remaining = codes.count - from
        for (length, byReading) in addedByLength where length <= remaining {
            guard let entries = byReading[reading(length: length)] else { continue }
            for entry in entries {
                body(length, entry.surface, entry.cost, addedPOSID, addedPOSID)
            }
        }
    }

    public func transitionCost(_ rid: Int, _ lid: Int) -> Int32 {
        // The hot call of the whole decoder — once per lattice edge examined, on
        // the order of 10^5 per sentence. Both guards exist to keep the hash out
        // of it: `editedRIDs` is empty for a user who has edited no transition,
        // and false for all but the handful of rows of a user who has.
        if rid < editedRIDs.count, editedRIDs[rid],
           let edited = connections[rid * system.posCount + lid] {
            return edited
        }
        return system.transitionCost(rid, lid)
    }

    public func prefixPenalty(_ lid: Int) -> Int32 { system.prefixPenalty(lid) }
    public func suffixPenalty(_ rid: Int) -> Int32 { system.suffixPenalty(rid) }
    public var posCount: Int { system.posCount }
    public var unknownPOSID: Int { system.unknownPOSID }
    public func posName(_ id: Int) -> String { system.posName(id) }

    public var statistics: DictionaryStatistics {
        DictionaryStatistics(
            readings: system.readingCount,
            tokens: system.tokenCount,
            posCount: system.posCount,
            userWordEdits: words.count,
            userConnectionEdits: connections.count
        )
    }

    // MARK: - Provenance and effective values, for the tuning UI

    /// The system dictionary's own cost for a pair — the cheapest of its tokens,
    /// or nil for a word the user added.
    ///
    /// The cheapest is the right one to show: it is the token the lattice puts
    /// first, and an override replaces all of them anyway.
    public func systemCost(reading: String, surface: String) -> Int32? {
        system.tokens(reading: reading, surface: surface).map(\.cost).min()
    }

    /// The POS ids the system dictionary has for a pair, cheapest token first.
    /// Empty for a user-added word.
    public func systemPOSIDs(reading: String, surface: String) -> [Int] {
        system.tokens(reading: reading, surface: surface)
            .sorted { $0.cost < $1.cost }
            .map(\.lid)
    }

    public func wordEdit(reading: String, surface: String) -> WordEdit? {
        words[WordKey(reading: reading, surface: surface)]
    }

    /// Effective cost of one pair, or nil when it is hidden or absent.
    public func effectiveCost(reading: String, surface: String) -> Int32? {
        if let edit = wordEdit(reading: reading, surface: surface) {
            if edit.disabled { return nil }
            if let cost = edit.cost { return cost }
        }
        return systemCost(reading: reading, surface: surface)
    }

    /// Every word edit, for listing what the user has changed.
    public var allWordEdits: [WordEdit] { Array(words.values) }

    // MARK: - Connections, for the tuning UI

    /// Mozc's own cost for a transition, ignoring any edit — what リセット goes
    /// back to, and what the pane shows beside an overridden value.
    public func systemTransitionCost(_ rid: Int, _ lid: Int) -> Int32 {
        system.transitionCost(rid, lid)
    }

    /// The `ConnectionKey` for a pair of POS ids, i.e. the pair named the way the
    /// file names it. The UI has ids (they come off the lattice nodes); the edits
    /// have names.
    public func connectionKey(_ rid: Int, _ lid: Int) -> ConnectionKey {
        ConnectionKey(left: system.posName(rid), right: system.posName(lid))
    }

    public func connectionEdit(_ rid: Int, _ lid: Int) -> ConnectionEdit? {
        connectionEdits[connectionKey(rid, lid)]
    }

    /// Every connection edit, newest first.
    public var allConnectionEdits: [ConnectionEdit] {
        connectionEdits.values.sorted {
            $0.updatedAt != $1.updatedAt
                ? $0.updatedAt > $1.updatedAt
                : ($0.left != $1.left
                    ? utf8Less($0.left, $1.left)
                    : utf8Less($0.right, $1.right))
        }
    }

    /// Every registered pair, newest first — the order the 共起 pane lists them
    /// in, so a pair the user just added is at the top where they are looking.
    public var allCollocations: [CollocationEdit] {
        collocationEdits.values.sorted {
            $0.updatedAt != $1.updatedAt
                ? $0.updatedAt > $1.updatedAt
                : ($0.left != $1.left
                    ? utf8Less($0.left, $1.left)
                    : utf8Less($0.right, $1.right))
        }
    }
}
