import XCTest
@testable import NanoTeams

/// Regression for the auto-accept hang in delegated tasks.
///
/// Sequence that pre-fix dead-locked the parent's `delegate_to_team` handler
/// for 30 minutes (until `delegationTimeoutSeconds`):
///
///  1. Child team produces all artifacts → child engine reaches
///     `.needsAcceptance`.
///  2. Awaiter delivers `.terminal(.needsAcceptance)` to the handler.
///  3. Handler calls `delegate.closeTask(childTID)` per spec #11 (delegation
///     auto-accepts — UI is hidden from the human).
///  4. `closeTask` mutates `closedAt`, then calls `stopEngine(for: childTID)`
///     which removes `engineState[childTID]` and `cancelAll`'s any registered
///     waiters.
///  5. Handler loops and calls `awaitTaskTerminalState(childTID)` again.
///  6. **Pre-fix**: fast-path checked only `engineState[childTID]` (now nil),
///     fell through to `register(taskID:)`, no transition fires, awaiter
///     hangs until timeout.
///
/// Post-fix: fast-path also reads `task.closedAt`. If it's set, return
/// `.terminal(.done)` immediately. Same idea for terminal `derivedStatus`
/// (`.failed` / `.done`) — recovery paths can leave the engine torn down
/// while the run carries the final state.
@MainActor
final class AwaitTaskTerminalStateClosedAtTests: XCTestCase {

    private func makeOrchestrator() -> NTMSOrchestrator {
        TestOrchestrator.make()
    }

