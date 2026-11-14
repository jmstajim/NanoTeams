import XCTest
@testable import NanoTeams

/// When the External Autovisor's filesystem snapshots are taken, what becomes of a snapshot that
/// fails or is slow, and what `task_changes` then says — the orchestrator half of N2–N5, N7, N9,
/// N10, N12, N13 and N16 of the F6 acceptance (2026-11-12). The service is a double given at
/// construction (`MockTaskSnapshotTestDouble`), with a short wait budget so a slow snapshot costs
/// a fraction of a second; `TaskSnapshot*Tests` cover what the service itself stores and reads.
@MainActor
final class ExternalAutovisorSnapshotTriggerTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agentA = AgentIdentity(
        id: UUID(uuidString: "eeeeeeee-1111-2222-3333-444444444441")!,
        label: "Claude Code"
    )
    private var mock: MockTaskSnapshotTestDouble!
    private var team: Team!
    private var folderID: String!

    /// The wait budget the orchestrator under test is built with.
    private let budget: Duration = .milliseconds(300)

    override func setUp() async throws {
        try await super.setUp()
        mock = MockTaskSnapshotTestDouble()
        sut = TestOrchestrator.make(
            embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient,
            taskSnapshotService: mock,
            taskSnapshotWaitBudget: budget)
    }

    override func tearDown() async throws {
        mock = nil
        team = nil
        folderID = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func openExternalFolder(_ dir: URL? = nil) async throws {
        let folder = dir ?? tempDir!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await sut.openWorkFolder(folder)
        team = try XCTUnwrap(sut.snapshot?.workFolder.teams.first {
            !$0.isChatMode && !$0.isHiddenFromPickers && $0.nonSupervisorRoles.count >= 2
        })
        await sut.mutateWorkFolder { $0.setActiveTeam(self.team.id) }
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
    }

    private var roleA: TeamRoleDefinition { team.nonSupervisorRoles[0] }

    private func at(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_799_971_200 + offset)
    }

    private func step(_ role: TeamRoleDefinition, _ status: StepStatus) -> StepExecution {
        StepExecution(
            id: role.id, role: Role.fromDefinition(role), title: role.name, status: status,
            createdAt: at(0), updatedAt: at(0),
            completedAt: [.done, .failed].contains(status) ? at(1) : nil)
    }

    /// A task of this agent's (or the person's, with `origin: nil`), optionally shaped.
    private func task(_ configure: ((inout NTMSTask) -> Void)? = nil) async throws -> Int {
        try await task(origin: .externalAgent(agentA), configure)
    }

    private func task(origin: TaskOrigin?, _ configure: ((inout NTMSTask) -> Void)? = nil) async throws -> Int {
        let created = await sut.createTask(
            title: "Calculator", supervisorTask: "Build a calculator", preferredTeamID: team.id,
            makeActive: false, origin: origin)
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        if let configure {
            _ = await sut.mutateTask(taskID: taskID) { configure(&$0) }
        }
        return taskID
    }

    /// A task with run 0 at `round`, `roleA`'s step in `status`.
    private func taskWithRun(origin: TaskOrigin?, round: Int = 1, roleStatus: StepStatus = .done) async throws -> Int {
        try await task(origin: origin) { task in
            var run = Run(id: 0, createdAt: self.at(0), steps: [self.step(self.roleA, roleStatus)], round: round)
            run.roleStatuses[self.roleA.id] = roleStatus == .done ? .done : .working
            task.runs = [run]
        }
    }

    private func run(_ taskID: Int) throws -> Run {
        try XCTUnwrap(sut.loadedTask(taskID)?.runs.last)
    }

    private func calls(_ taskID: Int, _ phase: TaskSnapshotPhase? = nil) -> [(round: Int, phase: TaskSnapshotPhase)] {
        mock.takeSnapshotCalls
            .filter { $0.taskID == taskID && (phase == nil || $0.phase == phase) }
            .map { ($0.round, $0.phase) }
    }

    /// Polls `condition` — for what a background capture records — instead of sleeping a guess.
    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () throws -> Bool) async rethrows -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if try condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return try condition()
    }

    private func failures(_ taskID: Int) throws -> [String] {
        try run(taskID).snapshotFailures.map { "\($0.round)/\($0.phase.rawValue)/\($0.reason.rawValue)" }.sorted()
    }

    private func call(_ tool: String, _ args: [String: Any]) async -> ToolExecutionResult {
        var args = args
        if args["folder_id"] == nil { args["folder_id"] = folderID }
        return await sut.executeExternalAutovisorTool(name: tool, args: args, agent: agentA)
    }

    private func envelope(_ result: ToolExecutionResult) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
    }

    private struct Boom: Error {}

    // MARK: - The seam

    /// RED under the mutation «the orchestrator builds its own service»: the double given at
    /// construction is the one a run's start reaches (N10 — the test this replaces asserted a
    /// non-optional property was not nil).
    func testTheServiceGivenAtConstruction_takesTheRunsStartSnapshot() async throws {
        try await openExternalFolder()
        let taskID = try await task()

        await sut.startRun(taskID: taskID)

        let first = try XCTUnwrap(mock.takeSnapshotCalls.first { $0.taskID == taskID })
        XCTAssertEqual(first.runID, 0, "runs are numbered from 0")
        XCTAssertEqual(first.round, 1)
        XCTAssertEqual(first.phase, .start)
        XCTAssertEqual(first.workFolder.standardizedFileURL, tempDir.standardizedFileURL)
    }

    /// The start snapshot lands before the engine starts, so the first step's first request
    /// cannot race the tree it is compared against (N10, §3.2 test 3). RED under the mutation
    /// «launch, then snapshot».
    func testStartRun_takesTheStartSnapshotBeforeTheEngineExists() async throws {
        try await openExternalFolder()
        let taskID = try await task()
        var engineDuringSnapshot: Bool?
        mock.onTakeSnapshot = { [weak self] in
            guard let self, engineDuringSnapshot == nil else { return }
            engineDuringSnapshot = self.sut.taskEngines[taskID] != nil
        }

        await sut.startRun(taskID: taskID)

        XCTAssertEqual(engineDuringSnapshot, false, "the engine must not exist while the start snapshot is taken")
        XCTAssertNotNil(sut.taskEngines[taskID], "and the run is launched after it")
    }

    func testShouldCaptureTaskSnapshots_isTopLevelExternalOnly_andReadsTheIndexForAnUnloadedTask() async throws {
        try await openExternalFolder()
        let external = try await task()
        let person = try await task(origin: nil)
        let manager = try await task(origin: .builtInAutovisor)
        let (_, child) = try sut.taskService.createTask(
            at: tempDir, title: "Child", supervisorTask: "Child", parentTaskID: external,
            parentRoleID: roleA.id, delegationDepth: 1, makeActive: false, origin: .externalAgent(agentA))
        await sut.ensureTaskLoaded(child)

        XCTAssertTrue(sut.shouldCaptureTaskSnapshots(taskID: external))
        XCTAssertFalse(sut.shouldCaptureTaskSnapshots(taskID: person))
        XCTAssertFalse(sut.shouldCaptureTaskSnapshots(taskID: manager))
        XCTAssertFalse(sut.shouldCaptureTaskSnapshots(taskID: child))
        XCTAssertFalse(sut.shouldCaptureTaskSnapshots(taskID: 9_999))

        // Evicted: the answer comes from the tasks index (RED under «loaded tasks only»).
        sut.evictLoadedTask(external)
        sut.evictLoadedTask(person)
        XCTAssertNil(sut.loadedTask(external))
        XCTAssertTrue(sut.shouldCaptureTaskSnapshots(taskID: external))
        XCTAssertFalse(sut.shouldCaptureTaskSnapshots(taskID: person))
    }

    // MARK: - N2, N3: every failure is recorded on its round

    func testStartRun_failedStartSnapshot_isRecordedOnRoundOneWithWhatItSaid() async throws {
        try await openExternalFolder()
        let taskID = try await task()
        mock.takeSnapshotError = ExternalAutovisorError("Snapshot add failed: disk full", code: .commandFailed)

        await sut.startRun(taskID: taskID)

        let failure = try XCTUnwrap(try run(taskID).snapshotFailures.first)
        XCTAssertEqual(failure.round, 1)
        XCTAssertEqual(failure.phase, .start)
        XCTAssertEqual(failure.reason, .failed)
        XCTAssertEqual(failure.detail, "Snapshot add failed: disk full", "the error's own text, not Foundation's")
        XCTAssertNotNil(sut.taskEngines[taskID], "a failed snapshot does not hold the launch")
    }

    /// N3, N5, N12: a slow start snapshot neither holds the launch past the budget nor stays
    /// `timed_out` once it lands — it becomes `completed_late`. The test it replaces checked only
    /// the elapsed time, not that the run launched.
    func testStartRun_slowStartSnapshot_launchesInTheBudget_thenRecordsCompletedLate() async throws {
        try await openExternalFolder()
        let taskID = try await task()
        mock.takeSnapshotDelaySeconds = 0.8

        let clock = ContinuousClock()
        let started = clock.now
        await sut.startRun(taskID: taskID)
        let elapsed = clock.now - started

        XCTAssertLessThan(elapsed, .milliseconds(700), "startRun waited \(elapsed)")
        XCTAssertNotNil(sut.taskEngines[taskID], "the run must be launched")
        XCTAssertEqual(try failures(taskID), ["1/start/timed_out"])
        let late = try await eventually { try self.failures(taskID) == ["1/start/completed_late"] }
        let afterLanding = try failures(taskID)
        XCTAssertTrue(late, "after landing: \(afterLanding)")
    }

    /// RED before N2: `restartRole` swallowed both failures (`_ = try?`).
    func testRestartRole_failedSnapshots_areRecordedOnTheRoundEachBelongsTo() async throws {
        try await openExternalFolder()
        let taskID = try await taskWithRun(origin: .externalAgent(agentA))
        mock.takeSnapshotError = Boom()

        await sut.restartRole(taskID: taskID, roleID: roleA.id, comment: "again")

        XCTAssertEqual(calls(taskID).map { "\($0.round)/\($0.phase.rawValue)" }.prefix(2), ["1/restart", "2/start"])
        let recorded = try await eventually { try self.failures(taskID).contains("2/start/failed") }
        XCTAssertTrue(recorded)
        XCTAssertTrue(try failures(taskID).contains("1/restart/failed"))
    }

    /// RED before N2: `requestRevision` swallowed both failures.
    func testRequestRevision_failedSnapshots_areRecordedOnTheRoundEachBelongsTo() async throws {
        try await openExternalFolder()
        let taskID = try await taskWithRun(origin: .externalAgent(agentA))
        mock.takeSnapshotError = Boom()

        await sut.requestRevision(taskID: taskID, roleID: roleA.id, comment: "fix it")

        XCTAssertEqual(calls(taskID).map { "\($0.round)/\($0.phase.rawValue)" }.prefix(2), ["1/revision", "2/start"])
        XCTAssertTrue(try failures(taskID).contains("1/revision/failed"))
        XCTAssertTrue(try failures(taskID).contains("2/start/failed"))
    }

    /// RED before N2: the background end snapshots — review, failure, stop — swallowed theirs.
    func testEngineOutcomes_failedEndSnapshots_areRecorded() async throws {
        try await openExternalFolder()
        let taskID = try await taskWithRun(origin: .externalAgent(agentA))
        mock.takeSnapshotError = Boom()
        let engine = sut.engineForTask(taskID)

        engine.onStateChanged?(.needsAcceptance)
        let review = try await eventually { try self.failures(taskID).contains("1/review/failed") }
        XCTAssertTrue(review)
        engine.onStateChanged?(.failed)
        let failure = try await eventually { try self.failures(taskID).contains("1/failure/failed") }
        XCTAssertTrue(failure)
        sut.stopEngine(for: taskID)
        let stop = try await eventually { try self.failures(taskID).contains("1/stop/failed") }
        XCTAssertTrue(stop)
    }

    /// RED before N2: `closeTask` swallowed it.
    func testCloseTask_failedCloseSnapshot_isRecorded() async throws {
        try await openExternalFolder()
        let taskID = try await taskWithRun(origin: .externalAgent(agentA))
        mock.takeSnapshotError = Boom()

        let closed = await sut.closeTask(taskID: taskID, by: .person)

        XCTAssertTrue(closed)
        XCTAssertEqual(try failures(taskID), ["1/close/failed"])
    }

    /// A landed end snapshot supersedes the failed end snapshots of its round: the last end is
    /// what `task_changes` reads.
    func testLandedEndSnapshot_clearsEarlierEndFailuresOfItsRound() {
        let earlier = [
            RunSnapshotFailure(round: 1, phase: .review, reason: .failed, detail: "x", recordedAt: at(1)),
            RunSnapshotFailure(round: 1, phase: .start, reason: .completedLate, recordedAt: at(1)),
            RunSnapshotFailure(round: 2, phase: .review, reason: .failed, recordedAt: at(1)),
        ]
        let after = NTMSOrchestrator.snapshotFailures(
            earlier, applying: [(TaskSnapshotRequest(round: 1, phase: .stop), .landed)],
            timedOut: [], late: false, at: at(2))
        XCTAssertEqual(after.map { "\($0.round)/\($0.phase.rawValue)" }, ["1/start", "2/review"])

        let late = NTMSOrchestrator.snapshotFailures(
            [RunSnapshotFailure(round: 3, phase: .close, reason: .timedOut, recordedAt: at(1))],
            applying: [(TaskSnapshotRequest(round: 3, phase: .close), .landed)],
            timedOut: [], late: true, at: at(2))
        XCTAssertEqual(late.map(\.reason), [.completedLate])

        let failedAgain = NTMSOrchestrator.snapshotFailures(
            [RunSnapshotFailure(round: 1, phase: .start, reason: .timedOut, recordedAt: at(1))],
            applying: [(TaskSnapshotRequest(round: 1, phase: .start), .failed("boom"))],
            timedOut: [], late: true, at: at(2))
        XCTAssertEqual(failedAgain.map(\.reason), [.failed])
        XCTAssertEqual(failedAgain.first?.detail, "boom")
        XCTAssertTrue(NTMSOrchestrator.snapshotFailures([], applying: [], timedOut: [], late: false, at: at(0)).isEmpty)
    }

    // MARK: - N5: no verb waits past the budget

    /// RED before N5: restart waited for both full snapshots (here 1.6 s) before waking the run.
    func testRestartRole_slowSnapshots_wakeTheRunWithinTheBudget() async throws {
        try await openExternalFolder()
        let taskID = try await taskWithRun(origin: .externalAgent(agentA))
        mock.takeSnapshotDelaySeconds = 0.8

        let clock = ContinuousClock()
        let started = clock.now
        await sut.restartRole(taskID: taskID, roleID: roleA.id, comment: nil)
        let elapsed = clock.now - started

        XCTAssertLessThan(elapsed, .milliseconds(1000), "restartRole waited \(elapsed)")
        XCTAssertNotNil(sut.taskEngines[taskID], "the run is woken")
        XCTAssertEqual(try failures(taskID), ["1/restart/timed_out", "2/start/timed_out"])
    }

    /// RED before N5: the close waited for its full snapshot with the engine still running.
    func testCloseTask_slowSnapshot_closesWithinTheBudget_withTheEngineStoppedFirst() async throws {
        try await openExternalFolder()
        let taskID = try await taskWithRun(origin: .externalAgent(agentA))
        _ = sut.engineForTask(taskID)
        mock.takeSnapshotDelaySeconds = 0.8
        var engineDuringSnapshot: Bool?
        mock.onTakeSnapshot = { [weak self] in
            guard let self, engineDuringSnapshot == nil else { return }
            engineDuringSnapshot = self.sut.taskEngines[taskID] != nil
        }

        let clock = ContinuousClock()
        let started = clock.now
        let closed = await sut.closeTask(taskID: taskID, by: .person)
        let elapsed = clock.now - started

        XCTAssertTrue(closed)
        XCTAssertLessThan(elapsed, .milliseconds(700), "closeTask waited \(elapsed)")
        XCTAssertEqual(engineDuringSnapshot, false, "the engine stops before the close snapshot")
        XCTAssertEqual(try failures(taskID), ["1/close/timed_out"])
    }

    // MARK: - N4, N9: a folder transition during a snapshot writes nothing anywhere

    /// Folder B holds a task with the SAME id. RED before N4: the failure recorded after the wait
    /// went to B's task (or raised "Cannot persist task N: task not loaded.").
    func testStartRun_folderChangesDuringAFailingStartSnapshot_writesNothingIntoTheNextFolder() async throws {
        let folderA = tempDir.appendingPathComponent("A", isDirectory: true)
        let folderB = tempDir.appendingPathComponent("B", isDirectory: true)
        try await openExternalFolder(folderB)
        let inB = try await task { task in task.runs = [Run(id: 0, createdAt: self.at(0), round: 1)] }
        try await openExternalFolder(folderA)
        let inA = try await task()
        XCTAssertEqual(inA, inB, "the fixture needs the same task id in both folders")
        // B's task of that id is LOADED when the snapshot fails — what a write by id reaches.
        mock.onTakeSnapshot = { [weak self] in
            await self?.sut.openWorkFolder(folderB)
            await self?.sut.ensureTaskLoaded(inB)
        }
        mock.takeSnapshotError = Boom()
        let errorsBefore = sut.errorSurfaceCount

        await sut.startRun(taskID: inA)

        XCTAssertEqual(sut.workFolderURL?.standardizedFileURL, folderB.standardizedFileURL)
        await sut.ensureTaskLoaded(inB)
        XCTAssertEqual(try run(inB).snapshotFailures, [], "nothing of A's run reaches B's task")
        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, "and no banner")
        XCTAssertNil(sut.taskEngines[inB], "no engine starts in B")
        XCTAssertEqual(mock.takeSnapshotCalls.map { $0.workFolder.standardizedFileURL }, [folderA.standardizedFileURL])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folderB.appendingPathComponent(".nanoteams/internal/snapshots.git").path))
    }

    /// E1 review R2, RED before 2026-11-12: a create whose folder closed AFTER the task was created
    /// answered "nothing was done in the one this call named" — and an agent without a
    /// `request_key` that believed it created the task again. The refusal names the task it made,
    /// in the message and in `details.task_id`, and its next call claims nothing about it.
    func testCreate_folderChangesAfterTheTaskWasCreated_namesTheTaskItCreated() async throws {
        let folderA = tempDir.appendingPathComponent("A", isDirectory: true)
        let folderB = tempDir.appendingPathComponent("B", isDirectory: true)
        try await openExternalFolder(folderB)
        try await openExternalFolder(folderA)
        let proven = try XCTUnwrap(folderID)
        mock.onTakeSnapshot = { [weak self] in await self?.sut.openWorkFolder(folderB) }

        let result = await call(
            ExternalAutovisorToolNames.createManagedTask,
            ["folder_id": proven, "title": "Calculator", "brief": "Build a calculator"])

        XCTAssertTrue(result.isError, result.outputJSON)
        let reply = try envelope(result)
        let error = try XCTUnwrap(reply["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "FOLDER_CHANGED")
        let createdID = try XCTUnwrap(Int(try XCTUnwrap((error["details"] as? [String: String])?["task_id"])))
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertEqual(message, NTMSOrchestrator.createdBeforeFolderChangedMessage(taskID: createdID))
        XCTAssertTrue(message.contains("Task #\(createdID) was created"), message)
        let next = try XCTUnwrap(reply["next"] as? [String: Any])
        XCTAssertEqual(next["suggested_cmd"] as? String, ExternalAutovisorToolNames.folderStatus)
        let reason = try XCTUnwrap(next["reason"] as? String)
        XCTAssertFalse(reason.contains("nothing was done"), reason)

        // The task the refusal names is the one in the folder the call began in.
        await sut.openWorkFolder(folderA)
        let row = try XCTUnwrap(sut.snapshot?.tasksIndex.tasks.first { $0.id == createdID })
        XCTAssertEqual(row.title, "Calculator")
    }

    /// A create the folder change overtook BEFORE the task existed still says nothing further was
    /// done, with no task to name.
    func testCreate_folderChangesBeforeTheTaskExists_namesNoTask() {
        let refusal = ExternalAutovisorError.folderChanged
        XCTAssertEqual(refusal.message, DeferredCallReplies.folderChanged)
        XCTAssertNil(refusal.details)
        XCTAssertFalse(ExternalNextCall.folderChanged.reason.contains("nothing was done"))
    }

    /// Each snapshot can ask whether this process still holds its folder — true while it does,
    /// false once a switch to another folder let it go (D-M18 R8: a sequence that outlives the
    /// switch must not sweep a store another NanoTeams may have opened).
    func testSnapshots_askWhetherTheFolderIsStillHeld() async throws {
        let folderA = tempDir.appendingPathComponent("A", isDirectory: true)
        let folderB = tempDir.appendingPathComponent("B", isDirectory: true)
        try await openExternalFolder(folderB)
        try await openExternalFolder(folderA)
        let taskID = try await task()
        var heldDuringTheSnapshot: Bool?
        mock.onTakeSnapshot = { [weak self] in
            guard let self, heldDuringTheSnapshot == nil else { return }
            heldDuringTheSnapshot = self.mock.folderStillHeldChecks.last?()
            await self.sut.openWorkFolder(folderB)
        }

        await sut.startRun(taskID: taskID)

        XCTAssertEqual(heldDuringTheSnapshot, true)
        let askA = try XCTUnwrap(mock.folderStillHeldChecks.first)
        XCTAssertFalse(askA(), "A is let go once B is open")
        try await openExternalFolder(folderA)
        XCTAssertTrue(askA(), "and held again once A is open again")
    }

    /// N9: a task WITH a run and a roster role, the folder changing INSIDE the snapshot. RED
    /// under the mutation «no lifecycle check after the snapshots»: the engine started and
    /// reported a state for the task id in B.
    func testRestartRole_folderChangesDuringTheSnapshots_neverStartsTheEngine() async throws {
        let folderA = tempDir.appendingPathComponent("A", isDirectory: true)
        let folderB = tempDir.appendingPathComponent("B", isDirectory: true)
        try await openExternalFolder(folderB)
        try await openExternalFolder(folderA)
        let taskID = try await taskWithRun(origin: .externalAgent(agentA))
        mock.onTakeSnapshot = { [weak self] in
            guard let self, self.sut.workFolderURL?.standardizedFileURL != folderB.standardizedFileURL else { return }
            await self.sut.openWorkFolder(folderB)
        }

        await sut.restartRole(taskID: taskID, roleID: roleA.id, comment: "again")

        XCTAssertEqual(sut.workFolderURL?.standardizedFileURL, folderB.standardizedFileURL)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(sut.taskEngines[taskID])
        XCTAssertNil(sut.engineState[taskID], "no engine reported a state in B")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folderB.appendingPathComponent(".nanoteams/internal/snapshots.git").path))
    }

    /// N9, as above for a revision of a role with completed work — with a task of the same id
    /// LOADED in B, which is what a wake by id after the switch would start.
    func testRequestRevision_folderChangesDuringTheSnapshots_neverWakesTheEngine() async throws {
        let folderA = tempDir.appendingPathComponent("A", isDirectory: true)
        let folderB = tempDir.appendingPathComponent("B", isDirectory: true)
        try await openExternalFolder(folderB)
        let inB = try await taskWithRun(origin: .externalAgent(agentA), roleStatus: .running)
        try await openExternalFolder(folderA)
        let taskID = try await taskWithRun(origin: .externalAgent(agentA))
        XCTAssertEqual(taskID, inB, "the fixture needs the same task id in both folders")
        mock.onTakeSnapshot = { [weak self] in
            guard let self, self.sut.workFolderURL?.standardizedFileURL != folderB.standardizedFileURL else { return }
            await self.sut.openWorkFolder(folderB)
            await self.sut.ensureTaskLoaded(inB)
        }

        await sut.requestRevision(taskID: taskID, roleID: roleA.id, comment: "fix it")

        XCTAssertEqual(sut.workFolderURL?.standardizedFileURL, folderB.standardizedFileURL)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(sut.taskEngines[inB], "no engine is woken for B's task of that id")
        XCTAssertNotEqual(sut.engineState[inB], .running)
        XCTAssertEqual(try run(inB).snapshotFailures, [])
    }

    /// N9, N12: a removed task's snapshots are cleaned in the folder it was removed from, once,
    /// whatever folder is open when the cleanup runs (the test it replaces asserted nothing).
    func testRemoveTask_cleansTheSnapshotsOfItsOwnFolder() async throws {
        let folderA = tempDir.appendingPathComponent("A", isDirectory: true)
        let folderB = tempDir.appendingPathComponent("B", isDirectory: true)
        try await openExternalFolder(folderB)
        try await openExternalFolder(folderA)
        let taskID = try await task()
        mock.onCleanupTask = { [weak self] in await self?.sut.openWorkFolder(folderB) }

        await sut.removeTask(taskID)

        let cleaned = await eventually { self.mock.cleanupTaskCalls.count == 1 }
        XCTAssertTrue(cleaned)
        XCTAssertEqual(mock.cleanupTaskCalls.first?.workFolder.standardizedFileURL, folderA.standardizedFileURL)
        XCTAssertEqual(mock.cleanupTaskCalls.first?.taskID, taskID)
    }

    // MARK: - N12: the triggers, and the tasks they never fire for

    func testReview_isTakenOnAcceptanceAndOnDone() async throws {
        try await openExternalFolder()
        let taskID = try await taskWithRun(origin: .externalAgent(agentA))
        let engine = sut.engineForTask(taskID)

        engine.onStateChanged?(.needsAcceptance)
        let first = await eventually { self.calls(taskID, .review).count == 1 }
        XCTAssertTrue(first)
        engine.onStateChanged?(.done)
        let second = await eventually { self.calls(taskID, .review).count == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(calls(taskID, .review).map(\.round), [1, 1])
    }

    /// The person's task takes no snapshot on ANY trigger. Each background trigger is awaited
    /// through a CONTROL — an agent task's stop, fired after them, whose snapshot arriving means
    /// theirs would have. RED under the mutation «`shouldCaptureTaskSnapshots` answers true»;
    /// the test it replaces checked right after `stopEngine`, before its Task could run.
    func testPersonsTask_takesNoSnapshotOnAnyTrigger() async throws {
        try await openExternalFolder()
        let person = try await taskWithRun(origin: nil)
        let control = try await taskWithRun(origin: .externalAgent(agentA))

        await sut.startRun(taskID: person)
        sut.stopEngine(for: person)
        _ = await sut.mutateTask(taskID: person) { task in
            task.runs[0].steps = [self.step(self.roleA, .done)]
            task.runs[0].roleStatuses[self.roleA.id] = .done
        }
        await sut.requestRevision(taskID: person, roleID: roleA.id, comment: "fix")
        await sut.restartRole(taskID: person, roleID: roleA.id, comment: nil)
        let engine = sut.engineForTask(person)
        engine.onStateChanged?(.needsAcceptance)
        engine.onStateChanged?(.failed)
        sut.stopEngine(for: person)
        _ = await sut.closeTask(taskID: person, by: .person)

        sut.stopEngine(for: control)
        let controlArrived = await eventually { !self.calls(control, .stop).isEmpty }
        XCTAssertTrue(controlArrived)
        XCTAssertTrue(calls(person).isEmpty, "the person's task: \(calls(person))")
    }

    /// RED before N13: a task with no run stopped wrote `…/1/1/stop` — round 1 of its SECOND run.
    func testStop_taskWithoutARun_takesNoSnapshot() async throws {
        try await openExternalFolder()
        let waiting = try await task()
        XCTAssertTrue(try XCTUnwrap(sut.loadedTask(waiting)).runs.isEmpty, "the fixture needs a task with no run")
        let control = try await taskWithRun(origin: .externalAgent(agentA))

        sut.stopEngine(for: waiting)
        sut.stopEngine(for: control)

        let controlArrived = await eventually { !self.calls(control, .stop).isEmpty }
        XCTAssertTrue(controlArrived)
        XCTAssertTrue(calls(waiting).isEmpty, "\(calls(waiting))")
    }

    func testControlTask_closeAndStop_viaTheTool_takeTheirSnapshots() async throws {
        try await openExternalFolder()
        let closing = try await taskWithRun(origin: .externalAgent(agentA))
        let stopping = try await taskWithRun(origin: .externalAgent(agentA))

        let close = await call(ExternalAutovisorToolNames.controlTask, ["task_id": closing, "action": "close"])
        XCTAssertFalse(close.isError, close.outputJSON)
        XCTAssertEqual(calls(closing).map(\.phase), [.close], "a close takes no stop snapshot")

        let stop = await call(ExternalAutovisorToolNames.controlTask, ["task_id": stopping, "action": "stop"])
        XCTAssertFalse(stop.isError, stop.outputJSON)
        let stopped = await eventually { self.calls(stopping, .stop).count == 1 }
        XCTAssertTrue(stopped)
    }

    // MARK: - task_changes over the record (N2, N3, N7, N16)

    /// RED before N2: an omitted round was the latest round WITH a snapshot — after a failed
    /// start, the round before — and its diff came back as if it were the current one.
    func testTaskChanges_omittedRound_isTheRunsCurrentRound_andItsFailedStartIsSaid() async throws {
        try await openExternalFolder()
        let taskID = try await task { task in
            var run = Run(id: 0, createdAt: self.at(0), round: 2)
            run.snapshotFailures = [RunSnapshotFailure(
                round: 2, phase: .start, reason: .failed, detail: "Snapshot add failed: boom", recordedAt: self.at(1))]
            task.runs = [run]
        }
        mock.diffChangesError = TaskSnapshotService.roundDoesNotExist(round: 2, taskID: taskID)

        let result = await call(ExternalAutovisorToolNames.taskChanges, ["task_id": taskID])

        XCTAssertEqual(mock.diffChangesCalls.last?.round, 2, "the current round is asked for")
        let error = try XCTUnwrap(try envelope(result)["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "SNAPSHOTS_UNAVAILABLE")
        let details = try XCTUnwrap(error["details"] as? [String: String])
        XCTAssertEqual(details, ["reason": "failed", "round": "2", "error": "Snapshot add failed: boom"])
    }

    /// A round of the run with no start snapshot and no record is `none_taken`, not "does not
    /// exist" — it exists; a round past the run's is INVALID_ARGS, asked of nobody.
    func testTaskChanges_roundsOfTheRun_versusRoundsPastIt() async throws {
        try await openExternalFolder()
        let taskID = try await task { task in task.runs = [Run(id: 0, createdAt: self.at(0), round: 2)] }
        mock.diffChangesError = TaskSnapshotService.roundDoesNotExist(round: 1, taskID: taskID)

        let inRun = await call(ExternalAutovisorToolNames.taskChanges, ["task_id": taskID, "round": 1])
        let inRunError = try XCTUnwrap(try envelope(inRun)["error"] as? [String: Any])
        XCTAssertEqual(inRunError["code"] as? String, "SNAPSHOTS_UNAVAILABLE")
        XCTAssertEqual((inRunError["details"] as? [String: String])?["reason"], "none_taken")

        let callsBefore = mock.diffChangesCalls.count
        let past = await call(ExternalAutovisorToolNames.taskChanges, ["task_id": taskID, "round": 3])
        let pastError = try XCTUnwrap(try envelope(past)["error"] as? [String: Any])
        XCTAssertEqual(pastError["code"] as? String, "INVALID_ARGS")
        XCTAssertEqual(mock.diffChangesCalls.count, callsBefore, "a round past the run's is not asked of the store")
    }

    /// RED before N3: one failed start refused `task_changes` for every round of the run.
    func testTaskChanges_failedFirstStart_doesNotRefuseALaterRound() async throws {
        try await openExternalFolder()
        let taskID = try await task { task in
            var run = Run(id: 0, createdAt: self.at(0), round: 2)
            run.snapshotFailures = [RunSnapshotFailure(round: 1, phase: .start, reason: .timedOut, recordedAt: self.at(1))]
            task.runs = [run]
        }

        let current = await call(ExternalAutovisorToolNames.taskChanges, ["task_id": taskID])
        XCTAssertFalse(current.isError, current.outputJSON)
        let explicit = await call(ExternalAutovisorToolNames.taskChanges, ["task_id": taskID, "round": 2])
        XCTAssertFalse(explicit.isError, explicit.outputJSON)
        XCTAssertEqual(mock.diffChangesCalls.map(\.round), [2, 2])
        let warnings = (try envelope(current)["meta"] as? [String: Any])?["warnings"] as? [String] ?? []
        XCTAssertTrue(warnings.isEmpty, "round 1's record says nothing about round 2: \(warnings)")
    }

    func testTaskChanges_lateStartAndMissingEnd_areWarnedOnTheirRound() async throws {
        try await openExternalFolder()
        let taskID = try await task { task in
            var run = Run(id: 0, createdAt: self.at(0), round: 1)
            run.snapshotFailures = [
                RunSnapshotFailure(round: 1, phase: .start, reason: .completedLate, recordedAt: self.at(1)),
                RunSnapshotFailure(round: 1, phase: .review, reason: .failed, detail: "x", recordedAt: self.at(2)),
            ]
            task.runs = [run]
        }

        let ended = await call(ExternalAutovisorToolNames.taskChanges, ["task_id": taskID])
        XCTAssertEqual(mock.diffChangesCalls.last?.roundIsOpen, false)
        let endedWarnings = (try envelope(ended)["meta"] as? [String: Any])?["warnings"] as? [String] ?? []
        XCTAssertEqual(endedWarnings, [
            TaskChangesWarnings.lateStartSnapshot(round: 1),
            TaskChangesWarnings.endSnapshotMissing(round: 1, reason: .failed),
        ])

        // An open round is read against the work tree: its missing end is not news.
        sut.engineState[taskID] = .running
        let open = await call(ExternalAutovisorToolNames.taskChanges, ["task_id": taskID])
        XCTAssertEqual(mock.diffChangesCalls.last?.roundIsOpen, true)
        let openWarnings = (try envelope(open)["meta"] as? [String: Any])?["warnings"] as? [String] ?? []
        XCTAssertEqual(openWarnings, [TaskChangesWarnings.lateStartSnapshot(round: 1)])
        sut.engineState[taskID] = nil
    }

    /// N7: which rounds are still going — the current round of an open task whose engine works,
    /// is paused, or waits for an answer.
    func testTaskChangesRoundIsOpen_byEngineStateRoundAndClose() async throws {
        try await openExternalFolder()
        let taskID = try await task { task in task.runs = [Run(id: 0, createdAt: self.at(0), round: 2)] }
        let task = try XCTUnwrap(sut.loadedTask(taskID))
        for state: TeamEngineState in [.pending, .running, .paused, .needsSupervisorInput] {
            sut.engineState[taskID] = state
            XCTAssertTrue(sut.taskChangesRoundIsOpen(task: task, round: 2), "\(state)")
            XCTAssertTrue(sut.taskChangesRoundIsOpen(task: task, round: nil), "\(state)")
            XCTAssertFalse(sut.taskChangesRoundIsOpen(task: task, round: 1), "an earlier round has ended (\(state))")
        }
        for state: TeamEngineState? in [.needsAcceptance, .done, .failed, nil] {
            sut.engineState[taskID] = state
            XCTAssertFalse(sut.taskChangesRoundIsOpen(task: task, round: 2), "\(String(describing: state))")
        }
        sut.engineState[taskID] = .running
        var closed = task
        closed.closedAt = at(5)
        XCTAssertFalse(sut.taskChangesRoundIsOpen(task: closed, round: 2))
        var runless = task
        runless.runs = []
        XCTAssertFalse(sut.taskChangesRoundIsOpen(task: runless, round: nil))
        sut.engineState[taskID] = nil
    }

    /// RED before N16: an error raised after the folder changed reached the agent as the old
    /// folder's `COMMAND_FAILED`.
    func testTaskChanges_errorAfterTheFolderChanged_isFolderChanged() async throws {
        try await openExternalFolder()
        let folderB = tempDir.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        let taskID = try await task { task in task.runs = [Run(id: 0, createdAt: self.at(0), round: 1)] }
        mock.onDiffChanges = { [weak self] in await self?.sut.openWorkFolder(folderB) }
        mock.diffChangesError = ExternalAutovisorError("Snapshot diff failed: gone", code: .commandFailed)

        let result = await call(ExternalAutovisorToolNames.taskChanges, ["task_id": taskID])

        let error = try XCTUnwrap(try envelope(result)["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "FOLDER_CHANGED")
        XCTAssertEqual(error["message"] as? String, DeferredCallReplies.folderChanged)
    }
}

/// The snapshot seam's double: records every call, and can be slowed, made to fail, or made to
/// run a closure (a folder switch) inside a call.
final class MockTaskSnapshotTestDouble: TaskSnapshotProtocol, @unchecked Sendable {
    var takeSnapshotCalls: [(workFolder: URL, taskID: Int, runID: Int, round: Int, phase: TaskSnapshotService.SnapshotPhase)] = []
    var cleanupTaskCalls: [(workFolder: URL, taskID: Int)] = []
    var diffChangesCalls: [(runID: Int?, round: Int?, roundIsOpen: Bool)] = []
    var takeSnapshotDelaySeconds: TimeInterval = 0
    var takeSnapshotError: (any Error)?
    var diffChangesError: (any Error)?
    var onTakeSnapshot: (() async -> Void)?
    var onCleanupTask: (() async -> Void)?
    var onDiffChanges: (() async -> Void)?

    /// Each call's `folderStillHeld`, in call order — asked by a test after the call, to see what
    /// the snapshot would have found then (D-M18 R8).
    var folderStillHeldChecks: [@Sendable () -> Bool] = []

    func takeSnapshot(
        workFolder: URL,
        taskID: Int,
        runID: Int,
        round: Int,
        phase: TaskSnapshotService.SnapshotPhase,
        folderStillHeld: @escaping @Sendable () -> Bool
    ) async throws {
        takeSnapshotCalls.append((workFolder, taskID, runID, round, phase))
        folderStillHeldChecks.append(folderStillHeld)
        if let onTakeSnapshot {
            await onTakeSnapshot()
        }
        if takeSnapshotDelaySeconds > 0 {
            try await Task.sleep(for: .seconds(takeSnapshotDelaySeconds))
        }
        if let takeSnapshotError {
            throw takeSnapshotError
        }
    }

    func diffChanges(
        workFolder: URL,
        folderID: String,
        taskID: Int,
        runID: Int?,
        round: Int?,
        roundIsOpen: Bool,
        page: Int?,
        pageSize: Int?,
        filePath: String?
    ) async throws -> TaskSnapshotService.TaskChangesResult {
        diffChangesCalls.append((runID, round, roundIsOpen))
        if let onDiffChanges {
            await onDiffChanges()
        }
        if let diffChangesError {
            throw diffChangesError
        }
        return TaskSnapshotService.TaskChangesResult(
            folder_id: folderID,
            task_id: taskID,
            round: round ?? 1,
            files: [],
            diff: "",
            page: page ?? 1,
            total_pages: 1,
            has_more: false,
            not_tracked: []
        )
    }

    func listTaskRefs(workFolder: URL, taskID: Int) async throws -> [String] {
        takeSnapshotCalls
            .filter { $0.taskID == taskID }
            .map { "refs/nanoteams/\($0.taskID)/\($0.runID)/\($0.round)/\($0.phase.rawValue)" }
    }

    func cleanupTask(workFolder: URL, taskID: Int) async throws {
        cleanupTaskCalls.append((workFolder, taskID))
        if let onCleanupTask {
            await onCleanupTask()
        }
    }
}
