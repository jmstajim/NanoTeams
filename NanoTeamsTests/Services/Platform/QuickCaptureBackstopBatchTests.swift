import XCTest

@testable import NanoTeams

/// End-to-end user-path tests for the Supervisor Message Queue's backstop
/// (`.needsSupervisorInput` flush). Drives a real `NTMSOrchestrator` so the
/// full chain — `tryFlushQueuedMessages` → `flushQueuedChatMessage` →
/// `answerSupervisorQuestion` → `step.supervisorAnswer` mutation — is verified
/// against actual storage, not mocks.
///
/// The user-reported bug ("queue 8 messages → role waits forever") reproduced
/// because the previous backstop drained one message per `engineState`
/// transition, so subsequent state changes had to fire to flush the rest. With
/// the batched fix, the FIRST backstop fire delivers all eligible messages in
/// one combined Supervisor turn — these tests pin that contract end-to-end.
@MainActor
final class QuickCaptureBackstopBatchTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - Helpers

    /// Spins up a task whose latest run has one or more steps in
    /// `.needsSupervisorInput` state — the precondition for backstop firing.
    /// `roleStatuses` is left to the engine's own bookkeeping; only step
    /// statuses matter for the backstop's `waitingSteps` filter.
    private func setUpTaskWaitingForSupervisor(
        roleIDs: [String],
        waitingRoleIDs: [String]
    ) async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Test", supervisorTask: "Goal")!

        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0)
            for roleID in roleIDs {
                var step = StepExecution.make(for: TeamRoleDefinition(
                    id: roleID, name: roleID.capitalized,
                    prompt: "", toolIDs: [], usePlanningPhase: false,
                    dependencies: RoleDependencies()
                ))
                if waitingRoleIDs.contains(roleID) {
                    step.status = .needsSupervisorInput
                    step.needsSupervisorInput = true
                    step.supervisorQuestion = "What should I do?"
                } else {
                    step.status = .pending
                }
                run.steps.append(step)
            }
            task.runs = [run]
        }

        // Engine state must be `.needsSupervisorInput` for `tryFlushQueuedMessages`
        // to dispatch to `flushQueuedChatMessage`.
        sut.engineState[taskID] = .needsSupervisorInput
        return taskID
    }

    /// `QueuedChatMessage(...)` is failable on empty payload — these helpers
    /// pre-validate so test bodies stay focused on the assertion.
    private func msg(
        _ text: String,
        target: String? = nil,
        auto: Bool = false,
        id: UUID = UUID()
    ) -> QuickCaptureFormState.QueuedChatMessage {
        QuickCaptureFormState.QueuedChatMessage(
            text: text, attachments: [], clippedTexts: [],
            targetRoleID: target, isFromAutomatedSupervisor: auto, id: id
        )!
    }

    /// Spins the run loop until `condition()` is true (or N attempts exhausted).
    /// `flushQueuedChatMessage` is dispatched via `Task { ... }` so the work
    /// runs after `tryFlushQueuedMessages` returns. We yield to let the queued
    /// Task run; for guarded async paths this is more reliable than a fixed sleep.
    /// Fails on timeout rather than returning silently. A silent timeout turns "the thing never
    /// happened" into "assert the stale value", which is how the CI failure of
    /// `testBackstopDrain_reportsFilesItCouldNotEmbed` came to read as a product bug
    /// (`"nil" is not equal to "Optional(true)"`) instead of "timed out waiting for the drain".
    /// House practice already does this — `LLMStatusMonitorTests.waitUntil` carries the same
    /// rationale — and this file was the outlier.
    private func waitFor(
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !condition() {
            XCTFail("waitFor timed out after \(timeout)s — the awaited condition never held",
                    file: file, line: line)
        }
    }

    // MARK: - User-reported bug: 8 queued messages → 1 combined delivery

    func testBackstop_eightQueuedRoleTargeted_drainsAllInOneSupervisorAnswer() async {
        // Repro of the user's screenshot: "Coding Assistant asks: standing by",
        // 8 messages "To Coding Assistant" stuck. After the fix the FIRST
        // backstop fire must drain all 8 into a single combined supervisor answer.
        let roleID = "coding-assistant"
        let taskID = await setUpTaskWaitingForSupervisor(
            roleIDs: [roleID], waitingRoleIDs: [roleID]
        )

        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut

        for i in 1...8 {
            controller.formState.appendQueuedMessage(
                msg("queued-\(i)", target: roleID), for: taskID
            )
        }
        XCTAssertEqual(controller.formState.queuedMessages(for: taskID).count, 8)

        controller.tryFlushQueuedMessages()

        // Wait for the dispatched flush Task to land the answer.
        await waitFor {
            sut.loadedTask(taskID)?.runs.last?.steps.first?.supervisorAnswer != nil
        }

        XCTAssertTrue(controller.formState.queuedMessages(for: taskID).isEmpty,
                      "All 8 messages must drain in the first backstop fire — no drip-stuck state")

        let step = sut.loadedTask(taskID)?.runs.last?.steps.first
        XCTAssertNotNil(step?.supervisorAnswer)
        let answer = step?.supervisorAnswer ?? ""
        for i in 1...8 {
            XCTAssertTrue(answer.contains("queued-\(i)"),
                          "Combined answer must include message \(i)")
        }
        // Single newline separator (matches primary path's `bodies.joined(separator: "\n")`).
        XCTAssertTrue(answer.contains("queued-1\nqueued-2"),
                      "Bodies joined with single newline, not blank lines")
        XCTAssertEqual(step?.status, .pending,
                       "Step must transition to .pending after answer (engine resumes)")
        XCTAssertFalse(step?.needsSupervisorInput ?? true,
                       "needsSupervisorInput flag cleared on answer")
    }

    // MARK: - Durable seen-marker retirement

    /// The answer is the durable "question consumed" event. The view-layer sweep
    /// that also clears this flag exists only while the main window is mounted —
    /// an answer submitted from the Quick Capture panel with the window closed
    /// must still retire the persisted marker, or the NEXT question finds the
    /// task pre-"seen" and the unread dot never lights.
    func testAnswer_retiresThePersistedSeenMarker() async {
        let roleID = "worker"
        let taskID = await setUpTaskWaitingForSupervisor(
            roleIDs: [roleID], waitingRoleIDs: [roleID]
        )
        let folderID = sut.snapshot!.projection.id
        sut.configuration.markTaskSeen(workFolderID: folderID, taskID: taskID)
        let stepID = sut.loadedTask(taskID)!.runs.last!.steps.first!.id

        let ok = await sut.answerSupervisorQuestion(stepID: stepID, taskID: taskID, answer: "done")

        XCTAssertTrue(ok)
        XCTAssertFalse(sut.configuration.isTaskSeen(workFolderID: folderID, taskID: taskID),
                       "answer commit must clear the persisted seen marker, view mounted or not")
    }

    // MARK: - Restart shape: parked but still waiting

    /// `StatusRecoveryService` parks a waiting step at `.paused` WITHOUT clearing
    /// `needsSupervisorInput` — the human is still owed the reply. The backstop's
    /// step filter must key on `canReceiveSupervisorAnswer`; filtering by
    /// `status == .needsSupervisorInput` is what silently stranded a queued
    /// message after a relaunch (the flush found "no waiting steps" and returned).
    func testBackstop_parkedButWaitingStep_stillDrains() async {
        let roleID = "worker"
        let taskID = await setUpTaskWaitingForSupervisor(
            roleIDs: [roleID], waitingRoleIDs: [roleID]
        )
        // Park the waiting step the way launch recovery does: status rewritten,
        // flag and question left standing.
        await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps[0].status = .paused
        }

        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut
        controller.formState.appendQueuedMessage(
            msg("after restart", target: roleID), for: taskID
        )

        controller.tryFlushQueuedMessages()
        await waitFor {
            sut.loadedTask(taskID)?.runs.last?.steps.first?.supervisorAnswer != nil
        }

        let step = sut.loadedTask(taskID)?.runs.last?.steps.first
        XCTAssertEqual(step?.supervisorAnswer, "after restart")
        XCTAssertTrue(controller.formState.queuedMessages(for: taskID).isEmpty,
                      "a parked-but-waiting chat must still receive its queued message")
    }

    // MARK: - Answer attribution (isFromAutomatedSupervisor → supervisorAnswerWasAuto)

    /// The Autovisor's `message_task` payload delivered via the backstop must mark
    /// the answer as automated — otherwise the child task's feed shows the human
    /// checkmark for an LLM-authored answer (the exact mislabel class the
    /// `supervisorAnswerWasAuto` flag exists to eliminate).
    func testBackstop_automatedSupervisorMessage_marksAnswerAsAuto() async {
        let roleID = "worker"
        let taskID = await setUpTaskWaitingForSupervisor(
            roleIDs: [roleID], waitingRoleIDs: [roleID]
        )
        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut
        controller.formState.appendQueuedMessage(
            msg("manager guidance", target: roleID, auto: true), for: taskID
        )

        controller.tryFlushQueuedMessages()
        await waitFor {
            sut.loadedTask(taskID)?.runs.last?.steps.first?.supervisorAnswer != nil
        }

        let step = sut.loadedTask(taskID)?.runs.last?.steps.first
        XCTAssertEqual(step?.supervisorAnswer, "manager guidance")
        XCTAssertEqual(step?.supervisorAnswerWasAuto, true,
                       "Autovisor-authored answer must carry the auto attribution")
    }

    /// A mixed batch (automated + human content) is attributed to the human —
    /// any human involvement makes it a human answer.
    func testBackstop_mixedBatch_humanContentWins_marksAnswerAsHuman() async {
        let roleID = "worker"
        let taskID = await setUpTaskWaitingForSupervisor(
            roleIDs: [roleID], waitingRoleIDs: [roleID]
        )
        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut
        controller.formState.appendQueuedMessage(
            msg("manager guidance", target: roleID, auto: true), for: taskID
        )
        controller.formState.appendQueuedMessage(
            msg("human addendum", target: roleID), for: taskID
        )

        controller.tryFlushQueuedMessages()
        await waitFor {
            sut.loadedTask(taskID)?.runs.last?.steps.first?.supervisorAnswer != nil
        }

        let step = sut.loadedTask(taskID)?.runs.last?.steps.first
        XCTAssertEqual(step?.supervisorAnswerWasAuto, false,
                       "Any human content in the drained batch makes it a human answer")
    }

    // MARK: - Mixed targeting (the user's other reproducer)

    func testBackstop_mixedTargetedAndUntargeted_drainsAllIntoSameBatch() async {
        // Reproduces the cross-surface scenario: some messages from QuickCapture
        // overlay (untargeted before Fix 1, or targeted after) + some from the
        // activity-feed composer's role chip (targeted). Backstop must combine
        // them in tier order: role-targeted FIFO → untargeted FIFO.
        let roleID = "ca"
        let taskID = await setUpTaskWaitingForSupervisor(
            roleIDs: [roleID], waitingRoleIDs: [roleID]
        )
        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut

        // Queue order interleaves the two surfaces — the resulting batch must
        // still order all targeted before all untargeted (tier priority).
        controller.formState.appendQueuedMessage(msg("u1", target: nil), for: taskID)
        controller.formState.appendQueuedMessage(msg("t1", target: roleID), for: taskID)
        controller.formState.appendQueuedMessage(msg("u2", target: nil), for: taskID)
        controller.formState.appendQueuedMessage(msg("t2", target: roleID), for: taskID)

        controller.tryFlushQueuedMessages()
        await waitFor {
            sut.loadedTask(taskID)?.runs.last?.steps.first?.supervisorAnswer != nil
        }

        let answer = sut.loadedTask(taskID)?.runs.last?.steps.first?.supervisorAnswer ?? ""
        XCTAssertEqual(answer, "t1\nt2\nu1\nu2",
                       "Tier 1 (role-targeted FIFO) drains first, then tier 2 (untargeted FIFO)")
        XCTAssertTrue(controller.formState.queuedMessages(for: taskID).isEmpty)
    }

    // MARK: - Multi-role waiting: only first targeted role's bucket drains

    func testBackstop_multipleWaitingRoles_onlyTargetedBucketForFirstMatchDrains() async {
        // FAANG-shape: PM and TL both `.needsSupervisorInput` simultaneously.
        // User has messages targeted to BOTH roles. One backstop fire drains
        // PM's bucket; TL's stays queued for its own engine-state cycle.
        let pm = "pm"
        let tl = "tl"
        let taskID = await setUpTaskWaitingForSupervisor(
            roleIDs: [pm, tl], waitingRoleIDs: [pm, tl]
        )
        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut

        let pmA = msg("for pm A", target: pm)
        let tlOnly = msg("for tl", target: tl)
        let pmB = msg("for pm B", target: pm)
        controller.formState.appendQueuedMessage(pmA, for: taskID)
        controller.formState.appendQueuedMessage(tlOnly, for: taskID)
        controller.formState.appendQueuedMessage(pmB, for: taskID)

        controller.tryFlushQueuedMessages()
        // PM is the picked role (first targeted with a waiting target). Wait
        // for the PM step's answer to land.
        await waitFor {
            sut.loadedTask(taskID)?.runs.last?.steps
                .first(where: { $0.effectiveRoleID == pm })?.supervisorAnswer != nil
        }

        let pmStep = sut.loadedTask(taskID)?.runs.last?.steps
            .first(where: { $0.effectiveRoleID == pm })
        let tlStep = sut.loadedTask(taskID)?.runs.last?.steps
            .first(where: { $0.effectiveRoleID == tl })

        XCTAssertEqual(pmStep?.supervisorAnswer, "for pm A\nfor pm B",
                       "PM bucket drains; TL-targeted stays queued")
        XCTAssertNil(tlStep?.supervisorAnswer,
                     "TL is unaffected — its bucket awaits its own backstop fire")

        let remaining = controller.formState.queuedMessages(for: taskID)
        XCTAssertEqual(remaining.map(\.id), [tlOnly.id],
                       "Exactly the TL-targeted message stays queued")
    }

    // MARK: - Untargeted routing in multi-waiting-role scenario

    func testBackstop_multipleWaitingRoles_untargetedRouteToFirstWaiting() async {
        // No role-targeted messages — backstop tier-2 logic routes untargeted
        // batch to the first waiting role (FIFO over the waiting set).
        let first = "first"
        let second = "second"
        let taskID = await setUpTaskWaitingForSupervisor(
            roleIDs: [first, second], waitingRoleIDs: [first, second]
        )
        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut

        controller.formState.appendQueuedMessage(msg("a"), for: taskID)
        controller.formState.appendQueuedMessage(msg("b"), for: taskID)

        controller.tryFlushQueuedMessages()
        await waitFor {
            sut.loadedTask(taskID)?.runs.last?.steps
                .first(where: { $0.effectiveRoleID == first })?.supervisorAnswer != nil
        }

        let firstStep = sut.loadedTask(taskID)?.runs.last?.steps
            .first(where: { $0.effectiveRoleID == first })
        let secondStep = sut.loadedTask(taskID)?.runs.last?.steps
            .first(where: { $0.effectiveRoleID == second })

        XCTAssertEqual(firstStep?.supervisorAnswer, "a\nb",
                       "Both untargeted messages land on the first waiting role in one batch")
        XCTAssertNil(secondStep?.supervisorAnswer,
                     "Second waiting role gets no answer — untargeted goes to first only")
        XCTAssertTrue(controller.formState.queuedMessages(for: taskID).isEmpty,
                      "Both untargeted messages drained")
    }

    // MARK: - Parallel-role same-state regression (new hook in setNeedsSupervisorInput)

    /// Pins the bug the `notifyQueuedMessageBackstop` hook in
    /// `LLMExecutionService.setNeedsSupervisorInput` fixes.
    ///
    /// Scenario (CLAUDE.md §45 parallel-role execution):
    /// - Role A's step is already `.needsSupervisorInput`; the engine sits in
    ///   `.needsSupervisorInput` because of A.
    /// - Supervisor queues a message **targeted at Role B**, which is still
    ///   working (not yet waiting). The backstop's
    ///   `collectQueuedMessagesForFlush` skips it — B isn't in the waiting set.
    /// - Role B's LLM iteration completes with its own `ask_supervisor`. The
    ///   step mutates to `.needsSupervisorInput`, but the engine state
    ///   `[taskID: .needsSupervisorInput]` does NOT change — `TeamEngine.transition(to:)`
    ///   suppresses same-state re-entry (CLAUDE.md §39).
    /// - The SwiftUI `onChange(of: taskEngineStates)` trigger in
    ///   `MainLayoutView.handleEngineStateChanged` therefore doesn't fire and
    ///   the queued message for B sits stranded.
    ///
    /// With the new hook, `setNeedsSupervisorInput` fires the backstop directly.
    /// This test simulates that by mutating B's step status (as the production
    /// `setNeedsSupervisorInput` does) and then calling
    /// `tryFlushQueuedMessages()` (as the production hook does) — without ever
    /// changing the engine-state dictionary. The drain must still happen.
    func testBackstop_parallelRole_drainsTargetedMessage_whenEngineStateUnchanged() async {
        let roleA = "role-a"
        let roleB = "role-b"

        // Setup: A waiting, B pending. Engine = .needsSupervisorInput (held by A).
        let taskID = await setUpTaskWaitingForSupervisor(
            roleIDs: [roleA, roleB], waitingRoleIDs: [roleA]
        )

        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut

        // Supervisor queues a message targeted at Role B (who isn't waiting yet).
        controller.formState.appendQueuedMessage(msg("for-B", target: roleB), for: taskID)

        // First flush attempt: B isn't in the waiting set yet, so the message
        // is collected as "skipped — target not waiting" and stays queued.
        controller.tryFlushQueuedMessages()
        // Join whatever was dispatched and confirm it no-ops. This was `waitFor(timeout: 0.2)
        // { false }` — a fixed sleep in a waiting helper's costume, which is exactly what made
        // the helper unable to fail on timeout.
        await controller._testAwaitPendingFlushes()

        XCTAssertEqual(controller.formState.queuedMessages(for: taskID).count, 1,
                       "Message targeted at B stays queued while B isn't waiting")
        XCTAssertNil(
            sut.loadedTask(taskID)?.runs.last?.steps
                .first(where: { $0.effectiveRoleID == roleB })?.supervisorAnswer,
            "B's step has no answer — backstop correctly didn't drain"
        )

        // Snapshot engine state BEFORE simulating Role B's setNeedsSupervisorInput.
        let engineStateBefore = sut.engineState[taskID]
        XCTAssertEqual(engineStateBefore, .needsSupervisorInput,
                       "Precondition: engine is already `.needsSupervisorInput` (held by A)")

        // Simulate Role B's `setNeedsSupervisorInput` call: mutate B's step status.
        // (Production calls `delegate.mutateTask` with this same body.)
        await sut.mutateTask(taskID: taskID) { task in
            guard let runIdx = task.runs.indices.last,
                  let stepIdx = task.runs[runIdx].steps.firstIndex(where: { $0.effectiveRoleID == roleB })
            else { return }
            task.runs[runIdx].steps[stepIdx].status = .needsSupervisorInput
            task.runs[runIdx].steps[stepIdx].needsSupervisorInput = true
            task.runs[runIdx].steps[stepIdx].supervisorQuestion = "B asking too"
        }

        // Verify engine state did NOT change — this is the same-state re-entry
        // case (CLAUDE.md §39). Without the new hook, the SwiftUI onChange
        // trigger would NOT fire and the queue would sit forever.
        XCTAssertEqual(sut.engineState[taskID], engineStateBefore,
                       "Engine state must NOT change — this is the bug condition")

        // Now simulate the new hook: `setNeedsSupervisorInput` calls
        // `delegate.notifyQueuedMessageBackstop(taskID:)` which forwards to
        // `QuickCaptureController.shared.tryFlushQueuedMessages()`.
        controller.tryFlushQueuedMessages()

        // Drain must now succeed — B is in the waiting set.
        await waitFor {
            sut.loadedTask(taskID)?.runs.last?.steps
                .first(where: { $0.effectiveRoleID == roleB })?.supervisorAnswer != nil
        }

        let bStep = sut.loadedTask(taskID)?.runs.last?.steps
            .first(where: { $0.effectiveRoleID == roleB })
        XCTAssertEqual(bStep?.supervisorAnswer, "for-B",
                       "Role B's queued message drained via the explicit backstop trigger")
        XCTAssertTrue(controller.formState.queuedMessages(for: taskID).isEmpty,
                      "Queue is empty — the regression is fixed")
    }

    // MARK: - Concurrent invocation safety (atomic reserve)

    func testBackstop_concurrentInvocations_secondSeesEmptyQueue() async {
        // Documented atomicity contract: the synchronous pop-before-await means
        // a second `tryFlushQueuedMessages` triggered by a rapid state flip
        // sees an empty queue and no-ops — no double-delivery.
        let roleID = "ca"
        let taskID = await setUpTaskWaitingForSupervisor(
            roleIDs: [roleID], waitingRoleIDs: [roleID]
        )
        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut

        for i in 1...3 {
            controller.formState.appendQueuedMessage(msg("m\(i)", target: roleID), for: taskID)
        }

        // Fire two flushes back-to-back synchronously. Both spawn Tasks that
        // run on the @MainActor — the second to actually execute will find an
        // empty queue because the first's synchronous pop already drained it.
        controller.tryFlushQueuedMessages()
        controller.tryFlushQueuedMessages()

        // Joined, not polled, and the distinction is what makes this test able to fail. It
        // asserts an ABSENCE (no double-append) while `supervisorAnswer` is assigned with `=`
        // — so a wait keyed on that value becoming non-nil can return between the first write
        // and a second one overwriting it, and the test pinning the atomicity contract would
        // read the correct first value and miss its own regression.
        await controller._testAwaitPendingFlushes()

        let answer = sut.loadedTask(taskID)?.runs.last?.steps.first?.supervisorAnswer
        XCTAssertEqual(answer, "m1\nm2\nm3",
                       "Exactly one combined delivery — no double-append from concurrent invocations")
        XCTAssertTrue(controller.formState.queuedMessages(for: taskID).isEmpty)
    }

    // MARK: - Failure-path data invariant: prepend preserves FIFO at head

    /// The flushQueuedChatMessage failure branch calls `prependQueuedMessages(popped, ...)`.
    /// This verifies the data behavior that branch depends on — popped batch
    /// goes to the HEAD in original order, and any message queued during the
    /// failed await stays BEHIND them. Triggering the actual production failure
    /// (concurrent step removal during the answerSupervisorQuestion await) is
    /// a race we can't simulate deterministically; this test pins the
    /// downstream invariant the failure handler relies on.
    func testFailurePath_prependQueuedMessages_keepsBatchAtHeadInOriginalOrder() async {
        let formState = QuickCaptureFormState()
        let m1 = msg("first")
        let m2 = msg("second")
        let m3 = msg("third")

        // Simulate: a flush popped [m1, m2, m3] synchronously, started its
        // await, and meanwhile the user queued "newcomer". On answerSupervisor
        // failure the failure branch prepends the popped batch.
        formState.appendQueuedMessage(msg("newcomer"), for: 1)
        formState.prependQueuedMessages([m1, m2, m3], for: 1)

        XCTAssertEqual(formState.queuedMessages(for: 1).map(\.text),
                       ["first", "second", "third", "newcomer"],
                       "Failed batch must come back at HEAD in original order — newcomer stays behind")
    }

    // MARK: - Submit auto-target (end-to-end Fix 1)

    func testSubmit_chatModeWithRunningRole_setsTargetRoleID_endToEnd() async {
        // Wire submitQueuedMessageFromForm through a real orchestrator with
        // an active running step. Verify the queued message comes out with
        // the running role's id as `targetRoleID` (no longer the "Team" queue).
        let roleID = "coding-assistant"
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "G")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            var run = Run(id: 0)
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: roleID, name: "Coding Assistant",
                prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies()
            ))
            step.status = .running  // Engine is mid-iteration, role is working.
            run.steps = [step]
            task.runs = [run]
        }
        sut.engineState[taskID] = .running
        await sut.switchTask(to: taskID)  // Sets activeTaskID for submit.

        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut
        controller.formState.answerText = "do the thing"

        controller.submitQueuedMessageFromForm()

        let queue = controller.formState.queuedMessages(for: taskID)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.targetRoleID, roleID,
                       "Submit must auto-target the first running step's role, not leave Team-queue (nil)")
        XCTAssertEqual(queue.first?.text, "do the thing")
        XCTAssertTrue(controller.formState.answerText.isEmpty,
                      "Composer cleared on successful submit")
    }

    func testSubmit_chatModeMultiRoleAllRunning_targetsFirstRunningInRunOrder() async {
        // Multi-role chat (Quest Party-shape): 3 roles all `.running`. Submit
        // targets whichever appears FIRST in `task.runs.last?.steps` order —
        // the same role QuickCapture's title is displaying.
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "G")!

        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
            var run = Run(id: 0)
            for id in ["loremaster", "npc", "encounter"] {
                var step = StepExecution.make(for: TeamRoleDefinition(
                    id: id, name: id.capitalized,
                    prompt: "", toolIDs: [], usePlanningPhase: false,
                    dependencies: RoleDependencies()
                ))
                step.status = .running
                run.steps.append(step)
            }
            task.runs = [run]
        }
        sut.engineState[taskID] = .running
        await sut.switchTask(to: taskID)

        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut
        controller.formState.answerText = "talk to loremaster"

        controller.submitQueuedMessageFromForm()

        let queue = controller.formState.queuedMessages(for: taskID)
        XCTAssertEqual(queue.first?.targetRoleID, "loremaster",
                       "Multi-role chat: first running step in run.steps order picks the recipient — same as title")
    }

    func testSubmit_noActiveTask_setsErrorMessage_andDoesNotQueue() async {
        // Defensive: submit without an active task surfaces `lastErrorMessage`
        // instead of silently dropping the draft.
        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut
        controller.formState.answerText = "stranded"

        controller.submitQueuedMessageFromForm()

        XCTAssertEqual(sut.lastErrorMessage, "No active task — open or create a task first.")
        XCTAssertEqual(controller.formState.answerText, "stranded",
                       "Draft preserved on error so user can retry after picking a task")
    }

    // MARK: - What the drain reports (wave 24)

    /// The drain builds each message through `AnswerTextBuilder` exactly like `createTask` and
    /// `submitAnswer` do, and then dropped the one thing those two report: `failedFiles`. With
    /// "embed files in prompt" on, a file that cannot be read as text is simply absent from the
    /// delivered message — the role answers without it, and the user is never told which file
    /// went missing or that one did.
    ///
    /// RED: drop the `failedFiles` report from `flushQueuedChatMessage` → nothing names
    /// `payload.bin` and this fails.
    func testBackstopDrain_reportsFilesItCouldNotEmbed() async throws {
        let roleID = "coding-assistant"
        let taskID = await setUpTaskWaitingForSupervisor(
            roleIDs: [roleID], waitingRoleIDs: [roleID]
        )
        sut.configuration.embedFilesInPrompt = true

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-embed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let source = outside.appendingPathComponent("payload.bin")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: source)
        guard let staged = sut.stageAttachment(url: source, draftID: UUID()) else {
            throw XCTSkip("staging unavailable")
        }

        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut
        let message = QuickCaptureFormState.QueuedChatMessage(
            text: "have a look", attachments: [staged], clippedTexts: [], targetRoleID: roleID
        )!
        controller.formState.appendQueuedMessage(message, for: taskID)

        // Sampled BEFORE the flush: `errorSurfaced(since:)` is the only correct way to ask
        // "did what I just awaited fail" — `lastErrorMessage` is a single-shot slot any render
        // can consume, and reading it across a suspension gets the answer wrong both ways.
        let errorsBefore = sut.errorSurfaceCount

        controller.tryFlushQueuedMessages()
        // JOIN, do not poll. Every pollable signal is produced on the near side of the drain's
        // suspension while the banner lands on the far side — see `_testPendingFlushTasks`.
        await controller._testAwaitPendingFlushes()

        XCTAssertFalse(controller.formState.hasQueuedMessage(for: taskID),
                       "precondition: the batch was popped")
        XCTAssertNotNil(sut.loadedTask(taskID)?.runs.last?.steps.first?.supervisorAnswer,
                        "precondition: the batch was actually delivered — an empty queue alone "
                            + "proves only the pop, which happens even when delivery then fails")
        XCTAssertEqual(sut.errorSurfaced(since: errorsBefore)?.contains("payload.bin"), true,
                       "the sibling submit paths name the file; a drain that silently drops it "
                           + "leaves the role answering about something it never received")
    }

    /// Counter-test: a clean drain says nothing. Without this the report could be unconditional
    /// and every delivered message would raise a banner.
    ///
    /// This one is why the drain must be JOINED rather than polled: it asserts an ABSENCE, and
    /// an absence cannot be waited for. While the wait exited early (at the pop, before the
    /// banner would have been written) the test passed by observing nothing at all — its own
    /// RED marker below was false on the runner that matters, since an unconditional banner
    /// still writes after the suspension.
    ///
    /// RED: report unconditionally → this fails.
    func testBackstopDrain_saysNothingWhenEveryFileEmbedded() async {
        let roleID = "coding-assistant"
        let taskID = await setUpTaskWaitingForSupervisor(
            roleIDs: [roleID], waitingRoleIDs: [roleID]
        )
        sut.configuration.embedFilesInPrompt = true
        sut.lastErrorMessage = nil

        let controller = QuickCaptureController(formState: QuickCaptureFormState())
        controller.store = sut
        controller.formState.appendQueuedMessage(msg("plain text", target: roleID), for: taskID)

        let errorsBefore = sut.errorSurfaceCount
        controller.tryFlushQueuedMessages()
        await controller._testAwaitPendingFlushes()

        XCTAssertNotNil(sut.loadedTask(taskID)?.runs.last?.steps.first?.supervisorAnswer,
                        "precondition: the batch was delivered — otherwise the absence below is "
                            + "the absence of a drain, not the absence of a banner")
        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore,
                       "an all-embedded drain must not banner. Counted rather than read off "
                           + "`lastErrorMessage`, which also reads nil for an error that WAS "
                           + "surfaced and then consumed by a render")
    }
}
