import XCTest
@testable import NanoTeams

/// F6 wave D2 (2026-11-12) — the run timeout as an external agent drives it, through the real
/// start, the real watchdog (`evaluateRunTimeouts`) and the real resume, with no engine state
/// set by hand. The step talks to `UnreachableChatClient`, so a started run stays `.running`,
/// retrying, until something pauses it.
/// - C8: what plan F4 §5.1 promised and nothing tested — after `set_timeout` a timed-out pause
///   still reads `timed_out`, never `by_person`; a message wakes it; `set_timeout 0` leaves the
///   pause what it was and arms nothing; a resume and a `request_changes` both continue the run
///   under the new limit; the Automation sheet and the built-in manager re-arm the watchdog like
///   the external call does;
/// - C11: a run that timed out before F4 recorded the limit it crossed (`timedOutAt` without
///   `timedOutAtLimit`) was never re-armed — raising the limit and resuming ran it unbounded;
/// - C7: `set_timeout` measured the age of a run that had already finished and refused any value
///   below it, so a value for the NEXT run could not be set;
/// - C16: `details.elapsed` of that refusal is the run's elapsed time.
@MainActor
final class ExternalRunTimeoutContractTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agent = AgentIdentity(
        id: UUID(uuidString: "eeeeeeee-2222-2222-3333-444444444441")!,
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

    private func call(_ tool: String, _ args: [String: Any] = [:]) async -> ToolExecutionResult {
        var args = args
        if args["folder_id"] == nil, tool != ExternalAutovisorToolNames.waitForEvents {
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

    private func refusal(_ result: ToolExecutionResult) throws -> [String: Any] {
        XCTAssertTrue(result.isError, result.outputJSON)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        return try XCTUnwrap(object["error"] as? [String: Any])
    }

    private func taskStatus(_ taskID: Int) async throws -> [String: Any] {
        try data(await call(ExternalAutovisorToolNames.taskStatus, ["task_id": taskID]))
    }

    /// The agent's task, started for real, and the moment its run began.
    private func startedTask(timeout seconds: Int) async throws -> (taskID: Int, runStart: Date) {
        let created = try data(await call(ExternalAutovisorToolNames.createManagedTask, [
            "title": "Calculator", "brief": "Build a calculator", "team_id": team.id,
            "run_timeout_seconds": seconds,
        ]))
        let taskID = try XCTUnwrap(created["task_id"] as? Int)
        // Its first step RUNNING, not just the engine: a Pause that lands before the first step
        // starts stops a pending step, which stays pending (see D-M18, C8).
        await waitUntil("the run is under way") {
            self.sut.taskEngineStates[taskID] == .running
                && self.sut.loadedTask(taskID)?.runs.last?.steps.contains { $0.status == .running } == true
        }
        let runStart = try XCTUnwrap(sut.loadedTask(taskID)?.runs.last?.createdAt)
        return (taskID, runStart)
    }

    /// The watchdog, run at `offset` seconds into the run.
    private func watchdog(at runStart: Date, plus offset: TimeInterval) async {
        await sut.evaluateRunTimeouts(now: runStart.addingTimeInterval(offset))
    }

    /// A started task the watchdog paused for crossing `limit`.
    private func timedOutTask(limit: Int) async throws -> (taskID: Int, runStart: Date) {
        let started = try await startedTask(timeout: limit)
        await watchdog(at: started.runStart, plus: TimeInterval(limit + 10))
        await waitUntil("the watchdog paused the run and its step") {
            let status = try? await self.taskStatus(started.taskID)
            return self.sut.taskEngineStates[started.taskID] == .paused
                && status?["pause_reason"] as? String == "timed_out"
        }
        return started
    }

    private func setTimeout(_ taskID: Int, _ seconds: Int) async -> ToolExecutionResult {
        await call(ExternalAutovisorToolNames.controlTask,
                   ["task_id": taskID, "action": "set_timeout", "timeout_seconds": seconds])
    }

    private func resume(_ taskID: Int) async throws {
        _ = try data(await call(ExternalAutovisorToolNames.controlTask, ["task_id": taskID, "action": "resume"]))
        await waitUntil("the run resumed") { self.sut.taskEngineStates[taskID] == .running }
    }

    private func pauseCause(_ taskID: Int) -> Run.PauseCause? {
        sut.loadedTask(taskID)?.runs.last?.pauseCause
    }

    // MARK: - C8: the timed-out pause after set_timeout

    /// §5.1 test 1: raising the limit on a timed-out pause leaves it the watchdog's pause — never
    /// the person's — in `task_status` and in the events, and a message wakes it.
    func testATimedOutPause_afterSetTimeout_isStillTimedOut_andAMessageWakesIt() async throws {
        try await openExternalFolder()
        let (taskID, _) = try await timedOutTask(limit: 60)

        _ = try data(await setTimeout(taskID, 300))

        let read11 = try await taskStatus(taskID)
        XCTAssertEqual(read11["pause_reason"] as? String, "timed_out")
        XCTAssertFalse(sut.isPausedInTheApp(taskID: taskID), "the watchdog's pause is not the person's")
        let snapshot = try data(await call(ExternalAutovisorToolNames.waitForEvents, ["timeout_seconds": 1]))
        let paused = ((snapshot["events"] as? [[String: Any]]) ?? []).filter {
            $0["task_id"] as? Int == taskID && $0["kind"] as? String == "paused"
        }
        XCTAssertEqual(paused.map { $0["pause_reason"] as? String }, ["timed_out"],
                       "one standing pause, the watchdog's: \(snapshot)")

        let message = try data(await call(ExternalAutovisorToolNames.messageTask,
                                          ["task_id": taskID, "message": "Carry on."]))
        XCTAssertNotEqual(message["status"] as? String, AutovisorActionOutcome.queuedPausedByPerson.rawValue,
                          "a message to the watchdog's pause is not held for the person: \(message)")
        await waitUntil("the message woke the run") { self.sut.taskEngineStates[taskID] == .running }
    }

    /// §5.1 test 3: after the limit is raised and the run resumed, the watchdog does not fire below
    /// the new limit and fires above it — the same run, measured from its start.
    func testRaisingTheLimitAndResuming_reArmsTheWatchdogAtTheNewLimit() async throws {
        try await openExternalFolder()
        let (taskID, runStart) = try await timedOutTask(limit: 60)
        let firstStamp = try XCTUnwrap(sut.loadedTask(taskID)?.runs.last?.timedOutAt)

        _ = try data(await setTimeout(taskID, 300))
        try await resume(taskID)

        await watchdog(at: runStart, plus: 250)
        XCTAssertEqual(sut.taskEngineStates[taskID], .running, "below the new limit nothing fires")

        await watchdog(at: runStart, plus: 310)
        await waitUntil("the watchdog fired at the new limit") { self.sut.taskEngineStates[taskID] == .paused }
        XCTAssertEqual(pauseCause(taskID), .runTimedOut)
        XCTAssertGreaterThan(try XCTUnwrap(sut.loadedTask(taskID)?.runs.last?.timedOutAt), firstStamp)
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.timedOutAtLimit, 300)
    }

    /// §5.1 test 3, the other way out of the pause: the limit raised, then `manage_role
    /// request_changes` on a role whose work is in — the revision wakes the run, and the watchdog
    /// measures the same run against the new limit.
    func testRaisingTheLimitAndRequestingChanges_reArmsTheWatchdogAtTheNewLimit() async throws {
        try await openExternalFolder()
        let (taskID, runStart) = try await timedOutTask(limit: 60)
        let firstStamp = try XCTUnwrap(sut.loadedTask(taskID)?.runs.last?.timedOutAt)
        // The role's work came in just before the watchdog fired: its step is done.
        _ = await sut.mutateTask(taskID: taskID) { task in
            let r = task.runs.count - 1
            guard let s = task.runs[r].steps.firstIndex(where: { $0.effectiveRoleID == self.roleA.id }) else { return }
            task.runs[r].steps[s].status = .done
            task.runs[r].roleStatuses[self.roleA.id] = .done
        }

        _ = try data(await setTimeout(taskID, 300))
        _ = try data(await call(ExternalAutovisorToolNames.manageRole, [
            "task_id": taskID, "role_id": roleA.id, "action": "request_changes", "comment": "Add tests.",
        ]))
        await waitUntil("the revision woke the run") { self.sut.taskEngineStates[taskID] == .running }

        await watchdog(at: runStart, plus: 250)
        XCTAssertEqual(sut.taskEngineStates[taskID], .running, "below the new limit nothing fires")
        await watchdog(at: runStart, plus: 310)
        await waitUntil("the watchdog fired at the new limit") { self.sut.taskEngineStates[taskID] == .paused }
        XCTAssertEqual(pauseCause(taskID), .runTimedOut)
        XCTAssertGreaterThan(try XCTUnwrap(sut.loadedTask(taskID)?.runs.last?.timedOutAt), firstStamp,
                             "a second firing, not the first one read again")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.timedOutAtLimit, 300)
    }

    /// §5.1 test 4: clearing the timeout on a timed-out pause does not turn it into a person's
    /// pause, and the resumed run has no watchdog at all.
    func testClearingTheTimeoutOnATimedOutPause_keepsItTimedOut_andArmsNothing() async throws {
        try await openExternalFolder()
        let (taskID, runStart) = try await timedOutTask(limit: 60)
        let firstStamp = sut.loadedTask(taskID)?.runs.last?.timedOutAt

        _ = try data(await setTimeout(taskID, 0))
        XCTAssertNil(sut.loadedTask(taskID)?.runTimeoutSeconds)
        let read12 = try await taskStatus(taskID)
        XCTAssertEqual(read12["pause_reason"] as? String, "timed_out")

        try await resume(taskID)
        await watchdog(at: runStart, plus: 86_400)
        XCTAssertEqual(sut.taskEngineStates[taskID], .running, "no limit, no watchdog")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.timedOutAt, firstStamp, "the history stays")
    }

    /// §5.1 test 5: the Automation sheet sets the limit through the same seam and re-arms the same.
    func testTheAutomationSheet_reArmsTheWatchdogLikeTheExternalCall() async throws {
        try await openExternalFolder()
        let (taskID, runStart) = try await timedOutTask(limit: 60)

        await sut.setTaskRunTimeout(taskID: taskID, seconds: 300)
        await sut.resumeRun(taskID: taskID)
        await waitUntil("the run resumed") { self.sut.taskEngineStates[taskID] == .running }

        await watchdog(at: runStart, plus: 250)
        XCTAssertEqual(sut.taskEngineStates[taskID], .running)
        await watchdog(at: runStart, plus: 310)
        await waitUntil("the watchdog fired at the new limit") { self.sut.taskEngineStates[taskID] == .paused }
        XCTAssertEqual(pauseCause(taskID), .runTimedOut)
    }

    /// §5.1 test 5, the built-in manager's `control_task set_timeout`: the same seam again.
    func testTheBuiltInManagersSetTimeout_reArmsTheWatchdog() async throws {
        try await openExternalFolder()
        let (taskID, runStart) = try await timedOutTask(limit: 60)
        // The built-in manager acts only while it drives the folder.
        await sut.setAutovisorDriver(.builtInModel)

        let result = await sut.performAutovisorAction(
            .controlTask(taskID: taskID, verb: .setTimeout(seconds: 300)),
            as: .builtInManager, within: sut.currentFolderLifecycle)
        XCTAssertTrue(result.ok, result.message)
        await sut.resumeRun(taskID: taskID)
        await waitUntil("the run resumed") { self.sut.taskEngineStates[taskID] == .running }

        await watchdog(at: runStart, plus: 250)
        XCTAssertEqual(sut.taskEngineStates[taskID], .running)
        await watchdog(at: runStart, plus: 310)
        await waitUntil("the watchdog fired at the new limit") { self.sut.taskEngineStates[taskID] == .paused }
    }

    // MARK: - C11: a timeout recorded before the limit was

    /// RED before D2: with `timedOutAtLimit` absent, `isArmed` was false for ever — the raised limit
    /// and the resume ran the run with no watchdog.
    func testARunThatTimedOutBeforeF4_isReArmedWhenTheLimitIsRaised() async throws {
        try await openExternalFolder()
        let (taskID, runStart) = try await timedOutTask(limit: 60)
        // The record a build before F4 wrote: the stamp, no limit beside it.
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[task.runs.count - 1].timedOutAtLimit = nil
        }

        _ = try data(await setTimeout(taskID, 300))
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.timedOutAtLimit, 60,
                       "the limit the run crossed is the one it had before the change")
        try await resume(taskID)

        await watchdog(at: runStart, plus: 250)
        XCTAssertEqual(sut.taskEngineStates[taskID], .running)
        await watchdog(at: runStart, plus: 310)
        await waitUntil("the watchdog fired at the new limit") { self.sut.taskEngineStates[taskID] == .paused }
        XCTAssertEqual(pauseCause(taskID), .runTimedOut)
    }

    /// The same record with no limit left on the task (cleared since): the limit it crossed is
    /// read off the run itself — it had run `timedOutAt − createdAt` when the watchdog fired.
    func testARunThatTimedOutBeforeF4_withTheLimitClearedSince_takesItsLimitFromTheRun() async throws {
        try await openExternalFolder()
        let (taskID, runStart) = try await timedOutTask(limit: 60)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[task.runs.count - 1].timedOutAtLimit = nil
            task.runs[task.runs.count - 1].timedOutAt = runStart.addingTimeInterval(70)
            task.runTimeoutSeconds = nil
        }

        _ = try data(await setTimeout(taskID, 300))
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.timedOutAtLimit, 70)
    }

    // MARK: - C7: set_timeout on a run that has finished

    /// RED before D2: the run in review, two hours old, refused any value under 7200 s — the agent
    /// could not set a limit for the next run without closing the task first.
    func testSetTimeout_onARunInReviewOlderThanTheValue_isAccepted() async throws {
        try await openExternalFolder()
        let createdTaskID = await sut.createTask(
            title: "Done", supervisorTask: "x", preferredTeamID: team.id, makeActive: false,
            origin: .externalAgent(agent))
        let taskID = try XCTUnwrap(createdTaskID)
        await sut.ensureTaskLoaded(taskID)
        let twoHoursAgo = Date().addingTimeInterval(-7_200)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0, createdAt: twoHoursAgo,
                steps: [StepExecution(id: self.roleA.id, role: Role.fromDefinition(self.roleA),
                                      title: self.roleA.name, status: .done)],
                roleStatuses: [self.roleA.id: .needsAcceptance], round: 1)]
        }
        let read13 = try await taskStatus(taskID)
        XCTAssertEqual(read13["status"] as? String, "review", "premise")

        _ = try data(await setTimeout(taskID, 1_800))
        XCTAssertEqual(sut.loadedTask(taskID)?.runTimeoutSeconds, 1_800)
    }

    /// A task whose last run is in review, two hours old. Its reply to `set_timeout`.
    private func reviewTaskReply(settingTimeout seconds: Int) async throws -> (data: [String: Any], warnings: [String]) {
        try await openExternalFolder()
        let createdTaskID = await sut.createTask(
            title: "In review", supervisorTask: "x", preferredTeamID: team.id, makeActive: false,
            origin: .externalAgent(agent))
        let taskID = try XCTUnwrap(createdTaskID)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0, createdAt: Date().addingTimeInterval(-7_200),
                steps: [StepExecution(id: self.roleA.id, role: Role.fromDefinition(self.roleA),
                                      title: self.roleA.name, status: .done)],
                roleStatuses: [self.roleA.id: .needsAcceptance], round: 1)]
        }
        let read = try await taskStatus(taskID)
        XCTAssertEqual(read["status"] as? String, "review", "premise")
        let result = await setTimeout(taskID, seconds)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let warnings = ((object["meta"] as? [String: Any])?["warnings"] as? [String]) ?? []
        return (try data(result), warnings)
    }

    /// Review R4: a run in review is not being watched, so the reply carries no deadline and no
    /// countdown for it — and when the run is older than the value, it says what continuing it
    /// does: the watchdog measures a continuation from the run's start and pauses it at once.
    /// RED before the fix: `deadline_at` 1.5 h in the past and `remaining` 0, with nothing to say
    /// what they mean.
    func testSetTimeout_onARunInReviewOlderThanTheValue_reportsNoDeadline_andWarnsAContinuationPauses() async throws {
        let (reply, warnings) = try await reviewTaskReply(settingTimeout: 1_800)

        let timeout = try XCTUnwrap(reply["timeout"] as? [String: Any])
        XCTAssertEqual(timeout["value"] as? Int, 1_800)
        XCTAssertNil(timeout["deadline_at"], "no run is being watched: \(timeout)")
        XCTAssertNil(timeout["remaining"], "no run is being watched: \(timeout)")
        XCTAssertEqual(warnings.count, 1, "\(warnings)")
        XCTAssertTrue(warnings.first?.contains("next tick") == true, "\(warnings)")
    }

    /// A value above the finished run's age: nothing a continuation would trip over, so no warning.
    func testSetTimeout_onARunInReviewYoungerThanTheValue_warnsNothing() async throws {
        let (reply, warnings) = try await reviewTaskReply(settingTimeout: 10_800)

        let timeout = try XCTUnwrap(reply["timeout"] as? [String: Any])
        XCTAssertEqual(timeout["value"] as? Int, 10_800)
        XCTAssertNil(timeout["deadline_at"])
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }

    /// Clearing the limit warns of nothing either.
    func testSetTimeout_clearedOnARunInReview_warnsNothing() async throws {
        let (reply, warnings) = try await reviewTaskReply(settingTimeout: 0)

        let timeout = try XCTUnwrap(reply["timeout"] as? [String: Any])
        XCTAssertEqual(timeout["value"] as? Int, 0)
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }

    /// The same for a failed run.
    func testSetTimeout_onAFailedRunOlderThanTheValue_isAccepted() async throws {
        try await openExternalFolder()
        let createdTaskID = await sut.createTask(
            title: "Failed", supervisorTask: "x", preferredTeamID: team.id, makeActive: false,
            origin: .externalAgent(agent))
        let taskID = try XCTUnwrap(createdTaskID)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0, createdAt: Date().addingTimeInterval(-7_200),
                steps: [StepExecution(id: self.roleA.id, role: Role.fromDefinition(self.roleA),
                                      title: self.roleA.name, status: .failed)],
                roleStatuses: [self.roleA.id: .failed], round: 1)]
        }
        let read14 = try await taskStatus(taskID)
        XCTAssertEqual(read14["status"] as? String, "failed", "premise")

        _ = try data(await setTimeout(taskID, 1_800))
    }

    /// A run still going keeps the refusal, and its `details.elapsed` is the run's elapsed time.
    func testSetTimeout_onARunStillGoing_atOrBelowItsElapsedTime_isRefusedWithTheElapsedTime() async throws {
        try await openExternalFolder()
        let (taskID, _) = try await startedTask(timeout: 3_600)
        let runStart = Date().addingTimeInterval(-100)
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[$0.runs.count - 1].createdAt = runStart }
        let before = Int(Date().timeIntervalSince(runStart))

        let refused = try refusal(await setTimeout(taskID, 100))
        let after = Int(Date().timeIntervalSince(runStart))

        XCTAssertEqual(refused["code"] as? String, "INVALID_ARGS")
        let details = try XCTUnwrap(refused["details"] as? [String: Any])
        let elapsed = try XCTUnwrap(Int(try XCTUnwrap(details["elapsed"] as? String)))
        XCTAssertGreaterThanOrEqual(elapsed, before)
        XCTAssertLessThanOrEqual(elapsed, after + 1, "the refusal reads the clock a moment later")
        XCTAssertEqual(sut.loadedTask(taskID)?.runTimeoutSeconds, 3_600, "a refused value changes nothing")
    }

    /// A paused run is still going — resume continues it — so it keeps the refusal too.
    func testSetTimeout_onATimedOutPause_atOrBelowItsElapsedTime_isRefused() async throws {
        try await openExternalFolder()
        let (taskID, _) = try await timedOutTask(limit: 60)
        _ = await sut.mutateTask(taskID: taskID) {
            $0.runs[$0.runs.count - 1].createdAt = Date().addingTimeInterval(-100)
        }
        let refused = try refusal(await setTimeout(taskID, 90))
        XCTAssertEqual(refused["code"] as? String, "INVALID_ARGS")
        XCTAssertEqual(sut.loadedTask(taskID)?.runTimeoutSeconds, 60)
    }
}
