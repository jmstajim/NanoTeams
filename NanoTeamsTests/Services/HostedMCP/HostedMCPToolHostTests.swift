import XCTest

@testable import NanoTeams

/// Holds the run launch open until the test releases it (`NTMSOrchestrator._testRunLaunchGate`),
/// and records what the launch saw on each side of that hold. The closure runs inside the
/// write's own task, so the `Task.isCancelled` it records is the write's cancellation — the one
/// `runLaunchIsStillWanted` reads — and not the test's.
private final class LaunchHold: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var cancelledAfterRelease: [Bool] = []
    let reached: XCTestExpectation

    init(reached: XCTestExpectation) {
        self.reached = reached
    }

    var cancellationSeenAfterRelease: [Bool] {
        lock.withLock { cancelledAfterRelease }
    }

    func hold() async {
        reached.fulfill()
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
        let cancelled = Task.isCancelled
        lock.withLock { cancelledAfterRelease.append(cancelled) }
    }

    func release() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for continuation in pending { continuation.resume() }
    }
}

/// The cancellation channel `HostedMCPDispatcher` hands a tool call: a flag it sets when the
/// request is cancelled.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool { lock.withLock { isSet } }

    func set() { lock.withLock { isSet = true } }
}

/// `HostedMCPToolHost`'s two cancellation rules (§7.3), each pinned by what it is for rather
/// than by the branch it takes:
///  - a read-only call ends when its caller is cancelled: `wait_for_events` comes back well
///    inside its timeout and gives its waiter slot back;
///  - a write does not, once it has passed its commit point: the task it created starts, and
///    `Task.isCancelled` stays false all the way into the run launch. `runLaunchIsStillWanted`
///    refuses a launch whose task is cancelled, so a cancellation that leaked into the write
///    would leave the task created and never started — the outcome the agent's retry cannot
///    see, because its `request_key` already names a task.
@MainActor
final class HostedMCPToolHostTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agent = AgentIdentity(label: "Tool Host Tests")
    private var host: HostedMCPToolHost!
    private var launchHold: LaunchHold?

    override func setUp() async throws {
        try await super.setUp()
        host = HostedMCPToolHost(orchestrator: sut)
    }

    override func tearDown() async throws {
        // Released BEFORE the seam is cleared: a launch left parked on the hold would leak its
        // continuation, which `withCheckedContinuation` reports as a failure.
        launchHold?.release()
        NTMSOrchestrator._testRunLaunchGate = nil
        launchHold = nil
        host = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// A folder an external agent can write to: open, a non-chat team active (the team an
    /// omitted `team_id` resolves to), the Autovisor on, driven by an external agent.
    private func openFolderReadyForExternalWrites() async throws -> String {
        await sut.openWorkFolder(tempDir)
        let team = try XCTUnwrap(
            sut.snapshot?.workFolder.teams.first { !$0.isChatMode && !$0.isHiddenFromPickers })
        await sut.mutateWorkFolder { $0.setActiveTeam(team.id) }
        await sut.setAutovisorDriver(.externalAgent)
        _ = await sut.setAutovisorEnabled(true)
        XCTAssertTrue(
            sut.externalAutovisorReadiness.allowsWrites,
            "fixture: the folder must accept external writes, got \(sut.externalAutovisorReadiness.state)")
        return try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
    }

    private func envelope(_ result: ToolExecutionResult) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))
        return try XCTUnwrap(object as? [String: Any], result.outputJSON)
    }

    private func envelopeData(_ result: ToolExecutionResult) throws -> [String: Any] {
        try XCTUnwrap(try envelope(result)["data"] as? [String: Any], result.outputJSON)
    }

    private func waitForEvents(after cursor: String?) async throws -> [String: Any] {
        var arguments: [String: JSONValue] = ["timeout_seconds": .int(0)]
        if let cursor { arguments["after"] = .string(cursor) }
        let result = await host.executeTool(
            name: ExternalAutovisorToolNames.waitForEvents,
            arguments: arguments,
            agent: agent,
            sessionID: nil,
            isCancelled: { false })
        XCTAssertFalse(result.isError, result.outputJSON)
        return try envelopeData(result)
    }

    // MARK: - Read-only: the caller's cancellation ends the call

    func testCancellingTheCaller_endsAParkedWaitWellInsideItsTimeout_andGivesItsSlotBack() async throws {
        _ = try await openFolderReadyForExternalWrites()
        let host = self.host!
        let agent = self.agent
        let feed = sut.autovisorEventFeed
        let startedAt = ContinuousClock.now

        let caller = Task {
            await host.executeTool(
                name: ExternalAutovisorToolNames.waitForEvents,
                arguments: ["timeout_seconds": .int(20)],
                agent: agent,
                sessionID: nil,
                isCancelled: { false })
        }
        // Parked first: a wait that answered at once (an unarmed feed says `not_ready`) would
        // come back early with or without the cancellation, and prove nothing.
        await waitUntil("the wait parks a waiter for the agent") {
            feed.hasWaitInProgress(forAgentID: agent.id)
        }
        caller.cancel()
        let result = await caller.value
        let elapsed = ContinuousClock.now - startedAt

        XCTAssertLessThan(elapsed, .seconds(5), "a cancelled wait must not run out its 20 s timeout")
        XCTAssertFalse(result.isError, result.outputJSON)
        let data = try envelopeData(result)
        XCTAssertEqual(data["timed_out"] as? Bool, false, result.outputJSON)
        XCTAssertEqual((data["events"] as? [Any])?.count, 0, result.outputJSON)
        XCTAssertNil(data["stop_reason"], "a cancellation is not a stop the feed reports: \(result.outputJSON)")
        XCTAssertFalse(feed.hasWaitInProgress(forAgentID: agent.id), "the cancelled wait must give its slot back")
    }

    func testACallerCancelledBeforeTheWaitBegins_neverParksAWaiter() async throws {
        _ = try await openFolderReadyForExternalWrites()
        let host = self.host!
        let agent = self.agent
        let startedAt = ContinuousClock.now

        let caller = Task {
            await host.executeTool(
                name: ExternalAutovisorToolNames.waitForEvents,
                arguments: ["timeout_seconds": .int(20)],
                agent: agent,
                sessionID: nil,
                isCancelled: { false })
        }
        caller.cancel()
        let result = await caller.value

        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(5))
        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try envelopeData(result)["timed_out"] as? Bool, false, result.outputJSON)
        XCTAssertFalse(sut.autovisorEventFeed.hasWaitInProgress(forAgentID: agent.id))
    }

    // MARK: - Writes: no cancellation after the commit point

    func testCancellingTheCallerAfterTheCommitPoint_letsTheWriteFinishAndStartItsTask() async throws {
        let folderID = try await openFolderReadyForExternalWrites()
        let snapshotBefore = try await waitForEvents(after: nil)
        let cursorBefore = try XCTUnwrap(snapshotBefore["cursor"] as? String)

        let hold = LaunchHold(reached: expectation(description: "the write reached its run launch"))
        launchHold = hold
        NTMSOrchestrator._testRunLaunchGate = { await hold.hold() }

        let host = self.host!
        let agent = self.agent
        let requestCancelled = CancellationFlag()
        let caller = Task {
            await host.executeTool(
                name: ExternalAutovisorToolNames.createManagedTask,
                arguments: [
                    "folder_id": .string(folderID),
                    "title": .string("Committed write"),
                    "brief": .string("Keeps going after its commit point."),
                    "request_key": .string("commit-point-1"),
                ],
                agent: agent,
                sessionID: nil,
                isCancelled: { requestCancelled.value })
        }

        // The launch runs after `createTask` returned: the task exists, the commit point is behind.
        await fulfillment(of: [hold.reached], timeout: 10)
        // Both channels at once, as the dispatcher's modern path does on a closed stream.
        requestCancelled.set()
        caller.cancel()
        hold.release()
        let result = await caller.value

        XCTAssertFalse(result.isError, result.outputJSON)
        let data = try envelopeData(result)
        let taskID = try XCTUnwrap(data["task_id"] as? Int, result.outputJSON)
        XCTAssertEqual(data["status"] as? String, "created_and_started", result.outputJSON)
        XCTAssertEqual(
            hold.cancellationSeenAfterRelease, [false],
            "the caller's cancellation must not reach the write's task after its commit point")
        XCTAssertNotNil(
            sut.taskEngines[taskID],
            "the launch must get past runLaunchIsStillWanted and start the engine")
        XCTAssertEqual(
            NTMSOrchestrator.taskCreated(
                forRequestKey: "commit-point-1", by: agent.id, in: sut.snapshot?.tasksIndex.tasks ?? []),
            taskID,
            "the request_key is the committed task's own, so a retry finds the task")
        XCTAssertFalse(
            sut.autovisorCreationLedger.isRequestInFlight("commit-point-1", for: agent.id),
            "the ledger stops holding the key at the commit")

        // The key the agent recovers by is on the task itself — its index row outlives the process
        // and the folder switch the ledger does not — and no event echoes the agent's own create.
        XCTAssertEqual(
            sut.snapshot?.tasksIndex.tasks.first { $0.id == taskID }?.requestKey, "commit-point-1",
            "the request_key is stored on the task the write committed")
        let delivered = try await waitForEvents(after: cursorBefore)
        let events = try XCTUnwrap(delivered["events"] as? [[String: Any]])
        XCTAssertFalse(
            events.contains { $0["task_id"] as? Int == taskID && $0["kind"] as? String == "created" },
            "the agent has the id from its own call: \(events)")
    }

    func testAWriteCancelledBeforeItsCommitPoint_createsNoTask() async throws {
        let folderID = try await openFolderReadyForExternalWrites()
        let tasksBefore = sut.snapshot?.tasksIndex.tasks.map(\.id) ?? []

        let result = await host.executeTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            arguments: [
                "folder_id": .string(folderID),
                "title": .string("Cancelled write"),
                "brief": .string("Cancelled before anything was written."),
                "request_key": .string("pre-commit-1"),
            ],
            agent: agent,
            sessionID: nil,
            isCancelled: { true })

        XCTAssertTrue(result.isError, result.outputJSON)
        let error = try XCTUnwrap(try envelope(result)["error"] as? [String: Any], result.outputJSON)
        XCTAssertEqual(error["code"] as? String, ToolErrorCode.cancelled.rawValue, result.outputJSON)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.map(\.id) ?? [], tasksBefore)
        XCTAssertNil(NTMSOrchestrator.taskCreated(
            forRequestKey: "pre-commit-1", by: agent.id, in: sut.snapshot?.tasksIndex.tasks ?? []))
        XCTAssertFalse(
            sut.autovisorCreationLedger.isRequestInFlight("pre-commit-1", for: agent.id),
            "a rolled-back create releases its key, so a retry may create")
    }
}
