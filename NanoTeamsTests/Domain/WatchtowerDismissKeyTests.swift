import XCTest
@testable import NanoTeams

/// `stepID == roleID`, so a dismissal keyed on the step alone is shared by every task
/// running the same team. These pin the task scope that fixes it, and the round-trip
/// the garbage collector needs in order to tell whose key it is looking at.
final class WatchtowerDismissKeyTests: XCTestCase {

    func testRoundTrip() {
        let key = WatchtowerDismissKey(taskID: 42, typeID: "engineer::ABC")
        let parsed = WatchtowerDismissKey(storageKey: key.storageKey)
        XCTAssertEqual(parsed, key)
    }

    func testTypeIDMayContainTheSeparator() {
        let key = WatchtowerDismissKey(taskID: 3, typeID: "bash::9::step::123.45")
        XCTAssertEqual(WatchtowerDismissKey(storageKey: key.storageKey), key)
    }

    /// The bug this type exists for: two tasks on the same team share `stepID`.
    func testSameTeamDifferentTasks_produceDifferentKeys() {
        let a = WatchtowerDismissKey(taskID: 5, typeID: "coding_assistant::Q")
        let b = WatchtowerDismissKey(taskID: 9, typeID: "coding_assistant::Q")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.storageKey, b.storageKey)
    }

    func testLegacyBareStepIDDoesNotParse() {
        XCTAssertNil(WatchtowerDismissKey(storageKey: "engineer"))
        XCTAssertNil(WatchtowerDismissKey(storageKey: "engineer::What next?"))
    }

    func testMalformedKeysDoNotParse() {
        XCTAssertNil(WatchtowerDismissKey(storageKey: ""))
        XCTAssertNil(WatchtowerDismissKey(storageKey: "t::typeID"), "no task id")
        XCTAssertNil(WatchtowerDismissKey(storageKey: "tabc::typeID"), "non-numeric task id")
        XCTAssertNil(WatchtowerDismissKey(storageKey: "t7::"), "empty type id")
        XCTAssertNil(WatchtowerDismissKey(storageKey: "7::typeID"), "missing t prefix")
    }

    func testNegativeAndZeroTaskIDsRoundTrip() {
        for taskID in [0, -1, Int.max] {
            let key = WatchtowerDismissKey(taskID: taskID, typeID: "x")
            XCTAssertEqual(WatchtowerDismissKey(storageKey: key.storageKey), key)
        }
    }
    // MARK: - Shared type-ID vocabulary (acceptance / failed)

    /// Both families used to spell their typeID as the bare stepID, so dismissing
    /// a failed banner also suppressed a later acceptance banner on the same step.
    func testAcceptanceAndFailed_sameStep_produceDistinctKeys() {
        XCTAssertNotEqual(
            WatchtowerDismissKey.acceptance(taskID: 1, stepID: "engineer"),
            WatchtowerDismissKey.failed(taskID: 1, stepID: "engineer"))
    }

    func testFamilyFactories_roundTripThroughStorage() {
        for key in [WatchtowerDismissKey.acceptance(taskID: 7, stepID: "engineer"),
                    WatchtowerDismissKey.failed(taskID: 7, stepID: "engineer")] {
            XCTAssertEqual(WatchtowerDismissKey(storageKey: key.storageKey), key)
        }
    }

    /// A pre-prefix key (bare stepID) must not equal the prefixed spelling — the
    /// one-way cost of the rename is a banner returning once, never a banner
    /// staying suppressed under a key written by the old spelling.
    func testBareStepIDKey_isNotTheFamilyKey() {
        XCTAssertNotEqual(
            WatchtowerDismissKey(taskID: 1, typeID: "engineer"),
            WatchtowerDismissKey.failed(taskID: 1, stepID: "engineer"))
    }

}
