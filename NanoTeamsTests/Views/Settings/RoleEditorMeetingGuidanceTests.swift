import XCTest
@testable import NanoTeams

/// The Role editor's Meeting Guidance field: loaded from the definition, normalised ONCE
/// (`RoleEditorState.normalizedMeetingGuidance`) for the preview and both save paths, so a
/// blank draft persists as `nil` — "not authored", the meeting turn falls back to the step
/// prompt — and anything else persists verbatim.
final class RoleEditorMeetingGuidanceTests: XCTestCase {

    private static let supervisorID = "sup"

    private func worker(meetingGuidance: String?) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "worker", name: "Worker", prompt: "step", meetingGuidance: meetingGuidance,
            toolIDs: [ToolNames.readFile], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Brief"], producesArtifacts: ["Report"]))
    }

    private func team(with role: TeamRoleDefinition) -> Team {
        let supervisor = TeamRoleDefinition(
            id: Self.supervisorID, name: "Supervisor", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "supervisor")
        return Team(name: "T", roles: [supervisor, role], artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())
    }

    // MARK: - normalise

    func testNormalized_blankIsNil_otherwiseVerbatim() {
        XCTAssertNil(RoleEditorState.normalizedMeetingGuidance(""))
        XCTAssertNil(RoleEditorState.normalizedMeetingGuidance(" \n\t"))
        XCTAssertEqual(RoleEditorState.normalizedMeetingGuidance("  keep me  "), "  keep me  ",
                       "never the trimmed copy — the bytes the author wrote are the bytes the model reads")
    }

    // MARK: - load

    func testLoaded_seedsTheDraft_andNilLoadsAsEmpty() {
        XCTAssertEqual(RoleEditorState.loaded(from: worker(meetingGuidance: "m")).meetingGuidance, "m")
        XCTAssertEqual(RoleEditorState.loaded(from: worker(meetingGuidance: nil)).meetingGuidance, "")
    }

    // MARK: - preview and the two save paths agree

    func testProvisionalDefinition_appliesTheSameNormalisation() {
        let role = worker(meetingGuidance: "old")
        var state = RoleEditorState.loaded(from: role)
        state.meetingGuidance = "   "
        XCTAssertNil(state.provisionalDefinition(mode: .edit(role)).meetingGuidance)
        state.meetingGuidance = "new"
        XCTAssertEqual(state.provisionalDefinition(mode: .edit(role)).meetingGuidance, "new")
    }

    func testApplyEdit_persistsAuthored_andClearsBlank() {
        let role = worker(meetingGuidance: "old")
        var t = team(with: role)
        var state = RoleEditorState.loaded(from: role)
        state.meetingGuidance = "new"
        XCTAssertTrue(RoleEditorMutations.applyEdit(to: &t, editorState: state, existingRoleID: role.id))
        XCTAssertEqual(t.roles[1].meetingGuidance, "new")

        state.meetingGuidance = "\n"
        XCTAssertTrue(RoleEditorMutations.applyEdit(to: &t, editorState: state, existingRoleID: role.id))
        XCTAssertNil(t.roles[1].meetingGuidance, "clearing the field un-authors the body")
        XCTAssertEqual(t.roles[1].resolvedMeetingGuidance, SystemTemplates.meetingStance(derivedFrom: "step"),
                       "un-authored ⇒ the stance derived from the step prompt, never the step prompt itself")
    }

    func testApplyEdit_supervisor_neverKeepsABody() throws {
        let role = worker(meetingGuidance: nil)
        var t = team(with: role)
        let supervisor = try XCTUnwrap(t.roles.first { $0.isSupervisor })
        var state = RoleEditorState.loaded(from: supervisor)
        state.meetingGuidance = "the human does not speak in meetings through a prompt"
        XCTAssertTrue(RoleEditorMutations.applyEdit(to: &t, editorState: state, existingRoleID: supervisor.id))
        XCTAssertNil(t.roles[0].meetingGuidance)
    }

    func testApplyCreate_persistsTheNormalisedDraft() {
        var t = team(with: worker(meetingGuidance: nil))
        var state = RoleEditorState()
        state.roleName = "Newcomer"
        state.meetingGuidance = "  authored  "
        let id = RoleEditorMutations.applyCreate(to: &t, editorState: state, teamID: t.id)
        XCTAssertEqual(t.roles.first { $0.id == id }?.meetingGuidance, "  authored  ")

        var blank = RoleEditorState()
        blank.roleName = "Quiet"
        blank.meetingGuidance = " "
        let quiet = RoleEditorMutations.applyCreate(to: &t, editorState: blank, teamID: t.id)
        XCTAssertNil(t.roles.first { $0.id == quiet }?.meetingGuidance)
    }
}
