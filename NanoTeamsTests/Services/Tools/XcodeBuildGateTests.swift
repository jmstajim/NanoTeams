import XCTest

@testable import NanoTeams

/// A runner that BLOCKS for a while and records whether two invocations ever overlapped.
///
/// The overlap counter is the whole point: asserting call ORDER would pass under a gate that
/// does not exist, because two sequential calls in a test are sequential anyway. Only a
/// runner that holds the thread can tell a serialised pair from a concurrent one.
private final class OverlapDetectingRunner: XcodebuildRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxConcurrent = 0
    private(set) var callCount = 0
    private let hold: TimeInterval
    /// Thrown INSTEAD of returning, after the hold — a build that timed out or was killed.
    private let failure: ProcessRunnerError?

    init(hold: TimeInterval = 0.25, failure: ProcessRunnerError? = nil) {
        self.hold = hold
        self.failure = failure
    }

    func run(
        _ arguments: [String], in directory: URL, timeout: TimeInterval
    ) throws -> ProcessRunner.Result {
        lock.withLock {
            inFlight += 1
            callCount += 1
            maxConcurrent = max(maxConcurrent, inFlight)
        }
        Thread.sleep(forTimeInterval: hold)
        lock.withLock { inFlight -= 1 }
        if let failure { throw failure }
        return ProcessRunner.Result(exitCode: 0, stdout: "** BUILD SUCCEEDED **", stderr: "")
    }
}

/// `run_xcodebuild` / `run_xcodetests` hold a process-wide token.
///
/// The tests run the HANDLERS, not `sweep`: `sweep` and `XcodebuildRunning.run` are
/// synchronous by signature, so the handler's `async` closure is the only frame that can
/// suspend, and a gate anywhere deeper would have to be a blocking lock.
final class XcodeBuildGateTests: XCTestCase {

    private var rootA: URL!
    private var rootB: URL!

    override func setUp() async throws {
        try await super.setUp()
        await XcodeBuildGate.shared._testReset()
        rootA = try Self.makeProject()
        rootB = try Self.makeProject()
    }

