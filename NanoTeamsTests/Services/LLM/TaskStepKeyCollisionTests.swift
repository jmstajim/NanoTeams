import XCTest

@testable import NanoTeams

/// Regression pins for the June 2026 concurrent-task stepID collision.
///
/// `StepExecution.id` equals the team role ID, so two tasks running the SAME team
/// carry identical stepID strings (observed: two tasks on the Startup team, both
/// with `startup_software_engineer`). Before the `TaskStepKey` fix, every per-step
/// runtime registry was keyed by the bare stepID:
///   • `LLMExecutionService.executionStates` — starting/pausing task B cancelled
///     task A's LIVE execution (`cancelStepExecution` hit the shared key), leaving
///     A a zombie: engine `.running`, step `.running`, no LLM behind it.
///   • `StreamingPreviewManager` — one task's commit/clear wiped the other task's
///     Thinking/Processing indicator state mid-stream.
///
/// These tests drive two tasks against the SAME stepID and assert full isolation.
@MainActor
final class StreamingPreviewManagerCrossTaskIsolationTests: XCTestCase, @unchecked Sendable {

    private var sut: StreamingPreviewManager!
    private let stepID = "startup_software_engineer"
    private let taskA = 39
    private let taskB = 40

    override func setUp() async throws {
        try await super.setUp()
        sut = StreamingPreviewManager()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    /// Seeds a full set of live indicator state for one task's step.
    private func seedLiveStream(taskID: Int, messageID: UUID, content: String, thinking: String) {
        sut.beginStreaming(stepID: stepID, taskID: taskID, messageID: messageID, role: .softwareEngineer)
        sut.updateProcessingStatus(stepID: stepID, taskID: taskID, status: .fraction(0.5))
        sut.append(stepID: stepID, taskID: taskID, messageID: messageID, role: .softwareEngineer, content: content)
        sut.appendThinking(stepID: stepID, taskID: taskID, content: thinking)
        sut.markStreamActivity(stepID: stepID, taskID: taskID)
        sut.markStreamingToolCall(stepID: stepID, taskID: taskID)
    }

    // MARK: - Concurrent streams on the same stepID

    func testSameStepID_twoTasks_streamContentIndependently() async {
        let msgA = UUID()
        let msgB = UUID()

        seedLiveStream(taskID: taskA, messageID: msgA, content: "task A content", thinking: "A thinks")
        seedLiveStream(taskID: taskB, messageID: msgB, content: "task B content", thinking: "B thinks")

        XCTAssertEqual(sut.streamingContent(stepID: stepID, taskID: taskA), "task A content")
        XCTAssertEqual(sut.streamingContent(stepID: stepID, taskID: taskB), "task B content")
        XCTAssertEqual(sut.streamingThinking(stepID: stepID, taskID: taskA), "A thinks")
        XCTAssertEqual(sut.streamingThinking(stepID: stepID, taskID: taskB), "B thinks")
        XCTAssertTrue(sut.isStreaming(messageID: msgA), "task A's message must stay registered")
        XCTAssertTrue(sut.isStreaming(messageID: msgB), "task B's message must stay registered")
    }

    /// THE indicator bug from the production trace: task A finishing its turn
    /// (commit) wiped task B's `hasStreamActivity` / progress / tool-call flags,
    /// flipping B's bubble from "Generating" back to "Waiting" (or hiding it).
    func testCommit_oneTask_keepsOtherTasksIndicatorState() async {
        let msgA = UUID()
        let msgB = UUID()
        seedLiveStream(taskID: taskA, messageID: msgA, content: "A", thinking: "A thinks")
        seedLiveStream(taskID: taskB, messageID: msgB, content: "B", thinking: "B thinks")

        sut.commit(stepID: stepID, taskID: taskA)

        // Task A's per-step state is gone.
        XCTAssertNil(sut.streamingContent(stepID: stepID, taskID: taskA))
        XCTAssertFalse(sut.hasReceivedStreamActivity(stepID: stepID, taskID: taskA))
        XCTAssertFalse(sut.isStreamingToolCall(stepID: stepID, taskID: taskA))
        XCTAssertNil(sut.lastStreamActivity(stepID: stepID, taskID: taskA))
        XCTAssertFalse(sut.isStreaming(messageID: msgA))

        // Task B's live indicator state survived in full.
        XCTAssertEqual(sut.streamingContent(stepID: stepID, taskID: taskB), "B")
        XCTAssertEqual(sut.streamingThinking(stepID: stepID, taskID: taskB), "B thinks")
        XCTAssertTrue(
            sut.hasReceivedStreamActivity(stepID: stepID, taskID: taskB),
            "Task A's commit must not wipe task B's stream-activity flag (the lost-indicator bug)")
        XCTAssertTrue(sut.isStreamingToolCall(stepID: stepID, taskID: taskB))
        XCTAssertNotNil(sut.processingStatus[TaskStepKey(taskID: taskB, stepID: stepID)])
        XCTAssertNotNil(sut.lastStreamActivity(stepID: stepID, taskID: taskB))
        XCTAssertTrue(sut.isStreaming(messageID: msgB))
    }

    func testClear_oneTask_keepsOtherTasksState() async {
        let msgA = UUID()
        let msgB = UUID()
        seedLiveStream(taskID: taskA, messageID: msgA, content: "A", thinking: "A thinks")
        seedLiveStream(taskID: taskB, messageID: msgB, content: "B", thinking: "B thinks")

        sut.clear(stepID: stepID, taskID: taskB)

        XCTAssertNil(sut.streamingContent(stepID: stepID, taskID: taskB))
        XCTAssertFalse(sut.isStreaming(messageID: msgB))

        XCTAssertEqual(sut.streamingContent(stepID: stepID, taskID: taskA), "A")
        XCTAssertTrue(sut.hasReceivedStreamActivity(stepID: stepID, taskID: taskA))
        XCTAssertTrue(sut.isStreaming(messageID: msgA))
    }

    /// Pre-fix, task B's `beginStreaming` on the shared stepID RESET task A's
    /// per-stream transients (the `⚠️OVERWRITE` the diagnostic trace was armed
    /// to catch) and deregistered A's messageID.
    func testBeginStreaming_secondTask_doesNotResetFirstTasksTransients() async {
        let msgA = UUID()
        seedLiveStream(taskID: taskA, messageID: msgA, content: "A mid-stream", thinking: "A thinks")

        sut.beginStreaming(stepID: stepID, taskID: taskB, messageID: UUID(), role: .softwareEngineer)

        XCTAssertEqual(
            sut.streamingContent(stepID: stepID, taskID: taskA), "A mid-stream",
            "Task B starting a stream on the same stepID must not touch task A's preview")
        XCTAssertEqual(sut.streamingThinking(stepID: stepID, taskID: taskA), "A thinks")
        XCTAssertTrue(sut.hasReceivedStreamActivity(stepID: stepID, taskID: taskA))
        XCTAssertTrue(sut.isStreamingToolCall(stepID: stepID, taskID: taskA))
        XCTAssertTrue(sut.isStreaming(messageID: msgA))

        // And task B starts genuinely fresh — no inherited flags from A.
        XCTAssertFalse(sut.hasReceivedStreamActivity(stepID: stepID, taskID: taskB))
        XCTAssertFalse(sut.isStreamingToolCall(stepID: stepID, taskID: taskB))
        XCTAssertNil(sut.streamingThinking(stepID: stepID, taskID: taskB))
    }

    /// The Autovisor stuck-detector reads `lastStreamActivity` per step — a shared
    /// clock would let task A's token flow mask a genuinely hung task B.
    func testLastStreamActivity_isolatedPerTask() async {
        sut.markStreamActivity(stepID: stepID, taskID: taskA)

        XCTAssertNotNil(sut.lastStreamActivity(stepID: stepID, taskID: taskA))
        XCTAssertNil(
            sut.lastStreamActivity(stepID: stepID, taskID: taskB),
            "Task A's activity must not refresh task B's hang-detection clock")
    }

    /// Same-key re-entry (the in-step LLM error retry path re-enters
    /// `beginStreaming` without an intervening commit/clear): the OLD messageID
    /// must be deregistered from the active set, or `isStreaming(messageID:)`
    /// would keep animating a bubble whose stream was replaced.
    func testBeginStreamingReentry_sameKey_deregistersOldMessageID() async {
        let msg1 = UUID()
        let msg2 = UUID()
        sut.beginStreaming(stepID: stepID, taskID: taskA, messageID: msg1, role: .softwareEngineer)
        XCTAssertTrue(sut.isStreaming(messageID: msg1))

        sut.beginStreaming(stepID: stepID, taskID: taskA, messageID: msg2, role: .softwareEngineer)

        XCTAssertTrue(sut.isStreaming(messageID: msg2))
        XCTAssertFalse(
            sut.isStreaming(messageID: msg1),
            "Re-entry on the same (taskID, stepID) must deregister the replaced messageID")
    }

    func testClearAll_clearsEveryTasksState() async {
        seedLiveStream(taskID: taskA, messageID: UUID(), content: "A", thinking: "tA")
        seedLiveStream(taskID: taskB, messageID: UUID(), content: "B", thinking: "tB")

        sut.clearAll()

        for task in [taskA, taskB] {
            XCTAssertNil(sut.streamingContent(stepID: stepID, taskID: task))
            XCTAssertFalse(sut.hasReceivedStreamActivity(stepID: stepID, taskID: task))
            XCTAssertNil(sut.lastStreamActivity(stepID: stepID, taskID: task))
        }
    }
}

// MARK: - LLMExecutionService.executionStates isolation

@MainActor
final class ExecutionStateCrossTaskIsolationTests: XCTestCase, @unchecked Sendable {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private let stepID = "startup_software_engineer"
    private let taskA = 39
    private let taskB = 40

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        service = nil
        mockDelegate = nil
        try await super.tearDown()
    }

