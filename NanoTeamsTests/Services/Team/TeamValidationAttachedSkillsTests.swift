import XCTest
@testable import NanoTeams

/// A role can reference an agent skill that no longer resolves — the `SKILL.md`
/// was deleted or renamed, or it lives in a work folder that isn't open. The run
/// still proceeds (the skill is simply absent from the prompt), so this is a
/// WARNING; but silence would be wrong, because the user configured that role
/// expecting the text to be there.
final class TeamValidationAttachedSkillsTests: XCTestCase {

    private func makeTeam(roles: [TeamRoleDefinition]) -> Team {
        Team(name: "T", roles: roles, artifacts: [], settings: .default, graphLayout: .default)
    }

    private func makeRole(id: String, skills: [String]) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id, name: id.capitalized, prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies(),
            attachedSkillIDs: skills, isSystemRole: false, systemRoleID: nil)
    }

    func testUnknownSkillID_isFlagged() {
        let team = makeTeam(roles: [makeRole(id: "eng", skills: ["known", "ghost"])])

        let issues = TeamValidationService.validateAttachedSkills(
            team: team, knownSkillIDs: ["known"])

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first, .unknownAttachedSkill(roleID: "eng", skillID: "ghost"))
    }

    func testKnownSkillIDs_produceNoIssues() {
        let team = makeTeam(roles: [makeRole(id: "eng", skills: ["a", "b"])])

        XCTAssertTrue(TeamValidationService
            .validateAttachedSkills(team: team, knownSkillIDs: ["a", "b", "c"]).isEmpty)
    }

    /// The distinction that matters: an EMPTY catalogue means "no scan has landed
    /// yet", not "nothing resolves". Flagging every attachment in that window
    /// would light up warnings on every skilled role the moment a folder opens.
    func testEmptyCatalogue_isTreatedAsUnknown_notAsAllMissing() {
        let team = makeTeam(roles: [makeRole(id: "eng", skills: ["a"])])

        XCTAssertTrue(TeamValidationService
            .validateAttachedSkills(team: team, knownSkillIDs: []).isEmpty)
    }

    func testRoleWithNoSkills_producesNoIssues() {
        let team = makeTeam(roles: [makeRole(id: "eng", skills: [])])

        XCTAssertTrue(TeamValidationService
            .validateAttachedSkills(team: team, knownSkillIDs: ["a"]).isEmpty)
    }

    func testMultipleRoles_eachDanglingIDIsReported() {
        let team = makeTeam(roles: [
            makeRole(id: "eng", skills: ["ghost1"]),
            makeRole(id: "pm", skills: ["ghost2", "known"]),
        ])

        let issues = TeamValidationService.validateAttachedSkills(
            team: team, knownSkillIDs: ["known"])

        XCTAssertEqual(Set(issues), [
            .unknownAttachedSkill(roleID: "eng", skillID: "ghost1"),
            .unknownAttachedSkill(roleID: "pm", skillID: "ghost2"),
        ])
    }

    // MARK: - Severity + message

    func testIsAWarningNotAnError() {
        XCTAssertFalse(
            TeamValidationService.ValidationError
                .unknownAttachedSkill(roleID: "eng", skillID: "ghost").isError)
    }

    func testDisplayMessage_namesTheRoleAndTheSkill() {
        let team = makeTeam(roles: [makeRole(id: "eng", skills: ["ghost"])])

        let message = TeamValidationService.ValidationError
            .unknownAttachedSkill(roleID: "eng", skillID: "ghost")
            .displayMessage(in: team)

        XCTAssertTrue(message.contains("Eng"), "role display name, not the raw id")
        XCTAssertTrue(message.contains("ghost"), "the id, so the user can find it")
    }

    /// An id referencing a role that no longer exists falls back to the raw id
    /// rather than rendering blank — same contract as every other message.
    func testDisplayMessage_unknownRole_fallsBackToTheID() {
        let message = TeamValidationService.ValidationError
            .unknownAttachedSkill(roleID: "deleted-role", skillID: "ghost")
            .displayMessage(in: makeTeam(roles: []))

        XCTAssertTrue(message.contains("deleted-role"))
    }

    // MARK: - Banner wiring

    func testEditorBanner_surfacesTheWarning() {
        let team = makeTeam(roles: [makeRole(id: "eng", skills: ["ghost"])])

        let issues = TeamEditorValidation.issues(
            team: team, allTeams: [team], knownSkillIDs: ["known"])

        XCTAssertTrue(issues.contains { !$0.isError && $0.message.contains("ghost") })
    }

    /// The default keeps every pre-existing call site inert.
    func testEditorBanner_withoutACatalogue_addsNothing() {
        let team = makeTeam(roles: [makeRole(id: "eng", skills: ["ghost"])])

        let issues = TeamEditorValidation.issues(team: team, allTeams: [team])

        XCTAssertFalse(issues.contains { $0.message.contains("ghost") })
    }
}
