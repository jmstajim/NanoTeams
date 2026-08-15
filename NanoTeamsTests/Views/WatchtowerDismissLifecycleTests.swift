import XCTest
@testable import NanoTeams

/// Tests for the Watchtower notification dismiss/undismiss lifecycle.
///
/// Covers the interaction between `dismissedNotificationIDs`, `allWatchtowerNotifications`,
/// and the stale-dismiss cleanup logic in `refreshNotifications()`.
@MainActor
final class WatchtowerDismissLifecycleTests: XCTestCase {

    var config: StoreConfiguration!

    override func setUp() async throws {
        try await super.setUp()
        config = StoreConfiguration(storage: InMemoryStorage())
    }

    override func tearDown() async throws {
        config = nil
        try await super.tearDown()
    }

    // MARK: - Dismiss / Undismiss

    func testDismissNotification_addsToSet() {
        config.dismissNotification(id: "step_1")
        XCTAssertTrue(config.dismissedNotificationIDs.contains("step_1"))
    }

    func testUndismissNotification_removesFromSet() {
        config.dismissNotification(id: "step_1")
        config.undismissNotification(id: "step_1")
        XCTAssertFalse(config.dismissedNotificationIDs.contains("step_1"))
    }

    func testUndismiss_nonexistentID_noOp() {
        config.undismissNotification(id: "nonexistent")
        XCTAssertTrue(config.dismissedNotificationIDs.isEmpty)
    }

    // MARK: - allWatchtowerNotifications