    /// A long-suspended stand-in for a live LLM stream; finishes promptly when
    /// cancelled (the sleep throws), which is what `cancelStepExecution` awaits.
    private func makeSuspendedTask() -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// THE production kill from the trace (`EXEC end task=39 via=cancelStep`):
    /// cancelling task B's step must not touch task A's live execution on the
    /// same stepID. Pre-fix, the single-key dictionary made this impossible —
    /// whichever task registered last owned the entry and the other one's
    /// cancel/teardown landed on it.
    func testCancelStepExecution_sameStepID_otherTasksExecutionSurvives() async {
        let runningA = makeSuspendedTask()
        let runningB = makeSuspendedTask()
        service._testInjectRunningTask(stepID: stepID, taskID: taskA, runningTask: runningA)
        service._testInjectRunningTask(stepID: stepID, taskID: taskB, runningTask: runningB)

        // Both entries coexist — pre-fix the second registration evicted the first.
        XCTAssertTrue(service._testHasExecutionState(stepID: stepID, taskID: taskA))
        XCTAssertTrue(service._testHasExecutionState(stepID: stepID, taskID: taskB))

        await service.cancelStepExecution(stepID: stepID, taskID: taskB)

        XCTAssertFalse(service._testHasExecutionState(stepID: stepID, taskID: taskB))
        XCTAssertTrue(runningB.isCancelled)

        XCTAssertTrue(
            service._testHasExecutionState(stepID: stepID, taskID: taskA),
            "Cancelling task B's step must not evict task A's executionStates entry (zombie-task bug)")
        XCTAssertFalse(
            runningA.isCancelled,
            "Task A's live LLM execution must not be cancelled by task B's teardown")

        runningA.cancel()
    }

    func testCancelExecutionsForTaskID_leavesOtherTasksSteps() async {
        let runningA = makeSuspendedTask()
        let runningB = makeSuspendedTask()
        service._testInjectRunningTask(stepID: stepID, taskID: taskA, runningTask: runningA)
        service._testInjectRunningTask(stepID: stepID, taskID: taskB, runningTask: runningB)

        service.cancelExecutions(forTaskID: taskB)

        XCTAssertFalse(service._testHasExecutionState(stepID: stepID, taskID: taskB))
        XCTAssertTrue(service._testHasExecutionState(stepID: stepID, taskID: taskA))
        XCTAssertFalse(runningA.isCancelled)

        runningA.cancel()
        runningB.cancel()
    }

    func testIsStepRunning_scopedToOwningTask() async {
        let runningA = makeSuspendedTask()
        service._testInjectRunningTask(stepID: stepID, taskID: taskA, runningTask: runningA)

        XCTAssertTrue(service.isStepRunning(stepID: stepID, taskID: taskA))
        XCTAssertFalse(
            service.isStepRunning(stepID: stepID, taskID: taskB),
            "Task B has no execution on this step — a shared key would falsely report it running")

        runningA.cancel()
    }

    func testRequestFinish_scopedToOwningTask() async {
        service._testRegisterStepTask(stepID: stepID, taskID: taskA)
        service._testRegisterStepTask(stepID: stepID, taskID: taskB)

        service.requestFinish(stepID: stepID, taskID: taskA)

        XCTAssertTrue(service._testFinishRequested(stepID: stepID, taskID: taskA))
        XCTAssertFalse(
            service._testFinishRequested(stepID: stepID, taskID: taskB),
            "Finish Role on task A must not gracefully finish task B's same-named step")
    }

    func testClearRunningTask_scopedToOwningTask() async {
        service._testRegisterStepTask(stepID: stepID, taskID: taskA)
        service._testRegisterStepTask(stepID: stepID, taskID: taskB)

        service.clearRunningTask(stepID: stepID, taskID: taskB)

        XCTAssertFalse(service._testHasExecutionState(stepID: stepID, taskID: taskB))
        XCTAssertTrue(service._testHasExecutionState(stepID: stepID, taskID: taskA))
    }

