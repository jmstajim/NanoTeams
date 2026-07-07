import XCTest

@testable import NanoTeams

/// Pins `BashRestrictionLevel`'s case list/order (declaration order = the
/// Settings picker order) and the metadata-completeness contract — every case,
/// including `.off` (whose guidance never reaches a judge), must carry non-empty
/// display strings. Mirrors `ComputerUsePolicyCodableTests.testMetadata_nonEmpty`.
final class BashRestrictionLevelTests: XCTestCase {

    func testAllCases_orderPinsThePicker() {
        // Off first, then ascending strictness (loosest → strictest), matching
        // ComputerUse's Off-first ordering: [Off | Permissive | Standard | Strict].
        XCTAssertEqual(BashRestrictionLevel.allCases, [.off, .permissive, .standard, .strict])
    }

    func testMetadata_nonEmpty() {
        for level in BashRestrictionLevel.allCases {
            XCTAssertFalse(level.displayName.isEmpty, "\(level) displayName must be non-empty")
            XCTAssertFalse(level.settingDescription.isEmpty, "\(level) settingDescription must be non-empty")
            XCTAssertFalse(level.judgeGuidance.isEmpty, "\(level) judgeGuidance must be non-empty")
        }
    }

    func testOff_rawValue_isStable() {
        // Raw-string Codable rides UserDefaults + BashPolicy JSON — pin the wire form.
        XCTAssertEqual(BashRestrictionLevel.off.rawValue, "off")
        XCTAssertEqual(BashRestrictionLevel(rawValue: "off"), .off)
    }
}