    private func makeWorkFolderRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-await-closedat-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The exact post-`closeTask` race the auto-accept loop stumbles into:
    /// task has `closedAt` set, engine has been torn down (`engineState[id]`
    /// is nil). `awaitTaskTerminalState` MUST short-circuit to
    /// `.terminal(.done)` rather than register a waiter that nobody can fire.
    func testAwait_taskWithClosedAt_andNoEngineState_returnsDoneImmediately() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }

        // Mark closed and ensure no engineState entry — exact post-`closeTask`
        // / `stopEngine` shape.
        let mutated = await store.mutateTask(taskID: taskID) { task in
            task.closedAt = MonotonicClock.shared.now()
        }
        XCTAssertTrue(mutated)
        XCTAssertNil(store.taskEngineStates[taskID],
                     "Test setup invariant: no engine state — pre-fix, this is the condition that hung the awaiter")

        // The race: handler awaits AFTER closeTask. Pre-fix this would
        // register a waiter and never resume. Post-fix it short-circuits.
        // Use a tight timeout: if the fast-path works the call returns in
        // microseconds; if it hangs the test fails fast.
        let outcome = await withTimeout(seconds: 1.0) {
            await store.awaitTaskTerminalState(taskID: taskID)
        }
        guard let outcome else {
            return XCTFail("awaitTaskTerminalState hung — fast-path on closedAt didn't fire")
        }
        switch outcome {
        case .terminal(let state):
            XCTAssertEqual(state, .done,
                           "closedAt set ⇒ awaitTaskTerminalState must report `.done` (handler treats this as success and returns artifacts to parent role)")
        default:
            XCTFail("Expected .terminal(.done), got \(outcome)")
        }
    }

    /// Symmetric case for `.failed` derived status — engine teardown after
    /// recovery path, run still carries failed step.
    func testAwait_taskWithFailedDerivedStatus_andNoEngineState_returnsFailedImmediately() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }

        // Add a failed step — derivedStatus picks `.failed` per Run.derivedStatus
        // priority order.
        let mutated = await store.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, steps: [])
            run.steps.append(StepExecution(
                id: "role_a",
                role: .softwareEngineer,
                title: "Step",
                status: .failed
            ))
            run.roleStatuses["role_a"] = .failed
            task.runs.append(run)
        }
        XCTAssertTrue(mutated)
        XCTAssertNil(store.taskEngineStates[taskID])

        let outcome = await withTimeout(seconds: 1.0) {
            await store.awaitTaskTerminalState(taskID: taskID)
        }
        guard let outcome else {
            return XCTFail("awaitTaskTerminalState hung on failed derived status")
        }
        switch outcome {
        case .terminal(let state):
            XCTAssertEqual(state, .failed,
                           "Failed run with no engine state must surface as terminal failure")
        default:
            XCTFail("Expected .terminal(.failed), got \(outcome)")
        }
    }

    /// Pin the existing engine-state fast-path: when `engineState[id]` is set
    /// to a wakeable terminal state, the function must still return that
    /// directly, not consult `closedAt` / `derivedStatus`.
    func testAwait_engineStateNeedsAcceptance_preservedFastPath() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let taskID = await store.createTask(title: "T", supervisorTask: "...")
        guard let taskID else { return XCTFail("task creation failed") }

        // Simulate engine in `.needsAcceptance` with no `closedAt` yet — this
        // is the state immediately before the handler calls `closeTask`.
        store.engineState[taskID] = .needsAcceptance

        let outcome = await store.awaitTaskTerminalState(taskID: taskID)
        switch outcome {
        case .terminal(let state):
            XCTAssertEqual(state, .needsAcceptance,
                           "Engine-state fast-path must still surface `.needsAcceptance` for the handler to enter its auto-accept branch")
        default:
            XCTFail("Expected .terminal(.needsAcceptance), got \(outcome)")
        }
    }

    func testAwait_recoveredPendingQuestionWithPausedEngineState_returnsNeedsSupervisorInputImmediately() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        guard let taskID = await store.createTask(title: "RecoveredChild", supervisorTask: "...") else {
            return XCTFail("task creation failed")
        }

        await store.mutateTask(taskID: taskID) { task in
            var step = StepExecution(
                id: "swe",
                role: .softwareEngineer,
                title: "SWE",
                status: .paused,
                needsSupervisorInput: true,
                supervisorQuestion: "Which database schema should I use?"
            )
            step.supervisorAnswer = nil
            var run = Run(id: 0, steps: [step])
            run.roleStatuses["swe"] = .working
            task.runs.append(run)
        }
        store.engineState[taskID] = .paused

        let outcome = await withTimeout(seconds: 0.4, onTimeout: {
            store.completionAwaiter.cancelAll(taskID: taskID)
        }) {
            await store.awaitTaskTerminalState(taskID: taskID)
        }
        XCTAssertEqual(
            outcome,
            .needsSupervisorInput,
            "a relaunch-recovered pending question (step .paused with answerableSupervisorSteps non-empty) must fast-path to .needsSupervisorInput"
        )
    }

    func testAwait_childRunTimeoutWatchdog_deliversPausedRunTimedOut() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        guard let taskID = await store.createTask(title: "TimeoutChild", supervisorTask: "...") else {
            return XCTFail("task creation failed")
        }

        let past = MonotonicClock.shared.now().addingTimeInterval(-120)
        await store.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = 30
            let step = StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .running)
            let run = Run(id: 0, createdAt: past, updatedAt: past, steps: [step])
            task.runs.append(run)
        }
        store.engineState[taskID] = .running

        let waiter = Task { await store.awaitTaskTerminalState(taskID: taskID) }
        await Task.yield()
        XCTAssertTrue(store.completionAwaiter.hasWaiters(for: taskID))

        await store.evaluateRunTimeouts()

        let outcome = await withTimeout(seconds: 0.4, onTimeout: {
            store.completionAwaiter.cancelAll(taskID: taskID)
        }) {
            await waiter.value
        }
        XCTAssertEqual(
            outcome,
            .paused(.runTimedOut(seconds: 30)),
            "child run timeout watchdog must wake awaiter with .paused(.runTimedOut)"
        )

        // Also cover the fast path on an already timed-out paused run when runTimeoutSeconds is nil,
        // and wakeEngine's refusal while team generation is active.
        await store.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = nil
        }
        store.engineState[taskID] = nil
        let fastOutcome = await store.awaitTaskTerminalState(taskID: taskID)
        XCTAssertEqual(fastOutcome, .paused(.runTimedOut(seconds: 0)))

        _ = store.beginTeamGeneration(taskID: taskID, within: store.currentFolderLifecycle)
        XCTAssertFalse(store.wakeEngine(taskID: taskID))
        store.endTeamGeneration(taskID: taskID)
    }

    func testAwait_childIterationLimitReached_deliversPausedIterationLimitReached() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        guard let taskID = await store.createTask(title: "IterLimitChild", supervisorTask: "...") else {
            return XCTFail("task creation failed")
        }

        await store.mutateTask(taskID: taskID) { task in
            let step = StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .running)
            var run = Run(id: 0, steps: [step])
            run.roleStatuses["swe"] = .working
            task.runs.append(run)
        }

        let engine = store.engineForTask(taskID)
        engine.setAutoIterationLimitForTesting(1)

        let waiter = Task { await store.awaitTaskTerminalState(taskID: taskID) }
        await Task.yield()
        XCTAssertTrue(store.completionAwaiter.hasWaiters(for: taskID))

        engine.start()

        let outcome = await withTimeout(seconds: 0.5, onTimeout: {
            store.completionAwaiter.cancelAll(taskID: taskID)
        }) {
            await waiter.value
        }
        XCTAssertEqual(
            outcome,
            .paused(.iterationLimitReached(limit: 1)),
            "child engine reaching autoIterationLimit must wake awaiter with .paused(.iterationLimitReached)"
        )
    }

    func testAwait_teamGenerationFailure_deliversTerminalFailed() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        let generatedTeam = TeamTemplateFactory.generatedTeam()
        await store.mutateWorkFolder { project in
            if !project.teams.contains(where: { $0.templateID == "generated" }) {
                project.teams.append(generatedTeam)
            }
        }
        guard let taskID = await store.createTask(
            title: "GenFailChild",
            supervisorTask: "Build it",
            preferredTeamID: generatedTeam.id
        ) else {
            return XCTFail("task creation failed")
        }
        await store.mutateTask(taskID: taskID) { task in
            task.runs.append(Run(id: 0, steps: [], teamID: generatedTeam.id))
        }

        let waiter = Task { await store.awaitTaskTerminalState(taskID: taskID) }
        await Task.yield()
        XCTAssertTrue(store.completionAwaiter.hasWaiters(for: taskID))

        let ok = await store.runTeamGeneration(taskID: taskID)
        XCTAssertFalse(ok)

        let outcome = await withTimeout(seconds: 0.4, onTimeout: {
            store.completionAwaiter.cancelAll(taskID: taskID)
        }) {
            await waiter.value
        }
        XCTAssertEqual(
            outcome,
            TaskCompletionAwaiter.WaitOutcome.terminal(.failed),
            "runTeamGeneration failure must deliver .terminal(.failed) to completionAwaiter"
        )
    }

    func testAwait_pausedFastPathsAndDerivedNeedsAcceptance() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        guard let taskID = await store.createTask(title: "FastPaths", supervisorTask: "...") else {
            return XCTFail("task creation failed")
        }

        // 1) Fast-path when engineState == .paused and pausedIterationLimit is set
        let engine = store.engineForTask(taskID)
        engine.pausedIterationLimit = 5
        store.engineState[taskID] = .paused
        let iterOutcome = await store.awaitTaskTerminalState(taskID: taskID)
        XCTAssertEqual(iterOutcome, .paused(.iterationLimitReached(limit: 5)))
        engine.pausedIterationLimit = nil

        // 2) Fast-path when engineState == .paused and run.timedOutAt != nil
        await store.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = 45
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .paused)],
                roleStatuses: ["swe": .working],
                timedOutAt: Date()
            )]
        }
        store.engineState[taskID] = .paused
        let timeoutOutcome = await store.awaitTaskTerminalState(taskID: taskID)
        XCTAssertEqual(timeoutOutcome, .paused(.runTimedOut(seconds: 45)))

        // 3) Fast-path when engineState == nil and run.derivedStatus == .needsSupervisorAcceptance
        store.engineState[taskID] = nil
        await store.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(false)
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .done)],
                roleStatuses: ["swe": .needsAcceptance]
            )]
        }
        let acceptOutcome = await store.awaitTaskTerminalState(taskID: taskID)
        XCTAssertEqual(acceptOutcome, .terminal(.needsAcceptance))

        // 4) Live engineState fast-paths (.done, .failed, .needsSupervisorInput)
        store.engineState[taskID] = .done
        let liveDone = await store.awaitTaskTerminalState(taskID: taskID)
        XCTAssertEqual(liveDone, .terminal(.done))

        store.engineState[taskID] = .failed
        let liveFailed = await store.awaitTaskTerminalState(taskID: taskID)
        XCTAssertEqual(liveFailed, .terminal(.failed))

        store.engineState[taskID] = .needsSupervisorInput
        let liveInput = await store.awaitTaskTerminalState(taskID: taskID)
        XCTAssertEqual(liveInput, .needsSupervisorInput)
    }

    /// A child whose run timed out, was resumed, and was then paused by the person is NOT paused
    /// by its timeout: the delegating role must keep waiting, as it does for any pause the child
    /// did not start itself (`.paused(reason)` is only for self-pauses), rather than read "the
    /// child timed out" and resume a run the person stopped.
    ///
    /// RED before 2026-11-07: the fast path read `timedOutAt != nil` and answered
    /// `.paused(.runTimedOut)` for the person's pause.
    func testAwait_childPausedByThePersonAfterItsTimeout_isNotReportedAsTimedOut() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.openWorkFolder(root)
        guard let taskID = await store.createTask(title: "Re-paused child", supervisorTask: "...") else {
            return XCTFail("task creation failed")
        }
        await store.mutateTask(taskID: taskID) { task in
            task.runTimeoutSeconds = 45
            var run = Run(
                id: 0,
                steps: [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .paused)],
                roleStatuses: ["swe": .working],
                timedOutAt: Date()
            )
            run.pauseCause = .requested
            task.runs = [run]
        }
        store.engineState[taskID] = .paused

        let waiter = Task { await store.awaitTaskTerminalState(taskID: taskID) }
        for _ in 0..<50 where !store.completionAwaiter.hasWaiters(for: taskID) {
            await Task.yield()
        }
        XCTAssertTrue(store.completionAwaiter.hasWaiters(for: taskID), "the person's pause is waited out, not answered at once")
        store.completionAwaiter.deliver(taskID: taskID, outcome: .terminal(.done))
        let outcome = await withTimeout(seconds: 0.4, onTimeout: {
            store.completionAwaiter.cancelAll(taskID: taskID)
        }) {
            await waiter.value
        }
        XCTAssertEqual(outcome, .terminal(.done))

        // The timeout's own pause still answers at once.
        await store.mutateTask(taskID: taskID) { $0.runs[0].pauseCause = .runTimedOut }
        let timedOut = await store.awaitTaskTerminalState(taskID: taskID)
        XCTAssertEqual(timedOut, .paused(.runTimedOut(seconds: 45)))
    }

    // MARK: - Helpers

    /// Wraps an async call with a hard timeout. Returns nil on timeout.
    /// Used to assert "fast-path completes quickly" rather than letting a
    /// hung test stall CI for 30 minutes.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        onTimeout: (@MainActor @Sendable () -> Void)? = nil,
        _ op: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: (timedOut: Bool, value: T?).self) { group in
            group.addTask { (false, await op()) }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                if let onTimeout {
                    await MainActor.run { onTimeout() }
                }
                return (true, nil)
            }
            let first = await group.next()
            group.cancelAll()
            if first?.timedOut == true {
                return nil
            }
            return first?.value
        }
    }
}