    /// The Autovisor idle-park flag is per (task, step): parking task A's manager
    /// pass must not park task B's same-named step.
    func testParkForEventsFlag_scopedToOwningTask() async {
        service._testRegisterStepTask(stepID: stepID, taskID: taskA)
        service._testRegisterStepTask(stepID: stepID, taskID: taskB)

        let envelope = await service.handleWaitForEvents(stepID: stepID, taskID: taskA)

        XCTAssertTrue(envelope.contains("\"ok\":true"), "got: \(envelope)")
        XCTAssertTrue(service._testParkForEventsRequested(stepID: stepID, taskID: taskA))
        XCTAssertFalse(
            service._testParkForEventsRequested(stepID: stepID, taskID: taskB),
            "Parking task A must not set task B's park flag on the shared stepID")
    }

    /// Same-key re-entry into `startStepExecution` must cancel the PREVIOUS
    /// execution before replacing the entry. The pre-fix order replaced first
    /// and then cancelled — targeting the fresh state's nil runningTask and
    /// silently leaking the old execution.
    func testStartStepExecutionReentry_cancelsPreviousRunningTask() async {
        let previous = makeSuspendedTask()
        service._testInjectRunningTask(stepID: stepID, taskID: taskA, runningTask: previous)

        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "Step", status: .running)
        let task = NTMSTask(id: taskA, title: "T", supervisorTask: "G", runs: [Run(id: 0, steps: [step])])
        // mockDelegate.workFolderURL is nil → startStepExecution bails after the
        // entry replacement, before spawning a real LLM task. The cancel-before-
        // replace contract is exactly what this pins.
        service.startStepExecution(stepID: stepID, taskID: taskA, task: task, runIndex: 0, stepIndex: 0)

        XCTAssertTrue(
            previous.isCancelled,
            "Re-entry must cancel the previous execution BEFORE replacing the entry — not after, when the reference is already lost")
        XCTAssertFalse(service.isStepRunning(stepID: stepID, taskID: taskA),
                       "The fresh entry starts with no runningTask")
    }

    /// Retry-cap counters are per (task, step): task A's thinking-loop streak must
    /// not pre-trigger task B's escalation, and B's clean turn must not absolve A.
    func testLoopBreakCounters_independentAcrossTasks() async {
        service._testSetThinkingLoopBreakCount(stepID: stepID, taskID: taskA, count: 2)
        service._testSetThinkingLoopBreakCount(stepID: stepID, taskID: taskB, count: 1)

        // Task B completes a clean stream — its counter resets.
        service._testResetThinkingLoopBreakCount(stepID: stepID, taskID: taskB)

        XCTAssertEqual(
            service._testThinkingLoopBreakCount(stepID: stepID, taskID: taskA), 2,
            "Task B's clean turn must not reset task A's consecutive-break budget")
        XCTAssertEqual(service._testThinkingLoopBreakCount(stepID: stepID, taskID: taskB), 0)
    }
}

// MARK: - Orchestrator integration: the reproduced trace scenario

