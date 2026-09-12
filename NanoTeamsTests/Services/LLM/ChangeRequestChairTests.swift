import XCTest
@testable import NanoTeams

/// Who holds the gavel in a `request_changes` vote.
///
/// The regressions here are written on **FAANG**, not on a fixture, because the defect they
/// pin is live in a SHIPPED team: FAANG's meeting coordinator is the TPM
/// (`TeamTemplateFactory` seeds `coordinatorIndex` at the TPM), the TPM holds
/// `request_changes`, and the team runs `.autonomous` — so a TPM change request convened a
/// meeting the TPM itself opened, closed every round of, concluded, and was the only holder
/// of `conclude_meeting` in. Engineering has the identical shape. The line in CLAUDE.md
/// saying the requester "is not in `participants` and never speaks" described the intent;
/// `handleTeamMeeting` appended the coordinator unconditionally, without consulting the seat.
@MainActor
final class ChangeRequestChairTests: XCTestCase {

    private var service: LLMExecutionService!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func faang() -> Team { Team.defaultTeams.first { $0.templateID == "faang" }! }

    private func roleID(_ team: Team, _ name: String) -> String {
        team.roles.first { $0.name == name }!.id
    }

    /// `requesterRoleID` defaults to the initiator's own definition — the fixtures below
    /// carry no twins, so the `findRole` trip is exact for them; the twin test passes it.
    private func chair(
        _ team: Team, initiator: Role, requesterRoleID: String? = nil, target: String?
    ) -> Role? {
        let seat: TeamMeetingService.InitiatorSeat =
            target.map { .presentsOnly(targetRoleID: $0) } ?? .speaks
        let requester = requesterRoleID ?? team.findRole(byIdentifier: initiator.baseID)?.id ?? ""
        guard case .chair(let role) = service.effectiveCoordinator(
            team: team, initiator: initiator, requesterRoleID: requester,
            seat: seat, targetRoleID: target) else { return nil }
        return role
    }

    // MARK: - The requester may not chair its own case

    func testRequesterIsTheCoordinator_aStandInTakesTheChair() {
        let team = faang()
        let coordinatorID = team.meetingCoordinatorID
        XCTAssertNotNil(coordinatorID, "test premise: FAANG has a coordinator")
        let coordinatorRole = Role.fromDefinition(team.findRole(byIdentifier: coordinatorID!)!)
        XCTAssertTrue(
            team.findRole(byIdentifier: coordinatorID!)!.toolIDs.contains(ToolNames.requestChanges),
            "test premise: FAANG's coordinator is also a `request_changes` holder — that pairing "
                + "is what made the defect reachable in a shipped team")

        let seated = chair(team, initiator: coordinatorRole, target: roleID(team, "Software Engineer"))
        let seatedID = seated.flatMap { team.findRole(byIdentifier: $0.baseID)?.id }
        XCTAssertNotNil(seatedID)
        XCTAssertNotEqual(seatedID, coordinatorID,
                          "the requester must not re-enter its own vote through the chair's door")
    }

    // MARK: - Nor may the target

    func testTargetIsTheCoordinator_aStandInTakesTheChair() {
        let team = faang()
        let coordinatorID = team.meetingCoordinatorID!
        let seated = chair(team, initiator: .softwareEngineer, target: coordinatorID)
        let seatedID = seated.flatMap { team.findRole(byIdentifier: $0.baseID)?.id }
        XCTAssertNotNil(seatedID)
        XCTAssertNotEqual(seatedID, coordinatorID,
                          "the target is a participant in its own vote; chairing it too is the "
                              + "same defect one seat over")
    }

    /// The stand-in is drawn from the pool with BOTH removed, and never the Supervisor.
    func testStandIn_isNeitherRequesterNorTargetNorSupervisor() {
        let team = faang()
        let coordinatorID = team.meetingCoordinatorID!
        let coordinatorRole = Role.fromDefinition(team.findRole(byIdentifier: coordinatorID)!)
        let targetID = roleID(team, "Software Engineer")

        let seated = chair(team, initiator: coordinatorRole, target: targetID)
        let seatedDef = seated.flatMap { team.findRole(byIdentifier: $0.baseID) }
        XCTAssertNotNil(seatedDef)
        XCTAssertNotEqual(seatedDef?.id, coordinatorID)
        XCTAssertNotEqual(seatedDef?.id, targetID)
        XCTAssertEqual(seatedDef?.isSupervisor, false)
    }

    /// A discussion meeting is unaffected: `request_team_meeting` seats its initiator and the
    /// team's coordinator chairs, requester or not. The rule is scoped to the seat.
    func testSpeaksSeat_keepsTheTeamCoordinator_evenWhenItIsTheInitiator() {
        let team = faang()
        let coordinatorID = team.meetingCoordinatorID!
        let coordinatorRole = Role.fromDefinition(team.findRole(byIdentifier: coordinatorID)!)
        let seated = chair(team, initiator: coordinatorRole, target: nil)
        XCTAssertEqual(team.findRole(byIdentifier: seated!.baseID)?.id, coordinatorID)
    }

    // MARK: - A team with nobody left to chair

