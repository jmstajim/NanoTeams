import XCTest
@testable import NanoTeams

/// Pure-logic tests for the role editor's "this role will get
/// `conclude_meeting` auto-injected" predicate. The predicate must mirror
/// `LLMExecutionService+ToolResolution`'s step 6 rule:
///   - Auto mode (no designated coordinator): any role with `request_team_meeting`.
///   - Coordinator mode: only the designated coordinator.
/// Plus a fix from review I1: read the LIVE tool selection from
/// `RoleEditorState` (the user may have toggled `request_team_meeting`
/// mid-session), not the stale `role.toolIDs` snapshot.
@MainActor
final class RoleEditorConcludeMeetingPredicateTests: XCTestCase {

    // MARK: - Coordinator mode

    func testWillAutoInject_coordinatorMode_coordinatorRoleWithRequestTool_true() {
        let result = RoleEditorConcludeMeetingPredicate.evaluate(
            roleID: "coord",
            liveSelectedTools: [ToolNames.requestTeamMeeting],
            designatedCoordinatorID: "coord"
        )
        XCTAssertTrue(result, "Designated coordinator with request_team_meeting must get the badge")
    }

    func testWillAutoInject_coordinatorMode_nonCoordinatorRoleWithRequestTool_false() {
        let result = RoleEditorConcludeMeetingPredicate.evaluate(
            roleID: "other",
            liveSelectedTools: [ToolNames.requestTeamMeeting],
            designatedCoordinatorID: "coord"
        )
        XCTAssertFalse(result, "Non-coordinator role must NOT get the badge in coordinator mode")
    }

    // MARK: - Auto mode

    func testWillAutoInject_autoMode_anyRoleWithRequestTool_true() {
        let result = RoleEditorConcludeMeetingPredicate.evaluate(
            roleID: "any",
            liveSelectedTools: [ToolNames.requestTeamMeeting],
            designatedCoordinatorID: nil
        )
        XCTAssertTrue(result, "Auto mode: any role with request_team_meeting must get the badge")
    }

    func testWillAutoInject_autoMode_roleWithoutRequestTool_false() {
        let result = RoleEditorConcludeMeetingPredicate.evaluate(
            roleID: "any",
            liveSelectedTools: [ToolNames.readFile],
            designatedCoordinatorID: nil
        )
        XCTAssertFalse(result, "Role without request_team_meeting must NOT get conclude_meeting")
    }

    // MARK: - Orphan-aware (round-2 review C2.1)

    // Regression pin for C2.1: an orphan designated coordinator ID must be
    // pre-normalized by the call site before reaching the predicate. The
    // predicate trusts its `designatedCoordinatorID` to already be
    // self-healed (nil for Auto / orphan, or a valid role id). The caller
    // (`willAutoInjectConcludeMeeting`) is responsible for that
    // normalization via `DesignatedCoordinatorResolver`.
    //
    // Direct-input shape pin: passing `nil` exercises the Auto-mode branch
    // exactly the way an orphan would after normalization — every role with
    // `request_team_meeting` gets the badge.
    func testWillAutoInject_designatedNilFromOrphanNormalization_treatsAsAutoMode() {
        let result = RoleEditorConcludeMeetingPredicate.evaluate(
            roleID: "live",
            liveSelectedTools: [ToolNames.requestTeamMeeting],
            designatedCoordinatorID: nil
        )
        XCTAssertTrue(result,
                      "Post-normalization nil (Auto OR orphan-collapsed) must trigger the badge")
    }

    // MARK: - Editor-context wiring (regression pin for review I1)

    // Real regression pin: the View's computed property MUST read
    // `editorState.selectedTools` (live edits), not `role.toolIDs` (snapshot
    // captured at sheet open). We exercise the wiring with conflicting
    // values for the two sources — if the wiring is wrong, the wrong source
    // wins and the test fails.