/// End-to-end pin of the production repro: two tasks on the same team (shared
/// stepID), task A mid-execution; pausing/tearing down task B must leave task A's
/// execution AND its streaming indicator intact. Pre-fix, `pauseRun(taskID: B)`
/// iterated B's steps and called `cancelStepExecution(stepID:)` on the shared
/// key — killing A's live LLM stream (the trace's `EXEC end task=39 via=cancelStep`).
@MainActor
final class PauseRunCrossTaskCollisionTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let sharedStepID = "startup_software_engineer"

    private func createTaskWithRunningStep(title: String, status: StepStatus = .running) async -> Int {
        let taskID = await sut.createTask(title: title, supervisorTask: "Goal")!
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(
                id: 0,
                steps: [StepExecution(
                    id: self.sharedStepID, role: .softwareEngineer,
                    title: "Implementation", status: status)],
                roleStatuses: [self.sharedStepID: .working]
            )
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        return taskID
    }

    func testPauseRunOfOneTask_doesNotKillSameStepExecutionOfOtherTask() async {
        await sut.openWorkFolder(tempDir)
        let taskA = await createTaskWithRunningStep(title: "Phase 39")
        let taskB = await createTaskWithRunningStep(title: "Phase 40")
        // De-alias active task vs paused task: pause B while A is ACTIVE, so a
        // regression that substitutes the active task's id anywhere in the
        // pause/cancel chain cannot coincidentally pass.
        await sut.switchTask(to: taskA)

        // Task A is mid-execution: live executionStates entry + live stream state.
        let runningA = Task { @MainActor in
            _ = try? await Task.sleep(for: .seconds(60))
        }
        sut.llmExecutionService._testInjectRunningTask(
            stepID: sharedStepID, taskID: taskA, runningTask: runningA)
        let msgA = UUID()
        sut.streamingPreviewManager.beginStreaming(
            stepID: sharedStepID, taskID: taskA, messageID: msgA, role: .softwareEngineer)
        sut.streamingPreviewManager.append(
            stepID: sharedStepID, taskID: taskA, messageID: msgA,
            role: .softwareEngineer, content: "A is thinking out loud")
        sut.streamingPreviewManager.markStreamActivity(stepID: sharedStepID, taskID: taskA)

        // Task B also registered (it is the one being paused).
        let runningB = Task { @MainActor in
            _ = try? await Task.sleep(for: .seconds(60))
        }
        sut.llmExecutionService._testInjectRunningTask(
            stepID: sharedStepID, taskID: taskB, runningTask: runningB)

        await sut.pauseRun(taskID: taskB)

        // Task B was torn down as requested.
        XCTAssertTrue(runningB.isCancelled)
        XCTAssertFalse(
            sut.llmExecutionService._testHasExecutionState(stepID: sharedStepID, taskID: taskB))

        // Task A — same team, same stepID — is untouched: no zombie "Working".
        XCTAssertFalse(
            runningA.isCancelled,
            "pauseRun(taskID: B) must not cancel task A's live execution on the shared stepID")
        XCTAssertTrue(
            sut.llmExecutionService._testHasExecutionState(stepID: sharedStepID, taskID: taskA),
            "Task A's executionStates entry must survive task B's pause")
        XCTAssertEqual(
            sut.streamingPreviewManager.streamingContent(stepID: sharedStepID, taskID: taskA),
            "A is thinking out loud",
            "Task A's streaming preview must survive task B's pause")
        XCTAssertTrue(
            sut.streamingPreviewManager.hasReceivedStreamActivity(stepID: sharedStepID, taskID: taskA),
            "Task A's Thinking/Processing indicator state must survive task B's pause")

        // Task A's step status was not flipped by B's pause cascade.
        await sut.ensureTaskLoaded(taskA)
        let stepA = sut.loadedTask(taskA)?.runs.last?.steps.first(where: { $0.id == sharedStepID })
        XCTAssertEqual(stepA?.status, .running, "Task A's step must stay .running through B's pause")

        runningA.cancel()
    }

    func testPauseRunOfOneTask_leavesOtherTasksStreamingClockForStuckDetector() async {
        await sut.openWorkFolder(tempDir)
        let taskA = await createTaskWithRunningStep(title: "Phase 39")
        let taskB = await createTaskWithRunningStep(title: "Phase 40")
        await sut.switchTask(to: taskA)

        sut.streamingPreviewManager.markStreamActivity(stepID: sharedStepID, taskID: taskA)

        await sut.pauseRun(taskID: taskB)

        XCTAssertNotNil(
            sut.streamingPreviewManager.lastStreamActivity(stepID: sharedStepID, taskID: taskA),
            "B's pause must not clear A's hang-detection clock (Autovisor stuck-detector input)")
        XCTAssertNil(
            sut.streamingPreviewManager.lastStreamActivity(stepID: sharedStepID, taskID: taskB),
            "B's own per-step stream state is cleared by its pause")
    }

    /// `correctRole` completes the role-control family: correcting task B's
    /// paused role (Branch B: feedback + revisionComment + auto-resume) must not
    /// touch task A's live execution, conversation, or streaming state on the
    /// shared stepID.
    func testCorrectRoleOnOneTask_doesNotTouchOtherTasksSameStep() async {
        await sut.openWorkFolder(tempDir)
        let taskA = await createTaskWithRunningStep(title: "Phase 39")
        let taskB = await createTaskWithRunningStep(title: "Phase 40", status: .paused)
        await sut.switchTask(to: taskA)

        let runningA = Task { @MainActor in
            _ = try? await Task.sleep(for: .seconds(60))
        }
        sut.llmExecutionService._testInjectRunningTask(
            stepID: sharedStepID, taskID: taskA, runningTask: runningA)
        sut.streamingPreviewManager.markStreamActivity(stepID: sharedStepID, taskID: taskA)
        sut.engineState[taskB] = .paused  // correctRole requires a paused engine

        await sut.correctRole(taskID: taskB, roleID: sharedStepID, comment: "take the other approach")

        // Precondition: the correction actually landed on B.
        let stepB = sut.loadedTask(taskB)?.runs.last?.steps.first(where: { $0.id == sharedStepID })
        XCTAssertEqual(stepB?.revisionComment, "take the other approach")

        // Task A is untouched: execution alive, no leaked feedback, indicator intact.
        XCTAssertFalse(runningA.isCancelled,
                       "correctRole(taskID: B) must not cancel task A's live execution")
        XCTAssertTrue(
            sut.llmExecutionService._testHasExecutionState(stepID: sharedStepID, taskID: taskA))
        let stepA = sut.loadedTask(taskA)?.runs.last?.steps.first(where: { $0.id == sharedStepID })
        XCTAssertNil(stepA?.revisionComment,
                     "B's revision gate must not leak onto A's same-named step")
        XCTAssertFalse(
            stepA?.messages.contains(where: { $0.content.contains("take the other approach") }) ?? true,
            "B's Supervisor feedback must not appear in A's step messages")
        XCTAssertTrue(
            sut.streamingPreviewManager.hasReceivedStreamActivity(stepID: sharedStepID, taskID: taskA),
            "A's streaming indicator state must survive B's correction")

        // Cleanup: correctRole auto-resumed B's run.
        await sut.pauseRun(taskID: taskB)
        runningA.cancel()
    }

    /// `finishAdvisoryRoleAwaiting` is another cancel entry point (Finish Role
    /// button / Autovisor `finish_advisory`) — finishing task B's role must not
    /// cancel task A's live execution on the shared stepID.
    func testFinishAdvisoryRoleOnOneTask_doesNotKillSameStepExecutionOfOtherTask() async {
        await sut.openWorkFolder(tempDir)
        let taskA = await createTaskWithRunningStep(title: "Phase 39")
        let taskB = await createTaskWithRunningStep(title: "Phase 40")
        await sut.switchTask(to: taskA)

        let runningA = Task { @MainActor in
            _ = try? await Task.sleep(for: .seconds(60))
        }
        let runningB = Task { @MainActor in
            _ = try? await Task.sleep(for: .seconds(60))
        }
        sut.llmExecutionService._testInjectRunningTask(
            stepID: sharedStepID, taskID: taskA, runningTask: runningA)
        sut.llmExecutionService._testInjectRunningTask(
            stepID: sharedStepID, taskID: taskB, runningTask: runningB)

        _ = await sut.finishAdvisoryRoleAwaiting(taskID: taskB, roleID: sharedStepID)

        XCTAssertTrue(runningB.isCancelled, "Precondition: B's own execution is cancelled by Finish Role")
        XCTAssertFalse(
            runningA.isCancelled,
            "finishAdvisoryRole(taskID: B) must not cancel task A's live execution on the shared stepID")
        XCTAssertTrue(
            sut.llmExecutionService._testHasExecutionState(stepID: sharedStepID, taskID: taskA))

        runningA.cancel()
    }

    /// `restartRole` is the other cancel entry point that iterates a COMPUTED role
    /// set (`rolesToReset` + downstream) — pin that restarting task B's role does
    /// not cancel task A's live execution on the shared stepID.
    func testRestartRoleOnOneTask_doesNotKillSameStepExecutionOfOtherTask() async {
        await sut.openWorkFolder(tempDir)
        let taskA = await createTaskWithRunningStep(title: "Phase 39")
        let taskB = await createTaskWithRunningStep(title: "Phase 40")
        await sut.switchTask(to: taskA)

        let runningA = Task { @MainActor in
            _ = try? await Task.sleep(for: .seconds(60))
        }
        sut.llmExecutionService._testInjectRunningTask(
            stepID: sharedStepID, taskID: taskA, runningTask: runningA)

        await sut.restartRole(taskID: taskB, roleID: sharedStepID, comment: nil)

        XCTAssertFalse(
            runningA.isCancelled,
            "restartRole(taskID: B) must not cancel task A's live execution on the shared stepID")
        XCTAssertTrue(
            sut.llmExecutionService._testHasExecutionState(stepID: sharedStepID, taskID: taskA))

        runningA.cancel()
    }
}

// MARK: - Post-teardown write barrier (isExecutionLive)

