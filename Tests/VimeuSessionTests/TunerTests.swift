import Foundation
import Testing
@testable import VimeuSession

private let dictionaryPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("dict/vimeu.dic").path

private func freshTuner() -> (Tuner, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vimeu-tuner-\(UUID().uuidString)", isDirectory: true)
    return (Tuner(engine: Engine(dictionaryPath: dictionaryPath, userDirectory: dir.path)), dir)
}

struct TunerParsingTests {
    @Test func romajiReadingBecomesKana() {
        #expect(Tuner.normalizeReading("kawawomuku") == "かわをむく")
        #expect(Tuner.normalizeReading("  かわ ") == "かわ")
        #expect(Tuner.normalizeReading("kyou,") == "きょう、")
        #expect(Tuner.normalizeReading("n") == "ん")
    }

    @Test func commandsParse() throws {
        #expect(try Tuner.parse(#"{"op":"boostWord","reading":"かわ","surface":"皮","steps":-2}"#)
                == .boostWord(reading: "かわ", surface: "皮", steps: -2))
        #expect(try Tuner.parse(#"{"op":"addCollocation","left":"皮","right":"剥く","polarity":"negative"}"#)
                == .addCollocation(left: "皮", right: "剥く", negative: true))
        #expect(throws: Tuner.CommandError.unknownOperation("nope")) { try Tuner.parse(#"{"op":"nope"}"#) }
        #expect(throws: Tuner.CommandError.missing("surface")) { try Tuner.parse(#"{"op":"deleteWord","reading":"か"}"#) }
        #expect(throws: (any Error).self) { try Tuner.parse("not json") }
    }

    @Test func withoutDictionaryStateSaysWhy() {
        let t = Tuner(engine: Engine(dictionaryPath: nil, userDirectory: NSTemporaryDirectory() + "vimeu-tuner-none"))
        #expect(t.state.ready == false)
        #expect(t.state.message?.contains("辞書") == true)
        #expect(throws: (any Error).self) { try t.run(.boostWord(reading: "か", surface: "蚊", steps: 1)) }
    }
}

@Suite(.enabled(if: FileManager.default.fileExists(atPath: dictionaryPath), "dict/vimeu.dic not built"))
struct TunerShippedDictionaryTests {
    @Test func stateListsCandidatesWithExactBreakdown() throws {
        let (t, dir) = freshTuner()
        defer { try? FileManager.default.removeItem(at: dir) }
        try t.run(json: #"{"op":"setReading","reading":"kawawomuku"}"#)
        let s = t.state
        #expect(s.reading == "かわをむく")
        #expect(s.candidates.count > 9)
        #expect(s.candidates.count <= Tuner.candidateRows)
        #expect(s.candidateCount >= s.candidates.count)
        for c in s.candidates { #expect(c.cost == c.wordCost + c.connectionCost + c.collocationCost) }
        #expect(s.words.contains { $0.surface == "皮" })
        #expect(s.connections.first?.left == "BOS")
        #expect(s.connections.last?.right == "EOS")
        #expect(s.collocationChoices.contains("皮"))
        // Round-trips through JSON for the Qt side.
        let decoded = try JSONDecoder().decode(Tuner.State.self, from: Data(t.stateJSON.utf8))
        #expect(decoded == s)
    }

    @Test func boostingAWordIsSavedAndMovesIt() throws {
        let (t, dir) = freshTuner()
        defer { try? FileManager.default.removeItem(at: dir) }
        try t.run(.setReading("かわ"))
        let before = try #require(t.state.words.first { $0.surface == "皮" })
        try t.run(.boostWord(reading: before.reading, surface: "皮", steps: 1))
        let after = try #require(t.state.words.first { $0.surface == "皮" })
        #expect(after.cost == before.cost - 500)
        #expect(after.userOverride)
        let tsv = try String(contentsOf: dir.appendingPathComponent("user_word.tsv"), encoding: .utf8)
        #expect(tsv.contains("かわ\t皮\t\(after.cost)\t0"))
        try t.run(.resetWord(reading: before.reading, surface: "皮"))
        #expect(t.state.words.first { $0.surface == "皮" }?.cost == before.cost)
    }

    @Test func selectionFollowsTheTextAcrossEdits() throws {
        let (t, dir) = freshTuner()
        defer { try? FileManager.default.removeItem(at: dir) }
        try t.run(.setReading("かわ"))
        let second = t.state.candidates[1].text
        try t.run(.selectCandidate(1))
        try t.run(.addWord(reading: "かわ", surface: "ｶﾜﾃｽﾄ", cost: 0))
        #expect(t.state.candidates.first?.text == "ｶﾜﾃｽﾄ")
        #expect(t.state.candidates[t.state.selectedCandidate].text == second)
    }

    @Test func pairsNeedTwoDifferentWordsAndShowActive() throws {
        let (t, dir) = freshTuner()
        defer { try? FileManager.default.removeItem(at: dir) }
        try t.run(.setReading("かわをむく"))
        #expect(throws: (any Error).self) { try t.run(.addCollocation(left: "皮", right: "皮", negative: false)) }
        try t.run(.addCollocation(left: "皮", right: "剥く", negative: false))
        #expect(t.state.collocations == [.init(left: "皮", right: "剥く", negative: false, active: true)])
        #expect(t.state.candidates.first?.text == "皮を剥く")
        try t.run(.removeCollocation(left: "皮", right: "剥く"))
        #expect(t.state.collocations.isEmpty)
    }

    @Test func reloadPicksUpExternalEdits() throws {
        let (t, dir) = freshTuner()
        defer { try? FileManager.default.removeItem(at: dir) }
        try t.run(.setReading("かわ"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "reading\tsurface\tcost\tdisabled\tupdated_at\nかわ\t皮\t0\t0\t0\n"
            .write(to: dir.appendingPathComponent("user_word.tsv"), atomically: true, encoding: .utf8)
        try t.run(.reload)
        #expect(t.state.candidates.first?.text == "皮")
    }
}
