import Foundation
import XCTest
@testable import VimeuInput

final class ReconversionSettingsTests: XCTestCase {
    private func enabled(_ values: [String: Any]) -> Bool {
        let defaults = UserDefaults(suiteName: "vimeu-reconversion-test-\(UUID().uuidString)")!
        defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        return ReconversionSettings.backspaceEnabled(in: defaults)
    }

    func testUnsetPreferenceEnablesReconversion() {
        XCTAssertTrue(enabled([:]))
    }

    func testStoredPreferenceIsRespected() {
        XCTAssertFalse(enabled([ReconversionSettings.backspaceKey: false]))
        XCTAssertTrue(enabled([ReconversionSettings.backspaceKey: true]))
    }
}
