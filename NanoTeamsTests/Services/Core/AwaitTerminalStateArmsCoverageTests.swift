import XCTest

@testable import NanoTeams

/// Wave 10 — the fast-path arms of `awaitTaskTerminalState` that no test entered.
///
/// This function is the delegation handler's only exit. Every arm it does NOT take falls through
/// to `completionAwaiter.register`, and a registration nobody can fire blocks the parent role for
/// the full `delegationTimeoutSeconds` (30 minutes). So the cost of a wrong arm is not a wrong
/// value — it is a wedged parent, which is precisely the bug `AwaitTaskTerminalStateClosedAtTests`
/// was written for. That suite pinned the `closedAt` arm; the five arms below were left open.
///
/// Each call goes through `awaitWithRescue`, which arms a one-second sentinel delivery so a
/// regression that starts registering a waiter fails instead of hanging the suite. Getting that
/// bound right took two attempts — see the helper.
@MainActor
final class AwaitTerminalStateArmsCoverageTests: XCTestCase {

    private func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-await-arms-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Seeds a work folder + one task and returns both, so each test states only its own state.
    private func makeTask() async -> (NTMSOrchestrator, URL, Int)? {
        let store = TestOrchestrator.make()
        let root = makeRoot()
        await store.openWorkFolder(root)
        guard let taskID = await store.createTask(title: "T", supervisorTask: "brief") else {
            return nil
        }
        return (store, root, taskID)
    }

    /// The three engine states that mean "this task has stopped, here is how", plus the one that
    /// means "it stopped to ask". They are the ordinary way a delegated child ends — the
    /// `closedAt` fast path below them only exists for the post-`closeTask` teardown race.
    ///
    /// Driven by seeding `engineState` directly rather than by running an engine: the arm under
    /// test is the READ, and running a real engine to produce each state would make the test about
    /// the engine's transitions instead.
    ///
    /// RED: delete any one `case` from the engine-state switch → that state falls through to the
    /// task checks (which find a fresh, open, non-terminal task), reaches `register`, and the
    /// rescue's sentinel comes back instead of that iteration's expected outcome.
    func testAwait_engineStateArms_eachShortCircuitsToItsOwnOutcome() async {
        guard let (store, root, taskID) = await makeTask() else {
            return XCTFail("task creation failed")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let expected: [(TeamEngineState, TaskCompletionAwaiter.WaitOutcome)] = [
            (.done, .terminal(.done)),
            (.failed, .terminal(.failed)),
            (.needsAcceptance, .terminal(.needsAcceptance)),
            (.needsSupervisorInput, .needsSupervisorInput),
        ]

        for (state, want) in expected {
            store.engineState[taskID] = state
            let got = await awaitWithRescue(store, taskID: taskID)
            XCTAssertEqual(got, want, "engine state \(state) must short-circuit")
        }
    }

    /// The `default: break` arm. A NON-terminal engine state (`.running`) must NOT be answered
    /// from the engine — it has to fall through, because the handler asked "tell me when this
    /// ends" and `.running` is not an ending. Here the fall-through lands on the `closedAt` check,
    /// so the test can assert the pass-through happened without registering a waiter that hangs.
    ///
    /// The combination is not artificial: `closeTask` sets `closedAt` and then tears the engine
    /// down, so a reader arriving mid-teardown sees exactly this pair.
    ///
    /// RED: answer `.running` from the engine switch (e.g. `default: return .needsSupervisorInput`)
    /// → the assertion sees `.needsSupervisorInput` instead of `.terminal(.done)`.
    func testAwait_runningEngine_fallsThroughToTheTaskState() async {
        guard let (store, root, taskID) = await makeTask() else {
            return XCTFail("task creation failed")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        store.engineState[taskID] = .running
        let mutated = await store.mutateTask(taskID: taskID) { task in
            task.closedAt = MonotonicClock.shared.now()
        }
        XCTAssertTrue(mutated)

        let got = await awaitWithRescue(store, taskID: taskID)
        XCTAssertEqual(got, .terminal(.done),
                       "a running engine must not answer; the closed task underneath it must")
    }

    /// The two DERIVED-status arms, reached only when the engine is gone entirely. Recovery paths
    /// leave exactly this shape: `stopAllEngines` on a work-folder switch drops the engine while
    /// the run keeps its final steps.
    ///
    /// `.done` here is the arm that looks unreachable and is not. `derivedStatusFromActiveRun`
    /// normally routes a finished-but-open task to `.needsSupervisorAcceptance`, and its `.done`
    /// answers require `closedAt` — which the check above would already have caught. The one
    /// remaining door is a task with NO runs at all, where the stored `status` is returned
    /// verbatim; that is the shape a task carries between `createTask` and its first run.
    ///
    /// RED: drop the `derivedStatusFromActiveRun` switch → both assertions register a waiter and
    /// see the rescue's sentinel.
    func testAwait_noEngine_readsTheTasksOwnTerminalStatus() async {
        guard let (store, root, taskID) = await makeTask() else {
            return XCTFail("task creation failed")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        store.engineState.removeEngine(for: taskID)
        XCTAssertNil(store.taskEngineStates[taskID], "setup: no engine state")

        // `.failed` — a run whose step failed, task still open.
        var mutated = await store.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .failed),
            ])]
        }
        XCTAssertTrue(mutated)
        var got = await awaitWithRescue(store, taskID: taskID)
        XCTAssertEqual(got, .terminal(.failed))

        // `.done` — no runs, stored status terminal, never closed.
        mutated = await store.mutateTask(taskID: taskID) { task in
            task.runs = []
            task.status = .done
            task.closedAt = nil
        }
        XCTAssertTrue(mutated)
        got = await awaitWithRescue(store, taskID: taskID)
        XCTAssertEqual(got, .terminal(.done))
    }

    /// Calls `awaitTaskTerminalState` with a rescue armed, and returns whatever it answered.
    ///
    /// A regression that stops short-circuiting registers a waiter nothing will ever fire, so the
    /// call must be bounded — but it CANNOT be bounded by the obvious `withTaskGroup` timeout,
    /// and this suite's first draft got that wrong. `withTaskGroup` awaits every child before it
    /// returns, `cancelAll()` does not resume a `CheckedContinuation`, and `register` ignores
    /// cancellation — so the "timeout" hangs the process instead of failing the test. Measured:
    /// with the `.needsSupervisorInput` arm deleted, that draft wedged `xcodebuild` until it was
    /// killed. The identical helper in `AwaitTaskTerminalStateClosedAtTests` carries the same
    /// defect and the same false promise in its doc comment.
    ///
    /// So the rescue is a DELIVERY, not a cancellation: after a second, hand the waiter a
    /// sentinel outcome no fast-path arm can produce. `cancelAll(taskID:)` would not do — it
    /// resumes with `.terminal(.failed)`, which is one of the values under test, so a hung call
    /// would masquerade as the `.failed` arm working.
    private func awaitWithRescue(
        _ store: NTMSOrchestrator, taskID: Int
    ) async -> TaskCompletionAwaiter.WaitOutcome {
        let rescue = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            store.completionAwaiter.deliver(taskID: taskID, outcome: Self.hungSentinel)
        }
        defer { rescue.cancel() }
        return await store.awaitTaskTerminalState(taskID: taskID)
    }

    private static let hungSentinel = TaskCompletionAwaiter.WaitOutcome
        .parentMessageQueued(text: "await-arms: fast path did not fire")
}