/// The deleted `taskIDForStep` guard doubled as the system's only post-teardown
/// write barrier: once a teardown path removed the executionStates entry, late
/// writes from the cooperatively-cancelled task's catch handlers silently no-op'd.
/// With explicit taskID threading that suppression must come from the
/// `isExecutionLive` gate — otherwise an orphan would write into whatever
/// currently answers to the captured taskID (a fresh run after a recurrence
/// supersede, or a same-numbered task in a newly opened work folder).
@MainActor
final class PostTeardownWriteBarrierTests: XCTestCase, @unchecked Sendable {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private let stepID = "test_step"
    private let taskID = 0

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)

        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "Step", status: .running)
        let run = Run(id: 0, steps: [step])
        mockDelegate.taskToMutate = NTMSTask(
            id: taskID, title: "T", supervisorTask: "G", runs: [run])
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        service = nil
        mockDelegate = nil
        try await super.tearDown()
    }

    func testPersistTokenUsage_afterTeardown_isDropped() async {
        // Live → write lands.
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        await service.persistTokenUsage(
            stepID: stepID, taskID: taskID, usage: TokenUsage(inputTokens: 10, outputTokens: 5))
        XCTAssertEqual(
            mockDelegate.taskToMutate?.runs.last?.steps.first?.tokenUsage?.inputTokens, 10,
            "Sanity: a LIVE execution's token usage must persist")

        // Torn down → orphan write is dropped, no mutation attempted.
        service.clearRunningTask(stepID: stepID, taskID: taskID)
        mockDelegate.eventLog.removeAll()
        await service.persistTokenUsage(
            stepID: stepID, taskID: taskID, usage: TokenUsage(inputTokens: 999, outputTokens: 999))

        XCTAssertTrue(
            mockDelegate.eventLog.isEmpty,
            "Post-teardown persistTokenUsage must be dropped by the liveness barrier — got \(mockDelegate.eventLog)")
        XCTAssertEqual(
            mockDelegate.taskToMutate?.runs.last?.steps.first?.tokenUsage?.inputTokens, 10,
            "Orphan token usage must not overwrite the persisted value")
    }

    func testAppendLLMMessage_afterTeardown_isDropped() async {
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        await service.appendLLMMessage(
            stepID: stepID, taskID: taskID, role: .assistant, content: "live turn")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs.last?.steps.first?.llmConversation.count, 1)

        service.clearRunningTask(stepID: stepID, taskID: taskID)
        await service.appendLLMMessage(
            stepID: stepID, taskID: taskID, role: .assistant, content: "orphan turn")

        XCTAssertEqual(
            mockDelegate.taskToMutate?.runs.last?.steps.first?.llmConversation.count, 1,
            "Post-teardown appendLLMMessage must not land — the orphan turn would pollute whatever task now answers to this id")
    }

    func testCompleteStepFailure_afterTeardown_doesNotFlipStepStatus() async {
        service.clearRunningTask(stepID: stepID, taskID: taskID)  // ensure not registered

        await service.completeStepFailure(
            stepID: stepID, taskID: taskID, errorMessage: "orphan failure")

        XCTAssertEqual(
            mockDelegate.taskToMutate?.runs.last?.steps.first?.status, .running,
            "An orphaned completeStepFailure must not flip a step it no longer owns")
    }
}

// MARK: - Streaming-snapshot keying (merged delegation timeline)

/// Pins `TeamActivityFeedView.makeStreamingSnapshot` reading under the bubble's
/// OWNING task id. In the merged delegation timeline a child task's bubble must
/// read the child's stream — a regression to the active task's id would compile
/// and silently blank out (or cross-wire) child-team streaming bubbles.
@MainActor
final class StreamingSnapshotKeyingTests: XCTestCase, @unchecked Sendable {

    private var manager: StreamingPreviewManager!
    private let stepID = "startup_software_engineer"

    override func setUp() async throws {
        try await super.setUp()
        manager = StreamingPreviewManager()
    }

    override func tearDown() async throws {
        manager = nil
        try await super.tearDown()
    }

    func testSnapshot_readsUnderOwningTaskID_notTheOtherTasks() async {
        let parentTask = 1
        let childTask = 2
        let msgParent = UUID()
        let msgChild = UUID()

        manager.beginStreaming(stepID: stepID, taskID: parentTask, messageID: msgParent, role: .softwareEngineer)
        manager.append(stepID: stepID, taskID: parentTask, messageID: msgParent,
                       role: .softwareEngineer, content: "parent stream")
        manager.beginStreaming(stepID: stepID, taskID: childTask, messageID: msgChild, role: .softwareEngineer)
        manager.append(stepID: stepID, taskID: childTask, messageID: msgChild,
                       role: .softwareEngineer, content: "child stream")
        manager.markStreamActivity(stepID: stepID, taskID: childTask)

        let childSnapshot = TeamActivityFeedView.makeStreamingSnapshot(
            manager: manager, messageID: msgChild, stepID: stepID, taskID: childTask)
        XCTAssertEqual(childSnapshot.content, "child stream")
        XCTAssertTrue(childSnapshot.isStreaming)
        XCTAssertTrue(childSnapshot.hasStreamActivity)

        let parentSnapshot = TeamActivityFeedView.makeStreamingSnapshot(
            manager: manager, messageID: msgParent, stepID: stepID, taskID: parentTask)
        XCTAssertEqual(
            parentSnapshot.content, "parent stream",
            "Parent bubble must not pick up the child's stream on the shared stepID")
        XCTAssertFalse(
            parentSnapshot.hasStreamActivity,
            "Child's activity flag must not leak into the parent's snapshot")
    }

    /// The non-content snapshot fields (Processing %, tool-call assembly flag,
    /// thinking) drive the indicator — each must read under its own task too.
    func testSnapshot_progressToolCallAndThinking_keyedPerTask() async {
        let parentTask = 1
        let childTask = 2
        let msgParent = UUID()
        let msgChild = UUID()
        manager.beginStreaming(stepID: stepID, taskID: parentTask, messageID: msgParent, role: .softwareEngineer)
        manager.beginStreaming(stepID: stepID, taskID: childTask, messageID: msgChild, role: .softwareEngineer)

        manager.updateProcessingStatus(stepID: stepID, taskID: parentTask, status: .fraction(0.4))
        manager.markStreamingToolCall(stepID: stepID, taskID: childTask)
        manager.appendThinking(stepID: stepID, taskID: childTask, content: "child reasons")

        let parent = TeamActivityFeedView.makeStreamingSnapshot(
            manager: manager, messageID: msgParent, stepID: stepID, taskID: parentTask)
        let child = TeamActivityFeedView.makeStreamingSnapshot(
            manager: manager, messageID: msgChild, stepID: stepID, taskID: childTask)

        XCTAssertEqual(parent.processingStatus, .fraction(0.4))
        XCTAssertNil(child.processingStatus, "Parent's Processing % must not render on the child bubble")
        XCTAssertTrue(child.isStreamingToolCall)
        XCTAssertFalse(parent.isStreamingToolCall, "Child's tool-call assembly must not animate the parent bubble")
        XCTAssertEqual(child.thinking, "child reasons")
        XCTAssertNil(parent.thinking)
    }
}

// MARK: - TaskStepKey identity corners

final class TaskStepKeyTests: XCTestCase {

    /// Pins the STRUCTURAL key against a "simplification" to string concatenation:
    /// `"\(taskID)\(stepID)"` would collide (12, "3") with (1, "23") — the exact
    /// ambiguity class a composite key exists to prevent.
    func testNoConcatenationAmbiguity_betweenTaskIDAndStepID() {
        let a = TaskStepKey(taskID: 12, stepID: "3")
        let b = TaskStepKey(taskID: 1, stepID: "23")
        XCTAssertNotEqual(a, b)

        var set: Set<TaskStepKey> = [a]
        XCTAssertFalse(set.contains(b))
        set.insert(b)
        XCTAssertEqual(set.count, 2, "Both keys must occupy distinct dictionary slots")
    }

    func testSamePair_isEqualAndHashesIdentically() {
        let a = TaskStepKey(taskID: 39, stepID: "startup_software_engineer")
        let b = TaskStepKey(taskID: 39, stepID: "startup_software_engineer")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, TaskStepKey(taskID: 40, stepID: "startup_software_engineer"))
        XCTAssertNotEqual(a, TaskStepKey(taskID: 39, stepID: "startup_tech_lead"))
    }
}

// MARK: - Post-teardown write barrier: cross-task and lifecycle corners

