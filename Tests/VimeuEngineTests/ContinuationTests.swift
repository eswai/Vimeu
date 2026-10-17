import Foundation
import XCTest
import VimeuDict
import VimeuUserDict
@testable import VimeuEngine

final class ContinuationTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")
    private var dictionary: DicReader!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vimeu-continuation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dictionary = try TestDictionary.write(to: directory.appendingPathComponent("test.dic").path, words: [
            ("したい", "死体", 3000, 1, 1), ("したい", "したい", 3000, 3, 3),
            ("そら", "空", 1000, 1, 1),
        ], prefixPenalty: [0, 700, 800, 1000, 900], suffixPenalty: [0, 300, 200, 400, 500])
    }

    override func tearDownWithError() throws {
        dictionary = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testLeftContextChangesRankingAndKeepsCostIdentity() throws {
        let converter = Converter(dictionary: dictionary)
        XCTAssertEqual(converter.best(reading: "したい"), "死体")
        let candidates = converter.convert(reading: "したい", limit: 9, previousRightID: 2)
        XCTAssertEqual(candidates.first?.text, "したい")
        for candidate in candidates {
            XCTAssertEqual(candidate.cost, candidate.wordCost + candidate.connectionCost)
            XCTAssertEqual(candidate.connectionCost, candidate.boundaries.reduce(0) { $0 + $1.cost })
            XCTAssertEqual(candidate.boundaries.first?.rid, 2)
            XCTAssertEqual(candidate.boundaries.first?.cost, dictionary.transitionCost(2, candidate.segments[0].lid))
        }
        let verb = try XCTUnwrap(candidates.first { $0.text == "したい" })
        XCTAssertEqual(verb.wordCost, 3000 + 400) // Original cost + suffix, no new prefix penalty.
        XCTAssertEqual(verb.cost, 150 + 3000 + 400)
        // A new composition still starts at BOS; context is not cached in Converter.
        XCTAssertEqual(converter.best(reading: "したい"), "死体")
    }

    func testContinuationOmitsPrefixPenaltyForUnknownNodesToo() throws {
        let converter = Converter(dictionary: dictionary)
        let candidate = try XCTUnwrap(converter.convert(reading: "ぬ", limit: 1, previousRightID: 2).first)
        XCTAssertEqual(candidate.text, "ぬ")
        XCTAssertEqual(candidate.wordCost, Lattice.unknownCost + 500)
        XCTAssertEqual(candidate.connectionCost, dictionary.transitionCost(2, 4) + dictionary.transitionCost(4, 0))
        let bosContinuation = try XCTUnwrap(converter.convert(reading: "ぬ", limit: 1, previousRightID: 0).first)
        let newComposition = try XCTUnwrap(converter.convert(reading: "ぬ", limit: 1).first)
        XCTAssertEqual(newComposition.wordCost - bosContinuation.wordCost, 900)
    }

    func testContextualNBestMatchesIndependentExhaustiveCosts() {
        let reading = "したいそら"
        let lattice = Lattice.build(reading: Array(reading.unicodeScalars), codes: dictionary.encode(reading),
                                    dictionary: dictionary, isContinuation: true)
        var exhaustive: [String: Int32] = [:]
        func visit(position: Int, rid: Int, cost: Int32, text: String) {
            if position == lattice.length {
                let total = cost + dictionary.transitionCost(rid, 0)
                exhaustive[text] = min(exhaustive[text] ?? .max, total)
                return
            }
            for index in lattice.beginIndices[position] {
                let node = lattice.nodes[index]
                visit(position: node.end, rid: node.rid,
                      cost: cost + dictionary.transitionCost(rid, node.lid) + node.wcost,
                      text: text + node.surface)
            }
        }
        visit(position: 0, rid: 2, cost: 0, text: "")
        let candidates = Converter(dictionary: dictionary).convert(reading: reading, limit: 100, previousRightID: 2)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: candidates.map { ($0.text, $0.cost) }), exhaustive)
        XCTAssertEqual(candidates.map(\.cost), candidates.map(\.cost).sorted())
    }

    func testContinuationUsesUserEditedConnections() throws {
        let editor = DictionaryEditor(system: dictionary, store: UserDictionaryStore(directory: directory.appendingPathComponent("user")))
        editor.setConnectionCost(rid: 2, lid: 3, cost: 42)
        let first = try XCTUnwrap(Converter(dictionary: editor.dictionary)
            .convert(reading: "したい", limit: 1, previousRightID: 2).first)
        XCTAssertEqual(first.text, "したい")
        XCTAssertEqual(first.boundaries.first?.cost, 42)
        XCTAssertEqual(first.cost, first.wordCost + first.connectionCost)
    }
}
