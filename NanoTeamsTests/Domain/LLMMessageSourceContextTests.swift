import XCTest
@testable import NanoTeams

/// Tests for LLMMessage.sourceContext and sourceRole Codable round-trips
/// and StepExecution nested arrays (consultations, meetingIDs, llmConversation).
final class LLMMessageSourceContextTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - MessageSourceContext Codable

    func testMessageSourceContext_Consultation_CodableRoundTrip() throws {
        let original: MessageSourceContext = .consultation
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MessageSourceContext.self, from: encoded)
        XCTAssertEqual(decoded, .consultation)
    }

    func testMessageSourceContext_Meeting_CodableRoundTrip() throws {
        let original: MessageSourceContext = .meeting
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MessageSourceContext.self, from: encoded)
        XCTAssertEqual(decoded, .meeting)
    }

    func testMessageSourceContext_RawValues() {
        XCTAssertEqual(MessageSourceContext.consultation.rawValue, "consultation")
        XCTAssertEqual(MessageSourceContext.meeting.rawValue, "meeting")
    }

    // MARK: - LLMMessage with sourceContext + sourceRole

    func testLLMMessage_WithSourceContext_CodableRoundTrip() throws {
        let original = LLMMessage(
            role: .user,
            content: "Here is my review of the plan.",
            sourceRole: .uxDesigner,
            sourceContext: .consultation
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, .user)
        XCTAssertEqual(decoded.content, "Here is my review of the plan.")
        XCTAssertEqual(decoded.sourceRole, .uxDesigner)
        XCTAssertEqual(decoded.sourceContext, .consultation)
    }

    func testLLMMessage_WithMeetingContext_CodableRoundTrip() throws {
        let original = LLMMessage(
            role: .user,
            content: "Meeting discussion point",
            sourceRole: .tpm,
            sourceContext: .meeting
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)

        XCTAssertEqual(decoded.sourceRole, .tpm)
        XCTAssertEqual(decoded.sourceContext, .meeting)
    }

    func testLLMMessage_WithoutSourceContext_DecodesAsNil() throws {
        // Backward compatibility: old JSON without sourceContext/sourceRole
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440001",
            "role": "assistant",
            "content": "Hello from the assistant"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LLMMessage.self, from: json)

        XCTAssertNil(decoded.sourceRole)
        XCTAssertNil(decoded.sourceContext)
        XCTAssertEqual(decoded.role, .assistant)
        XCTAssertEqual(decoded.content, "Hello from the assistant")
    }

    func testLLMMessage_WithThinking_CodableRoundTrip() throws {
        let original = LLMMessage(
            role: .assistant,
            content: "Final answer",
            thinking: "Let me reason through this..."
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)

        XCTAssertEqual(decoded.thinking, "Let me reason through this...")
        XCTAssertNil(decoded.sourceRole)
        XCTAssertNil(decoded.sourceContext)
    }

    func testLLMMessage_WithCustomRole_CodableRoundTrip() throws {
        let original = LLMMessage(
            role: .user,
            content: "Custom role response",
            sourceRole: .custom(id: "dataScientist"),
            sourceContext: .consultation
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)

        XCTAssertEqual(decoded.sourceRole, .custom(id: "dataScientist"))
    }

    // MARK: - StepExecution with Nested Arrays

    func testStepExecution_WithConsultations_CodableRoundTrip() throws {
        let consultation = TeammateConsultation(
            requestingRole: .softwareEngineer,
            consultedRole: .uxDesigner,
            question: "How should the UI look?",
            response: "Use glassmorphism.",
            status: .completed
        )
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Engineer Step",
            consultations: [consultation]
        )

        let encoded = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(StepExecution.self, from: encoded)

        XCTAssertEqual(decoded.consultations.count, 1)
        XCTAssertEqual(decoded.consultations.first?.consultedRole, .uxDesigner)
        XCTAssertEqual(decoded.consultations.first?.response, "Use glassmorphism.")
        XCTAssertEqual(decoded.consultations.first?.status, .completed)
    }

    func testStepExecution_WithMeetingIDs_CodableRoundTrip() throws {
        let meetingID1 = UUID()
        let meetingID2 = UUID()
        let step = StepExecution(
            id: "test_step",
            role: .tpm,
            title: "PM Step",
            meetingIDs: [meetingID1, meetingID2]
        )

        let encoded = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(StepExecution.self, from: encoded)

        XCTAssertEqual(decoded.meetingIDs.count, 2)
        XCTAssertTrue(decoded.meetingIDs.contains(meetingID1))
        XCTAssertTrue(decoded.meetingIDs.contains(meetingID2))
    }

    func testStepExecution_WithLLMConversation_CodableRoundTrip() throws {
        let messages = [
            LLMMessage(role: .system, content: "You are a PM."),
            LLMMessage(role: .user, content: "Here is the task."),
            LLMMessage(role: .assistant, content: "I will create a plan."),
            LLMMessage(
                role: .user,
                content: "Designer perspective on UI",
                sourceRole: .uxDesigner,
                sourceContext: .consultation
            )
        ]
        let step = StepExecution(
            id: "test_step",
            role: .tpm,
            title: "PM Step",
            llmConversation: messages
        )

        let encoded = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(StepExecution.self, from: encoded)

        XCTAssertEqual(decoded.llmConversation.count, 4)

        // Verify the consultation message preserved sourceRole/sourceContext
        let consultationMsg = decoded.llmConversation[3]
        XCTAssertEqual(consultationMsg.sourceRole, .uxDesigner)
        XCTAssertEqual(consultationMsg.sourceContext, .consultation)
    }

    func testStepExecution_BackwardCompatibility_NoOptionalFields() throws {
        let json = """
        {
            "id": "legacy_step",
            "role": "softwareEngineer",
            "title": "Legacy Step",
            "status": "done"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(StepExecution.self, from: json)

        XCTAssertTrue(decoded.consultations.isEmpty)
        XCTAssertTrue(decoded.meetingIDs.isEmpty)
        XCTAssertTrue(decoded.llmConversation.isEmpty)
        XCTAssertNil(decoded.scratchpad)
        XCTAssertFalse(decoded.needsSupervisorInput)
    }

    // MARK: - Run.teamID Preservation

    func testRun_TeamID_CodableRoundTrip() throws {
        let teamID: NTMSID = "test_team"
        let run = Run(id: 0, teamID: teamID)

        let encoded = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(Run.self, from: encoded)

        XCTAssertEqual(decoded.teamID, teamID)
    }

    func testRun_TeamID_BackwardCompatibility() throws {
        let json = """
        {
            "id": 0,
            "mode": "manual"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Run.self, from: json)

        XCTAssertNil(decoded.teamID)
    }
}
