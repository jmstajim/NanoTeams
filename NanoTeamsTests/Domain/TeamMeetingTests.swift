import XCTest

@testable import NanoTeams

final class TeamMeetingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - TeamMeeting Initialization Tests

    func testTeamMeeting_initialization() {
        let meeting = TeamMeeting(
            topic: "Architecture Review",
            initiatedBy: .softwareEngineer,
            participants: [.uxDesigner, .tpm]
        )

        XCTAssertEqual(meeting.topic, "Architecture Review")
        XCTAssertEqual(meeting.initiatedBy, .softwareEngineer)
        XCTAssertEqual(meeting.participants, [.uxDesigner, .tpm])
        XCTAssertNil(meeting.context)
        XCTAssertTrue(meeting.messages.isEmpty)
        XCTAssertTrue(meeting.decisions.isEmpty)
        XCTAssertEqual(meeting.status, .pending)
    }

    func testTeamMeeting_initializationWithAllFields() {
        let id = UUID()
        let createdAt = Date()

        let meeting = TeamMeeting(
            id: id,
            createdAt: createdAt,
            topic: "Sprint Planning",
            initiatedBy: .tpm,
            participants: [.productManager, .softwareEngineer],
            context: "Q2 priorities",
            status: .inProgress
        )

        XCTAssertEqual(meeting.id, id)
        XCTAssertEqual(meeting.createdAt, createdAt)
        XCTAssertEqual(meeting.topic, "Sprint Planning")
        XCTAssertEqual(meeting.context, "Q2 priorities")
        XCTAssertEqual(meeting.status, .inProgress)
    }

    // MARK: - TeamMeeting Codable Tests

    func testTeamMeeting_codable() throws {
        let original = TeamMeeting(
            topic: "Test Meeting",
            initiatedBy: .tpm,
            participants: [.uxDesigner, .softwareEngineer],
            context: "Test context",
            status: .completed
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TeamMeeting.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.topic, original.topic)
        XCTAssertEqual(decoded.initiatedBy, original.initiatedBy)
        XCTAssertEqual(decoded.participants, original.participants)
        XCTAssertEqual(decoded.context, original.context)
        XCTAssertEqual(decoded.status, original.status)
    }

    func testTeamMeeting_codable_backwardsCompatibility() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "topic": "Legacy Meeting",
            "initiatedBy": "tpm",
            "participants": ["uxDesigner"]
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TeamMeeting.self, from: data)

        XCTAssertEqual(decoded.status, .pending)  // Default
        XCTAssertNil(decoded.context)
        XCTAssertTrue(decoded.messages.isEmpty)
        XCTAssertTrue(decoded.decisions.isEmpty)
    }

    // MARK: - TeamMeeting Helper Methods Tests

    func testTeamMeeting_addMessage() {
        var meeting = TeamMeeting(
            topic: "Test",
            initiatedBy: .tpm,
            participants: [.uxDesigner]
        )
        let originalUpdatedAt = meeting.updatedAt

        let message = TeamMessage(
            role: .uxDesigner,
            content: "I suggest using blue",
            messageType: .proposal
        )

        // Small delay to ensure updatedAt changes
        Thread.sleep(forTimeInterval: 0.01)

        meeting.addMessage(message)

        XCTAssertEqual(meeting.messages.count, 1)
        XCTAssertEqual(meeting.messages[0].content, "I suggest using blue")
        XCTAssertGreaterThan(meeting.updatedAt, originalUpdatedAt)
    }

    func testTeamMeeting_addDecision() {
        var meeting = TeamMeeting(
            topic: "Test",
            initiatedBy: .tpm,
            participants: [.uxDesigner]
        )

        let decision = TeamDecision(
            summary: "Use blue color scheme",
            proposedBy: .uxDesigner,
            agreedBy: [.tpm]
        )

        meeting.addDecision(decision)

        XCTAssertEqual(meeting.decisions.count, 1)
        XCTAssertEqual(meeting.decisions[0].summary, "Use blue color scheme")
    }

    func testTeamMeeting_start() {
        var meeting = TeamMeeting(
            topic: "Test",
            initiatedBy: .tpm,
            participants: [.uxDesigner]
        )

        XCTAssertEqual(meeting.status, .pending)

        meeting.start()

        XCTAssertEqual(meeting.status, .inProgress)
    }

    func testTeamMeeting_complete() {
        var meeting = TeamMeeting(
            topic: "Test",
            initiatedBy: .tpm,
            participants: [.uxDesigner],
            status: .inProgress
        )

        meeting.complete()

        XCTAssertEqual(meeting.status, .completed)
    }

    func testTeamMeeting_escalateToSupervisor() {
        var meeting = TeamMeeting(
            topic: "Test",
            initiatedBy: .tpm,
            participants: [.uxDesigner],
            status: .inProgress
        )

        meeting.escalateToSupervisor()

        XCTAssertEqual(meeting.status, .escalatedToSupervisor)
    }

    func testTeamMeeting_cancel() {
        var meeting = TeamMeeting(
            topic: "Test",
            initiatedBy: .tpm,
            participants: [.uxDesigner]
        )

        meeting.cancel()

        XCTAssertEqual(meeting.status, .cancelled)
    }

    func testTeamMeeting_turnCount() {
        var meeting = TeamMeeting(
            topic: "Test",
            initiatedBy: .tpm,
            participants: [.uxDesigner]
        )

        XCTAssertEqual(meeting.turnCount, 0)

        meeting.addMessage(TeamMessage(role: .uxDesigner, content: "Message 1"))
        XCTAssertEqual(meeting.turnCount, 1)

        meeting.addMessage(TeamMessage(role: .tpm, content: "Message 2"))
        XCTAssertEqual(meeting.turnCount, 2)
    }

    func testTeamMeeting_messagesFromRole() {
        var meeting = TeamMeeting(
            topic: "Test",
            initiatedBy: .tpm,
            participants: [.uxDesigner, .softwareEngineer]
        )

        meeting.addMessage(TeamMessage(role: .uxDesigner, content: "Designer message 1"))
        meeting.addMessage(TeamMessage(role: .softwareEngineer, content: "Engineer message"))
        meeting.addMessage(TeamMessage(role: .uxDesigner, content: "Designer message 2"))

        let designerMessages = meeting.messages(from: .uxDesigner)

        XCTAssertEqual(designerMessages.count, 2)
        XCTAssertTrue(designerMessages.allSatisfy { $0.role == .uxDesigner })
    }

    func testTeamMeeting_hasParticipated() {
        var meeting = TeamMeeting(
            topic: "Test",
            initiatedBy: .tpm,
            participants: [.uxDesigner, .softwareEngineer]
        )

        XCTAssertFalse(meeting.hasParticipated(.uxDesigner))

        meeting.addMessage(TeamMessage(role: .uxDesigner, content: "Hello"))

        XCTAssertTrue(meeting.hasParticipated(.uxDesigner))
        XCTAssertFalse(meeting.hasParticipated(.softwareEngineer))
    }

    // MARK: - TeamMessage Tests

    func testTeamMessage_initialization() {
        let message = TeamMessage(
            role: .uxDesigner,
            content: "Test message"
        )

        XCTAssertEqual(message.role, .uxDesigner)
        XCTAssertEqual(message.content, "Test message")
        XCTAssertNil(message.replyToID)
        XCTAssertEqual(message.messageType, .discussion)
    }

    func testTeamMessage_initializationWithAllFields() {
        let replyID = UUID()
        let message = TeamMessage(
            role: .tpm,
            content: "Good point",
            replyToID: replyID,
            messageType: .agreement
        )

        XCTAssertEqual(message.replyToID, replyID)
        XCTAssertEqual(message.messageType, .agreement)
    }

    func testTeamMessage_codable() throws {
        let original = TeamMessage(
            role: .uxDesigner,
            content: "Test",
            messageType: .proposal
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TeamMessage.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.content, original.content)
        XCTAssertEqual(decoded.messageType, original.messageType)
    }

    // MARK: - TeamMessageType Tests

    func testTeamMessageType_allCases() {
        let types: [TeamMessageType] = [
            .discussion, .question, .proposal,
            .objection, .agreement, .summary, .conclusion
        ]

        for type in types {
            let encoded = try! JSONEncoder().encode(type)
            let decoded = try! JSONDecoder().decode(TeamMessageType.self, from: encoded)
            XCTAssertEqual(decoded, type)
        }
    }

    // MARK: - TeamDecision Tests

    func testTeamDecision_initialization() {
        let decision = TeamDecision(
            summary: "Use React",
            proposedBy: .softwareEngineer
        )

        XCTAssertEqual(decision.summary, "Use React")
        XCTAssertEqual(decision.proposedBy, .softwareEngineer)
        XCTAssertNil(decision.rationale)
        XCTAssertTrue(decision.agreedBy.isEmpty)
        XCTAssertTrue(decision.nextSteps.isEmpty)
    }

    func testTeamDecision_initializationWithAllFields() {
        let decision = TeamDecision(
            summary: "Adopt microservices",
            rationale: "Better scalability",
            proposedBy: .softwareEngineer,
            agreedBy: [.tpm, .productManager],
            nextSteps: ["Design API contracts", "Set up CI/CD"]
        )

        XCTAssertEqual(decision.rationale, "Better scalability")
        XCTAssertEqual(decision.agreedBy.count, 2)
        XCTAssertEqual(decision.nextSteps.count, 2)
    }

    func testTeamDecision_codable() throws {
        let original = TeamDecision(
            summary: "Test decision",
            rationale: "Because",
            proposedBy: .uxDesigner,
            agreedBy: [.tpm],
            nextSteps: ["Step 1"]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TeamDecision.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.summary, original.summary)
        XCTAssertEqual(decoded.rationale, original.rationale)
        XCTAssertEqual(decoded.proposedBy, original.proposedBy)
        XCTAssertEqual(decoded.agreedBy, original.agreedBy)
        XCTAssertEqual(decoded.nextSteps, original.nextSteps)
    }

    // MARK: - MeetingStatus Tests

    func testMeetingStatus_displayName() {
        XCTAssertEqual(MeetingStatus.pending.displayName, "Pending")
        XCTAssertEqual(MeetingStatus.inProgress.displayName, "In Progress")
        XCTAssertEqual(MeetingStatus.completed.displayName, "Completed")
        XCTAssertEqual(MeetingStatus.escalatedToSupervisor.displayName, "Escalated to Supervisor")
        XCTAssertEqual(MeetingStatus.cancelled.displayName, "Cancelled")
    }

    func testMeetingStatus_icon() {
        XCTAssertEqual(MeetingStatus.pending.icon, "clock")
        XCTAssertEqual(MeetingStatus.inProgress.icon, "person.3.fill")
        XCTAssertEqual(MeetingStatus.completed.icon, "checkmark.circle")
        XCTAssertEqual(MeetingStatus.escalatedToSupervisor.icon, "exclamationmark.triangle")
        XCTAssertEqual(MeetingStatus.cancelled.icon, "xmark.circle")
    }

    func testMeetingStatus_isActive() {
        XCTAssertTrue(MeetingStatus.pending.isActive)
        XCTAssertTrue(MeetingStatus.inProgress.isActive)
        XCTAssertFalse(MeetingStatus.completed.isActive)
        XCTAssertFalse(MeetingStatus.escalatedToSupervisor.isActive)
        XCTAssertFalse(MeetingStatus.cancelled.isActive)
    }

    // MARK: - Hashable Tests

    func testTeamMeeting_hashable() {
        let id = UUID()
        let meeting1 = TeamMeeting(
            id: id,
            topic: "Test",
            initiatedBy: .tpm,
            participants: [.uxDesigner]
        )

        let meeting2 = TeamMeeting(
            id: id,
            topic: "Test",
            initiatedBy: .tpm,
            participants: [.uxDesigner]
        )

        XCTAssertEqual(meeting1.hashValue, meeting2.hashValue)

        var set = Set<TeamMeeting>()
        set.insert(meeting1)
        XCTAssertTrue(set.contains(meeting2))
    }

    func testTeamMessage_hashable() {
        let id = UUID()
        let msg1 = TeamMessage(id: id, role: .uxDesigner, content: "Test")
        let msg2 = TeamMessage(id: id, role: .uxDesigner, content: "Test")

        XCTAssertEqual(msg1.hashValue, msg2.hashValue)
    }

    func testTeamDecision_hashable() {
        let id = UUID()
        let dec1 = TeamDecision(id: id, summary: "Test", proposedBy: .uxDesigner)
        let dec2 = TeamDecision(id: id, summary: "Test", proposedBy: .uxDesigner)

        XCTAssertEqual(dec1.hashValue, dec2.hashValue)
    }

    // MARK: - MeetingToolSummary Tests

    func testMeetingToolSummary_initialization() {
        let summary = MeetingToolSummary(
            toolName: "read_file",
            arguments: "{\"path\": \"src/main.swift\"}",
            result: "File content here",
            isError: false
        )

        XCTAssertEqual(summary.toolName, "read_file")
        XCTAssertEqual(summary.arguments, "{\"path\": \"src/main.swift\"}")
        XCTAssertEqual(summary.result, "File content here")
        XCTAssertFalse(summary.isError)
    }

    func testMeetingToolSummary_codable() throws {
        let original = MeetingToolSummary(
            toolName: "search",
            arguments: "{\"query\": \"TODO\"}",
            result: "Found 3 matches",
            isError: false
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeetingToolSummary.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.toolName, original.toolName)
        XCTAssertEqual(decoded.arguments, original.arguments)
        XCTAssertEqual(decoded.result, original.result)
        XCTAssertEqual(decoded.isError, original.isError)
    }

    func testMeetingToolSummary_withError() {
        let summary = MeetingToolSummary(
            toolName: "read_file",
            arguments: "{\"path\": \"nonexistent.swift\"}",
            result: "File not found",
            isError: true
        )

        XCTAssertTrue(summary.isError)
    }

    func testMeetingToolSummary_hashable() {
        let id = UUID()
        let date = Date()
        let s1 = MeetingToolSummary(id: id, createdAt: date, toolName: "a", arguments: "", result: "")
        let s2 = MeetingToolSummary(id: id, createdAt: date, toolName: "a", arguments: "", result: "")

        XCTAssertEqual(s1, s2)
        XCTAssertEqual(s1.hashValue, s2.hashValue)
    }

    // MARK: - TeamMessage with Thinking/ToolSummaries

    func testTeamMessage_withThinking() {
        let message = TeamMessage(
            role: .softwareEngineer,
            content: "I suggest using microservices",
            messageType: .proposal,
            thinking: "Let me consider the architecture options..."
        )

        XCTAssertEqual(message.thinking, "Let me consider the architecture options...")
        XCTAssertNil(message.toolSummaries)
    }

    func testTeamMessage_withToolSummaries() {
        let toolSummaries = [
            MeetingToolSummary(toolName: "read_file", arguments: "{}", result: "content", isError: false),
            MeetingToolSummary(toolName: "list_files", arguments: "{}", result: "files", isError: false)
        ]
        let message = TeamMessage(
            role: .softwareEngineer,
            content: "After reviewing the code...",
            toolSummaries: toolSummaries
        )

        XCTAssertEqual(message.toolSummaries?.count, 2)
        XCTAssertEqual(message.toolSummaries?[0].toolName, "read_file")
    }

    func testTeamMessage_codable_withThinkingAndTools() throws {
        let toolSummaries = [
            MeetingToolSummary(toolName: "read_file", arguments: "{\"path\":\"a.swift\"}", result: "code", isError: false)
        ]
        let original = TeamMessage(
            role: .uxDesigner,
            content: "Based on the code...",
            messageType: .proposal,
            thinking: "I need to check the codebase first",
            toolSummaries: toolSummaries
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TeamMessage.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.thinking, "I need to check the codebase first")
        XCTAssertEqual(decoded.toolSummaries?.count, 1)
        XCTAssertEqual(decoded.toolSummaries?[0].toolName, "read_file")
    }

    func testTeamMessage_codable_backwardsCompatibility_missingThinkingAndTools() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "role": "uxDesigner",
            "content": "Old message without thinking",
            "messageType": "discussion"
        }
        """

        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TeamMessage.self, from: data)

        XCTAssertEqual(decoded.content, "Old message without thinking")
        XCTAssertNil(decoded.thinking)
        XCTAssertNil(decoded.toolSummaries)
    }
}