    override func tearDown() async throws {
        await XcodeBuildGate.shared._testReset()
        for root in [rootA, rootB].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: root)
        }
        rootA = nil
        rootB = nil
        try await super.tearDown()
    }

    private static func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt_gate_\(UUID().uuidString.prefix(8))", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        let paths = NTMSPaths(workFolderRoot: root)
        try FileManager.default.createDirectory(
            at: paths.internalDir, withIntermediateDirectories: true)
        try #"{"selectedScheme":"App"}"#
            .write(to: paths.settingsJSON, atomically: true, encoding: .utf8)
        return root
    }

    private func context(_ root: URL, task: Int, role: String) -> ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: root, taskID: task, runID: 0, roleID: role)
    }

    // MARK: - Exclusion

    /// Two roles building at once share one DerivedData and corrupt each other's `build.db`
    /// — measured in this repository three times (`database is locked`, `0 passed, 0 failed`
    /// under `TEST FAILED`, a `build` killing a running `test-without-building`). Worse than
    /// a failure, because a red build from a lock is indistinguishable from a red build from
    /// the code: a verifier that lost the race reports a failure the change did not cause.
    ///
    /// RED: remove `XcodeBuildGate.withExclusiveAccess` from the handler → `maxConcurrent`
    /// reaches 2.
    func testTwoBuildsInTheSameProcessNeverOverlap() async {
        let runner = OverlapDetectingRunner()
        let tool = RunXcodebuildTool(workFolderRoot: rootA, runner: runner)
        let ctxA = context(rootA, task: 1, role: "architect")
        let ctxB = context(rootA, task: 2, role: "critic")

        async let first = tool.handle(context: ctxA, args: [:])
        async let second = tool.handle(context: ctxB, args: [:])
        _ = await [first, second]

        XCTAssertEqual(runner.maxConcurrent, 1,
                       "two builds must never be in flight at once — DerivedData is shared")
        XCTAssertEqual(runner.callCount, 2, "both calls must still RUN, just not together")
    }

    /// The token is per PROCESS, not per work folder. A folder key would be dead weight (one
    /// folder is open at a time, and `openWorkFolder` cancels every batch before switching)
    /// and actively wrong: `URL ==` splits `/var` from `/private/var` into two gates over one
    /// DerivedData.
    func testBuildAndTestInDifferentFoldersStillSerialise() async {
        let runner = OverlapDetectingRunner()
        let build = RunXcodebuildTool(workFolderRoot: rootA, runner: runner)
        let tests = RunXcodetestsTool(workFolderRoot: rootB, runner: runner)
        let ctxA = context(rootA, task: 1, role: "engineer")
        let ctxB = context(rootB, task: 2, role: "verifier")

        async let first = build.handle(context: ctxA, args: [:])
        async let second = tests.handle(context: ctxB, args: [:])
        _ = await [first, second]

        XCTAssertEqual(runner.maxConcurrent, 1)
    }

    // MARK: - Cancellation

    /// A waiter that is cancelled must never run, and must not be recorded as a failure.
    ///
    /// `ProcessRunnerError.cancelled`, not `CancellationError`: the former has an arm in
    /// `ToolErrorHandler` that emits the unified cancel envelope (code `cancelled`), which
    /// `ToolRuntime.executeOne` logs like any other result of a handler that ran — with a
    /// `queuedMS` equal to the whole wait, see the test below. A `CancellationError` would
    /// fall into the generic classifier and be logged as `COMMAND_FAILED` — an "executed
    /// failure" in every log-based audit, for a build that never started.
    func testCancelledWaiter_neverRuns_andComesBackAsACancellation() async {
        let runner = OverlapDetectingRunner(hold: 0.6)
        let tool = RunXcodebuildTool(workFolderRoot: rootA, runner: runner)

        let holderContext = context(rootA, task: 1, role: "holder")
        let waiterContext = context(rootA, task: 2, role: "waiter")
        let holder = Task { await tool.handle(context: holderContext, args: [:]) }
        // Let the holder take the token before the waiter queues.
        try? await Task.sleep(for: .milliseconds(120))

        let waiter = Task { await tool.handle(context: waiterContext, args: [:]) }
        try? await Task.sleep(for: .milliseconds(80))
        waiter.cancel()

        let waiterResult = await waiter.value
        _ = await holder.value

        XCTAssertTrue(waiterResult.isCancellationEnvelope,
                      "got: \(waiterResult.outputJSON)")
        XCTAssertEqual(runner.callCount, 1,
                       "the cancelled call must not have reached the runner")
    }

    /// The wait survives the throw. A cancelled waiter's envelope carries `queuedMS`, so an
    /// audit reading `durationMS` beside it sees that the WHOLE duration was queue. Until the
    /// evening of 2026-09-11 `withExclusiveAccess` returned the duration only on success —
    /// every failure envelope (cancelled wait, cancelled or timed-out build) was logged
    /// wait-inclusive with no `queuedMS`, the exact misreading the field was added to prevent.
    ///
    /// RED: make `withExclusiveAccess` throw again instead of returning a `Result` → nil.
    func testACancelledWaiter_carriesItsQueuedMS() async {
        let runner = OverlapDetectingRunner(hold: 0.6)
        let tool = RunXcodebuildTool(workFolderRoot: rootA, runner: runner)

        let holderContext = context(rootA, task: 1, role: "holder")
        let waiterContext = context(rootA, task: 2, role: "waiter")
        let holder = Task { await tool.handle(context: holderContext, args: [:]) }
        try? await Task.sleep(for: .milliseconds(120))
        let waiter = Task { await tool.handle(context: waiterContext, args: [:]) }
        try? await Task.sleep(for: .milliseconds(150))
        waiter.cancel()

        let result = await waiter.value
        _ = await holder.value
        XCTAssertTrue(result.isCancellationEnvelope, result.outputJSON)
        XCTAssertGreaterThan(result.queuedMS ?? 0, 100, "the wait must reach the envelope")
    }

    /// Same for a build that started after queueing and then FAILED (here: timed out): the
    /// error envelope still says how long it queued before the compiler got its turn.
    func testAQueuedBuildThatTimesOut_carriesItsQueuedMS() async {
        let holderRunner = OverlapDetectingRunner(hold: 0.4)
        let failingRunner = OverlapDetectingRunner(
            hold: 0.05, failure: .timeout(1, stdout: "", stderr: ""))
        let holderTool = RunXcodebuildTool(workFolderRoot: rootA, runner: holderRunner)
        let failingTool = RunXcodebuildTool(workFolderRoot: rootA, runner: failingRunner)

        let holderContext = context(rootA, task: 1, role: "holder")
        let holder = Task { await holderTool.handle(context: holderContext, args: [:]) }
        try? await Task.sleep(for: .milliseconds(120))
        let queued = await failingTool.handle(context: context(rootA, task: 2, role: "late"), args: [:])
        _ = await holder.value

        XCTAssertTrue(queued.isError, queued.outputJSON)
        XCTAssertTrue(queued.outputJSON.contains("COMMAND_TIMED_OUT"), queued.outputJSON)
        XCTAssertGreaterThan(queued.queuedMS ?? 0, 100, "the wait must reach the error envelope")
        XCTAssertEqual(failingRunner.callCount, 1, "premise: the failing build did run, after the wait")
    }

    /// A cancel that lands AFTER the hand-off — release resumed the waiter, its task has not
    /// left the cancellation-handler scope — must not leave a tombstone in
    /// `cancelledBeforeEnqueue`. Timing-dependent by nature, so it is attempted several
    /// times and the tombstone count must be zero after every settle.
    ///
    /// RED: drop the `live` guard from `cancelWaiter` → an id is inserted and never removed.
    func testACancelThatLandsAfterTheHandOff_leavesNoTombstone() async {
        for _ in 0..<8 {
            await XcodeBuildGate.shared._testReset()
            _ = try? await XcodeBuildGate.shared.acquire(key: nil)
            let waiter = Task { try await XcodeBuildGate.shared.acquire(key: nil) }
            try? await Task.sleep(for: .milliseconds(30))
            await XcodeBuildGate.shared.release()
            waiter.cancel()
            _ = try? await waiter.value
            await XcodeBuildGate.shared.release()
            let tombstones = await XcodeBuildGate.shared._testCancelledBeforeEnqueueCount
            XCTAssertEqual(tombstones, 0)
        }
    }

    /// One step can queue BOTH runners in one batch. The first hand-off must not clear the
    /// step's queue entry while its second waiter is still in line — the caption would
    /// vanish for the whole of the second wait.
    ///
    /// RED: remove the `queue.contains` guard from the release path → the key is gone
    /// after the first hand-off.
    func testTwoWaitersOnOneKey_theKeyStaysQueuedUntilBothAreServed() async {
        let key = TaskStepKey(taskID: 3, stepID: "verifier")
        _ = try? await XcodeBuildGate.shared.acquire(key: nil)
        let first = Task { try await XcodeBuildGate.shared.acquire(key: key) }
        try? await Task.sleep(for: .milliseconds(40))
        let second = Task { try await XcodeBuildGate.shared.acquire(key: key) }
        try? await Task.sleep(for: .milliseconds(40))

        await XcodeBuildGate.shared.release()   // hand-off to `first`
        _ = try? await first.value
        var waiting = await XcodeBuildGate.shared.waiting
        XCTAssertTrue(waiting.contains(key), "the second waiter still carries the key")

        await XcodeBuildGate.shared.release()   // hand-off to `second`
        _ = try? await second.value
        waiting = await XcodeBuildGate.shared.waiting
        XCTAssertFalse(waiting.contains(key), "nobody carries it any more")
        await XcodeBuildGate.shared.release()
    }

    /// …and the token it was waiting for is not lost with it: the next caller gets in.
    func testCancellingAWaiterDoesNotStrandTheToken() async {
        await XcodeBuildGate.shared._testReset()
        let first = try? await XcodeBuildGate.shared.acquire(key: nil)
        XCTAssertNotNil(first)

        let waiterKey = TaskStepKey(taskID: 1, stepID: "w")
        let waiter = Task { try await XcodeBuildGate.shared.acquire(key: waiterKey) }
        try? await Task.sleep(for: .milliseconds(80))
        waiter.cancel()
        await XCTAssertThrowsErrorAsync(try await waiter.value)

        await XcodeBuildGate.shared.release()
        let afterwards = try? await XcodeBuildGate.shared.acquire(key: nil)
        XCTAssertNotNil(afterwards, "the queue must be clean after a cancelled waiter")
        await XcodeBuildGate.shared.release()
    }

    // MARK: - What the wait is visible AS

    /// The queue is published as a set of step keys, so the UI can say WHY a tool call is
    /// taking minutes. A placeholder in `resultJSON` is forbidden instead:
    /// `AutovisorStatus.hasToolInFlight` reads `resultJSON == nil` to mean "in flight", and
    /// filling it would stop `AutovisorStuckEvaluator` suppressing its "hung" verdict — past
    /// `stuckHangSeconds` (180) the queued role would be restarted and lose its conversation.
    func testTheQueueIsObservable_andEmptiesWhenTheTokenIsHandedOver() async {
        let key = TaskStepKey(taskID: 7, stepID: "verifier")
        _ = try? await XcodeBuildGate.shared.acquire(key: nil)

        let waiter = Task { try await XcodeBuildGate.shared.acquire(key: key) }  // key is a local let
        try? await Task.sleep(for: .milliseconds(100))
        var waiting = await XcodeBuildGate.shared.waiting
        XCTAssertTrue(waiting.contains(key), "a queued role must be visible as queued")

        await XcodeBuildGate.shared.release()
        _ = try? await waiter.value
        waiting = await XcodeBuildGate.shared.waiting
        XCTAssertFalse(waiting.contains(key), "handing the token over clears the queue entry")
        await XcodeBuildGate.shared.release()
    }

    /// The queue wait is reported SEPARATELY from the call's duration. `durationMS` in
    /// `tool_calls.jsonl` is suspend-inclusive, so without `queuedMS` the documented
    /// `jq 'select(.durationMS > 500)'` sweep bills the queue to the compiler.
    func testQueuedCallCarriesQueuedMS_andTheFirstOneDoesNot() async {
        let runner = OverlapDetectingRunner(hold: 0.4)
        let tool = RunXcodebuildTool(workFolderRoot: rootA, runner: runner)

        let ctxA = context(rootA, task: 1, role: "a")
        let ctxB = context(rootA, task: 2, role: "b")
        async let first = tool.handle(context: ctxA, args: [:])
        try? await Task.sleep(for: .milliseconds(100))
        async let second = tool.handle(context: ctxB, args: [:])
        let results = await [first, second]

        let queued = results.compactMap(\.queuedMS)
        XCTAssertEqual(queued.count, 1, "exactly one of the pair waited")
        XCTAssertGreaterThan(queued[0], 100, "the wait is the holder's build, ~400 ms")
    }
}

