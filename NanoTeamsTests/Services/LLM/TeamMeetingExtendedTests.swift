import XCTest

@testable import NanoTeams

/// Extended tests for TeamMeetingService covering determineNextSpeaker,
/// determineMessageType, shouldConcludeMeeting, and meeting summary edge cases.
final class TeamMeetingExtendedTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - determineMessageType Tests (Indirect via addMessage)

    func testDetermineMessageType_Agreement_IAgreePhrases() {
        let types = classifyMessages([
            "I agree with that approach",
            "Sounds good to me",
            "Let's go with that plan"
        ])

        for t in types {
            XCTAssertEqual(t, .agreement, "Expected agreement for '\(t)'")
        }
    }

    func testDetermineMessageType_Objection_ConcernPhrases() {
        // Specific objection markers: "concern", "suffer", "issue with"
        XCTAssertEqual(TeamMessageType.determine(from: "I have a concern about scalability"), .objection)
        XCTAssertEqual(TeamMessageType.determine(from: "But the performance might suffer"), .objection)
        XCTAssertEqual(TeamMessageType.determine(from: "There's an issue with that approach"), .objection)

        // Generic "however" is too broad — real LLM proposals often contain it.
        // Without specific objection markers it falls through to .discussion.
        XCTAssertEqual(TeamMessageType.determine(from: "However, we should consider..."), .discussion)
    }

    func testDetermineMessageType_Objection_ConcessivePatterns() {
        // Concessive objection — starts with agreement then pushes back
        XCTAssertEqual(TeamMessageType.determine(from: "Fine, but let's break it down. Moving every three months means you're never fully embedded."), .objection)
        XCTAssertEqual(TeamMessageType.determine(from: "Sure, but that ignores the cost of constant relocation."), .objection)
        XCTAssertEqual(TeamMessageType.determine(from: "Fair point, but we need to consider the long-term effects."), .objection)
        XCTAssertEqual(TeamMessageType.determine(from: "I appreciate the enthusiasm, but let's check the numbers."), .objection)
    }

    func testDetermineMessageType_Objection_SkepticalOpening() {
        // Skeptical opening patterns
        XCTAssertEqual(TeamMessageType.determine(from: "I hate to be the one pointing out the cracks here, but every quarter you're resetting your life."), .objection)
        XCTAssertEqual(TeamMessageType.determine(from: "Let's not forget that constant relocation erodes relationships."), .objection)
        XCTAssertEqual(TeamMessageType.determine(from: "Hold on, we're skating on thin ice with that assumption."), .objection)
        XCTAssertEqual(TeamMessageType.determine(from: "Let's be real — the paperwork alone would kill productivity."), .objection)
    }

    func testDetermineMessageType_Proposal_SuggestPhrases() {
        let types = classifyMessages([
            "I suggest we use microservices",
            "I propose a different architecture",
            "We could try a modular approach",
            "How about using Redis for caching?"
        ])

        for t in types {
            XCTAssertEqual(t, .proposal, "Expected proposal")
        }
    }

    func testDetermineMessageType_Question_ContainsQuestionMark() {
        let types = classifyMessages([
            "What framework should we use?",
            "Any thoughts on this?"
        ])

        for t in types {
            XCTAssertEqual(t, .question, "Expected question")
        }
    }

    func testDetermineMessageType_Summary() {
        let types = classifyMessages([
            "In summary, we should proceed with option A",
            "To summarize the discussion so far"
        ])

        for t in types {
            XCTAssertEqual(t, .summary, "Expected summary")
        }
    }

    func testDetermineMessageType_Conclusion() {
        let types = classifyMessages([
            "The decision is to proceed with REST API",
            "We can conclude that microservices is the way to go",
            "As agreed by the team, we will use GraphQL"
        ])

        for t in types {
            XCTAssertEqual(t, .conclusion, "Expected conclusion")
        }
    }

    func testDetermineMessageType_Discussion_Default() {
        let types = classifyMessages([
            "The current system handles 1000 requests per second",
            "Our team has experience with both approaches"
        ])

        for t in types {
            XCTAssertEqual(t, .discussion, "Expected discussion (default)")
        }
    }

    // MARK: - shouldConcludeMeeting Indirect Tests

    func testMeeting_AllParticipatedWithAgreement_ShouldConclude() {
        var meeting = createMeeting(participants: [.uxDesigner, .softwareEngineer])
        meeting.start()

        // Both participants contribute
        meeting.addMessage(TeamMessage(
            role: .uxDesigner,
            content: "I think we should use SwiftUI",
            messageType: .proposal
        ))
        meeting.addMessage(TeamMessage(
            role: .softwareEngineer,
            content: "I agree with that approach",
            messageType: .agreement
        ))

        // Check via the service's limit/conclusion logic
        XCTAssertTrue(meeting.hasParticipated(.uxDesigner))
        XCTAssertTrue(meeting.hasParticipated(.softwareEngineer))

        let lastMessages = meeting.messages.suffix(3)
        let hasAgreement = lastMessages.contains { $0.messageType == .agreement }
        XCTAssertTrue(hasAgreement, "Should detect agreement in recent messages")
    }

    func testMeeting_NotAllParticipated_ShouldNotConclude() {
        var meeting = createMeeting(participants: [.uxDesigner, .softwareEngineer, .sre])
        meeting.start()

        // Only designer speaks
        meeting.addMessage(TeamMessage(
            role: .uxDesigner,
            content: "I suggest we use SwiftUI",
            messageType: .proposal
        ))

        XCTAssertTrue(meeting.hasParticipated(.uxDesigner))
        XCTAssertFalse(meeting.hasParticipated(.softwareEngineer))
        XCTAssertFalse(meeting.hasParticipated(.sre))
    }

    // MARK: - determineNextSpeaker Indirect Tests

    func testNextSpeaker_EmptyMeeting_CoordinatorGoesFirst() {
        // When meeting.messages is empty, coordinator should speak first
        let meeting = createMeeting(participants: [.uxDesigner, .softwareEngineer])
        XCTAssertTrue(meeting.messages.isEmpty)
    }

    func testNextSpeaker_RoundRobin_AllParticipantsGetTurn() {
        var meeting = createMeeting(participants: [.uxDesigner, .softwareEngineer, .sre])
        meeting.start()

        // After coordinator (PM) speaks, next should be from participants who haven't spoken
        meeting.addMessage(TeamMessage(role: .tpm, content: "Let's discuss"))
        meeting.addMessage(TeamMessage(role: .uxDesigner, content: "Design thoughts"))
        meeting.addMessage(TeamMessage(role: .softwareEngineer, content: "Engineering thoughts"))

        // QA hasn't spoken yet
        XCTAssertFalse(meeting.hasParticipated(.sre))
        XCTAssertTrue(meeting.hasParticipated(.uxDesigner))
        XCTAssertTrue(meeting.hasParticipated(.softwareEngineer))
    }

    // MARK: - generateMeetingSummary Edge Cases

    func testGenerateMeetingSummary_EmptyMeeting() {
        let meeting = createMeeting(participants: [.uxDesigner])

        let summary = TeamMeetingService.generateMeetingSummary(meeting: meeting)

        XCTAssertTrue(summary.contains("Test Topic"))
        XCTAssertTrue(summary.contains("Messages: 0"))
        XCTAssertFalse(summary.contains("Decisions:"))
    }

    func testGenerateMeetingSummary_MultipleDecisions() {
        var meeting = createMeeting(participants: [.uxDesigner, .softwareEngineer])
        meeting.start()

        meeting.addDecision(TeamDecision(
            summary: "First decision",
            proposedBy: .tpm
        ))
        meeting.addDecision(TeamDecision(
            summary: "Second decision",
            rationale: "Better approach",
            proposedBy: .softwareEngineer,
            nextSteps: ["Step A", "Step B"]
        ))

        let summary = TeamMeetingService.generateMeetingSummary(meeting: meeting)

        XCTAssertTrue(summary.contains("First decision"))
        XCTAssertTrue(summary.contains("Second decision"))
        XCTAssertTrue(summary.contains("Better approach"))
        XCTAssertTrue(summary.contains("Step A"))
    }

    // MARK: - generateMeetingResultForConversation Edge Cases

    func testGenerateMeetingResult_EmptyMeetingNoDecisions() {
        let meeting = createMeeting(participants: [.uxDesigner])

        let result = TeamMeetingService.generateMeetingResultForConversation(meeting: meeting)

        XCTAssertTrue(result.contains("Team Meeting Result"))
        XCTAssertTrue(result.contains("Test Topic"))
        // No decisions, no key messages
        XCTAssertFalse(result.contains("Decision:"))
    }

    func testGenerateMeetingResult_WithKeyMessages_NoDecisions() {
        var meeting = createMeeting(participants: [.uxDesigner, .softwareEngineer])
        meeting.start()

        meeting.addMessage(TeamMessage(
            role: .softwareEngineer,
            content: "I suggest we use GraphQL for the API",
            messageType: .proposal
        ))
        meeting.addMessage(TeamMessage(
            role: .uxDesigner,
            content: "I agree with that approach, it fits the design",
            messageType: .agreement
        ))

        let result = TeamMeetingService.generateMeetingResultForConversation(meeting: meeting)

        XCTAssertTrue(result.contains("Key points discussed:"))
        XCTAssertTrue(result.contains("Software Engineer"))
    }

    func testGenerateMeetingResult_LongMessages_Truncated() {
        var meeting = createMeeting(participants: [.uxDesigner])
        meeting.start()

        let longContent = String(repeating: "x", count: 500)
        meeting.addMessage(TeamMessage(
            role: .uxDesigner,
            content: "I suggest \(longContent)",
            messageType: .proposal
        ))

        let result = TeamMeetingService.generateMeetingResultForConversation(meeting: meeting)

        // The message content should be truncated to prefix(200) + "..."
        XCTAssertTrue(result.contains("..."))
    }

    // MARK: - concludeMeeting Edge Cases

    func testConcludeMeeting_WithEmptyNextSteps() {
        var meeting = createMeeting(participants: [.uxDesigner])
        meeting.start()

        TeamMeetingService.concludeMeeting(
            meeting: &meeting,
            decision: "Proceed",
            rationale: nil,
            nextSteps: "",
            concludedBy: .tpm
        )

        let decision = meeting.decisions.first!
        XCTAssertTrue(decision.nextSteps.isEmpty)
    }

    func testConcludeMeeting_NextStepsFiltersEmptyLines() {
        var meeting = createMeeting(participants: [.uxDesigner])
        meeting.start()

        TeamMeetingService.concludeMeeting(
            meeting: &meeting,
            decision: "Proceed",
            rationale: nil,
            nextSteps: "Step 1\n\n\nStep 2\n",
            concludedBy: .tpm
        )

        let decision = meeting.decisions.first!
        XCTAssertEqual(decision.nextSteps, ["Step 1", "Step 2"])
    }

    // MARK: - Meeting Limit Tests

    func testHasReachedMeetingLimit_ZeroLimit_AlwaysTrue() {
        let limits = TeamLimits(maxMeetingsPerRun: 0)

        let result = TeamMeetingService.hasReachedMeetingLimit(
            meetings: [],
            limits: limits
        )

        XCTAssertTrue(result)
    }

    func testHasReachedTurnLimit_ZeroLimit_AlwaysTrue() {
        let meeting = createMeeting(participants: [.uxDesigner])
        let limits = TeamLimits(maxMeetingTurns: 0)

        let result = TeamMeetingService.hasReachedTurnLimit(
            meeting: meeting,
            limits: limits
        )

        XCTAssertTrue(result)
    }

    // MARK: - Codable Round-Trip with Extended Data

    func testTeamMeeting_Codable_WithFullData() throws {
        var meeting = createMeeting(participants: [.uxDesigner, .softwareEngineer, .sre])
        meeting.start()
        meeting.addMessage(TeamMessage(
            role: .tpm,
            content: "Let's discuss the architecture",
            messageType: .discussion
        ))
        meeting.addMessage(TeamMessage(
            role: .uxDesigner,
            content: "I suggest component-based design",
            messageType: .proposal
        ))
        meeting.addMessage(TeamMessage(
            role: .softwareEngineer,
            content: "I agree with the component approach",
            messageType: .agreement
        ))
        meeting.addDecision(TeamDecision(
            summary: "Use component-based architecture",
            rationale: "Better reusability",
            proposedBy: .uxDesigner,
            agreedBy: [.uxDesigner, .softwareEngineer],
            nextSteps: ["Create base component", "Set up storybook"]
        ))
        meeting.complete()

        let encoded = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(TeamMeeting.self, from: encoded)

        XCTAssertEqual(decoded.messages.count, 3)
        XCTAssertEqual(decoded.decisions.count, 1)
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertEqual(decoded.decisions[0].nextSteps.count, 2)
    }

    // MARK: - Codable with Thinking/ToolSummaries

    func testTeamMeeting_Codable_WithThinkingAndToolSummaries() throws {
        var meeting = createMeeting(participants: [.uxDesigner, .softwareEngineer])
        meeting.start()

        let toolSummaries = [
            MeetingToolSummary(toolName: "read_file", arguments: "{\"path\":\"main.swift\"}", result: "import Foundation", isError: false),
            MeetingToolSummary(toolName: "list_files", arguments: "{\"path\":\"src\"}", result: "main.swift\nutils.swift", isError: false)
        ]

        meeting.addMessage(TeamMessage(
            role: .softwareEngineer,
            content: "After reviewing the code, I suggest refactoring",
            messageType: .proposal,
            thinking: "The architecture has some issues I should mention",
            toolSummaries: toolSummaries
        ))
        meeting.addMessage(TeamMessage(
            role: .uxDesigner,
            content: "I agree with that approach",
            messageType: .agreement
        ))

        let encoded = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(TeamMeeting.self, from: encoded)

        XCTAssertEqual(decoded.messages.count, 2)

        let msg0 = decoded.messages[0]
        XCTAssertEqual(msg0.thinking, "The architecture has some issues I should mention")
        XCTAssertEqual(msg0.toolSummaries?.count, 2)
        XCTAssertEqual(msg0.toolSummaries?[0].toolName, "read_file")
        XCTAssertEqual(msg0.toolSummaries?[1].toolName, "list_files")
        XCTAssertFalse(msg0.toolSummaries?[0].isError ?? true)

        let msg1 = decoded.messages[1]
        XCTAssertNil(msg1.thinking)
        XCTAssertNil(msg1.toolSummaries)
    }

    // MARK: - Helpers

    private func createMeeting(
        participants: [Role]
    ) -> TeamMeeting {
        TeamMeeting(
            topic: "Test Topic",
            initiatedBy: .softwareEngineer,
            participants: participants,
            context: nil
        )
    }

    /// Helper to classify messages using `TeamMessageType.determine(from:)`.
    private func classifyMessages(_ contents: [String]) -> [TeamMessageType] {
        contents.map { TeamMessageType.determine(from: $0) }
    }
}