    func testSupervisorInput_appearsWhenNeedsSupervisorInput() {
        let step = makeStep(id: "step_1", needsSupervisorInput: true, question: "What next?")
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])

        let notifications = run.allWatchtowerNotifications(task: task, teamRoles: [])
        XCTAssertEqual(notifications.count, 1)
        if case .supervisorInput(let stepID, let question, _) = notifications.first {
            XCTAssertEqual(stepID, "step_1")
            XCTAssertEqual(question, "What next?")
        } else {
            XCTFail("Expected supervisorInput notification")
        }
    }

    func testSupervisorInput_hiddenWhenAnswered() {
        // Production flow: after the Supervisor answers, `setNeedsSupervisorInput`
        // sets `needsSupervisorInput = false` and the step continues. The mock
        // mirrors that resolved state (not the in-flight race window where
        // `needsSupervisorInput == true && answer != nil` — that's a transient
        // state in which the next question is now in-flight and the notification
        // SHOULD appear, which is what `stepHasActiveSupervisorInput` correctly
        // returns).
        let step = makeStep(
            id: "step_1",
            needsSupervisorInput: false,
            question: "What next?",
            answer: "Do X"
        )
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])

        let notifications = run.allWatchtowerNotifications(task: task, teamRoles: [])
        XCTAssertTrue(notifications.isEmpty, "Answered question should not generate notification")
    }

    func testSupervisorInput_reappearsAfterNewQuestion() {
        // Simulate: first question answered, then new question on same step
        let step = makeStep(
            id: "step_1",
            needsSupervisorInput: true,
            question: "New question?",
            answer: nil  // new question, answer cleared
        )
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])

        let notifications = run.allWatchtowerNotifications(task: task, teamRoles: [])
        XCTAssertEqual(notifications.count, 1)
    }

    // MARK: - bashApprovalNeeded (held command, cross-task)

    func testBashApprovalNeeded_appearsForHeldCommand() {
        // The holding step is `.running` (in-loop hold), NOT .needsSupervisorInput —
        // so only the bashApprovals param surfaces it.
        let step = makeStep(id: "step_1", needsSupervisorInput: false, question: nil)
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])   // task.id == 1
        let req = BashApprovalRequest(
            taskID: 1, stepID: "step_1", commandKey: "key", command: "rm -rf build",
            workingDirectory: nil, offerAlways: true, createdAt: Date(timeIntervalSince1970: 100))

        let notifications = run.allWatchtowerNotifications(task: task, teamRoles: [], bashApprovals: [req])
        XCTAssertEqual(notifications.count, 1)
        if case .bashApprovalNeeded(let stepID, let taskID, let command, let role, _) = notifications.first {
            XCTAssertEqual(stepID, "step_1")
            XCTAssertEqual(taskID, 1)
            XCTAssertEqual(command, "rm -rf build")
            XCTAssertEqual(role, .softwareEngineer, "role resolved from the holding step")
        } else {
            XCTFail("Expected bashApprovalNeeded notification")
        }
    }

    func testBashApprovalNeeded_filtersByTaskID() {
        let step = makeStep(id: "step_1", needsSupervisorInput: false, question: nil)
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])   // id 1
        let req = BashApprovalRequest(
            taskID: 999, stepID: "step_1", commandKey: "key", command: "ls",
            workingDirectory: nil, offerAlways: false, createdAt: Date(timeIntervalSince1970: 1))
        let notifications = run.allWatchtowerNotifications(task: task, teamRoles: [], bashApprovals: [req])
        XCTAssertTrue(notifications.isEmpty, "a request for a different task must not surface here")
    }

    func testBashApprovalNeeded_noApprovals_noNotification() {
        let step = makeStep(id: "step_1", needsSupervisorInput: false, question: nil)
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])
        XCTAssertTrue(run.allWatchtowerNotifications(task: task, teamRoles: []).isEmpty,
                      "default empty bashApprovals ⇒ no bash notification")
    }

    // MARK: - timedOut visibility

    private func containsTimedOut(_ notifications: [WatchtowerNotificationType]) -> Bool {
        notifications.contains { if case .timedOut = $0 { return true } else { return false } }
    }

    func testTimedOut_appearsWhenRunPausedAndStamped() {
        var run = makeRun(steps: [StepExecution(id: "a", role: .softwareEngineer, title: "S", status: .paused)])
        run.timedOutAt = Date()
        let task = makeTask(runs: [run])
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused, "sanity: paused step → paused task")
        XCTAssertTrue(containsTimedOut(run.allWatchtowerNotifications(task: task, teamRoles: [])),
                      "timed-out banner shows while the run is paused-by-timeout")
    }

    func testTimedOut_hiddenWhenRunResumed() {
        var run = makeRun(steps: [StepExecution(id: "a", role: .softwareEngineer, title: "S", status: .running)])
        run.timedOutAt = Date()
        let task = makeTask(runs: [run])
        XCTAssertFalse(containsTimedOut(run.allWatchtowerNotifications(task: task, teamRoles: [])),
                       "once resumed (running again), the timed-out banner clears")
    }

    func testTimedOut_hiddenWhenNoStamp() {
        let run = makeRun(steps: [StepExecution(id: "a", role: .softwareEngineer, title: "S", status: .paused)])
        let task = makeTask(runs: [run])
        XCTAssertFalse(containsTimedOut(run.allWatchtowerNotifications(task: task, teamRoles: [])),
                       "a plain paused run (no timeout) shows no timed-out banner")
    }

    // MARK: - Dismiss Lifecycle (simulates refreshNotifications logic)

    func testDismissedStep_filteredFromDisplay() {
        let step = makeStep(id: "step_1", needsSupervisorInput: true, question: "Q?")
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])

        let all = run.allWatchtowerNotifications(task: task, teamRoles: [])
        // Dismiss using the actual dismissID (which now includes the question
        // text as a multi-round disambiguator).
        config.dismissNotification(id: all[0].dismissID)

        let visible = all.filter { !config.dismissedNotificationIDs.contains($0.dismissID) }
        XCTAssertTrue(visible.isEmpty, "Dismissed notification should not be visible")
    }

    func testStaleCleanup_undismissesAnsweredStep() {
        // Step was dismissed (user answered), then step is no longer needsSupervisorInput
        config.dismissNotification(id: "step_1")

        let step = makeStep(id: "step_1", needsSupervisorInput: false, question: nil)
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])

        // Simulate refreshNotifications cleanup
        let all = run.allWatchtowerNotifications(task: task, teamRoles: [])
        let activeIDs = Set(all.map(\.dismissID))

        for id in config.dismissedNotificationIDs where !activeIDs.contains(id) {
            config.undismissNotification(id: id)
        }

        XCTAssertFalse(config.dismissedNotificationIDs.contains("step_1"),
                        "Stale dismiss should be cleared when step no longer has active notification")
    }

    func testStaleCleanup_preservesDismissForActiveStep() {
        // Step is dismissed via X button, but step still has active question
        let step = makeStep(id: "step_1", needsSupervisorInput: true, question: "Q?")
        let run = makeRun(steps: [step])
        let task = makeTask(runs: [run])

        let all = run.allWatchtowerNotifications(task: task, teamRoles: [])
        let dismissID = all[0].dismissID
        config.dismissNotification(id: dismissID)

        let activeIDs = Set(all.map(\.dismissID))

        for id in config.dismissedNotificationIDs where !activeIDs.contains(id) {
            config.undismissNotification(id: id)
        }

        XCTAssertTrue(config.dismissedNotificationIDs.contains(dismissID),
                       "Active notification dismiss should NOT be cleared")
    }

    func testStaleCleanup_emptyTasks_preservesDismissed() {
        // Simulates app startup — no tasks loaded yet
        config.dismissNotification(id: "step_1")
        config.dismissNotification(id: "step_2")

        let allLoadedTasks: [NTMSTask] = []  // empty on startup

        // Guard: only run cleanup when tasks are loaded
        if !allLoadedTasks.isEmpty {
            // Would undismiss, but guard prevents it
            config.undismissNotification(id: "step_1")
        }

        XCTAssertEqual(config.dismissedNotificationIDs.count, 2,
                        "Dismissed IDs must survive when no tasks are loaded (app startup)")
    }

    func testFullLifecycle_answer_newQuestion_shows() {
        // 1. Question appears
        let step1 = makeStep(id: "step_1", needsSupervisorInput: true, question: "Q1?")
        var run = makeRun(steps: [step1])
        let task = makeTask(runs: [run])

        var all = run.allWatchtowerNotifications(task: task, teamRoles: [])
        XCTAssertEqual(all.count, 1, "Question should generate notification")
        let q1DismissID = all[0].dismissID

        // 2. User answers → dismiss (using the actual dismissID, which now
        //    includes the question text)
        config.dismissNotification(id: q1DismissID)
        var visible = all.filter { !config.dismissedNotificationIDs.contains($0.dismissID) }
        XCTAssertTrue(visible.isEmpty, "Answered notification should be hidden")

        // 3. Step processes answer (no longer needsSupervisorInput)
        let step2 = makeStep(id: "step_1", needsSupervisorInput: false, question: nil, answer: "A1")
        run = makeRun(steps: [step2])
        all = run.allWatchtowerNotifications(task: makeTask(runs: [run]), teamRoles: [])
        let activeIDs = Set(all.map(\.dismissID))
        for id in config.dismissedNotificationIDs where !activeIDs.contains(id) {
            config.undismissNotification(id: id)
        }
        XCTAssertFalse(config.dismissedNotificationIDs.contains(q1DismissID),
                        "Stale dismiss should be cleared")

        // 4. New question arrives on same step — new dismissID, never dismissed.
        //    Critical multi-round assertion: even if step 3's cleanup had failed
        //    to undismiss Q1's stale entry, Q2 would still surface because its
        //    dismissID differs from Q1's (different question text).
        let step3 = makeStep(id: "step_1", needsSupervisorInput: true, question: "Q2?")
        run = makeRun(steps: [step3])
        all = run.allWatchtowerNotifications(task: makeTask(runs: [run]), teamRoles: [])
        XCTAssertNotEqual(all[0].dismissID, q1DismissID, "Q2's dismissID must differ from Q1's")
        visible = all.filter { !config.dismissedNotificationIDs.contains($0.dismissID) }
        XCTAssertEqual(visible.count, 1, "New question should show (different dismissID)")
    }

    // MARK: - Multi-Round Race Regression
    //
    // Pin two invariants for the supervisor-input banner across rounds on the
    // same step: the count-based active predicate (race window where stale
    // supervisorAnswer is still present) and per-question dismissID
    // disambiguation (so dismissing Q_N doesn't suppress Q_(N+1)).

    /// Two ask_supervisor calls + one supervisorAnswer message → notification appears
    /// (the count-based predicate's `trailingUnanswered` branch).
    func testMultiRoundRace_secondQuestionUnansweredViaToolCallCount() {
        let q1 = makeAskCall(question: "Q1?")
        let q2 = makeAskCall(question: "Q2?")
        let a1 = makeAnswerMessage(text: "A1")
        let step = StepExecution(
            id: "step_1",
            role: .softwareEngineer,
            title: "Test Step",
            status: .needsSupervisorInput,
            toolCalls: [q1, a1.matchingToolCallStub, q2],  // ordering: Q1, A1 (no tool call), Q2
            needsSupervisorInput: true,
            supervisorQuestion: "Q2?",
            supervisorAnswer: "A1",  // stale — would have hidden the banner pre-fix
            llmConversation: [a1.message]
        )
        let run = makeRun(steps: [step])
        let notifications = run.allWatchtowerNotifications(task: makeTask(runs: [run]), teamRoles: [])

        XCTAssertEqual(notifications.count, 1, "Q2 must surface even with stale supervisorAnswer from A1")
        guard case .supervisorInput(let stepID, let question, _) = notifications.first else {
            return XCTFail("Expected .supervisorInput")
        }
        XCTAssertEqual(stepID, "step_1")
        XCTAssertEqual(question, "Q2?")
    }

    /// After dismissing Q1's banner (via "Open" arrow), Q2 arrives on the same step.
    /// Q2's dismissID differs from Q1's because the question text is part of dismissID,
    /// so Q2 is NOT filtered out even though dismissedNotificationIDs still contains Q1's ID.
    func testMultiRoundRace_dismissedFirstQuestion_secondQuestionStillVisible() {
        // Round 1: only Q1
        let q1Call = makeAskCall(question: "Q1?")
        let step1 = StepExecution(
            id: "step_1",
            role: .softwareEngineer,
            title: "Test",
            status: .needsSupervisorInput,
            toolCalls: [q1Call],
            needsSupervisorInput: true,
            supervisorQuestion: "Q1?"
        )
        let run1 = makeRun(steps: [step1])
        let q1Notifications = run1.allWatchtowerNotifications(task: makeTask(runs: [run1]), teamRoles: [])
        XCTAssertEqual(q1Notifications.count, 1)
        let q1DismissID = q1Notifications[0].dismissID

        // Supervisor clicks "Open" → dismissNotification(q1DismissID)
        config.dismissNotification(id: q1DismissID)

        // Round 2: Q1 + A1 + Q2 (the race window — supervisorAnswer not yet cleared
        // when setNeedsSupervisorInput runs for Q2)
        let a1 = makeAnswerMessage(text: "A1")
        let q2Call = makeAskCall(question: "Q2?")
        let step2 = StepExecution(
            id: "step_1",
            role: .softwareEngineer,
            title: "Test",
            status: .needsSupervisorInput,
            toolCalls: [q1Call, a1.matchingToolCallStub, q2Call],
            needsSupervisorInput: true,
            supervisorQuestion: "Q2?",
            supervisorAnswer: "A1",
            llmConversation: [a1.message]
        )
        let run2 = makeRun(steps: [step2])
        let q2Notifications = run2.allWatchtowerNotifications(task: makeTask(runs: [run2]), teamRoles: [])

        // Critical: Q2 surfaces despite Q1's dismiss still being in the set.
        let visible = q2Notifications.filter { !config.dismissedNotificationIDs.contains($0.dismissID) }
        XCTAssertEqual(visible.count, 1, "Q2 must appear; stale Q1 dismiss must not suppress it")
        XCTAssertNotEqual(visible[0].dismissID, q1DismissID, "Q2's dismissID must differ")
    }

    /// Cross-surface invariant: `Run.allWatchtowerNotifications` and
    /// `ActivityFeedBuilder.stepHasActiveSupervisorInput` must agree on activeness
    /// for the same step. The two surfaces (Watchtower banners, activity feed
    /// composer chips) share one predicate so they can't drift.
    func testWatchtowerPredicate_consistentWithActivityFeedBuilder() {
        let cases: [(label: String, step: StepExecution, expectedActive: Bool)] = [
            ("idle flag only",
             makeStep(id: "s1", needsSupervisorInput: true, question: "Q?"),
             true),
            ("answered, flag cleared",
             makeStep(id: "s2", needsSupervisorInput: false, question: nil, answer: "A"),
             false),
            ("multi-round race",
             {
                 let q1 = makeAskCall(question: "Q1?")
                 let a1 = makeAnswerMessage(text: "A1")
                 let q2 = makeAskCall(question: "Q2?")
                 return StepExecution(
                     id: "s3", role: .softwareEngineer, title: "T",
                     status: .needsSupervisorInput,
                     toolCalls: [q1, a1.matchingToolCallStub, q2],
                     needsSupervisorInput: true,
                     supervisorQuestion: "Q2?",
                     supervisorAnswer: "A1",
                     llmConversation: [a1.message]
                 )
             }(),
             true),
            // Predicate active via trailingUnanswered + supervisorQuestion lag.
            // Watchtower must STILL surface the banner using the fallback that
            // parses the trailing ask call's args. Without that fallback Watchtower
            // silently skips and the user has no feedback.
            ("predicate active, supervisorQuestion nil — fallback parsing",
             {
                 let q1 = makeAskCall(question: "Q1?")
                 let a1 = makeAnswerMessage(text: "A1")
                 let q2 = makeAskCall(question: "Lagged Q2?")
                 return StepExecution(
                     id: "s4", role: .softwareEngineer, title: "T",
                     status: .running,
                     toolCalls: [q1, a1.matchingToolCallStub, q2],
                     needsSupervisorInput: false,  // lag: flag not yet set
                     supervisorQuestion: nil,      // lag: text not yet copied
                     llmConversation: [a1.message]
                 )
             }(),
             true)
        ]

        for testCase in cases {
            let run = makeRun(steps: [testCase.step])
            let watchtowerActive = !run.allWatchtowerNotifications(task: makeTask(runs: [run]), teamRoles: []).isEmpty
            let feedActive = ActivityFeedBuilder.stepHasActiveSupervisorInput(testCase.step)
            XCTAssertEqual(feedActive, testCase.expectedActive,
                           "Feed predicate disagreement (\(testCase.label))")
            XCTAssertEqual(watchtowerActive, testCase.expectedActive,
                           "Watchtower predicate disagreement (\(testCase.label))")
        }
    }

    /// Gap-window invariant: after the user answers via
    /// `StepMessagingService.answerSupervisorQuestion`, the count-based active
    /// predicate must return false immediately — not after the engine resumes
    /// and runStep continuation appends `.supervisorAnswer` to llmConversation.
    /// Pre-fix the answer message was appended later in `+StepLifecycle`, so
    /// for one event-loop tick the predicate saw `askCalls.count > answerMessages.count`
    /// and re-surfaced the banner the user had just dismissed.
    func testStepMessagingService_answerAppendsLLMMessageAtomically() {
        let q1Call = makeAskCall(question: "Q1?")
        var task = NTMSTask(
            id: 1, title: "Test", supervisorTask: "Do something",
            runs: [
                {
                    var run = Run(id: 0, teamID: "test_team")
                    run.steps = [
                        StepExecution(
                            id: "step_1", role: .softwareEngineer, title: "T",
                            status: .needsSupervisorInput,
                            toolCalls: [q1Call],
                            needsSupervisorInput: true,
                            supervisorQuestion: "Q1?"
                        )
                    ]
                    return run
                }()
            ]
        )

        // Pre-condition: predicate active (Q1 unanswered)
        XCTAssertTrue(
            ActivityFeedBuilder.stepHasActiveSupervisorInput(task.runs[0].steps[0]),
            "Setup sanity: predicate must be active before answer"
        )

        // Apply answer
        let applied = StepMessagingService.answerSupervisorQuestion(
            stepID: "step_1", answer: "A1", in: &task
        )
        XCTAssertTrue(applied)

        // Post-condition: predicate immediately resolves without waiting for
        // engine resume or runStep continuation.
        let step = task.runs[0].steps[0]
        XCTAssertFalse(
            ActivityFeedBuilder.stepHasActiveSupervisorInput(step),
            "Predicate must resolve atomically with the answer mutation"
        )

        // Sanity: the answer message landed in llmConversation with the right
        // sourceContext so `answerMessages.count == askCalls.count`.
        let answerCount = step.llmConversation.filter { $0.sourceContext == .supervisorAnswer }.count
        XCTAssertEqual(answerCount, 1, "Exactly one .supervisorAnswer message appended")
        XCTAssertEqual(step.llmConversation.last?.content, "Supervisor answer: A1")
    }

    /// Empty-answer edge: no LLMMessage append, no `"Supervisor answer: "` noise.
    /// The `needsSupervisorInput` flag still clears so the engine doesn't deadlock,
    /// but the predicate now sees `needsSupervisorInput == false` AND a trailing
    /// ask call with no matching answer message — which the count branch counts as
    /// still-active. Edge documented; not "broken" — empty answers shouldn't reach
    /// `answerSupervisorQuestion` in production (UI gates on non-empty), and if one
    /// slips through, leaving the banner active is the safe choice.
    func testStepMessagingService_emptyAnswer_skipsLLMMessageAppend() {
        let q1Call = makeAskCall(question: "Q1?")
        var task = NTMSTask(
            id: 1, title: "Test", supervisorTask: "Do",
            runs: [{
                var run = Run(id: 0, teamID: "t")
                run.steps = [
                    StepExecution(
                        id: "step_1", role: .softwareEngineer, title: "T",
                        status: .needsSupervisorInput,
                        toolCalls: [q1Call],
                        needsSupervisorInput: true,
                        supervisorQuestion: "Q1?"
                    )
                ]
                return run
            }()]
        )

        StepMessagingService.answerSupervisorQuestion(
            stepID: "step_1", answer: "   ", in: &task
        )

        let step = task.runs[0].steps[0]
        XCTAssertNil(step.supervisorAnswer, "Whitespace-only answer normalises to nil")
        XCTAssertTrue(
            step.llmConversation.filter { $0.sourceContext == .supervisorAnswer }.isEmpty,
            "No phantom 'Supervisor answer: ' message appended"
        )
    }

    /// Identical question text across rounds collides on dismissID — current
    /// limitation of `"\(stepID)::\(question)"`. Pinned so a future change to
    /// the format (e.g. UUID-based) breaks loudly here and is reviewed.
    func testMultiRoundRace_identicalQuestionText_pinsKnownCollision() {
        let askCall = makeAskCall(question: "Continue?")
        let step1 = StepExecution(
            id: "step_1", role: .softwareEngineer, title: "T",
            status: .needsSupervisorInput,
            toolCalls: [askCall],
            needsSupervisorInput: true,
            supervisorQuestion: "Continue?"
        )
        let run1 = makeRun(steps: [step1])
        let r1Notifications = run1.allWatchtowerNotifications(task: makeTask(runs: [run1]), teamRoles: [])
        let r1DismissID = r1Notifications[0].dismissID
        config.dismissNotification(id: r1DismissID)

        // Second round, identical question text on same step.
        let askCall2 = makeAskCall(question: "Continue?")
        let answer1 = makeAnswerMessage(text: "yes")
        let step2 = StepExecution(
            id: "step_1", role: .softwareEngineer, title: "T",
            status: .needsSupervisorInput,
            toolCalls: [askCall, answer1.matchingToolCallStub, askCall2],
            needsSupervisorInput: true,
            supervisorQuestion: "Continue?",
            supervisorAnswer: "yes",
            llmConversation: [answer1.message]
        )
        let run2 = makeRun(steps: [step2])
        let r2Notifications = run2.allWatchtowerNotifications(task: makeTask(runs: [run2]), teamRoles: [])

        // Current behaviour: dismissID collides → Q2 suppressed.
        // If this assertion ever fails, the format changed to disambiguate
        // identical text — update both this test and the dismissID doc comment.
        XCTAssertEqual(r2Notifications[0].dismissID, r1DismissID,
                        "Pinning known collision: identical question text reuses dismissID")
        let visible = r2Notifications.filter { !config.dismissedNotificationIDs.contains($0.dismissID) }
        XCTAssertTrue(visible.isEmpty,
                       "Pinning known limitation: identical-text Q2 is suppressed by dismissed Q1")
    }

    // MARK: - Helpers

    private func makeStep(
        id: String,
        needsSupervisorInput: Bool,
        question: String?,
        answer: String? = nil
    ) -> StepExecution {
        StepExecution(
            id: id,
            role: .softwareEngineer,
            title: "Test Step",
            status: needsSupervisorInput ? .needsSupervisorInput : .running,
            needsSupervisorInput: needsSupervisorInput,
            supervisorQuestion: question,
            supervisorAnswer: answer
        )
    }

    private func makeAskCall(question: String) -> StepToolCall {
        StepToolCall(
            name: ToolNames.askSupervisor,
            argumentsJSON: #"{"question":"\#(question)"}"#
        )
    }

    /// Bundles a supervisor answer LLMMessage with a placeholder tool call so callers
    /// can intersperse `[Q1, A1, Q2]` ordering on `step.toolCalls`. The placeholder is
    /// a non-`ask_supervisor` call (filtered out by `askCalls`), it just preserves
    /// chronological ordering for the trailing-call check.
    private func makeAnswerMessage(text: String) -> (message: LLMMessage, matchingToolCallStub: StepToolCall) {
        let message = LLMMessage(
            role: .user,
            content: text,
            sourceRole: .supervisor,
            sourceContext: .supervisorAnswer
        )
        let stub = StepToolCall(name: "supervisor_answer_marker", argumentsJSON: "{}")
        return (message, stub)
    }

    private func makeRun(steps: [StepExecution]) -> Run {
        var run = Run(id: 0, teamID: "test_team")
        run.steps = steps
        return run
    }

    private func makeTask(runs: [Run]) -> NTMSTask {
        NTMSTask(id: 1, title: "Test Task", supervisorTask: "Do something", runs: runs)
    }
}

// MARK: - In-Memory Storage

private final class InMemoryStorage: ConfigurationStorage {
    private var store: [String: Any] = [:]

    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
}
