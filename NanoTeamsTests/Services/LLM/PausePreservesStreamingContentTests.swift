import XCTest

@testable import NanoTeams

/// Regression tests for the pause→partial-content-preservation fix.
///
/// Before the fix, `cancelStepExecution` was synchronous and tore down `executionStates`
/// + the streaming preview manager *before* the cancelled task's `catch is CancellationError`
/// handler had a chance to run. The handler calls `commitStreamingContent()` →
/// `delegate.commitStreaming(...)`, whose liveness barrier (then `taskIDForStep`,
/// now `isExecutionLive`) saw a torn-down entry and silently dropped
/// `assistantCollected` / `thinkingCollected`.
///
/// The fix awaits `runningTask.value` between cancellation and teardown. These tests
/// pin that contract by injecting a stub running task that mimics the streaming
/// catch handler.
@MainActor
final class PausePreservesStreamingContentTests: XCTestCase, @unchecked Sendable {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        service = nil
        mockDelegate = nil
        try await super.tearDown()
    }

    // MARK: - Contract: cancelStepExecution awaits the catch handler

    func testCancelStepExecution_awaitsCatchHandlerBeforeTeardown() async {
        let stepID = "step-await-catch"
        let taskID = 42

        // `MainActorFlag` is `@MainActor`-isolated so the running task's catch
        // handler can record completion (also @MainActor) and the test can read it
        // safely under Swift 6 isolation checking.
        let flag = MainActorFlag()

        // Mimic the streaming catch handler: suspend until cancelled, then run a
        // small bounded handler that flips the flag.
        let runningTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                flag.value = true
            } catch {
                // ignore
            }
        }

        service._testInjectRunningTask(stepID: stepID, taskID: taskID, runningTask: runningTask)
        XCTAssertTrue(service._testHasExecutionState(stepID: stepID, taskID: taskID))

        // BEFORE the fix this returned synchronously — flag would still be false.
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)

        XCTAssertTrue(
            flag.value,
            "cancelStepExecution must not return until the cancelled task's catch handler runs"
        )
        XCTAssertFalse(
            service._testHasExecutionState(stepID: stepID, taskID: taskID),
            "executionStates entry must be cleared after cancellation completes"
        )
    }

    // MARK: - Contract: the (taskID, stepID) execution state stays alive through the catch handler

    func testCancelStepExecution_keepsExecutionStateAliveUntilCatchHandlerCompletes() async {
        let stepID = "step-task-id-lookup"
        let taskID = 7

        // Capture the taskID lookup result FROM INSIDE the cancellation handler.
        // Before the fix, executionStates was wiped before the handler ran, so this
        // would be nil (causing the real `commitStreamingContent` and
        // `persistTokenUsage` to no-op).
        let observed = ObservedTaskID()
        let weakService = service!

        let runningTask = Task { @MainActor [weak weakService] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                // `taskIDForStep` no longer exists (executionStates is keyed by
                // TaskStepKey); the equivalent liveness probe is whether the
                // (stepID, taskID) execution state still exists mid-handler.
                observed.value = weakService?._testHasExecutionState(stepID: stepID, taskID: taskID) == true
                    ? taskID : nil
            } catch {
                // ignore
            }
        }

        service._testInjectRunningTask(stepID: stepID, taskID: taskID, runningTask: runningTask)

        await service.cancelStepExecution(stepID: stepID, taskID: taskID)

        XCTAssertEqual(
            observed.value, taskID,
            "Catch handler must see live executionStates for its (taskID, stepID) key — this is what unblocks commitStreamingContent and persistTokenUsage on cancellation"
        )
    }

    // MARK: - Contract: clearStreamingPreview still fires after teardown

    func testCancelStepExecution_clearsStreamingPreviewAfterAwaiting() async {
        let stepID = "step-preview-clear"
        let taskID = 99

        let runningTask = Task<Void, Never> { @MainActor in
            do { try await Task.sleep(for: .seconds(30)) }
            catch { /* ignore */ }
        }

        service._testInjectRunningTask(stepID: stepID, taskID: taskID, runningTask: runningTask)

        XCTAssertFalse(mockDelegate.clearStreamingPreviewCalls.contains(stepID))
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)
        XCTAssertTrue(mockDelegate.clearStreamingPreviewCalls.contains(stepID))
    }

    // MARK: - Defensive: edge inputs to cancelStepExecution

    /// Cancelling a step that never ran (no `executionStates` entry) must be a safe
    /// no-op: no crash, no error banner. Defensive — callers like `pauseRun` iterate
    /// steps and may legitimately invoke `cancelStepExecution` on an already-finished
    /// or never-started step.
    func testCancelStepExecution_unknownStepID_doesNotCrashOrSetError() async {
        await service.cancelStepExecution(stepID: "never-existed", taskID: 0)
        XCTAssertTrue(
            mockDelegate.lastErrorMessages.isEmpty,
            "Cancelling unknown stepID must not surface an error banner — got: \(mockDelegate.lastErrorMessages)"
        )
        XCTAssertFalse(service._testHasExecutionState(stepID: "never-existed", taskID: 0))
    }

    /// LLM completes naturally just before user clicks Pause: the `runningTask` is
    /// already finished. `await runningTask.value` must return immediately (well
    /// under the 3s timeout) and no error banner should appear.
    func testCancelStepExecution_alreadyFinishedTask_completesQuicklyWithoutError() async {
        let stepID = "step-already-finished"
        let taskID = 21

        let runningTask = Task<Void, Never> { /* completes immediately */ }
        await runningTask.value  // ensure it's truly finished before injection

        service._testInjectRunningTask(stepID: stepID, taskID: taskID, runningTask: runningTask)

        let start = Date()
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, 0.5,
            "Cancelling an already-finished task must complete quickly (no timeout wait) — elapsed \(elapsed)s"
        )
        XCTAssertTrue(
            mockDelegate.lastErrorMessages.isEmpty,
            "Already-finished task must not trigger the timeout banner"
        )
    }

    /// Two concurrent `cancelStepExecution` calls for the same step. Both should
    /// complete cleanly — `executionStates` cleared exactly once, `clearStreamingPreview`
    /// idempotent. Pins the silent-failure-hunter review's claim that the new async
    /// path is safe under concurrent invocation (e.g., `pauseRun` racing with
    /// `restartRole` for a shared step).
    func testCancelStepExecution_concurrentCalls_completeSafelyAndIdempotently() async {
        let stepID = "step-concurrent-cancel"
        let taskID = 33

        let signal = ManualSignal()
        let runningTask = Task<Void, Never> { @MainActor in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                // Tiny work in catch handler so both racers actually wait for it.
                signal.fire()
            } catch { /* ignore */ }
        }

        service._testInjectRunningTask(stepID: stepID, taskID: taskID, runningTask: runningTask)

        // Two concurrent cancels.
        async let a: Void = service.cancelStepExecution(stepID: stepID, taskID: taskID)
        async let b: Void = service.cancelStepExecution(stepID: stepID, taskID: taskID)
        _ = await (a, b)

        XCTAssertTrue(signal.fired, "Catch handler must have run at least once")
        XCTAssertFalse(
            service._testHasExecutionState(stepID: stepID, taskID: taskID),
            "executionStates must be cleared after concurrent cancels"
        )
        // `clearStreamingPreview` is called by both cancels — idempotent. Verify
        // that's the only side-effect duplication (no spurious error banner).
        XCTAssertTrue(
            mockDelegate.lastErrorMessages.isEmpty,
            "Concurrent cancels must not surface a timeout banner — got: \(mockDelegate.lastErrorMessages)"
        )
    }

    // MARK: - Helper: awaitTaskWithTimeout / OnceResolver

    /// Success path of `awaitTaskWithTimeout` — task finishes before the timeout.
    /// The previous timeout-firing test only proved the failure path; if `OnceResolver`
    /// were inverted ("returns true after first call to deny") the function would
    /// always return false and `cancelStepExecution` would *always* surface a
    /// timeout banner in production. This test guards the inverse.
    func testAwaitTaskWithTimeout_returnsTrueWhenTaskFinishesBeforeDeadline() async {
        let task = Task<Void, Never> {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let finished = await LLMExecutionService.awaitTaskWithTimeout(task, seconds: 1.0)
        XCTAssertTrue(finished, "Task that completes before the timeout must report finished=true")
    }

    /// `awaitTaskWithTimeout` returns false when the timeout wins. Already covered
    /// indirectly by `testCancelStepExecution_timesOutWhenCatchHandlerHangs` but pinned
    /// here in isolation so the helper's contract is regression-protected even if
    /// the cancel-step plumbing changes.
    func testAwaitTaskWithTimeout_returnsFalseWhenTaskExceedsDeadline() async {
        let task = Task<Void, Never> { @MainActor in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
                // Never resume — task hangs indefinitely.
            }
        }
        let start = Date()
        let finished = await LLMExecutionService.awaitTaskWithTimeout(task, seconds: 0.3)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(finished, "Hung task must report finished=false when deadline elapses")
        XCTAssertLessThan(elapsed, 1.0, "Helper must respect the timeout, not wait forever — elapsed \(elapsed)s")
    }

    /// `OnceResolver.tryResolve` must return `true` exactly once across any number
    /// of concurrent calls. Direct unit test — if this primitive breaks, every
    /// `awaitTaskWithTimeout` could double-resume the continuation and crash.
    func testOnceResolver_resolvesExactlyOnceUnderConcurrency() async {
        let resolver = OnceResolver()
        let resultCount = ResultCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    if resolver.tryResolve() {
                        await resultCount.increment()
                    }
                }
            }
        }

        let count = await resultCount.value
        XCTAssertEqual(count, 1, "OnceResolver must allow exactly one tryResolve to win — got \(count)")
    }

    // MARK: - User-facing: real streaming pipeline + cancellation persists partial content

    /// Drives the actual streaming pipeline (`startStepExecution` → stub `LLMClient` → real
    /// `performStreamingCall` → cancellation catch handler) and verifies the task's step
    /// ends up with the partial assistant message — what the user would see in the
    /// activity feed after clicking Pause.
    func testStartStepExecution_thenCancel_writesPartialContentToStep() async throws {
        let stepID = "user_facing_step_content"
        let taskID = 1

        let initialTask = makeTaskWithRunningStep(taskID: taskID, stepID: stepID)
        let mock = StreamPersistingMockDelegate()
        mock.workFolderURL = tempDir
        mock.taskToMutate = initialTask

        let stubClient = StreamingStubLLMClient(
            thinkingChunks: [],
            contentChunks: ["Let me ", "think about ", "this carefully."]
        )
        let service = LLMExecutionService(
            repository: NTMSRepository(),
            clientFactory: { stubClient }
        )
        service.attach(delegate: mock)

        // Kick off the streaming call.
        service.startStepExecution(
            stepID: stepID, taskID: taskID,
            task: initialTask, runIndex: 0, stepIndex: 0)

        // Wait until content actually arrives. `markStreamActivity` fires on every
        // content delta — `appendStreamingPreview` may not, because the streaming
        // pipeline buffers small content into `pendingUI` (capped by
        // `LLMConstants.uiFlushCharThreshold` and a time window). The buffered
        // content still ends up in `assistantCollected` via the forced flush inside
        // `commitStreamingContent` on cancellation, so we just need to confirm the
        // stream is live before pausing.
        try await waitUntil {
            !mock.markStreamActivityCalls.isEmpty
        }

        // User clicks Pause.
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)

        // What the user would see in the activity feed: a regular assistant bubble
        // containing the partial content the model emitted before pause.
        guard let run = mock.taskToMutate?.runs.last,
              let step = run.steps.first(where: { $0.id == stepID })
        else {
            XCTFail("Mock task lost the step after cancellation")
            return
        }

        let partialAssistant = step.llmConversation.first(where: { $0.role == .assistant })
        XCTAssertNotNil(partialAssistant, "An assistant LLMMessage must exist after pause")
        XCTAssertFalse(
            (partialAssistant?.content ?? "").isEmpty,
            "Partial assistant content must be persisted on cancellation — got empty content"
        )

        let stepMessage = step.messages.first(where: { $0.role == .softwareEngineer })
        XCTAssertNotNil(stepMessage, "A StepMessage must be appended so PromptBuilder sees partial content on resume")
        XCTAssertFalse(
            (stepMessage?.content ?? "").isEmpty,
            "StepMessage content must reflect the partial stream output"
        )

        // The committed content should be a prefix of the full intended stream — i.e.
        // some substring of "Let me think about this carefully." that the stream got
        // through before the cancel arrived. We don't pin an exact prefix because
        // scheduling is non-deterministic; we just require it's non-empty AND a
        // valid prefix.
        let full = "Let me think about this carefully."
        if let content = partialAssistant?.content {
            XCTAssertTrue(
                full.hasPrefix(content),
                "Committed partial content '\(content)' should be a prefix of the streamed text '\(full)'"
            )
        }
    }

    /// Same flow, but the model emits thinking-only deltas (no visible content) before
    /// being cancelled. The user expects to see the thinking disclosure after pause —
    /// the LLMMessage must carry the thinking even when content is empty.
    func testStartStepExecution_thenCancel_writesPartialThinkingToLLMMessage() async throws {
        let stepID = "user_facing_step_thinking"
        let taskID = 2

        let initialTask = makeTaskWithRunningStep(taskID: taskID, stepID: stepID)
        let mock = StreamPersistingMockDelegate()
        mock.workFolderURL = tempDir
        mock.taskToMutate = initialTask

        let stubClient = StreamingStubLLMClient(
            thinkingChunks: ["I should ", "consider the ", "edge cases first..."],
            contentChunks: []
        )
        let service = LLMExecutionService(
            repository: NTMSRepository(),
            clientFactory: { stubClient }
        )
        service.attach(delegate: mock)

        service.startStepExecution(
            stepID: stepID, taskID: taskID,
            task: initialTask, runIndex: 0, stepIndex: 0)

        try await waitUntil {
            !mock.appendStreamingThinkingCalls.isEmpty
        }

        await service.cancelStepExecution(stepID: stepID, taskID: taskID)

        guard let run = mock.taskToMutate?.runs.last,
              let step = run.steps.first(where: { $0.id == stepID }),
              let assistantMsg = step.llmConversation.first(where: { $0.role == .assistant })
        else {
            XCTFail("Mock task lost the assistant message after cancellation")
            return
        }

        XCTAssertNotNil(
            assistantMsg.thinking,
            "Thinking must be persisted so the activity feed disclosure shows it after pause"
        )
        XCTAssertFalse(
            (assistantMsg.thinking ?? "").isEmpty,
            "Thinking must not be empty — got nil/empty after cancellation"
        )

        let full = "I should consider the edge cases first..."
        if let thinking = assistantMsg.thinking {
            XCTAssertTrue(
                full.hasPrefix(thinking),
                "Partial thinking '\(thinking)' should be a prefix of '\(full)'"
            )
        }
    }

    // MARK: - Co-fix: persistTokenUsage runs in the cancellation catch handler

    /// The fix's docstring claims `persistTokenUsage` is co-unblocked by keeping
    /// `executionStates[stepID]` alive through the catch handler. Pin it: inject a
    /// running task whose catch handler calls `persistTokenUsage` directly, then
    /// verify the token usage actually lands on `step.tokenUsage`. Before the fix,
    /// `taskIDForStep` returned nil here and the call no-op'd silently.
    func testCancelStepExecution_persistTokenUsageReachesStepInCatchHandler() async {
        let stepID = "step-token-usage-on-cancel"
        let taskID = 17

        let mock = StreamPersistingMockDelegate()
        mock.workFolderURL = tempDir
        mock.taskToMutate = makeTaskWithRunningStep(taskID: taskID, stepID: stepID)

        let fxService = LLMExecutionService(repository: NTMSRepository())
        fxService.attach(delegate: mock)

        let runningTask = Task<Void, Never> { @MainActor [weak fxService] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                await fxService?.persistTokenUsage(
                    stepID: stepID,
                    taskID: taskID,
                    usage: TokenUsage(inputTokens: 250, outputTokens: 80)
                )
            } catch { /* ignore */ }
        }

        fxService._testInjectRunningTask(stepID: stepID, taskID: taskID, runningTask: runningTask)

        await fxService.cancelStepExecution(stepID: stepID, taskID: taskID)

        let step = mock.taskToMutate?.runs.last?.steps.first(where: { $0.id == stepID })
        XCTAssertEqual(
            step?.tokenUsage?.inputTokens, 250,
            "persistTokenUsage in the catch handler must reach step.tokenUsage — input tokens lost"
        )
        XCTAssertEqual(
            step?.tokenUsage?.outputTokens, 80,
            "persistTokenUsage in the catch handler must reach step.tokenUsage — output tokens lost"
        )
    }

    // MARK: - Robustness: timeout fires if catch handler stalls

    /// Catch handler intentionally hangs by suspending on a never-resumed continuation
    /// — simulates a stalled `mutateTask` disk write (locked file, slow network volume).
    /// `cancelStepExecution` must time out and surface a banner instead of freezing
    /// the user's Pause click forever.
    func testCancelStepExecution_timesOutWhenCatchHandlerHangs() async {
        let stepID = "step-hang"
        let taskID = 99

        let runningTask = Task<Void, Never> { @MainActor in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                // Suspend forever — `withCheckedContinuation` is non-throwing, so even
                // future cancellations can't interrupt this. Mimics blocked disk I/O
                // inside `mutateTask`.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
                    // Never resume.
                }
            } catch { /* ignore */ }
        }

        service._testInjectRunningTask(stepID: stepID, taskID: taskID, runningTask: runningTask)

        let start = Date()
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, LLMConstants.cancelHandlerTimeoutSeconds + 2.0,
            "cancelStepExecution must time out, not hang forever — elapsed \(elapsed)s"
        )
        XCTAssertGreaterThanOrEqual(
            elapsed, LLMConstants.cancelHandlerTimeoutSeconds * 0.85,
            "Timeout should fire close to the configured cap (\(LLMConstants.cancelHandlerTimeoutSeconds)s) — elapsed \(elapsed)s"
        )
        XCTAssertTrue(
            mockDelegate.lastErrorMessages.contains(where: { $0.contains("timed out") }),
            "Timeout must surface an explanatory banner — got messages: \(mockDelegate.lastErrorMessages)"
        )
        XCTAssertFalse(
            service._testHasExecutionState(stepID: stepID, taskID: taskID),
            "executionStates entry must still be cleared even after timeout — caller proceeds with teardown"
        )
    }

    // MARK: - Edge case: zero-delta cancel — empty pre-created LLMMessage stays empty

    /// User pauses before any token arrived. `beginStreaming` already pre-created an
    /// empty `LLMMessage` in `step.llmConversation`; on zero-delta cancellation we
    /// should NOT mutate it into a non-empty state, and we MUST NOT append a phantom
    /// `StepMessage`. Otherwise the activity feed renders an empty assistant bubble
    /// or PromptBuilder feeds the model an empty turn on resume.
    func testStartStepExecution_zeroDeltaCancel_doesNotMaterializeContent() async throws {
        let stepID = "user_facing_step_zero_delta"
        let taskID = 3

        let initialTask = makeTaskWithRunningStep(taskID: taskID, stepID: stepID)
        let mock = StreamPersistingMockDelegate()
        mock.workFolderURL = tempDir
        mock.taskToMutate = initialTask

        let stubClient = StreamingStubLLMClient(
            thinkingChunks: [],
            contentChunks: []  // Stream emits NOTHING and just suspends.
        )
        let fxService = LLMExecutionService(
            repository: NTMSRepository(),
            clientFactory: { stubClient }
        )
        fxService.attach(delegate: mock)

        fxService.startStepExecution(
            stepID: stepID, taskID: taskID,
            task: initialTask, runIndex: 0, stepIndex: 0)

        // Wait until `beginStreaming` has created the empty LLMMessage on disk —
        // proves the streaming pipeline is fully attached before we cancel.
        try await waitUntil {
            !mock.beginStreamingCalls.isEmpty
        }

        await fxService.cancelStepExecution(stepID: stepID, taskID: taskID)

        guard let step = mock.taskToMutate?.runs.last?.steps.first(where: { $0.id == stepID }) else {
            XCTFail("Mock task lost the step")
            return
        }

        // The empty pre-created LLMMessage exists (from beginStreaming) but stays empty.
        let assistantMessages = step.llmConversation.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1, "Exactly the pre-created empty message should exist")
        XCTAssertTrue(
            (assistantMessages.first?.content ?? "").isEmpty,
            "No phantom content should be conjured for a zero-delta cancellation"
        )
        XCTAssertNil(
            assistantMessages.first?.thinking,
            "No phantom thinking either"
        )
        // Critical: no StepMessage was appended. PromptBuilder reads `step.messages`
        // for resume conversation rebuild — an empty StepMessage would feed the model
        // its own non-existent turn.
        XCTAssertTrue(
            step.messages.filter { $0.role == .softwareEngineer }.isEmpty,
            "No assistant StepMessage should be appended for empty content — got \(step.messages)"
        )
    }

    // MARK: - User journey: resume after pause-with-partial preserves the prior bubble

    /// The actual end-to-end behavior the user expects: pause mid-stream, see partial
    /// bubble, click resume, the partial bubble survives AND the next streaming
    /// iteration creates a *separate* assistant bubble. Verifies that re-running
    /// `startStepExecution` after cancellation doesn't replace, scrub, or merge the
    /// prior partial `LLMMessage`.
    func testPause_thenResumeStream_preservesPriorPartialBubble() async throws {
        let stepID = "user_facing_step_resume"
        let taskID = 4

        let initialTask = makeTaskWithRunningStep(taskID: taskID, stepID: stepID)
        let mock = StreamPersistingMockDelegate()
        mock.workFolderURL = tempDir
        mock.taskToMutate = initialTask

        // First iteration: emit some content, pause.
        let firstStub = StreamingStubLLMClient(
            thinkingChunks: [],
            contentChunks: ["First ", "iteration ", "content."]
        )
        let firstService = LLMExecutionService(
            repository: NTMSRepository(),
            clientFactory: { firstStub }
        )
        firstService.attach(delegate: mock)
        firstService.startStepExecution(
            stepID: stepID, taskID: taskID,
            task: initialTask, runIndex: 0, stepIndex: 0)
        try await waitUntil { !mock.markStreamActivityCalls.isEmpty }
        await firstService.cancelStepExecution(stepID: stepID, taskID: taskID)

        // Snapshot state after first pause: should have one assistant message with
        // the first stream's partial content.
        guard let stepAfterPause = mock.taskToMutate?.runs.last?.steps.first(where: { $0.id == stepID }) else {
            XCTFail("Step lost after first pause")
            return
        }
        let firstPartials = stepAfterPause.llmConversation.filter { $0.role == .assistant }
        XCTAssertEqual(firstPartials.count, 1, "First pause should produce exactly one partial bubble")
        let firstPartialContent = firstPartials.first?.content ?? ""
        XCTAssertFalse(firstPartialContent.isEmpty, "First partial must be non-empty")
        XCTAssertTrue("First iteration content.".hasPrefix(firstPartialContent))

        // Reset markStreamActivityCalls so the next waitUntil only sees second-iteration
        // events. (Mock state otherwise carries forward.)
        mock.markStreamActivityCalls.removeAll()

        // Second iteration: re-stream as if the engine resumed the step. Step
        // status is still `.running` because we never called pauseStep.
        let secondStub = StreamingStubLLMClient(
            thinkingChunks: [],
            contentChunks: ["Second ", "iteration ", "content."]
        )
        let secondService = LLMExecutionService(
            repository: NTMSRepository(),
            clientFactory: { secondStub }
        )
        secondService.attach(delegate: mock)
        // Re-read the task because mock.taskToMutate was mutated by the first run.
        guard let resumedTask = mock.taskToMutate else {
            XCTFail("taskToMutate lost between pauses")
            return
        }
        secondService.startStepExecution(
            stepID: stepID, taskID: taskID,
            task: resumedTask, runIndex: 0, stepIndex: 0)
        try await waitUntil { !mock.markStreamActivityCalls.isEmpty }
        await secondService.cancelStepExecution(stepID: stepID, taskID: taskID)

        // Final assertion: TWO assistant LLMMessages exist — the pre-resume partial
        // is preserved, and the post-resume partial is added separately. Neither
        // overwrites nor merges into the other. This is what the user sees: two
        // bubbles in the activity feed, one above the other.
        guard let finalStep = mock.taskToMutate?.runs.last?.steps.first(where: { $0.id == stepID }) else {
            XCTFail("Step lost after resume + second pause")
            return
        }
        let allAssistants = finalStep.llmConversation.filter { $0.role == .assistant }
        XCTAssertEqual(
            allAssistants.count, 2,
            "Resume must add a second bubble, not replace the first — got \(allAssistants.count) bubbles: \(allAssistants.map(\.content))"
        )
        XCTAssertEqual(
            allAssistants.first?.content, firstPartialContent,
            "First partial bubble's content must be preserved verbatim across resume"
        )
        let secondContent = allAssistants[1].content
        XCTAssertFalse(secondContent.isEmpty, "Second partial must be non-empty")
        XCTAssertTrue(
            "Second iteration content.".hasPrefix(secondContent),
            "Second partial '\(secondContent)' should be a prefix of the second stream"
        )
    }

    // MARK: - Top-level thinking-loop discard (faithful orphan removal)

    /// Faithful orphan-removal pin. `PerformStreamingCallLoopBreakTests` uses the
    /// recording `MockLLMExecutionDelegate` whose `beginStreaming` plants nothing, so
    /// its `llmConversation.isEmpty` check is tautological. Here the mock plants the
    /// empty assistant `LLMMessage` exactly as `NTMSOrchestrator.beginStreaming` does,
    /// so the round-trip is real: a top-level thinking-loop break must DISCARD that
    /// planted message (`discardStreaming` → `removeLLMMessage`) — leaving no orphan —
    /// and must NOT commit the looping turn.
    func testTopLevelThinkingLoop_discardRemovesPlantedOrphan_doesNotCommit() async throws {
        let stepID = "orphan_discard_step"
        let taskID = 11
        let task = makeTaskWithRunningStep(taskID: taskID, stepID: stepID)  // top-level (parentTaskID nil)
        let mock = StreamPersistingMockDelegate()
        mock.workFolderURL = tempDir
        mock.taskToMutate = task

        let service = LLMExecutionService(repository: NTMSRepository())
        service.attach(delegate: mock)
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)

        // 600-char thinking buffer: a 24-char phrase repeated 25× → fires the
        // within-message detector and crosses the 400-char scan cadence in one delta.
        let loopThinking = String(repeating: "Wait, let me reconsider.", count: 25)
        let result = try await service.performStreamingCall(
            stepID: stepID, taskID: taskID, roleForMessage: .softwareEngineer,
            client: StreamingStubLLMClient(thinkingChunks: [loopThinking], contentChunks: []),
            config: LLMConfig(), tools: [], conversationMessages: [],
            networkLogger: nil)

        XCTAssertNotNil(result.thinkingLoopSignal, "Top-level thinking loop must set the signal")
        XCTAssertEqual(mock.discardStreamingCalls.count, 1, "The planted message must be discarded once")
        XCTAssertTrue(mock.commitStreamingCalls.isEmpty, "The looping turn must NOT be committed")

        guard let step = mock.taskToMutate?.runs.last?.steps.first(where: { $0.id == stepID }) else {
            return XCTFail("Step lost after discard")
        }
        XCTAssertTrue(step.llmConversation.isEmpty,
                      "beginStreaming planted an empty assistant message; discard must remove it (no orphan)")
    }

    // MARK: - Helpers

    /// Polls `condition` until it returns true or `timeout` seconds elapse. Throws
    /// `WaitTimeoutError` on miss so the calling test exits via `try` instead of
    /// continuing into downstream assertions on stale state — that would produce a
    /// confusing cascade of failures that buries the original timeout.
    private func waitUntil(
        timeout: TimeInterval = 5.0,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                throw WaitTimeoutError(timeout: timeout)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct WaitTimeoutError: Error, LocalizedError {
        let timeout: TimeInterval
        var errorDescription: String? {
            "waitUntil: condition not met within \(timeout)s — stream did not start emitting in time. On a slow CI runner, bump the timeout."
        }
    }

    private func makeTaskWithRunningStep(taskID: Int, stepID: String) -> NTMSTask {
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "Test Step",
            status: .running
        )
        let run = Run(id: 0, steps: [step])
        return NTMSTask(
            id: taskID,
            title: "Test Task",
            supervisorTask: "Test goal",
            runs: [run]
        )
    }

    @MainActor
    private final class MainActorFlag {
        var value = false
    }

    @MainActor
    private final class ObservedTaskID {
        var value: Int?
    }

    /// One-shot fire flag readable from `@MainActor` context. Used by the concurrent-
    /// cancel test to verify the catch handler actually ran.
    @MainActor
    private final class ManualSignal {
        private(set) var fired = false
        func fire() { fired = true }
    }

    /// Concurrent-safe counter for the OnceResolver concurrency stress test.
    private actor ResultCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}