/// The barrier itself must be keyed per (taskID, stepID) — a stepID-scoped barrier
/// would reintroduce the very collision the refactor fixed (task A's teardown
/// silencing task B's live writes on the shared stepID).
@MainActor
final class PostTeardownWriteBarrierCornerTests: XCTestCase, @unchecked Sendable {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private let stepID = "startup_software_engineer"
    private let taskA = 0
    private let taskB = 1

    /// No-op stream client for collaboration-handler early-return tests — the
    /// liveness guard must reject before any LLM call is attempted.
    private final class SilentClient: LLMClient, @unchecked Sendable {
        func streamChat(
            config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
            logger _: NetworkLogger?, stepID _: String?, roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        service = nil
        mockDelegate = nil
        try await super.tearDown()
    }

    private func makeTask(id: Int) -> NTMSTask {
        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "Step", status: .running)
        let run = Run(id: 0, steps: [step])
        return NTMSTask(id: id, title: "T\(id)", supervisorTask: "G", runs: [run])
    }

    private func stubConfig() -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://localhost", modelName: "stub")
    }

    func testTeardownOfOneTask_doesNotBlockOtherTasksWrites_onSharedStepID() async {
        mockDelegate.taskToMutate = makeTask(id: taskB)
        service._testRegisterStepTask(stepID: stepID, taskID: taskA)
        service._testRegisterStepTask(stepID: stepID, taskID: taskB)

        service.clearRunningTask(stepID: stepID, taskID: taskA)

        // Task B's write still lands — the barrier is per (taskID, stepID).
        await service.appendLLMMessage(
            stepID: stepID, taskID: taskB, role: .assistant, content: "B is alive")
        XCTAssertEqual(
            mockDelegate.taskToMutate?.runs.last?.steps.first?.llmConversation.count, 1,
            "Tearing down task A must not silence task B's live writes on the shared stepID")

        // Task A's orphan write is dropped without even attempting a mutation.
        let eventsBefore = mockDelegate.eventLog
        await service.appendLLMMessage(
            stepID: stepID, taskID: taskA, role: .assistant, content: "A orphan")
        XCTAssertEqual(mockDelegate.eventLog, eventsBefore,
                       "Task A's orphan write must be dropped before mutateTask")
    }

    /// restartRole re-registers the step — the barrier must reopen, not stay sticky.
    func testReRegisterAfterTeardown_reopensWrites() async {
        mockDelegate.taskToMutate = makeTask(id: taskA)
        service._testRegisterStepTask(stepID: stepID, taskID: taskA)
        service.clearRunningTask(stepID: stepID, taskID: taskA)

        await service.appendLLMMessage(
            stepID: stepID, taskID: taskA, role: .assistant, content: "orphan")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs.last?.steps.first?.llmConversation.count, 0)

        service._testRegisterStepTask(stepID: stepID, taskID: taskA)
        await service.appendLLMMessage(
            stepID: stepID, taskID: taskA, role: .assistant, content: "fresh run turn")
        XCTAssertEqual(
            mockDelegate.taskToMutate?.runs.last?.steps.first?.llmConversation.count, 1,
            "Re-registration (restartRole / fresh run) must reopen the write path")
    }

    func testSetNeedsSupervisorInput_crossTask_onlyLiveTaskFiresBackstop() async {
        mockDelegate.taskToMutate = makeTask(id: taskB)
        service._testRegisterStepTask(stepID: stepID, taskID: taskA)
        service._testRegisterStepTask(stepID: stepID, taskID: taskB)
        service.clearRunningTask(stepID: stepID, taskID: taskA)

        let orphanResult = await service.setNeedsSupervisorInput(
            stepID: stepID, taskID: taskA, question: "orphan Q")
        XCTAssertFalse(orphanResult)
        XCTAssertTrue(mockDelegate.notifyQueuedMessageBackstopCalls.isEmpty,
                      "Torn-down task A must not fire the auto-resuming backstop")

        let liveResult = await service.setNeedsSupervisorInput(
            stepID: stepID, taskID: taskB, question: "live Q")
        XCTAssertTrue(liveResult)
        XCTAssertEqual(mockDelegate.notifyQueuedMessageBackstopCalls, [taskB],
                       "Live task B on the same stepID must keep its backstop")
    }

    /// One sweep over the remaining gated leaf writers: none may reach `mutateTask`
    /// after teardown.
    func testAllGatedLeafWriters_afterTeardown_attemptNoMutation() async {
        mockDelegate.taskToMutate = makeTask(id: taskA)
        service._testRegisterStepTask(stepID: stepID, taskID: taskA)
        service.clearRunningTask(stepID: stepID, taskID: taskA)
        mockDelegate.eventLog.removeAll()

        await service.persistWireTranscript(
            stepID: stepID, taskID: taskA,
            messages: [ChatMessage(role: .user, content: "orphan transcript")])
        await service.updateScratchpad(stepID: stepID, taskID: taskA, content: "orphan plan")
        await service.appendToolCalls(stepID: stepID, taskID: taskA, toolCalls: [
            StepToolCall(name: "read_file", argumentsJSON: "{}")
        ])
        await service.updateToolCallResult(
            stepID: stepID, taskID: taskA, toolCallID: UUID(),
            result: ToolExecutionResult(
                providerID: nil, toolName: "read_file", argumentsJSON: "{}",
                outputJSON: "{}", isError: false))
        await service.saveLLMConversation(stepID: stepID, taskID: taskA, messages: [
            ChatMessage(role: .user, content: "orphan")
        ])
        await service.recordConsultation(
            stepID: stepID, taskID: taskA,
            consultation: TeammateConsultation(
                requestingRole: .softwareEngineer, consultedRole: .techLead, question: "q"))
        await service.recordAutoSupervisorAnswer(
            stepID: stepID, taskID: taskA, question: "q", answer: "a")

        XCTAssertTrue(
            mockDelegate.eventLog.isEmpty,
            "No gated leaf writer may attempt a mutation post-teardown — got \(mockDelegate.eventLog)")
    }

    /// `saveConsultationChat` persists mid-consultation/meeting state — an
    /// orphaned save after the executing step's teardown must be dropped
    /// (same barrier class as commitStreamingContent).
    func testSaveConsultationChat_afterTeardown_isDropped() async {
        mockDelegate.taskToMutate = makeTask(id: taskA)
        service._testRegisterStepTask(stepID: stepID, taskID: taskA)

        // Live → the save lands.
        let chat = RoleConsultationChat(id: "tech_lead", messages: [])
        await service.saveConsultationChat(
            stepID: stepID, taskID: taskA, runIndex: 0, roleID: "tech_lead", chat: chat)
        XCTAssertNotNil(
            mockDelegate.taskToMutate?.runs.first?.consultationChats["tech_lead"],
            "Sanity: a LIVE execution's consultation chat must persist")

        // Torn down → the orphan save is dropped before any mutation attempt.
        service.clearRunningTask(stepID: stepID, taskID: taskA)
        mockDelegate.eventLog.removeAll()
        var orphan = RoleConsultationChat(id: "sre", messages: [])
        orphan.messages.append(LLMMessage(role: .user, content: "orphan turn"))
        await service.saveConsultationChat(
            stepID: stepID, taskID: taskA, runIndex: 0, roleID: "sre", chat: orphan)

        XCTAssertTrue(mockDelegate.eventLog.isEmpty,
                      "Post-teardown saveConsultationChat must be dropped by the liveness barrier")
        XCTAssertNil(mockDelegate.taskToMutate?.runs.first?.consultationChats["sre"])
    }

    /// The exploratory-search finalizer completes ASYNC after tool execution —
    /// when the step was torn down in the meantime, its envelope/tool-call
    /// writes must be dropped by the barrier-gated leaves it calls.
    func testExploratorySearchFinalizer_afterTeardown_attemptsNoMutation() async {
        mockDelegate.taskToMutate = makeTask(id: taskA)
        service._testRegisterStepTask(stepID: stepID, taskID: taskA)
        service.clearRunningTask(stepID: stepID, taskID: taskA)
        mockDelegate.eventLog.removeAll()

        let payload = try! ExploratorySearchPayload(
            query: "collision", mode: .substring, paths: nil, fileGlob: nil,
            contextBefore: 0, contextAfter: 0, maxResults: 20)
        let result = ToolExecutionResult(
            providerID: nil, toolName: ToolNames.search,
            argumentsJSON: #"{"query":"collision","exploratory":true}"#,
            outputJSON: #"{"ok":true,"data":{"status":"exploring"}}"#,
            isError: false, signal: .exploratorySearch(payload))
        var conversation: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: result, toolCallID: UUID(), stepID: stepID, taskID: taskA,
            conversationMessages: &conversation)

        XCTAssertTrue(
            mockDelegate.eventLog.isEmpty,
            "An exploratory finalizer landing after teardown must not mutate the task — got \(mockDelegate.eventLog)")
    }

    /// The vision finalizer mirrors the exploratory one: its analyze call resolves
    /// async (here: instantly, via the not-configured error path) and its
    /// envelope/conversation writes must be dropped by the gated leaves when the
    /// step was torn down in the meantime.
    func testVisionFinalizer_afterTeardown_attemptsNoMutation() async {
        mockDelegate.taskToMutate = makeTask(id: taskA)
        service._testRegisterStepTask(stepID: stepID, taskID: taskA)
        service.clearRunningTask(stepID: stepID, taskID: taskA)
        mockDelegate.eventLog.removeAll()

        let result = ToolExecutionResult(
            providerID: nil, toolName: ToolNames.analyzeImage,
            argumentsJSON: #"{"path":"img.png","prompt":"describe"}"#,
            outputJSON: #"{"ok":true,"data":{"status":"analyzing"}}"#,
            isError: false, signal: .visionAnalysis(imagePath: "img.png", prompt: "describe"))
        var conversation: [ChatMessage] = []
        await service.appendVisionResult(
            result: result, toolCallID: UUID(), stepID: stepID, taskID: taskA,
            client: SilentClient(), config: stubConfig(), networkLogger: nil,
            conversationMessages: &conversation)

        XCTAssertTrue(
            mockDelegate.eventLog.isEmpty,
            "A vision finalizer landing after teardown must not mutate the task — got \(mockDelegate.eventLog)")
    }

    func testCollaborationHandlers_notLive_rejectBeforeAnyWork() async {
        let task = makeTask(id: taskA)
        mockDelegate.taskToMutate = task
        // Deliberately NOT registered.

        let consult = await service.handleTeammateConsultation(
            stepID: stepID, consultedRoleID: "tech_lead", question: "q", context: nil,
            requestingRole: .softwareEngineer, task: task, runIndex: 0, stepIndex: 0,
            client: SilentClient(), config: stubConfig())
        XCTAssertTrue(consult.text.contains("no task context"), "got: \(consult.text)")
        XCTAssertFalse(consult.succeeded, "rejected consultation must report failure")

        let meeting = await service.handleTeamMeeting(
            stepID: stepID, topic: "t", participantIDs: [], context: nil,
            initiatingRole: .softwareEngineer, task: task, runIndex: 0, stepIndex: 0,
            client: SilentClient(), config: stubConfig())
        XCTAssertTrue(meeting.text.contains("no task context"), "got: \(meeting.text)")
        XCTAssertFalse(meeting.succeeded, "rejected meeting must report failure")

        let change = await service.handleChangeRequest(
            stepID: stepID, targetRoleID: "tech_lead", changes: "c", reasoning: "r",
            requestingRole: .softwareEngineer, task: task, runIndex: 0, stepIndex: 0,
            client: SilentClient(), config: stubConfig())
        XCTAssertTrue(change.text.contains("no task context"), "got: \(change.text)")
        XCTAssertFalse(change.succeeded, "rejected change request must report failure")

        XCTAssertTrue(mockDelegate.eventLog.isEmpty,
                      "Rejected collaboration handlers must not have mutated anything")
    }

    func testHandleWaitForEvents_wrongTaskID_isRejected() async {
        service._testRegisterStepTask(stepID: stepID, taskID: taskA)

        let envelope = await service.handleWaitForEvents(stepID: stepID, taskID: 99)

        XCTAssertTrue(envelope.contains("\"ok\":false") || envelope.contains("no longer running"),
                      "wait_for_events under a foreign taskID must fail loudly; got: \(envelope)")
        XCTAssertFalse(service._testParkForEventsRequested(stepID: stepID, taskID: taskA),
                       "The other task's park flag must stay untouched")
    }
}

