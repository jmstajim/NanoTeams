import XCTest
@testable import NanoTeams

/// Pure-logic tests for the `MeetingCoordinatorPickerLogic` namespace that
/// backs the Collaboration section's coordinator Picker. Two responsibilities:
///   1. Normalize a stored coordinator ID against the live role list (orphan
///      tolerance — review finding C2).
///   2. Sanitize the picker's `set` action so an empty/orphan inbound value
///      becomes `nil` on the model.
@MainActor
final class TeamSettingsCollaborationSectionLogicTests: XCTestCase {

    // MARK: - normalizedSelection (get)

    // Auto mode: stored nil stays nil → picker shows "Auto".
    func testNormalizedSelection_storedNil_returnsNil() {
        let result = MeetingCoordinatorPickerLogic.normalizedSelection(
            stored: nil, availableIDs: ["pm", "swe"]
        )
        XCTAssertNil(result)
    }

    // Valid stored ID is preserved → picker selects the matching role.
    func testNormalizedSelection_storedMatchesAvailable_returnsStored() {
        let result = MeetingCoordinatorPickerLogic.normalizedSelection(
            stored: "pm", availableIDs: ["pm", "swe"]
        )
        XCTAssertEqual(result, "pm")
    }

    // Orphan stored ID (role was removed, or legacy data) collapses to nil so
    // the picker shows "Auto" — matches the runtime's silent self-heal at
    // `LLMExecutionService.resolveCoordinatorRole`.
    func testNormalizedSelection_storedOrphan_returnsNil() {
        let result = MeetingCoordinatorPickerLogic.normalizedSelection(
            stored: "ghost-of-deleted-role", availableIDs: ["pm", "swe"]
        )
        XCTAssertNil(result, "Orphan stored ID must visually collapse to Auto")
    }

    // Defensive: empty stored string is treated like nil. Not currently
    // reachable from the picker's set path (which writes `nil`/role-id only),
    // but guards against stored-data corruption / hand-edited teams.json.
    func testNormalizedSelection_storedEmptyString_returnsNil() {
        let result = MeetingCoordinatorPickerLogic.normalizedSelection(
            stored: "", availableIDs: ["pm", "swe"]
        )
        XCTAssertNil(result)
    }

    // MARK: - sanitizedSelection (set)

    // Selecting "Auto" (nil) on the picker writes nil to the model.
    func testSanitizedSelection_nilStaysNil() {
        XCTAssertNil(MeetingCoordinatorPickerLogic.sanitizedSelection(nil))
    }

    // Selecting a role writes the role id to the model.
    func testSanitizedSelection_validIDPassesThrough() {
        XCTAssertEqual(
            MeetingCoordinatorPickerLogic.sanitizedSelection("pm"),
            "pm"
        )
    }

    // Defensive: empty-string inbound (shouldn't happen in current binding,
    // but the picker doesn't statically prevent it) collapses to nil so the
    // model never persists `""` as a coordinator id.
    func testSanitizedSelection_emptyStringCollapsesToNil() {
        XCTAssertNil(MeetingCoordinatorPickerLogic.sanitizedSelection(""))
    }
}
