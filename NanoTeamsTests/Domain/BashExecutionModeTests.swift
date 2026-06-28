import XCTest

@testable import NanoTeams

/// `BashExecutionMode` taxonomy after the Manual / Semi-automatic split. Pins the
/// raw-value contract (the legacy `"manual"` storage value maps to the renamed
/// `.semiAutomatic`, NOT the new always-confirm `.manual`), the case set/order
/// behind the Settings picker, the display strings, and Codable round-trips.
final class BashExecutionModeTests: XCTestCase {

    func testRawValues() {
        // Storage contract — these strings are persisted in UserDefaults / teams JSON.
        XCTAssertEqual(BashExecutionMode.off.rawValue, "off")
        XCTAssertEqual(BashExecutionMode.manual.rawValue, "alwaysConfirm")
        XCTAssertEqual(BashExecutionMode.semiAutomatic.rawValue, "manual")
        XCTAssertEqual(BashExecutionMode.auto.rawValue, "auto")
    }

    func testLegacyManualRawValue_mapsToSemiAutomatic() {
        // Pre-rename configs stored "manual" for today's behavior → semi-automatic.
        XCTAssertEqual(BashExecutionMode(rawValue: "manual"), .semiAutomatic)
        // The new always-confirm mode is a DISTINCT raw value so it can't be reached
        // accidentally by a legacy "manual" value.
        XCTAssertEqual(BashExecutionMode(rawValue: "alwaysConfirm"), .manual)
    }

    func testUnknownRawValue_isNil() {
        XCTAssertNil(BashExecutionMode(rawValue: "semiAutomatic"),
            "the case name is NOT the raw value — semi-automatic persists as legacy \"manual\"")
        XCTAssertNil(BashExecutionMode(rawValue: "bogus"))
        XCTAssertNil(BashExecutionMode(rawValue: ""))
    }

    func testAllCases_orderAndMembership() {
        // CaseIterable order drives the Settings segmented picker — strictest →
        // loosest: Off, Manual (confirm all), Semi-automatic (confirm unknown), Auto.
        XCTAssertEqual(BashExecutionMode.allCases, [.off, .manual, .semiAutomatic, .auto])
    }

    func testRawValueRoundTrips() {
        for mode in BashExecutionMode.allCases {
            XCTAssertEqual(BashExecutionMode(rawValue: mode.rawValue), mode)
        }
    }

    func testDisplayNames() {
        XCTAssertEqual(BashExecutionMode.off.displayName, "Off")
        XCTAssertEqual(BashExecutionMode.manual.displayName, "Manual")
        XCTAssertEqual(BashExecutionMode.semiAutomatic.displayName, "Semi-automatic")
        XCTAssertEqual(BashExecutionMode.auto.displayName, "Auto")
    }

    func testSettingDescriptions_areDistinctAndOnMessage() {
        for mode in BashExecutionMode.allCases {
            XCTAssertFalse(mode.settingDescription.isEmpty, "\(mode) needs a settings description")
        }
        // Manual emphasizes "every"; semi-automatic mentions the read-only carve-out.
        XCTAssertTrue(BashExecutionMode.manual.settingDescription.lowercased().contains("every"))
        XCTAssertTrue(BashExecutionMode.semiAutomatic.settingDescription.lowercased().contains("read-only"))
        XCTAssertNotEqual(
            BashExecutionMode.manual.settingDescription,
            BashExecutionMode.semiAutomatic.settingDescription)
    }

    func testCodableRoundTripsForEveryCase() throws {
        for mode in BashExecutionMode.allCases {
            let data = try JSONEncoder().encode([mode])
            XCTAssertEqual(try JSONDecoder().decode([BashExecutionMode].self, from: data), [mode])
        }
    }
}
