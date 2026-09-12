import XCTest
@testable import NanoTeams

/// The severity law of `TeamValidationService.ValidationError.isError` for every live case.
///
/// Until 2026-09-04 this file exercised the four artifact-chain validators (duplicate producer,
/// missing producer, circular dependency, orphan artifact) and the aggregators over them. None of that had a
/// production caller — the Team Editor banner never showed its output — so it was deleted with
/// the four cases only it could construct. What survives of the law this file pinned is the
/// error/warning split, which `TeamEditorValidation.issues` forwards to the banner row's icon
/// and tint (CLAUDE.md #104: re-aimed, not dropped).
final class TeamValidationServiceTests: XCTestCase {

    private typealias ValidationError = TeamValidationService.ValidationError

    // MARK: - ValidationError.isError

    /// Eligibility is the rule the run-time handler also refuses (`roleIsTopLevelDelegator` →
    /// `.delegationDenied`, `LLMExecutionService+DelegateToTeam`). Self-delegation has NO runtime
    /// mirror — the handler's whitelist guard passes an own-team id — so it is caught only here
    /// and by the role editor's team picker (`RoleEditorDelegationPolicy.delegatableTeams`
    /// excludes the own team). `isError` is the one place either is marked blocking, and what it
    /// drives is the banner's red tint and the top bar's count; the editor gates nothing on it.
    ///
    /// RED: move `.delegationToSelf` into the `return false` arm of `isError` → the second
    /// assertion fails.
    func testValidationError_isError_trueForBlockingDelegationCases() {
        XCTAssertTrue(ValidationError.nonTopLevelDelegator(roleID: "a").isError)
        XCTAssertTrue(ValidationError.delegationToSelf(roleID: "a", teamID: "t").isError)
    }

    /// A stale whitelist entry, an empty effective catalogue and a missing skill file are all
    /// recoverable without editing the role — the run proceeds — so they must not block.
    ///
    /// RED: move `.unknownDelegationTeam` into the `return true` arm of `isError` → the first
    /// assertion fails.
    func testValidationError_isError_falseForAdvisoryCases() {
        XCTAssertFalse(ValidationError.unknownDelegationTeam(roleID: "a", teamID: "t").isError,
                       "a deleted target team may come back — warn, do not block")
        XCTAssertFalse(ValidationError.noDelegationTargets(roleID: "a").isError)
        XCTAssertFalse(ValidationError.unknownAttachedSkill(roleID: "a", skillID: "s").isError,
                       "the run proceeds with the skill absent from the prompt — warn, do not block")
        XCTAssertFalse(ValidationError.meetingCoordinatorHealed(from: "ghost", to: "a").isError,
                       "the team runs with the healed coordinator — warn, do not block")
    }

    /// Off on a chat-mode team leaves its role with no reply channel — the one setting
    /// combination that makes a run useless, so it blocks.
    func testValidationError_isError_trueForAskSupervisorOffInChatMode() {
        XCTAssertTrue(ValidationError.askSupervisorOffInChatMode.isError)
    }

    // MARK: - validateMeetingCoordinator / validateSupervisorMode

