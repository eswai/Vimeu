import XCTest
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
}
