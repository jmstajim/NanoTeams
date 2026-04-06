import XCTest

@testable import NanoTeams

@MainActor
final class ChangeRequestVotingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Vote Tallying Tests

    func testTallyVotes_majorityApprove() {
        let messages = [
            TeamMessage(role: .softwareEngineer, content: "I agree with the changes. VOTE: APPROVE"),
            TeamMessage(role: .techLead, content: "Looks good to me. VOTE: APPROVE"),
            TeamMessage(role: .sre, content: "Not sure about this. VOTE: REJECT"),
        ]

        let result = ChangeRequestService.tallyVotes(meetingMessages: messages)
        XCTAssertEqual(result, .approved)
    }

    func testTallyVotes_majorityReject() {
        let messages = [
            TeamMessage(role: .softwareEngineer, content: "This doesn't make sense. VOTE: REJECT"),
            TeamMessage(role: .techLead, content: "I disagree. VOTE: REJECT"),
            TeamMessage(role: .sre, content: "I think it's good. VOTE: APPROVE"),
        ]

        let result = ChangeRequestService.tallyVotes(meetingMessages: messages)
        XCTAssertEqual(result, .rejected)
    }

    func testTallyVotes_tie() {
        let messages = [
            TeamMessage(role: .softwareEngineer, content: "I approve. VOTE: APPROVE"),
            TeamMessage(role: .techLead, content: "I reject. VOTE: REJECT"),
        ]

        let result = ChangeRequestService.tallyVotes(meetingMessages: messages)
        XCTAssertEqual(result, .tied)
    }

    func testTallyVotes_noVotes() {
        let messages = [
            TeamMessage(role: .softwareEngineer, content: "This is interesting, let me think about it."),
            TeamMessage(role: .techLead, content: "I need more context."),
        ]

        let result = ChangeRequestService.tallyVotes(meetingMessages: messages)
        XCTAssertEqual(result, .tied) // 0 == 0 → tied
    }

    func testTallyVotes_emptyMessages() {
        let result = ChangeRequestService.tallyVotes(meetingMessages: [])
        XCTAssertEqual(result, .tied)
    }

    func testTallyVotes_caseInsensitive() {
        let messages = [
            TeamMessage(role: .softwareEngineer, content: "vote: approve"),
            TeamMessage(role: .techLead, content: "Vote: Approve"),
            TeamMessage(role: .sre, content: "VOTE: REJECT"),
        ]

        let result = ChangeRequestService.tallyVotes(meetingMessages: messages)
        XCTAssertEqual(result, .approved)
    }

    func testTallyVotes_noSpaceVariant() {
        let messages = [
            TeamMessage(role: .softwareEngineer, content: "VOTE:APPROVE"),
            TeamMessage(role: .techLead, content: "VOTE:REJECT"),
            TeamMessage(role: .sre, content: "VOTE:APPROVE"),
        ]

        let result = ChangeRequestService.tallyVotes(meetingMessages: messages)
        XCTAssertEqual(result, .approved)
    }

    func testTallyVotes_voteInMiddleOfMessage() {
        let messages = [
            TeamMessage(role: .softwareEngineer, content: "After careful consideration, I think the changes are good. VOTE: APPROVE. That's my final answer."),
            TeamMessage(role: .techLead, content: "I have concerns about the approach. VOTE: REJECT. We should reconsider."),
        ]

        let result = ChangeRequestService.tallyVotes(meetingMessages: messages)
        XCTAssertEqual(result, .tied)
    }

    func testTallyVotes_onlyCountsOneVotePerMessage() {
        // A message with both APPROVE and REJECT — only the first match wins (else-if)
        let messages = [
            TeamMessage(role: .softwareEngineer, content: "VOTE: APPROVE but also VOTE: REJECT"),
        ]

        let result = ChangeRequestService.tallyVotes(meetingMessages: messages)
        // APPROVE branch checked first → 1 approve + 0 reject → approved
        XCTAssertEqual(result, .approved)
    }

    // MARK: - Role Tool Defaults Tests

    func testCodeReviewer_hasRequestChanges() {
        let tools = (SystemTemplates.fallbackToolIDs[Role.codeReviewer.baseID] ?? [])
        XCTAssertTrue(tools.contains("request_changes"))
    }

    func testSRE_hasRequestChanges() {
        let tools = (SystemTemplates.fallbackToolIDs[Role.sre.baseID] ?? [])
        XCTAssertTrue(tools.contains("request_changes"))
    }

    func testTechLead_hasAskSupervisor() {
        let tools = (SystemTemplates.fallbackToolIDs[Role.techLead.baseID] ?? [])
        XCTAssertTrue(tools.contains("ask_supervisor"))
        XCTAssertFalse(tools.contains("request_changes"))
    }

    func testTPM_hasRequestChanges() {
        let tools = (SystemTemplates.fallbackToolIDs[Role.tpm.baseID] ?? [])
        XCTAssertTrue(tools.contains("request_changes"))
        XCTAssertTrue(tools.contains("ask_teammate"))
        XCTAssertTrue(tools.contains("request_team_meeting"))
        XCTAssertFalse(tools.contains("read_lines"))
        XCTAssertFalse(tools.contains("update_scratchpad"))
    }

    func testSoftwareEngineer_doesNotHaveRequestChanges() {
        let tools = (SystemTemplates.fallbackToolIDs[Role.softwareEngineer.baseID] ?? [])
        XCTAssertFalse(tools.contains("request_changes"))
    }

    func testProductManager_doesNotHaveRequestChanges() {
        let tools = (SystemTemplates.fallbackToolIDs[Role.productManager.baseID] ?? [])
        XCTAssertFalse(tools.contains("request_changes"))
    }

    func testSupervisor_doesNotHaveRequestChanges() {
        let tools = (SystemTemplates.fallbackToolIDs[Role.supervisor.baseID] ?? [])
        XCTAssertFalse(tools.contains("request_changes"))
    }

    // MARK: - System Template Tests

    func testSystemTemplate_codeReviewer_hasRequestChanges() {
        let template = SystemTemplates.roles["codeReviewer"]
        XCTAssertNotNil(template)
        XCTAssertTrue(template!.toolIDs.contains("request_changes"))
    }

    func testSystemTemplate_sre_hasRequestChanges() {
        let template = SystemTemplates.roles["sre"]
        XCTAssertNotNil(template)
        XCTAssertTrue(template!.toolIDs.contains("request_changes"))
    }

    func testSystemTemplate_techLead_hasAskSupervisor() {
        let template = SystemTemplates.roles["techLead"]
        XCTAssertNotNil(template)
        XCTAssertTrue(template!.toolIDs.contains("ask_supervisor"))
        XCTAssertFalse(template!.toolIDs.contains("request_changes"))
    }

    func testSystemTemplate_tpm_hasRequestChanges() {
        let template = SystemTemplates.roles["tpm"]
        XCTAssertNotNil(template)
        XCTAssertTrue(template!.toolIDs.contains("request_changes"))
    }

    func testSystemTemplate_softwareEngineer_doesNotHaveRequestChanges() {
        let template = SystemTemplates.roles["softwareEngineer"]
        XCTAssertNotNil(template)
        XCTAssertFalse(template!.toolIDs.contains("request_changes"))
    }

    // MARK: - validateChangeRequest (Round 3)

    func testValidateChangeRequest_targetRoleNotFound_returnsError() {
        let team = Team(name: "T", roles: [], artifacts: [], settings: .default, graphLayout: .default)
        let run = Run(id: 0)

        let result = ChangeRequestService.validateChangeRequest(
            targetRoleID: "nonexistent",
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: .default,
            run: run
        )

        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("not found"))
        XCTAssertNil(result.targetRoleDef)
    }

    func testValidateChangeRequest_targetStepNotDone_returnsError() {
        let role = TeamRoleDefinition(
            id: "swe-id", name: "SWE", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Code"])
        )
        let team = Team(name: "T", roles: [role], artifacts: [], settings: .default, graphLayout: .default)
        let step = StepExecution(id: "swe-id", role: .softwareEngineer, title: "SWE Step", status: .running)
        let run = Run(id: 0, steps: [step])

        let result = ChangeRequestService.validateChangeRequest(
            targetRoleID: "swe-id",
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: .default,
            run: run
        )

        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("not completed"))
    }

    func testValidateChangeRequest_validRequest_returnsNilAndTargetDef() {
        let role = TeamRoleDefinition(
            id: "swe-id", name: "SWE", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Code"])
        )
        let team = Team(name: "T", roles: [role], artifacts: [], settings: .default, graphLayout: .default)
        let step = StepExecution(id: "swe-id", role: .softwareEngineer, title: "SWE Step", status: .done)
        let run = Run(id: 0, steps: [step])

        let result = ChangeRequestService.validateChangeRequest(
            targetRoleID: "swe-id",
            requestingRole: .codeReviewer,
            team: team,
            teamSettings: .default,
            run: run
        )

        XCTAssertNil(result.error)
        XCTAssertEqual(result.targetRoleDef?.id, "swe-id")
    }
}