    private func team(coordID: String?, mode: SupervisorMode = .manual, chatMode: Bool) -> Team {
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: chatMode ? [] : ["Result"]),
            isSystemRole: true, systemRoleID: "supervisor")
        let worker = TeamRoleDefinition(
            id: "w", name: "Worker", prompt: "p", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Supervisor Task"],
                                           producesArtifacts: chatMode ? [] : ["Result"]))
        return Team(
            name: "T", roles: [supervisor, worker], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: coordID, supervisorMode: mode),
            graphLayout: TeamGraphLayout())
    }

    func testValidateMeetingCoordinator_liveStoredID_isClean() {
        XCTAssertEqual(TeamValidationService.validateMeetingCoordinator(team: team(coordID: "w", chatMode: false)), [])
    }

    func testValidateMeetingCoordinator_nilOrOrphan_warnsNamingTheHealedRole() {
        XCTAssertEqual(
            TeamValidationService.validateMeetingCoordinator(team: team(coordID: nil, chatMode: false)),
            [.meetingCoordinatorHealed(from: nil, to: "w")])
        XCTAssertEqual(
            TeamValidationService.validateMeetingCoordinator(team: team(coordID: "ghost", chatMode: false)),
            [.meetingCoordinatorHealed(from: "ghost", to: "w")])
    }

    func testValidateSupervisorMode_offOnChatModeTeam_isAnError_elsewhereClean() {
        XCTAssertEqual(
            TeamValidationService.validateSupervisorMode(team: team(coordID: "w", mode: .off, chatMode: true)),
            [.askSupervisorOffInChatMode])
        XCTAssertEqual(TeamValidationService.validateSupervisorMode(team: team(coordID: "w", mode: .off, chatMode: false)), [])
        XCTAssertEqual(TeamValidationService.validateSupervisorMode(team: team(coordID: "w", mode: .manual, chatMode: true)), [])
    }

    // MARK: - validateSupervisorAskTools

    private func teamWithToolIDs(_ toolIDs: [String]) -> Team {
        var t = team(coordID: "w", chatMode: false)
        guard let i = t.roles.firstIndex(where: { $0.id == "w" }) else { return t }
        t.roles[i].toolIDs = toolIDs
        return t
    }

    /// A role granted the questionnaire and not the plain ask is flagged — a WARNING, because
    /// the resolver pairs the two before the schema ships (step 4-bis) and the run is fine. The
    /// banner says so anyway: the stored toolset does not match what runs, and the next person
    /// to read the Tools tab would otherwise conclude the role cannot ask at all.
    ///
    /// RED: return `[]` from `validateSupervisorAskTools` → the first assertion fails.
    func testValidateSupervisorAskTools_formWithoutThePlainAsk_warnsNamingTheRole() {
        let issues = TeamValidationService.validateSupervisorAskTools(
            team: teamWithToolIDs([ToolNames.readFile, ToolNames.askSupervisorForm]))

        XCTAssertEqual(issues, [.supervisorFormWithoutPlainAsk(roleID: "w")])
        XCTAssertFalse(issues[0].isError, "the resolver pairs them — warn, do not block")
        let message = issues[0].displayMessage(in: teamWithToolIDs([ToolNames.askSupervisorForm]))
        XCTAssertTrue(message.contains("Worker"), "the role is named, not its id")
        XCTAssertTrue(message.contains(ToolNames.askSupervisor),
                      "the message names the tool to add")
    }

    /// Both, the plain ask alone, and neither are all legitimate shapes: the form is a
    /// companion, so only its solitude is worth a word.
    ///
    /// RED: flag on `!toolIDs.contains(askSupervisorForm)` instead → the "plain ask alone"
    /// row fails, which is the shape almost every bundled role has.
    func testValidateSupervisorAskTools_everyOtherShape_isClean() {
        for toolIDs in [
            [ToolNames.askSupervisor, ToolNames.askSupervisorForm],
            [ToolNames.askSupervisor],
            [ToolNames.readFile],
            [],
        ] {
            XCTAssertEqual(
                TeamValidationService.validateSupervisorAskTools(team: teamWithToolIDs(toolIDs)), [],
                "\(toolIDs) is a legitimate toolset")
        }
    }

    func testDisplayMessages_nameTheRoleAndTheRemedy() {
        let t = team(coordID: "ghost", chatMode: true)
        let healed = ValidationError.meetingCoordinatorHealed(from: "ghost", to: "w").displayMessage(in: t)
        XCTAssertTrue(healed.contains("Worker"), "the healed role is named, not its id")
        XCTAssertTrue(healed.contains("ghost"))
        let off = ValidationError.askSupervisorOffInChatMode.displayMessage(in: t)
        XCTAssertTrue(off.contains("ask_supervisor"))
        XCTAssertTrue(off.contains("Manual or Autonomous"))
    }
}
