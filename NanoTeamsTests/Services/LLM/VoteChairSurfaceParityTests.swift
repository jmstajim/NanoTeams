import XCTest
@testable import NanoTeams

/// The editor and the runtime must agree about who can hold the gavel.
///
/// `CoordinatorResolutionConsistencyTests` next door pins "who is the COORDINATOR" — four
/// readers, one `Team.meetingCoordinatorID`. This pins the half that opened up in 1.9.18, when
/// a `request_changes` VOTE stopped always being chaired by the coordinator: if the coordinator
/// is the requester or the target it is disqualified and a stand-in is drawn from the pool with
/// both removed, and a team with nobody left gets `.noImpartialChair` and no vote at all.
///
/// Two surfaces went on claiming otherwise, unconditionally — the role-list tool badge ("In
/// meeting turns only (coordinator): conclude_meeting") and the wire preview, which read
/// `team.meetingCoordinatorID` directly while the runtime reads the resolved chair. Symptom:
/// the editor says role X closes meetings, the feed shows role Y closed the vote (DEBTS D-B12).
///
/// The expectation here is DERIVED from the runtime — every legal `(requester, target)` pair is
/// put to `effectiveCoordinator` and the editor is asked about whoever it seats — so this test
/// cannot drift away from the rule it is checking.
@MainActor
final class VoteChairSurfaceParityTests: XCTestCase {

    private var service: LLMExecutionService!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    /// RED: compute the badge's chair standing from `team.meetingCoordinatorID == role.id`
    /// (the pre-fix rule) → every stand-in comes back "never chairs a vote" and this fails
    /// naming the team and the pair.
    ///
    /// The assertion goes through `RoleToolBadgePolicy.model` deliberately, not through
    /// `MeetingChairPolicy` — the policy and the runtime share one rule and would agree
    /// vacuously. What has to agree with the runtime is the surface the Supervisor READS.
    func testEditorNamesEveryRoleTheRuntimeCanSeatAsAVoteChair() {
        var checkedPairs = 0
        var offenders: [String] = []

        for team in Team.defaultTeams where team.canHoldMeetings {
            for pair in MeetingChairPolicy.legalVotePairs(in: team) {
                guard let requester = team.roles.first(where: { $0.id == pair.requesterID })
                else { continue }
                checkedPairs += 1
                let seated = service.effectiveCoordinator(
                    team: team,
                    initiator: Role.fromDefinition(requester),
                    requesterRoleID: pair.requesterID,
                    seat: .presentsOnly(targetRoleID: pair.targetID),
                    targetRoleID: pair.targetID)
                guard case .chair(let chairRole) = seated,
                      let chairDef = team.findRole(byIdentifier: chairRole.baseID)
                else { continue }
                if !badge(for: chairDef, in: team).chair.canChairSomeVote {
                    offenders.append(
                        "\(team.name): the runtime seats '\(chairDef.name)' for "
                            + "(\(requester.name) → \(pair.targetID)), the editor says it never "
                            + "chairs a vote")
                }
            }
        }

        // Anti-vacuum: bundled teams must actually offer legal vote pairs, or "the editor
        // names every seated role" is a statement about an empty loop.
        XCTAssertGreaterThanOrEqual(
            checkedPairs, 4,
            "no bundled team offers a legal (requester, target) pair — the derivation went "
                + "blind and this pin proves nothing")
        XCTAssertTrue(offenders.isEmpty, offenders.sorted().joined(separator: "\n"))
    }

    /// The discriminating control for the pin above: on a team whose coordinator IS party to
    /// some legal pair, the editor must also say the coordinator can be displaced. Without
    /// this, a badge that answered `canChairSomeVote = true` for everyone would pass.
    ///
    /// RED: make `Standing.displacedOnSomeVote` always false → this fails.
    func testTheEditorAlsoNamesTheDisplacementItself() {
        let displaced = Team.defaultTeams
            .filter(\.canHoldMeetings)
            .filter { team in
                guard let coordinatorID = team.meetingCoordinatorID else { return false }
                return MeetingChairPolicy.legalVotePairs(in: team).contains {
                    $0.requesterID == coordinatorID || $0.targetID == coordinatorID
                }
            }
        XCTAssertFalse(
            displaced.isEmpty,
            "no bundled team has a coordinator party to a legal vote — the displacement this "
                + "pin is about is unreachable and the sibling assertion is weaker than it looks")
        for team in displaced {
            guard let coordinatorID = team.meetingCoordinatorID,
                  let coordinator = team.roles.first(where: { $0.id == coordinatorID })
            else { continue }
            let standing = badge(for: coordinator, in: team).chair
            XCTAssertTrue(standing.chairsMeetings, "\(team.name): \(coordinator.name)")
            XCTAssertTrue(
                standing.displacedOnSomeVote,
                "\(team.name): \(coordinator.name) is party to a legal vote, so the editor must "
                    + "say it loses the gavel there")
            XCTAssertFalse(
                standing.standInIDs.isEmpty,
                "\(team.name): the editor must be able to NAME who takes the chair instead")
        }
    }

