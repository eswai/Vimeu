import Foundation
import VimeuDict

/// A hand-built dictionary for the engine tests.
///
/// The engine is exercised against this rather than the shipped one: these tests
/// assert the *mechanics* (lattice coverage, the cost identity, exactness of the
/// n-best). Whether the real dictionary converts real Japanese well is a
/// different question, measured by `vimeu-eval` against the frozen test sets in
/// `corpus/`.
enum TestDictionary {
    /// A small POS table shaped like `id.def`'s: 0 is BOS/EOS, the rest are
    /// ordinary classes.
    static let posNames = [
        "BOS/EOS,*,*",       // 0
        "名詞,一般,*",        // 1
        "助詞,格助詞,*",      // 2
        "動詞,自立,*",        // 3
        "名詞,サ変接続,*",    // 4 — Mozc's unknown_id
    ]
    static let unknownPOSID = 4
    static var posCount: Int { posNames.count }

    /// Row-major `[rid * posCount + lid]`. Reads as "how much it costs for a
    /// word of class *row* to be followed by one of class *column*".
    static let connection: [Int16] = [
        //  BOS/EOS 名詞  助詞  動詞  サ変
        /* from BOS */ 0, 100, 3000, 500, 2000,
        /* 名詞    */ 200, 800, 100, 900, 2000,
        /* 助詞    */ 300, 200, 2000, 150, 2000,
        /* 動詞    */ 0, 700, 400, 1500, 2000,
        /* サ変    */ 500, 1000, 1000, 1000, 1000,
    ]

    static func write(
        to path: String,
        words: [(reading: String, surface: String, cost: Int32, lid: Int, rid: Int)],
        prefixPenalty: [UInt16]? = nil,
        suffixPenalty: [UInt16]? = nil
    ) throws -> DicReader {
        let writer = DicWriter()
        try writer.setPOSTable(
            names: posNames,
            connection: connection,
            prefixPenalty: prefixPenalty ?? [UInt16](repeating: 0, count: posCount),
            suffixPenalty: suffixPenalty ?? [UInt16](repeating: 0, count: posCount),
            unknownPOSID: unknownPOSID
        )
        for w in words {
            try writer.add(reading: w.reading, surface: w.surface, cost: w.cost, lid: w.lid, rid: w.rid)
        }
        try writer.write(to: path)
        return try DicReader(path: path)
    }
}
