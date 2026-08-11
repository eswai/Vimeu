import XCTest
@testable import VimeuDict

/// Everything the engine relies on has to survive the trip through the file:
/// write a dictionary, mmap it back, and check it token for token.
final class DicRoundTripTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimeu-test-\(UUID().uuidString).dic").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    // A three-POS toy table standing in for Mozc's 2,672: 0 is BOS/EOS as it is
    // in id.def, 1 and 2 are ordinary words.
    private static let posNames = ["BOS/EOS,*,*", "名詞,一般,*", "助詞,格助詞,*"]
    private static let posCount = 3
    /// Row-major [rid * 3 + lid].
    private static let connection: [Int16] = [
        0, 100, 900,   // from BOS
        200, 700, 10,  // from 名詞
        300, 20, 800,  // from 助詞
    ]
    private static let prefixPenalty: [UInt16] = [0, 0, 3000]
    private static let suffixPenalty: [UInt16] = [0, 500, 0]

    /// (reading, surface, cost, lid, rid)
    private static let words: [(String, String, Int32, Int, Int)] = [
        ("あおい", "青い", 5000, 1, 1),
        ("あおい", "葵", 6200, 1, 1),
        ("とうきょう", "東京", 4000, 1, 1),
        ("はし", "橋", 5500, 1, 1),
        ("はし", "箸", 5900, 1, 1),
    ]

    private func makeWriter() throws -> DicWriter {
        let w = DicWriter()
        try w.setPOSTable(
            names: Self.posNames,
            connection: Self.connection,
            prefixPenalty: Self.prefixPenalty,
            suffixPenalty: Self.suffixPenalty
        )
        return w
    }

    private func writeSample() throws -> DicReader {
        let w = try makeWriter()
        for (r, s, c, l, rr) in Self.words {
            try w.add(reading: r, surface: s, cost: c, lid: l, rid: rr)
        }
        try w.write(to: path)
        return try DicReader(path: path, verifyContentHash: true)
    }

    func testCountsAndTokens() throws {
        let dic = try writeSample()
        XCTAssertEqual(dic.readingCount, 3)  // あおい / とうきょう / はし
        XCTAssertEqual(dic.tokenCount, 5)
        XCTAssertEqual(dic.posCount, 3)

        var found: [String: [DicToken]] = [:]
        for id in 0..<dic.readingCount {
            found[dic.reading(id)] = dic.tokens(readingID: id)
        }
        XCTAssertEqual(found["あおい"]?.map(\.surface), ["青い", "葵"])
        XCTAssertEqual(found["とうきょう"]?.map(\.surface), ["東京"])
        XCTAssertEqual(found["はし"]?.map(\.surface), ["橋", "箸"])
        XCTAssertEqual(found["あおい"]?.first?.cost, 5000)
        XCTAssertEqual(found["あおい"]?.first?.lid, 1)
        XCTAssertEqual(found["あおい"]?.first?.rid, 1)
    }

    /// Tokens for a reading must come back **cheapest first** — the lattice
    /// assumes it, and so does the tuning UI's ordering.
    func testTokensAreSortedByCostAscending() throws {
        let w = try makeWriter()
        try w.add(reading: "てすと", surface: "高い", cost: 9000, lid: 1, rid: 1)
        try w.add(reading: "てすと", surface: "安い", cost: 1000, lid: 1, rid: 1)
        try w.add(reading: "てすと", surface: "並", cost: 5000, lid: 1, rid: 1)
        try w.write(to: path)
        let dic = try DicReader(path: path)
        XCTAssertEqual(dic.tokens(readingID: 0).map(\.surface), ["安い", "並", "高い"])
    }

    /// Tokens tied at the same cost break on UTF-8 order of the surface, which
    /// puts hiragana ahead of katakana. Not cosmetic: Mozc's costs are integers,
    /// so exact ties are common and concentrated among the most frequent words,
    /// and whichever sorts first wins every path the costs cannot separate.
    func testCostTiesBreakOnSurfaceOrder() throws {
        let w = try makeWriter()
        try w.add(reading: "を", surface: "ヲ", cost: 3000, lid: 2, rid: 2)
        try w.add(reading: "を", surface: "を", cost: 3000, lid: 2, rid: 2)
        try w.write(to: path)
        let dic = try DicReader(path: path)
        XCTAssertEqual(dic.tokens(readingID: 0).map(\.surface), ["を", "ヲ"])
    }

    /// One spelling under two POS ids is two tokens, not one. Collapsing them
    /// would erase the connection cost that tells them apart — the single most
    /// important thing this format carries that the predecessor's did not.
    func testSameSurfaceUnderDifferentPOSStaysTwoTokens() throws {
        let w = try makeWriter()
        try w.add(reading: "ああると", surface: "アアルト", cost: 7129, lid: 1, rid: 1)
        try w.add(reading: "ああると", surface: "アアルト", cost: 6390, lid: 2, rid: 2)
        try w.write(to: path)
        let dic = try DicReader(path: path)

        let tokens = dic.tokens(readingID: 0)
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens.map(\.cost), [6390, 7129])
        XCTAssertEqual(tokens.map(\.lid), [2, 1])
        XCTAssertEqual(dic.tokens(reading: "ああると", surface: "アアルト").count, 2)
    }

    func testConnectionMatrixRoundTrips() throws {
        let dic = try writeSample()
        for rid in 0..<Self.posCount {
            for lid in 0..<Self.posCount {
                XCTAssertEqual(
                    dic.transitionCost(rid, lid),
                    Int32(Self.connection[rid * Self.posCount + lid]),
                    "trans(\(rid), \(lid))"
                )
            }
        }
    }

    /// Out-of-range ids must not trap. A user-added word can carry a POS id from
    /// a dictionary that has since been rebuilt, and crashing inside an input
    /// method takes the desktop's text entry with it.
    func testTransitionCostOutOfRangeIsNeutral() throws {
        let dic = try writeSample()
        XCTAssertEqual(dic.transitionCost(9999, 0), 0)
        XCTAssertEqual(dic.transitionCost(0, -1), 0)
    }

    func testBoundaryPenaltiesAndPOSNames() throws {
        let dic = try writeSample()
        XCTAssertEqual(dic.prefixPenalty(2), 3000)
        XCTAssertEqual(dic.prefixPenalty(1), 0)
        XCTAssertEqual(dic.suffixPenalty(1), 500)
        XCTAssertEqual(dic.suffixPenalty(2), 0)

        XCTAssertEqual(dic.posName(0), "BOS/EOS,*,*")
        XCTAssertEqual(dic.posName(2), "助詞,格助詞,*")
        XCTAssertEqual(dic.posName(99), "?")
    }

    func testCommonPrefixSearch() throws {
        let w = try makeWriter()
        for (r, s) in [("は", "歯"), ("はし", "橋"), ("はしる", "走る"), ("はな", "花")] {
            try w.add(reading: r, surface: s, cost: 5000, lid: 1, rid: 1)
        }
        try w.write(to: path)
        let dic = try DicReader(path: path)

        // "はしる" starts with は, はし and はしる — all three, shortest first.
        var hits: [(Int, String)] = []
        let codes = dic.encode("はしる")
        dic.commonPrefixSearch(codes: codes, from: 0) { length, id in
            hits.append((length, dic.reading(id)))
        }
        XCTAssertEqual(hits.map(\.0), [1, 2, 3])
        XCTAssertEqual(hits.map(\.1), ["は", "はし", "はしる"])

        // From offset 1 of "はしる" the remaining text is "しる", which is absent.
        var fromOffset: [Int] = []
        dic.commonPrefixSearch(codes: codes, from: 1) { length, _ in fromOffset.append(length) }
        XCTAssertEqual(fromOffset, [])
    }

    func testCommonPrefixSearchRespectsMaxLength() throws {
        let w = try makeWriter()
        try w.add(reading: "は", surface: "歯", cost: 5000, lid: 1, rid: 1)
        try w.add(reading: "はし", surface: "橋", cost: 5000, lid: 1, rid: 1)
        try w.write(to: path)
        let dic = try DicReader(path: path)

        var lengths: [Int] = []
        dic.commonPrefixSearch(codes: dic.encode("はし"), from: 0, maxLength: 1) { l, _ in
            lengths.append(l)
        }
        XCTAssertEqual(lengths, [1])
    }

    /// A character the dictionary has never seen must not match anything, and
    /// must not derail the search either.
    func testUnknownCharacterEncodesToZero() throws {
        let dic = try writeSample()
        XCTAssertEqual(dic.encode("漢"), [0])

        var hits = 0
        dic.commonPrefixSearch(codes: dic.encode("漢字"), from: 0) { _, _ in hits += 1 }
        XCTAssertEqual(hits, 0)
    }

    func testReadingIDLookup() throws {
        let dic = try writeSample()
        XCTAssertNotNil(dic.readingID(of: "はし"))
        XCTAssertNil(dic.readingID(of: "はしし"))
        XCTAssertNil(dic.readingID(of: ""))
    }

    /// Readings past the lattice's reach are dead weight and get dropped.
    func testOverlongReadingsAreDropped() throws {
        let w = try makeWriter()
        let long = String(repeating: "あ", count: DicFormat.maxReadingLength + 1)
        try w.add(reading: long, surface: "長", cost: 5000, lid: 1, rid: 1)
        try w.add(reading: "あ", surface: "亜", cost: 5000, lid: 1, rid: 1)
        let stats = try w.write(to: path)
        XCTAssertEqual(stats.droppedLongReadings, 1)
        XCTAssertEqual(stats.readingCount, 1)
    }

    /// Byte-identical output for identical input: dictionary changes stay
    /// reviewable as a hash diff.
    func testOutputIsDeterministic() throws {
        _ = try writeSample()
        let first = try Data(contentsOf: URL(fileURLWithPath: path))

        _ = try writeSample()
        let second = try Data(contentsOf: URL(fileURLWithPath: path))

        XCTAssertEqual(first, second)
    }

    func testRejectsGarbage() throws {
        try Data(repeating: 0, count: 4096).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try DicReader(path: path))
    }

    func testRejectsMismatchedConnectionMatrix() throws {
        let w = DicWriter()
        XCTAssertThrowsError(
            try w.setPOSTable(
                names: Self.posNames,
                connection: [0, 1, 2],  // needs 9
                prefixPenalty: Self.prefixPenalty,
                suffixPenalty: Self.suffixPenalty
            )
        )
    }
}