    /// RED: restore `isCoordinator: inputs.team?.meetingCoordinatorID == inputs.role.id` at
    /// `PromptBuilder+WirePreview.swift:270` → the stand-in's preview loses `conclude_meeting`
    /// and the coordinator's keeps it regardless of the flag.
    ///
    /// The preview never has a vote in hand, and it does not need one: `WirePreviewInputs`
    /// already carries an explicit `isCoordinator`, set by the sheet's chair toggle. Ignoring
    /// it made the preview contradict ITSELF before it ever contradicted a vote — the
    /// coordinator hint followed the toggle while the tool block followed the stored id.
    func testMeetingPreview_toolsFollowTheChairFlag_notTheStoredCoordinator() {
        guard let team = Team.defaultTeams.first(where: {
            $0.canHoldMeetings && $0.nonSupervisorRoles.count >= 2
        }),
            let coordinatorID = team.meetingCoordinatorID,
            let coordinator = team.roles.first(where: { $0.id == coordinatorID }),
            let standIn = team.nonSupervisorRoles.first(where: { $0.id != coordinatorID })
        else { return XCTFail("no bundled team with a coordinator and a second role") }

        let asChair = PromptBuilder.resolveWirePreviewTools(
            kind: .meeting, inputs: makeInputs(team: team, role: standIn, isCoordinator: true))
        XCTAssertTrue(
            asChair.contains { $0.name == ToolNames.concludeMeeting },
            "a stand-in chairing a vote must be previewable — that is the payload the feed "
                + "will show")

        let asParticipant = PromptBuilder.resolveWirePreviewTools(
            kind: .meeting,
            inputs: makeInputs(team: team, role: coordinator, isCoordinator: false))
        XCTAssertFalse(
            asParticipant.contains { $0.name == ToolNames.concludeMeeting },
            "the coordinator displaced from a vote it is party to holds no gavel in it")
    }

    /// RED: drop `canHoldMeetings` from the survey → a team with meetings off reports standings
    /// for a meeting it cannot hold.
    func testMeetingsOff_leavesEveryStandingEmpty() {
        guard var team = Team.defaultTeams.first(where: { $0.canHoldMeetings }) else {
            return XCTFail("no bundled team holds meetings")
        }
        team.settings.meetingsEnabled = false
        let survey = MeetingChairPolicy.voteChairSurvey(in: team)
        for role in team.roles {
            XCTAssertEqual(survey.standing(of: role.id), MeetingChairPolicy.Standing(),
                           "\(role.name) has a standing on a team that holds no meetings")
        }
    }

    private func badge(
        for role: TeamRoleDefinition, in team: Team
    ) -> RoleToolBadgePolicy.Model {
        RoleToolBadgePolicy.model(
            role: role,
            team: team,
            allTeams: [team],
            storage: .defaultStorage,
            selectedScheme: nil,
            isVisionConfigured: false,
            approval: ToolApprovalAvailability(
                bash: .available, computerUse: .withheld(.switchedOff)),
            autovisorTeamPolicy: .unrestricted
        )
    }

    private func makeInputs(
        team: Team, role: TeamRoleDefinition, isCoordinator: Bool
    ) -> PromptBuilder.WirePreviewInputs {
        PromptBuilder.WirePreviewInputs(
            role: role,
            team: team,
            allTeams: [team],
            workFolder: nil,
            workFolderState: .defaultStorage,
            selectedScheme: nil,
            isVisionConfigured: false,
            approval: ToolApprovalAvailability(
                bash: .available, computerUse: .withheld(.switchedOff)),
            globalContext: AppDefaults.globalContext,
            isCoordinator: isCoordinator,
            agentInstructions: nil
        )
    }
}