extension XcodeBuildGateTests {

    /// The cancel that arrives BEFORE the waiter has enqueued its continuation. Without the
    /// `cancelledBeforeEnqueue` set the cancel finds an empty queue, does nothing, and the
    /// waiter then parks on a continuation nobody will ever resume — a hang, not a failure.
    ///
    /// RED: drop `cancelledBeforeEnqueue` from `XcodeBuildGate` → this test times out.
    func testCancelArrivingBeforeTheWaiterEnqueues_stillThrows() async {
        _ = try? await XcodeBuildGate.shared.acquire(key: nil)
        let key = TaskStepKey(taskID: 42, stepID: "racer")
        let waiter = Task { try await XcodeBuildGate.shared.acquire(key: key) }
        // No sleep: the cancel races the enqueue on purpose. Either ordering must end in a
        // throw, which is what makes this a race test rather than a timing one.
        waiter.cancel()
        await XCTAssertThrowsErrorAsync(try await waiter.value)

        let waiting = await XcodeBuildGate.shared.waiting
        XCTAssertFalse(waiting.contains(key), "a cancelled waiter must not stay in the queue")
        await XcodeBuildGate.shared.release()
    }

    /// A waiter with no step key — a meeting runtime, a fixture — queues and is served like
    /// any other; it simply contributes nothing for the UI to render.
    func testAKeylessWaiter_queuesAndIsServed_withoutAppearingInTheQueue() async {
        _ = try? await XcodeBuildGate.shared.acquire(key: nil)
        let waiter = Task { try await XcodeBuildGate.shared.acquire(key: nil) }
        try? await Task.sleep(for: .milliseconds(80))
        let waiting = await XcodeBuildGate.shared.waiting
        XCTAssertTrue(waiting.isEmpty, "a keyless waiter has nothing to show")

        await XcodeBuildGate.shared.release()
        let queued = try? await waiter.value
        XCTAssertNotNil(queued, "it still gets the token")
        await XcodeBuildGate.shared.release()
    }

