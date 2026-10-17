import Foundation
import XCTest
@testable import VimeuInput

final class PartialCommitSettingsTests: XCTestCase {
    private func settings(_ values: [String: Any]) -> PartialCommitSettings {
        let defaults = UserDefaults(suiteName: "vimeu-partial-commit-test-\(UUID().uuidString)")!
        // Exercise the persisted-key contract without changing the user's
        // preferences or depending on preferences-daemon access in the sandbox.
        defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        return PartialCommitSettings(defaults: defaults)
    }

    func testUnsetPreferencesEnableConvertedPrefixAtDefaultLength() {
        let value = settings([:])
        XCTAssertTrue(value.enabled)
        XCTAssertEqual(value.length, 40)
        XCTAssertEqual(value.retainedLength, 20)
        XCTAssertEqual(value.mode, .converted)
        XCTAssertTrue(value.requiresStableCandidate)
        XCTAssertEqual(value.stableLength, 5)
    }

    func testStoredPreferencesAreReadIndependentlyOfLiveConversion() {
        let value = settings([
            PartialCommitSettings.enabledKey: true,
            PartialCommitSettings.lengthKey: 15,
            PartialCommitSettings.modeKey: "reading",
        ])
        XCTAssertEqual(value, PartialCommitSettings(length: 15, mode: .reading))
        XCTAssertFalse(value.converts(liveConversion: false))
        XCTAssertTrue(value.converts(liveConversion: true))
        XCTAssertEqual(value.retainedLength, 7)
    }

    func testStoredDisabledAndInvalidValuesAreHandled() {
        let value = settings([
            PartialCommitSettings.enabledKey: false,
            PartialCommitSettings.lengthKey: -1,
            PartialCommitSettings.modeKey: "unknown",
        ])
        XCTAssertFalse(value.enabled)
        XCTAssertEqual(value.length, 2)
        XCTAssertEqual(value.mode, .converted)
        XCTAssertFalse(value.isNeeded(reading: String(repeating: "あ", count: 40)))
        XCTAssertEqual(settings([PartialCommitSettings.lengthKey: 1_001]).length, 1_000)
    }

    func testExplicitDisabledStabilityPreferenceIsPreserved() {
        XCTAssertFalse(settings([PartialCommitSettings.requiresStableCandidateKey: false]).requiresStableCandidate)
    }

    func testStabilityOptionIsStoredAndItsLengthIsClamped() {
        let value = settings([
            PartialCommitSettings.requiresStableCandidateKey: true,
            PartialCommitSettings.stableLengthKey: 8,
        ])
        XCTAssertTrue(value.observesStability)
        XCTAssertEqual(value.stableLength, 8)
        XCTAssertEqual(settings([PartialCommitSettings.stableLengthKey: 0]).stableLength, 1)
        XCTAssertEqual(settings([PartialCommitSettings.stableLengthKey: 1_001]).stableLength, 1_000)
        XCTAssertFalse(PartialCommitSettings(enabled: false, requiresStableCandidate: true).observesStability)
    }
}
