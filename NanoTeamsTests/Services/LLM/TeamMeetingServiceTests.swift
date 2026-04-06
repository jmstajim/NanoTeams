import XCTest
@testable import NanoTeams

final class TeamMeetingServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - createMeeting Tests

    func testCreateMeeting_CreatesWithCorrectValues() {
        let meeting = TeamMeetingService.createMeeting(
            topic: "Architecture discussion",
            initiatedBy: .softwareEngineer,
            participants: [.productManager, .tpm, .softwareEngineer],
            context: "Need to decide on database approach"
        )

        XCTAssertEqual(meeting.topic, "Architecture discussion")
        XCTAssertEqual(meeting.initiatedBy, .softwareEngineer)
        XCTAssertEqual(meeting.participants.count, 3)
        XCTAssertTrue(meeting.participants.contains(.productManager))
        XCTAssertTrue(meeting.participants.contains(.tpm))
        XCTAssertTrue(meeting.participants.contains(.softwareEngineer))
        XCTAssertEqual(meeting.context, "Need to decide on database approach")
        XCTAssertEqual(meeting.status, .pending)
        XCTAssertTrue(meeting.messages.isEmpty)
        XCTAssertTrue(meeting.decisions.isEmpty)
    }

    func testCreateMeeting_WithoutContext_CreatesCorrectly() {
        let meeting = TeamMeetingService.createMeeting(
            topic: "Sprint planning",
            initiatedBy: .tpm,
            participants: [.uxDesigner, .softwareEngineer, .sre],
            context: nil
        )

        XCTAssertEqual(meeting.topic, "Sprint planning")
        XCTAssertEqual(meeting.initiatedBy, .tpm)
        XCTAssertNil(meeting.context)
        XCTAssertEqual(meeting.status, .pending)
    }

    // MARK: - hasReachedMeetingLimit Tests

    func testHasReachedMeetingLimit_WithinLimit_ReturnsFalse() {
        let meetings = createMeetings(count: 2)
        let limits = TeamLimits(maxMeetingsPerRun: 3)

        let result = TeamMeetingService.hasReachedMeetingLimit(
            meetings: meetings,
            limits: limits
        )

        XCTAssertFalse(result)
    }

    func testHasReachedMeetingLimit_AtLimit_ReturnsTrue() {
        let meetings = createMeetings(count: 3)
        let limits = TeamLimits(maxMeetingsPerRun: 3)

        let result = TeamMeetingService.hasReachedMeetingLimit(
            meetings: meetings,
            limits: limits
        )

        XCTAssertTrue(result)
    }

    func testHasReachedMeetingLimit_OverLimit_ReturnsTrue() {
        let meetings = createMeetings(count: 5)
        let limits = TeamLimits(maxMeetingsPerRun: 3)

        let result = TeamMeetingService.hasReachedMeetingLimit(
            meetings: meetings,
            limits: limits
        )

        XCTAssertTrue(result)
    }

    func testHasReachedMeetingLimit_EmptyMeetings_ReturnsFalse() {
        let meetings: [TeamMeeting] = []
        let limits = TeamLimits(maxMeetingsPerRun: 3)

        let result = TeamMeetingService.hasReachedMeetingLimit(
            meetings: meetings,
            limits: limits
        )

        XCTAssertFalse(result)
    }

    // MARK: - hasReachedTurnLimit Tests

    func testHasReachedTurnLimit_WithinLimit_ReturnsFalse() {
        var meeting = createBasicMeeting()
        addMessages(to: &meeting, count: 5)
        let limits = TeamLimits(maxMeetingTurns: 10)

        let result = TeamMeetingService.hasReachedTurnLimit(
            meeting: meeting,
            limits: limits
        )

        XCTAssertFalse(result)
    }

    func testHasReachedTurnLimit_AtLimit_ReturnsTrue() {
        var meeting = createBasicMeeting()
        addMessages(to: &meeting, count: 10)
        let limits = TeamLimits(maxMeetingTurns: 10)

        let result = TeamMeetingService.hasReachedTurnLimit(
            meeting: meeting,
            limits: limits
        )

        XCTAssertTrue(result)
    }

    func testHasReachedTurnLimit_OverLimit_ReturnsTrue() {
        var meeting = createBasicMeeting()
        addMessages(to: &meeting, count: 15)
        let limits = TeamLimits(maxMeetingTurns: 10)

        let result = TeamMeetingService.hasReachedTurnLimit(
            meeting: meeting,
            limits: limits
        )

        XCTAssertTrue(result)
    }

    func testHasReachedTurnLimit_NoMessages_ReturnsFalse() {
        let meeting = createBasicMeeting()
        let limits = TeamLimits(maxMeetingTurns: 10)

        let result = TeamMeetingService.hasReachedTurnLimit(
            meeting: meeting,
            limits: limits
        )

        XCTAssertFalse(result)
    }

    // MARK: - concludeMeeting Tests

    func testConcludeMeeting_SetsDecisionAndStatus() {
        var meeting = createBasicMeeting()
        meeting.start()
        addMessages(to: &meeting, count: 3)

        TeamMeetingService.concludeMeeting(
            meeting: &meeting,
            decision: "Use microservices architecture",
            rationale: "Better scalability and team familiarity",
            nextSteps: "Engineer starts with API gateway\nDesigner updates mockups",
            concludedBy: .tpm
        )

        XCTAssertEqual(meeting.status, .completed)
        XCTAssertEqual(meeting.decisions.count, 1)

        let decision = meeting.decisions.first!
        XCTAssertEqual(decision.summary, "Use microservices architecture")
        XCTAssertEqual(decision.rationale, "Better scalability and team familiarity")
        XCTAssertEqual(decision.proposedBy, .tpm)
        XCTAssertEqual(decision.nextSteps.count, 2)
        XCTAssertTrue(decision.nextSteps.contains("Engineer starts with API gateway"))
        XCTAssertTrue(decision.nextSteps.contains("Designer updates mockups"))
    }

    func testConcludeMeeting_WithoutRationale_SetsCorrectly() {
        var meeting = createBasicMeeting()
        meeting.start()

        TeamMeetingService.concludeMeeting(
            meeting: &meeting,
            decision: "Proceed with current approach",
            rationale: nil,
            nextSteps: nil,
            concludedBy: .tpm
        )

        XCTAssertEqual(meeting.status, .completed)
        XCTAssertEqual(meeting.decisions.count, 1)

        let decision = meeting.decisions.first!
        XCTAssertEqual(decision.summary, "Proceed with current approach")
        XCTAssertNil(decision.rationale)
        XCTAssertTrue(decision.nextSteps.isEmpty)
    }

    func testConcludeMeeting_SetsAgreedByToParticipants() {
        var meeting = TeamMeetingService.createMeeting(
            topic: "Test topic",
            initiatedBy: .softwareEngineer,
            participants: [.uxDesigner, .softwareEngineer, .sre],
            context: nil
        )
        meeting.start()

        TeamMeetingService.concludeMeeting(
            meeting: &meeting,
            decision: "Agreed decision",
            rationale: nil,
            nextSteps: nil,
            concludedBy: .tpm
        )

        let decision = meeting.decisions.first!
        XCTAssertEqual(decision.agreedBy.count, 3)
        XCTAssertTrue(decision.agreedBy.contains(.uxDesigner))
        XCTAssertTrue(decision.agreedBy.contains(.softwareEngineer))
        XCTAssertTrue(decision.agreedBy.contains(.sre))
    }

    // MARK: - generateMeetingSummary Tests

    func testGenerateMeetingSummary_IncludesBasicInfo() {
        var meeting = createBasicMeeting()
        addMessages(to: &meeting, count: 3)
        meeting.complete()

        let summary = TeamMeetingService.generateMeetingSummary(meeting: meeting)

        XCTAssertTrue(summary.contains("Test Topic"))
        XCTAssertTrue(summary.contains("Completed"))
        XCTAssertTrue(summary.contains("Messages: 3"))
    }

    func testGenerateMeetingSummary_IncludesDecisions() {
        var meeting = createBasicMeeting()
        meeting.start()
        TeamMeetingService.concludeMeeting(
            meeting: &meeting,
            decision: "Use REST API",
            rationale: "Simpler implementation",
            nextSteps: "Start implementation\nWrite tests",
            concludedBy: .tpm
        )

        let summary = TeamMeetingService.generateMeetingSummary(meeting: meeting)

        XCTAssertTrue(summary.contains("Decisions:"))
        XCTAssertTrue(summary.contains("Use REST API"))
        XCTAssertTrue(summary.contains("Simpler implementation"))
        XCTAssertTrue(summary.contains("Start implementation"))
    }

    func testGenerateMeetingSummary_WithNoDecisions_OmitsDecisionSection() {
        let meeting = createBasicMeeting()

        let summary = TeamMeetingService.generateMeetingSummary(meeting: meeting)

        XCTAssertFalse(summary.contains("Decisions:"))
    }

    // MARK: - generateMeetingResultForConversation Tests

    func testGenerateMeetingResultForConversation_WithDecision_IncludesDecision() {
        var meeting = createBasicMeeting()
        meeting.start()
        TeamMeetingService.concludeMeeting(
            meeting: &meeting,
            decision: "Implement caching layer",
            rationale: "Performance improvement needed",
            nextSteps: "Engineer implements Redis cache",
            concludedBy: .tpm
        )

        let result = TeamMeetingService.generateMeetingResultForConversation(meeting: meeting)

        XCTAssertTrue(result.contains("Team Meeting Result"))
        XCTAssertTrue(result.contains("Decision: Implement caching layer"))
        XCTAssertTrue(result.contains("Rationale: Performance improvement needed"))
        XCTAssertTrue(result.contains("Engineer implements Redis cache"))
    }

    func testGenerateMeetingResultForConversation_WithoutDecision_IncludesKeyPoints() {
        var meeting = createBasicMeeting()
        meeting.start()

        // Add proposal and agreement messages
        meeting.addMessage(TeamMessage(
            role: .softwareEngineer,
            content: "I suggest we use GraphQL for the API",
            messageType: .proposal
        ))
        meeting.addMessage(TeamMessage(
            role: .uxDesigner,
            content: "I agree with that approach",
            messageType: .agreement
        ))

        let result = TeamMeetingService.generateMeetingResultForConversation(meeting: meeting)

        XCTAssertTrue(result.contains("Team Meeting Result"))
        XCTAssertTrue(result.contains("Key points discussed:"))
    }

    // MARK: - TeamMeeting Model Tests

    func testTeamMeeting_TurnCount_ReturnsMessageCount() {
        var meeting = createBasicMeeting()
        XCTAssertEqual(meeting.turnCount, 0)

        addMessages(to: &meeting, count: 5)
        XCTAssertEqual(meeting.turnCount, 5)
    }

    func testTeamMeeting_Start_SetsStatusToInProgress() {
        var meeting = createBasicMeeting()
        XCTAssertEqual(meeting.status, .pending)

        meeting.start()

        XCTAssertEqual(meeting.status, .inProgress)
    }

    func testTeamMeeting_Complete_SetsStatusToCompleted() {
        var meeting = createBasicMeeting()
        meeting.start()

        meeting.complete()

        XCTAssertEqual(meeting.status, .completed)
    }

    func testTeamMeeting_EscalateToSupervisor_SetsCorrectStatus() {
        var meeting = createBasicMeeting()
        meeting.start()

        meeting.escalateToSupervisor()

        XCTAssertEqual(meeting.status, .escalatedToSupervisor)
    }

    func testTeamMeeting_Cancel_SetsStatusToCancelled() {
        var meeting = createBasicMeeting()

        meeting.cancel()

        XCTAssertEqual(meeting.status, .cancelled)
    }

    func testTeamMeeting_AddMessage_AppendsAndUpdatesTimestamp() {
        var meeting = createBasicMeeting()
        let originalUpdate = meeting.updatedAt

        // Small delay to ensure timestamp difference
        Thread.sleep(forTimeInterval: 0.01)

        meeting.addMessage(TeamMessage(
            role: .softwareEngineer,
            content: "Test message"
        ))

        XCTAssertEqual(meeting.messages.count, 1)
        XCTAssertGreaterThan(meeting.updatedAt, originalUpdate)
    }

    func testTeamMeeting_AddDecision_AppendsAndUpdatesTimestamp() {
        var meeting = createBasicMeeting()
        let originalUpdate = meeting.updatedAt

        Thread.sleep(forTimeInterval: 0.01)

        meeting.addDecision(TeamDecision(
            summary: "Test decision",
            proposedBy: .tpm
        ))

        XCTAssertEqual(meeting.decisions.count, 1)
        XCTAssertGreaterThan(meeting.updatedAt, originalUpdate)
    }

    func testTeamMeeting_MessagesFromRole_FiltersCorrectly() {
        var meeting = createBasicMeeting()
        meeting.addMessage(TeamMessage(role: .softwareEngineer, content: "Eng message 1"))
        meeting.addMessage(TeamMessage(role: .uxDesigner, content: "Designer message"))
        meeting.addMessage(TeamMessage(role: .softwareEngineer, content: "Eng message 2"))

        let engineerMessages = meeting.messages(from: .softwareEngineer)

        XCTAssertEqual(engineerMessages.count, 2)
        XCTAssertTrue(engineerMessages.allSatisfy { $0.role == .softwareEngineer })
    }

    func testTeamMeeting_HasParticipated_ReturnsTrueIfHasMessages() {
        var meeting = createBasicMeeting()
        meeting.addMessage(TeamMessage(role: .softwareEngineer, content: "Test"))

        XCTAssertTrue(meeting.hasParticipated(.softwareEngineer))
        XCTAssertFalse(meeting.hasParticipated(.uxDesigner))
    }

    // MARK: - MeetingStatus Tests

    func testMeetingStatus_DisplayName() {
        XCTAssertEqual(MeetingStatus.pending.displayName, "Pending")
        XCTAssertEqual(MeetingStatus.inProgress.displayName, "In Progress")
        XCTAssertEqual(MeetingStatus.completed.displayName, "Completed")
        XCTAssertEqual(MeetingStatus.escalatedToSupervisor.displayName, "Escalated to Supervisor")
        XCTAssertEqual(MeetingStatus.cancelled.displayName, "Cancelled")
    }

    func testMeetingStatus_Icon() {
        XCTAssertEqual(MeetingStatus.pending.icon, "clock")
        XCTAssertEqual(MeetingStatus.inProgress.icon, "person.3.fill")
        XCTAssertEqual(MeetingStatus.completed.icon, "checkmark.circle")
        XCTAssertEqual(MeetingStatus.escalatedToSupervisor.icon, "exclamationmark.triangle")
        XCTAssertEqual(MeetingStatus.cancelled.icon, "xmark.circle")
    }

    func testMeetingStatus_IsActive() {
        XCTAssertTrue(MeetingStatus.pending.isActive)
        XCTAssertTrue(MeetingStatus.inProgress.isActive)
        XCTAssertFalse(MeetingStatus.completed.isActive)
        XCTAssertFalse(MeetingStatus.escalatedToSupervisor.isActive)
        XCTAssertFalse(MeetingStatus.cancelled.isActive)
    }

    // MARK: - TeamMessageType Tests

    func testTeamMessageType_AllCases() {
        let allTypes: [TeamMessageType] = [
            .discussion,
            .question,
            .proposal,
            .objection,
            .agreement,
            .summary,
            .conclusion
        ]

        XCTAssertEqual(allTypes.count, 7)
    }

    // MARK: - Codable Tests

    func testTeamMeeting_Codable_RoundTrip() throws {
        var original = TeamMeeting(
            topic: "Test Meeting",
            initiatedBy: .softwareEngineer,
            participants: [.uxDesigner, .sre],
            context: "Test context",
            status: .inProgress
        )
        original.addMessage(TeamMessage(
            role: .softwareEngineer,
            content: "Test message",
            messageType: .proposal
        ))
        original.addDecision(TeamDecision(
            summary: "Test decision",
            rationale: "Test rationale",
            proposedBy: .tpm,
            nextSteps: ["Step 1", "Step 2"]
        ))

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TeamMeeting.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.topic, original.topic)
        XCTAssertEqual(decoded.initiatedBy, original.initiatedBy)
        XCTAssertEqual(decoded.participants, original.participants)
        XCTAssertEqual(decoded.context, original.context)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.decisions.count, 1)
    }

    func testTeamMessage_Codable_RoundTrip() throws {
        let original = TeamMessage(
            role: .uxDesigner,
            content: "Test content",
            replyToID: UUID(),
            messageType: .agreement
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TeamMessage.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.content, original.content)
        XCTAssertEqual(decoded.replyToID, original.replyToID)
        XCTAssertEqual(decoded.messageType, original.messageType)
    }

    func testTeamDecision_Codable_RoundTrip() throws {
        let original = TeamDecision(
            summary: "Test summary",
            rationale: "Test rationale",
            proposedBy: .tpm,
            agreedBy: [.uxDesigner, .softwareEngineer],
            nextSteps: ["Step 1", "Step 2"]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TeamDecision.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.summary, original.summary)
        XCTAssertEqual(decoded.rationale, original.rationale)
        XCTAssertEqual(decoded.proposedBy, original.proposedBy)
        XCTAssertEqual(decoded.agreedBy, original.agreedBy)
        XCTAssertEqual(decoded.nextSteps, original.nextSteps)
    }

    // MARK: - Helpers

    private func createBasicMeeting() -> TeamMeeting {
        TeamMeeting(
            topic: "Test Topic",
            initiatedBy: .softwareEngineer,
            participants: [.uxDesigner, .softwareEngineer, .sre],
            context: nil
        )
    }

    private func createMeetings(count: Int) -> [TeamMeeting] {
        (0..<count).map { i in
            TeamMeeting(
                topic: "Meeting \(i)",
                initiatedBy: .tpm,
                participants: [.softwareEngineer, .uxDesigner]
            )
        }
    }

    private func addMessages(to meeting: inout TeamMeeting, count: Int) {
        let roles: [Role] = [.softwareEngineer, .uxDesigner, .sre, .tpm]
        for i in 0..<count {
            meeting.addMessage(TeamMessage(
                role: roles[i % roles.count],
                content: "Message \(i)"
            ))
        }
    }

    // MARK: - Meeting Persistence in Run/Step Tests

    func testMeetingPersistence_RunMeetingsArray() {
        var run = Run(id: 0)
        XCTAssertTrue(run.meetings.isEmpty)

        let meeting = createBasicMeeting()
        run.meetings.append(meeting)

        XCTAssertEqual(run.meetings.count, 1)
        XCTAssertEqual(run.meetings.first?.topic, "Test Topic")
    }

    func testMeetingPersistence_StepMeetingIDs() {
        var step = StepExecution(id: "test_step", role: .tpm, title: "PM Step")
        XCTAssertTrue(step.meetingIDs.isEmpty)

        let meetingID = UUID()
        step.meetingIDs.append(meetingID)

        XCTAssertEqual(step.meetingIDs.count, 1)
        XCTAssertEqual(step.meetingIDs.first, meetingID)
    }

    func testMeetingPersistence_StepMeetingIDs_CodableRoundTrip() throws {
        var step = StepExecution(id: "test_step", role: .tpm, title: "PM Step")
        let meetingID = UUID()
        step.meetingIDs.append(meetingID)

        let encoded = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(StepExecution.self, from: encoded)

        XCTAssertEqual(decoded.meetingIDs, [meetingID])
    }

    // MARK: - MessageSourceContext Tests

    func testMessageSourceContext_CodableRoundTrip() throws {
        let msg = LLMMessage(
            role: .user,
            content: "Test meeting result",
            sourceRole: .tpm,
            sourceContext: .meeting
        )

        let encoded = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)

        XCTAssertEqual(decoded.sourceContext, .meeting)
        XCTAssertEqual(decoded.sourceRole, .tpm)
    }

    func testMessageSourceContext_ConsultationCodable() throws {
        let msg = LLMMessage(
            role: .user,
            content: "Consultation response",
            sourceRole: .uxDesigner,
            sourceContext: .consultation
        )

        let encoded = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: encoded)

        XCTAssertEqual(decoded.sourceContext, .consultation)
    }

    func testMessageSourceContext_NilByDefault() {
        let msg = LLMMessage(role: .assistant, content: "Normal message")

        XCTAssertNil(msg.sourceContext)
        XCTAssertNil(msg.sourceRole)
    }

    func testMessageSourceContext_BackwardsCompatibility() throws {
        // Simulate old JSON without sourceContext field
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","role":"user","content":"Old message","createdAt":0}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: data)

        XCTAssertNil(decoded.sourceContext)
        XCTAssertNil(decoded.sourceRole)
        XCTAssertEqual(decoded.content, "Old message")
    }

    // MARK: - MeetingStreamResult Tests

    func testMeetingStreamResult_EmptyFields() {
        let result = TeamMeetingService.MeetingStreamResult(
            content: "",
            thinking: "",
            resolvedToolCalls: []
        )

        XCTAssertTrue(result.content.isEmpty)
        XCTAssertTrue(result.thinking.isEmpty)
        XCTAssertTrue(result.resolvedToolCalls.isEmpty)
    }

    func testMeetingStreamResult_WithAllFields() {
        let toolCall = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\":\"test.swift\"}",
            resultJSON: "file contents"
        )
        let result = TeamMeetingService.MeetingStreamResult(
            content: "Based on my analysis...",
            thinking: "Let me consider the options",
            resolvedToolCalls: [toolCall]
        )

        XCTAssertEqual(result.content, "Based on my analysis...")
        XCTAssertEqual(result.thinking, "Let me consider the options")
        XCTAssertEqual(result.resolvedToolCalls.count, 1)
        XCTAssertEqual(result.resolvedToolCalls[0].name, "read_file")
    }

    // MARK: - completeTurn Tests

    func testCompleteTurn_AddsMessageWithThinkingAndTools() {
        var meeting = createBasicMeeting()
        meeting.start()

        let toolSummaries = [
            MeetingToolSummary(toolName: "read_file", arguments: "{}", result: "code", isError: false)
        ]

        let limits = TeamLimits(maxMeetingTurns: 20)
        let context = TeamMeetingService.MeetingContext(
            topic: "Test",
            initiatedBy: .softwareEngineer,
            participants: [.uxDesigner, .softwareEngineer],
            additionalContext: nil,
            task: NTMSTask(id: 0, title: "Test", supervisorTask: "Goal"),
            availableArtifacts: [],
            artifactReader: { _ in nil },
            team: Team.default,
            coordinatorRole: .tpm,
            limits: limits
        )

        let shouldContinue = TeamMeetingService.completeTurn(
            meeting: &meeting,
            speaker: .softwareEngineer,
            content: "After reviewing the code...",
            thinking: "I should check the implementation",
            toolSummaries: toolSummaries,
            context: context
        )

        XCTAssertTrue(shouldContinue)
        XCTAssertEqual(meeting.messages.count, 1)

        let msg = meeting.messages[0]
        XCTAssertEqual(msg.role, .softwareEngineer)
        XCTAssertEqual(msg.content, "After reviewing the code...")
        XCTAssertEqual(msg.thinking, "I should check the implementation")
        XCTAssertEqual(msg.toolSummaries?.count, 1)
        XCTAssertEqual(msg.toolSummaries?[0].toolName, "read_file")
    }

    func testCompleteTurn_NilThinkingAndTools() {
        var meeting = createBasicMeeting()
        meeting.start()

        let limits = TeamLimits(maxMeetingTurns: 20)
        let context = TeamMeetingService.MeetingContext(
            topic: "Test",
            initiatedBy: .softwareEngineer,
            participants: [.uxDesigner, .softwareEngineer],
            additionalContext: nil,
            task: NTMSTask(id: 0, title: "Test", supervisorTask: "Goal"),
            availableArtifacts: [],
            artifactReader: { _ in nil },
            team: Team.default,
            coordinatorRole: .tpm,
            limits: limits
        )

        _ = TeamMeetingService.completeTurn(
            meeting: &meeting,
            speaker: .uxDesigner,
            content: "Simple response",
            thinking: nil,
            toolSummaries: nil,
            context: context
        )

        let msg = meeting.messages[0]
        XCTAssertNil(msg.thinking)
        XCTAssertNil(msg.toolSummaries)
    }

    // MARK: - determineMessageType (now static) Tests

    func testDetermineMessageType_DirectAccess() {
        XCTAssertEqual(TeamMessageType.determine(from: "I agree with that"), .agreement)
        XCTAssertEqual(TeamMessageType.determine(from: "I have a concern"), .objection)
        XCTAssertEqual(TeamMessageType.determine(from: "I suggest we try"), .proposal)
        XCTAssertEqual(TeamMessageType.determine(from: "What do you think?"), .question)
        XCTAssertEqual(TeamMessageType.determine(from: "In summary"), .summary)
        XCTAssertEqual(TeamMessageType.determine(from: "The decision is"), .conclusion)
        XCTAssertEqual(TeamMessageType.determine(from: "The system runs well"), .discussion)
    }

    // MARK: - MeetingTurnResult Tests

    func testMeetingTurnResult_StructFields() {
        let meeting = createBasicMeeting()
        let streamResult = TeamMeetingService.MeetingStreamResult(
            content: "test",
            thinking: "thinking",
            resolvedToolCalls: []
        )

        let turnResult = TeamMeetingService.MeetingTurnResult(
            meeting: meeting,
            shouldContinue: true,
            speaker: .uxDesigner,
            streamResult: streamResult
        )

        XCTAssertTrue(turnResult.shouldContinue)
        XCTAssertEqual(turnResult.speaker, .uxDesigner)
        XCTAssertEqual(turnResult.streamResult.content, "test")
        XCTAssertEqual(turnResult.streamResult.thinking, "thinking")
    }
}
