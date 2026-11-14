import XCTest

@testable import NanoTeams

/// The registry around `ApprovalWaiter`. Its bugs are the invisible kind — a leaked hold is a
/// role that never resumes, an un-pruned empty entry is a step that reads as "still waiting"
/// forever — so the pruning and the two sweeps are pinned rather than assumed.
final class ApprovalHoldTableTests: XCTestCase {

    private enum Decision: Sendable, Equatable { case allow, deny, cancelled }

    private var table: ApprovalHoldTable<Decision>!
    private let key = TaskStepKey(taskID: 1, stepID: "engineer")
    private let other = TaskStepKey(taskID: 2, stepID: "engineer")

    override func setUp() {
        super.setUp()
        table = ApprovalHoldTable<Decision>()
    }

    override func tearDown() {
        table = nil
        super.tearDown()
    }

    // MARK: - Registering and releasing

    func testStartsEmpty() {
        XCTAssertTrue(table.isEmpty)
        XCTAssertNil(table[key])
        XCTAssertEqual(table.count, 0)
    }

    func testRegisterMakesTheHoldVisible() {
        _ = table.register(key, holdKey: "rm -rf")
        XCTAssertFalse(table.isEmpty)
        XCTAssertNotNil(table[key]?["rm -rf"])
        XCTAssertEqual(table[key]?.count, 1)
    }

    /// An empty inner map left behind reads as "this step is holding something" to every
    /// `[key] != nil` check downstream.
    func testReleasePrunesTheStepEntry() {
        _ = table.register(key, holdKey: "a")
        table.release(key, holdKey: "a")
        XCTAssertNil(table[key])
        XCTAssertTrue(table.isEmpty)
    }

    func testReleaseKeepsSiblingHolds() {
        _ = table.register(key, holdKey: "a")
        _ = table.register(key, holdKey: "b")
        table.release(key, holdKey: "a")
        XCTAssertNil(table[key]?["a"])
        XCTAssertNotNil(table[key]?["b"])
    }

    func testReleaseOfSomethingNotHeldIsANoOp() {
        table.release(key, holdKey: "never registered")
        XCTAssertTrue(table.isEmpty)
    }

    /// Two tasks on one team share a stepID (invariant #5), so a table keyed by stepID alone
    /// would let one task's teardown resolve the other's held command.
    func testStepsOfDifferentTasksDoNotShareHolds() {
        _ = table.register(key, holdKey: "a")
        _ = table.register(other, holdKey: "a")
        table.failAll(key, with: .cancelled)
        XCTAssertNil(table[key])
        XCTAssertNotNil(table[other]?["a"])
    }

    // MARK: - Resolution

    func testResolveDeliversToTheWaitingGate() async {
        let waiter = table.register(key, holdKey: "a")
        async let decision: Decision = withCheckedContinuation { waiter.attach($0) }
        table.resolve(key, holdKey: "a", with: .allow)
        let received = await decision
        XCTAssertEqual(received, .allow)
    }

    func testResolveOfAnAbsentHoldIsANoOp() {
        // A double-tap, or a tap that lands after Pause, must not crash on a spent hold.
        table.resolve(key, holdKey: "a", with: .allow)
        table.release(key, holdKey: "a")
        XCTAssertTrue(table.isEmpty)
    }

    func testFailAllForOneStepResolvesItsHolds() async {
        let first = table.register(key, holdKey: "a")
        let second = table.register(key, holdKey: "b")
        async let one: Decision = withCheckedContinuation { first.attach($0) }
        async let two: Decision = withCheckedContinuation { second.attach($0) }
        table.failAll(key, with: .cancelled)
        let decisions = await [one, two]
        XCTAssertEqual(decisions, [.cancelled, .cancelled])
        XCTAssertTrue(table.isEmpty)
    }

    /// A held gate that survives a work-folder switch keeps its continuation alive into the
    /// next folder, where task ids repeat.
    func testFailAllSweepsEveryStep() async {
        let first = table.register(key, holdKey: "a")
        let second = table.register(other, holdKey: "b")
        async let one: Decision = withCheckedContinuation { first.attach($0) }
        async let two: Decision = withCheckedContinuation { second.attach($0) }
        table.failAll(with: .cancelled)
        let decisions = await [one, two]
        XCTAssertEqual(decisions, [.cancelled, .cancelled])
        XCTAssertTrue(table.isEmpty)
    }

    /// Idempotent by construction: `ApprovalWaiter` absorbs the second resolution, so a
    /// human's decision that landed first is never overwritten by a teardown sweep.
    func testTeardownDoesNotOverwriteADecisionThatLandedFirst() async {
        let waiter = table.register(key, holdKey: "a")
        async let decision: Decision = withCheckedContinuation { waiter.attach($0) }
        table.resolve(key, holdKey: "a", with: .deny)
        table.failAll(with: .cancelled)
        let received = await decision
        XCTAssertEqual(received, .deny)
    }

    /// A re-issued identical call means the earlier gate already returned; keeping its waiter
    /// would pin a continuation nothing will resume.
    func testRegisteringTheSameHoldKeyReplacesTheWaiter() {
        let first = table.register(key, holdKey: "a")
        let second = table.register(key, holdKey: "a")
        XCTAssertFalse(first === second)
        XCTAssertTrue(table[key]?["a"] === second)
        XCTAssertEqual(table[key]?.count, 1)
    }
}
