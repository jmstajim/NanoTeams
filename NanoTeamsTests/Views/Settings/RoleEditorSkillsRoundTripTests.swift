import XCTest
@testable import NanoTeams

/// `TeamRoleDefinition.attachedSkillIDs` ⇄ `RoleEditorState.attachedSkillIDs`.
///
/// The property that matters is that the ORDER survives a full save → load →
/// save cycle unchanged. That order is the order of the `### Skill:` sections in
/// the role's system prompt, so a reshuffle on save is a full prefix re-prefill
/// (~4.3s at 13k tokens) for a user who changed nothing. The delegation whitelist
/// beside it legitimately round-trips through a `Set` — membership is all it
/// means — which is exactly the pattern this must NOT copy.
@MainActor
final class RoleEditorSkillsRoundTripTests: XCTestCase {

    private func makeTeam(with role: TeamRoleDefinition) -> Team {
        Team(name: "T", roles: [role], artifacts: [], settings: .default, graphLayout: .default)
    }

    private func makeRole(
        id: String = "r1",
        skills: [String] = [],
        isSupervisor: Bool = false
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: isSupervisor ? "Supervisor" : "Engineer",
            prompt: "p",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(),
            attachedSkillIDs: skills,
            isSystemRole: false,
            systemRoleID: isSupervisor ? "supervisor" : nil)
    }

    // MARK: - Load

    func testLoad_copiesTheOrderVerbatim() {
        // Reverse-alphabetical, so any accidental sort is visible.
        let role = makeRole(skills: ["z", "m", "a"])

        var state = RoleEditorState()
        state.load(from: role)

        XCTAssertEqual(state.attachedSkillIDs, ["z", "m", "a"])
    }

    func testLoad_noSkills_isEmpty() {
        var state = RoleEditorState()
        state.load(from: makeRole())

        XCTAssertTrue(state.attachedSkillIDs.isEmpty)
    }

    // MARK: - Save

    func testApplyEdit_persistsTheOrderVerbatim() throws {
        let role = makeRole(skills: ["z", "m", "a"])
        var team = makeTeam(with: role)
        var state = RoleEditorState()
        state.load(from: role)

        XCTAssertTrue(RoleEditorMutations.applyEdit(to: &team, editorState: state, existingRoleID: "r1"))

        XCTAssertEqual(try XCTUnwrap(team.roles.first).attachedSkillIDs, ["z", "m", "a"])
    }

    /// The regression this whole ordering discipline exists to prevent: a user
    /// opens a role, changes nothing, hits Save — the bytes must be identical.
    func testSaveLoadSave_withNoEdits_isIdentical() throws {
        let role = makeRole(skills: ["z", "m", "a"])
        var team = makeTeam(with: role)

        for _ in 0..<3 {
            let current = try XCTUnwrap(team.roles.first)
            var state = RoleEditorState()
            state.load(from: current)
            XCTAssertTrue(
                RoleEditorMutations.applyEdit(to: &team, editorState: state, existingRoleID: "r1"))
            XCTAssertEqual(try XCTUnwrap(team.roles.first).attachedSkillIDs, ["z", "m", "a"],
                           "a no-op re-save must not reshuffle the prompt")
        }
    }

    func testApplyEdit_reorderInTheEditor_persists() throws {
        let role = makeRole(skills: ["a", "b", "c"])
        var team = makeTeam(with: role)
        var state = RoleEditorState()
        state.load(from: role)

        state.attachedSkillIDs = RoleEditorSkillsPolicy.movingUp("c", in: state.attachedSkillIDs)
        XCTAssertTrue(RoleEditorMutations.applyEdit(to: &team, editorState: state, existingRoleID: "r1"))

        XCTAssertEqual(try XCTUnwrap(team.roles.first).attachedSkillIDs, ["a", "c", "b"])
    }

    func testApplyEdit_detach_persists() throws {
        let role = makeRole(skills: ["a", "b"])
        var team = makeTeam(with: role)
        var state = RoleEditorState()
        state.load(from: role)

        state.attachedSkillIDs = RoleEditorSkillsPolicy.detaching("a", from: state.attachedSkillIDs)
        XCTAssertTrue(RoleEditorMutations.applyEdit(to: &team, editorState: state, existingRoleID: "r1"))

        XCTAssertEqual(try XCTUnwrap(team.roles.first).attachedSkillIDs, ["b"])
    }

    /// The Supervisor is the user — no system prompt, so no place for a skill.
    func testApplyEdit_supervisorBranch_clearsSkills() throws {
        let role = makeRole(id: "sup", skills: ["a"], isSupervisor: true)
        var team = makeTeam(with: role)
        var state = RoleEditorState()
        state.load(from: role)

        XCTAssertTrue(RoleEditorMutations.applyEdit(to: &team, editorState: state, existingRoleID: "sup"))

        XCTAssertTrue(try XCTUnwrap(team.roles.first).attachedSkillIDs.isEmpty)
    }

    func testApplyCreate_carriesTheOrder() throws {
        var team = Team(name: "T", roles: [], artifacts: [], settings: .default, graphLayout: .default)
        var state = RoleEditorState()
        state.roleName = "Engineer"
        state.rolePrompt = "p"
        state.attachedSkillIDs = ["z", "a"]

        let newID = RoleEditorMutations.applyCreate(to: &team, editorState: state, teamID: team.id)

        let created = try XCTUnwrap(team.roles.first { $0.id == newID })
        XCTAssertEqual(created.attachedSkillIDs, ["z", "a"])
    }

    // MARK: - Contrast with the delegation whitelist

    /// Documents WHY the two fields differ: delegation is a membership test, so a
    /// `Set` is correct there; skills are a sequence, so it would be wrong here.
    func testDelegationStaysASet_whileSkillsStayAnArray() {
        var state = RoleEditorState()
        state.attachedSkillIDs = ["b", "a"]
        state.selectedDelegationTeamIDs = ["t1", "t2"]

        XCTAssertEqual(state.attachedSkillIDs, ["b", "a"], "sequence — order is meaning")
        XCTAssertEqual(state.selectedDelegationTeamIDs, Set(["t1", "t2"]), "membership — order is not")
    }
}
