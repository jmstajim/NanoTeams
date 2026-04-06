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
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: messages), .approved)
    }

    func testTallyVotes_moreRejects_returnsRejected() {
        let messages = [
            makeMessage(.techLead, "Not needed. VOTE: REJECT"),
            makeMessage(.softwareEngineer, "Too risky. VOTE: REJECT"),
            makeMessage(.codeReviewer, "VOTE: APPROVE"),
        ]
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: messages), .rejected)
    }

    func testTallyVotes_equalVotes_returnsTied() {
        let messages = [
            makeMessage(.techLead, "VOTE: APPROVE"),
            makeMessage(.softwareEngineer, "VOTE: REJECT"),
        ]
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: messages), .tied)
    }

    func testTallyVotes_noVotes_returnsTied() {
        let messages = [
            makeMessage(.techLead, "Let me think about it..."),
            makeMessage(.softwareEngineer, "I'm not sure either"),
        ]
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: messages), .tied)
    }

    func testTallyVotes_emptyMessages_returnsTied() {
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: []), .tied)
    }

    func testTallyVotes_voteWithoutSpace_counted() {
        let messages = [
            makeMessage(.techLead, "VOTE:APPROVE"),
        ]
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: messages), .approved)
    }

    func testTallyVotes_caseInsensitiveContent() {
        // The content is uppercased in the code, so mixed case should work
        let messages = [
            makeMessage(.techLead, "I think this is fine. Vote: Approve"),
        ]
        XCTAssertEqual(ChangeRequestService.tallyVotes(meetingMessages: messages), .approved)
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
        XCTAssertTrue(context.contains("VOTE: APPROVE"))
        XCTAssertTrue(context.contains("VOTE: REJECT"))
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