// MARK: - Streaming stub LLM client

/// Emits a deterministic sequence of thinking/content deltas, then suspends until the
/// underlying URLSession-equivalent task is cancelled. Used to drive the real
/// `performStreamingCall` pipeline so we can observe what `cancelStepExecution`
/// preserves on real partial output.
private final class StreamingStubLLMClient: LLMClient, @unchecked Sendable {
    let thinkingChunks: [String]
    let contentChunks: [String]

    init(thinkingChunks: [String], contentChunks: [String]) {
        self.thinkingChunks = thinkingChunks
        self.contentChunks = contentChunks
    }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let thinking = thinkingChunks
        let content = contentChunks
        return AsyncThrowingStream { continuation in
            let producer = Task.detached {
                for chunk in thinking {
                    if Task.isCancelled { break }
                    continuation.yield(StreamEvent(thinkingDelta: chunk))
                    try? await Task.sleep(for: .milliseconds(30))  // 30ms
                }
                for chunk in content {
                    if Task.isCancelled { break }
                    continuation.yield(StreamEvent(contentDelta: chunk))
                    try? await Task.sleep(for: .milliseconds(30))
                }
                // Suspend forever — until the consumer cancels (mimics a real LLM
                // server holding the connection open mid-response).
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

// MARK: - Faithful mock delegate

/// Extends `MockLLMExecutionDelegate` semantics by replacing `commitStreaming` and
/// `beginStreaming` with implementations that actually mutate `taskToMutate` the way
/// the real `NTMSOrchestrator` does. This makes the integration tests above able to
/// assert against the post-pause task state — what the user would see in the activity
/// feed and what would be persisted on disk.
@MainActor
private final class StreamPersistingMockDelegate: LLMExecutionDelegate {
    var workFolderURL: URL?
    var snapshot: WorkFolderContext?
    var agentInstructions: AgentInstructionsSnapshot?
    var roleSkills: RoleSkillsSnapshot?
    var globalLLMConfig: LLMConfig = LLMConfig()
    var globalLLMContext: String = ""
    var maxLLMRetries: Int = 0
    var visionLLMConfig: LLMConfig?
    var bashPolicy: BashPolicy = BashPolicy()
    var computerUsePolicy: ComputerUsePolicy = ComputerUsePolicy()
    func bashApprovalDidBegin(_ request: BashApprovalRequest) {}
    func bashApprovalDidEnd(taskID: Int, stepID: String, commandKey: String, createdAt: Date) {}
    func clearAllBashApprovalRequests() {}
    func computerUseApprovalDidBegin(_ request: ComputerUseApprovalRequest) {}
    func computerUseApprovalDidEnd(taskID: Int, stepID: String, actionKey: String, createdAt: Date) {}
    func clearAllComputerUseApprovalRequests() {}
    var loggingEnabled: Bool = false
    var exploratorySearchEnabled: Bool = false
    var searchExploratoryByDefault: Bool = false
    var readFileMaxLines: Int = AppDefaults.readFileMaxLines
    var searchMaxResults: Int = AppDefaults.searchMaxResults
    var searchContextBefore: Int = AppDefaults.searchContextBefore
    var searchContextAfter: Int = AppDefaults.searchContextAfter
    var hasRealWorkFolder: Bool = true
    var scriptedSearchIndex: SearchIndex?
    var awaitSearchIndexCallCount: Int = 0
    var scriptedExpansion: VocabVectorIndexService.ExpansionResult = .empty
    var expandSearchQueryCallCount: Int = 0

    func awaitSearchIndex() async -> SearchIndex? {
        awaitSearchIndexCallCount += 1
        return scriptedSearchIndex
    }

    func expandSearchQuery(query _: String, tokens _: [String]) async -> VocabVectorIndexService.ExpansionResult {
        expandSearchQueryCallCount += 1
        return scriptedExpansion
    }

    // Recording arrays so existing assertions in the regression test still work.
    var beginStreamingCalls: [(String, UUID, Role, Int)] = []
    var appendStreamingPreviewCalls: [(String, UUID, Role, String)] = []
    var replaceStreamingPreviewCalls: [(String, UUID, Role, String)] = []
    var appendStreamingThinkingCalls: [(String, String)] = []
    var commitStreamingCalls: [(String, Int, String, String?)] = []
    var clearStreamingPreviewCalls: [String] = []
    var updateProcessingProgressCalls: [(String, Double)] = []
    var clearProcessingProgressCalls: [String] = []
    var markStreamActivityCalls: [String] = []
    func markStreamActivity(stepID: String, taskID _: Int) { markStreamActivityCalls.append(stepID) }
    var markStreamingToolCallCalls: [String] = []
    func markStreamingToolCall(stepID: String, taskID _: Int) { markStreamingToolCallCalls.append(stepID) }
    func notifyQueuedMessageBackstop(taskID _: Int) {}

    var taskToMutate: NTMSTask?

    /// Tracks (stepID → messageID) for streaming sessions so commit can update the
    /// pre-created LLMMessage rather than appending a duplicate.
    private var streamingMessageIDs: [String: UUID] = [:]
    private var streamingRoles: [String: Role] = [:]

    func loadedTask(_ taskID: Int) -> NTMSTask? {
        if taskToMutate?.id == taskID { return taskToMutate }
        return nil
    }

    func mutateTask(taskID: Int, _ mutate: (inout NTMSTask) -> Void) async -> Bool {
        if var task = taskToMutate, task.id == taskID {
            mutate(&task)
            taskToMutate = task
            return true
        }
        return false
    }

    /// Mirrors `NTMSOrchestrator.beginStreaming`: pre-creates an empty LLMMessage in
    /// the step's conversation so the activity feed picks up the streaming bubble.
    func beginStreaming(stepID: String, taskID: Int, messageID: UUID, role: Role) async {
        beginStreamingCalls.append((stepID, messageID, role, taskID))
        streamingMessageIDs[stepID] = messageID
        streamingRoles[stepID] = role

        let msg = LLMMessage(id: messageID, role: .assistant, content: "")
        _ = await mutateTask(taskID: taskID) { task in
            TaskMutationService.appendLLMMessage(msg, to: stepID, in: &task)
        }
    }

    func appendStreamingPreview(stepID: String, taskID _: Int, messageID: UUID, role: Role, content: String) {
        appendStreamingPreviewCalls.append((stepID, messageID, role, content))
    }

    func replaceStreamingPreview(stepID: String, taskID _: Int, messageID: UUID, role: Role, content: String) {
        replaceStreamingPreviewCalls.append((stepID, messageID, role, content))
    }

    func appendStreamingThinking(stepID: String, taskID _: Int, content: String) {
        appendStreamingThinkingCalls.append((stepID, content))
    }

    /// Mirrors `NTMSOrchestrator.commitStreaming`: writes the partial content/thinking
    /// into both `step.llmConversation` (updates the pre-created assistant LLMMessage)
    /// and `step.messages` (appends a new StepMessage if content is non-empty).
    func commitStreaming(stepID: String, taskID: Int, content: String, thinking: String?) async {
        commitStreamingCalls.append((stepID, taskID, content, thinking))

        let messageID = streamingMessageIDs[stepID] ?? UUID()
        let role = streamingRoles[stepID] ?? .softwareEngineer

        _ = await mutateTask(taskID: taskID) { task in
            TaskMutationService.commitStreamingContent(
                stepID: stepID,
                messageID: messageID,
                content: content,
                thinking: thinking,
                role: role,
                in: &task
            )
        }

        streamingMessageIDs[stepID] = nil
        streamingRoles[stepID] = nil
    }

    var discardStreamingCalls: [(String, UUID, Int)] = []
    func discardStreaming(stepID: String, messageID: UUID, taskID: Int) async {
        discardStreamingCalls.append((stepID, messageID, taskID))
        _ = await mutateTask(taskID: taskID) { task in
            TaskMutationService.removeLLMMessage(id: messageID, from: stepID, in: &task)
        }
        streamingMessageIDs[stepID] = nil
        streamingRoles[stepID] = nil
    }

    func noteStreamLoop(taskID _: Int, stepID _: String, signal _: LoopSignal) -> Bool { true }

    func clearStreamingPreview(stepID: String, taskID _: Int) {
        clearStreamingPreviewCalls.append(stepID)
        streamingMessageIDs[stepID] = nil
        streamingRoles[stepID] = nil
    }

    func updateStreamingProcessingProgress(stepID: String, taskID _: Int, progress: Double) {
        updateProcessingProgressCalls.append((stepID, progress))
    }

    func clearStreamingProcessingProgress(stepID: String, taskID _: Int) {
        clearProcessingProgressCalls.append(stepID)
    }

    var setMeetingParticipantsCalls: [(Set<String>, Int)] = []
    var clearMeetingParticipantsCalls: [Int] = []
    func setActiveMeetingParticipants(_ participantIDs: Set<String>, for taskID: Int) {
        setMeetingParticipantsCalls.append((participantIDs, taskID))
    }
    func clearActiveMeetingParticipants(for taskID: Int) { clearMeetingParticipantsCalls.append(taskID) }

    var scriptedQueuedMessages: [(taskID: Int, roleID: String?, content: String)] = []
    var consumedQueuedMessages: [(Int, String, String, String)] = []
    func consumeQueuedSupervisorMessage(taskID: Int, roleID: String, stepID: String) async -> String? {
        let idx = scriptedQueuedMessages.firstIndex { $0.taskID == taskID && ($0.roleID == roleID || $0.roleID == nil) }
        guard let i = idx else { return nil }
        let entry = scriptedQueuedMessages.remove(at: i)
        consumedQueuedMessages.append((taskID, roleID, stepID, entry.content))
        return entry.content
    }

    var lastInfoMessages: [String] = []
    func setLastInfoMessageForUI(_ message: String) { lastInfoMessages.append(message) }

    var lastErrorMessages: [String] = []
    func setLastErrorMessageForUI(_ message: String) { lastErrorMessages.append(message) }
    func holdDownstreamForRevision(taskID _: Int, runningRoleIDs _: [String], requesterRoleID _: String) async {}

    var scriptedAwaitOutcomes: [TaskCompletionAwaiter.WaitOutcome] = []
    var awaitedTaskIDs: [Int] = []
    func awaitTaskTerminalState(taskID: Int) async -> TaskCompletionAwaiter.WaitOutcome {
        awaitedTaskIDs.append(taskID)
        guard !scriptedAwaitOutcomes.isEmpty else { return .terminal(.failed) }
        return scriptedAwaitOutcomes.removeFirst()
    }

    var createDelegatedTaskStub: Int? = nil
    var createdDelegatedTaskRequests: [(parentTaskID: Int, parentRoleID: String, title: String, supervisorTask: String, preferredTeamID: NTMSID?, depth: Int)] = []
    func createDelegatedTask(
        parentTaskID: Int, parentRoleID: String, title: String, supervisorTask: String,
        preferredTeamID: NTMSID?, depth: Int
    ) async -> Int? {
        createdDelegatedTaskRequests.append(
            (parentTaskID, parentRoleID, title, supervisorTask, preferredTeamID, depth))
        return createDelegatedTaskStub
    }

    var startedRunForTaskIDs: [Int] = []
    func startRunForTask(taskID: Int) async { startedRunForTaskIDs.append(taskID) }

    var closeTaskStub: Bool = true
    var closedTaskIDs: [Int] = []
    func closeTask(taskID: Int) async -> Bool {
        closedTaskIDs.append(taskID)
        return closeTaskStub
    }

    var lastErrorPerTaskStub: [Int: String] = [:]
    func lastErrorMessageForTask(_ taskID: Int) -> String? { lastErrorPerTaskStub[taskID] }

    func streamLastActivityAt(stepID: String, taskID: Int) -> Date? { nil }
    func streamLiveText(stepID: String, taskID: Int) -> String? { nil }

    var stopEngineCalls: [Int] = []
    func stopEngineForTask(_ taskID: Int) { stopEngineCalls.append(taskID) }

    var pauseRunCalls: [Int] = []
    func pauseRun(taskID: Int) async { pauseRunCalls.append(taskID) }

    var resumeRunCalls: [Int] = []
    func resumeRun(taskID: Int) async { resumeRunCalls.append(taskID) }

    var activeDelegationChildStub: [String: Int] = [:]
    func activeDelegationChildID(taskID: Int, roleID: String) -> Int? {
        activeDelegationChildStub["\(taskID):\(roleID)"]
    }

    var answerSupervisorCalls: [(taskID: Int, stepID: String, answer: String)] = []
    func answerSupervisorQuestion(taskID: Int, stepID: String, answer: String) async -> Bool {
        answerSupervisorCalls.append((taskID, stepID, answer))
        return true
    }
    func performAutovisorAction(_ action: AutovisorAction) async -> AutovisorActionResult { .success("ok") }
    func persistAutovisorMemory(_ text: String) async -> Bool { true }
    func autovisorLoadTask(_ taskID: Int) async -> NTMSTask? { loadedTask(taskID) }
}
