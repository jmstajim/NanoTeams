import XCTest
@testable import NanoTeams

/// Tests for `ActivityFeedBuilder.buildTimelineItems()` — ordering, interleaving,
/// notification pinning, section headers, and filtering correctness.
@MainActor
final class ActivityFeedBuilderTests: XCTestCase {

    private typealias TN = ToolNames

    override func setUp() {
        super.setUp()
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

        if case .llmMessage(let msg, _, _) = result[0].item { XCTAssertEqual(msg.content, "First") }
        else { XCTFail("Expected llmMessage at index 0") }
        if case .llmMessage(let msg, _, _) = result[1].item { XCTAssertEqual(msg.content, "Second") }
        else { XCTFail("Expected llmMessage at index 1") }
        if case .llmMessage(let msg, _, _) = result[2].item { XCTAssertEqual(msg.content, "Third") }
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

        if case .llmMessage(let msg, let role, _) = result[0].item {
            XCTAssertEqual(msg.content, "PM first")
            XCTAssertEqual(role, .productManager)
        } else { XCTFail("Expected PM message at 0") }

        if case .llmMessage(let msg, let role, _) = result[1].item {
            XCTAssertEqual(msg.content, "SWE second")
            XCTAssertEqual(role, .softwareEngineer)
        } else { XCTFail("Expected SWE message at 1") }

        if case .llmMessage(let msg, let role, _) = result[2].item {
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

        if case .toolCall(_, let role, _) = result[0].item { XCTAssertEqual(role, .productManager) }
        else { XCTFail("Expected PM toolCall at 0") }
        if case .llmMessage(_, let role, _) = result[1].item { XCTAssertEqual(role, .softwareEngineer) }
        else { XCTFail("Expected SWE message at 1") }
        if case .toolCall(_, let role, _) = result[2].item { XCTAssertEqual(role, .softwareEngineer) }
        else { XCTFail("Expected SWE toolCall at 2") }
        if case .artifact(_, let role, _) = result[3].item { XCTAssertEqual(role, .productManager) }
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
            if case .llmMessage(let msg, _, _) = item.item { return msg.content }
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

        if case .llmMessage(let msg, _, _) = result[0].item { XCTAssertEqual(msg.content, "Before") }
        else { XCTFail("Expected llmMessage at 0") }
        if case .meetingMessage(let msg, _) = result[1].item { XCTAssertEqual(msg.content, "Meeting msg") }
        else { XCTFail("Expected meetingMessage at 1") }
        if case .llmMessage(let msg, _, _) = result[2].item { XCTAssertEqual(msg.content, "After") }
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

        if case .meetingMessage(let msg, _) = result[0].item { XCTAssertEqual(msg.content, "First") }
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
            if case .meetingMessage(let msg, _) = item.item { return msg.content }
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
            if case .notification(_, _, .supervisorInput, _) = $0.item { return true }
            return false
        }
        XCTAssertEqual(notifications.count, 0, "Active notifications should be excluded from timeline")
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
            if case .notification(_, _, .supervisorInput, _) = $0.item { return true }
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
            if case .notification(_, _, .supervisorInput, _) = $0.item { return true }
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
            if case .notification(_, _, .supervisorInput, _) = $0.item { return true }
            return false
        }
        // Only answered notification in timeline; active excluded
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications[0].item.createdAt, date(150), "Answered notification at answer timestamp")
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

        // Answered step — should NOT appear in active questions
        let ask3 = makeToolCall(name: TN.askSupervisor, at: date(300), argumentsJSON: #"{"question":"Q3?"}"#)
        let step3 = makeStep(
            role: .softwareEngineer,
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
            if case .notification(_, _, .failed, _) = $0.item { return true }
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
            if case .notification(_, _, .failed, _) = $0.item { return true }
            return false
        }
        XCTAssertNotNil(notif)
        XCTAssertEqual(notif?.item.createdAt, date(350))
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
            if case .notification(_, _, .supervisorInput, _) = $0.item { return true }
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

        if case .llmMessage(let msg, _, _) = result[0].item { XCTAssertEqual(msg.content, "Visible") }
        else { XCTFail("Expected Visible at 0") }
        if case .llmMessage(let msg, _, _) = result[1].item { XCTAssertEqual(msg.content, "Also visible") }
        else { XCTFail("Expected Also visible at 1") }
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
            if case .llmMessage(let msg, _, _) = item.item { return msg.content }
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
        // Empty streaming message should be kept
        XCTAssertEqual(result.count, 3)
        assertOrdered(result)
    }

    func testStreamingMessagePositionedByTimestamp() {
        let streamingMsgID = UUID()
        let step = makeStep(messages: [
            makeMessage(content: "First", at: date(100)),
            makeMessage(content: "Third", at: date(300)),
            LLMMessage(id: streamingMsgID, createdAt: date(200), role: .assistant, content: "Streaming")
        ])
        let result = build(steps: [step]) { id in id == streamingMsgID }
        XCTAssertEqual(result.count, 3)
        assertOrdered(result)

        if case .llmMessage(let msg, _, _) = result[1].item {
            XCTAssertEqual(msg.content, "Streaming")
        } else { XCTFail("Expected streaming message at position 1") }
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
        if case .llmMessage(_, let role, _) = result[1].item {
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
        if case .llmMessage(let msg, _, _) = result[1].item {
            XCTAssertEqual(msg.content, "After meeting")
        } else { XCTFail("Expected 'After meeting' at 1") }

        if case .llmMessage(let msg, let role, _) = result[2].item {
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

        if case .supervisorTask(let brief, let taskDate, _, _, _, _) = result[0].item {
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
        XCTAssertEqual(item.id, "supervisor-task")
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
        let input = "Answer text\n\n--- Attached Files ---\n- .nanoteams/tasks/1/a.txt\n- .nanoteams/tasks/1/b.png"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer text")
        XCTAssertEqual(result.paths, [".nanoteams/tasks/1/a.txt", ".nanoteams/tasks/1/b.png"])
        XCTAssertTrue(result.clippedTexts.isEmpty)
    }

    func testStripAttachedFiles_extractsSingleClip() {
        let input = "My answer\n\n--- Clipped Text ---\nsome code snippet"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "My answer")
        XCTAssertEqual(result.clippedTexts, ["some code snippet"])
    }

    func testStripAttachedFiles_extractsNumberedClips() {
        let input = "Answer\n\n--- Clipped Text (1 of 2) ---\nclip one\n\n--- Clipped Text (2 of 2) ---\nclip two"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
        XCTAssertEqual(result.clippedTexts.count, 2)
        XCTAssertEqual(result.clippedTexts[0], "clip one")
        XCTAssertEqual(result.clippedTexts[1], "clip two")
    }

    func testStripAttachedFiles_extractsClipWithSourceContext() {
        let input = "Answer\n\n--- Clipped Text (MyFile.swift:10-20) ---\nfunc hello() { }"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
        XCTAssertEqual(result.clippedTexts, ["func hello() { }"])
    }

    func testStripAttachedFiles_extractsClipsAndFilesTogether() {
        let input = "Answer\n\n--- Clipped Text ---\nsnippet\n\n--- Attached Files ---\n- file.txt"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
        XCTAssertEqual(result.clippedTexts, ["snippet"])
        XCTAssertEqual(result.paths, ["file.txt"])
    }

    func testStripAttachedFiles_stripsEmbeddedFileContent() {
        let input = "Answer\n\n--- Attached File: data.swift ---\nlet x = 1"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
    }

    func testStripAttachedFiles_stripsEmbeddedFileWithHyphenatedName() {
        let input = "Answer\n\n--- Attached File: my-component.swift ---\nlet x = 1"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
    }

    func testStripAttachedFiles_clipsOnlyNoText_returnsEmptyText() {
        let input = "--- Clipped Text ---\nonly a clip"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.clippedTexts, ["only a clip"])
    }

    // MARK: - Regression: Issue #1 — Embedded file with hyphenated filename

    func testStripAttachedFiles_embeddedFile_multipleHyphens() {
        let input = "Answer\n\n--- Attached File: my-data-model.swift ---\nstruct Foo {}"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
        // Embedded file content must NOT leak into displayed text
        XCTAssertFalse(result.text?.contains("struct Foo") ?? false)
    }

    // MARK: - Regression: Issue #3 — Embedded file content leaks into last clip

    func testStripAttachedFiles_clipThenEmbeddedFile_noContentLeak() {
        let input = "Answer\n\n--- Clipped Text ---\nsnippet\n\n--- Attached File: data.swift ---\nlet x = 1"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
        XCTAssertEqual(result.clippedTexts.count, 1)
        XCTAssertEqual(result.clippedTexts[0], "snippet")
        // Embedded file content must NOT appear in clip text
        XCTAssertFalse(result.clippedTexts[0].contains("let x = 1"))
    }

    // MARK: - Regression: Issue #5 — Clip header with parentheses in path

    func testStripAttachedFiles_clipWithParenthesesInPath() {
        let input = "Answer\n\n--- Clipped Text (MyFile(iOS).swift:10-20) ---\nfunc run() {}"
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "Answer")
        XCTAssertEqual(result.clippedTexts, ["func run() {}"])
    }

    func testStripAttachedFiles_numberedClipWithSourceAndParentheses() {
        let input = "Answer\n\n--- Clipped Text (1 of 2, App(iOS).swift:5-10) ---\nfirst\n\n--- Clipped Text (2 of 2) ---\nsecond"
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

        --- Clipped Text (src/main.swift:1-5) ---
        import Foundation

        --- Attached File: my-helper.swift ---
        func helper() {}

        --- Attached Files ---
        - .nanoteams/tasks/1/attachments/image.png
        """
        let result = ActivityFeedBuilder.stripAttachedFiles(from: input)
        XCTAssertEqual(result.text, "My answer")
        XCTAssertEqual(result.clippedTexts.count, 1)
        XCTAssertTrue(result.clippedTexts[0].contains("import Foundation"))
        XCTAssertFalse(result.clippedTexts[0].contains("func helper"))
        XCTAssertEqual(result.paths, [".nanoteams/tasks/1/attachments/image.png"])
    }

    // MARK: - Supervisor Task Embedded Content Stripping

    func testSupervisorTask_embeddedFileContent_strippedFromDisplay() {
        let taskWithEmbed = """
        опиши логику

        --- Attached File: Логика.pdf ---
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
        if case .supervisorTask(_, _, let displayText, _, _, _) = result[0].item {
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

        --- Attached File: report.pdf ---
        Report content here

        --- Attached Files ---
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
        guard case .supervisorTask(_, _, let displayText, _, let paths, _) = result.first?.item else {
            return XCTFail("Expected supervisorTask")
        }
        XCTAssertEqual(displayText, "check this")
        XCTAssertEqual(paths, [".nanoteams/tasks/1/attachments/report.pdf"])
    }

    func testSupervisorTask_embeddedClips_extractedFromDisplay() {
        let taskWithClips = """
        do this

        --- Clipped Text ---
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
        guard case .supervisorTask(_, _, let displayText, let clips, _, _) = result.first?.item else {
            return XCTFail("Expected supervisorTask")
        }
        XCTAssertEqual(displayText, "do this")
        XCTAssertEqual(clips.count, 1)
        XCTAssertTrue(clips[0].contains("let x = 42"))
    }

    func testSupervisorTask_structuredFieldsTakePriority() {
        // When structured fields (supervisorClippedTexts, supervisorAttachmentPaths) are provided,
        // they take priority over fields extracted from the text.
        let taskWithEmbed = "task text\n\n--- Clipped Text ---\ninline clip"
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
        guard case .supervisorTask(_, _, _, let clips, let paths, _) = result.first?.item else {
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
        guard case .supervisorTask(_, _, let displayText, let clips, let paths, _) = result.first?.item else {
            return XCTFail("Expected supervisorTask")
        }
        XCTAssertEqual(displayText, "simple task description")
        XCTAssertTrue(clips.isEmpty)
        XCTAssertTrue(paths.isEmpty)
    }
}