    /// Role's persisted `toolIDs` does NOT have `request_team_meeting`, but
    /// the user just toggled it ON in the Tools tab. The badge must light up.
    /// If wiring read `role.toolIDs` instead of `editorState.selectedTools`,
    /// this test would fail.
    func testFromEditorContext_liveSelectedToolsWins_addedInSession() {
        var editorState = RoleEditorState()
        editorState.selectedTools = [ToolNames.requestTeamMeeting]
        let roleSnapshot = TeamRoleDefinition(
            id: "r", name: "R", prompt: "",
            toolIDs: [],  // NO request_team_meeting in persisted snapshot
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T",
            roles: [roleSnapshot],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: nil),
            graphLayout: TeamGraphLayout()
        )
        let result = RoleEditorConcludeMeetingPredicate.fromEditorContext(
            mode: .edit(roleSnapshot), editorState: editorState, team: team
        )
        XCTAssertTrue(result,
                      "Wiring must take live selectedTools (which has request_team_meeting), not role.toolIDs (which doesn't)")
    }

    /// Inverse: role's persisted `toolIDs` HAS `request_team_meeting`, but the
    /// user just toggled it OFF. The badge must turn off.
    func testFromEditorContext_liveSelectedToolsWins_removedInSession() {
        var editorState = RoleEditorState()
        editorState.selectedTools = []  // user toggled off
        let roleSnapshot = TeamRoleDefinition(
            id: "r", name: "R", prompt: "",
            toolIDs: [ToolNames.requestTeamMeeting],  // YES in persisted snapshot
            usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T",
            roles: [roleSnapshot],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: nil),
            graphLayout: TeamGraphLayout()
        )
        let result = RoleEditorConcludeMeetingPredicate.fromEditorContext(
            mode: .edit(roleSnapshot), editorState: editorState, team: team
        )
        XCTAssertFalse(result,
                       "Wiring must take live selectedTools (empty), not role.toolIDs (has it)")
    }

    /// Wiring must orphan-normalize the designated coordinator before
    /// evaluating. Stored ID references a non-existent role; the badge
    /// should light up for any role with `request_team_meeting` (Auto-mode
    /// fallback after normalization). If wiring forwarded the raw orphan
    /// ID, no role would match coord-mode equality and the badge would
    /// stay off — the round-2 C2.1 asymmetry bug.
    func testFromEditorContext_orphanCoordinatorNormalizesToAutoMode() {
        var editorState = RoleEditorState()
        editorState.selectedTools = [ToolNames.requestTeamMeeting]
        let role = TeamRoleDefinition(
            id: "live", name: "Live", prompt: "",
            toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies()
        )
        let team = Team(
            name: "T",
            roles: [role],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "ghost-of-deleted-role"),
            graphLayout: TeamGraphLayout()
        )
        let result = RoleEditorConcludeMeetingPredicate.fromEditorContext(
            mode: .edit(role), editorState: editorState, team: team
        )
        XCTAssertTrue(result,
                      "Orphan designated coordinator must normalize to Auto, badging any request_team_meeting role")
    }

    /// Supervisor guard: even if a Supervisor role has `request_team_meeting`
    /// in its live tool selection (which shouldn't happen but isn't
    /// structurally prevented), the badge MUST NOT light up — Supervisor is
    /// the user, not an LLM, and never receives auto-injected tools.
    /// Regression pin for round-3 review CR.2 (the predicate's doc claimed
    /// Supervisor returns false but the implementation only had a create-mode
    /// guard, leaving the Supervisor case as a behavioral coincidence).
    func testFromEditorContext_supervisorRole_returnsFalseEvenWithRequestTool() {
        var editorState = RoleEditorState()
        editorState.selectedTools = [ToolNames.requestTeamMeeting]
        let supervisorRole = TeamRoleDefinition(
            id: "supervisor",
            name: "Supervisor",
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            systemRoleID: "supervisor"
        )
        let team = Team(
            name: "T",
            roles: [supervisorRole],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: nil),
            graphLayout: TeamGraphLayout()
        )
        let result = RoleEditorConcludeMeetingPredicate.fromEditorContext(
            mode: .edit(supervisorRole), editorState: editorState, team: team
        )
        XCTAssertFalse(result,
                       "Supervisor must NOT receive auto-injected conclude_meeting badge under any condition")
    }

    /// Create-mode (no role under edit) → predicate inactive.
    func testFromEditorContext_createMode_returnsFalse() {
        var editorState = RoleEditorState()
        editorState.selectedTools = [ToolNames.requestTeamMeeting]
        let team = Team(
            name: "T", roles: [], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: nil),
            graphLayout: TeamGraphLayout()
        )
        let result = RoleEditorConcludeMeetingPredicate.fromEditorContext(
            mode: .create, editorState: editorState, team: team
        )
        XCTAssertFalse(result)
    }
}
