import XCTest
@testable import NanoTeams

/// F6 wave D2 (2026-11-12) — one task, one status, on every surface the external agent reads it
/// through, and one name for the moment a schedule fires next:
/// - C4: a task the person paused while a role waited at its acceptance gate, evicted from memory,
///   read `acceptance_gate` in the `wait_for_events` heartbeat (which did not hydrate it) and
///   `paused` in `list_tasks` and `task_status` (which did) — so the agent could accept a role in a
///   task the person had stopped;
/// - C6: `waiting` for a scheduled task that never ran is the external mapper's word, read off
///   `TaskSummary.hasRuns`; the domain's `derivedStatusFromActiveRun` (the sidebar, the built-in
///   manager's `list_tasks`, the engine seeding after a restart) answers as it did before F4;
/// - L2: `list_tasks.next_run_at` and `task_status.recurrence.next_fire_at` named one moment twice.
@MainActor
final class ExternalTaskStatusParityTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agent = AgentIdentity(
        id: UUID(uuidString: "eeeeeeee-1111-2222-3333-444444444441")!,
        label: "Claude Code"
    )

    private var team: Team!
    private var folderID: String!

    override func tearDown() async throws {
        team = nil
        folderID = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func openExternalFolder() async throws {
        await sut.openWorkFolder(tempDir)
        let pipeline = try XCTUnwrap(sut.snapshot?.workFolder.teams.first {
            !$0.isChatMode && !$0.isHiddenFromPickers && $0.nonSupervisorRoles.count >= 2
        })
        await sut.mutateWorkFolder { $0.setActiveTeam(pipeline.id) }
        team = pipeline
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
    }

    private var roleA: TeamRoleDefinition { team.nonSupervisorRoles[0] }

    private func task(_ configure: ((inout NTMSTask) -> Void)? = nil) async throws -> Int {
        let created = await sut.createTask(
            title: "Calculator", supervisorTask: "Build a calculator", preferredTeamID: team.id,
            makeActive: false, origin: .externalAgent(agent))
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        if let configure {
            _ = await sut.mutateTask(taskID: taskID) { configure(&$0) }
        }
        return taskID
    }

    private func call(_ tool: String, _ args: [String: Any] = [:]) async -> ToolExecutionResult {
        var args = args
        if args["folder_id"] == nil, tool != ExternalAutovisorToolNames.folderStatus,
           tool != ExternalAutovisorToolNames.waitForEvents {
            args["folder_id"] = folderID
        }
        return await sut.executeExternalAutovisorTool(name: tool, args: args, agent: agent)
    }

    private func data(
        _ result: ToolExecutionResult, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        XCTAssertFalse(result.isError, result.outputJSON, file: file, line: line)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any],
            file: file, line: line)
        return try XCTUnwrap(object["data"] as? [String: Any], file: file, line: line)
    }

    private func listRow(_ taskID: Int) async throws -> [String: Any] {
        let read15 = await call(ExternalAutovisorToolNames.listTasks)
        let rows = try XCTUnwrap(try data(read15)["tasks"] as? [[String: Any]])
        return try XCTUnwrap(rows.first { $0["id"] as? Int == taskID })
    }

    /// The heartbeat row for `taskID`: a wait from the feed's head that times out.
    private func heartbeatRow(_ taskID: Int) async throws -> [String: Any] {
        let read16 = await call(ExternalAutovisorToolNames.folderStatus)
        let cursor = try XCTUnwrap(try data(read16)["event_cursor"] as? String)
        let wait = try data(await call(
            ExternalAutovisorToolNames.waitForEvents, ["after": cursor, "timeout_seconds": 1]))
        XCTAssertEqual(wait["timed_out"] as? Bool, true, "premise: no event, so the heartbeat answers")
        let rows = try XCTUnwrap(wait["tasks"] as? [[String: Any]])
        return try XCTUnwrap(rows.first { $0["task_id"] as? Int == taskID })
    }

    /// A role at its acceptance gate: the step parked on `.needsApproval`, the role
    /// `.needsAcceptance` — the run derives `.paused` with no pause of anyone's.
    private func atTheGate(_ task: inout NTMSTask, pausedBy actor: ControlActor?) {
        var run = Run(
            id: 0,
            steps: [StepExecution(
                id: roleA.id, role: Role.fromDefinition(roleA), title: roleA.name, status: .needsApproval)],
            roleStatuses: [roleA.id: .needsAcceptance],
            round: 1)
        if let actor {
            run.pauseCause = .requested
            run.pauseRequestedBy = actor
        }
        task.runs = [run]
    }

    // MARK: - C4: one status on every surface

    /// RED before D2: the heartbeat read the unloaded row as `acceptance_gate`.
    func testATaskThePersonPausedAtTheGate_readsPausedOnEverySurface_whileUnloaded() async throws {
        try await openExternalFolder()
        let taskID = try await task { self.atTheGate(&$0, pausedBy: .person) }

        sut.evictLoadedTask(taskID)
        XCTAssertNil(sut.loadedTask(taskID), "premise: the task is not in memory")
        let heartbeat = try await heartbeatRow(taskID)["status"] as? String

        sut.evictLoadedTask(taskID)
        let listed = try await listRow(taskID)["status"] as? String

        sut.evictLoadedTask(taskID)
        let detailed = try data(await call(ExternalAutovisorToolNames.taskStatus, ["task_id": taskID]))["status"] as? String

        XCTAssertEqual(listed, "paused")
        XCTAssertEqual(detailed, "paused")
        XCTAssertEqual(heartbeat, "paused", "the heartbeat must not offer a gate the person paused")
    }

    /// The same shape with nobody's pause is a gate on every surface — the hydration the heartbeat
    /// now shares with `list_tasks` must not turn a real gate into a pause.
    func testATaskAtTheGateNobodyPaused_readsAcceptanceGateOnEverySurface_whileUnloaded() async throws {
        try await openExternalFolder()
        let taskID = try await task { self.atTheGate(&$0, pausedBy: nil) }

        sut.evictLoadedTask(taskID)
        let heartbeat = try await heartbeatRow(taskID)["status"] as? String
        sut.evictLoadedTask(taskID)
        let listed = try await listRow(taskID)["status"] as? String

        XCTAssertEqual(listed, "acceptance_gate")
        XCTAssertEqual(heartbeat, "acceptance_gate")
    }

    /// An index row at the gate whose task cannot be read: the mapper does not know whose pause it
    /// is, and the safe answer is the pause — it is the one status that tells the agent to touch
    /// nothing. RED before D2: `acceptance_gate`.
    func testAnUnreadableRowAtTheGate_readsPaused() async throws {
        try await openExternalFolder()
        let summary = TaskSummary(id: 9_999, title: "Gone", status: .paused, hasRolesAwaitingAcceptance: true)
        XCTAssertEqual(sut.externalTaskStatus(for: summary, task: nil).rawValue, "paused")
    }

    // MARK: - Review R2: the heartbeat reads quietly and only its own rows

    /// A wait from the feed's head that times out, and the heartbeat rows it carried.
    private func heartbeatRows() async throws -> [[String: Any]] {
        let status = await call(ExternalAutovisorToolNames.folderStatus)
        let cursor = try XCTUnwrap(try data(status)["event_cursor"] as? String)
        let wait = try data(await call(
            ExternalAutovisorToolNames.waitForEvents, ["after": cursor, "timeout_seconds": 1]))
        return (wait["tasks"] as? [[String: Any]]) ?? []
    }

    /// Another agent's task at the gate is not this agent's row, and the index row says so — the
    /// heartbeat must not read it off disk to find that out. RED before the review fix (R2): the
    /// row was hydrated before the ownership check, loading another's task (and running its
    /// recovery) on every poll.
    func testTheHeartbeat_doesNotLoadAnotherAgentsTaskAtTheGate() async throws {
        try await openExternalFolder()
        let other = AgentIdentity(
            id: UUID(uuidString: "eeeeeeee-1111-2222-3333-444444444442")!, label: "Codex")
        let created = await sut.createTask(
            title: "Theirs", supervisorTask: "x", preferredTeamID: team.id,
            makeActive: false, origin: .externalAgent(other))
        let theirs = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(theirs)
        _ = await sut.mutateTask(taskID: theirs) { self.atTheGate(&$0, pausedBy: nil) }
        sut.evictLoadedTask(theirs)

        let rows = try await heartbeatRows()

        XCTAssertFalse(rows.contains { $0["task_id"] as? Int == theirs }, "premise: not this agent's row")
        XCTAssertNil(sut.loadedTask(theirs), "the heartbeat loaded another agent's task")
    }

    /// A row at the gate whose task.json cannot be read reads `paused` — and a poll that fails to
    /// read it surfaces nothing: the agent's read is not the person's error, and a failure counted
    /// in `errorSurfaceCount` is read as their own by any operation that awaits across the poll
    /// (`errorSurfaced(since:)`). RED before the review fix (R2): every poll counted one.
    func testAnUnreadableRowAtTheGate_isReadQuietly_onEveryPoll() async throws {
        try await openExternalFolder()
        let taskID = try await task { self.atTheGate(&$0, pausedBy: nil) }
        sut.evictLoadedTask(taskID)
        let taskJSON = NTMSPaths(workFolderRoot: tempDir).taskJSON(taskID: taskID)
        try Data("{ not a task".utf8).write(to: taskJSON)
        let before = sut.errorSurfaceCount

        let first = try await heartbeatRows().first { $0["task_id"] as? Int == taskID }
        let second = try await heartbeatRows().first { $0["task_id"] as? Int == taskID }
        let listed = try await listRow(taskID)

        XCTAssertEqual(first?["status"] as? String, "paused")
        XCTAssertEqual(second?["status"] as? String, "paused")
        XCTAssertEqual(listed["status"] as? String, "paused")
        XCTAssertEqual(sut.errorSurfaceCount, before, "a poll's failed read surfaced an error")
        XCTAssertNil(sut.loadedTask(taskID))
    }

    // MARK: - Review R6: what the descriptions list is what the tools send

    /// The values a description lists after `opening` ("status is one of " for a task's, a
    /// step's "status (") up to the first `.`, `—` or `)`.
    nonisolated static func listedStatuses(
        in description: String, after opening: String = "status is one of "
    ) -> Set<String> {
        guard let start = description.range(of: opening) else { return [] }
        let tail = description[start.upperBound...]
        let end = tail.firstIndex { $0 == "." || $0 == "—" || $0 == ")" } ?? tail.endIndex
        return Set(tail[..<end]
            .replacingOccurrences(of: " or ", with: ", ")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    /// A task stopped at the gate with nobody's pause reads `acceptance_gate` in `list_tasks` and
    /// `task_status` — a value both descriptions must list, or an agent that matches the
    /// documented values does not recognise a role waiting for its decision. RED before the
    /// review fix (R6): both listed seven values without it.
    func testTheStatusATaskAtTheGateReads_isOneItsToolsList() async throws {
        try await openExternalFolder()
        let taskID = try await task { self.atTheGate(&$0, pausedBy: nil) }
        let row = try await listRow(taskID)
        let listed = try XCTUnwrap(row["status"] as? String)
        let detail = try data(await call(ExternalAutovisorToolNames.taskStatus, ["task_id": taskID]))
        let detailed = try XCTUnwrap(detail["status"] as? String)
        XCTAssertEqual(listed, "acceptance_gate", "premise")

        let listTasks = Self.listedStatuses(in: HostedMCPCatalog.toolDescription(for: ExternalAutovisorToolNames.listTasks))
        let taskStatus = Self.listedStatuses(in: HostedMCPCatalog.toolDescription(for: ExternalAutovisorToolNames.taskStatus))
        XCTAssertFalse(listTasks.isEmpty || taskStatus.isEmpty, "the scan found no list")
        XCTAssertTrue(listTasks.contains(listed), "list_tasks lists \(listTasks.sorted())")
        XCTAssertTrue(taskStatus.contains(detailed), "task_status lists \(taskStatus.sorted())")
    }

    // MARK: - C6: `waiting` is the external word, not the domain's

    /// RED before D2: F4 made the domain answer `.waiting` here, which reached the sidebar, the
    /// built-in manager's `list_tasks` and the engine seeding — none of which F4 meant to change.
    func testTheDomainStatusOfARecurringTaskThatNeverRan_isWhatItWasBeforeF4() {
        var task = NTMSTask(id: 1, title: "Nightly", supervisorTask: "Check", origin: nil)
        task.recurrence = TaskRecurrence(rule: .interval(seconds: 3_600), nextFireAt: Date().addingTimeInterval(3_600))
        XCTAssertEqual(task.derivedStatusFromActiveRun(), task.status, "no run: the stored status, as before F4")

        task.runs = [Run(id: 0, round: 1)]
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running, "a run with no steps yet: running, as before F4")
        XCTAssertNil(
            NTMSOrchestrator.mapDerivedStatusToEngineState(task.derivedStatusFromActiveRun(), hasSteps: false),
            "a half-built run seeds no engine state after a restart, recurring or not")
    }

    /// The external mapper says `waiting` from the index row alone — `hasRuns == false` beside an
    /// armed schedule. RED before D2: the row's status was `.running`, so the mapper said so.
    func testAnIndexRowThatNeverRan_withAnArmedSchedule_readsWaiting() async throws {
        try await openExternalFolder()
        let armed = TaskSummary(
            id: 1, title: "Nightly", status: .running,
            nextRecurrenceFireAt: Date().addingTimeInterval(3_600), hasRuns: false)
        XCTAssertEqual(sut.externalTaskStatus(for: armed, task: nil).rawValue, "waiting")

        let ran = TaskSummary(
            id: 2, title: "Nightly", status: .running,
            nextRecurrenceFireAt: Date().addingTimeInterval(3_600), hasRuns: true)
        XCTAssertEqual(sut.externalTaskStatus(for: ran, task: nil).rawValue, "running", "a task that ran is not waiting")

        let unscheduled = TaskSummary(id: 3, title: "Once", status: .running, hasRuns: false)
        XCTAssertEqual(sut.externalTaskStatus(for: unscheduled, task: nil).rawValue, "running",
                       "no schedule armed: nothing to wait for")

        let rowBeforeTheField = TaskSummary(
            id: 4, title: "Old", status: .running, nextRecurrenceFireAt: Date().addingTimeInterval(3_600))
        XCTAssertEqual(sut.externalTaskStatus(for: rowBeforeTheField, task: nil).rawValue, "running",
                       "a row written before hasRuns existed says nothing about runs")
    }

    /// A one-shot task scheduled for later reads `waiting` from the detail, the row, and the row of
    /// an evicted task — the three reads of the same fact.
    func testAScheduledTaskThatNeverRan_readsWaitingOnEverySurface() async throws {
        try await openExternalFolder()
        let created = try data(await call(ExternalAutovisorToolNames.createManagedTask, [
            "title": "Later", "brief": "Run later",
            "run_once_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600)),
        ]))
        let taskID = try XCTUnwrap(created["task_id"] as? Int)
        XCTAssertTrue(sut.loadedTask(taskID)?.runs.isEmpty == true, "premise: it has not run")

        let detailed = try data(await call(ExternalAutovisorToolNames.taskStatus, ["task_id": taskID]))["status"] as? String
        let listed = try await listRow(taskID)["status"] as? String
        sut.evictLoadedTask(taskID)
        let listedUnloaded = try await listRow(taskID)["status"] as? String

        XCTAssertEqual(detailed, "waiting")
        XCTAssertEqual(listed, "waiting")
        XCTAssertEqual(listedUnloaded, "waiting")
        XCTAssertNotEqual(sut.snapshot?.tasksIndex.tasks.first { $0.id == taskID }?.status, .waiting,
                          "the index row keeps the domain status; waiting is the external word")
    }

    // MARK: - L2: one name for the next fire

    /// RED before D2: the detail named the moment `next_fire_at`, the row `next_run_at`.
    func testTheNextFire_hasOneNameAndOneValue_inTheRowAndTheDetail() async throws {
        try await openExternalFolder()
        let taskID = try await task()
        _ = try data(await call(ExternalAutovisorToolNames.scheduleTask, ["task_id": taskID, "repeat_every_minutes": 60]))

        let read17 = await call(ExternalAutovisorToolNames.taskStatus, ["task_id": taskID])
        let recurrence = try XCTUnwrap(
            try data(read17)["recurrence"] as? [String: Any])
        let row = try await listRow(taskID)

        XCTAssertNil(recurrence["next_fire_at"], "the old name is gone")
        let detailMoment = try XCTUnwrap(recurrence["next_run_at"] as? String)
        XCTAssertEqual(detailMoment, row["next_run_at"] as? String, "one moment, one value")
    }

    /// A schedule that is no longer armed has no next run on either read — the detail used to
    /// report the stale `nextFireAt` of a disabled rule while the row reported none.
    func testADisabledSchedule_hasNoNextRunOnEitherRead() async throws {
        try await openExternalFolder()
        let lastFired = Date(timeIntervalSince1970: 1_799_971_200)
        let taskID = try await task { task in
            task.recurrence = TaskRecurrence(
                rule: .interval(seconds: 3_600), isEnabled: false,
                nextFireAt: Date().addingTimeInterval(3_600), lastFiredAt: lastFired)
        }

        let read18 = await call(ExternalAutovisorToolNames.taskStatus, ["task_id": taskID])
        let recurrence = try XCTUnwrap(
            try data(read18)["recurrence"] as? [String: Any])
        let row = try await listRow(taskID)

        XCTAssertEqual(recurrence["enabled"] as? Bool, false)
        XCTAssertNil(recurrence["next_run_at"])
        XCTAssertNil(row["next_run_at"])
        XCTAssertEqual(recurrence["last_run_at"] as? String, JSONCoderFactory.iso8601Formatter.string(from: lastFired),
                       "the moment the schedule last started a run, named like the next one")
        XCTAssertNil(recurrence["last_fired_at"], "the old name is gone")
    }
}
