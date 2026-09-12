import XCTest
@testable import NanoTeams

@MainActor
final class ChangeRequestServiceTests: XCTestCase {

    // MARK: - tallyVotes

    func testTallyVotes_moreApproves_returnsApproved() {
        let messages = [
            makeMessage(.techLead, "I agree with these changes. VOTE: APPROVE"),
            makeMessage(.softwareEngineer, "Looks good. VOTE: APPROVE"),
            makeMessage(.codeReviewer, "I disagree. VOTE: REJECT"),
        ]
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: nil, target: nil), .approved)
    }

    func testTallyVotes_moreRejects_returnsRejected() {
        let messages = [
            makeMessage(.techLead, "Not needed. VOTE: REJECT"),
            makeMessage(.softwareEngineer, "Too risky. VOTE: REJECT"),
            makeMessage(.codeReviewer, "VOTE: APPROVE"),
        ]
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: nil, target: nil), .rejected)
    }

    func testTallyVotes_equalVotes_returnsTied() {
        let messages = [
            makeMessage(.techLead, "VOTE: APPROVE"),
            makeMessage(.softwareEngineer, "VOTE: REJECT"),
        ]
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: nil, target: nil), .tied)
    }

    /// RED: restore `return .tied` for the 0-0 case → this and the caller-level
    /// `testNoVotes_isRejected_andAmendsNothing` both fail.
    func testTallyVotes_noVotes_returnsNoVotes() {
        let messages = [
            makeMessage(.techLead, "Let me think about it..."),
            makeMessage(.softwareEngineer, "I'm not sure either"),
        ]
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: nil, target: nil), .noVotes)
    }

    func testTallyVotes_emptyMessages_returnsNoVotes() {
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: [], coordinator: nil, target: nil), .noVotes)
    }

    func testTallyVotes_voteWithoutSpace_counted() {
        let messages = [
            makeMessage(.techLead, "VOTE:APPROVE"),
        ]
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: nil, target: nil), .approved)
    }

    func testTallyVotes_caseInsensitiveContent() {
        // The content is uppercased in the code, so mixed case should work
        let messages = [
            makeMessage(.techLead, "I think this is fine. Vote: Approve"),
        ]
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: nil, target: nil), .approved)
    }

    // MARK: - tallyVotes: one ballot per ROLE, and the chair is an arbiter

    /// The rotation does not hand out turns evenly. `determineNextSpeaker` rotates over the
    /// participants MINUS the chair, and the chair additionally opens the meeting, closes
    /// every round and concludes — 6 turns out of 10 in a three-seat vote. Counting MESSAGES
    /// therefore gave one voter six ballots and let seating order decide every close vote.
    ///
    /// RED: count messages instead of roles → the single dissenter is outvoted 3-1 here.
    func testTallyVotes_oneBallotPerRole_notPerMessage() {
        let messages = [
            makeMessage(.techLead, "Opening. VOTE: APPROVE"),
            makeMessage(.softwareEngineer, "I disagree. VOTE: REJECT"),
            makeMessage(.techLead, "Round closed. VOTE: APPROVE"),
            makeMessage(.techLead, "Still think so. VOTE: APPROVE"),
        ]
        XCTAssertEqual(
            ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: nil, target: nil), .tied,
            "three turns by one role are one ballot, so this is 1-1")
    }

    /// A role's LAST token-bearing message is its ballot — a later turn is a revised
    /// position, not an additional vote.
    func testTallyVotes_aRoleMayChangeItsMind_theLastTokenWins() {
        let messages = [
            makeMessage(.techLead, "On reflection, VOTE: REJECT"),
            makeMessage(.techLead, "Actually the risk is contained. VOTE: APPROVE"),
        ]
        XCTAssertEqual(
            ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: nil, target: nil), .approved)
    }

    /// The concluding turn carries no `VOTE:` token — its content is `conclusion.decision` —
    /// and must not erase the vote the same role cast earlier.
    func testTallyVotes_aLaterMessageWithoutATokenDoesNotEraseTheVote() {
        let messages = [
            makeMessage(.techLead, "VOTE: APPROVE"),
            makeMessage(.techLead, "Concluding: the change carries."),
        ]
        XCTAssertEqual(
            ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: nil, target: nil), .approved)
    }

    /// `MeetingCoordinator.turnDirective` appends `voteInstruction` to EVERY directive,
    /// the chair's included — so the chair votes. Weight is the COUNT's business: a chair
    /// that votes like everyone else while speaking more than everyone else is just the
    /// loudest voter. Two of the three edges a checker-bearing team votes on have exactly
    /// two non-chair voters, so their disagreement is the ordinary case.
    func testTallyVotes_chairBreaksATieAmongTheOthers() {
        let messages = [
            makeMessage(.softwareEngineer, "VOTE: APPROVE"),
            makeMessage(.codeReviewer, "VOTE: REJECT"),
            makeMessage(.techLead, "As chair, VOTE: APPROVE"),
        ]
        XCTAssertEqual(
            ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: .techLead, target: nil),
            .approved)
    }

    /// …and only a tie. An arbiter that could overturn a majority would not be an arbiter.
    func testTallyVotes_chairDoesNotOverturnAMajority() {
        let messages = [
            makeMessage(.softwareEngineer, "VOTE: APPROVE"),
            makeMessage(.sre, "VOTE: APPROVE"),
            makeMessage(.codeReviewer, "VOTE: REJECT"),
            makeMessage(.techLead, "As chair, VOTE: REJECT"),
        ]
        XCTAssertEqual(
            ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: .techLead, target: nil),
            .approved, "2-1 among the voters stands; the chair only breaks ties")
    }

    /// `.tied` survives, but its reachable shape narrows: the voters are even AND the chair
    /// abstained. That is the case the V1 auto-approve policy (DEBTS) still stands on.
    func testTallyVotes_tieWithAnAbstainingChair_isStillTied() {
        let messages = [
            makeMessage(.softwareEngineer, "VOTE: APPROVE"),
            makeMessage(.codeReviewer, "VOTE: REJECT"),
            makeMessage(.techLead, "I will let the room decide."),
        ]
        XCTAssertEqual(
            ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: .techLead, target: nil),
            .tied)
    }

    /// Nobody voted at all — including the chair. Distinct from a tie: there is no
    /// disagreement to resolve, so nothing may be read as consent.
    func testTallyVotes_chairAbstainsAndNobodyElseVoted_isNoVotes() {
        let messages = [
            makeMessage(.softwareEngineer, "Thinking."),
            makeMessage(.techLead, "Let us reconvene."),
        ]
        XCTAssertEqual(
            ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: .techLead, target: nil),
            .noVotes)
    }

    /// A chair voting alone decides: it is the only ballot cast, so there is no room whose
    /// verdict it could be overriding. `.noVotes` means no ballot from ANYONE — an arbiter
    /// that heard the whole discussion and cast the only ballot has decided.
    func testTallyVotes_onlyTheChairVoted_itDecides() {
        let messages = [
            makeMessage(.softwareEngineer, "No opinion."),
            makeMessage(.techLead, "VOTE: REJECT"),
        ]
        XCTAssertEqual(
            ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: .techLead, target: nil),
            .rejected)
    }

    // MARK: - The target defends, it does not vote

    /// The defendant's ballot is dropped: target REJECT against the chair's APPROVE is an
    /// EMPTY electorate, and the chair decides. Until the evening of 2026-09-11 the target
    /// was counted, `1 > 0` short-circuited before the chair, and the request was rejected
    /// by the role it was about — on every bundled edge whose requester is the target's only
    /// consumer (Engineering Code Reviewer → Software Engineer among them).
    ///
    /// RED: drop the `role != target` clause from `electorate` → `.rejected`.
    func testTallyVotes_theTargetsOwnBallotIsNotCounted() {
        let messages = [
            makeMessage(.softwareEngineer, "My implementation stands.\nVOTE: REJECT"),
            makeMessage(.techLead, "The reviewer is right.\nVOTE: APPROVE"),
        ]
        XCTAssertEqual(
            ChangeRequestService.tallyVotes(
                meetingMessages: messages, coordinator: .techLead, target: .softwareEngineer),
            .approved)
    }

    /// One consumer against the target: the consumer IS the electorate and decides alone;
    /// the target's ballot is not what makes it a tie for the chair to break.
    func testTallyVotes_targetAgainstOneConsumer_theConsumerDecides() {
        let messages = [
            makeMessage(.softwareEngineer, "VOTE: REJECT"),
            makeMessage(.sre, "VOTE: APPROVE"),
            makeMessage(.techLead, "I would have rejected. VOTE: REJECT"),
        ]
        XCTAssertEqual(
            ChangeRequestService.tallyVotes(
                meetingMessages: messages, coordinator: .techLead, target: .softwareEngineer),
            .approved, "the chair does not overturn an electorate of one either")
    }

    /// The target's ballot is not merely down-weighted: with nobody else and no chair
    /// ballot, the vote is `.noVotes`, never the target's own verdict.
    func testTallyVotes_onlyTheTargetVoted_isNoVotes() {
        let messages = [
            makeMessage(.softwareEngineer, "VOTE: APPROVE"),
            makeMessage(.techLead, "Let me hear the others."),
        ]
        XCTAssertEqual(
            ChangeRequestService.tallyVotes(
                meetingMessages: messages, coordinator: .techLead, target: .softwareEngineer),
            .noVotes)
    }

    /// A nil target excludes nobody — the discussion-meeting shape, and the tally's old
    /// behaviour for every caller that has no defendant.
    func testTallyVotes_nilTarget_countsEveryNonChairBallot() {
        let messages = [
            makeMessage(.softwareEngineer, "VOTE: REJECT"),
            makeMessage(.techLead, "VOTE: APPROVE"),
        ]
        XCTAssertEqual(
            ChangeRequestService.tallyVotes(meetingMessages: messages, coordinator: .techLead, target: nil),
            .rejected)
    }

    // MARK: - validateChangeRequest

    func testValidateChangeRequest_targetNotFound_returnsError() {
        let team = makeTeam()
        let run = makeRun(steps: [])
        let (error, roleDef) = ChangeRequestService.validateChangeRequest(
            targetRoleID: "nonexistent",
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: team.settings,
            run: run
        )
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("not found"))
        XCTAssertNil(roleDef)
    }

    func testValidateChangeRequest_targetIsSupervisor_returnsError() {
        let team = makeTeam()
        let supervisorRole = team.roles.first { $0.isSupervisor }!
        let run = makeRun(steps: [])
        let (error, _) = ChangeRequestService.validateChangeRequest(
            targetRoleID: supervisorRole.id,
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: team.settings,
            run: run
        )
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("Supervisor"))
    }

    func testValidateChangeRequest_targetStepNotDone_returnsError() {
        let team = makeTeam()
        let engineerRole = team.roles.first { $0.systemRoleID == "softwareEngineer" }!
        let step = StepExecution.make(for: engineerRole)
        var mutableStep = step
        mutableStep.status = .running
        let run = makeRun(steps: [mutableStep])
        let (error, _) = ChangeRequestService.validateChangeRequest(
            targetRoleID: engineerRole.id,
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: team.settings,
            run: run
        )
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("not completed"))
    }

    func testValidateChangeRequest_targetStepDone_succeeds() {
        let team = makeTeam()
        let engineerRole = team.roles.first { $0.systemRoleID == "softwareEngineer" }!
        var step = StepExecution.make(for: engineerRole)
        step.status = .done
        let run = makeRun(steps: [step])
        let (error, roleDef) = ChangeRequestService.validateChangeRequest(
            targetRoleID: engineerRole.id,
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: team.settings,
            run: run
        )
        XCTAssertNil(error)
        XCTAssertNotNil(roleDef)
        XCTAssertEqual(roleDef?.id, engineerRole.id)
    }

    func testValidateChangeRequest_limitExceeded_returnsError() {
        let team = makeTeam()
        let engineerRole = team.roles.first { $0.systemRoleID == "softwareEngineer" }!
        var step = StepExecution.make(for: engineerRole)
        step.status = .done
        var settings = team.settings
        settings.limits = TeamLimits(maxChangeRequestsPerRun: 1)
        var run = makeRun(steps: [step])
        run.changeRequests = [ChangeRequest(
            requestingRoleID: "cr", targetRoleID: engineerRole.id,
            changes: "fix", reasoning: "bug", status: .approved
        )]
        let (error, _) = ChangeRequestService.validateChangeRequest(
            targetRoleID: engineerRole.id,
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: settings,
            run: run
        )
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("limit reached"))
    }

    func testValidateChangeRequest_amendmentLimitExceeded_returnsError() {
        let team = makeTeam()
        let engineerRole = team.roles.first { $0.systemRoleID == "softwareEngineer" }!
        var step = StepExecution.make(for: engineerRole)
        step.status = .done
        step.amendments = [
            StepAmendment(requestedByRoleID: "cr", reason: "fix1"),
            StepAmendment(requestedByRoleID: "cr", reason: "fix2"),
        ]
        var settings = team.settings
        settings.limits = TeamLimits(maxAmendmentsPerStep: 2)
        let run = makeRun(steps: [step])
        let (error, _) = ChangeRequestService.validateChangeRequest(
            targetRoleID: engineerRole.id,
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: settings,
            run: run
        )
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("Amendment limit"))
    }

    func testValidateChangeRequest_targetNotFound_listsAvailableRoles() {
        let team = makeTeam()
        let run = makeRun(steps: [])
        let (error, roleDef) = ChangeRequestService.validateChangeRequest(
            targetRoleID: "totally_unknown_role_xyz",
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: team.settings,
            run: run
        )
        XCTAssertNil(roleDef)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("Available roles:"),
                      "Not-found error should list valid roles so the LLM can self-correct")
        XCTAssertTrue(error!.contains("Software Engineer"),
                      "Available-roles list should include the team's real role names")
    }

    /// Regression: an LLM emitting snake_case `software_engineer` must resolve through the
    /// normalized `findRole(byIdentifier:)` instead of failing with "not found".
    func testValidateChangeRequest_snakeCaseTarget_resolvesViaNormalizedFindRole() {
        let team = makeTeam()
        let engineerRole = team.roles.first { $0.systemRoleID == "softwareEngineer" }!
        var step = StepExecution.make(for: engineerRole)
        step.status = .done
        let run = makeRun(steps: [step])
        // The requester is the Code Reviewer, not the TPM: since 2026-09-11 a target must be
        // a DIRECT supplier of the requester, and the TPM reads the Code Review Summary, not
        // the Engineering Notes. Sending a repair past the role whose work you actually read
        // is what the rule forbids.
        let (error, roleDef) = ChangeRequestService.validateChangeRequest(
            targetRoleID: "software_engineer",
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: team.settings,
            run: run
        )
        XCTAssertNil(error, "snake_case target should resolve, not error")
        XCTAssertEqual(roleDef?.id, engineerRole.id)
    }

    // MARK: - The target must be a direct supplier

    /// A vote convenes the CONSUMERS of the target's artifact, and an approval propagates
    /// transitively. So a checker naming a role it does not read summons roles that have
    /// nothing to do with it, resets everything between, and — on a pipeline with one
    /// `ask_supervisor` holder — interrupts the human a second time. The requester may only
    /// send back work it actually read.
    ///
    /// RED: delete the direct-supplier guard from `validateChangeRequest` → the TPM's request
    /// against the Software Engineer validates, and the error below is nil.
    func testValidateChangeRequest_targetThatSuppliesNothingTheRequesterReads_isRefused() throws {
        let team = makeTeam()
        let engineerRole = try XCTUnwrap(team.roles.first { $0.systemRoleID == "softwareEngineer" })
        var step = StepExecution.make(for: engineerRole)
        step.status = .done

        let (error, roleDef) = ChangeRequestService.validateChangeRequest(
            targetRoleID: engineerRole.id,
            requestingRole: .tpm,          // reads the Code Review Summary, not the Notes
            team: team,
            teamSettings: team.settings,
            run: makeRun(steps: [step]))

        XCTAssertNil(roleDef)
        let message = try XCTUnwrap(error)
        XCTAssertTrue(message.contains("does not produce any artifact you require"), message)
        XCTAssertTrue(message.contains("Code Reviewer"),
                      "the refusal must name what the requester MAY ask, or it is a dead end: \(message)")
    }

    /// The other side of the same guard: a requester with no upstream at all is told so
    /// plainly instead of being handed an empty list of alternatives.
    func testValidateChangeRequest_requesterWithNoUpstream_isToldThereIsNobodyToAsk() throws {
        let supervisor = TeamRoleDefinition(
            id: "sup", name: "Supervisor", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Supervisor Task"]),
            systemRoleID: "supervisor")
        let first = TeamRoleDefinition(
            id: "first", name: "First", prompt: "p", toolIDs: [ToolNames.requestChanges],
            usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Thing"]))
        let second = TeamRoleDefinition(
            id: "second", name: "Second", prompt: "p", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Other"]))
        let team = Team(
            name: "NoUpstream", roles: [supervisor, first, second], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout())
        var step = StepExecution.make(for: second)
        step.status = .done

        let (error, _) = ChangeRequestService.validateChangeRequest(
            targetRoleID: "second", requestingRole: .custom(id: "First"),
            team: team, teamSettings: team.settings, run: makeRun(steps: [step]))

        let message = try XCTUnwrap(error)
        XCTAssertTrue(message.contains("no upstream role to ask"), message)
    }

    /// A requester the team does not know — a `Role` with no definition — cannot be judged by
    /// the graph, so the guard does not fire and the older checks decide. Silently refusing
    /// here would break every fixture that drives the service without a full roster.
    func testValidateChangeRequest_requesterNotInTheTeam_isNotJudgedByTheGraph() throws {
        let team = makeTeam()
        let engineerRole = try XCTUnwrap(team.roles.first { $0.systemRoleID == "softwareEngineer" })
        var step = StepExecution.make(for: engineerRole)
        step.status = .done

        let (error, roleDef) = ChangeRequestService.validateChangeRequest(
            targetRoleID: engineerRole.id,
            requestingRole: .custom(id: "Not On This Team"),
            team: team, teamSettings: team.settings, run: makeRun(steps: [step]))

        XCTAssertNil(error, "got: \(error ?? "")")
        XCTAssertEqual(roleDef?.id, engineerRole.id)
    }

    /// The available-roles hint lists real targets but excludes the Supervisor
    /// (user-controlled — never a valid change-request target).
    func testValidateChangeRequest_availableRolesExcludeSupervisor() {
        let team = makeTeam()
        let run = makeRun(steps: [])
        let (error, _) = ChangeRequestService.validateChangeRequest(
            targetRoleID: "totally_unknown_role_xyz",
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: team.settings,
            run: run
        )
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("Available roles:"))
        XCTAssertFalse(error!.contains("Supervisor"),
                       "Available-roles list must exclude the Supervisor")
    }

    // MARK: - buildVotingContext

    func testBuildVotingContext_formatsCorrectly() {
        let team = makeTeam()
        let engineerRole = team.roles.first { $0.systemRoleID == "softwareEngineer" }!
        let (topic, context) = ChangeRequestService.buildVotingContext(
            requestingRole: .codeReviewer,
            targetRoleDef: engineerRole,
            changes: "Fix null check",
            reasoning: "Missing edge case"
        )
        XCTAssertTrue(topic.contains("Code Reviewer"))
        XCTAssertTrue(topic.contains(engineerRole.name))
        XCTAssertTrue(context.contains("Fix null check"))
        XCTAssertTrue(context.contains("Missing edge case"))
        // The vote contract rides every turn's directive (recency slot), not the context —
        // a standing rule in a mid-conversation user turn sinks behind the transcript
        // (playbook R1.1.3); the context itself is lowercase prose with no bare colon label
        // (R1.3.2 / R4.3.2 — it opened with `CHANGE REQUEST DETAILS:` until 2026-09-07).
        XCTAssertFalse(context.contains("VOTE:"), context)
        XCTAssertFalse(context.contains("MUST"), context)
        let bareLabel = try! NSRegularExpression(pattern: #"^[A-Z][A-Za-z ]+:\s*$"#, options: [.anchorsMatchLines])
        XCTAssertNil(bareLabel.firstMatch(in: context, range: NSRange(context.startIndex..., in: context)),
                     "a bare `Label:` line is a second marker family in a `## ` wire: \(context)")
        let directive = MeetingCoordinator.turnDirective(
            speakerName: "SWE", turnNumber: 2, maxTurns: 6, isCoordinator: false,
            isDiscussionClub: false, votes: true)
        XCTAssertTrue(directive.contains("VOTE: APPROVE") && directive.contains("VOTE: REJECT"), directive)
        let plain = MeetingCoordinator.turnDirective(
            speakerName: "SWE", turnNumber: 2, maxTurns: 6, isCoordinator: false,
            isDiscussionClub: false)
        XCTAssertFalse(plain.contains("VOTE:"), "a discussion meeting carries no vote contract: \(plain)")
        // The TARGET is not asked for the ballot the tally would drop; it is asked to defend.
        let target = MeetingCoordinator.turnDirective(
            speakerName: "SWE", turnNumber: 2, maxTurns: 6, isCoordinator: false,
            isDiscussionClub: false, votes: true, speakerIsTarget: true)
        XCTAssertFalse(target.contains("VOTE:"), "the defendant reads no vote contract: \(target)")
        XCTAssertTrue(target.contains("you do not vote"), target)
        XCTAssertTrue(target.hasPrefix(plain), "the defence instruction rides the same base directive")
        // `speakerIsTarget` without `votes` is a discussion turn: no instruction of either kind.
        let notAVote = MeetingCoordinator.turnDirective(
            speakerName: "SWE", turnNumber: 2, maxTurns: 6, isCoordinator: false,
            isDiscussionClub: false, votes: false, speakerIsTarget: true)
        XCTAssertEqual(notAVote, plain)
    }

    // MARK: - Helpers

    private func makeMessage(_ role: Role, _ content: String) -> TeamMessage {
        TeamMessage(
            id: UUID(),
            createdAt: MonotonicClock.shared.now(),
            role: role,
            content: content,
            messageType: .discussion
        )
    }

    private func makeTeam() -> Team {
        Team.defaultTeams.first { $0.templateID == "faang" }!
    }

    private func makeRun(steps: [StepExecution]) -> Run {
        Run(id: 0, steps: steps)
    }
}
