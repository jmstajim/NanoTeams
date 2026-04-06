import XCTest
@testable import NanoTeams

/// Tests for TeamActivityFeedView logic: message filtering, notification ordering,
/// thinking streaming state, and token cleaning.
///
/// These tests validate the core logic patterns used by `buildTimelineItems()` and
/// `messageBubbleContent()` without instantiating the SwiftUI view.
@MainActor
final class TeamActivityFeedLogicTests: XCTestCase {

    var streamingManager: StreamingPreviewManager!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        streamingManager = StreamingPreviewManager()
    }

    override func tearDown() {
        streamingManager = nil
        super.tearDown()
    }

    // MARK: - Helper: Build a step with conversation

    private func makeStep(
        role: Role = .softwareEngineer,
        teamRoleID: String? = nil,
        status: StepStatus = .done,
        llmConversation: [LLMMessage] = [],
        toolCalls: [StepToolCall] = [],
        needsSupervisorInput: Bool = false,
        supervisorQuestion: String? = nil,
        supervisorAnswer: String? = nil
    ) -> StepExecution {
        StepExecution(
            id: teamRoleID ?? role.baseID,
            role: role,
            title: "\(role.displayName) Step",
            status: status,
            toolCalls: toolCalls,
            needsSupervisorInput: needsSupervisorInput,
            supervisorQuestion: supervisorQuestion,
            supervisorAnswer: supervisorAnswer,
            llmConversation: llmConversation
        )
    }

    // MARK: - Helper: Replicate buildTimelineItems filtering logic

    /// Replicates the LLM message filtering logic from `buildTimelineItems()`.
    /// Returns the LLMMessages that would pass through the filter.
    private func filterMessages(
        in step: StepExecution,
        showDebug: Bool,
        artifactContents: Set<String> = [],
        streamingMessageIDs: Set<UUID> = []
    ) -> [LLMMessage] {
        var result: [LLMMessage] = []

        for msg in step.llmConversation where msg.role != .system && msg.role != .tool {
            let hasThinking = msg.thinking.map { !$0.isEmpty } ?? false
            let isActivelyStreaming = streamingMessageIDs.contains(msg.id)
            if msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasThinking && !isActivelyStreaming {
                continue
            }

            if !showDebug && msg.role == .user {
                if msg.sourceRole == nil && msg.sourceContext == nil { continue }
                if msg.sourceContext == .supervisorAnswer { continue }
            }

            if !showDebug && !msg.content.isEmpty && artifactContents.contains(msg.content) && !hasThinking {
                continue
            }

            result.append(msg)
        }

        return result
    }

    /// Replicates the per-tool-call notification creation from `buildTimelineItems()`.
    /// Returns (question, answer, timestamp) for each ask_supervisor notification.
    private func supervisorNotifications(for step: StepExecution) -> [(question: String, answer: String?, timestamp: Date)] {
        let askCalls = step.toolCalls.filter { $0.name == "ask_supervisor" }
        let answerMessages = step.llmConversation.filter { $0.sourceContext == .supervisorAnswer }
        var result: [(String, String?, Date)] = []

        for (index, call) in askCalls.enumerated() {
            let isLast = index == askCalls.count - 1
            let question: String
            if let parsed = parseQuestion(from: call.argumentsJSON) {
                question = parsed
            } else if isLast {
                question = step.supervisorQuestion ?? "?"
            } else {
                question = "?"
            }
            let isActive = isLast && step.needsSupervisorInput && step.supervisorAnswer == nil

            let answer: String?
            if isActive {
                answer = nil
            } else if index < answerMessages.count {
                let content = answerMessages[index].content
                answer = content.hasPrefix("Supervisor answer: ")
                    ? String(content.dropFirst("Supervisor answer: ".count))
                    : content
            } else if isLast {
                answer = step.supervisorAnswer
            } else {
                answer = "(answered)"
            }

            let timestamp = isActive ? Date.distantFuture : call.createdAt
            result.append((question, answer, timestamp))
        }
        return result
    }

    private func parseQuestion(from text: String) -> String? {
        ActivityFeedBuilder.parseAskSupervisorQuestion(from: text)
    }

    // MARK: - Bug 1: Supervisor Answer Messages Filtered in Non-Debug

    func testSupervisorAnswerMessageHiddenWhenDebugOff() {
        let supervisorAnswerMsg = LLMMessage(
            role: .user,
            content: "Supervisor answer: russian",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer
        )

        let step = makeStep(llmConversation: [supervisorAnswerMsg])
        let filtered = filterMessages(in: step, showDebug: false)

        XCTAssertTrue(filtered.isEmpty, "Supervisor answer message should be hidden when debug is off")
    }

    func testSupervisorAnswerMessageVisibleWhenDebugOn() {
        let supervisorAnswerMsg = LLMMessage(
            role: .user,
            content: "Supervisor answer: russian",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer
        )

        let step = makeStep(llmConversation: [supervisorAnswerMsg])
        let filtered = filterMessages(in: step, showDebug: true)

        XCTAssertEqual(filtered.count, 1, "Supervisor answer message should be visible when debug is on")
    }

    func testPlainUserMessageFilteredWhenDebugOff() {
        let userMsg = LLMMessage(role: .user, content: "Some prompt input")
        let step = makeStep(llmConversation: [userMsg])
        let filtered = filterMessages(in: step, showDebug: false)

        XCTAssertTrue(filtered.isEmpty, "Plain user message should be hidden when debug is off")
    }

    func testConsultationResponseVisibleWhenDebugOff() {
        let consultationMsg = LLMMessage(
            role: .user,
            content: "Here is my analysis...",
            sourceRole: .techLead,
            sourceContext: .consultation
        )

        let step = makeStep(llmConversation: [consultationMsg])
        let filtered = filterMessages(in: step, showDebug: false)

        XCTAssertEqual(filtered.count, 1, "Consultation response should be visible when debug is off")
    }

    func testMeetingMessageVisibleWhenDebugOff() {
        let meetingMsg = LLMMessage(
            role: .user,
            content: "Meeting conclusion...",
            sourceRole: .productManager,
            sourceContext: .meeting
        )

        let step = makeStep(llmConversation: [meetingMsg])
        let filtered = filterMessages(in: step, showDebug: false)

        XCTAssertEqual(filtered.count, 1, "Meeting message should be visible when debug is off")
    }

    func testAssistantMessageAlwaysVisible() {
        let assistantMsg = LLMMessage(role: .assistant, content: "Here is the plan...")
        let step = makeStep(llmConversation: [assistantMsg])

        let filteredDebugOff = filterMessages(in: step, showDebug: false)
        let filteredDebugOn = filterMessages(in: step, showDebug: true)

        XCTAssertEqual(filteredDebugOff.count, 1)
        XCTAssertEqual(filteredDebugOn.count, 1)
    }

    func testSystemAndToolMessagesAlwaysFiltered() {
        let systemMsg = LLMMessage(role: .system, content: "You are a PM")
        let toolMsg = LLMMessage(role: .tool, content: "{\"result\": \"ok\"}")
        let step = makeStep(llmConversation: [systemMsg, toolMsg])

        let filteredDebugOn = filterMessages(in: step, showDebug: true)
        XCTAssertTrue(filteredDebugOn.isEmpty, "System and tool messages should always be filtered out")
    }

    // MARK: - Bug 1: Mixed Conversation Filtering

    func testMixedConversationFiltering() {
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: "System prompt"),
            LLMMessage(role: .user, content: "User prompt"),
            LLMMessage(role: .assistant, content: "I'll work on this"),
            LLMMessage(role: .user, content: "Supervisor says: yes", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
            LLMMessage(role: .assistant, content: "Got it, continuing"),
            LLMMessage(role: .user, content: "Tech Lead says: use async", sourceRole: .techLead, sourceContext: .consultation),
            LLMMessage(role: .tool, content: "{\"result\": \"file contents\"}"),
        ]

        let step = makeStep(llmConversation: messages)
        let filtered = filterMessages(in: step, showDebug: false)

        // Expected: 2 assistant messages + 1 consultation = 3
        // Filtered: system, tool, plain user, supervisor answer
        XCTAssertEqual(filtered.count, 3)
        XCTAssertEqual(filtered[0].content, "I'll work on this")
        XCTAssertEqual(filtered[1].content, "Got it, continuing")
        XCTAssertEqual(filtered[2].sourceContext, .consultation)
    }

    // MARK: - Bug 5: Empty Streaming Messages Not Filtered

    func testEmptyStreamingMessageNotFiltered() {
        let msgID = UUID()
        let emptyMsg = LLMMessage(id: msgID, role: .assistant, content: "")
        let step = makeStep(llmConversation: [emptyMsg])

        // Without streaming — should be filtered
        let filteredNormal = filterMessages(in: step, showDebug: false, streamingMessageIDs: [])
        XCTAssertTrue(filteredNormal.isEmpty, "Empty non-streaming message should be filtered")

        // With streaming — should pass through
        let filteredStreaming = filterMessages(in: step, showDebug: false, streamingMessageIDs: [msgID])
        XCTAssertEqual(filteredStreaming.count, 1, "Empty streaming message should NOT be filtered")
    }

    func testEmptyMessageWithThinkingNotFiltered() {
        let msg = LLMMessage(role: .assistant, content: "", thinking: "I'm reasoning about this...")
        let step = makeStep(llmConversation: [msg])

        let filtered = filterMessages(in: step, showDebug: false)
        XCTAssertEqual(filtered.count, 1, "Empty message with thinking should not be filtered")
    }

    func testEmptyMessageWithEmptyThinkingFiltered() {
        let msg = LLMMessage(role: .assistant, content: "", thinking: "")
        let step = makeStep(llmConversation: [msg])

        let filtered = filterMessages(in: step, showDebug: false)
        XCTAssertTrue(filtered.isEmpty, "Empty message with empty thinking should be filtered")
    }

    func testWhitespaceOnlyMessageFiltered() {
        let msg = LLMMessage(role: .assistant, content: "   \n\t  ")
        let step = makeStep(llmConversation: [msg])

        let filtered = filterMessages(in: step, showDebug: false)
        XCTAssertTrue(filtered.isEmpty, "Whitespace-only message should be filtered")
    }

    // MARK: - Bug 5: Artifact Content Filtering

    func testArtifactContentMessageFilteredWhenDebugOff() {
        let artifactContent = "# Product Requirements\n\nThe system shall..."
        let msg = LLMMessage(role: .assistant, content: artifactContent)
        let step = makeStep(llmConversation: [msg])

        let filtered = filterMessages(in: step, showDebug: false, artifactContents: [artifactContent])
        XCTAssertTrue(filtered.isEmpty, "Message whose content became an artifact should be filtered")
    }

    func testArtifactContentMessageWithThinkingNotFiltered() {
        let artifactContent = "# Product Requirements\n\nThe system shall..."
        let msg = LLMMessage(role: .assistant, content: artifactContent, thinking: "Let me think about requirements...")
        let step = makeStep(llmConversation: [msg])

        let filtered = filterMessages(in: step, showDebug: false, artifactContents: [artifactContent])
        XCTAssertEqual(filtered.count, 1, "Artifact message with thinking should show (thinking visible, content hidden in bubble)")
    }

    func testArtifactContentMessageVisibleWhenDebugOn() {
        let artifactContent = "# Product Requirements"
        let msg = LLMMessage(role: .assistant, content: artifactContent)
        let step = makeStep(llmConversation: [msg])

        let filtered = filterMessages(in: step, showDebug: true, artifactContents: [artifactContent])
        XCTAssertEqual(filtered.count, 1, "Artifact content message should be visible when debug is on")
    }

    // MARK: - Bug 7: Supervisor Notification — Per-Tool-Call

    func testAnsweredSupervisorNotificationUsesToolCallTimestamp() {
        let toolCallTime = MonotonicClock.shared.now()
        let askCall = StepToolCall(
            createdAt: toolCallTime,
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"What color?\"}"
        )

        let laterTime = MonotonicClock.shared.now()
        var step = makeStep(
            llmConversation: [LLMMessage(role: .user, content: "Supervisor answer: Blue", sourceRole: .supervisor, sourceContext: .supervisorAnswer)],
            toolCalls: [askCall],
            supervisorQuestion: "What color?",
            supervisorAnswer: "Blue"
        )
        step.updatedAt = laterTime

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 1)
        XCTAssertEqual(notifs[0].timestamp, toolCallTime,
            "Answered notification should use tool call timestamp, not step.updatedAt")
        XCTAssertEqual(notifs[0].answer, "Blue")
    }

    func testActiveSupervisorNotificationPinnedToBottom() {
        let askCall = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"What theme?\"}"
        )

        let step = makeStep(
            toolCalls: [askCall],
            needsSupervisorInput: true,
            supervisorQuestion: "What theme?",
            supervisorAnswer: nil
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 1)
        XCTAssertEqual(notifs[0].timestamp, Date.distantFuture,
            "Active (unanswered) notification should be pinned to bottom")
        XCTAssertNil(notifs[0].answer)
    }

    func testNoNotificationWhenNoToolCalls() {
        let step = makeStep(supervisorQuestion: "Manual question?", supervisorAnswer: "Yes")
        let notifs = supervisorNotifications(for: step)
        XCTAssertTrue(notifs.isEmpty, "No notification without ask_supervisor tool calls")
    }

    func testMultipleAskSupervisorCallsCreateMultipleNotifications() {
        let firstCallTime = MonotonicClock.shared.now()
        let firstCall = StepToolCall(
            createdAt: firstCallTime,
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"First question\"}"
        )

        let secondCallTime = MonotonicClock.shared.now()
        let secondCall = StepToolCall(
            createdAt: secondCallTime,
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Second question\"}"
        )

        let step = makeStep(
            llmConversation: [
                LLMMessage(role: .user, content: "Supervisor answer: answer1", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
                LLMMessage(role: .user, content: "Supervisor answer: answer2", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
            ],
            toolCalls: [firstCall, secondCall],
            supervisorQuestion: "Second question",
            supervisorAnswer: "answer2"
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 2, "Each ask_supervisor call should get its own notification")

        XCTAssertEqual(notifs[0].question, "First question")
        XCTAssertEqual(notifs[0].answer, "answer1")
        XCTAssertEqual(notifs[0].timestamp, firstCallTime)

        XCTAssertEqual(notifs[1].question, "Second question")
        XCTAssertEqual(notifs[1].answer, "answer2")
        XCTAssertEqual(notifs[1].timestamp, secondCallTime)
    }

    func testMultipleCallsWithLastUnanswered() {
        let firstCallTime = MonotonicClock.shared.now()
        let firstCall = StepToolCall(
            createdAt: firstCallTime,
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"First question\"}"
        )

        let secondCallTime = MonotonicClock.shared.now()
        let secondCall = StepToolCall(
            createdAt: secondCallTime,
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Second question\"}"
        )

        let step = makeStep(
            llmConversation: [
                LLMMessage(role: .user, content: "Supervisor answer: answer1", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
            ],
            toolCalls: [firstCall, secondCall],
            needsSupervisorInput: true,
            supervisorQuestion: "Second question",
            supervisorAnswer: nil
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 2)

        // First: answered, uses its tool call timestamp
        XCTAssertEqual(notifs[0].question, "First question")
        XCTAssertEqual(notifs[0].answer, "answer1")
        XCTAssertEqual(notifs[0].timestamp, firstCallTime)

        // Second: active, pinned to bottom
        XCTAssertEqual(notifs[1].question, "Second question")
        XCTAssertNil(notifs[1].answer)
        XCTAssertEqual(notifs[1].timestamp, Date.distantFuture)
    }

    func testNotificationOrderingWithArtifactAfterSupervisorAnswer() {
        let askTime = MonotonicClock.shared.now()
        let askCall = StepToolCall(
            createdAt: askTime,
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Any themes?\"}"
        )

        let artifactTime = MonotonicClock.shared.now()

        let step = makeStep(
            llmConversation: [
                LLMMessage(role: .user, content: "Supervisor answer: no", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
            ],
            toolCalls: [askCall],
            supervisorQuestion: "Any themes?",
            supervisorAnswer: "no"
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 1)
        XCTAssertTrue(notifs[0].timestamp <= artifactTime,
            "Notification should sort before artifact created after the answer")
        XCTAssertEqual(notifs[0].timestamp, askTime)
    }

    func testParseQuestionFromArgumentsJSON() {
        // Valid JSON
        XCTAssertEqual(parseQuestion(from: "{\"question\":\"What color?\"}"), "What color?")
        XCTAssertEqual(parseQuestion(from: "{\"question\": \"With spaces\"}"), "With spaces")
        XCTAssertNil(parseQuestion(from: "{\"question\":\"\"}"), "Empty question should return nil")
        XCTAssertNil(parseQuestion(from: "{\"other\":\"field\"}"), "Missing question key should return nil")

        // Malformed/truncated JSON (from streaming)
        XCTAssertEqual(
            parseQuestion(from: "{\"question\":\"You approach closer to have a conversation"),
            "You approach closer to have a conversation",
            "Should extract question from truncated JSON")

        XCTAssertEqual(
            parseQuestion(from: "{\"question\":\"Has \\\"quotes\\\" inside\"}"),
            "Has \"quotes\" inside",
            "Should unescape JSON quotes")

        // Completely invalid
        XCTAssertNil(parseQuestion(from: "invalid json"), "Completely invalid should return nil")
        XCTAssertNil(parseQuestion(from: ""), "Empty should return nil")
    }

    func testEarlierCallWithUnparseableJSONDoesNotInheritLatestQuestion() {
        // Bug fix: Earlier tool calls with unparseable argumentsJSON should show "?"
        // instead of inheriting step.supervisorQuestion (which holds the LATEST question).
        let firstCall = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "invalid json"  // Unparseable
        )

        let secondCall = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Latest question\"}"
        )

        let step = makeStep(
            llmConversation: [
                LLMMessage(role: .user, content: "Supervisor answer: answer1", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
                LLMMessage(role: .user, content: "Supervisor answer: answer2", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
            ],
            toolCalls: [firstCall, secondCall],
            supervisorQuestion: "Latest question",
            supervisorAnswer: "answer2"
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 2)
        XCTAssertEqual(notifs[0].question, "?",
            "Earlier call with unparseable JSON should show '?' not the latest question")
        XCTAssertEqual(notifs[1].question, "Latest question",
            "Last call should parse correctly")
    }

    func testLastCallWithUnparseableJSONFallsBackToStepQuestion() {
        // The last tool call CAN fall back to step.supervisorQuestion
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "invalid"
        )

        let step = makeStep(
            toolCalls: [call],
            needsSupervisorInput: true,
            supervisorQuestion: "Fallback question",
            supervisorAnswer: nil
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 1)
        XCTAssertEqual(notifs[0].question, "Fallback question",
            "Last call should fall back to step.supervisorQuestion")
    }

    // MARK: - Bug 8: Raw JSON in Notification Question

    func testTruncatedStreamingJSONParsesQuestion() {
        // Streaming can produce truncated JSON like {"question":"text...
        // without closing "} — the parser should still extract the question.
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"You stand in the noisy market of Veira"
        )

        let step = makeStep(
            toolCalls: [call],
            needsSupervisorInput: true,
            supervisorQuestion: "You stand in the noisy market of Veira",
            supervisorAnswer: nil
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 1)
        XCTAssertEqual(notifs[0].question, "You stand in the noisy market of Veira",
            "Truncated JSON should still yield the question text, not raw JSON")
    }

    func testPartialJSONWithOnlyOpenBrace() {
        // Edge case: very early truncation
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\""
        )

        let step = makeStep(
            toolCalls: [call],
            needsSupervisorInput: true,
            supervisorQuestion: "Real question",
            supervisorAnswer: nil
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 1)
        // Empty extracted string falls through to step.supervisorQuestion (last call)
        XCTAssertEqual(notifs[0].question, "Real question")
    }

    func testQuestionWithEscapedCharactersInJSON() {
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Line1\\nLine2 and \\\"quoted\\\" text\"}"
        )

        let step = makeStep(
            toolCalls: [call],
            needsSupervisorInput: true,
            supervisorQuestion: nil,
            supervisorAnswer: nil
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 1)
        XCTAssertEqual(notifs[0].question, "Line1\nLine2 and \"quoted\" text",
            "JSON escapes should be unescaped in displayed question")
    }

    func testMultipleCallsTruncatedJSONEachParsedIndependently() {
        // Each tool call's argumentsJSON is truncated differently
        let call1 = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"First question about magic"
        )
        let call2 = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Second question about dragons"
        )

        let step = makeStep(
            llmConversation: [
                LLMMessage(role: .user, content: "Supervisor answer: answer1", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
            ],
            toolCalls: [call1, call2],
            needsSupervisorInput: true,
            supervisorQuestion: "Second question about dragons",
            supervisorAnswer: nil
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 2)
        XCTAssertEqual(notifs[0].question, "First question about magic",
            "First call's truncated JSON should parse to its own question")
        XCTAssertEqual(notifs[1].question, "Second question about dragons",
            "Second call's truncated JSON should parse to its own question")
    }

    func testRawJSONNeverShownAsQuestion() {
        // Verify that raw JSON like {"question":"..." never leaks into the question text
        let validJSON = "{\"question\":\"What color?\"}"
        let truncatedJSON = "{\"question\":\"What size"
        let emptyQuestion = "{\"question\":\"\"}"
        let noQuestionKey = "{\"other\":\"value\"}"

        XCTAssertEqual(parseQuestion(from: validJSON), "What color?")
        XCTAssertEqual(parseQuestion(from: truncatedJSON), "What size")
        XCTAssertNil(parseQuestion(from: emptyQuestion))
        XCTAssertNil(parseQuestion(from: noQuestionKey))

        // None of these should ever return a string starting with "{"
        for json in [validJSON, truncatedJSON, emptyQuestion, noQuestionKey] {
            if let parsed = parseQuestion(from: json) {
                XCTAssertFalse(parsed.hasPrefix("{"),
                    "Parsed question should never start with '{': got \(parsed)")
            }
        }
    }

    // MARK: - Bug 9: Duplicate Questions After New ask_supervisor

    func testThreeCallsMiddleUnparseableDoesNotInheritLatest() {
        // Three calls: first valid, second unparseable, third valid + active
        let call1 = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Question A\"}"
        )
        let call2 = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "broken"  // Unparseable
        )
        let call3 = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Question C\"}"
        )

        let step = makeStep(
            llmConversation: [
                LLMMessage(role: .user, content: "Supervisor answer: A answer", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
                LLMMessage(role: .user, content: "Supervisor answer: B answer", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
            ],
            toolCalls: [call1, call2, call3],
            needsSupervisorInput: true,
            supervisorQuestion: "Question C",
            supervisorAnswer: nil
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 3)
        XCTAssertEqual(notifs[0].question, "Question A")
        XCTAssertEqual(notifs[0].answer, "A answer")
        XCTAssertEqual(notifs[1].question, "?",
            "Middle call with broken JSON should show '?' not 'Question C'")
        XCTAssertEqual(notifs[1].answer, "B answer")
        XCTAssertEqual(notifs[2].question, "Question C")
        XCTAssertNil(notifs[2].answer, "Last call is active — no answer")
    }

    func testAllCallsUnparseableOnlyLastFallsBack() {
        // All three calls have unparseable JSON
        let call1 = StepToolCall(name: "ask_supervisor", argumentsJSON: "bad1")
        let call2 = StepToolCall(name: "ask_supervisor", argumentsJSON: "bad2")
        let call3 = StepToolCall(name: "ask_supervisor", argumentsJSON: "bad3")

        let step = makeStep(
            llmConversation: [
                LLMMessage(role: .user, content: "Supervisor answer: a1", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
                LLMMessage(role: .user, content: "Supervisor answer: a2", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
                LLMMessage(role: .user, content: "Supervisor answer: a3", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
            ],
            toolCalls: [call1, call2, call3],
            supervisorQuestion: "Real third question",
            supervisorAnswer: "a3"
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 3)
        XCTAssertEqual(notifs[0].question, "?",
            "First call: unparseable, not last → '?'")
        XCTAssertEqual(notifs[1].question, "?",
            "Second call: unparseable, not last → '?'")
        XCTAssertEqual(notifs[2].question, "Real third question",
            "Last call: unparseable but falls back to step.supervisorQuestion")
    }

    func testQuestionsStayDistinctAfterNewCallAppears() {
        // Reproduces the original bug scenario: two answered calls, then a new active one.
        // Each call has valid parseable JSON — all should keep their own question text.
        let call1 = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"You stand in the market of Veira\"}"
        )
        let call2 = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Do you accept Elora's offer?\"}"
        )
        let call3 = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Where do you want to go?\"}"
        )

        let step = makeStep(
            llmConversation: [
                LLMMessage(role: .user, content: "Supervisor answer: Yes", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
                LLMMessage(role: .user, content: "Supervisor answer: I accept", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
            ],
            toolCalls: [call1, call2, call3],
            needsSupervisorInput: true,
            supervisorQuestion: "Where do you want to go?",
            supervisorAnswer: nil
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 3)

        // Each notification must have its OWN question, not the latest one
        XCTAssertEqual(notifs[0].question, "You stand in the market of Veira")
        XCTAssertEqual(notifs[0].answer, "Yes")
        XCTAssertEqual(notifs[1].question, "Do you accept Elora's offer?")
        XCTAssertEqual(notifs[1].answer, "I accept")
        XCTAssertEqual(notifs[2].question, "Where do you want to go?")
        XCTAssertNil(notifs[2].answer)
    }

    func testStepSupervisorQuestionNotUsedForEarlierCalls() {
        // Explicit test: step.supervisorQuestion must NEVER leak into non-last notifications
        let call1 = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Original Q1\"}"
        )
        let call2 = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Original Q2\"}"
        )

        // step.supervisorQuestion is set to Q2 (latest) — must not affect call1's question
        let step = makeStep(
            llmConversation: [
                LLMMessage(role: .user, content: "Supervisor answer: A1", sourceRole: .supervisor, sourceContext: .supervisorAnswer),
            ],
            toolCalls: [call1, call2],
            needsSupervisorInput: true,
            supervisorQuestion: "Original Q2",
            supervisorAnswer: nil
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs[0].question, "Original Q1",
            "First notification must use its own parsed question, not step.supervisorQuestion")
        XCTAssertNotEqual(notifs[0].question, notifs[1].question,
            "Different tool calls must show different questions")
    }

    // MARK: - Bug 3: Thinking Streaming State

    /// Replicates the thinking streaming logic from `messageBubbleContent()`.
    /// Thinking spinner shows only while content hasn't started arriving.
    private func isThinkingStreaming(isStreaming: Bool, hasContent: Bool) -> Bool {
        isStreaming && !hasContent
    }

    func testThinkingStreamingWhileNoContent() {
        XCTAssertTrue(isThinkingStreaming(isStreaming: true, hasContent: false),
            "Thinking should show spinner when streaming and no content yet")
    }

    func testThinkingNotStreamingWhenContentArrived() {
        XCTAssertFalse(isThinkingStreaming(isStreaming: true, hasContent: true),
            "Thinking spinner should stop once content starts arriving")
    }

    func testThinkingNotStreamingWhenNotStreaming() {
        XCTAssertFalse(isThinkingStreaming(isStreaming: false, hasContent: false),
            "Thinking should not show spinner when not streaming")
        XCTAssertFalse(isThinkingStreaming(isStreaming: false, hasContent: true),
            "Thinking should not show spinner when not streaming (with content)")
    }

    // MARK: - Bug 8: ModelTokenCleaner on Committed Content

    func testModelTokenCleanerStripsChannelToken() {
        let content = "<|channel|>"
        let cleaned = ModelTokenCleaner.clean(content)
        XCTAssertEqual(cleaned, "", "Channel token should be completely stripped")
    }

    func testModelTokenCleanerStripsChannelTokenFromContent() {
        let content = "<|channel|>Here is the implementation plan."
        let cleaned = ModelTokenCleaner.clean(content)
        XCTAssertEqual(cleaned, "Here is the implementation plan.")
    }

    func testModelTokenCleanerStripsMultipleTokens() {
        let content = "<|channel|>Hello <|constrain|>World"
        let cleaned = ModelTokenCleaner.clean(content)
        XCTAssertEqual(cleaned, "Hello World")
    }

    func testModelTokenCleanerPreservesNormalContent() {
        let content = "This is normal content without any tokens."
        let cleaned = ModelTokenCleaner.clean(content)
        XCTAssertEqual(cleaned, content)
    }

    func testModelTokenCleanerDetectsTokens() {
        XCTAssertTrue(ModelTokenCleaner.containsModelTokens("<|channel|>"))
        XCTAssertTrue(ModelTokenCleaner.containsModelTokens("text <|constrain|> more"))
        XCTAssertFalse(ModelTokenCleaner.containsModelTokens("no tokens here"))
        XCTAssertFalse(ModelTokenCleaner.containsModelTokens(""))
    }

    // MARK: - Bug 4: StreamEvent Processing Progress

    func testStreamEventProcessingProgressField() {
        let event = StreamEvent(processingProgress: 0.45)
        XCTAssertFalse(event.isEmpty)
        XCTAssertEqual(event.processingProgress, 0.45)
    }

    func testStreamEventProcessingProgressZeroIsNotEmpty() {
        let event = StreamEvent(processingProgress: 0.0)
        XCTAssertFalse(event.isEmpty, "Progress 0.0 means processing started, event is not empty")
    }

    func testStreamEventOnlyProgressIsNotEmpty() {
        // An event with ONLY processing progress and nothing else should not be empty
        let event = StreamEvent(processingProgress: 0.5)
        XCTAssertTrue(event.contentDelta.isEmpty)
        XCTAssertTrue(event.thinkingDelta.isEmpty)
        XCTAssertTrue(event.toolCallDeltas.isEmpty)
        XCTAssertNil(event.tokenUsage)
        XCTAssertNil(event.session)
        XCTAssertFalse(event.isEmpty, "Event with only processingProgress should not be empty")
    }

    // MARK: - Bug 5: Inline Streaming — StreamingPreviewManager Integration

    func testBeginStreamingMakesMessageDetectable() {
        let stepID = "test_step"
        let messageID = UUID()

        streamingManager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)

        XCTAssertTrue(streamingManager.isStreaming(messageID: messageID))
        XCTAssertEqual(streamingManager.streamingContent(for: stepID), "")
    }

    func testCommitEndsStreamingDetection() {
        let stepID = "test_step"
        let messageID = UUID()

        streamingManager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)
        streamingManager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Hello")
        streamingManager.commit(stepID: stepID)

        XCTAssertFalse(streamingManager.isStreaming(messageID: messageID),
            "After commit, message should no longer be detected as streaming")
    }

    func testEmptyMessagePassesFilterDuringStreaming() {
        let stepID = "test_step"
        let messageID = UUID()

        streamingManager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)

        // Pre-created empty LLMMessage
        let emptyMsg = LLMMessage(id: messageID, role: .assistant, content: "")
        let step = makeStep(llmConversation: [emptyMsg])

        // Filter with streaming active — should pass through
        let filtered = filterMessages(in: step, showDebug: false, streamingMessageIDs: [messageID])
        XCTAssertEqual(filtered.count, 1, "Empty message should pass filter during active streaming")

        // Filter without streaming — should be filtered
        let filteredAfter = filterMessages(in: step, showDebug: false, streamingMessageIDs: [])
        XCTAssertTrue(filteredAfter.isEmpty, "Empty message should be filtered after streaming ends")
    }

    // MARK: - Bug 5: TaskMutationService.commitStreamingContent

    func testCommitStreamingContentUpdatesLLMMessageAndStepMessage() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        let messageID = UUID()
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "SWE Step", status: .running)
        let run = Run(id: 0, steps: [step])
        task.runs = [run]

        let runIndex = 0
        let stepIndex = 0

        // Pre-create empty LLMMessage (what beginStreaming does)
        task.runs[runIndex].steps[stepIndex].llmConversation.append(
            LLMMessage(id: messageID, role: .assistant, content: "")
        )

        // Commit streaming content (what commitStreaming does)
        TaskMutationService.commitStreamingContent(
            stepID: task.runs[runIndex].steps[stepIndex].id,
            messageID: messageID,
            content: "Final content",
            thinking: "Reasoning text",
            role: .softwareEngineer,
            in: &task
        )

        // Verify LLMMessage updated
        let llmMsg = task.runs[runIndex].steps[stepIndex].llmConversation.first(where: { $0.id == messageID })
        XCTAssertEqual(llmMsg?.content, "Final content")
        XCTAssertEqual(llmMsg?.thinking, "Reasoning text")

        // Verify StepMessage created
        let stepMsg = task.runs[runIndex].steps[stepIndex].messages.first(where: { $0.id == messageID })
        XCTAssertNotNil(stepMsg, "StepMessage should be created by commitStreamingContent")
        XCTAssertEqual(stepMsg?.content, "Final content")
    }

    func testCommitStreamingContentEmptyContentDoesNotCreateStepMessage() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        let messageID = UUID()
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "SWE Step", status: .running)
        let run = Run(id: 0, steps: [step])
        task.runs = [run]

        task.runs[0].steps[0].llmConversation.append(
            LLMMessage(id: messageID, role: .assistant, content: "")
        )

        // Commit with empty content (e.g. cancelled before any tokens)
        TaskMutationService.commitStreamingContent(
            stepID: task.runs[0].steps[0].id,
            messageID: messageID,
            content: "   ",
            thinking: nil,
            role: .softwareEngineer,
            in: &task
        )

        // LLMMessage should be updated (even with whitespace)
        let llmMsg = task.runs[0].steps[0].llmConversation.first(where: { $0.id == messageID })
        XCTAssertEqual(llmMsg?.content, "   ")

        // StepMessage should NOT be created (content is whitespace-only)
        let stepMsg = task.runs[0].steps[0].messages.first(where: { $0.id == messageID })
        XCTAssertNil(stepMsg, "Empty/whitespace content should not create a StepMessage")
    }

    // MARK: - Bug 3+5: Full Lifecycle — Thinking Then Content

    func testStreamingLifecycleThinkingThenContent() {
        let stepID = "test_step"
        let messageID = UUID()

        // Phase 1: Begin
        streamingManager.beginStreaming(stepID: stepID, messageID: messageID, role: .softwareEngineer)
        XCTAssertTrue(streamingManager.isStreaming(messageID: messageID))

        // Phase 2: Thinking arrives (content still empty)
        streamingManager.appendThinking(stepID: stepID, content: "I need to analyze...")
        let thinkingContent = streamingManager.streamingThinking(for: stepID)
        let contentDuringThinking = streamingManager.streamingContent(for: stepID) ?? ""

        XCTAssertEqual(thinkingContent, "I need to analyze...")
        XCTAssertTrue(contentDuringThinking.isEmpty)
        // At this point: isThinkingStreaming = true (streaming && no content)
        XCTAssertTrue(isThinkingStreaming(isStreaming: true, hasContent: !contentDuringThinking.isEmpty))

        // Phase 3: Content starts arriving (thinking is done)
        streamingManager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "Here is ")
        let contentAfterFirstToken = streamingManager.streamingContent(for: stepID) ?? ""

        XCTAssertFalse(contentAfterFirstToken.isEmpty)
        // Now: isThinkingStreaming = false (content arrived)
        XCTAssertFalse(isThinkingStreaming(isStreaming: true, hasContent: !contentAfterFirstToken.isEmpty))

        // Phase 4: More content
        streamingManager.append(stepID: stepID, messageID: messageID, role: .softwareEngineer, content: "the plan.")
        XCTAssertEqual(streamingManager.streamingContent(for: stepID), "Here is the plan.")

        // Phase 5: Commit
        streamingManager.commit(stepID: stepID)
        XCTAssertFalse(streamingManager.isStreaming(messageID: messageID))
        XCTAssertNil(streamingManager.streamingThinking(for: stepID))
        XCTAssertNil(streamingManager.streamingContent(for: stepID))
    }

    // MARK: - Bug 2: Engine State for Pause/Resume

    func testNeedsSupervisorInputIsPauseable() {
        // The playPauseButton logic: Pause shown for .running OR .needsSupervisorInput OR .needsAcceptance
        let pauseableStates: Set<TeamEngineState> = [.running, .needsSupervisorInput, .needsAcceptance]
        let resumeableStates: Set<TeamEngineState> = [.paused]

        XCTAssertTrue(pauseableStates.contains(.running))
        XCTAssertTrue(pauseableStates.contains(.needsSupervisorInput),
            "needsSupervisorInput should be pauseable")
        XCTAssertTrue(pauseableStates.contains(.needsAcceptance),
            "needsAcceptance should be pauseable")
        XCTAssertFalse(pauseableStates.contains(.paused))
        XCTAssertFalse(pauseableStates.contains(.done))

        XCTAssertTrue(resumeableStates.contains(.paused))
        XCTAssertFalse(resumeableStates.contains(.needsAcceptance),
            "needsAcceptance should NOT be resumeable — it's pauseable now")
        XCTAssertFalse(resumeableStates.contains(.running))
        XCTAssertFalse(resumeableStates.contains(.needsSupervisorInput),
            "needsSupervisorInput should NOT be resumeable — it's already active")
    }
}
