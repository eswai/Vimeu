import XCTest
import VimeuDict
import VimeuEngine
import VimeuUserDict
@testable import VimeuUI

final class CandidateViewModelTests: XCTestCase {
    @MainActor
    func testVisibleIndicesFollowSelectionInPagesOfTen() {
        let model = CandidateViewModel()
        model.update(candidates: (1...25).map(String.init), selected: 0)

        XCTAssertEqual(model.visibleIndices, 0..<10)

        model.update(candidates: model.candidates, selected: 9)
        XCTAssertEqual(model.visibleIndices, 0..<10)

        model.update(candidates: model.candidates, selected: 10)
        XCTAssertEqual(model.visibleIndices, 10..<20)

        model.update(candidates: model.candidates, selected: 24)
        XCTAssertEqual(model.visibleIndices, 20..<25)
    }

    @MainActor
    func testAdjustmentWordsUseCandidatesBeyondTheFormerNineItemLimit() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dictionaryPath = packageRoot.appendingPathComponent("dict/vimeu.dic").path
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: dictionaryPath),
            "dict/vimeu.dic not built — run `make dict`"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimeu-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = DictionaryEditor(
            system: try DicReader(path: dictionaryPath),
            store: UserDictionaryStore(directory: directory)
        )
        let expectedCandidates = Converter(dictionary: editor.dictionary)
            .convert(reading: "はし", limit: NBest.maxExpansions)
        try XCTSkipUnless(expectedCandidates.count > 9, "test reading has too few candidates")

        let model = AdjustmentViewModel()
        model.editor = editor
        model.reading = "はし"
        model.reconvert()

        XCTAssertEqual(model.candidates.map(\.text), expectedCandidates.map(\.text))
        XCTAssertEqual(
            model.words,
            editor.wordKnobs(for: expectedCandidates, reading: "はし")
        )
    }
}
