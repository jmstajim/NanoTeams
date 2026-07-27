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

    // MARK: - Helpers

    /// Wraps an async call with a hard timeout. Returns nil on timeout.
    /// Used to assert "fast-path completes quickly" rather than letting a
    /// hung test stall CI for 30 minutes.
    private func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
