import XCTest

@testable import NanoTeams

final class StepExecutionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - reset() (Round 4 regression)

    func testStepExecution_Reset_ClearsAllFields() {
        var step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Engineer Step",
            expectedArtifacts: ["Code"],
            status: .done,
            completedAt: MonotonicClock.shared.now(),
            messages: [StepMessage(role: .supervisor, content: "Old message")],
            artifacts: [Artifact(name: "Code", icon: "doc", mimeType: "text/plain", description: "")],
            toolCalls: [StepToolCall(name: "read_file", argumentsJSON: "{}")],
            workNotes: "Some notes",
            scratchpad: "## Plan\n- step 1",
            consultations: [
                TeammateConsultation(
                    id: UUID(),
                    createdAt: MonotonicClock.shared.now(),
                    requestingRole: .softwareEngineer,
                    consultedRole: .techLead,
                    question: "How?",
                    status: .completed
                ),
            ],
            meetingIDs: [UUID()],
            amendments: [
                StepAmendment(
                    requestedByRoleID: "cr",
                    reason: "Fix bug",
                    meetingDecision: "approved"
                ),
            ],
            needsSupervisorInput: true,
            supervisorQuestion: "Should I continue?",
            supervisorAnswer: "Yes",
            supervisorCommentForNext: "Good job",
            tokenUsage: TokenUsage(inputTokens: 100, outputTokens: 50),
            llmConversation: [LLMMessage(role: .user, content: "Hello")],
            llmSessionID: "session-123"
        )

        step.reset()

        XCTAssertEqual(step.status, .pending)
        XCTAssertNil(step.completedAt)
        XCTAssertTrue(step.messages.isEmpty)
        XCTAssertTrue(step.artifacts.isEmpty)
        XCTAssertTrue(step.toolCalls.isEmpty)
        XCTAssertNil(step.workNotes)
        XCTAssertNil(step.scratchpad)
        XCTAssertTrue(step.consultations.isEmpty)
        XCTAssertTrue(step.meetingIDs.isEmpty)
        XCTAssertTrue(step.amendments.isEmpty)
        XCTAssertFalse(step.needsSupervisorInput)
        XCTAssertNil(step.supervisorQuestion)
        XCTAssertNil(step.supervisorAnswer)
        XCTAssertNil(step.supervisorCommentForNext)
        XCTAssertNil(step.tokenUsage)
        XCTAssertTrue(step.llmConversation.isEmpty)
        XCTAssertNil(step.llmSessionID)

        // Identity fields preserved
        XCTAssertEqual(step.role, .softwareEngineer)
        XCTAssertEqual(step.id, "test_step")
        XCTAssertEqual(step.title, "Engineer Step")
        XCTAssertEqual(step.expectedArtifacts, ["Code"])
    }

    func testStepExecution_Reset_WithSupervisorComment() {
        var step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Engineer Step",
            status: .done,
            completedAt: MonotonicClock.shared.now(),
            scratchpad: "Old plan",
            tokenUsage: TokenUsage(inputTokens: 200, outputTokens: 100)
        )

        step.reset(supervisorComment: "Fix it")

        XCTAssertEqual(step.status, .pending)
        XCTAssertNil(step.completedAt)
        XCTAssertNil(step.scratchpad)
        XCTAssertNil(step.tokenUsage)
        XCTAssertEqual(step.messages.count, 1)
        XCTAssertEqual(step.messages[0].content, "Fix it")
        XCTAssertEqual(step.messages[0].role, .supervisor)
    }
}
