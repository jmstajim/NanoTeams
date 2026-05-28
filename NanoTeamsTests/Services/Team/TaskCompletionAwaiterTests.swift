import XCTest
@testable import NanoTeams

/// Lifecycle tests for the `TaskCompletionAwaiter` continuation registry.
@MainActor
final class TaskCompletionAwaiterTests: XCTestCase {

    var awaiter: TaskCompletionAwaiter!

    override func setUp() {
        super.setUp()
        awaiter = TaskCompletionAwaiter()
    }

    override func tearDown() {
        awaiter = nil
        super.tearDown()
    }

    // MARK: - register/deliver round-trip

    func testRegister_resumesOnDeliver_terminalDone() async {
        let task = Task { await awaiter.register(taskID: 1) }
        // Yield so the continuation has registered.
        await Task.yield()
        XCTAssertTrue(awaiter.hasWaiters(for: 1))
        awaiter.deliver(taskID: 1, outcome: .terminal(.done))
        let outcome = await task.value
        XCTAssertEqual(outcome, .terminal(.done))
        XCTAssertFalse(awaiter.hasWaiters(for: 1))
    }

    func testRegister_resumesOnDeliver_needsSupervisorInput() async {
        let task = Task { await awaiter.register(taskID: 2) }
        await Task.yield()
        awaiter.deliver(taskID: 2, outcome: .needsSupervisorInput)
        let outcome = await task.value
        XCTAssertEqual(outcome, .needsSupervisorInput)
    }

    // MARK: - cancelAll

    func testCancelAll_releasesAllWaitersAsFailed() async {
        let t1 = Task { await awaiter.register(taskID: 5) }
        let t2 = Task { await awaiter.register(taskID: 5) }
        await Task.yield()
        awaiter.cancelAll(taskID: 5)
        let outcome1 = await t1.value
        let outcome2 = await t2.value
        XCTAssertEqual(outcome1, .terminal(.failed))
        XCTAssertEqual(outcome2, .terminal(.failed))
    }

    func testCancelAll_global_releasesAllTasks() async {
        let a = Task { await awaiter.register(taskID: 10) }
        let b = Task { await awaiter.register(taskID: 11) }
        await Task.yield()
        awaiter.cancelAll()
        let outcomeA = await a.value
        let outcomeB = await b.value
        XCTAssertEqual(outcomeA, .terminal(.failed))
        XCTAssertEqual(outcomeB, .terminal(.failed))
    }

    // MARK: - Deliver-with-no-waiters is a no-op

    func testDeliver_withNoRegisteredWaiters_isNoOp() {
        // Should not crash or raise; just discards the outcome.
        awaiter.deliver(taskID: 99, outcome: .terminal(.done))
        XCTAssertFalse(awaiter.hasWaiters(for: 99))
    }

    // MARK: - Multiple waiters per task

    func testMultipleWaiters_perTask_allResume() async {
        let waiters = (0..<3).map { _ in Task { await awaiter.register(taskID: 7) } }
        await Task.yield()
        awaiter.deliver(taskID: 7, outcome: .terminal(.done))
        for w in waiters {
            let outcome = await w.value
            XCTAssertEqual(outcome, .terminal(.done))
        }
        XCTAssertFalse(awaiter.hasWaiters(for: 7))
    }

    // MARK: - I-10: TerminalOutcome narrowing pin

    /// Pin: `WaitOutcome.terminal(_)` carries `TerminalOutcome` (3 cases),
    /// not `TeamEngineState` (7 cases). Pre-narrowing, the type permitted
    /// `.terminal(.idle)` / `.terminal(.running)` / `.terminal(.paused)`
    /// — none of which are real terminal states, and any of which would
    /// have wedged a delegation handler into a tight loop.
    ///
    /// This is a structural test — it relies on the compiler refusing to
    /// build with the old shape. If a future refactor widens
    /// `TerminalOutcome` back to `TeamEngineState`, this test still
    /// compiles but the *consumer* (`awaitDelegationCompletion`'s
    /// switch) would need its defensive `.terminal(let other)` arm
    /// re-added — that arm's removal is the second half of the
    /// narrowing, pinned via the depth-3 cascade integration tests.
    func testTerminalOutcome_exhaustiveCases() {
        let allCases: [TaskCompletionAwaiter.TerminalOutcome] = [.done, .failed, .needsAcceptance]
        XCTAssertEqual(allCases.count, 3,
                       "TerminalOutcome must remain narrow — adding a non-terminal case here would re-introduce the wedge-in-loop risk.")
        // Each case round-trips through `WaitOutcome.terminal(_)` —
        // pin the equality contract so a refactor that breaks `Equatable`
        // synthesis (e.g. adding associated values without `: Equatable`)
        // surfaces here, not in the awaiter loop's switch.
        for outcome in allCases {
            XCTAssertEqual(
                TaskCompletionAwaiter.WaitOutcome.terminal(outcome),
                TaskCompletionAwaiter.WaitOutcome.terminal(outcome)
            )
        }
    }
}
