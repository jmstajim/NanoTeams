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
final class QuickCaptureBackstopBatchTests: NTMSOrchestratorTestBase {

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
        id: UUID = UUID()
    ) -> QuickCaptureFormState.QueuedChatMessage {
        QuickCaptureFormState.QueuedChatMessage(
            text: text, attachments: [], clippedTexts: [],
            targetRoleID: target, id: id
        )!
    }

    /// Spins the run loop until `condition()` is true (or N attempts exhausted).
    /// `flushQueuedChatMessage` is dispatched via `Task { ... }` so the work
    /// runs after `tryFlushQueuedMessages` returns. We yield to let the queued
    /// Task run; for guarded async paths this is more reliable than a fixed sleep.
    private func waitFor(
        timeout: TimeInterval = 1.0,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
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

        await waitFor {
            sut.loadedTask(taskID)?.runs.last?.steps.first?.supervisorAnswer != nil
        }

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
        controller.formState.supervisorTask = "do the thing"

        controller.submitQueuedMessageFromForm()

        let queue = controller.formState.queuedMessages(for: taskID)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.targetRoleID, roleID,
                       "Submit must auto-target the first running step's role, not leave Team-queue (nil)")
        XCTAssertEqual(queue.first?.text, "do the thing")
        XCTAssertTrue(controller.formState.supervisorTask.isEmpty,
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
        controller.formState.supervisorTask = "talk to loremaster"

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
        controller.formState.supervisorTask = "stranded"

        controller.submitQueuedMessageFromForm()

        XCTAssertEqual(sut.lastErrorMessage, "No active task — open or create a task first.")
        XCTAssertEqual(controller.formState.supervisorTask, "stranded",
                       "Draft preserved on error so user can retry after picking a task")
    }
}
