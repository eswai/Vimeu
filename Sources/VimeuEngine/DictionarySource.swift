import Foundation
import VimeuDict
import VimeuUserDict

/// What conversion needs from a dictionary.
///
/// The lattice and the decoder talk to this rather than to `DicReader` directly,
/// so the user's edits can be layered on top (`OverlaidDictionary`) without the
/// search knowing. It is deliberately narrow: prefix lookup and the three
/// POS-indexed tables Mozc's cost model reads.
///
/// Readings are addressed by their encoded form — one byte per kana, produced by
/// `encode` — so a whole sentence is encoded once and every lookup indexes into
/// it, instead of slicing strings per position.
public protocol DictionarySource: Sendable {
    /// Map a reading onto the dictionary's alphabet. Characters it has never
    /// seen become 0, which no key contains.
    func encode(_ reading: String) -> [UInt8]

    /// Every token whose reading is a prefix of `codes[from...]`, shortest
    /// first. `body` receives the reading length in kana and the token's Mozc
    /// fields, with the effective cost — the user's override where there is one.
    func forEachToken(
        codes: [UInt8],
        from: Int,
        _ body: (_ length: Int, _ surface: String, _ cost: Int32, _ lid: Int, _ rid: Int) -> Void
    )

    /// Mozc's connection cost for `left.rid` followed by `right.lid`. Called
    /// once per lattice edge examined, so it must stay O(1).
    func transitionCost(_ rid: Int, _ lid: Int) -> Int32

    /// Extra cost for beginning / ending the conversion with this POS.
    func prefixPenalty(_ lid: Int) -> Int32
    func suffixPenalty(_ rid: Int) -> Int32

    var posCount: Int { get }
    /// POS given to nodes the dictionary could not explain.
    var unknownPOSID: Int { get }
    /// The `id.def` feature string of a POS id, for the tuning UI.
    func posName(_ id: Int) -> String

    /// Sizes, for logging and for `vimeu-eval` to report what it ran against.
    var statistics: DictionaryStatistics { get }

    /// Word pairs the user has registered. Empty for everything but
    /// `OverlaidDictionary`, and empty there too until the user adds one — the
    /// packed dictionary has no such table and never will, because these are
    /// edits (§2.3), not data shipped with the dictionary.
    var collocations: Set<CollocationKey> { get }
}

extension DictionarySource {
    public var collocations: Set<CollocationKey> { [] }
}

public struct DictionaryStatistics: Sendable {
    public var readings: Int
    public var tokens: Int
    public var posCount: Int
    /// Non-zero only when a user dictionary is layered on top.
    public var userWordEdits: Int

    public init(readings: Int, tokens: Int, posCount: Int, userWordEdits: Int = 0) {
        self.readings = readings
        self.tokens = tokens
        self.posCount = posCount
        self.userWordEdits = userWordEdits
    }
}

/// The packed dictionary on its own — the whole source when the user has made
/// no edits.
extension DicReader: DictionarySource {
    public func forEachToken(
        codes: [UInt8],
        from: Int,
        _ body: (_ length: Int, _ surface: String, _ cost: Int32, _ lid: Int, _ rid: Int) -> Void
    ) {
        commonPrefixSearch(codes: codes, from: from) { length, readingID in
            forEachTokenField(readingID: readingID) { surface, cost, lid, rid in
                body(length, surface, cost, lid, rid)
            }
        }
    }

    public var statistics: DictionaryStatistics {
        DictionaryStatistics(readings: readingCount, tokens: tokenCount, posCount: posCount)
    }
}