// MARK: - Orphaned stream commit drop (real performStreamingCall path)

/// Drives the REAL streaming pipeline into the orphan scenario from the production
/// audit: the entry is torn down by a bulk cancel (`cancelExecutions(forTaskID:)`,
/// which does NOT await the stream) while the stream is still flowing — the final
/// `commitStreamingContent()` must be dropped by the barrier instead of landing on
/// whatever now answers to the captured taskID.
@MainActor
final class OrphanStreamCommitDropTests: XCTestCase, @unchecked Sendable {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    /// Resumable gate: the scripted stream yields one delta, suspends here until
    /// the test tears the execution down, then finishes normally.
    @MainActor
    private final class AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class GatedClient: LLMClient, @unchecked Sendable {
        let gate: AsyncGate
        init(gate: AsyncGate) { self.gate = gate }
        func streamChat(
            config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
            logger _: NetworkLogger?, stepID _: String?, roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let gate = gate
            return AsyncThrowingStream { continuation in
                Task {
                    continuation.yield(StreamEvent(contentDelta: "partial content from a dying stream"))
                    await gate.wait()
                    continuation.finish()
                }
            }
        }
        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        service = nil
        mockDelegate = nil
        try await super.tearDown()
    }

    func testBulkCancelMidStream_dropsTheFinalCommit() async throws {
        let stepID = "startup_software_engineer"
        let taskID = 39
        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "Step", status: .running)
        mockDelegate.taskToMutate = NTMSTask(
            id: taskID, title: "T", supervisorTask: "G", runs: [Run(id: 0, steps: [step])])
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)

        let gate = AsyncGate()
        let config = LLMConfig(
            provider: .lmStudio, baseURLString: "http://localhost",
            modelName: "stub")
        let weakService = service!
        let streamTask = Task { @MainActor in
            try await weakService.performStreamingCall(
                stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
                client: GatedClient(gate: gate), config: config,
                tools: [], conversationMessages: [], networkLogger: nil)
        }

        // Wait until the delta has been observed (markStreamActivity fires on every
        // content delta immediately — unlike appendStreamingPreview, which sits in
        // the 200-char/0.2s UI flush buffer until commit).
        var spins = 0
        while mockDelegate.markStreamActivityCalls.isEmpty && spins < 20_000 {
            spins += 1
            await Task.yield()
        }
        XCTAssertFalse(mockDelegate.markStreamActivityCalls.isEmpty,
                       "Precondition: the stream must have delivered its delta")

        // Bulk teardown (does NOT await the stream) — the orphan window opens.
        service.cancelExecutions(forTaskID: taskID)
        gate.open()

        let result = try await streamTask.value

        XCTAssertEqual(result.assistantContent, "partial content from a dying stream",
                       "The call still returns its collected content to the (dying) loop")
        XCTAssertTrue(
            mockDelegate.commitStreamingCalls.isEmpty,
            "The orphaned stream's final commit must be dropped by the liveness barrier — landing it would write into whatever now answers to taskID \(taskID)")
    }
}

