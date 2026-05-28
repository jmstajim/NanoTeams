import XCTest
@testable import NanoTeams

/// Pure-logic tests for the orphan-aware designated-coordinator ID normalizer.
/// Single source of truth shared by:
///   - `LLMExecutionService+ToolResolution.swift` step 6 (`conclude_meeting` auto-inject gate)
///   - `RoleEditorSheet.willAutoInjectConcludeMeeting` (UI badge predicate)
///   - `TeamSettingsCollaborationSection` picker get-binding (orphan-tolerant view)
@MainActor
final class DesignatedCoordinatorResolverTests: XCTestCase {

    // Auto mode: nil stored stays nil.
    func testNormalize_storedNil_returnsNil() {
        XCTAssertNil(DesignatedCoordinatorResolver.normalize(
            storedID: nil, availableIDs: ["pm", "swe"]
        ))
    }

    // Valid stored ID is preserved.
    func testNormalize_storedMatchesAvailable_returnsStored() {
        XCTAssertEqual(
            DesignatedCoordinatorResolver.normalize(
                storedID: "pm", availableIDs: ["pm", "swe"]
            ),
            "pm"
        )
    }

    // Orphan stored ID (role removed) collapses to nil — same self-heal as
    // `LLMExecutionService.resolveCoordinatorRole`. Critical: every reader of
    // `team.settings.meetingCoordinatorRoleID` must agree on this.
    func testNormalize_storedOrphan_returnsNil() {
        XCTAssertNil(DesignatedCoordinatorResolver.normalize(
            storedID: "ghost-of-deleted-role", availableIDs: ["pm", "swe"]
        ))
    }

    // Defensive: empty stored string is treated like nil.
    func testNormalize_storedEmptyString_returnsNil() {
        XCTAssertNil(DesignatedCoordinatorResolver.normalize(
            storedID: "", availableIDs: ["pm", "swe"]
        ))
    }

    // Defensive: empty availableIDs (team with no roles?) → nil for any input.
    func testNormalize_availableEmpty_returnsNil() {
        XCTAssertNil(DesignatedCoordinatorResolver.normalize(
            storedID: "pm", availableIDs: []
        ))
    }
}