    /// Two non-Supervisor roles: the requester and the target. There is no third party, so
    /// the vote does not run. Before the rule the TARGET chaired its own case here, and this
    /// branch was unreachable.
    func testTwoRoleTeam_hasNoImpartialChair() {
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Supervisor Task"]),
            systemRoleID: "supervisor")
        let a = TeamRoleDefinition(
            id: "a", name: "Maker", prompt: "p", toolIDs: [ToolNames.createArtifact],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Supervisor Task"],
                                           producesArtifacts: ["Work"]))
        let b = TeamRoleDefinition(
            id: "b", name: "Checker", prompt: "p",
            toolIDs: [ToolNames.createArtifact, ToolNames.requestChanges], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Work"],
                                           producesArtifacts: ["Review"]))
        let team = Team(
            name: "Pair", roles: [supervisor, a, b], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "b"), graphLayout: TeamGraphLayout())

        XCTAssertEqual(
            service.effectiveCoordinator(
                team: team, initiator: .custom(id: "Checker"), requesterRoleID: "b",
                seat: .presentsOnly(targetRoleID: "a"), targetRoleID: "a"),
            .noImpartialChair)
    }

    // MARK: - The requester and the coordinator are read by definition id, not by Role

    /// Two definitions sharing a `systemRoleID` — an editor duplicate — collapse to ONE
    /// `Role` in `Role.fromDefinition`, and `findRole(byIdentifier:)` answers with the first
    /// of them. Until the evening of 2026-09-11 both the requester and the coordinator were
    /// round-tripped through that pair, so with the requester's twin stored first the
    /// uninvolved coordinator was disqualified through it and a stand-in took a chair that
    /// was rightfully the coordinator's.
    ///
    /// The meeting itself is still `Role`-keyed (DEBTS D-B13), which is why the assertion
    /// is on the ROLE the chair resolves to, not on a definition id: `.tpm` here can only
    /// mean the coordinator kept the chair, because the requester's twin is disqualified by
    /// its own id and a stand-in from the remaining pool would be the Code Reviewer.
    ///
    /// RED: put `canonical(coordinator.baseID)` back in place of `team.meetingCoordinatorID`
    /// → `.codeReviewer`.
    func testDuplicatedSystemRole_theCoordinatorIsNotDisqualifiedThroughItsTwin() {
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Supervisor Task"]),
            systemRoleID: "supervisor")
        // The requester is the twin stored FIRST, so it is what the identifier trip lands on.
        let requester = TeamRoleDefinition(
            id: "tpm-b", name: "TPM (copy)", prompt: "", toolIDs: [ToolNames.requestChanges],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Engineering Notes"],
                                           producesArtifacts: ["Release Notes B"]),
            systemRoleID: "tpm")
        let bystander = TeamRoleDefinition(
            id: "cr", name: "Code Reviewer", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Engineering Notes"],
                                           producesArtifacts: ["Code Review Summary"]),
            systemRoleID: "codeReviewer")
        let coordinator = TeamRoleDefinition(
            id: "tpm-a", name: "TPM", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Engineering Notes"],
                                           producesArtifacts: ["Release Notes"]),
            systemRoleID: "tpm")
        let target = TeamRoleDefinition(
            id: "swe", name: "Software Engineer", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Engineering Notes"]),
            systemRoleID: "softwareEngineer")
        let team = Team(
            name: "Twins", roles: [supervisor, requester, bystander, coordinator, target],
            artifacts: [], settings: TeamSettings(meetingCoordinatorRoleID: "tpm-a"),
            graphLayout: TeamGraphLayout())
        XCTAssertEqual(team.findRole(byIdentifier: "tpm")?.id, "tpm-b",
                       "test premise: the identifier trip lands on the requester's twin")

        XCTAssertEqual(
            chair(team, initiator: .tpm, requesterRoleID: "tpm-b", target: "swe"), .tpm,
            "the coordinator is neither the requester nor the target and keeps the chair")
        // And the requester's twin IS out when it is the coordinator: the stand-in rule runs.
        var twinChairs = team
        twinChairs.settings.meetingCoordinatorRoleID = "tpm-b"
        XCTAssertEqual(
            chair(twinChairs, initiator: .tpm, requesterRoleID: "tpm-b", target: "swe"),
            .codeReviewer)
    }

    // MARK: - Custom roles: one constructor on both sides

    /// `resolveCoordinatorRole` used to build `.custom(id: def.id)` while
    /// `MeetingParticipantResolver` built `.custom(id: definition.name)`. Identical for a
    /// built-in role, different for a custom one — so on a user-authored team the chair
    /// failed `handleTeamMeeting`'s `participants.contains` check, was appended a SECOND
    /// time, spoke twice a round and counted as two voters. Exactly the teams the runtime
    /// rule exists to protect.
    ///
    /// RED: return `.custom(id: def.id)` from `resolveCoordinatorRole` → the chair's id is
    /// the uuid and stops matching the participant built from the same definition.
    func testCustomRoleChair_usesTheSameConstructorAsTheParticipantResolver() {
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Supervisor Task"]),
            systemRoleID: "supervisor")
        let one = TeamRoleDefinition(
            id: "uuid-one", name: "Lore Keeper", prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies())
        let two = TeamRoleDefinition(
            id: "uuid-two", name: "Map Maker", prompt: "p", toolIDs: [],
            usePlanningPhase: false, dependencies: RoleDependencies())
        let team = Team(
            name: "Custom", roles: [supervisor, one, two], artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "uuid-one"),
            graphLayout: TeamGraphLayout())

        let resolved = service.resolveCoordinatorRole(team: team)
        let asParticipant = MeetingParticipantResolver.filterParticipants(
            participantIDs: ["uuid-one"], initiatingRole: .custom(id: "Map Maker"),
            team: team, teamSettings: team.settings).participants.first

        XCTAssertEqual(resolved, asParticipant,
                       "the chair and the same role seated as a participant must be ONE role, "
                           + "or the chair is appended twice and votes twice")
        XCTAssertEqual(resolved, .custom(id: "Lore Keeper"))
    }
}