    /// The observer is how the queue reaches the UI at all. One registration point, and it is
    /// told the current state immediately so a late subscriber is not blind until the next
    /// change.
    func testTheObserverIsToldTheQueue_onRegistrationAndOnEveryChange() async {
        let box = ObservedQueues()
        await XcodeBuildGate.shared.setObserver { keys, seq in box.record(keys, seq: seq) }
        XCTAssertEqual(box.snapshots.count, 1, "registration reports the current state")

        _ = try? await XcodeBuildGate.shared.acquire(key: nil)
        let key = TaskStepKey(taskID: 9, stepID: "queued")
        let waiter = Task { try await XcodeBuildGate.shared.acquire(key: key) }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(box.snapshots.contains { $0.contains(key) }, "the queue entry must be reported")

        await XcodeBuildGate.shared.release()
        _ = try? await waiter.value
        XCTAssertEqual(box.snapshots.last, [], "and its removal too")
        // Every notification is numbered, strictly increasing: the consumer hops them to the
        // main actor through unordered tasks and drops any that arrives late.
        XCTAssertEqual(box.seqs, box.seqs.sorted())
        XCTAssertEqual(Set(box.seqs).count, box.seqs.count, "no two notifications share a number")
        await XcodeBuildGate.shared.release()
    }
}

/// A `@Sendable` sink the gate can call from its own executor.
private final class ObservedQueues: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [Set<TaskStepKey>] = []
    private var _seqs: [UInt64] = []
    var snapshots: [Set<TaskStepKey>] { lock.withLock { _snapshots } }
    var seqs: [UInt64] { lock.withLock { _seqs } }
    func record(_ keys: Set<TaskStepKey>, seq: UInt64) {
        lock.withLock { _snapshots.append(keys); _seqs.append(seq) }
    }
}

/// `XCTAssertThrowsError` has no async form.
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected a throw", file: file, line: line)
    } catch {
        // expected
    }
}