// MARK: - Generated-team delegation: parent torn down mid-generation

/// `delegate_to_team(team_id: "generated")` holds a LONG await inside
/// `TeamGenerationService.generate`. If the parent is torn down during that
/// await, the handler must NOT spawn a child task for the dead parent and must
/// NOT flip the placeholder tool call on whatever now answers to the captured
/// parent taskID.
@MainActor
final class DelegationGenerationTeardownTests: XCTestCase, @unchecked Sendable {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private let stepID = "delegator"
    private let taskID = 5

    @MainActor
    private final class AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Stalls at the gate mid-generation, then either throws or emits a valid
    /// `create_team` flat-config JSON as content.
    private final class GatedGenerationClient: LLMClient, @unchecked Sendable {
        enum Outcome { case fail, succeed }
        let gate: AsyncGate
        let outcome: Outcome
        init(gate: AsyncGate, outcome: Outcome) {
            self.gate = gate
            self.outcome = outcome
        }
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "stub generation failure" }
        }
        func streamChat(
            config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
            logger _: NetworkLogger?, stepID _: String?, roleName _: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let gate = gate
            let outcome = outcome
            return AsyncThrowingStream { continuation in
                Task {
                    await gate.wait()
                    switch outcome {
                    case .fail:
                        continuation.finish(throwing: StubError())
                    case .succeed:
                        let config = #"{"name":"GenT","description":"d","roles":[{"name":"Eng","prompt":"p","produces_artifacts":["X"],"requires_artifacts":["Supervisor Task"],"tools":[]}],"artifacts":[{"name":"X","description":"d"}],"supervisor_requires":["X"]}"#
                        continuation.yield(StreamEvent(contentDelta: "```json\n" + config + "\n```"))
                        continuation.finish()
                    }
                }
            }
        }
        func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
    }

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        service = nil
        mockDelegate = nil
        try await super.tearDown()
    }

    /// Parent task whose generated team contains a top-level delegator role
    /// allowed to spawn generated teams.
    private func makeParentTask() -> NTMSTask {
        let delegator = TeamRoleDefinition(
            id: stepID, name: "Delegator", prompt: "d",
            toolIDs: [ToolNames.delegateToTeam], usePlanningPhase: false,
            dependencies: RoleDependencies(),
            allowDelegationToGeneratedTeams: true
        )
        let team = Team(
            name: "Parent Team",
            roles: [delegator],
            artifacts: [],
            settings: .default,
            graphLayout: TeamGraphLayout()
        )
        let step = StepExecution(id: stepID, role: .custom(id: stepID), title: "Step", status: .running)
        var task = NTMSTask(id: taskID, title: "Parent", supervisorTask: "G", runs: [Run(id: 0, steps: [step])])
        task.adoptGeneratedTeam(team)
        return task
    }

    private func stubConfig() -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://localhost", modelName: "stub")
    }

    private func runHandler(client: GatedGenerationClient, task: NTMSTask) async -> Task<String, Never> {
        let service = service!
        let stepID = stepID
        return Task { @MainActor in
            await service.handleDelegateToTeam(
                stepID: stepID,
                teamIDRaw: DelegationConstants.generatedTeamSentinel,
                taskBrief: "build a thing",
                initiatingRole: .custom(id: stepID),
                task: task,
                runIndex: 0,
                stepIndex: 0,
                client: client,
                config: stubConfig())
        }
    }

    func testGenerationSucceedsAfterParentTeardown_bailsWithoutChildOrFlip() async {
        let task = makeParentTask()
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        mockDelegate.createDelegatedTaskStub = 99  // would be used if the handler proceeded

        let gate = AsyncGate()
        let handler = await runHandler(client: GatedGenerationClient(gate: gate, outcome: .succeed), task: task)

        // Let the handler append its placeholder and enter the generation await.
        var spins = 0
        while mockDelegate.taskToMutate?.runs.first?.steps.first?.toolCalls.isEmpty != false && spins < 20_000 {
            spins += 1
            await Task.yield()
        }
        let mutationsBeforeTeardown = mockDelegate.eventLog.count

        // Parent torn down mid-generation, then generation completes successfully.
        service.cancelExecutions(forTaskID: taskID)
        gate.open()
        let envelope = await handler.value

        XCTAssertTrue(envelope.contains("torn down during team generation"),
                      "Handler must bail when the parent died mid-generation; got: \(envelope)")
        XCTAssertTrue(mockDelegate.createdDelegatedTaskRequests.isEmpty,
                      "No child task may be spawned for a dead parent")
        XCTAssertEqual(mockDelegate.eventLog.count, mutationsBeforeTeardown,
                       "No placeholder flip may land post-teardown — got \(mockDelegate.eventLog)")
    }

    func testGenerationFailsAfterParentTeardown_errorFlipIsDropped() async {
        let task = makeParentTask()
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)

        let gate = AsyncGate()
        let handler = await runHandler(client: GatedGenerationClient(gate: gate, outcome: .fail), task: task)

        var spins = 0
        while mockDelegate.taskToMutate?.runs.first?.steps.first?.toolCalls.isEmpty != false && spins < 20_000 {
            spins += 1
            await Task.yield()
        }
        let mutationsBeforeTeardown = mockDelegate.eventLog.count

        service.cancelExecutions(forTaskID: taskID)
        gate.open()
        let envelope = await handler.value

        XCTAssertTrue(envelope.contains("\"ok\":false"),
                      "Failure envelope still returns to the (dying) loop; got: \(envelope)")
        XCTAssertEqual(mockDelegate.eventLog.count, mutationsBeforeTeardown,
                       "The error flip must be dropped by the liveness barrier post-teardown")
        XCTAssertTrue(mockDelegate.createdDelegatedTaskRequests.isEmpty)
    }
}

