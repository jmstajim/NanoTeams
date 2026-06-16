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

    /// Returns `(question, answer, timestamp)` for each `ask_supervisor`
    /// notification a step would produce in the activity feed, plus an entry
    /// for the trailing active question (synthesized with `Date.distantFuture`
    /// so tests can pin "active goes last" without reaching into the composer).
    ///
    /// Delegates to `ActivityFeedBuilder` instead of replicating the criterion
    /// — otherwise a production refactor (e.g. the multi-round race fix) that
    /// changes the active-question definition silently bypasses these tests.
    ///
    /// Timestamps for resolved entries come from `buildTimelineItems`'s emit
    /// path: the matching `Supervisor answer: …` message's `createdAt`, falling
    /// back to the tool call's `createdAt` when no message exists for that
    /// index. Active entries pin to `Date.distantFuture`.
    private func supervisorNotifications(
        for step: StepExecution
    ) -> [(question: String, answer: String?, timestamp: Date)] {
        var result: [(String, String?, Date)] = []

        let items = ActivityFeedBuilder.buildTimelineItems(
            steps: [step], run: nil,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
        for tagged in items {
            guard case let .notification(_, _, type, _, _) = tagged.item,
                  case let .supervisorInput(question, answer, _, _, _, _, _) = type
            else { continue }
            result.append((question, answer, tagged.item.createdAt))
        }

        // Active question (skipped by `buildTimelineItems`, owned by the
        // docked composer) — synthesize an entry so tests that pinned
        // "active goes last" still work.
        for q in ActivityFeedBuilder.activeSupervisorQuestions(steps: [step]) {
            result.append((q.question, nil, Date.distantFuture))
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

    func testAnsweredSupervisorNotificationUsesAnswerMessageTimestamp() {
        let toolCallTime = MonotonicClock.shared.now()
        let askCall = StepToolCall(
            createdAt: toolCallTime,
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"What color?\"}"
        )
        let answerTime = MonotonicClock.shared.now()
        let answerMsg = LLMMessage(
            createdAt: answerTime,
            role: .user,
            content: "Supervisor answer: Blue",
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer
        )

        let laterTime = MonotonicClock.shared.now()
        var step = makeStep(
            llmConversation: [answerMsg],
            toolCalls: [askCall],
            supervisorQuestion: "What color?",
            supervisorAnswer: "Blue"
        )
        step.updatedAt = laterTime

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 1)
        XCTAssertEqual(notifs[0].timestamp, answerTime,
            "Answered notification should sort at the answer's createdAt (when the Supervisor responded), NOT step.updatedAt or the ask's tool-call time")
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

    /// Escalation-path answered Q&A: when the engine's drift/refusal/parse-cap
    /// fires `setNeedsSupervisorInput` directly (no `ask_supervisor` tool call)
    /// and the supervisor then answers, `emitItems` must still synthesize a
    /// history notification from `step.supervisorQuestion` + `step.supervisorAnswer`.
    /// Previously this test asserted the OPPOSITE — pinning the bug where
    /// escalation Q&As silently vanished from feed history once answered.
    /// Companion deep test: `ActivityFeedBuilderTests.testEmitItems_escalationPathAnswered_emitsHistoryNotification`.
    func testEscalationPath_answeredQuestion_emitsHistoryNotification() {
        let step = makeStep(supervisorQuestion: "Manual question?", supervisorAnswer: "Yes")
        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(
            notifs.count, 1,
            "Escalation-path answered Q&A MUST emit exactly one history notification — otherwise the Q&A disappears from the feed once answered."
        )
        XCTAssertEqual(notifs.first?.question, "Manual question?")
        XCTAssertEqual(notifs.first?.answer, "Yes")
    }

    func testMultipleAskSupervisorCallsCreateMultipleNotifications() {
        let firstCallTime = MonotonicClock.shared.now()
        let firstCall = StepToolCall(
            createdAt: firstCallTime,
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"First question\"}"
        )
        let firstAnswerTime = MonotonicClock.shared.now()

        let secondCallTime = MonotonicClock.shared.now()
        let secondCall = StepToolCall(
            createdAt: secondCallTime,
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Second question\"}"
        )
        let secondAnswerTime = MonotonicClock.shared.now()

        let step = makeStep(
            llmConversation: [
                LLMMessage(createdAt: firstAnswerTime, role: .user, content: "Supervisor answer: answer1",
                           sourceRole: .supervisor, sourceContext: .supervisorAnswer),
                LLMMessage(createdAt: secondAnswerTime, role: .user, content: "Supervisor answer: answer2",
                           sourceRole: .supervisor, sourceContext: .supervisorAnswer),
            ],
            toolCalls: [firstCall, secondCall],
            supervisorQuestion: "Second question",
            supervisorAnswer: "answer2"
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 2, "Each ask_supervisor call should get its own notification")

        XCTAssertEqual(notifs[0].question, "First question")
        XCTAssertEqual(notifs[0].answer, "answer1")
        XCTAssertEqual(notifs[0].timestamp, firstAnswerTime,
            "Answered notification sorts at the answer's createdAt")

        XCTAssertEqual(notifs[1].question, "Second question")
        XCTAssertEqual(notifs[1].answer, "answer2")
        XCTAssertEqual(notifs[1].timestamp, secondAnswerTime)
    }

    func testMultipleCallsWithLastUnanswered() {
        let firstCallTime = MonotonicClock.shared.now()
        let firstCall = StepToolCall(
            createdAt: firstCallTime,
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"First question\"}"
        )
        let firstAnswerTime = MonotonicClock.shared.now()

        let secondCallTime = MonotonicClock.shared.now()
        let secondCall = StepToolCall(
            createdAt: secondCallTime,
            name: "ask_supervisor",
            argumentsJSON: "{\"question\":\"Second question\"}"
        )

        let step = makeStep(
            llmConversation: [
                LLMMessage(createdAt: firstAnswerTime, role: .user, content: "Supervisor answer: answer1",
                           sourceRole: .supervisor, sourceContext: .supervisorAnswer),
            ],
            toolCalls: [firstCall, secondCall],
            needsSupervisorInput: true,
            supervisorQuestion: "Second question",
            supervisorAnswer: nil
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 2)

        // First: answered, sorts at the answer message's createdAt
        XCTAssertEqual(notifs[0].question, "First question")
        XCTAssertEqual(notifs[0].answer, "answer1")
        XCTAssertEqual(notifs[0].timestamp, firstAnswerTime)

        // Second: active, pinned to bottom by the synthesized entry from `activeSupervisorQuestions`
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
        let answerTime = MonotonicClock.shared.now()

        let artifactTime = MonotonicClock.shared.now()

        let step = makeStep(
            llmConversation: [
                LLMMessage(createdAt: answerTime, role: .user, content: "Supervisor answer: no",
                           sourceRole: .supervisor, sourceContext: .supervisorAnswer),
            ],
            toolCalls: [askCall],
            supervisorQuestion: "Any themes?",
            supervisorAnswer: "no"
        )

        let notifs = supervisorNotifications(for: step)
        XCTAssertEqual(notifs.count, 1)
        XCTAssertTrue(notifs[0].timestamp <= artifactTime,
            "Notification should sort before artifact created after the answer")
        XCTAssertEqual(notifs[0].timestamp, answerTime,
            "Resolved notification sorts at the answer message's createdAt (when the Supervisor responded)")
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

    /// Pins the PRODUCTION formula (`MessageBubbleView.isThinkingStreaming`),
    /// not a test-local copy — deleting `|| isStreamingToolCall` from
    /// production must fail these tests. Thinking spinner shows while content
    /// hasn't started arriving, OR while a tool-call envelope is being
    /// assembled (its text streams into the thinking preview, so the Thinking
    /// row stays the live indicator even though the visible prose froze at
    /// the marker).
    private func isThinkingStreaming(
        isStreaming: Bool, hasContent: Bool, isStreamingToolCall: Bool = false
    ) -> Bool {
        MessageBubbleView.isThinkingStreaming(
            isStreaming: isStreaming,
            hasMessageContent: hasContent,
            isStreamingToolCall: isStreamingToolCall
        )
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

    func testThinkingStreamingDuringToolCallAssembly() {
        XCTAssertTrue(
            isThinkingStreaming(isStreaming: true, hasContent: true, isStreamingToolCall: true),
            "During tool-call assembly the envelope streams into the thinking preview — the Thinking spinner must keep animating even though frozen prose is present")
        XCTAssertTrue(
            isThinkingStreaming(isStreaming: true, hasContent: false, isStreamingToolCall: true),
            "Same without prose — envelope-only turns animate the Thinking row too")
        XCTAssertFalse(
            isThinkingStreaming(isStreaming: false, hasContent: true, isStreamingToolCall: true),
            "isStreaming gate still rules — a stale flag on a committed bubble must not animate")
    }

    // MARK: - Trailing Thinking Row (chronological placement)

    /// Pins the PRODUCTION formula (`MessageBubbleView.showsTrailingThinkingRow`).
    /// The trailing animated "Thinking…" row renders BELOW the content when a
    /// tool-call envelope streams into the thinking preview after prose froze
    /// — the live activity is chronologically after the content. The top
    /// thinking section goes static in that state (its `isStreaming` is
    /// `isThinkingStreaming && !hasMessageContent`), so there is exactly one
    /// live indicator at a time.
    private func showsTrailingThinkingRow(
        isStreaming: Bool, hasContent: Bool, isStreamingToolCall: Bool, hasThinking: Bool
    ) -> Bool {
        MessageBubbleView.showsTrailingThinkingRow(
            isStreaming: isStreaming,
            hasMessageContent: hasContent,
            isStreamingToolCall: isStreamingToolCall,
            hasThinkingContent: hasThinking
        )
    }

    func testTrailingThinkingRow_showsDuringToolCallAssemblyWithContent() {
        XCTAssertTrue(
            showsTrailingThinkingRow(isStreaming: true, hasContent: true, isStreamingToolCall: true, hasThinking: true),
            "Frozen prose + envelope streaming into the thinking preview — the animated row belongs below the content")
    }

    func testTrailingThinkingRow_hiddenWithoutContent() {
        XCTAssertFalse(
            showsTrailingThinkingRow(isStreaming: true, hasContent: false, isStreamingToolCall: true, hasThinking: true),
            "No content yet — the TOP thinking section is the live indicator, no trailing row")
        XCTAssertFalse(
            showsTrailingThinkingRow(isStreaming: true, hasContent: false, isStreamingToolCall: false, hasThinking: true),
            "Plain reasoning stream — top section animates, no trailing row")
    }

    func testTrailingThinkingRow_hiddenWithoutThinking() {
        XCTAssertFalse(
            showsTrailingThinkingRow(isStreaming: true, hasContent: true, isStreamingToolCall: true, hasThinking: false),
            "Empty thinking preview — the indicator's 'Generating' fallback covers this gap, not the thinking row")
    }

    func testTrailingThinkingRow_hiddenWhileProseStreams() {
        XCTAssertFalse(
            showsTrailingThinkingRow(isStreaming: true, hasContent: true, isStreamingToolCall: false, hasThinking: true),
            "Prose still growing, no tool call — the growing text is the live indicator")
    }

    func testTrailingThinkingRow_hiddenWhenNotStreaming() {
        XCTAssertFalse(
            showsTrailingThinkingRow(isStreaming: false, hasContent: true, isStreamingToolCall: true, hasThinking: true),
            "Committed bubble — stale flags must not resurrect the trailing row")
    }

    func testTopThinkingRow_goesStaticDuringToolCallAssemblyWithContent() {
        XCTAssertFalse(
            MessageBubbleView.topThinkingRowAnimates(
                isStreaming: true, hasMessageContent: true, isStreamingToolCall: true),
            "Envelope assembly with frozen prose — the TRAILING row carries the animation; the top section must go static. (Passing plain isThinkingStreaming here would resurrect the double-animated-row bug.)")
    }

    func testTopThinkingRow_animatesWhileReasoningIsLiveTail() {
        XCTAssertTrue(
            MessageBubbleView.topThinkingRowAnimates(
                isStreaming: true, hasMessageContent: false, isStreamingToolCall: false),
            "Reasoning streaming, no content yet — top section is the live indicator")
        XCTAssertTrue(
            MessageBubbleView.topThinkingRowAnimates(
                isStreaming: true, hasMessageContent: false, isStreamingToolCall: true),
            "Envelope-only turn (no prose) — top section still carries the animation")
    }

    /// Exhaustive 16-combo pin of the "exactly one live thinking indicator"
    /// invariant the doc comments promise: the top section and the trailing
    /// row must never animate simultaneously, whatever the flags.
    func testThinkingRows_neverBothAnimate() {
        for isStreaming in [false, true] {
            for hasContent in [false, true] {
                for toolCall in [false, true] {
                    for hasThinking in [false, true] {
                        let top = MessageBubbleView.topThinkingRowAnimates(
                            isStreaming: isStreaming,
                            hasMessageContent: hasContent,
                            isStreamingToolCall: toolCall)
                        let trailing = MessageBubbleView.showsTrailingThinkingRow(
                            isStreaming: isStreaming,
                            hasMessageContent: hasContent,
                            isStreamingToolCall: toolCall,
                            hasThinkingContent: hasThinking)
                        XCTAssertFalse(top && trailing,
                            "Both thinking rows animating at once (isStreaming: \(isStreaming), hasContent: \(hasContent), toolCall: \(toolCall), hasThinking: \(hasThinking))")
                    }
                }
            }
        }
    }

    // MARK: - Corner cases: cross-component live-indicator invariants

    /// Mirrors `MessageBubbleView.body`'s render gate for the top thinking
    /// section: the row exists only when `hasThinkingContent`, and animates
    /// per `topThinkingRowAnimates`. The helpers alone don't model the
    /// `if hasThinkingContent` wrapper — these corner tests must, or the
    /// matrix would report false conflicts for rows that never render.
    private func renderedTopRowAnimates(
        isStreaming: Bool, hasContent: Bool, toolCall: Bool, hasThinking: Bool
    ) -> Bool {
        hasThinking && MessageBubbleView.topThinkingRowAnimates(
            isStreaming: isStreaming,
            hasMessageContent: hasContent,
            isStreamingToolCall: toolCall
        )
    }

    /// Corner pin across the FULL flag matrix (128 combos), composing the
    /// row helpers with the PRODUCTION `resolveStatusText`: at any moment at
    /// most ONE live indicator renders — animated top row, animated trailing
    /// row, or an indicator status text. Catches cross-component drift that
    /// the per-symbol truth tables can't (e.g. a future `resolveStatusText`
    /// branch returning text while `hasThinkingContent` is true would pass
    /// its own suite but double-indicate here).
    func testLiveIndicators_atMostOne_acrossFullFlagMatrix() {
        for isStreaming in [false, true] {
            for hasContent in [false, true] {
                for toolCall in [false, true] {
                    for hasThinking in [false, true] {
                        for progress in [nil, 0.42] as [Double?] {
                            for activity in [false, true] {
                                // Production never sets both: resolveImplicitStreamTarget
                                // returns false for the live preview target. The
                                // `&& activity` conjunct is matrix pruning only (an
                                // implicit target with no activity has no live
                                // indicator candidates at all) — production does NOT
                                // couple the two; `BubbleInputs.committed` zeroes
                                // `hasStreamActivity` regardless.
                                let implicitTarget = !isStreaming && activity

                                let top = renderedTopRowAnimates(
                                    isStreaming: isStreaming, hasContent: hasContent,
                                    toolCall: toolCall, hasThinking: hasThinking)
                                let trailing = MessageBubbleView.showsTrailingThinkingRow(
                                    isStreaming: isStreaming,
                                    hasMessageContent: hasContent,
                                    isStreamingToolCall: toolCall,
                                    hasThinkingContent: hasThinking)
                                let statusText = MessageBubbleStreamingIndicator.resolveStatusText(
                                    isStreaming: isStreaming,
                                    isImplicitStreamTarget: implicitTarget,
                                    hasMessageContent: hasContent,
                                    hasThinkingContent: hasThinking,
                                    processingProgress: progress,
                                    hasStreamActivity: activity,
                                    isStreamingToolCall: toolCall)

                                let liveCount = [top, trailing, statusText != nil].filter(\.self).count
                                XCTAssertLessThanOrEqual(liveCount, 1,
                                    "Multiple live indicators (top: \(top), trailing: \(trailing), status: \(statusText ?? "nil")) at (isStreaming: \(isStreaming), hasContent: \(hasContent), toolCall: \(toolCall), hasThinking: \(hasThinking), progress: \(String(describing: progress)), activity: \(activity))")
                            }
                        }
                    }
                }
            }
        }
    }

    /// Liveness corner pin — the inverse of the exclusivity test: while
    /// streaming, the bubble must NEVER show zero animation. Every streaming
    /// state must surface at least one live signal: an animated thinking row,
    /// an indicator status text, or visibly growing prose (content present
    /// with no tool-call freeze — the growing text itself is the indicator).
    /// This is the regression class of the original 37s zero-animation
    /// freeze during tool-call envelope assembly: a future edit that hides a
    /// row without handing the live signal to another component fails here.
    func testStreamingBubble_alwaysHasLiveSignal() {
        for hasContent in [false, true] {
            for toolCall in [false, true] {
                for hasThinking in [false, true] {
                    for progress in [nil, 0.42] as [Double?] {
                        for activity in [false, true] {
                            let top = renderedTopRowAnimates(
                                isStreaming: true, hasContent: hasContent,
                                toolCall: toolCall, hasThinking: hasThinking)
                            let trailing = MessageBubbleView.showsTrailingThinkingRow(
                                isStreaming: true,
                                hasMessageContent: hasContent,
                                isStreamingToolCall: toolCall,
                                hasThinkingContent: hasThinking)
                            let statusText = MessageBubbleStreamingIndicator.resolveStatusText(
                                isStreaming: true,
                                isImplicitStreamTarget: false,
                                hasMessageContent: hasContent,
                                hasThinkingContent: hasThinking,
                                processingProgress: progress,
                                hasStreamActivity: activity,
                                isStreamingToolCall: toolCall)
                            let growingProse = hasContent && !toolCall

                            XCTAssertTrue(top || trailing || statusText != nil || growingProse,
                                "Zero live signal while streaming at (hasContent: \(hasContent), toolCall: \(toolCall), hasThinking: \(hasThinking), progress: \(String(describing: progress)), activity: \(activity))")
                        }
                    }
                }
            }
        }
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

        streamingManager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)

        XCTAssertTrue(streamingManager.isStreaming(messageID: messageID))
        XCTAssertEqual(streamingManager.streamingContent(stepID: stepID, taskID: 0), "")
    }

    func testCommitEndsStreamingDetection() {
        let stepID = "test_step"
        let messageID = UUID()

        streamingManager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)
        streamingManager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Hello")
        streamingManager.commit(stepID: stepID, taskID: 0)

        XCTAssertFalse(streamingManager.isStreaming(messageID: messageID),
            "After commit, message should no longer be detected as streaming")
    }

    func testEmptyMessagePassesFilterDuringStreaming() {
        let stepID = "test_step"
        let messageID = UUID()

        streamingManager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)

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
        streamingManager.beginStreaming(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer)
        XCTAssertTrue(streamingManager.isStreaming(messageID: messageID))

        // Phase 2: Thinking arrives (content still empty)
        streamingManager.appendThinking(stepID: stepID, taskID: 0, content: "I need to analyze...")
        let thinkingContent = streamingManager.streamingThinking(stepID: stepID, taskID: 0)
        let contentDuringThinking = streamingManager.streamingContent(stepID: stepID, taskID: 0) ?? ""

        XCTAssertEqual(thinkingContent, "I need to analyze...")
        XCTAssertTrue(contentDuringThinking.isEmpty)
        // At this point: isThinkingStreaming = true (streaming && no content)
        XCTAssertTrue(isThinkingStreaming(isStreaming: true, hasContent: !contentDuringThinking.isEmpty))

        // Phase 3: Content starts arriving (thinking is done)
        streamingManager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "Here is ")
        let contentAfterFirstToken = streamingManager.streamingContent(stepID: stepID, taskID: 0) ?? ""

        XCTAssertFalse(contentAfterFirstToken.isEmpty)
        // Now: isThinkingStreaming = false (content arrived)
        XCTAssertFalse(isThinkingStreaming(isStreaming: true, hasContent: !contentAfterFirstToken.isEmpty))

        // Phase 4: More content
        streamingManager.append(stepID: stepID, taskID: 0, messageID: messageID, role: .softwareEngineer, content: "the plan.")
        XCTAssertEqual(streamingManager.streamingContent(stepID: stepID, taskID: 0), "Here is the plan.")

        // Phase 5: Commit
        streamingManager.commit(stepID: stepID, taskID: 0)
        XCTAssertFalse(streamingManager.isStreaming(messageID: messageID))
        XCTAssertNil(streamingManager.streamingThinking(stepID: stepID, taskID: 0))
        XCTAssertNil(streamingManager.streamingContent(stepID: stepID, taskID: 0))
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

    // MARK: - shouldShowComposer (chat-mode visibility regression)
    //
    // Pure-logic tests for the static helper extracted from TeamActivityFeedView.
    // The bug: chat-mode tasks whose engine state seeded as .done after restart
    // (e.g. Personal Assistant whose only step is the auto-completed Supervisor
    // Task) hid the composer because the previous switch returned false on .done.
    // Fix: chat-mode tasks always show the composer until explicitly closed.

    func testShouldShowComposer_chatMode_engineDone_visible() {
        XCTAssertTrue(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: false, activeTaskID: 1, closedAt: nil,
            isChatMode: true, engineState: .done))
    }

    /// A failed engine keeps the composer visible: sending a message resumes/retries
    /// the run (`QuickCaptureController.tryFlushQueuedMessages` → `resumeRun` revives
    /// the failed step). Chat-mode failed tasks (e.g. Coding Agent after an LLM error)
    /// must be retryable by message.
    func testShouldShowComposer_chatMode_engineFailed_visible() {
        XCTAssertTrue(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: false, activeTaskID: 1, closedAt: nil,
            isChatMode: true, engineState: .failed))
    }

    func testShouldShowComposer_chatMode_enginePaused_visible() {
        XCTAssertTrue(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: false, activeTaskID: 1, closedAt: nil,
            isChatMode: true, engineState: .paused))
    }

    func testShouldShowComposer_chatMode_engineNil_visible() {
        XCTAssertTrue(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: false, activeTaskID: 1, closedAt: nil,
            isChatMode: true, engineState: nil))
    }

    func testShouldShowComposer_chatMode_closedAtSet_hidden() {
        XCTAssertFalse(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: false, activeTaskID: 1, closedAt: Date(),
            isChatMode: true, engineState: .paused))
    }

    func testShouldShowComposer_nonChat_engineDone_hidden() {
        XCTAssertFalse(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: false, activeTaskID: 1, closedAt: nil,
            isChatMode: false, engineState: .done))
    }

    func testShouldShowComposer_nonChat_enginePaused_visible() {
        XCTAssertTrue(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: false, activeTaskID: 1, closedAt: nil,
            isChatMode: false, engineState: .paused))
    }

    /// Non-chat failed task: composer stays visible so the Supervisor can send a
    /// message to resume/retry the run (the user-reported flow). `.done`/`nil` still hide.
    func testShouldShowComposer_nonChat_engineFailed_visible() {
        XCTAssertTrue(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: false, activeTaskID: 1, closedAt: nil,
            isChatMode: false, engineState: .failed))
    }

    func testShouldShowComposer_nonChat_engineNil_hidden() {
        XCTAssertFalse(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: false, activeTaskID: 1, closedAt: nil,
            isChatMode: false, engineState: nil))
    }

    /// Read-only wins over the `.failed`-is-resumable rule: a read-only failed task hides
    /// the composer (pins guard precedence — `isReadOnly` returns before the engineState switch).
    func testShouldShowComposer_readOnly_nonChat_engineFailed_hidden() {
        XCTAssertFalse(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: true, activeTaskID: 1, closedAt: nil,
            isChatMode: false, engineState: .failed))
    }

    func testShouldShowComposer_readOnly_alwaysHidden() {
        // read-only wins over chat-mode
        XCTAssertFalse(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: true, activeTaskID: 1, closedAt: nil,
            isChatMode: true, engineState: .paused))
        XCTAssertFalse(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: true, activeTaskID: 1, closedAt: nil,
            isChatMode: false, engineState: .running))
    }

    func testShouldShowComposer_noActiveTask_hidden() {
        XCTAssertFalse(TeamActivityFeedView.shouldShowComposer(
            isReadOnly: false, activeTaskID: nil, closedAt: nil,
            isChatMode: true, engineState: .paused))
    }

    // MARK: - runDataVersion (recompute trigger)

    /// `runDataVersion` is the gate for `recomputeAndRebuild` — when it changes,
    /// `.onChange(of: runDataVersion)` fires and the view model refreshes
    /// `cachedSupervisorQuestions` so the composer chip and question card render.
    /// Engine escalation paths (`setNeedsSupervisorInput` from drift/refusal/
    /// parse-failure caps in `LLMExecutionService+StepFlowControl.swift`) flip
    /// `step.needsSupervisorInput=true` WITHOUT appending a tool call or LLM
    /// message — so a hash that only walks `toolCalls.count`/`llmConversation.count`
    /// stays stable, the recompute never fires, and the user has to switch tasks
    /// back and forth to force a fresh view rebuild.
    ///
    /// Pinned because the bug is invisible from the activeQuestions side:
    /// `activeSupervisorQuestions` itself works correctly (companion test
    /// `testEscalationPath_emptyAskCalls_flagSet_surfacesStoredQuestion`); the
    /// cache just never gets recomputed.
    func testComputeRunDataVersion_changesWhenNeedsSupervisorInputFlips() {
        let stepOff = makeStep(needsSupervisorInput: false)
        let stepOn = makeStep(needsSupervisorInput: true)
        let runOff = Run(id: 0, steps: [stepOff])
        let runOn = Run(id: 0, steps: [stepOn])

        let versionOff = TeamActivityFeedView.computeRunDataVersion(run: runOff, descendants: [])
        let versionOn = TeamActivityFeedView.computeRunDataVersion(run: runOn, descendants: [])

        XCTAssertNotEqual(
            versionOff, versionOn,
            "needsSupervisorInput MUST contribute to runDataVersion — otherwise the escalation path silently fails to trigger recomputeAndRebuild."
        )
    }

    /// `step.status` flipping `.running` → `.paused` / `.done` without any count
    /// change (e.g. `pauseRun`, `finishAdvisoryRole`) must invalidate the hash —
    /// otherwise the dispatcher's `resolveImplicitStreamTarget` keeps returning
    /// `true` against a stale `cachedAllSteps[i].status`, and a residual
    /// `processingProgress` would mis-surface "Processing" on a paused step.
    func testComputeRunDataVersion_changesWhenStepStatusFlips() {
        let stepRunning = makeStep(status: .running)
        let stepPaused = makeStep(status: .paused)
        let runRunning = Run(id: 0, steps: [stepRunning])
        let runPaused = Run(id: 0, steps: [stepPaused])

        XCTAssertNotEqual(
            TeamActivityFeedView.computeRunDataVersion(run: runRunning, descendants: []),
            TeamActivityFeedView.computeRunDataVersion(run: runPaused, descendants: []),
            "step.status MUST contribute to runDataVersion — otherwise status-only transitions (pause/finish-advisory) leave cachedAllSteps stale"
        )
    }

    /// Sibling regression: counts (toolCalls / llmConversation / artifacts) must
    /// still affect the hash. Without this, a Green-phase implementation could
    /// accidentally remove existing fields while adding needsSupervisorInput.
    func testComputeRunDataVersion_changesWhenToolCallCountGrows() {
        let step0 = makeStep(toolCalls: [])
        let step1 = makeStep(toolCalls: [
            StepToolCall(name: "read_file", argumentsJSON: "{}", resultJSON: "{}")
        ])
        let run0 = Run(id: 0, steps: [step0])
        let run1 = Run(id: 0, steps: [step1])

        let v0 = TeamActivityFeedView.computeRunDataVersion(run: run0, descendants: [])
        let v1 = TeamActivityFeedView.computeRunDataVersion(run: run1, descendants: [])
        XCTAssertNotEqual(v0, v1, "Tool call growth must change runDataVersion")
    }

    /// LLM conversation growth (each iteration appends a message) must propagate
    /// to runDataVersion — the primary signal during normal streaming.
    func testComputeRunDataVersion_changesWhenLLMConversationGrows() {
        let step0 = makeStep(llmConversation: [])
        let step1 = makeStep(llmConversation: [
            LLMMessage(role: .assistant, content: "hello")
        ])
        let run0 = Run(id: 0, steps: [step0])
        let run1 = Run(id: 0, steps: [step1])

        XCTAssertNotEqual(
            TeamActivityFeedView.computeRunDataVersion(run: run0, descendants: []),
            TeamActivityFeedView.computeRunDataVersion(run: run1, descendants: []),
            "LLM conversation growth must change runDataVersion"
        )
    }

    func testComputeRunDataVersion_changesWhenLastMessageUpdatedInPlace() {
        // The retry-note collapse mutates the last message's content + createdAt
        // WITHOUT changing the count. The version must still change so the feed
        // rebuilds and the bubble doesn't show a stale attempt counter.
        let attempt1 = LLMMessage(
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            role: .assistant,
            content: "\(LLMConstants.llmServerErrorRetryNotePrefix) 1): retrying")
        let attempt2 = LLMMessage(
            id: attempt1.id,
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            role: .assistant,
            content: "\(LLMConstants.llmServerErrorRetryNotePrefix) 2): retrying")
        let runBefore = Run(id: 0, steps: [makeStep(llmConversation: [attempt1])])
        let runAfter = Run(id: 0, steps: [makeStep(llmConversation: [attempt2])])

        XCTAssertEqual(
            runBefore.steps[0].llmConversation.count,
            runAfter.steps[0].llmConversation.count,
            "Precondition: collapse keeps the message count constant")
        XCTAssertNotEqual(
            TeamActivityFeedView.computeRunDataVersion(run: runBefore, descendants: []),
            TeamActivityFeedView.computeRunDataVersion(run: runAfter, descendants: []),
            "In-place update of the last message (collapsing retry note) must change runDataVersion"
        )
    }

    func testComputeRunDataVersion_descendantInPlaceLastMessageUpdate_changesVersion() {
        // The descendant loop also folds in last?.createdAt — a delegated child's
        // in-place retry-note update (same count) must still trigger a rebuild.
        func descendant(lastCreatedAt: Date) -> ActivityFeedBuilder.DescendantTask {
            let msg = LLMMessage(createdAt: lastCreatedAt, role: .assistant,
                                 content: "\(LLMConstants.llmServerErrorRetryNotePrefix) 1)…")
            let step = makeStep(llmConversation: [msg])
            let childTask = NTMSTask(id: 99, title: "Child", supervisorTask: "g",
                                     runs: [Run(id: 0, steps: [step])])
            return ActivityFeedBuilder.DescendantTask(
                task: childTask, run: Run(id: 0, steps: [step]),
                teamRoles: [], teamName: "Child Team", delegationDepth: 1,
                delegatedFromRoleName: "Coding Agent")
        }
        XCTAssertNotEqual(
            TeamActivityFeedView.computeRunDataVersion(
                run: nil, descendants: [descendant(lastCreatedAt: Date(timeIntervalSinceReferenceDate: 100))]),
            TeamActivityFeedView.computeRunDataVersion(
                run: nil, descendants: [descendant(lastCreatedAt: Date(timeIntervalSinceReferenceDate: 200))]),
            "A descendant's in-place last-message update must change the version")
    }

    func testComputeRunDataVersion_runStepInPlaceLastMessageUpdate_changesVersion() {
        // The single-run `run` path folds in last?.createdAt, so an in-place update
        // to the last message (count unchanged) still flips the hash.
        func makeRun(lastCreatedAt: Date) -> Run {
            Run(id: 0, steps: [makeStep(llmConversation: [
                LLMMessage(createdAt: lastCreatedAt, role: .assistant, content: "note")
            ])])
        }
        XCTAssertNotEqual(
            TeamActivityFeedView.computeRunDataVersion(
                run: makeRun(lastCreatedAt: Date(timeIntervalSinceReferenceDate: 100)), descendants: []),
            TeamActivityFeedView.computeRunDataVersion(
                run: makeRun(lastCreatedAt: Date(timeIntervalSinceReferenceDate: 200)), descendants: []),
            "A run-step in-place last-message update must change the version")
    }

    func testComputeRunDataVersion_allEmpty_isDeterministic() {
        // No run, no descendants → a stable hash (the last?.createdAt fold must not
        // introduce timestamp-based churn).
        XCTAssertEqual(
            TeamActivityFeedView.computeRunDataVersion(run: nil, descendants: []),
            TeamActivityFeedView.computeRunDataVersion(run: nil, descendants: []))
    }

    /// Stability check: hash must NOT change when nothing relevant did. Without
    /// this, future field additions could accidentally make runDataVersion
    /// non-deterministic (e.g. timestamp-based hashing), spamming
    /// recomputeAndRebuild every render.
    func testComputeRunDataVersion_stableWhenNothingChanges() {
        let step = makeStep(needsSupervisorInput: true, supervisorQuestion: "Q")
        let run = Run(id: 0, steps: [step])

        let v1 = TeamActivityFeedView.computeRunDataVersion(run: run, descendants: [])
        let v2 = TeamActivityFeedView.computeRunDataVersion(run: run, descendants: [])
        XCTAssertEqual(v1, v2, "Same input must produce same hash — otherwise recompute fires on every render")
    }

    /// Nil run must produce a stable, valid hash (not crash). Initial app load
    /// passes nil before the active task is resolved.
    func testComputeRunDataVersion_nilRun_returnsStableHash() {
        let v1 = TeamActivityFeedView.computeRunDataVersion(run: nil, descendants: [])
        let v2 = TeamActivityFeedView.computeRunDataVersion(run: nil, descendants: [])
        XCTAssertEqual(v1, v2, "Nil run must be stable")
    }

    /// Critical regression: `needsSupervisorInput` flipping in a DELEGATED
    /// descendant must also trigger recompute — otherwise child-team supervisor
    /// questions stay invisible until task switch (the same bug as for the
    /// active run, but in the descendant branch of the hash).
    func testComputeRunDataVersion_changesWhenDescendantNeedsSupervisorInputFlips() {
        let descTask = NTMSTask(id: 1, title: "Child", supervisorTask: "Child task")
        let stepOff = makeStep(needsSupervisorInput: false)
        let stepOn = makeStep(needsSupervisorInput: true)
        let descRunOff = Run(id: 0, steps: [stepOff])
        let descRunOn = Run(id: 0, steps: [stepOn])

        let descOff = ActivityFeedBuilder.DescendantTask(
            task: descTask, run: descRunOff, teamRoles: [],
            teamName: "Child Team", delegationDepth: 1, delegatedFromRoleName: "Parent Role"
        )
        let descOn = ActivityFeedBuilder.DescendantTask(
            task: descTask, run: descRunOn, teamRoles: [],
            teamName: "Child Team", delegationDepth: 1, delegatedFromRoleName: "Parent Role"
        )

        let vOff = TeamActivityFeedView.computeRunDataVersion(run: nil, descendants: [descOff])
        let vOn = TeamActivityFeedView.computeRunDataVersion(run: nil, descendants: [descOn])
        XCTAssertNotEqual(
            vOff, vOn,
            "Descendant step's needsSupervisorInput must contribute — otherwise child-team escalations also stay hidden until task switch."
        )
    }
}
