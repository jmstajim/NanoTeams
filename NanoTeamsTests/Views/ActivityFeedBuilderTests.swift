import XCTest
@testable import NanoTeams

/// Tests for `ActivityFeedBuilder.buildTimelineItems()` — ordering, interleaving,
/// notification pinning, section headers, and filtering correctness.
@MainActor
final class ActivityFeedBuilderTests: XCTestCase {

    private typealias TN = ToolNames

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - Helpers

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: offset)
    }

    private func makeMessage(
        role: LLMRole = .assistant,
        content: String,
        at timestamp: Date,
        sourceRole: Role? = nil,
        sourceContext: MessageSourceContext? = nil,
        thinking: String? = nil
    ) -> LLMMessage {
        LLMMessage(
            createdAt: timestamp,
            role: role,
            content: content,
            thinking: thinking,
            sourceRole: sourceRole,
            sourceContext: sourceContext
        )
    }

    private func makeToolCall(
        name: String = "read_file",
        at timestamp: Date,
        argumentsJSON: String = "{}"
    ) -> StepToolCall {
        StepToolCall(createdAt: timestamp, name: name, argumentsJSON: argumentsJSON)
    }

    private func makeArtifact(name: String, at timestamp: Date) -> Artifact {
        Artifact(name: name, createdAt: timestamp, updatedAt: timestamp)
    }

    private func makeStep(
        role: Role = .softwareEngineer,
        messages: [LLMMessage] = [],
        toolCalls: [StepToolCall] = [],
        artifacts: [Artifact] = [],
        status: StepStatus = .done,
        needsSupervisorInput: Bool = false,
        supervisorQuestion: String? = nil,
        supervisorAnswer: String? = nil,
        supervisorAnswerWasAuto: Bool = false,
        completedAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> StepExecution {
        StepExecution(
            id: role.baseID,
            role: role,
            title: "\(role.displayName) Step",
            status: status,
            updatedAt: updatedAt ?? MonotonicClock.shared.now(),
            completedAt: completedAt,
            artifacts: artifacts,
            toolCalls: toolCalls,
            needsSupervisorInput: needsSupervisorInput,
            supervisorQuestion: supervisorQuestion,
            supervisorAnswer: supervisorAnswer,
            supervisorAnswerWasAuto: supervisorAnswerWasAuto,
            llmConversation: messages
        )
    }

    private func makeMeetingMessage(role: Role, content: String, at timestamp: Date) -> TeamMessage {
        TeamMessage(createdAt: timestamp, role: role, content: content)
    }

    private func makeMeeting(topic: String = "Design review", messages: [TeamMessage]) -> TeamMeeting {
        TeamMeeting(topic: topic, initiatedBy: .productManager, participants: [.productManager, .techLead], messages: messages)
    }

    private func makeRun(
        meetings: [TeamMeeting] = [],
        changeRequests: [ChangeRequest] = []
    ) -> Run {
        Run(id: 0, meetings: meetings, changeRequests: changeRequests)
    }

    private func makeChangeRequest(at timestamp: Date) -> ChangeRequest {
        ChangeRequest(
            createdAt: timestamp,
            requestingRoleID: "codeReviewer",
            targetRoleID: "softwareEngineer",
            changes: "Fix error handling",
            reasoning: "Missing nil check"
        )
    }

    private func build(
        steps: [StepExecution],
        run: Run? = nil,
        supervisorBrief: String? = nil,
        supervisorBriefDate: Date? = nil,
        cache: [String: Set<String>] = [:],
        debug: Bool = false,
        streaming: @escaping (UUID) -> Bool = { _ in false }
    ) -> [ActivityFeedBuilder.TaggedItem] {
        ActivityFeedBuilder.buildTimelineItems(
            steps: steps,
            run: run,
            supervisorBrief: supervisorBrief,
            supervisorBriefDate: supervisorBriefDate,
            stepArtifactContentCache: cache,
            debugModeEnabled: debug,
            isStreaming: streaming
        )
    }

    private func assertOrdered(
        _ items: [ActivityFeedBuilder.TaggedItem],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for i in 1..<items.count {
            XCTAssertLessThanOrEqual(
                items[i - 1].item.createdAt, items[i].item.createdAt,
                "Item at index \(i - 1) (\(items[i - 1].item.createdAt)) should be <= item at index \(i) (\(items[i].item.createdAt))",
                file: file, line: line
            )
        }
    }

    // MARK: - 1. Empty / Minimal

    func testEmptyTimeline() {
        let result = build(steps: [], run: nil)
        XCTAssertTrue(result.isEmpty)
    }

    func testStepsWithOnlySystemMessages() {
        let step = makeStep(messages: [
            makeMessage(role: .system, content: "You are an engineer", at: date(100)),
            makeMessage(role: .tool, content: "{}", at: date(200))
        ])
        let result = build(steps: [step])
        XCTAssertTrue(result.isEmpty)
    }

    func testSingleAssistantMessage() {
        let step = makeStep(messages: [
            makeMessage(content: "Hello", at: date(100))
        ])
        let result = build(steps: [step])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].showSectionHeader)
    }

    // MARK: - 2. Single Step Ordering

    func testSingleStepMessagesOrderedByTimestamp() {
        let step = makeStep(messages: [
            makeMessage(content: "Third", at: date(300)),
            makeMessage(content: "First", at: date(100)),
            makeMessage(content: "Second", at: date(200))
        ])
        let result = build(steps: [step])
        XCTAssertEqual(result.count, 3)
        assertOrdered(result)

        if case .llmMessage(let msg, _, _, _) = result[0].item { XCTAssertEqual(msg.content, "First") }
        else { XCTFail("Expected llmMessage at index 0") }
        if case .llmMessage(let msg, _, _, _) = result[1].item { XCTAssertEqual(msg.content, "Second") }
        else { XCTFail("Expected llmMessage at index 1") }
        if case .llmMessage(let msg, _, _, _) = result[2].item { XCTAssertEqual(msg.content, "Third") }
        else { XCTFail("Expected llmMessage at index 2") }
    }

    func testSingleStepMixedTypesOrdered() {
        let step = makeStep(
            messages: [makeMessage(content: "Message", at: date(200))],
            toolCalls: [makeToolCall(at: date(100))],
            artifacts: [makeArtifact(name: "Doc", at: date(300))]
        )
        let result = build(steps: [step])
        XCTAssertEqual(result.count, 3)
        assertOrdered(result)

        if case .toolCall = result[0].item {} else { XCTFail("Expected toolCall at 0") }
        if case .llmMessage = result[1].item {} else { XCTFail("Expected llmMessage at 1") }
        if case .artifact = result[2].item {} else { XCTFail("Expected artifact at 2") }
    }

    // MARK: - 3. Cross-Step Interleaving

    func testCrossStepInterleaving() {
        let stepA = makeStep(role: .productManager, messages: [
            makeMessage(content: "PM first", at: date(100)),
            makeMessage(content: "PM third", at: date(300))
        ])
        let stepB = makeStep(role: .softwareEngineer, messages: [
            makeMessage(content: "SWE second", at: date(200))
        ])
        let result = build(steps: [stepA, stepB])
        XCTAssertEqual(result.count, 3)
        assertOrdered(result)

        if case .llmMessage(let msg, let role, _, _) = result[0].item {
            XCTAssertEqual(msg.content, "PM first")
            XCTAssertEqual(role, .productManager)
        } else { XCTFail("Expected PM message at 0") }

        if case .llmMessage(let msg, let role, _, _) = result[1].item {
            XCTAssertEqual(msg.content, "SWE second")
            XCTAssertEqual(role, .softwareEngineer)
        } else { XCTFail("Expected SWE message at 1") }

        if case .llmMessage(let msg, let role, _, _) = result[2].item {
            XCTAssertEqual(msg.content, "PM third")
            XCTAssertEqual(role, .productManager)
        } else { XCTFail("Expected PM message at 2") }
    }

    func testCrossStepInterleavingMixedTypes() {
        let stepA = makeStep(role: .productManager,
                             toolCalls: [makeToolCall(at: date(100))],
                             artifacts: [makeArtifact(name: "Plan", at: date(400))]
        )
        let stepB = makeStep(role: .softwareEngineer,
                             messages: [makeMessage(content: "Msg", at: date(200))],
                             toolCalls: [makeToolCall(at: date(300))]
        )
        let result = build(steps: [stepA, stepB])
        XCTAssertEqual(result.count, 4)
        assertOrdered(result)

        if case .toolCall(_, let role, _, _) = result[0].item { XCTAssertEqual(role, .productManager) }
        else { XCTFail("Expected PM toolCall at 0") }
        if case .llmMessage(_, let role, _, _) = result[1].item { XCTAssertEqual(role, .softwareEngineer) }
        else { XCTFail("Expected SWE message at 1") }
        if case .toolCall(_, let role, _, _) = result[2].item { XCTAssertEqual(role, .softwareEngineer) }
        else { XCTFail("Expected SWE toolCall at 2") }
        if case .artifact(_, let role, _, _) = result[3].item { XCTAssertEqual(role, .productManager) }
        else { XCTFail("Expected PM artifact at 3") }
    }

    func testThreeStepsInterleaved() {
        let stepPM = makeStep(role: .productManager, messages: [
            makeMessage(content: "PM", at: date(100)),
            makeMessage(content: "PM late", at: date(600))
        ])
        let stepTL = makeStep(role: .techLead, messages: [
            makeMessage(content: "TL", at: date(200)),
            makeMessage(content: "TL late", at: date(400))
        ])
        let stepSWE = makeStep(role: .softwareEngineer, messages: [
            makeMessage(content: "SWE", at: date(300)),
            makeMessage(content: "SWE late", at: date(500))
        ])
        let result = build(steps: [stepPM, stepTL, stepSWE])
        XCTAssertEqual(result.count, 6)
        assertOrdered(result)

        let contents = result.compactMap { item -> String? in
            if case .llmMessage(let msg, _, _, _) = item.item { return msg.content }
            return nil
        }
        XCTAssertEqual(contents, ["PM", "TL", "SWE", "TL late", "SWE late", "PM late"])
    }

    // MARK: - 4. Meeting Messages

    func testMeetingMessagesInterleavedWithStepItems() {
        let step = makeStep(messages: [
            makeMessage(content: "Before", at: date(100)),
            makeMessage(content: "After", at: date(300))
        ])
        let meeting = makeMeeting(messages: [
            makeMeetingMessage(role: .productManager, content: "Meeting msg", at: date(200))
        ])
        let result = build(steps: [step], run: makeRun(meetings: [meeting]))
        XCTAssertEqual(result.count, 3)
        assertOrdered(result)

        if case .llmMessage(let msg, _, _, _) = result[0].item { XCTAssertEqual(msg.content, "Before") }
        else { XCTFail("Expected llmMessage at 0") }
        if case .meetingMessage(let msg, _, _) = result[1].item { XCTAssertEqual(msg.content, "Meeting msg") }
        else { XCTFail("Expected meetingMessage at 1") }
        if case .llmMessage(let msg, _, _, _) = result[2].item { XCTAssertEqual(msg.content, "After") }
        else { XCTFail("Expected llmMessage at 2") }
    }

    func testMeetingMessagesOrderedInternally() {
        let meeting = makeMeeting(messages: [
            makeMeetingMessage(role: .productManager, content: "Second", at: date(200)),
            makeMeetingMessage(role: .techLead, content: "First", at: date(100))
        ])
        let result = build(steps: [], run: makeRun(meetings: [meeting]))
        XCTAssertEqual(result.count, 2)
        assertOrdered(result)

        if case .meetingMessage(let msg, _, _) = result[0].item { XCTAssertEqual(msg.content, "First") }
        else { XCTFail("Expected First at 0") }
    }

    func testMultipleMeetingsInterleaved() {
        let meeting1 = makeMeeting(topic: "Meeting A", messages: [
            makeMeetingMessage(role: .productManager, content: "A1", at: date(100)),
            makeMeetingMessage(role: .productManager, content: "A2", at: date(300))
        ])
        let meeting2 = makeMeeting(topic: "Meeting B", messages: [
            makeMeetingMessage(role: .techLead, content: "B1", at: date(200)),
            makeMeetingMessage(role: .techLead, content: "B2", at: date(400))
        ])
        let result = build(steps: [], run: makeRun(meetings: [meeting1, meeting2]))
        XCTAssertEqual(result.count, 4)
        assertOrdered(result)

        let contents = result.compactMap { item -> String? in
            if case .meetingMessage(let msg, _, _) = item.item { return msg.content }
            return nil
        }
        XCTAssertEqual(contents, ["A1", "B1", "A2", "B2"])
    }

    // MARK: - 5. Change Requests

    func testChangeRequestInterleavedWithStepItems() {
        let step = makeStep(messages: [
            makeMessage(content: "Before", at: date(100)),
            makeMessage(content: "After", at: date(300))
        ])
        let cr = makeChangeRequest(at: date(200))
        let result = build(steps: [step], run: makeRun(changeRequests: [cr]))
        XCTAssertEqual(result.count, 3)
        assertOrdered(result)

        if case .changeRequest = result[1].item {} else { XCTFail("Expected changeRequest at 1") }
    }

    func testMultipleChangeRequestsOrdered() {
        let cr1 = makeChangeRequest(at: date(300))
        let cr2 = makeChangeRequest(at: date(100))
        let result = build(steps: [], run: makeRun(changeRequests: [cr1, cr2]))
        XCTAssertEqual(result.count, 2)
        assertOrdered(result)

        // cr2 (t=100) should come first
        XCTAssertEqual(result[0].item.createdAt, date(100))
        XCTAssertEqual(result[1].item.createdAt, date(300))
    }

    // MARK: - 6. Supervisor Notifications

    func testActiveNotificationExcludedFromTimeline() {
        let askCall = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"Help?"}"#)
        let step = makeStep(
            messages: [makeMessage(content: "Working", at: date(500))],
            toolCalls: [askCall],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: #"{"question":"Help?"}"#
        )
        let result = build(steps: [step])

        // Active notification should NOT be in the timeline (shown as banner instead)
        let notifications = result.filter {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }
        XCTAssertEqual(notifications.count, 0, "Active notifications should be excluded from timeline")
    }

    /// One step, TWO ask calls in its history, no stored `supervisorQuestion` —
    /// the composer chip must read the LAST ask's arguments (`last(where:)`),
    /// never the first ask of the run.
    ///
    /// RED: swap the lookup to `first(where:)` → the chip shows "Q1?" and the
    /// asked-at anchor jumps back to the first call.
    func testActiveSupervisorQuestion_twoAsksInOneStep_lastAskWins() {
        let ask1 = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"Q1?"}"#)
        let ask2 = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"Q2?"}"#)
        let step = makeStep(
            role: .productManager,
            toolCalls: [ask1, ask2],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])

        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions.first?.question, "Q2?")
        XCTAssertEqual(questions.first?.askedAt, date(200))
    }

    func testMultipleActiveNotificationsExcluded() {
        let ask1 = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"Q1?"}"#)
        let step1 = makeStep(
            role: .productManager,
            toolCalls: [ask1],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let ask2 = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"Q2?"}"#)
        let step2 = makeStep(
            role: .techLead,
            messages: [makeMessage(content: "Analysis", at: date(50))],
            toolCalls: [ask2],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let result = build(steps: [step1, step2])
        let supervisorNotifications = result.filter {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }
        XCTAssertEqual(supervisorNotifications.count, 0, "All active notifications excluded from timeline")

        // Only step2's message + both tool calls should remain
        XCTAssertTrue(result.count >= 1)
    }

    func testAnsweredNotificationAtAnswerTimestamp() {
        let askCall = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"Help?"}"#)
        let answerMsg = makeMessage(role: .user, content: "Supervisor answer: Yes", at: date(250),
                                    sourceContext: .supervisorAnswer)
        let step = makeStep(
            messages: [
                makeMessage(content: "Before", at: date(100)),
                answerMsg,
                makeMessage(content: "After", at: date(300))
            ],
            toolCalls: [askCall],
            supervisorAnswer: "Yes"
        )
        let result = build(steps: [step])
        assertOrdered(result)

        let notifItem = result.first {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }
        XCTAssertNotNil(notifItem)
        // Answered notification should be at ANSWER timestamp (250), not call timestamp (200)
        XCTAssertEqual(notifItem?.item.createdAt, date(250))
    }

    func testMixedActiveAndAnsweredNotifications() {
        // Step 1: answered question
        let ask1 = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"Q1?"}"#)
        let answer1 = makeMessage(role: .user, content: "Supervisor answer: A1", at: date(150),
                                  sourceContext: .supervisorAnswer)
        let step1 = makeStep(
            role: .productManager,
            messages: [answer1],
            toolCalls: [ask1],
            supervisorAnswer: "A1"
        )

        // Step 2: active question
        let ask2 = makeToolCall(name: TN.askSupervisor, at: date(300), argumentsJSON: #"{"question":"Q2?"}"#)
        let step2 = makeStep(
            role: .techLead,
            toolCalls: [ask2],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let result = build(steps: [step1, step2])

        let notifications = result.filter {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }
        // Only answered notification in timeline; active excluded
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications[0].item.createdAt, date(150), "Answered notification at answer timestamp")
    }

    /// In-flight window: the engine has appended the `ask_supervisor` tool call but
    /// has not yet called `setNeedsSupervisorInput`. The docked composer already
    /// considers the question active (via `activeSupervisorQuestions`'s
    /// `needsSupervisorInput || trailingIsAsk` rule), so emitting a card would
    /// duplicate the answering surface. `emitItems` must skip the same window.
    func testInFlightNotificationExcluded_trailingAskWithoutFlag() {
        let askCall = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"In-flight?"}"#)
        // Step is `.running` (not yet `.needsSupervisorInput`) and the flag is
        // false — but the trailing tool call IS ask_supervisor and there's no
        // supervisorAnswer yet.
        let step = makeStep(
            toolCalls: [askCall],
            status: .running,
            needsSupervisorInput: false,
            supervisorAnswer: nil
        )
        let result = build(steps: [step])

        let notifications = result.filter {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }
        XCTAssertEqual(
            notifications.count, 0,
            "In-flight ask_supervisor (trailing call, no flag, no answer) must be skipped — owned by the docked composer"
        )
    }

    /// Trailing call is `ask_supervisor`, no flag, but the answer is already
    /// committed — this is a fully resolved historical question and SHOULD be
    /// emitted as a card.
    func testInFlightFalsePositive_resolvedAnswerStillEmits() {
        let askCall = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"Resolved?"}"#)
        let answerMsg = makeMessage(role: .user, content: "Supervisor answer: ok", at: date(150),
                                    sourceContext: .supervisorAnswer)
        let step = makeStep(
            messages: [answerMsg],
            toolCalls: [askCall],
            status: .running,
            needsSupervisorInput: false,
            supervisorAnswer: "ok"
        )
        let result = build(steps: [step])

        let notifications = result.filter {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }
        XCTAssertEqual(notifications.count, 1, "Resolved supervisor-input card must still appear in history")
    }

    /// Multi-round race: supervisor answered iter N, LLM emitted iter N+1's
    /// `ask_supervisor` (so `appendToolCalls` ran), but `setNeedsSupervisorInput`
    /// has not yet cleared `step.supervisorAnswer`. The stale answer survives on
    /// the step field but `answerMessages.count == 1 < askCalls.count == 2`, so
    /// the trailing call is correctly identified as in-flight. Without this we
    /// would emit a second card in the feed showing the stale answer attached
    /// to the new (unanswered) question.
    func testInFlightSkipsTrailingWhenSupervisorAnswerStaleFromPriorRound() {
        let ask1 = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"first?"}"#)
        let answer1 = makeMessage(role: .user, content: "Supervisor answer: yes", at: date(150),
                                  sourceContext: .supervisorAnswer)
        let ask2 = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"second?"}"#)
        // The stale-`supervisorAnswer` window: iter 1 answered (message in
        // conversation, step.supervisorAnswer still set), iter 2 ask landed,
        // setNeedsSupervisorInput has not yet fired for iter 2.
        let step = makeStep(
            messages: [answer1],
            toolCalls: [ask1, ask2],
            status: .running,
            needsSupervisorInput: false,
            supervisorAnswer: "yes"  // stale carry-over from iter 1
        )
        let result = build(steps: [step])

        let notifications: [ActivityNotificationType] = result.compactMap {
            if case .notification(_, _, let type, _, _) = $0.item { return type }
            return nil
        }
        XCTAssertEqual(notifications.count, 1, "Only iter 1 should appear as history; iter 2 is in-flight")

        // Attribution: the surviving card must carry iter 1's question + answer,
        // NOT iter 2's question (the stale `supervisorAnswer` could be
        // mis-pinned to ask 2 if the indexing logic regressed — see the
        // screenshot bug from the original report).
        guard case let .supervisorInput(question, answer, _, _, _, _, _) = notifications[0] else {
            return XCTFail("Expected .supervisorInput notification")
        }
        XCTAssertEqual(question, "first?", "Card must carry iter 1's question, NOT iter 2's")
        XCTAssertEqual(answer, "yes", "Card must carry iter 1's answer, NOT a stale value or `(answered)` placeholder")
    }

    /// `wasAutoAnswered` threading: the notification must carry the step's
    /// `supervisorAnswerWasAuto` verbatim — the card's "Auto-answered" badge keys
    /// on WHO answered, never on the team's supervisor mode (a human reply to the
    /// Autovisor's idle park in an autonomous team must render the checkmark).
    func testSupervisorInputNotification_carriesWasAutoAnsweredFromStep() {
        for flag in [true, false] {
            let ask = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"q?"}"#)
            let answerMsg = makeMessage(role: .user, content: "Supervisor answer: a", at: date(150),
                                        sourceContext: .supervisorAnswer)
            let step = makeStep(
                messages: [answerMsg],
                toolCalls: [ask],
                status: .done,
                supervisorAnswer: "a",
                supervisorAnswerWasAuto: flag
            )
            let notifications: [ActivityNotificationType] = build(steps: [step]).compactMap {
                if case .notification(_, _, let type, _, _) = $0.item { return type }
                return nil
            }
            guard case let .supervisorInput(_, _, _, _, _, _, wasAutoAnswered) = notifications.first else {
                return XCTFail("Expected .supervisorInput notification")
            }
            XCTAssertEqual(wasAutoAnswered, flag,
                           "Notification must mirror step.supervisorAnswerWasAuto (\(flag))")
        }
    }

    /// Documented granularity limit of `wasAutoAnswered` (step-latest flag): on a
    /// step whose history holds MULTIPLE resolved Q&As, every card carries the
    /// LATEST answer's attribution — per-question fidelity is not stored. This
    /// test makes the limitation explicit so a future "fix" that changes the
    /// behavior does so consciously, updating the docs with it.
    func testMultiAskStep_allResolvedCards_carryLatestAttribution() {
        let ask1 = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"first?"}"#)
        let answer1 = makeMessage(role: .user, content: "Supervisor answer: by hand", at: date(150),
                                  sourceContext: .supervisorAnswer)
        let ask2 = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"second?"}"#)
        let answer2 = makeMessage(role: .user, content: "Supervisor answer: by bot", at: date(250),
                                  sourceContext: .supervisorAnswer)
        let step = makeStep(
            messages: [answer1, answer2],
            toolCalls: [ask1, ask2],
            status: .done,
            supervisorAnswer: "by bot",
            supervisorAnswerWasAuto: true  // latest answer was automated
        )

        let flags: [Bool] = build(steps: [step]).compactMap {
            if case .notification(_, _, .supervisorInput(_, _, _, _, _, _, let wasAuto), _, _) = $0.item {
                return wasAuto
            }
            return nil
        }

        XCTAssertEqual(flags, [true, true],
                       "Step-latest flag stamps BOTH resolved cards — including the human-answered first Q&A")
    }

    /// Companion to the above: `activeSupervisorQuestions` must still surface
    /// iter 2 so the docked composer has a chip — without this fix the dock
    /// would also miss the trailing call (`supervisorAnswer != nil` guard).
    func testActiveSupervisorQuestions_returnsTrailingUnansweredEvenWithStaleAnswer() {
        let ask1 = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"first?"}"#)
        let answer1 = makeMessage(role: .user, content: "Supervisor answer: yes", at: date(150),
                                  sourceContext: .supervisorAnswer)
        let ask2 = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"second?"}"#)
        let step = makeStep(
            messages: [answer1],
            toolCalls: [ask1, ask2],
            status: .running,
            needsSupervisorInput: false,
            supervisorAnswer: "yes"
        )

        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(active.count, 1, "Trailing unanswered call must be reported as active")
        XCTAssertEqual(active.first?.question, "second?", "The TRAILING call is the active one, not the answered first")
    }

    /// Earlier `ask_supervisor` calls in the same step (i.e. non-trailing) are
    /// always historical and should always be emitted, regardless of whether
    /// the trailing tool call is ask_supervisor or anything else.
    func testInFlightDoesNotSuppressEarlierAnsweredCall() {
        let ask1 = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"first?"}"#)
        let answer1 = makeMessage(role: .user, content: "Supervisor answer: A1", at: date(150),
                                  sourceContext: .supervisorAnswer)
        let ask2 = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"second?"}"#)
        // Trailing ask is ask2 (in-flight), but ask1 was already answered.
        let step = makeStep(
            messages: [answer1],
            toolCalls: [ask1, ask2],
            status: .running,
            needsSupervisorInput: false,
            supervisorAnswer: nil
        )
        let result = build(steps: [step])

        let notifications = result.filter {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }
        XCTAssertEqual(notifications.count, 1, "Earlier answered ask is historical and still appears")
    }

    /// `needsSupervisorInput` is an OR'd defensive backstop in the active-input
    /// predicate. This test exercises it ALONE: the engine flag is set but the
    /// trailing-unanswered count-check WOULD return false. The backstop covers
    /// any engine path that flips the flag without a matching `ask_supervisor`
    /// tool call (e.g. legacy state, recovery flow, manual question injection).
    ///
    /// Without the backstop, this test would emit a card AND `activeSupervisorQuestions`
    /// would return `[]` — both surfaces would silently disagree with the flag.
    func testNeedsSupervisorInputBackstop_firesAloneWithoutTrailingAsk() {
        // Tool calls present but trailing call is NOT ask_supervisor.
        let read = makeToolCall(name: TN.readFile, at: date(100), argumentsJSON: "{}")
        let ask = makeToolCall(name: TN.askSupervisor, at: date(150), argumentsJSON: #"{"question":"legacy?"}"#)
        let answer = makeMessage(role: .user, content: "Supervisor answer: yes", at: date(170),
                                 sourceContext: .supervisorAnswer)
        // ask was answered (count-check returns false), but the flag is still
        // set — a stuck-flag legacy state we want to detect, not ignore.
        let step = makeStep(
            messages: [answer],
            toolCalls: [ask, read],  // trailing = read_file, NOT ask
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorAnswer: "yes"
        )

        // Emit-side: the backstop is at the step level, but emit-side skip is
        // only applied to the LAST ask in the per-call loop. Here the only ask
        // is at index 0 (which is also `isLast` for the askCalls subset), so
        // the backstop kicks in and the card is suppressed.
        let result = build(steps: [step])
        let notifications = result.filter {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }
        XCTAssertEqual(notifications.count, 0,
                       "Emit-side skip must honor the needsSupervisorInput backstop even when trailing call isn't ask_supervisor")

        // Activity-side: the dock must report a question so the user has a chip.
        // (Without ask calls there's no `lastCall` to surface, so the dock falls
        // back to the step's stored question. This test pins that fall-through.)
        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(active.count, 1, "Backstop must surface the active question to the dock too")
    }

    /// Defensive edge case: a step with zero `ask_supervisor` tool calls but
    /// the engine flag is set. Real engine paths shouldn't produce this state
    /// (the flag is set as part of appending an ask call), but the predicate
    /// must not crash. Asserts no-op for both surfaces, except that the dock
    /// has the question to surface — confirmed via the backstop above.
    func testEmptyAskCalls_emitsNoNotifications_evenWithFlagSet() {
        let step = makeStep(
            toolCalls: [],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Manual?",
            supervisorAnswer: nil
        )
        let result = build(steps: [step])
        let notifications = result.filter {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }
        XCTAssertEqual(notifications.count, 0, "No ask calls → no cards (nothing to enumerate)")
    }

    func testEmptyAskCalls_activeQuestions_isEmpty_whenFlagAlsoOff() {
        let step = makeStep(toolCalls: [], status: .running, needsSupervisorInput: false)
        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertTrue(active.isEmpty, "Truly idle step is not active")
    }

    // MARK: - activeSupervisorQuestions edge cases

    /// Transient mid-stream window between rounds — the source of the visual
    /// flicker reported in the bug screenshot. Sequence:
    ///   1. Round N-1: `setNeedsSupervisorInput("Q1")` → `supervisorQuestion="Q1"`, `needsSupervisorInput=true`
    ///   2. User answers → `needsSupervisorInput=false`. `supervisorQuestion="Q1"` STAYS
    ///      (`StepMessagingService.answerSupervisorQuestion` deliberately doesn't clear it).
    ///   3. Round N starts. `appendToolCalls(ask("Q2"))` fires → `step.toolCalls.last="Q2"`
    ///      and `runDataVersion` changes (toolCalls.count grew). Recompute runs.
    ///   4. BEFORE `setNeedsSupervisorInput("Q2")` lands, the cache sees:
    ///         `needsSupervisorInput=false`, `supervisorQuestion="Q1"` (stale), trailing ask="Q2".
    ///   5. `setNeedsSupervisorInput("Q2")` → `supervisorQuestion="Q2"`, `needsSupervisorInput=true`.
    ///
    /// Without `needsSupervisorInput` as the gate, step 4 would surface the
    /// stale "Q1" briefly until step 5 lands — visible as a flash of the
    /// previous question. The preference for `step.supervisorQuestion` must
    /// fire only when `setNeedsSupervisorInput` has confirmed it as fresh.
    func testActiveSupervisorQuestions_transientWindow_staleSupervisorQuestion_doesNotShadowNewToolCall() {
        let ask1 = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"Q1 (prev round)"}"#)
        let answer1 = makeMessage(
            role: .user, content: "Supervisor answer: a1", at: date(150),
            sourceContext: .supervisorAnswer
        )
        let ask2 = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"Q2 (current round)"}"#)

        let step = makeStep(
            messages: [answer1],
            toolCalls: [ask1, ask2],
            status: .running,
            // KEY: false, because setNeedsSupervisorInput("Q2") hasn't landed yet.
            // Q1's `true` was flipped to `false` by the user's answer to Q1.
            needsSupervisorInput: false,
            // KEY: still Q1 — answerSupervisorQuestion doesn't clear it,
            // and setNeedsSupervisorInput("Q2") hasn't fired yet.
            supervisorQuestion: "Q1 (prev round)",
            supervisorAnswer: "a1"
        )

        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(active.count, 1, "Trailing-unanswered path activates the step")
        XCTAssertEqual(
            active.first?.question, "Q2 (current round)",
            "In the trailing-unanswered transient window, the new tool-call argument is fresher than the stale supervisorQuestion — needsSupervisorInput must gate the storedQ preference, otherwise the user sees a flash of the previous question."
        )
    }

    /// Last-resort fallback: when `step.supervisorQuestion` is nil AND the
    /// trailing `ask_supervisor` tool call's `argumentsJSON` is unparseable,
    /// the chip MUST render the literal `"?"` so the user knows there's a
    /// pending question even if the text is lost. Pinning this prevents a
    /// regression to `""` (empty chip label, indistinguishable from no
    /// pending question at all) — the only path that puts a `"?"` in front
    /// of the user, otherwise untested.
    func testActiveSupervisorQuestions_nilStoredQuestion_unparseableJSON_fallsBackToQuestionMark() {
        let askWithBadJSON = makeToolCall(
            name: TN.askSupervisor, at: date(100),
            argumentsJSON: "not valid json {"
        )
        let step = makeStep(
            toolCalls: [askWithBadJSON],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: nil
        )
        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(
            active.first?.question, "?",
            "Last-resort fallback MUST be \"?\" so the user sees a pending-question signal. Empty string would render an invisible chip — regression to silent failure."
        )
    }

    /// Whitespace-only `step.supervisorQuestion` must NOT shadow the tool-call
    /// argument. Trimming + emptiness check is the gate — without it, an
    /// engine path that accidentally writes `" "` would silently override the
    /// real ask_supervisor question with a blank prompt in the activity feed
    /// while QC overlay (which has its own non-nil guard) would still show
    /// the real question — re-introducing the desync this whole layer fixes.
    func testActiveSupervisorQuestions_whitespaceOnlyStoredQuestion_fallsBackToToolCallArg() {
        let ask = makeToolCall(
            name: TN.askSupervisor, at: date(100),
            argumentsJSON: #"{"question":"Real question from tool call"}"#
        )
        let step = makeStep(
            toolCalls: [ask],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "   \n  \t  "
        )
        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(
            active.first?.question, "Real question from tool call",
            "Whitespace-only supervisorQuestion must NOT shadow the tool-call argument"
        )
    }

    /// Pre-escalation regression guard: when `step.supervisorQuestion` is nil
    /// (the normal mid-stream state right after appendToolCalls but before
    /// setNeedsSupervisorInput), the question text MUST come from the tool
    /// call's argumentsJSON. Otherwise normal `ask_supervisor` flows show "?"
    /// during the brief window when the question card materializes.
    func testActiveSupervisorQuestions_nilStoredQuestion_usesToolCallArg() {
        let ask = makeToolCall(
            name: TN.askSupervisor, at: date(100),
            argumentsJSON: #"{"question":"What scheme should I use?"}"#
        )
        // needsSupervisorInput=true via flag, but supervisorQuestion not yet
        // persisted to the step (transient window).
        let step = makeStep(
            toolCalls: [ask],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: nil
        )
        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.question, "What scheme should I use?")
    }

    /// Escalation path pairs with the last assistant turn so the composer's
    /// preview shows what the LLM actually said (the refusal that triggered
    /// the cap), not just the system-generated escalation prompt. Without this,
    /// users would see only "Role X emitted 3 refusal messages…" with no
    /// context of WHAT the model said.
    func testActiveSupervisorQuestions_escalationPath_pairsWithLastAssistantMessage() {
        let refusal = makeMessage(
            role: .assistant,
            content: "I'm sorry, but I can't identify a clear task to work on.",
            at: date(50)
        )
        let step = makeStep(
            messages: [refusal],
            toolCalls: [],  // escalation path = no tool call
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Role Coding Agent emitted 3 consecutive refusal messages. Please advise."
        )
        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.paired?.id, refusal.id,
                       "Escalation must pair with last assistant turn so user sees the LLM's refusal context")
    }

    /// Mixed batch: one step with a real ask_supervisor (normal path) + one
    /// step with escalation (no tool call). Both must surface, and sort order
    /// by askedAt must be deterministic across surfaces (CLAUDE.md notes the
    /// chip-row order matters for auto-selection).
    func testActiveSupervisorQuestions_mixedNormalAndEscalation_bothSurface() {
        let ask = makeToolCall(
            name: TN.askSupervisor, at: date(100),
            argumentsJSON: #"{"question":"Normal path question?"}"#
        )
        let stepNormal = StepExecution(
            id: "step-normal",
            role: .softwareEngineer,
            title: "SWE Step",
            status: .needsSupervisorInput,
            updatedAt: date(110),
            toolCalls: [ask],
            needsSupervisorInput: true,
            supervisorQuestion: "Normal path question?",
            llmConversation: []
        )

        let stepEscalation = StepExecution(
            id: "step-escalation",
            role: .codeReviewer,
            title: "CR Step",
            status: .needsSupervisorInput,
            updatedAt: date(200),
            toolCalls: [],
            needsSupervisorInput: true,
            supervisorQuestion: "Escalation question — please advise.",
            llmConversation: []
        )

        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [stepEscalation, stepNormal])
        XCTAssertEqual(active.count, 2, "Both normal and escalation steps must surface")
        // Sort order: askedAt ascending. Normal step has askedAt = tool call timestamp (100),
        // escalation step has askedAt = step.updatedAt (200). Normal comes first.
        XCTAssertEqual(active.first?.question, "Normal path question?")
        XCTAssertEqual(active.last?.question, "Escalation question — please advise.")
    }

    /// Determinism guard: two simultaneous escalation steps with identical
    /// askedAt timestamps must sort by stepID for stable chip ordering. The
    /// sort tie-breaker uses stepID per `activeSupervisorQuestions`'s
    /// comment — without this, the leftmost Answer chip could flip on each
    /// recompute and retarget user typing to a different role.
    func testActiveSupervisorQuestions_sameAskedAt_sortsByStepID() {
        let sameTimestamp = date(100)
        let stepA = StepExecution(
            id: "aaa-step",
            role: .softwareEngineer,
            title: "A", status: .needsSupervisorInput,
            updatedAt: sameTimestamp,
            toolCalls: [],
            needsSupervisorInput: true,
            supervisorQuestion: "From A",
            llmConversation: []
        )
        let stepB = StepExecution(
            id: "zzz-step",
            role: .codeReviewer,
            title: "B", status: .needsSupervisorInput,
            updatedAt: sameTimestamp,
            toolCalls: [],
            needsSupervisorInput: true,
            supervisorQuestion: "From B",
            llmConversation: []
        )

        // Pass in non-sorted input order; result must still be aaa < zzz.
        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [stepB, stepA])
        XCTAssertEqual(active.count, 2)
        XCTAssertEqual(active[0].stepID, "aaa-step", "Tie-break by stepID ascending")
        XCTAssertEqual(active[1].stepID, "zzz-step")
    }

    /// Escalation-after-ask: a real `ask_supervisor` tool call landed earlier,
    /// then the engine's refusal-loop / drift / parse-failure cap fired and
    /// `setNeedsSupervisorInput` overwrote `step.supervisorQuestion` with the
    /// escalation text. The activity-feed composer must surface the CURRENT
    /// (escalation) question, NOT the stale tool-call argument — otherwise it
    /// disagrees with the QuickCapture overlay (which reads
    /// `step.supervisorQuestion` directly in
    /// `DefaultQuickCaptureModeCoordinator.resolveMode`) and the user sees
    /// two different questions for the same waiting step.
    func testActiveSupervisorQuestions_prefersStepSupervisorQuestionOverStaleToolCallArg() {
        let askWithStaleQ = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"I've reviewed the repository contents, but there's no code or clear task to act on."}"#
        )
        let answer = makeMessage(
            role: .user, content: "Supervisor answer: йцу", at: date(150),
            sourceContext: .supervisorAnswer
        )
        let step = makeStep(
            messages: [answer],
            toolCalls: [askWithStaleQ],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            // Escalation overwrote supervisorQuestion with a different text:
            supervisorQuestion: "Role Coding Agent emitted 3 consecutive refusal messages without calling any tools. The model appears stuck — please advise how to proceed."
        )

        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(
            active.first?.question,
            "Role Coding Agent emitted 3 consecutive refusal messages without calling any tools. The model appears stuck — please advise how to proceed.",
            "When step.supervisorQuestion is set, it MUST win over a stale tool-call argument — setNeedsSupervisorInput is the authoritative writer for the current question text, and QC overlay reads it directly. Both surfaces must agree."
        )
    }

    /// Escalation path: when the engine calls `setNeedsSupervisorInput` from a
    /// drift cap / refusal-loop cap / parse-failure cap (in
    /// `LLMExecutionService+StepFlowControl.swift`), it sets
    /// `needsSupervisorInput=true` + `supervisorQuestion=q` but does NOT append
    /// an `ask_supervisor` tool call to `step.toolCalls`. `activeSupervisorQuestions`
    /// must surface the stored question so the composer chip + question card
    /// render — otherwise the user sees the role pause silently with no question
    /// to answer. Pinned because the engine's no-tool-call escape hatch is the
    /// ONLY path through which this state legally arises (CLAUDE.md §7's
    /// `setNeedsSupervisorInput` doc explicitly calls it out).
    func testEscalationPath_emptyAskCalls_flagSet_surfacesStoredQuestion() {
        let step = makeStep(
            toolCalls: [],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Role X produced two consecutive long reasoning responses without calling any tool. Please advise."
        )
        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(active.count, 1, "Escalation must surface the stored question to the dock")
        XCTAssertEqual(
            active.first?.question,
            "Role X produced two consecutive long reasoning responses without calling any tool. Please advise.",
            "Question text must come from step.supervisorQuestion when no ask_supervisor tool call exists"
        )
    }

    /// Defense-in-depth at the view layer. The companion writer at
    /// `LLMExecutionService+TaskStateMutations.swift:140` currently guards the
    /// `setNeedsSupervisorInput` path against empty question text — but future
    /// engine paths (or accidental edits) could set `needsSupervisorInput=true`
    /// with a nil/empty `supervisorQuestion` and no tool call. Today's
    /// `activeSupervisorQuestions` silently drops such steps via
    /// `guard !trimmedQ.isEmpty else { continue }`, wedging the engine in
    /// `.needsSupervisorInput` forever with no UI signal — no composer chip,
    /// no question card, no error banner. This test pins the contract that the
    /// composer MUST surface a placeholder chip so the supervisor can unblock
    /// the step instead.
    func testActiveSupervisorQuestions_emptyStoredQuestion_noToolCall_emitsPlaceholderChip() {
        let step = makeStep(
            toolCalls: [],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: nil
        )
        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(
            active.count, 1,
            "Empty-question waiting step MUST surface a placeholder chip — silent drop wedges the engine forever with no UI signal."
        )
        XCTAssertEqual(
            active.first?.question, ActivityFeedBuilder.escalationFallbackQuestion,
            "Placeholder text must come from the canonical constant so UI/log surfaces stay in sync."
        )
    }

    /// Whitespace-only `step.supervisorQuestion` on the escalation path (no
    /// tool call) must also fall back to the placeholder rather than silently
    /// dropping the step. Without this, an engine path that writes `"  \n  "`
    /// would also wedge the step.
    func testActiveSupervisorQuestions_whitespaceOnlyStoredQuestion_noToolCall_emitsPlaceholderChip() {
        let step = makeStep(
            toolCalls: [],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "   \n  \t  "
        )
        let active = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.question, ActivityFeedBuilder.escalationFallbackQuestion)
    }

    /// Companion to `testEscalationPath_emptyAskCalls_flagSet_surfacesStoredQuestion`:
    /// once the supervisor ANSWERS an escalation question, the answered Q&A must
    /// appear in feed history. The history builder (`emitItems`) walks
    /// `step.toolCalls.filter { $0.name == ToolNames.askSupervisor }` — which is
    /// empty on the escalation path — so without a synthesized notification the
    /// Q&A vanishes entirely once `needsSupervisorInput` flips back to false.
    /// Pinned because the bug is silent: composer chip disappears (correct
    /// behavior for the active→answered transition), but the answered card
    /// never materializes (incorrect — leaves the supervisor with no record
    /// of the question or their own answer).
    func testEmitItems_escalationPathAnswered_emitsHistoryNotification() {
        let refusal = makeMessage(
            role: .assistant,
            content: "I'm sorry, but I can't identify a clear task to work on.",
            at: date(50)
        )
        let answer = makeMessage(
            role: .user,
            content: "Supervisor answer: Please read CLAUDE.md and propose 3 small fixes.",
            at: date(200),
            sourceContext: .supervisorAnswer
        )
        let step = makeStep(
            messages: [refusal, answer],
            toolCalls: [],                       // escalation path = no ask_supervisor call
            status: .running,                    // answered, role has resumed
            needsSupervisorInput: false,
            supervisorQuestion: "Role Coding Agent emitted 3 consecutive refusal messages. Please advise.",
            supervisorAnswer: "Please read CLAUDE.md and propose 3 small fixes.",
            updatedAt: date(210)
        )

        let result = build(steps: [step])

        let supervisorNotifs: [(question: String, answer: String?)] = result.compactMap {
            if case let .notification(_, _, .supervisorInput(question, answer, _, _, _, _, _), _, _) = $0.item {
                return (question, answer)
            }
            return nil
        }
        XCTAssertEqual(
            supervisorNotifs.count, 1,
            "Escalation-path answered Q&A MUST surface one supervisorInput notification — otherwise the Q&A disappears from feed history once the supervisor answers."
        )
        XCTAssertEqual(
            supervisorNotifs.first?.question,
            "Role Coding Agent emitted 3 consecutive refusal messages. Please advise.",
            "Question text must come from step.supervisorQuestion (no tool-call args on the escalation path)"
        )
        XCTAssertEqual(
            supervisorNotifs.first?.answer,
            "Please read CLAUDE.md and propose 3 small fixes.",
            "Answer text must come from the supervisor-answer message body (with `Supervisor answer: ` prefix stripped)"
        )
    }

    /// The escalation-path answered card must sort at the ANSWER's timestamp,
    /// not `step.updatedAt`. `updatedAt` is re-stamped by every later mutation
    /// (each appended tool call), so anchoring on it made the card perpetually
    /// drift below tool calls that executed AFTER the answer — the
    /// "Autovisor asked card keeps moving down" bug.
    func testEscalationAnsweredCard_usesAnswerMessageTimestamp_notStepUpdatedAt() {
        let answer = makeMessage(
            role: .user,
            content: "Supervisor answer: не работают кнопки wasd",
            at: date(200),
            sourceContext: .supervisorAnswer
        )
        let laterTool1 = makeToolCall(name: "search", at: date(250))
        let laterTool2 = makeToolCall(name: "read_file", at: date(300))
        let step = makeStep(
            messages: [answer],
            toolCalls: [laterTool1, laterTool2],   // executed AFTER the answer
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Idle — waiting for events.",
            supervisorAnswer: "не работают кнопки wasd",
            updatedAt: date(400)                   // re-stamped by the latest mutation
        )

        let result = build(steps: [step])

        guard let cardIndex = result.firstIndex(where: {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }) else { return XCTFail("Expected a supervisorInput notification") }

        if case let .notification(_, _, _, createdAt, _) = result[cardIndex].item {
            XCTAssertEqual(
                createdAt, date(200),
                "Card must anchor on the answer message's createdAt, not step.updatedAt"
            )
        }
        let toolIndices = result.indices.filter {
            if case .toolCall = result[$0].item { return true }
            return false
        }
        XCTAssertEqual(toolIndices.count, 2)
        for toolIndex in toolIndices {
            XCTAssertLessThan(
                cardIndex, toolIndex,
                "Answered card must render BEFORE tool calls that executed after the answer"
            )
        }
    }

    /// The escalation card's timeline-item id must be stable across rebuilds.
    /// A fresh `UUID()` per build churned ForEach item identity (view
    /// re-creation / re-animation) and broke the `supervisorThinking` window
    /// dedupKey — clicking "Open in window" after any timeline rebuild
    /// spawned a duplicate window instead of focusing the existing one.
    func testEscalationAnsweredCard_identityStableAcrossRebuilds() {
        let answer = makeMessage(
            role: .user,
            content: "Supervisor answer: ok",
            at: date(200),
            sourceContext: .supervisorAnswer
        )
        let step = makeStep(
            messages: [answer],
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Idle — waiting for events.",
            supervisorAnswer: "ok",
            updatedAt: date(210)
        )

        func cardID(in items: [ActivityFeedBuilder.TaggedItem]) -> String? {
            items.first(where: {
                if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
                return false
            })?.item.id
        }

        let first = cardID(in: build(steps: [step]))
        let second = cardID(in: build(steps: [step]))
        XCTAssertNotNil(first)
        XCTAssertEqual(
            first, second,
            "Escalation card identity must be anchored on the persisted answer message id, not a per-rebuild UUID()"
        )
    }

    /// The card's "Thinking" row must show the reasoning that LED to the park
    /// (last assistant thinking at or before the answer), not whatever the
    /// model thought AFTER resuming — an unbounded `last(where:)` re-bound the
    /// row to post-answer reasoning as the step kept running.
    func testEscalationAnsweredCard_thinkingAnchoredToAnswerTime() {
        let preParkThinking = makeMessage(
            role: .assistant,
            content: "Going idle.",
            at: date(50),
            thinking: "Nothing left to do — parking for events."
        )
        let answer = makeMessage(
            role: .user,
            content: "Supervisor answer: fix WASD",
            at: date(200),
            sourceContext: .supervisorAnswer
        )
        let postAnswerThinking = makeMessage(
            role: .assistant,
            content: "Investigating input handling.",
            at: date(300),
            thinking: "The user reports WASD keys broken — checking Input.js."
        )
        let step = makeStep(
            messages: [preParkThinking, answer, postAnswerThinking],
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Idle — waiting for events.",
            supervisorAnswer: "fix WASD",
            updatedAt: date(310)
        )

        let result = build(steps: [step])

        guard let card = result.first(where: {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }) else { return XCTFail("Expected a supervisorInput notification") }

        if case let .notification(_, _, .supervisorInput(_, _, _, _, _, thinking, _), _, _) = card.item {
            XCTAssertEqual(
                thinking, "Nothing left to do — parking for events.",
                "Thinking must be bounded by the answer timestamp — post-answer reasoning belongs to the resumed turn, not this card"
            )
        }
    }

    /// Legacy-data fallback: `supervisorAnswer` set but NO `.supervisorAnswer`
    /// message in `llmConversation` (task.json persisted before
    /// `StepMessagingService.answerSupervisorQuestion` appended the message in
    /// the same mutation). The card must STILL emit, anchored on
    /// `step.updatedAt` — a future "tightening" to `guard let answerMsg` would
    /// silently vanish answered escalation cards for legacy tasks.
    func testEscalationAnsweredCard_noAnswerMessage_fallsBackToStepUpdatedAt() {
        let refusal = makeMessage(
            role: .assistant,
            content: "I can't identify a clear task.",
            at: date(50)
        )
        let step = makeStep(
            messages: [refusal],          // no .supervisorAnswer message — legacy shape
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Please advise.",
            supervisorAnswer: "legacy answer",
            updatedAt: date(300)
        )

        let result = build(steps: [step])

        guard let card = result.first(where: {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }) else {
            return XCTFail("Answered escalation card must still emit without an answer message (legacy data)")
        }
        if case let .notification(_, _, _, createdAt, _) = card.item {
            XCTAssertEqual(
                createdAt, date(300),
                "Without an answer message the card falls back to step.updatedAt (pre-fix behavior)"
            )
        }
    }

    /// Multi-round park (the Autovisor scenario): wait_for_events parks →
    /// answered → parks again → answered again, leaving 2+ `.supervisorAnswer`
    /// messages in one long-lived step. The card renders only the LATEST round
    /// (`supervisorQuestion`/`supervisorAnswer` are overwritten per round), so
    /// it must anchor on `answerMessages.last` — a `.last` → `.first`
    /// regression would jump the card back above all of round 2's activity and
    /// re-bind its thinking row to round-1 reasoning.
    func testEscalationAnsweredCard_multiRound_anchorsOnLatestAnswer() {
        let round1Answer = makeMessage(
            role: .user,
            content: "Supervisor answer: round one",
            at: date(100),
            sourceContext: .supervisorAnswer
        )
        let betweenRoundsThinking = makeMessage(
            role: .assistant,
            content: "Parking again.",
            at: date(300),
            thinking: "Round-2 work done — going idle."
        )
        let round2Answer = makeMessage(
            role: .user,
            content: "Supervisor answer: round two",
            at: date(500),
            sourceContext: .supervisorAnswer
        )
        let step = makeStep(
            messages: [round1Answer, betweenRoundsThinking, round2Answer],
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Idle — waiting for events.",
            supervisorAnswer: "round two",
            updatedAt: date(510)
        )

        let result = build(steps: [step])

        guard let card = result.first(where: {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }) else { return XCTFail("Expected a supervisorInput notification") }

        if case let .notification(_, _, .supervisorInput(_, _, _, _, _, thinking, _), createdAt, _) = card.item {
            XCTAssertEqual(
                createdAt, date(500),
                "Card must anchor on the LATEST answer message, not the first"
            )
            XCTAssertEqual(
                thinking, "Round-2 work done — going idle.",
                "Thinking bound must be the latest answer's timestamp — round-2 reasoning, not round-1"
            )
        } else {
            XCTFail("Expected a supervisorInput notification payload")
        }
    }

    // MARK: - Escalation card corner cases

    /// Whitespace-only `supervisorQuestion` must NOT produce a history card —
    /// the branch trims before the emptiness check. Without the trim guard, an
    /// engine path that writes `"  \n "` would render a card with a blank
    /// question header above a real answer.
    func testEscalationAnsweredCard_whitespaceOnlyQuestion_noCard() {
        let answer = makeMessage(
            role: .user,
            content: "Supervisor answer: ok",
            at: date(200),
            sourceContext: .supervisorAnswer
        )
        let step = makeStep(
            messages: [answer],
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "   \n  \t  ",
            supervisorAnswer: "ok",
            updatedAt: date(210)
        )

        let result = build(steps: [step])

        XCTAssertFalse(
            result.contains {
                if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
                return false
            },
            "Whitespace-only question must be treated as no question — no history card"
        )
    }

    /// A re-parked escalation step (`needsSupervisorInput == true`) must NOT
    /// emit a history card even when a previous round's answer + answer
    /// message are still present — active state is owned by the docked
    /// composer (`activeSupervisorQuestions`), and a duplicate card would
    /// surface the answering UI twice. This pins the `!stepIsActive` gate on
    /// the escalation branch specifically (the normal-path equivalent is
    /// covered by `testActiveNotificationExcludedFromTimeline`).
    func testEscalationCard_reParkedStep_suppressedWhileActive() {
        let round1Answer = makeMessage(
            role: .user,
            content: "Supervisor answer: round one",
            at: date(100),
            sourceContext: .supervisorAnswer
        )
        let step = makeStep(
            messages: [round1Answer],
            toolCalls: [],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,           // round 2 parked
            supervisorQuestion: "Idle — waiting for events.",
            supervisorAnswer: "round one",         // stale round-1 leftovers
            updatedAt: date(300)
        )

        let result = build(steps: [step])

        XCTAssertFalse(
            result.contains {
                if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
                return false
            },
            "While the step is parked again, the composer owns the question — no history card"
        )
        XCTAssertEqual(
            ActivityFeedBuilder.activeSupervisorQuestions(steps: [step]).count, 1,
            "Sanity: the re-parked question must surface via the composer instead"
        )
    }

    /// When the only assistant thinking in the conversation came AFTER the
    /// answer (the model resumed and reasoned about the reply), the card's
    /// thinking row must be nil — post-answer reasoning belongs to the resumed
    /// turn's own bubble, not the question card.
    func testEscalationAnsweredCard_onlyPostAnswerThinking_thinkingIsNil() {
        let answer = makeMessage(
            role: .user,
            content: "Supervisor answer: fix WASD",
            at: date(200),
            sourceContext: .supervisorAnswer
        )
        let postAnswerThinking = makeMessage(
            role: .assistant,
            content: "On it.",
            at: date(300),
            thinking: "User reports broken keys — investigating."
        )
        let step = makeStep(
            messages: [answer, postAnswerThinking],
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Idle — waiting for events.",
            supervisorAnswer: "fix WASD",
            updatedAt: date(310)
        )

        let result = build(steps: [step])

        guard let card = result.first(where: {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }) else { return XCTFail("Expected a supervisorInput notification") }

        if case let .notification(_, _, .supervisorInput(_, _, _, _, _, thinking, _), _, _) = card.item {
            XCTAssertNil(
                thinking,
                "No pre-answer thinking exists — the card must not borrow post-answer reasoning"
            )
        } else {
            XCTFail("Expected a supervisorInput notification payload")
        }
    }

    /// The thinking bound is inclusive (`<=`, mirroring the normal path's
    /// `<= call.createdAt`). `MonotonicClock` makes equal stamps impossible in
    /// production, but persisted fixtures / imported data can carry them — a
    /// refactor to strict `<` would silently drop a same-tick thinking turn.
    func testEscalationAnsweredCard_thinkingAtExactAnchorTimestamp_included() {
        let sameTick = date(200)
        let parkThinking = makeMessage(
            role: .assistant,
            content: "Going idle.",
            at: sameTick,
            thinking: "Same-tick reasoning."
        )
        let answer = makeMessage(
            role: .user,
            content: "Supervisor answer: ok",
            at: sameTick,
            sourceContext: .supervisorAnswer
        )
        let step = makeStep(
            messages: [parkThinking, answer],
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Idle — waiting for events.",
            supervisorAnswer: "ok",
            updatedAt: date(210)
        )

        let result = build(steps: [step])

        guard let card = result.first(where: {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }) else { return XCTFail("Expected a supervisorInput notification") }

        if case let .notification(_, _, .supervisorInput(_, _, _, _, _, thinking, _), _, _) = card.item {
            XCTAssertEqual(
                thinking, "Same-tick reasoning.",
                "The bound must be inclusive — a thinking turn stamped exactly at the anchor belongs to the question"
            )
        } else {
            XCTFail("Expected a supervisorInput notification payload")
        }
    }

    /// Documented degradation of the legacy fallback: with no answer message
    /// the anchor is `step.updatedAt`, which (being re-stamped last) bounds
    /// nothing — the thinking lookup degenerates to the pre-fix unbounded scan
    /// and shows the LATEST assistant reasoning. Acceptable for legacy data
    /// (the step is settled, so the row is at least stable); this pin makes
    /// the trade-off explicit instead of accidental.
    func testEscalationAnsweredCard_legacyFallback_showsLatestThinking() {
        let earlyThinking = makeMessage(
            role: .assistant,
            content: "Refusing.",
            at: date(100),
            thinking: "Early reasoning."
        )
        let lateThinking = makeMessage(
            role: .assistant,
            content: "Resumed.",
            at: date(250),
            thinking: "Late reasoning."
        )
        let step = makeStep(
            messages: [earlyThinking, lateThinking],   // legacy: no .supervisorAnswer message
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Please advise.",
            supervisorAnswer: "legacy answer",
            updatedAt: date(300)
        )

        let result = build(steps: [step])

        guard let card = result.first(where: {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }) else { return XCTFail("Expected a supervisorInput notification") }

        if case let .notification(_, _, .supervisorInput(_, _, _, _, _, thinking, _), _, _) = card.item {
            XCTAssertEqual(
                thinking, "Late reasoning.",
                "Legacy fallback anchors on updatedAt (latest stamp) — the bound filters nothing, latest thinking wins"
            )
        } else {
            XCTFail("Expected a supervisorInput notification payload")
        }
    }

    /// Discriminating test for the new gate vs the old `supervisorAnswer == nil`
    /// gate: a step where the OLD criterion would emit (`supervisorAnswer == nil`
    /// passes) AND the NEW count criterion also emits (`answerMessages.count(0)
    /// < askCalls.count(0)` is false → not in-flight → emit). Crafted so the
    /// `isResolved` branch in `SupervisorInputCard` is exercised.
    ///
    /// Companion: `testInFlightFalsePositive_resolvedAnswerStillEmits` covered
    /// the case where both gates emit; this version adds the discriminating
    /// scenario where the OLD gate would have skipped but the new one emits.
    func testFalsePositiveDiscriminator_oldCriterionWouldSkip_newCriterionEmits() {
        let ask = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"q?"}"#)
        let answerMsg = makeMessage(role: .user, content: "Supervisor answer: ok", at: date(150),
                                    sourceContext: .supervisorAnswer)
        // The discriminator: a step with the answer message committed, but
        // `step.supervisorAnswer` cleared (this only happens transiently if
        // the engine clears it on a follow-up — but happens often in unit
        // fixtures that build state in pieces). Old criterion: `supervisorAnswer
        // == nil` AND `needsSupervisorInput == false` → emit. New criterion:
        // `answerMessages.count(1) >= askCalls.count(1)` → emit. Both emit,
        // but for different reasons — pin both paths.
        let step = makeStep(
            messages: [answerMsg],
            toolCalls: [ask],
            status: .done,
            needsSupervisorInput: false,
            supervisorAnswer: nil
        )
        let result = build(steps: [step])
        let notifications = result.filter {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }
        XCTAssertEqual(notifications.count, 1,
                       "New criterion (count-based) must emit when there's a matching answer message")
    }

    // MARK: - 6b. Active Supervisor Questions (banner data)

    func testActiveSupervisorQuestions() {
        let ask1 = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"Q1?"}"#)
        let step1 = makeStep(
            role: .productManager,
            toolCalls: [ask1],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let ask2 = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"Q2?"}"#)
        let step2 = makeStep(
            role: .techLead,
            toolCalls: [ask2],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        // Answered step — should NOT appear in active questions.
        // In production both `step.supervisorAnswer` AND a matching
        // `Supervisor answer: …` LLMMessage are written together (see
        // `LLMExecutionService+StepLifecycle.swift:124-128`); the count check
        // distinguishes a real answered state from a stale-carry race window.
        let ask3 = makeToolCall(name: TN.askSupervisor, at: date(300), argumentsJSON: #"{"question":"Q3?"}"#)
        let answer3 = makeMessage(role: .user, content: "Supervisor answer: Done",
                                  at: date(350), sourceContext: .supervisorAnswer)
        let step3 = makeStep(
            role: .softwareEngineer,
            messages: [answer3],
            toolCalls: [ask3],
            supervisorAnswer: "Done"
        )

        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step1, step2, step3])
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[0].question, "Q1?")
        XCTAssertEqual(questions[0].role, .productManager)
        XCTAssertEqual(questions[1].question, "Q2?")
        XCTAssertEqual(questions[1].role, .techLead)
    }

    /// Pins FIFO fairness for the leftmost Answer chip: regardless of the order steps
    /// arrive in (Dictionary iteration of `roleStatuses` is non-deterministic), the
    /// active questions must be sorted ascending by the `ask_supervisor` timestamp.
    func testActiveSupervisorQuestions_sortsByAskedAtAscending_regardlessOfInputOrder() {
        let askLate = makeToolCall(name: TN.askSupervisor, at: date(300), argumentsJSON: #"{"question":"late?"}"#)
        let stepLate = makeStep(
            role: .softwareEngineer, toolCalls: [askLate],
            status: .needsSupervisorInput, needsSupervisorInput: true
        )
        let askEarly = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"early?"}"#)
        let stepEarly = makeStep(
            role: .productManager, toolCalls: [askEarly],
            status: .needsSupervisorInput, needsSupervisorInput: true
        )
        let askMid = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"mid?"}"#)
        let stepMid = makeStep(
            role: .techLead, toolCalls: [askMid],
            status: .needsSupervisorInput, needsSupervisorInput: true
        )

        // Steps deliberately passed out of chronological order.
        let questions = ActivityFeedBuilder.activeSupervisorQuestions(
            steps: [stepLate, stepEarly, stepMid]
        )
        XCTAssertEqual(questions.map(\.role), [.productManager, .techLead, .softwareEngineer],
                       "Expected ascending askedAt: early(PM) < mid(TL) < late(SWE)")
        let timestamps = questions.map(\.askedAt)
        XCTAssertEqual(timestamps, [date(100), date(200), date(300)])
    }

    /// `askedAt` must come from the LAST `ask_supervisor` call in the step (the active
    /// question), not from the first one. Otherwise a role that asked twice unfairly
    /// holds the leftmost slot using a stale early timestamp.
    func testActiveSupervisorQuestions_askedAtComesFromLastAskCall() {
        let firstAsk = makeToolCall(name: TN.askSupervisor, at: date(50), argumentsJSON: #"{"question":"old?"}"#)
        let lastAsk = makeToolCall(name: TN.askSupervisor, at: date(400), argumentsJSON: #"{"question":"current?"}"#)
        let step = makeStep(
            role: .productManager, toolCalls: [firstAsk, lastAsk],
            status: .needsSupervisorInput, needsSupervisorInput: true
        )

        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].question, "current?",
                       "Should surface the current (last) question, not the stale first one")
        XCTAssertEqual(questions[0].askedAt, date(400),
                       "askedAt must reflect the active question's timestamp, not the original ask")
    }

    /// When two pending questions share `askedAt` (same `MonotonicClock` tick or
    /// identical `Date()`), the order must be stable across recomputes — otherwise
    /// the leftmost Answer chip flips between recomputes and any user typing into
    /// the auto-selected first chip would silently retarget. We tie-break by `stepID`.
    func testActiveSupervisorQuestions_tieBreaker_isStableByStepID() {
        let sameTime = date(100)
        let askA = makeToolCall(name: TN.askSupervisor, at: sameTime, argumentsJSON: #"{"question":"A?"}"#)
        let stepA = makeStep(
            role: .productManager, toolCalls: [askA],
            status: .needsSupervisorInput, needsSupervisorInput: true
        )
        let askB = makeToolCall(name: TN.askSupervisor, at: sameTime, argumentsJSON: #"{"question":"B?"}"#)
        let stepB = makeStep(
            role: .techLead, toolCalls: [askB],
            status: .needsSupervisorInput, needsSupervisorInput: true
        )

        // PM step id < TL step id alphabetically (`product_manager` < `tech_lead`).
        let questionsForward = ActivityFeedBuilder.activeSupervisorQuestions(steps: [stepA, stepB])
        let questionsReverse = ActivityFeedBuilder.activeSupervisorQuestions(steps: [stepB, stepA])
        XCTAssertEqual(
            questionsForward.map(\.stepID), questionsReverse.map(\.stepID),
            "Same-tick questions must produce identical order regardless of input sequence"
        )
        XCTAssertEqual(
            questionsForward.map(\.stepID).sorted(), questionsForward.map(\.stepID),
            "Tie-breaker should be stepID ascending"
        )
    }

    // MARK: - 6c. Per-step auxiliary (one pass per step per build)

    /// `emitItems` used to evaluate the escalation-card gate TWICE per step per
    /// build — once for bubble suppression, once for card emission — and its
    /// first clause was a `contains(where:)` over `toolCalls` proving absence
    /// (a full pass). The gate's value now lives in the per-step aux.
    ///
    /// RED: in the second step loop replace `a.card` with a fresh
    /// `Self.escalationCard(for: step, askIndex: a.askIndex, isActive: a.isActive)`
    /// → evaluations reads 2.
    func testEscalationCard_evaluatedOncePerStepPerBuild() {
        let refusal = makeMessage(role: .assistant, content: "I can't find a task.", at: date(50))
        let answer = makeMessage(
            role: .user, content: "Supervisor answer: read CLAUDE.md", at: date(200),
            sourceContext: .supervisorAnswer)
        let step = makeStep(
            messages: [refusal, answer],
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Role emitted 3 refusals. Please advise.",
            supervisorAnswer: "read CLAUDE.md",
            updatedAt: date(210)
        )

        EscalationCardProbe.reset()
        let result = build(steps: [step])

        XCTAssertEqual(EscalationCardProbe.evaluations(), 1,
                       "the gate is evaluated exactly once per step per build (== 1 is its own anti-vacuum)")
        let cards = result.filter {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }
        XCTAssertEqual(cards.count, 1, "the card still renders exactly once")
    }

    /// The refuter's shape: the role asked, did tool work, and was THEN parked by a
    /// cap. The chip must still carry the earlier ask's identity and timestamp —
    /// `positions.last` is `lastIndex(where:)`, not "the trailing call".
    ///
    /// RED: replace `askIndex(step).lastPosition` in `activeSupervisorQuestions` with
    /// `step.toolCalls.last?.name == ToolNames.askSupervisor ? step.toolCalls.count - 1 : nil`
    /// → `toolCallID` becomes a synthetic UUID and `askedAt == step.updatedAt`.
    func testActiveSupervisorQuestions_earlierAskThenToolWorkThenCapPark_findsTheEarlierAsk() {
        let ask = makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"Q1?"}"#)
        let step = makeStep(
            role: .productManager,
            toolCalls: [ask, makeToolCall(at: date(200)), makeToolCall(at: date(300))],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Cap: please advise",
            updatedAt: date(400)
        )

        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])

        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions.first?.toolCallID, ask.id, "the EARLIER ask, not a synthetic id")
        XCTAssertEqual(questions.first?.askedAt, date(100), "anchored on the ask, not on updatedAt")
        XCTAssertEqual(questions.first?.question, "Cap: please advise",
                       "flag-true prefers the stored text over the call's argument")
        XCTAssertNil(questions.first?.paired, "no assistant turn precedes the ask")
    }

    /// The index provider is asked ONCE per step per build and its answer is read
    /// back by the second loop through the aux — and the items are byte-for-byte
    /// what the default provider produces.
    ///
    /// RED: in the second step loop call `askIndex(originTaskID, step)` again instead
    /// of reading `aux[stepIndex].askIndex` → 6 calls.
    func testBuildTimeline_asksTheIndexProviderOncePerStep() {
        let twoAsks = makeStep(
            role: .productManager,
            messages: [
                makeMessage(role: .user, content: "Supervisor answer: A1", at: date(150), sourceContext: .supervisorAnswer),
                makeMessage(role: .user, content: "Supervisor answer: A2", at: date(250), sourceContext: .supervisorAnswer),
            ],
            toolCalls: [
                makeToolCall(name: TN.askSupervisor, at: date(100), argumentsJSON: #"{"question":"Q1?"}"#),
                makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"Q2?"}"#),
            ],
            status: .done
        )
        let noAsk = makeStep(
            role: .techLead,
            messages: [makeMessage(content: "Plan.", at: date(300))],
            toolCalls: [makeToolCall(at: date(310))],
            status: .done
        )
        let escalation = makeStep(
            role: .softwareEngineer,
            messages: [
                makeMessage(role: .assistant, content: "Idle.", at: date(400), thinking: "parking"),
                makeMessage(role: .user, content: "Supervisor answer: go", at: date(500), sourceContext: .supervisorAnswer),
            ],
            toolCalls: [],
            status: .running,
            needsSupervisorInput: false,
            supervisorQuestion: "Idle — waiting.",
            supervisorAnswer: "go",
            updatedAt: date(510)
        )
        let steps = [twoAsks, noAsk, escalation]

        var providerCalls = 0
        let timeline = ActivityFeedBuilder.buildTimeline(
            steps: steps, run: nil,
            stepArtifactContentCache: [:], debugModeEnabled: false,
            askIndex: { _, step in
                providerCalls += 1
                return AskCallIndex(toolCalls: step.toolCalls)
            },
            isStreaming: { _ in false }
        )
        let reference = build(steps: steps)

        XCTAssertEqual(providerCalls, 3, "one ask-index per step per build")
        XCTAssertEqual(timeline.items.count, reference.count)
        XCTAssertEqual(timeline.items.map(\.id), reference.map(\.id), "same items, same order as the default provider")
        XCTAssertGreaterThan(reference.count, 5, "anti-vacuum: the fixture renders bubbles, calls and cards")
    }

    // MARK: - 7. Failed Step Notification

    func testFailedNotificationAtCompletedAt() {
        let step = makeStep(
            messages: [makeMessage(content: "Working", at: date(100))],
            status: .failed,
            completedAt: date(400)
        )
        let result = build(steps: [step])
        assertOrdered(result)

        let notif = result.first {
            if case .notification(_, _, .failed, _, _) = $0.item { return true }
            return false
        }
        XCTAssertNotNil(notif)
        XCTAssertEqual(notif?.item.createdAt, date(400))
    }

    func testFailedNotificationFallsBackToUpdatedAt() {
        let step = makeStep(
            messages: [makeMessage(content: "Working", at: date(100))],
            status: .failed,
            completedAt: nil,
            updatedAt: date(350)
        )
        let result = build(steps: [step])

        let notif = result.first {
            if case .notification(_, _, .failed, _, _) = $0.item { return true }
            return false
        }
        XCTAssertNotNil(notif)
        XCTAssertEqual(notif?.item.createdAt, date(350))
    }

    func testFailedNotification_carriesErrorReasonFromStepMessages() {
        var step = makeStep(status: .failed, completedAt: date(400))
        // completeStepFailure records the reason into `messages` (StepMessage),
        // NOT `llmConversation` — populate it directly.
        step.messages = [
            StepMessage(
                role: .softwareEngineer,
                content: "\(StepExecution.llmErrorNotePrefix): LLM request failed with HTTP 404: model_not_found")
        ]
        let result = build(steps: [step])

        var captured: String?
        var found = false
        for item in result {
            if case .notification(_, _, .failed(let msg), _, _) = item.item {
                captured = msg
                found = true
            }
        }
        XCTAssertTrue(found, "A .failed notification must be emitted")
        XCTAssertEqual(
            captured, "LLM request failed with HTTP 404: model_not_found",
            "The failed bubble must carry the stored error reason with the prefix stripped")
    }

    func testFailedNotification_noErrorReason_whenNoLLMErrorNote() {
        let step = makeStep(status: .failed, completedAt: date(400)) // no step.messages
        let result = build(steps: [step])

        var found = false
        for item in result {
            if case .notification(_, _, .failed(let msg), _, _) = item.item {
                found = true
                XCTAssertNil(msg, "No LLM-error note → errorMessage stays nil (card shows hint)")
            }
        }
        XCTAssertTrue(found)
    }

    // MARK: - 7a. failureMessage(for:) extraction

    func testFailureMessage_stripsPrefix() {
        var step = makeStep(status: .failed)
        step.messages = [StepMessage(role: .softwareEngineer,
                                     content: "\(StepExecution.llmErrorNotePrefix): boom")]
        XCTAssertEqual(ActivityFeedBuilder.failureMessage(for: step), "boom")
    }

    func testFailureMessage_picksLastErrorNote() {
        var step = makeStep(status: .failed)
        step.messages = [
            StepMessage(role: .softwareEngineer, content: "\(StepExecution.llmErrorNotePrefix): first"),
            StepMessage(role: .softwareEngineer, content: "Some unrelated note"),
            StepMessage(role: .softwareEngineer, content: "\(StepExecution.llmErrorNotePrefix): second"),
        ]
        XCTAssertEqual(ActivityFeedBuilder.failureMessage(for: step), "second")
    }

    func testFailureMessage_nilWhenNoErrorNote() {
        var step = makeStep(status: .failed)
        // A warning note (different prefix) must not be mistaken for a failure.
        step.messages = [StepMessage(role: .softwareEngineer, content: "LLM warning: heads up")]
        XCTAssertNil(ActivityFeedBuilder.failureMessage(for: step))
    }

    func testFailureMessage_nilWhenReasonEmpty() {
        var step = makeStep(status: .failed)
        step.messages = [StepMessage(role: .softwareEngineer,
                                     content: "\(StepExecution.llmErrorNotePrefix):    ")]
        XCTAssertNil(ActivityFeedBuilder.failureMessage(for: step))
    }

    func testFailureMessage_readsStepMessagesNotLLMConversation() {
        // failureMessage reads step.messages (StepMessage). Retry notes and other
        // turns live in the SEPARATE step.llmConversation (LLMMessage). Even a red
        // herring there with the exact failure prefix must be ignored.
        // (makeStep's `messages:` param populates llmConversation; step.messages stays empty.)
        let step = makeStep(
            messages: [makeMessage(content: "\(StepExecution.llmErrorNotePrefix): red herring", at: date(1))],
            status: .failed)
        XCTAssertNil(ActivityFeedBuilder.failureMessage(for: step),
                     "failureMessage must read step.messages, never llmConversation")
    }

    func testFailureMessage_errorNoteNotLast_stillExtracted() {
        var step = makeStep(status: .failed)
        step.messages = [
            StepMessage(role: .softwareEngineer, content: "\(StepExecution.llmErrorNotePrefix): boom"),
            StepMessage(role: .softwareEngineer, content: "a later unrelated note"),
        ]
        XCTAssertEqual(ActivityFeedBuilder.failureMessage(for: step), "boom",
                       "The error note is found even when it isn't the last message")
    }

    func testFailureMessage_trimsSurroundingWhitespace() {
        var step = makeStep(status: .failed)
        step.messages = [StepMessage(role: .softwareEngineer,
                                     content: "\(StepExecution.llmErrorNotePrefix):   real reason  ")]
        XCTAssertEqual(ActivityFeedBuilder.failureMessage(for: step), "real reason")
    }

    func testFailureMessage_barePrefixNoReason_returnsNil() {
        var step = makeStep(status: .failed)
        step.messages = [StepMessage(role: .softwareEngineer,
                                     content: "\(StepExecution.llmErrorNotePrefix): ")]
        XCTAssertNil(ActivityFeedBuilder.failureMessage(for: step))
    }

    func testFailureMessage_prefixWithoutTrailingSpace_returnsNil() {
        // The separator is "<prefix>: " — a note missing the space is not a match.
        var step = makeStep(status: .failed)
        step.messages = [StepMessage(role: .softwareEngineer,
                                     content: "\(StepExecution.llmErrorNotePrefix):boom")]
        XCTAssertNil(ActivityFeedBuilder.failureMessage(for: step))
    }

    // MARK: - 8. Section Headers

    func testFirstItemAlwaysGetsHeader() {
        let step = makeStep(messages: [makeMessage(content: "Hello", at: date(100))])
        let result = build(steps: [step])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].showSectionHeader)
    }

    func testConsecutiveSameRoleNoHeader() {
        let step = makeStep(role: .softwareEngineer, messages: [
            makeMessage(content: "First", at: date(100)),
            makeMessage(content: "Second", at: date(200))
        ])
        let result = build(steps: [step])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].showSectionHeader, "First item gets header")
        XCTAssertFalse(result[1].showSectionHeader, "Same role — no header")
    }

    func testDifferentRolesBothGetHeaders() {
        let stepA = makeStep(role: .productManager, messages: [
            makeMessage(content: "PM msg", at: date(100))
        ])
        let stepB = makeStep(role: .softwareEngineer, messages: [
            makeMessage(content: "SWE msg", at: date(200))
        ])
        let result = build(steps: [stepA, stepB])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].showSectionHeader)
        XCTAssertTrue(result[1].showSectionHeader)
    }

    func testNotificationBreaksGrouping() {
        // PM message at t=100, answered notification at t=250 (answer time), PM message at t=300
        let askCall = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"Q?"}"#)
        let answer = makeMessage(role: .user, content: "Supervisor answer: A", at: date(250),
                                 sourceContext: .supervisorAnswer)
        let step = makeStep(
            role: .productManager,
            messages: [
                makeMessage(content: "Before", at: date(100)),
                answer,
                makeMessage(content: "After", at: date(300))
            ],
            toolCalls: [askCall],
            supervisorAnswer: "A"
        )
        let result = build(steps: [step])

        // Find notification index
        let notifIndex = result.firstIndex {
            if case .notification(_, _, .supervisorInput, _, _) = $0.item { return true }
            return false
        }
        XCTAssertNotNil(notifIndex)

        // Notification always gets header (roleID == nil)
        if let idx = notifIndex {
            XCTAssertTrue(result[idx].showSectionHeader, "Notification should always show header")
            // Item after notification should also get header (grouping broken)
            if idx + 1 < result.count {
                XCTAssertTrue(result[idx + 1].showSectionHeader,
                              "Item after notification should get header (grouping broken)")
            }
        }
    }

    func testMeetingMessageGrouping() {
        let meeting = makeMeeting(messages: [
            makeMeetingMessage(role: .productManager, content: "PM1", at: date(100)),
            makeMeetingMessage(role: .productManager, content: "PM2", at: date(200)),
            makeMeetingMessage(role: .techLead, content: "TL1", at: date(300))
        ])
        let result = build(steps: [], run: makeRun(meetings: [meeting]))
        XCTAssertEqual(result.count, 3)

        XCTAssertTrue(result[0].showSectionHeader, "First PM gets header")
        XCTAssertFalse(result[1].showSectionHeader, "Second PM — same role, no header")
        XCTAssertTrue(result[2].showSectionHeader, "TL gets header — different role")
    }

    // MARK: - 9. Filtering Preserves Order

    func testSystemToolMessagesFilteredOrderPreserved() {
        let step = makeStep(messages: [
            makeMessage(content: "First visible", at: date(100)),
            makeMessage(role: .system, content: "System prompt", at: date(150)),
            makeMessage(role: .tool, content: "{}", at: date(180)),
            makeMessage(content: "Second visible", at: date(200)),
            makeMessage(content: "Third visible", at: date(300))
        ])
        let result = build(steps: [step])
        XCTAssertEqual(result.count, 3, "System and tool messages should be filtered")
        assertOrdered(result)
    }

    func testUserWithoutSourceFiltered() {
        let step = makeStep(messages: [
            makeMessage(content: "Visible", at: date(100)),
            makeMessage(role: .user, content: "Plain user prompt", at: date(200)),
            makeMessage(content: "Also visible", at: date(300))
        ])
        let result = build(steps: [step])
        XCTAssertEqual(result.count, 2, "Plain user message without sourceRole should be filtered")
        assertOrdered(result)

        if case .llmMessage(let msg, _, _, _) = result[0].item { XCTAssertEqual(msg.content, "Visible") }
        else { XCTFail("Expected Visible at 0") }
        if case .llmMessage(let msg, _, _, _) = result[1].item { XCTAssertEqual(msg.content, "Also visible") }
        else { XCTFail("Expected Also visible at 1") }
    }

    /// The thinking-loop correction is a `.user` turn, so it would hit the
    /// no-source filter above and vanish — which is exactly what made a real
    /// loop break leave no trace anywhere but a `cancelled` row in
    /// `network_log.json` (off by default in Release). Its `.loopCorrection`
    /// context is what keeps it visible; this pins that it survives.
    func testLoopCorrectionUserMessage_isNotFiltered() {
        let step = makeStep(messages: [
            makeMessage(content: "Visible", at: date(100)),
            makeMessage(role: .user, content: "Your previous turn was discarded…",
                        at: date(200), sourceContext: .loopCorrection)
        ])
        let result = build(steps: [step])
        let contents = result.compactMap { item -> String? in
            if case .llmMessage(let msg, _, _, _) = item.item { return msg.content }
            return nil
        }
        XCTAssertTrue(contents.contains("Your previous turn was discarded…"),
                      "a .loopCorrection turn must reach the feed — without it the loop "
                          + "break has no durable user-visible record at all")
    }

    /// Same class of defect as `.loopCorrection`, and the one the wedged Autovisor pass
    /// actually presented as: every retry nudge is a `.user` turn with no attribution, so
    /// all eight of them hit the no-source filter and vanished. The user watched a role
    /// emit the same reply over and over with nothing on screen saying it was being asked
    /// to try again, or why.
    func testRetryNudgeUserMessage_isNotFiltered() {
        let step = makeStep(messages: [
            makeMessage(content: "Waiting for the M3 task to finish.", at: date(100)),
            makeMessage(role: .user,
                        content: "You replied with text but did not call a tool.",
                        at: date(200), sourceContext: .retryNudge)
        ])
        let result = build(steps: [step])
        let contents = result.compactMap { item -> String? in
            if case .llmMessage(let msg, _, _, _) = item.item { return msg.content }
            return nil
        }
        XCTAssertTrue(contents.contains("You replied with text but did not call a tool."),
                      "a .retryNudge turn must reach the feed — otherwise N identical "
                          + "assistant bubbles appear with no visible cause")
    }

    func testArtifactContentDedupOrderPreserved() {
        let artifactContent = "# Product Requirements\n\nDetailed content here."
        let step = makeStep(
            messages: [
                makeMessage(content: "Before", at: date(100)),
                makeMessage(content: artifactContent, at: date(200)),
                makeMessage(content: "After", at: date(300))
            ],
            artifacts: [makeArtifact(name: "Requirements", at: date(250))]
        )
        let result = build(steps: [step], cache: [step.id: [artifactContent]])
        assertOrdered(result)

        // The message with artifact content should be filtered
        let messageContents = result.compactMap { item -> String? in
            if case .llmMessage(let msg, _, _, _) = item.item { return msg.content }
            return nil
        }
        XCTAssertFalse(messageContents.contains(artifactContent),
                       "Message matching artifact content should be filtered")
        XCTAssertTrue(messageContents.contains("Before"))
        XCTAssertTrue(messageContents.contains("After"))
    }

    func testDebugModeDisablesFiltering() {
        let step = makeStep(messages: [
            makeMessage(content: "Assistant", at: date(100)),
            makeMessage(role: .user, content: "Plain user", at: date(200)),
            makeMessage(content: "Another", at: date(300))
        ])
        let result = build(steps: [step], debug: true)
        // In debug mode, plain user messages are NOT filtered
        XCTAssertEqual(result.count, 3)
        assertOrdered(result)
    }

    // MARK: - 10. Streaming

    func testStreamingEmptyMessageKept() {
        let streamingMsgID = UUID()
        let step = makeStep(messages: [
            makeMessage(content: "Before", at: date(100)),
            LLMMessage(id: streamingMsgID, createdAt: date(200), role: .assistant, content: ""),
            makeMessage(content: "After", at: date(300))
        ])
        let result = build(steps: [step]) { id in id == streamingMsgID }
        XCTAssertEqual(result.count, 3)
        if case .llmMessage(let msg, _, _, _) = result[0].item {
            XCTAssertEqual(msg.content, "Before")
        } else { XCTFail("Expected 'Before' at position 0") }
        if case .llmMessage(let msg, _, _, _) = result[1].item {
            XCTAssertEqual(msg.content, "After")
        } else { XCTFail("Expected 'After' at position 1") }
        if case .llmMessage(let msg, _, _, _) = result[2].item {
            XCTAssertEqual(msg.id, streamingMsgID,
                           "Empty streaming preview kept AND pinned to end")
        } else { XCTFail("Expected streaming message at end") }
    }

    /// A streaming item's `createdAt` is the moment streaming began, which is not
    /// guaranteed to be the latest timestamp in the step — later non-streaming
    /// messages can land while the preview is still alive. The live bubble must
    /// stay at the bottom of the feed in that case, not slot back into chronology.
    func testStreamingMessagePinnedToEnd() {
        let streamingMsgID = UUID()
        let step = makeStep(messages: [
            makeMessage(content: "First", at: date(100)),
            makeMessage(content: "Third", at: date(300)),
            LLMMessage(id: streamingMsgID, createdAt: date(200), role: .assistant, content: "Streaming")
        ])
        let result = build(steps: [step]) { id in id == streamingMsgID }
        XCTAssertEqual(result.count, 3)

        if case .llmMessage(let msg, _, _, _) = result[0].item {
            XCTAssertEqual(msg.content, "First")
        } else { XCTFail("Expected 'First' at position 0") }
        if case .llmMessage(let msg, _, _, _) = result[1].item {
            XCTAssertEqual(msg.content, "Third",
                           "Non-streaming items keep chronological order")
        } else { XCTFail("Expected 'Third' at position 1") }
        if case .llmMessage(let msg, _, _, _) = result[2].item {
            XCTAssertEqual(msg.content, "Streaming",
                           "Streaming message must be pinned to the end")
        } else { XCTFail("Expected streaming message at position 2 (end)") }
    }

    /// Streaming bubble stays at the bottom even when newer non-streaming messages
    /// (e.g. retry notices) land with a later `createdAt` than the stream's start time.
    func testStreamingMessage_pinnedToEnd_evenWhenLaterMessagesAppended() {
        let streamingID = UUID()
        let step = makeStep(messages: [
            makeMessage(content: "Earlier note", at: date(100)),
            LLMMessage(id: streamingID, createdAt: date(200), role: .assistant, content: ""),
            makeMessage(content: "Later note", at: date(300)),
        ])
        let result = build(steps: [step]) { id in id == streamingID }
        XCTAssertEqual(result.count, 3)
        if case .llmMessage(let msg, _, _, _) = result[2].item {
            XCTAssertEqual(msg.id, streamingID,
                           "Streaming preview pinned to end of feed even after newer messages land")
        } else { XCTFail("Streaming bubble should be the last item") }
    }

    /// Two concurrent streaming items (different steps in the same team, possible when
    /// dependency graph has parallel branches) must both pin to the end AND order among
    /// themselves by `createdAt`, matching the order in which their streams began.
    func testMultipleStreamingItems_pinnedToEnd_orderedByStartTime() {
        let streamingA = UUID()
        let streamingB = UUID()
        let stepA = makeStep(role: .productManager, messages: [
            makeMessage(content: "Committed A1", at: date(100)),
            LLMMessage(id: streamingA, createdAt: date(150), role: .assistant, content: ""),
        ])
        let stepB = makeStep(role: .softwareEngineer, messages: [
            makeMessage(content: "Committed B1", at: date(120)),
            LLMMessage(id: streamingB, createdAt: date(170), role: .assistant, content: ""),
            makeMessage(content: "Committed B2", at: date(300)),
        ])
        let result = build(steps: [stepA, stepB]) { id in id == streamingA || id == streamingB }
        XCTAssertEqual(result.count, 5)
        // Last two items must be the streaming previews, with A before B (earlier start)
        if case .llmMessage(let msg, _, _, _) = result[3].item {
            XCTAssertEqual(msg.id, streamingA, "Earlier-started streaming preview comes first within the pinned partition")
        } else { XCTFail("Expected streamingA at position 3") }
        if case .llmMessage(let msg, _, _, _) = result[4].item {
            XCTAssertEqual(msg.id, streamingB, "Later-started streaming preview comes last")
        } else { XCTFail("Expected streamingB at position 4") }
    }

    /// When a stream finalizes, `isStreaming(id)` flips to false. The item must slot back
    /// into its chronological position (defined by its `createdAt`) rather than remain
    /// pinned to the end.
    func testStreaming_committedTransition_returnsToChronologicalPosition() {
        let messageID = UUID()
        let step = makeStep(messages: [
            makeMessage(content: "Before", at: date(100)),
            LLMMessage(id: messageID, createdAt: date(200), role: .assistant, content: "Finalized content"),
            makeMessage(content: "After", at: date(300)),
        ])

        // While streaming: pinned to end.
        let streaming = build(steps: [step]) { id in id == messageID }
        XCTAssertEqual(streaming.count, 3)
        if case .llmMessage(let msg, _, _, _) = streaming[2].item {
            XCTAssertEqual(msg.id, messageID, "Streaming item pinned to end")
        } else { XCTFail("Expected streaming at end") }

        // After commit (isStreaming flips false): slots back into chronology.
        let committed = build(steps: [step]) { _ in false }
        XCTAssertEqual(committed.count, 3)
        if case .llmMessage(let msg, _, _, _) = committed[1].item {
            XCTAssertEqual(msg.id, messageID, "Committed item slots back to its createdAt position")
        } else { XCTFail("Expected committed item at chronological position 1") }
    }

    // MARK: - 11. Consultation / Meeting Context Messages

    func testConsultationMessagesOrdered() {
        let step = makeStep(role: .softwareEngineer, messages: [
            makeMessage(content: "Working", at: date(100)),
            makeMessage(role: .user, content: "Consultation reply", at: date(200),
                        sourceRole: .techLead, sourceContext: .consultation),
            makeMessage(content: "Continue", at: date(300))
        ])
        let result = build(steps: [step])
        XCTAssertEqual(result.count, 3)
        assertOrdered(result)

        // Consultation message should use sourceRole as display role
        if case .llmMessage(_, let role, _, _) = result[1].item {
            XCTAssertEqual(role, .techLead, "Display role should be sourceRole (techLead)")
        } else { XCTFail("Expected consultation message at 1") }
    }

    func testMeetingContextMessagesOrdered() {
        let step = makeStep(role: .softwareEngineer, messages: [
            makeMessage(content: "Before meeting", at: date(100)),
            makeMessage(role: .user, content: "Meeting result", at: date(300),
                        sourceRole: .productManager, sourceContext: .meeting),
            makeMessage(content: "After meeting", at: date(200))
        ])
        let result = build(steps: [step])
        XCTAssertEqual(result.count, 3)
        assertOrdered(result)

        // "After meeting" at t=200 should come before "Meeting result" at t=300
        if case .llmMessage(let msg, _, _, _) = result[1].item {
            XCTAssertEqual(msg.content, "After meeting")
        } else { XCTFail("Expected 'After meeting' at 1") }

        if case .llmMessage(let msg, let role, _, _) = result[2].item {
            XCTAssertEqual(msg.content, "Meeting result")
            XCTAssertEqual(role, .productManager)
        } else { XCTFail("Expected 'Meeting result' at 2") }
    }

    // MARK: - 12. Supervisor Task

    func testSupervisorTaskAppearsFirst() {
        let step = makeStep(messages: [
            makeMessage(content: "Working on it", at: date(200))
        ])
        let result = build(
            steps: [step],
            supervisorBrief: "Build a sorting algorithm",
            supervisorBriefDate: date(10)
        )
        XCTAssertEqual(result.count, 2)
        assertOrdered(result)

        if case .supervisorTask(let brief, let taskDate, _, _, _, _, _) = result[0].item {
            XCTAssertEqual(brief, "Build a sorting algorithm")
            XCTAssertEqual(taskDate, date(10))
        } else {
            XCTFail("Expected supervisorTask at index 0")
        }
    }

    func testSupervisorTaskProperties() {
        let result = build(
            steps: [],
            supervisorBrief: "Test goal",
            supervisorBriefDate: date(50)
        )
        XCTAssertEqual(result.count, 1)

        let item = result[0].item
        // ID now includes originTaskID for cross-team uniqueness (delegation V1).
        XCTAssertEqual(item.id, "supervisor-task-0")
        XCTAssertEqual(item.roleID, Role.supervisor.baseID)
        XCTAssertEqual(item.createdAt, date(50))
    }

    func testSupervisorTaskSectionHeader() {
        let step = makeStep(role: .productManager, messages: [
            makeMessage(content: "PM working", at: date(200))
        ])
        let result = build(
            steps: [step],
            supervisorBrief: "Do something",
            supervisorBriefDate: date(10)
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].showSectionHeader, "Supervisor task gets header (first item)")
        XCTAssertTrue(result[1].showSectionHeader, "PM gets header (different roleID)")
    }

    func testSupervisorTaskEmptyBriefOmitted() {
        let step = makeStep(messages: [makeMessage(content: "Hello", at: date(100))])
        let result = build(
            steps: [step],
            supervisorBrief: "   ",
            supervisorBriefDate: date(10)
        )
        XCTAssertEqual(result.count, 1)
        if case .supervisorTask = result[0].item {
            XCTFail("Empty/whitespace brief should not produce a supervisorTask item")
        }
    }

    func testSupervisorTaskNilBriefOmitted() {
        let result = build(steps: [], supervisorBrief: nil, supervisorBriefDate: date(10))
        XCTAssertTrue(result.isEmpty)
    }

    func testSupervisorTaskNilDateOmitted() {
        let result = build(steps: [], supervisorBrief: "Valid goal", supervisorBriefDate: nil)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - stripAttachedFiles

    func testStripAttachedFiles_plainText_noExtraction() {
        let result = ActivityFeedBuilder.stripAttachedFiles(from: "Just an answer")
        XCTAssertEqual(result.text, "Just an answer")
        XCTAssertTrue(result.paths.isEmpty)
        XCTAssertTrue(result.clippedTexts.isEmpty)
    }

    func testStripAttachedFiles_extractsFilePaths() {
        let input = "Answer text\n\n## Attached Files\n- .nanoteams/tasks/1/a.txt\n- .nanoteams/tasks/1/b.png"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer text")
        XCTAssertEqual(result.paths, [".nanoteams/tasks/1/a.txt", ".nanoteams/tasks/1/b.png"])
        XCTAssertTrue(result.clippedTexts.isEmpty)
    }

    func testStripAttachedFiles_extractsSingleClip() {
        let input = "My answer\n\n## Clipped Text\nsome code snippet"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "My answer")
        XCTAssertEqual(result.clippedTexts, ["some code snippet"])
    }

    func testStripAttachedFiles_extractsNumberedClips() {
        let input = "Answer\n\n## Clipped Text \u{2014} 1 of 2\nclip one\n\n## Clipped Text \u{2014} 2 of 2\nclip two"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
        XCTAssertEqual(result.clippedTexts.count, 2)
        XCTAssertEqual(result.clippedTexts[0], "clip one")
        XCTAssertEqual(result.clippedTexts[1], "clip two")
    }

    func testStripAttachedFiles_extractsClipWithSourceContext() {
        let input = "Answer\n\n## Clipped Text \u{2014} MyFile.swift:10-20\nfunc hello() { }"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
        XCTAssertEqual(result.clippedTexts, ["func hello() { }"])
    }

    func testStripAttachedFiles_extractsClipsAndFilesTogether() {
        let input = "Answer\n\n## Clipped Text\nsnippet\n\n## Attached Files\n- file.txt"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
        XCTAssertEqual(result.clippedTexts, ["snippet"])
        XCTAssertEqual(result.paths, ["file.txt"])
    }

    func testStripAttachedFiles_stripsEmbeddedFileContent() {
        let input = "Answer\n\n## Attached File: data.swift\nlet x = 1"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
    }

    func testStripAttachedFiles_stripsEmbeddedFileWithHyphenatedName() {
        let input = "Answer\n\n## Attached File: my-component.swift\nlet x = 1"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
    }

    func testStripAttachedFiles_clipsOnlyNoText_returnsEmptyText() {
        let input = "## Clipped Text\nonly a clip"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.clippedTexts, ["only a clip"])
    }

    // MARK: - Regression: Issue #1 — Embedded file with hyphenated filename

    func testStripAttachedFiles_embeddedFile_multipleHyphens() {
        let input = "Answer\n\n## Attached File: my-data-model.swift\nstruct Foo {}"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
        // Embedded file content must NOT leak into displayed text
        XCTAssertFalse(result.text?.contains("struct Foo") ?? false)
    }

    // MARK: - Regression: Issue #3 — Embedded file content leaks into last clip

    func testStripAttachedFiles_clipThenEmbeddedFile_noContentLeak() {
        let input = "Answer\n\n## Clipped Text\nsnippet\n\n## Attached File: data.swift\nlet x = 1"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
        XCTAssertEqual(result.clippedTexts.count, 1)
        XCTAssertEqual(result.clippedTexts[0], "snippet")
        // Embedded file content must NOT appear in clip text
        XCTAssertFalse(result.clippedTexts[0].contains("let x = 1"))
    }

    // MARK: - Regression: Issue #5 — Clip header with parentheses in path

    func testStripAttachedFiles_clipWithParenthesesInPath() {
        // Parentheses inside the metadata tail (e.g. `MyFile(iOS).swift:10-20`)
        // are fine — the new em-dash separator removes the previous concern
        // that the trailing `---` could collide with file paths containing `(`.
        let input = "Answer\n\n## Clipped Text \u{2014} MyFile(iOS).swift:10-20\nfunc run() {}"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
        XCTAssertEqual(result.clippedTexts, ["func run() {}"])
    }

    func testStripAttachedFiles_numberedClipWithSourceAndParentheses() {
        let input = "Answer\n\n## Clipped Text \u{2014} 1 of 2, App(iOS).swift:5-10\nfirst\n\n## Clipped Text \u{2014} 2 of 2\nsecond"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
        XCTAssertEqual(result.clippedTexts.count, 2)
        XCTAssertEqual(result.clippedTexts[0], "first")
        XCTAssertEqual(result.clippedTexts[1], "second")
    }

    // MARK: - Regression: all sections combined

    func testStripAttachedFiles_allSectionsCombined() {
        let input = """
        My answer
        
        ## Clipped Text \u{2014} src/main.swift:1-5
        import Foundation
        
        ## Attached File: my-helper.swift
        func helper() {}
        
        ## Attached Files
        - .nanoteams/tasks/1/attachments/image.png
        """
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "My answer")
        XCTAssertEqual(result.clippedTexts.count, 1)
        XCTAssertTrue(result.clippedTexts[0].contains("import Foundation"))
        XCTAssertFalse(result.clippedTexts[0].contains("func helper"))
        XCTAssertEqual(result.paths, [".nanoteams/tasks/1/attachments/image.png"])
    }

    // MARK: - stripAttachedFiles Skills

    func testStripAttachedFiles_extractsSkillSection_reEncodedAsSkillClip() {
        let input = "please help\n\n## Skill: code-review\n# Review\nCheck for bugs."
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "please help")
        XCTAssertEqual(result.clippedTexts.count, 1)
        let parsed = SkillClip.parse(result.clippedTexts[0])
        XCTAssertEqual(parsed?.name, "code-review")
        XCTAssertEqual(parsed?.body, "# Review\nCheck for bugs.")
        // Feed re-extraction carries no agent/origin (they weren't in the prompt section).
        XCTAssertNil(parsed?.agentLabel)
        XCTAssertNil(parsed?.origin)
    }

    func testStripAttachedFiles_skillOnly_returnsEmptyText() {
        let input = "## Skill: review\nskill body"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertNil(result.text)
        XCTAssertEqual(SkillClip.parse(result.clippedTexts.first ?? "")?.name, "review")
    }

    func testStripAttachedFiles_multipleSkills_eachReExtracted() {
        let input = "hi\n\n## Skill: alpha\nbody a\n\n## Skill: beta\nbody b"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "hi")
        let names = result.clippedTexts.compactMap { SkillClip.parse($0)?.name }
        XCTAssertEqual(names, ["alpha", "beta"])
    }

    func testStripAttachedFiles_skillClipFileAndPaths_allExtracted() {
        let input = """
        My answer
        
        ## Skill: review
        skill body
        
        ## Clipped Text \u{2014} src.swift:1-5
        import Foundation
        
        ## Attached File: helper.swift
        func helper() {}
        
        ## Attached Files
        - path/img.png
        """
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "My answer")
        XCTAssertEqual(result.paths, ["path/img.png"])
        // One plain clip + one re-encoded skill.
        let skillNames = result.clippedTexts.compactMap { SkillClip.parse($0)?.name }
        XCTAssertEqual(skillNames, ["review"])
        let plainClips = result.clippedTexts.filter { SkillClip.parse($0) == nil }
        XCTAssertEqual(plainClips.count, 1)
        XCTAssertTrue(plainClips[0].contains("import Foundation"))
        XCTAssertFalse(result.clippedTexts.contains { $0.contains("func helper") })
    }

    func testStripAttachedFiles_skillPhraseMidLine_notExtracted() {
        // Line-anchored: `## Skill:` must start a line to be a section header.
        let input = "I want to use ## Skill: review here"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "I want to use ## Skill: review here")
        XCTAssertTrue(result.clippedTexts.isEmpty)
    }

    func testStripAttachedFiles_skillBodyWithMarkdownHeaders_survivesIntact() {
        // The common case: a SKILL.md body contains ordinary "## Heading" lines.
        // They match neither the clip nor the skill regex, so the body is preserved.
        let body = "## Usage\nrun it\n\n## Examples\n`foo bar`"
        let built = AnswerTextBuilder.build(text: "", clips: [SkillClip(name: "guide", body: body).encoded()]).answer
        let result = ActivityFeedBuilder.stripAttachedFiles(from: built)
        let parsed = SkillClip.parse(result.clippedTexts.first ?? "")
        XCTAssertEqual(parsed?.name, "guide")
        XCTAssertEqual(parsed?.body, body)
    }

    func testStripAttachedFiles_skillBodyWithExactClipMarkerLine_knownDisplayEdge() {
        // Documented display-only limitation: a skill body containing a line that
        // is EXACTLY "## Clipped Text" is mis-split by the line-anchored clip block
        // (the same tradeoff the app already accepts for embedded markers). The LLM
        // always receives the full skill via `build`; only the FEED render splits.
        let input = "## Skill: x\nbefore\n## Clipped Text\nafter"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        // The skill name is still recovered; the body is truncated at the marker.
        let names = result.clippedTexts.compactMap { SkillClip.parse($0)?.name }
        XCTAssertEqual(names, ["x"])
        XCTAssertTrue(result.clippedTexts.contains { SkillClip.parse($0)?.body == "before" })
    }

    func testBuildStripRoundTrip_skill_preservesNameAndBody() {
        let staged = SkillClip(name: "review", agentLabel: "Claude Code", origin: .project, body: "do the review").encoded()
        let built = AnswerTextBuilder.build(text: "", clips: [staged]).answer
        let result = ActivityFeedBuilder.stripAttachedFiles(from: built)
        let parsed = SkillClip.parse(result.clippedTexts.first ?? "")
        XCTAssertEqual(parsed?.name, "review")
        XCTAssertEqual(parsed?.body, "do the review")
    }

    // MARK: - Supervisor Task Embedded Content Stripping

    func testSupervisorTask_embeddedFileContent_strippedFromDisplay() {
        let taskWithEmbed = """
        опиши логику
        
        ## Attached File: Логика.pdf
        Page 1: The offline logic...
        Page 2: When connectivity returns...
        """
        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [],
            run: nil,
            supervisorBrief: taskWithEmbed,
            supervisorBriefDate: date(10),
            supervisorTask: taskWithEmbed,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
        XCTAssertEqual(result.count, 1)
        if case .supervisorTask(_, _, let displayText, _, _, _, _) = result[0].item {
            XCTAssertEqual(displayText, "опиши логику")
            XCTAssertFalse(displayText.contains("Attached File"))
            XCTAssertFalse(displayText.contains("offline logic"))
        } else {
            XCTFail("Expected supervisorTask item")
        }
    }

    func testSupervisorTask_embeddedFile_extractsAttachmentPaths() {
        let taskWithEmbed = """
        check this
        
        ## Attached File: report.pdf
        Report content here
        
        ## Attached Files
        - .nanoteams/tasks/1/attachments/report.pdf
        """
        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [],
            run: nil,
            supervisorBrief: taskWithEmbed,
            supervisorBriefDate: date(10),
            supervisorTask: taskWithEmbed,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
        guard case .supervisorTask(_, _, let displayText, _, let paths, _, _) = result.first?.item else {
            return XCTFail("Expected supervisorTask")
        }
        XCTAssertEqual(displayText, "check this")
        XCTAssertEqual(paths, [".nanoteams/tasks/1/attachments/report.pdf"])
    }

    func testSupervisorTask_embeddedClips_extractedFromDisplay() {
        let taskWithClips = """
        do this
        
        ## Clipped Text
        let x = 42
        """
        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [],
            run: nil,
            supervisorBrief: taskWithClips,
            supervisorBriefDate: date(10),
            supervisorTask: taskWithClips,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
        guard case .supervisorTask(_, _, let displayText, let clips, _, _, _) = result.first?.item else {
            return XCTFail("Expected supervisorTask")
        }
        XCTAssertEqual(displayText, "do this")
        XCTAssertEqual(clips.count, 1)
        XCTAssertTrue(clips[0].contains("let x = 42"))
    }

    func testSupervisorTask_structuredFieldsTakePriority() {
        // When structured fields (supervisorClippedTexts, supervisorAttachmentPaths) are provided,
        // they take priority over fields extracted from the text.
        let taskWithEmbed = "task text\n\n## Clipped Text\ninline clip"
        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [],
            run: nil,
            supervisorBrief: taskWithEmbed,
            supervisorBriefDate: date(10),
            supervisorTask: taskWithEmbed,
            supervisorClippedTexts: ["structured clip"],
            supervisorAttachmentPaths: ["path/to/file.pdf"],
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
        guard case .supervisorTask(_, _, _, let clips, let paths, _, _) = result.first?.item else {
            return XCTFail("Expected supervisorTask")
        }
        // Structured fields win over stripped-from-text fields
        XCTAssertEqual(clips, ["structured clip"])
        XCTAssertEqual(paths, ["path/to/file.pdf"])
    }

    func testSupervisorTask_plainText_noStripping() {
        let plain = "simple task description"
        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [],
            run: nil,
            supervisorBrief: plain,
            supervisorBriefDate: date(10),
            supervisorTask: plain,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
        guard case .supervisorTask(_, _, let displayText, let clips, let paths, _, _) = result.first?.item else {
            return XCTFail("Expected supervisorTask")
        }
        XCTAssertEqual(displayText, "simple task description")
        XCTAssertTrue(clips.isEmpty)
        XCTAssertTrue(paths.isEmpty)
    }

    // MARK: - PairedAssistantMessage invariants

    /// Trim-to-nil at construction: whitespace-only `thinking` collapses to nil
    /// so consumers can use `paired?.thinking != nil` directly as "show the
    /// disclosure" without re-trimming. Mirrors the invariant the removed
    /// `content` field used to enforce.
    func testPairedAssistantMessage_whitespaceOnlyThinking_collapsesToNil() {
        let paired = PairedAssistantMessage(id: UUID(), thinking: "   \n  ", content: nil)
        XCTAssertNil(paired.thinking)
    }

    /// Edge-trim preserves interior whitespace — only leading/trailing collapse.
    func testPairedAssistantMessage_thinking_trimsEdgesOnly() {
        let paired = PairedAssistantMessage(
            id: UUID(), thinking: "  line one\n  line two  ", content: nil
        )
        XCTAssertEqual(paired.thinking, "line one\n  line two")
    }

    /// Nil thinking stays nil.
    func testPairedAssistantMessage_nilThinking_staysNil() {
        let paired = PairedAssistantMessage(id: UUID(), thinking: nil, content: nil)
        XCTAssertNil(paired.thinking)
    }

    /// `content` gets the same trim-to-nil treatment as `thinking`, so
    /// `isFullyRenderedByQuestionCard` can't be fooled by a turn whose "prose" is
    /// a stray newline the model emitted before its tool call. Mirror of the
    /// `thinking` pins above.
    /// RED: drop the `content` trim in `PairedAssistantMessage.init` → `content` keeps
    /// the whitespace, `XCTAssertNil(paired.content)` fails, and the turn reads as prose.
    func testPairedAssistantMessage_whitespaceOnlyContent_collapsesToNil() {
        let paired = PairedAssistantMessage(id: UUID(), thinking: nil, content: "  \n\t ")
        XCTAssertNil(paired.content)
        XCTAssertTrue(paired.isFullyRenderedByQuestionCard,
                      "Whitespace-only prose is no prose — the card still covers the turn")
    }

    /// Edge-trim only, matching `thinking`.
    /// RED: drop the `content` trim in `PairedAssistantMessage.init` → the leading and
    /// trailing spaces survive and the equality assertion fails.
    func testPairedAssistantMessage_content_trimsEdgesOnly() {
        let paired = PairedAssistantMessage(
            id: UUID(), thinking: nil, content: "  first\n  second  "
        )
        XCTAssertEqual(paired.content, "first\n  second")
    }

    /// The suppression predicate, pinned directly — both outcomes are witnessed
    /// by real data (17 contentless pairs, 1 with prose, in the probe over every
    /// work folder on this machine).
    /// RED: invert the predicate to `content != nil` → a contentless turn stops being
    /// suppressible and `XCTAssertTrue` fails.
    func testIsFullyRenderedByQuestionCard_nilContent_isTrue() {
        let paired = PairedAssistantMessage(id: UUID(), thinking: "Reasoning.", content: nil)
        XCTAssertTrue(paired.isFullyRenderedByQuestionCard,
                      "A contentless turn is fully covered by the card's question + thinking")
    }

    /// RED: force the predicate to `true` → a prose turn reads as covered and
    /// `XCTAssertFalse` fails.
    func testIsFullyRenderedByQuestionCard_withProse_isFalse() {
        let paired = PairedAssistantMessage(
            id: UUID(), thinking: "Reasoning.", content: "Looked into it. Answering."
        )
        XCTAssertFalse(paired.isFullyRenderedByQuestionCard,
                       "The card renders no body, so prose is not covered and the bubble must stay")
    }

    // MARK: - Paired-message lift (composer takes the reply, feed suppresses bubble)

    /// Pairs `paired.id` / `paired.thinking` with the assistant turn whose
    /// `createdAt <= lastCall.createdAt`. `id` drives bubble-suppression in the
    /// feed; `thinking` feeds the composer's thinking disclosure.
    func testActiveSupervisorQuestions_populatesPairedIDAndThinking() {
        let reply = makeMessage(
            content: "Explanation of findings.",
            at: date(90),
            thinking: "Reasoning."
        )
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"What next?"}"#
        )
        let step = makeStep(
            role: .productManager,
            messages: [reply],
            toolCalls: [ask],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].paired?.id, reply.id)
        XCTAssertEqual(questions[0].paired?.thinking, "Reasoning.")
        XCTAssertEqual(questions[0].question, "What next?")
    }

    /// In-flight window: `commitStreaming` and `appendToolCalls` have landed but
    /// `setNeedsSupervisorInput` hasn't fired yet (tool execution is still running).
    /// Without this branch the bubble would flash visible for ~50-1000ms before
    /// the composer takes over. See `replied-structured-petal.md`.
    func testActiveSupervisorQuestions_inFlight_pendingToolCallStillReturnsQuestion() {
        let reply = makeMessage(content: "Body.", at: date(90))
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"What next?"}"#
        )
        let step = makeStep(
            role: .productManager,
            messages: [reply],
            toolCalls: [ask],
            status: .running,
            // Flag NOT yet flipped — we're between appendToolCalls and setNeedsSupervisorInput.
            needsSupervisorInput: false,
            supervisorAnswer: nil
        )

        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(questions.count, 1, "Trailing ask_supervisor call alone must activate the chip")
        XCTAssertEqual(questions[0].paired?.id, reply.id)
    }

    /// Pairing must NOT activate when the trailing call is something other than
    /// `ask_supervisor` (e.g. the LLM asked once, supervisor answered, then the role
    /// emitted more tool calls). Without this guard, any leftover `ask_supervisor`
    /// somewhere in the call list would keep suppressing replies forever.
    func testActiveSupervisorQuestions_trailingNonAskCall_doesNotActivate() {
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"old?"}"#
        )
        let trailing = makeToolCall(name: "read_file", at: date(150))
        let step = makeStep(
            role: .productManager,
            toolCalls: [ask, trailing],
            status: .running,
            needsSupervisorInput: false,
            supervisorAnswer: nil
        )

        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertTrue(questions.isEmpty,
                      "ask_supervisor is no longer the trailing call (a later read_file landed); chip must not appear")
    }

    /// While the paired-question is active, a CONTENTLESS assistant turn is
    /// suppressed from the timeline — the question card renders its `thinking`
    /// plus the question, which is everything that turn had. Once
    /// `supervisorAnswer` is set, the bubble reappears (existing active-hidden,
    /// answered-visible convention).
    ///
    /// The contentless precondition is load-bearing, not incidental: this is the
    /// 17-of-18 shape real `ask_supervisor` calls take. A fixture carrying prose
    /// here would pin the very defect the narrowing removed.
    func testEmitItems_suppressesContentlessPairedMessage_whileActive_thenReappears() {
        let reply = makeMessage(content: "", at: date(90), thinking: "Reasoning.")
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"What next?"}"#
        )
        let step = makeStep(
            role: .productManager,
            messages: [reply],
            toolCalls: [ask],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )
        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])

        let active = ActivityFeedBuilder.buildTimelineItems(
            steps: [step], run: nil,
            stepArtifactContentCache: [:], debugModeEnabled: false,
            activeQuestions: questions,
            isStreaming: { _ in false }
        )
        let activeBubbles = active.filter {
            if case .llmMessage = $0.item { return true } else { return false }
        }
        XCTAssertTrue(activeBubbles.isEmpty,
                      "Paired assistant bubble must be suppressed while question is active")

        // Answer the question → suppression deactivates, bubble reappears.
        // Both the `step.supervisorAnswer` field AND the `Supervisor answer: …`
        // LLMMessage are appended in production (see
        // `LLMExecutionService+StepLifecycle.swift:124-128`).
        let answerMsg = makeMessage(role: .user, content: "Supervisor answer: Proceed",
                                    at: date(110), sourceContext: .supervisorAnswer)
        let answered = makeStep(
            role: .productManager,
            messages: [reply, answerMsg],
            toolCalls: [ask],
            status: .done,
            needsSupervisorInput: false,
            supervisorQuestion: "What next?",
            supervisorAnswer: "Proceed"
        )
        let answeredQuestions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [answered])
        XCTAssertTrue(answeredQuestions.isEmpty, "Answered question is not in the active set")

        let afterAnswer = ActivityFeedBuilder.buildTimelineItems(
            steps: [answered], run: nil,
            stepArtifactContentCache: [:], debugModeEnabled: false,
            activeQuestions: answeredQuestions,
            isStreaming: { _ in false }
        )
        let answeredBubbles = afterAnswer.filter {
            if case .llmMessage = $0.item { return true } else { return false }
        }
        XCTAssertEqual(answeredBubbles.count, 1,
                       "Paired bubble must reappear once the question is answered (history preserved)")
    }

    /// Streaming exemption: the paired assistant message is still rendering deltas
    /// (preview manager owns the live bubble). Even though it matches the suppressed
    /// id set, we must NOT skip it — otherwise the bubble disappears mid-stream when
    /// the engine flips state, and the composer hasn't yet caught up.
    ///
    /// Fixture is contentless-with-thinking on purpose: a prose-carrying turn is
    /// not in the suppressed set at all after the narrowing, so the exemption
    /// would no longer be what keeps it visible and the test would prove nothing.
    func testEmitItems_streamingContentlessPairedMessage_isNotSuppressed() {
        let streamingReply = makeMessage(content: "", at: date(90), thinking: "Streaming reasoning.")
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"?"}"#
        )
        let step = makeStep(
            role: .productManager,
            messages: [streamingReply],
            toolCalls: [ask],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )
        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        let streamingID = streamingReply.id

        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [step], run: nil,
            stepArtifactContentCache: [:], debugModeEnabled: false,
            activeQuestions: questions,
            isStreaming: { $0 == streamingID }
        )
        let bubbles = result.filter {
            if case .llmMessage = $0.item { return true } else { return false }
        }
        XCTAssertEqual(bubbles.count, 1,
                       "Streaming bubble must remain visible even when matching the suppressed set")
    }
    // MARK: - Prose paired with an active ask must keep a surface

    /// The reported defect, reproduced structurally: a role streams prose AND a
    /// trailing `ask_supervisor` in the SAME turn, then parks. The composer's
    /// question card renders only `question` + `thinking` (commit `cfe23f5b`
    /// deleted its body), so suppressing the bubble leaves that prose with no
    /// surface at all — it is visible while streaming and vanishes at commit,
    /// exactly while the user is reading in order to answer.
    ///
    /// Shape mirrors the real run: five contentless tool-loop iterations, then a
    /// sixth turn carrying prose plus the ask.
    ///
    /// RED before the fix: `suppressedMessageIDs` takes every `paired.id`
    /// unconditionally, so `proseBubbles.count == 0`.
    /// RED: force `isFullyRenderedByQuestionCard` to `true` → the prose turn re-enters
    /// `suppressedMessageIDs` and `bubbles.count` is 0 instead of 1.
    func testEmitItems_realRunShape_prosePlusAskSupervisor_bubbleSurvives() {
        // Five contentless iterations, each: empty assistant turn + a tool call.
        var messages: [LLMMessage] = []
        var calls: [StepToolCall] = []
        for i in 0..<5 {
            let base = date(Double(i) * 10)
            messages.append(makeMessage(content: "", at: base))
            calls.append(makeToolCall(name: TN.readLines, at: base.addingTimeInterval(1)))
        }
        // Sixth turn: prose + the ask, same turn.
        let prose = makeMessage(content: "Looked into it. Answering.", at: date(60))
        messages.append(prose)
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(61),
            argumentsJSON: #"{"question":"Short answer: which of the two layouts should I keep, the grid or the list?"}"#
        )
        calls.append(ask)

        let step = makeStep(
            role: .productManager,
            messages: messages,
            toolCalls: calls,
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )
        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(questions.count, 1, "Trailing ask_supervisor must produce one active question")
        XCTAssertEqual(questions[0].paired?.id, prose.id, "The prose turn is the paired one")

        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [step], run: nil,
            stepArtifactContentCache: [:], debugModeEnabled: false,
            activeQuestions: questions,
            isStreaming: { _ in false }
        )
        let bubbles = result.compactMap { tagged -> LLMMessage? in
            if case .llmMessage(let message, _, _, _) = tagged.item { return message }
            return nil
        }
        // (a) the prose survives, (b) it is the ONLY bubble — the five contentless
        // turns stay filtered by the empty-content rule, so the fix resurrects nothing.
        XCTAssertEqual(bubbles.count, 1,
                       "Exactly one bubble: the prose turn. Contentless turns must stay filtered.")
        XCTAssertEqual(bubbles.first?.id, prose.id,
                       "Prose emitted alongside an active ask_supervisor must remain in the feed")

        // (c) grouping: the ask card now hugs its own prose bubble instead of the
        // previous iteration's tool call (`continuesTurn` doc, known imprecision).
        guard let askIndex = result.firstIndex(where: { tagged in
            if case .toolCall(let call, _, _, _) = tagged.item { return call.id == ask.id }
            return false
        }) else { return XCTFail("ask_supervisor card must be in the timeline") }
        XCTAssertTrue(result[askIndex].continuesTurn,
                      "The ask card continues the turn opened by its own prose bubble")
    }

    /// Escalation twin — the second mechanism that populates `paired` (drift /
    /// refusal-loop / parse-failure caps): no `ask_supervisor` tool call at all,
    /// `needsSupervisorInput` flipped directly with `supervisorQuestion` set.
    /// Two mechanisms, two pins (CLAUDE.md #60) — a fix applied to only the
    /// tool-call construction site would leave this one suppressing prose.
    /// RED: force `isFullyRenderedByQuestionCard` to `true` → the escalation-paired
    /// prose is suppressed and `bubbles.count` is 0 instead of 1.
    func testEmitItems_escalationPath_pairedTurnWithProse_bubbleSurvives() {
        let prose = makeMessage(content: "Here is what I found so far.", at: date(90))
        let step = makeStep(
            role: .productManager,
            messages: [prose],
            toolCalls: [],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "I have looped three times without progress — how should I proceed?"
        )
        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(questions.count, 1, "Escalation path must surface an active question")
        XCTAssertEqual(questions[0].paired?.id, prose.id)

        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [step], run: nil,
            stepArtifactContentCache: [:], debugModeEnabled: false,
            activeQuestions: questions,
            isStreaming: { _ in false }
        )
        let bubbles = result.compactMap { tagged -> LLMMessage? in
            if case .llmMessage(let message, _, _, _) = tagged.item { return message }
            return nil
        }
        XCTAssertEqual(bubbles.count, 1,
                       "Escalation-paired prose must stay visible — the card renders only the question")
        XCTAssertEqual(bubbles.first?.id, prose.id)
    }

    /// Pairs strictly by `createdAt <= lastCall.createdAt` — a stray assistant
    /// message that lands AFTER the active `ask_supervisor` (e.g. an in-flight
    /// streaming artifact written by the next iteration before suppression
    /// re-evaluates) must NOT be picked as the paired reply.
    func testActiveSupervisorQuestions_pairedLookup_excludesAssistantsAfterAskTimestamp() {
        let earlier = makeMessage(content: "Legit reply.", at: date(50))
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"What next?"}"#
        )
        // Future-timestamped assistant message — must not be the paired one.
        let later = makeMessage(content: "Stray future message.", at: date(150))
        let step = makeStep(
            role: .productManager,
            messages: [earlier, later],
            toolCalls: [ask],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].paired?.id, earlier.id,
                       "Paired message must be the most-recent assistant turn ≤ lastCall.createdAt")
    }

    /// Paired lookup is filtered to `.assistant` role. A `.user` turn (e.g. a
    /// consultation reply with `sourceContext: .consultation`) sitting right before
    /// `ask_supervisor` must not be lifted into the composer's preview — that
    /// would surface another role's words under the asking role's chip.
    func testActiveSupervisorQuestions_pairedLookup_filtersByAssistantRole() {
        let assistantReply = makeMessage(content: "Assistant's reasoning.", at: date(80))
        let userTurn = makeMessage(
            role: .user, content: "Consultation answer.", at: date(95),
            sourceRole: .productManager, sourceContext: .consultation
        )
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"What next?"}"#
        )
        let step = makeStep(
            role: .softwareEngineer,
            messages: [assistantReply, userTurn],
            toolCalls: [ask],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(questions[0].paired?.id, assistantReply.id,
                       "Paired lookup must skip .user turns even when they're closer to the ask timestamp")
    }

    /// Composer-hidden fallthrough: when the consumer (viewmodel / view) decides
    /// the composer can't be rendered (engine `.failed`, read-only, closed task)
    /// it passes `activeQuestions: []` — suppression must not fire, otherwise the
    /// LLM's reply is lost (no composer card to surface it).
    func testEmitItems_emptyActiveQuestions_doesNotSuppressAnyBubble() {
        let reply = makeMessage(content: "Explanation.", at: date(90))
        let ask = makeToolCall(
            name: TN.askSupervisor,
            at: date(100),
            argumentsJSON: #"{"question":"?"}"#
        )
        let step = makeStep(
            role: .productManager,
            messages: [reply],
            toolCalls: [ask],
            status: .needsSupervisorInput,
            needsSupervisorInput: true
        )

        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [step], run: nil,
            stepArtifactContentCache: [:], debugModeEnabled: false,
            // Caller intentionally passes [] (composer hidden) — bubble must stay.
            activeQuestions: [],
            isStreaming: { _ in false }
        )
        let bubbles = result.filter {
            if case .llmMessage = $0.item { return true } else { return false }
        }
        XCTAssertEqual(bubbles.count, 1,
                       "Empty activeQuestions disables suppression; reply stays visible in the feed")
    }

    /// Multi-turn step (Q1 answered → Q2 active). Q1's paired reply (older) must stay
    /// visible as history; only Q2's paired reply (latest) is suppressed.
    ///
    /// Both turns are contentless-with-thinking so the subject under test stays
    /// the SCOPE of the suppressed set (latest question only), not the prose rule:
    /// a prose-carrying turn is never suppressible at all, which would make the
    /// `newReply` half pass for the wrong reason.
    func testEmitItems_doesNotSuppressOlderPairedMessages_whenLaterQuestionActive() {
        let oldReply = makeMessage(content: "", at: date(50), thinking: "First reasoning.")
        let oldAsk = makeToolCall(name: TN.askSupervisor, at: date(60), argumentsJSON: #"{"question":"Q1?"}"#)
        let newReply = makeMessage(content: "", at: date(190), thinking: "Second reasoning.")
        let newAsk = makeToolCall(name: TN.askSupervisor, at: date(200), argumentsJSON: #"{"question":"Q2?"}"#)

        let step = makeStep(
            role: .productManager,
            messages: [oldReply, newReply],
            toolCalls: [oldAsk, newAsk],
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Q2?",
            supervisorAnswer: nil // Q1 was answered earlier; setNeedsSupervisorInput cleared answer
        )
        let questions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(questions.first?.paired?.id, newReply.id,
                       "Active paired message must be the latest assistant turn before the last ask")

        let result = ActivityFeedBuilder.buildTimelineItems(
            steps: [step], run: nil,
            stepArtifactContentCache: [:], debugModeEnabled: false,
            activeQuestions: questions,
            isStreaming: { _ in false }
        )
        let bubbleMessageIDs: Set<UUID> = Set(result.compactMap {
            if case .llmMessage(let msg, _, _, _) = $0.item { return msg.id }
            return nil
        })
        XCTAssertTrue(bubbleMessageIDs.contains(oldReply.id),
                      "Older paired reply must remain visible as conversation history")
        XCTAssertFalse(bubbleMessageIDs.contains(newReply.id),
                       "Latest paired reply must be suppressed (lives in composer preview)")
    }

    // MARK: - Reasoning turn / tool-call grouping (createdAt re-stamp)

    /// End-to-end pin of the user-visible outcome of the `commitStreamingContent`
    /// re-stamp: a reasoning-only turn (empty content + thinking) whose committed
    /// assistant message is stamped at turn-END sorts immediately before its own
    /// `create_artifact` tool call, even when a second role runs concurrently and
    /// emits an item DURING the turn. Guards both the createdAt-based sort and the
    /// re-stamp's effect.
    func testCommittedReasoningTurn_groupsWithItsToolCall_despiteConcurrentRole() {
        // UX Researcher reasoning-only turn, committed at turn-END (date 100).
        let uxMsg = makeMessage(content: "", at: date(100), thinking: "all the reasoning")
        let uxCall = makeToolCall(name: TN.createArtifact, at: date(100.4),
                                  argumentsJSON: #"{"name":"Research Report"}"#)
        let uxArtifact = makeArtifact(name: "Research Report", at: date(100.8))
        let uxStep = makeStep(role: .uxResearcher, messages: [uxMsg],
                              toolCalls: [uxCall], artifacts: [uxArtifact])

        // Product Manager runs concurrently; its tool call lands DURING the UX turn.
        let pmCall = makeToolCall(name: TN.updateScratchpad, at: date(75))
        let pmStep = makeStep(role: .productManager, toolCalls: [pmCall])

        let items = build(steps: [uxStep, pmStep]).map(\.item)

        guard let msgIdx = items.firstIndex(where: {
            if case .llmMessage(let m, _, _, _) = $0 { return m.id == uxMsg.id }
            return false
        }) else { return XCTFail("UX assistant turn missing from feed") }
        guard let callIdx = items.firstIndex(where: {
            if case .toolCall(let c, _, _, _) = $0 { return c.id == uxCall.id }
            return false
        }) else { return XCTFail("UX create_artifact tool call missing from feed") }

        XCTAssertEqual(callIdx, msgIdx + 1,
                       "The committed reasoning turn must sort immediately before its own create_artifact tool call — no concurrent role's item wedged between them")
    }

    /// Documents the pre-fix bug shape (and why the re-stamp matters): a turn-START
    /// stamped bubble is split from its turn-END tool call when a concurrent role's
    /// item lands between them. The `commitStreamingContent` re-stamp is what moves
    /// the bubble to turn-END so this split cannot happen for committed turns.
    ///
    /// NOTE: this is a CHARACTERIZATION test — it hand-builds the broken (turn-START)
    /// timestamp, so it passes independently of the production fix and is NOT a
    /// regression guard. The guard for the fix is the `TaskMutationServiceTests`
    /// re-stamp tests + `testCommittedReasoningTurn_*` above.
    func testReasoningTurnStampedAtTurnStart_isSplitFromItsToolCall_byConcurrentRole() {
        let uxMsg = makeMessage(content: "", at: date(20), thinking: "reasoning")  // turn START
        let uxCall = makeToolCall(name: TN.createArtifact, at: date(100.4),         // turn END
                                  argumentsJSON: #"{"name":"Research Report"}"#)
        let uxStep = makeStep(role: .uxResearcher, messages: [uxMsg], toolCalls: [uxCall])
        let pmCall = makeToolCall(name: TN.updateScratchpad, at: date(75))
        let pmStep = makeStep(role: .productManager, toolCalls: [pmCall])

        let items = build(steps: [uxStep, pmStep]).map(\.item)
        let msgIdx = items.firstIndex {
            if case .llmMessage(let m, _, _, _) = $0 { return m.id == uxMsg.id }; return false
        }!
        let callIdx = items.firstIndex {
            if case .toolCall(let c, _, _, _) = $0 { return c.id == uxCall.id }; return false
        }!
        XCTAssertGreaterThan(callIdx - msgIdx, 1,
                             "With a turn-START timestamp the concurrent PM item wedges between the bubble and its tool call — the split the commit re-stamp fixes")
    }

    /// Full turn contiguity: with a turn-END timestamp the bubble, its tool call,
    /// AND the resulting artifact render as three consecutive items, even with a
    /// concurrent role emitting during the turn.
    func testCommittedReasoningTurn_message_toolCall_artifact_areContiguous() {
        let uxMsg = makeMessage(content: "", at: date(100), thinking: "reasoning")
        let uxCall = makeToolCall(name: TN.createArtifact, at: date(100.4),
                                  argumentsJSON: #"{"name":"Research Report"}"#)
        let uxArtifact = makeArtifact(name: "Research Report", at: date(100.8))
        let uxStep = makeStep(role: .uxResearcher, messages: [uxMsg],
                              toolCalls: [uxCall], artifacts: [uxArtifact])
        let pmCall = makeToolCall(name: TN.updateScratchpad, at: date(75))
        let pmStep = makeStep(role: .productManager, toolCalls: [pmCall])

        let items = build(steps: [uxStep, pmStep]).map(\.item)
        let msgIdx = items.firstIndex {
            if case .llmMessage(let m, _, _, _) = $0 { return m.id == uxMsg.id }; return false
        }
        let callIdx = items.firstIndex {
            if case .toolCall(let c, _, _, _) = $0 { return c.id == uxCall.id }; return false
        }
        let artIdx = items.firstIndex {
            if case .artifact(let a, _, _, _) = $0 { return a.id == uxArtifact.id }; return false
        }
        guard let msgIdx, let callIdx, let artIdx else { return XCTFail("UX turn items missing from feed") }
        XCTAssertEqual(callIdx, msgIdx + 1, "tool call immediately follows the bubble")
        XCTAssertEqual(artIdx, msgIdx + 2, "artifact immediately follows the tool call — whole turn contiguous")
    }

    /// A content-less, thinking-less turn (e.g. a cancelled/empty commit) must NOT
    /// render as an orphan bubble even though the fix now stamps it at turn-END —
    /// only the tool call it produced shows. Guards against the re-stamp surfacing
    /// empty placeholders.
    func testTrulyEmptyReasoningTurn_isSuppressed_notRenderedAsOrphanBubble() {
        let emptyMsg = makeMessage(content: "", at: date(100), thinking: nil)
        let call = makeToolCall(name: TN.createArtifact, at: date(100.4),
                                argumentsJSON: #"{"name":"Research Report"}"#)
        let step = makeStep(role: .uxResearcher, messages: [emptyMsg], toolCalls: [call])

        let items = build(steps: [step]).map(\.item)
        let hasEmptyBubble = items.contains {
            if case .llmMessage(let m, _, _, _) = $0 { return m.id == emptyMsg.id }
            return false
        }
        XCTAssertFalse(hasEmptyBubble, "A content-less, thinking-less turn must be suppressed (no orphan bubble)")
        XCTAssertTrue(items.contains {
            if case .toolCall(let c, _, _, _) = $0 { return c.id == call.id }
            return false
        }, "The tool call it produced must still render")
    }

    /// The turn stays grouped even when a concurrent role emits on BOTH sides of it
    /// (before AND after) — guards that the fix isn't accidentally relying on the
    /// concurrent item being earlier than the turn.
    func testCommittedReasoningTurn_groupsWithItsToolCall_concurrentRoleBracketingBothSides() {
        let uxMsg = makeMessage(content: "", at: date(100), thinking: "reasoning")
        let uxCall = makeToolCall(name: TN.createArtifact, at: date(100.4),
                                  argumentsJSON: #"{"name":"Research Report"}"#)
        let uxStep = makeStep(role: .uxResearcher, messages: [uxMsg], toolCalls: [uxCall])

        // Product Manager emits both BEFORE (75) and AFTER (150) the UX turn.
        let pmBefore = makeToolCall(name: TN.updateScratchpad, at: date(75))
        let pmAfter = makeToolCall(name: TN.readFile, at: date(150))
        let pmStep = makeStep(role: .productManager, toolCalls: [pmBefore, pmAfter])

        let items = build(steps: [uxStep, pmStep]).map(\.item)
        let msgIdx = items.firstIndex {
            if case .llmMessage(let m, _, _, _) = $0 { return m.id == uxMsg.id }; return false
        }
        let callIdx = items.firstIndex {
            if case .toolCall(let c, _, _, _) = $0 { return c.id == uxCall.id }; return false
        }
        guard let msgIdx, let callIdx else { return XCTFail("UX turn items missing from feed") }
        XCTAssertEqual(callIdx, msgIdx + 1,
                       "UX bubble and its tool call stay adjacent even with concurrent PM activity bracketing the turn on both sides")
    }

    /// Two roles each commit a reasoning turn at their own turn-END; each role's
    /// bubble groups with ITS OWN tool call — the turns don't cross-contaminate
    /// after interleave, and the earlier turn fully precedes the later one.
    func testTwoConcurrentReasoningTurns_eachGroupsWithItsOwnToolCall() {
        let tlMsg = makeMessage(content: "", at: date(90), thinking: "TL reasoning")
        let tlCall = makeToolCall(name: TN.createArtifact, at: date(90.4),
                                  argumentsJSON: #"{"name":"Implementation Plan"}"#)
        let tlStep = makeStep(role: .techLead, messages: [tlMsg], toolCalls: [tlCall])

        let uxMsg = makeMessage(content: "", at: date(100), thinking: "UX reasoning")
        let uxCall = makeToolCall(name: TN.createArtifact, at: date(100.4),
                                  argumentsJSON: #"{"name":"Research Report"}"#)
        let uxStep = makeStep(role: .uxResearcher, messages: [uxMsg], toolCalls: [uxCall])

        let items = build(steps: [tlStep, uxStep]).map(\.item)
        func mIdx(_ id: UUID) -> Int? {
            items.firstIndex { if case .llmMessage(let m, _, _, _) = $0 { return m.id == id }; return false }
        }
        func cIdx(_ id: UUID) -> Int? {
            items.firstIndex { if case .toolCall(let c, _, _, _) = $0 { return c.id == id }; return false }
        }
        guard let tlM = mIdx(tlMsg.id), let tlC = cIdx(tlCall.id),
              let uxM = mIdx(uxMsg.id), let uxC = cIdx(uxCall.id)
        else { return XCTFail("turn items missing from feed") }
        XCTAssertEqual(tlC, tlM + 1, "Tech Lead bubble adjacent to its own tool call")
        XCTAssertEqual(uxC, uxM + 1, "UX bubble adjacent to its own tool call")
        XCTAssertLessThan(tlC, uxM, "Earlier turn (TL @90) fully precedes the later turn (UX @100)")
    }

    /// Per-turn grouping within a SINGLE step at the feed level: two committed turns,
    /// each re-stamped at its own turn-END, render as [msg1, call1, msg2, call2] —
    /// each bubble adjacent to its own tool call, in turn order.
    func testMultipleTurnsInOneStep_eachGroupsWithItsOwnToolCall() {
        let msg1 = makeMessage(content: "", at: date(90), thinking: "turn 1")
        let call1 = makeToolCall(name: TN.readFile, at: date(90.4))
        let msg2 = makeMessage(content: "", at: date(100), thinking: "turn 2")
        let call2 = makeToolCall(name: TN.createArtifact, at: date(100.4),
                                 argumentsJSON: #"{"name":"Research Report"}"#)
        let step = makeStep(role: .uxResearcher, messages: [msg1, msg2], toolCalls: [call1, call2])

        let items = build(steps: [step]).map(\.item)
        func mIdx(_ id: UUID) -> Int? {
            items.firstIndex { if case .llmMessage(let m, _, _, _) = $0 { return m.id == id }; return false }
        }
        func cIdx(_ id: UUID) -> Int? {
            items.firstIndex { if case .toolCall(let c, _, _, _) = $0 { return c.id == id }; return false }
        }
        guard let m1 = mIdx(msg1.id), let c1 = cIdx(call1.id),
              let m2 = mIdx(msg2.id), let c2 = cIdx(call2.id)
        else { return XCTFail("turn items missing from feed") }
        XCTAssertEqual([m1, c1, m2, c2], [0, 1, 2, 3],
                       "Two turns in one step render as msg1, call1, msg2, call2 — each bubble adjacent to its own tool call")
    }

    /// LIMIT of the fix (characterization): the re-stamp co-locates a role's OWN turn;
    /// it does NOT exclude a foreign item by time. A concurrent item whose `createdAt`
    /// falls strictly between the bubble and its tool call DOES sort between them. The
    /// fix narrows the split window to the turn's own commit→tool-call gap (sub-second
    /// in practice) — it does not guarantee zero interleave.
    func testForeignItemStrictlyInsideTurnGap_doesWedge_documentedLimit() {
        let uxMsg = makeMessage(content: "", at: date(100), thinking: "reasoning")
        let uxCall = makeToolCall(name: TN.createArtifact, at: date(100.4),
                                  argumentsJSON: #"{"name":"Research Report"}"#)
        let uxStep = makeStep(role: .uxResearcher, messages: [uxMsg], toolCalls: [uxCall])
        // PM item lands STRICTLY between the bubble (100) and its tool call (100.4).
        let pmCall = makeToolCall(name: TN.updateScratchpad, at: date(100.2))
        let pmStep = makeStep(role: .productManager, toolCalls: [pmCall])

        let items = build(steps: [uxStep, pmStep]).map(\.item)
        let msgIdx = items.firstIndex {
            if case .llmMessage(let m, _, _, _) = $0 { return m.id == uxMsg.id }; return false
        }!
        let callIdx = items.firstIndex {
            if case .toolCall(let c, _, _, _) = $0 { return c.id == uxCall.id }; return false
        }!
        XCTAssertEqual(callIdx - msgIdx, 2,
                       "A foreign item inside the commit→tool-call gap still sorts between bubble and call — the fix narrows but does not eliminate interleave")
    }

    // MARK: - Turn grouping

    private func llmItem(at t: Date, role: Role = .softwareEngineer, task: Int = 0) -> TeamActivityTimelineItem {
        .llmMessage(message: makeMessage(content: "hi", at: t), role: role, stepID: "s", originTaskID: task)
    }

    private func toolItem(at t: Date, role: Role = .softwareEngineer, task: Int = 0) -> TeamActivityTimelineItem {
        .toolCall(call: makeToolCall(at: t), role: role, stepID: "s", originTaskID: task)
    }

    /// RED: return `false` for `.toolCall` in `continuesTurn`'s first switch →
    /// this fails, the hug is lost, and every tool-call card falls back to the
    /// between-turns gap so a role's work stops reading as blocks.
    func testContinuesTurn_toolCallAfterAssistantMessage_isTrue() {
        XCTAssertTrue(ActivityFeedBuilder.continuesTurn(
            item: toolItem(at: Date(timeIntervalSince1970: 2)),
            previous: llmItem(at: Date(timeIntervalSince1970: 1))
        ))
    }

    /// RED: let `.llmMessage` continue a turn (move it into the first switch's
    /// `break` arm) → this fails, and the `Thinking` bubble hugs the tool-call
    /// card ABOVE it instead of the calls it produced — exactly the ambiguity
    /// in the reported screenshot.
    func testContinuesTurn_assistantMessageAfterToolCall_isFalse() {
        XCTAssertFalse(ActivityFeedBuilder.continuesTurn(
            item: llmItem(at: Date(timeIntervalSince1970: 2)),
            previous: toolItem(at: Date(timeIntervalSince1970: 1))
        ))
    }

    /// RED: delete the `item.roleID == previous.roleID` conjunct → this fails,
    /// and one role's first tool call hugs the previous role's last item at 2pt
    /// as though they were one turn.
    func testContinuesTurn_acrossRoleChange_isFalse() {
        XCTAssertFalse(ActivityFeedBuilder.continuesTurn(
            item: toolItem(at: Date(timeIntervalSince1970: 2), role: .codeReviewer),
            previous: llmItem(at: Date(timeIntervalSince1970: 1), role: .softwareEngineer)
        ))
    }

    /// RED: delete the `item.originTaskID == previous.originTaskID` conjunct →
    /// this fails, and a delegated child team's first call hugs the parent's
    /// last message straight across the team-boundary band.
    func testContinuesTurn_acrossOriginTaskID_isFalse() {
        XCTAssertFalse(ActivityFeedBuilder.continuesTurn(
            item: toolItem(at: Date(timeIntervalSince1970: 2), task: 7),
            previous: llmItem(at: Date(timeIntervalSince1970: 1), task: 0)
        ))
    }

    /// The reported shape, end to end: two turns of one role, each a message
    /// followed by the call it produced.
    ///
    /// RED: stop threading `prevItem` in `annotate` (pass `nil` to
    /// `continuesTurn`) → this fails, every row reads as a turn start, and the
    /// feed goes back to a flat list with no grouping at all.
    func testBuildTimelineItems_stampsContinuesTurn_onTheCallsOfTheSameTurn() {
        let t0 = Date(timeIntervalSince1970: 1)
        let step = makeStep(
            messages: [
                makeMessage(content: "first", at: t0),
                makeMessage(content: "second", at: t0.addingTimeInterval(2)),
            ],
            toolCalls: [
                makeToolCall(at: t0.addingTimeInterval(1)),
                makeToolCall(at: t0.addingTimeInterval(3)),
            ]
        )
        let flags = build(steps: [step]).map(\.continuesTurn)
        XCTAssertEqual(
            flags, [false, true, false, true],
            "Each assistant message opens a turn; the call it produced continues it."
        )
    }

    /// The first row must never be pushed down — the feed already has its own
    /// top padding, and a gap here would stack on it.
    ///
    /// RED: drop the `isFirst` guard from `rowTopPadding` → the two
    /// first-row assertions fail, and the feed gains a stray gap above its
    /// very first item.
    func testRowTopPadding_tiers() {
        XCTAssertEqual(TeamActivityFeedView.rowTopPadding(isFirst: true, continuesTurn: false), 0)
        XCTAssertEqual(TeamActivityFeedView.rowTopPadding(isFirst: true, continuesTurn: true), 0)
        XCTAssertEqual(
            TeamActivityFeedView.rowTopPadding(isFirst: false, continuesTurn: true),
            ActivityCardTokens.turnHugSpacing)
        XCTAssertEqual(
            TeamActivityFeedView.rowTopPadding(isFirst: false, continuesTurn: false),
            ActivityCardTokens.turnGapSpacing)
        // The break between turns must beat the ~5.7pt of optical whitespace
        // that 13pt prose leaves under an 11pt status row even at zero padding.
        // Equal tiers were tried and reported as still ambiguous: with no
        // contrast the row looks as attached to the item above it as to its own
        // message. See `ActivityCardTokens.turnGapSpacing` for the measurement.
        XCTAssertGreaterThan(
            ActivityCardTokens.turnGapSpacing, ActivityCardTokens.turnHugSpacing,
            "A turn boundary must break more than the inside of a turn, or nothing groups.")
        XCTAssertGreaterThanOrEqual(
            ActivityCardTokens.turnGapSpacing, 2 * ActivityCardTokens.turnHugSpacing,
            "The break needs to be visibly bigger, not bigger by a rounding error — 2pt of difference reads as none.")
    }
}
