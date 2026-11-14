import XCTest
@testable import NanoTeams

/// A Pause the person pressed in the app is theirs to lift — in the code, not only in the text an
/// automated Supervisor reads (Alex's decision, 2026-11-12; `DEBTS.md` D-M18). Until then
/// `control_task resume`, `control_task start` and `manage_role correct` lifted it like any other
/// pause, and only `HostedMCPInstructions` ("by_person, do not resume") told the agent to leave it.
///
/// Driven through `executeExternalAutovisorTool` — the agent's own seam, code, `details` and
/// `next` included — and through `performAutovisorAction` for the built-in manager, which is held
/// to the same rule for the person's Pause and not for its own.
@MainActor
final class PersonsPauseGateTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agentA = AgentIdentity(
        id: UUID(uuidString: "aaaaaaaa-5555-6666-7777-888888888881")!,
        label: "Claude Code"
    )

    private var folderID: String!

    override func tearDown() async throws {
        folderID = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func openExternalFolder() async throws {
        await sut.openWorkFolder(tempDir)
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
    }

    /// A task with one step running — what a Pause actually stops. `origin` says whose it is.
    private func runningTask(origin: TaskOrigin?) async throws -> Int {
        let created = await sut.createTask(
            title: "Calculator", supervisorTask: "Build a calculator", makeActive: false, origin: origin)
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .running)],
                roleStatuses: ["eng": .working]
            )]
        }
        return taskID
    }

    private func ownRunningTask() async throws -> Int {
        try await runningTask(origin: .externalAgent(agentA))
    }

    /// The agent's task, paused by the person in the app.
    private func ownTaskPausedByThePerson() async throws -> Int {
        let taskID = try await ownRunningTask()
        let paused = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(paused, "premise: the person's Pause stopped the step")
        let reason = try await taskStatus(taskID)["pause_reason"] as? String
        XCTAssertEqual(reason, "by_person", "premise")
        return taskID
    }

    private func call(_ tool: String, _ args: [String: Any]) async -> ToolExecutionResult {
        var args = args
        args["folder_id"] = folderID
        return await sut.executeExternalAutovisorTool(name: tool, args: args, agent: agentA)
    }

    private func control(_ taskID: Int, _ action: String) async -> ToolExecutionResult {
        await call(ExternalAutovisorToolNames.controlTask, ["task_id": taskID, "action": action])
    }

    private func correct(_ taskID: Int) async -> ToolExecutionResult {
        await call(ExternalAutovisorToolNames.manageRole, [
            "task_id": taskID, "role_id": "eng", "action": "correct", "comment": "Use SQLite.",
        ])
    }

    private func envelope(_ result: ToolExecutionResult) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
    }

    private func refusal(_ result: ToolExecutionResult) throws -> (error: [String: Any], next: [String: Any]?) {
        XCTAssertTrue(result.isError, result.outputJSON)
        let object = try envelope(result)
        return (try XCTUnwrap(object["error"] as? [String: Any], result.outputJSON), object["next"] as? [String: Any])
    }

    private func taskStatus(_ taskID: Int) async throws -> [String: Any] {
        let result = await call(ExternalAutovisorToolNames.taskStatus, ["task_id": taskID])
        return try XCTUnwrap(try envelope(result)["data"] as? [String: Any], result.outputJSON)
    }

    private func run(_ taskID: Int) -> Run? { sut.loadedTask(taskID)?.runs.last }

    /// The person's pause, as it stands: the cause, its requester, the timeline and the step.
    private struct PauseRecord: Equatable {
        let runCount: Int
        let cause: Run.PauseCause?
        let requester: ControlActor?
        let timeline: [SupervisorTimelineEvent.Kind]
        let stepStatus: StepStatus?
        let stepMessages: Int
        let conversation: Int
        let revisionComment: String?
        let engine: TeamEngineState?
    }

    private func record(_ taskID: Int) -> PauseRecord {
        let step = run(taskID)?.steps.first
        return PauseRecord(
            runCount: sut.loadedTask(taskID)?.runs.count ?? 0,
            cause: run(taskID)?.pauseCause,
            requester: run(taskID)?.pauseRequestedBy,
            timeline: run(taskID)?.supervisorEvents.map(\.kind) ?? [],
            stepStatus: step?.status,
            stepMessages: step?.messages.count ?? 0,
            conversation: step?.llmConversation.count ?? 0,
            revisionComment: step?.revisionComment,
            engine: sut.taskEngineStates[taskID])
    }

    /// What every refusal of a person's pause carries: its code, the reason in `details`, a
    /// message that says whose pause it is, and a `next` that waits for their resume.
    private func assertRefusedForThePersonsPause(
        _ result: ToolExecutionResult, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let (error, next) = try refusal(result)
        XCTAssertEqual(error["code"] as? String, "PAUSED_BY_PERSON", result.outputJSON, file: file, line: line)
        XCTAssertEqual((error["details"] as? [String: Any])?["pause_reason"] as? String, "by_person",
                       result.outputJSON, file: file, line: line)
        let message = try XCTUnwrap(error["message"] as? String, file: file, line: line)
        XCTAssertTrue(message.contains("the person paused"), message, file: file, line: line)
        XCTAssertTrue(message.contains("only they can resume it"), message, file: file, line: line)
        XCTAssertEqual(next?["suggested_cmd"] as? String, ExternalAutovisorToolNames.waitForEvents,
                       result.outputJSON, file: file, line: line)
        XCTAssertNil((next?["suggested_args"] as? [String: Any])?["folder_id"],
                     "wait_for_events takes no folder_id: \(result.outputJSON)", file: file, line: line)
        XCTAssertFalse((next?["reason"] as? String)?.isEmpty ?? true, file: file, line: line)
    }

    // MARK: - The agent on the person's pause

    func testResume_ofThePersonsPause_isRefused_andTheTaskStaysPaused() async throws {
        try await openExternalFolder()
        let taskID = try await ownTaskPausedByThePerson()
        let before = record(taskID)

        let resumed = await control(taskID, "resume")
        try assertRefusedForThePersonsPause(resumed)

        XCTAssertEqual(record(taskID), before, "nothing is written")
        XCTAssertEqual(sut.taskEngineStates[taskID], .paused)
        let reason = try await taskStatus(taskID)["pause_reason"] as? String
        XCTAssertEqual(reason, "by_person")
    }

    func testCorrect_ofThePersonsPause_isRefused_andNothingIsDelivered() async throws {
        try await openExternalFolder()
        let taskID = try await ownTaskPausedByThePerson()
        let before = record(taskID)

        let corrected = await correct(taskID)
        try assertRefusedForThePersonsPause(corrected)

        XCTAssertEqual(record(taskID), before, "no correction, no resume")
        XCTAssertNil(run(taskID)?.steps.first?.revisionComment)
        let reason = try await taskStatus(taskID)["pause_reason"] as? String
        XCTAssertEqual(reason, "by_person")
    }

    /// `start` on a paused task begins a NEW run, which leaves the person's paused one behind —
    /// the same Pause lifted by another verb.
    func testStart_ofATaskThePersonPaused_isRefused_andNoRunIsCreated() async throws {
        try await openExternalFolder()
        let taskID = try await ownTaskPausedByThePerson()
        let before = record(taskID)

        let started = await control(taskID, "start")
        try assertRefusedForThePersonsPause(started)

        XCTAssertEqual(record(taskID), before)
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.count, 1)
    }

    /// A message still waits in the queue, unchanged by the gate: it lands and does not lift.
    func testMessage_onThePersonsPause_isStillQueued_withoutLiftingIt() async throws {
        try await openExternalFolder()
        let taskID = try await ownTaskPausedByThePerson()

        let result = await call(ExternalAutovisorToolNames.messageTask, ["task_id": taskID, "message": "Use SQLite."])

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual((try envelope(result)["data"] as? [String: Any])?["status"] as? String, "queued_paused_by_person")
        XCTAssertEqual(sut.taskEngineStates[taskID], .paused)
    }

    // MARK: - Every other pause, and the person

    func testResume_ofTheAgentsOwnPause_resumes() async throws {
        try await openExternalFolder()
        let taskID = try await ownRunningTask()
        let paused = await control(taskID, "pause")
        XCTAssertFalse(try refusalIfAny(paused))
        let reason = try await taskStatus(taskID)["pause_reason"] as? String
        XCTAssertEqual(reason, "by_agent", "premise")

        let resumed = await control(taskID, "resume")

        XCTAssertFalse(resumed.isError, resumed.outputJSON)
        XCTAssertEqual(run(taskID)?.pauseCause, .resumed)
        XCTAssertNotEqual(sut.taskEngineStates[taskID], .paused)
    }

    func testCorrect_ofTheAgentsOwnPause_resumes() async throws {
        try await openExternalFolder()
        let taskID = try await ownRunningTask()
        let paused = await control(taskID, "pause")
        XCTAssertFalse(try refusalIfAny(paused))

        let corrected = await correct(taskID)

        XCTAssertFalse(corrected.isError, corrected.outputJSON)
        XCTAssertEqual(run(taskID)?.pauseCause, .resumed)
    }

    /// The watchdog's pause, after the agent raised the limit — the remedy the instructions name.
    func testResume_ofATimedOutPause_afterSetTimeout_resumes() async throws {
        try await openExternalFolder()
        let taskID = try await ownRunningTask()
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].timedOutAt = MonotonicClock.shared.now()
            task.runs[0].timedOutAtLimit = 60
        }
        await sut.pauseRun(taskID: taskID, cause: .runTimedOut)
        let premise = try await taskStatus(taskID)["pause_reason"] as? String
        XCTAssertEqual(premise, "timed_out", "premise")
        let set = await call(ExternalAutovisorToolNames.controlTask, [
            "task_id": taskID, "action": "set_timeout", "timeout_seconds": 3_600,
        ])
        XCTAssertFalse(try refusalIfAny(set))
        let after = try await taskStatus(taskID)["pause_reason"] as? String
        XCTAssertEqual(after, "timed_out", "still the watchdog's")

        let resumed = await control(taskID, "resume")

        XCTAssertFalse(resumed.isError, resumed.outputJSON)
        XCTAssertEqual(run(taskID)?.pauseCause, .resumed)
    }

    func testRecoveredPause_resumes() async throws {
        try await openExternalFolder()
        let taskID = try await ownRunningTask()
        await sut.pauseRun(taskID: taskID, cause: .recovered)
        let premise = try await taskStatus(taskID)["pause_reason"] as? String
        XCTAssertEqual(premise, "recovered", "premise")

        let resumed = await control(taskID, "resume")

        XCTAssertFalse(resumed.isError, resumed.outputJSON)
        XCTAssertEqual(run(taskID)?.pauseCause, .resumed)
    }

    /// The person resumes in the app as before — the gate is an automated Supervisor's only.
    func testThePersonsOwnResume_liftsTheirPause() async throws {
        try await openExternalFolder()
        let taskID = try await ownTaskPausedByThePerson()

        await sut.resumeRun(taskID: taskID, by: .person)

        XCTAssertEqual(run(taskID)?.pauseCause, .resumed)
        XCTAssertNotEqual(sut.taskEngineStates[taskID], .paused)
        XCTAssertEqual(run(taskID)?.supervisorEvents.last?.actor, .person)
        // …and once it is lifted, the agent's verbs are the agent's again.
        let paused = await control(taskID, "pause")
        XCTAssertFalse(try refusalIfAny(paused))
        let resumed = await control(taskID, "resume")
        XCTAssertFalse(resumed.isError, resumed.outputJSON)
    }

    // MARK: - `resumable` promises only a resume that runs

    /// A step's `resumable: true` says `control_task resume` will continue it — so on the person's
    /// pause, which that resume is refused, it is absent: on the agent's `task_status` and on the
    /// built-in manager's. On the agent's own pause it stays.
    func testResumable_isAbsentOnThePersonsPause_andPresentOnTheAgentsOwn() async throws {
        try await openExternalFolder()
        let persons = try await ownTaskPausedByThePerson()
        let own = try await ownRunningTask()
        let paused = await control(own, "pause")
        XCTAssertFalse(try refusalIfAny(paused))

        let personsSteps = try await taskStatus(persons)["steps"] as? [[String: Any]]
        let ownSteps = try await taskStatus(own)["steps"] as? [[String: Any]]

        XCTAssertEqual(personsSteps?.first?["status"] as? String, "paused", "premise")
        XCTAssertNil(personsSteps?.first?["resumable"], "a resume the gate refuses is not promised")
        XCTAssertEqual(ownSteps?.first?["resumable"] as? Bool, true)

        let task = try XCTUnwrap(sut.loadedTask(persons))
        let builtIn = LLMExecutionService.renderTaskStatusEnvelope(task: task, team: nil, now: MonotonicClock.shared.now())
        XCTAssertFalse(builtIn.contains("\"resumable\""), builtIn)
        let ownTask = try XCTUnwrap(sut.loadedTask(own))
        XCTAssertTrue(
            LLMExecutionService.renderTaskStatusEnvelope(task: ownTask, team: nil, now: MonotonicClock.shared.now())
                .contains("\"resumable\":true"))
    }

    // MARK: - Corner cases

    func testResume_ofATaskNotPaused_isNotThePersonsRefusal() async throws {
        try await openExternalFolder()
        let taskID = try await ownRunningTask()

        let resumed = await control(taskID, "resume")
        let corrected = await correct(taskID)

        if resumed.isError {
            XCTAssertNotEqual(try refusal(resumed).error["code"] as? String, "PAUSED_BY_PERSON", resumed.outputJSON)
        }
        let correctRefusal = try refusal(corrected)
        XCTAssertEqual(correctRefusal.error["code"] as? String, "COMMAND_FAILED", corrected.outputJSON)
        XCTAssertTrue((correctRefusal.error["message"] as? String)?.contains("control_task pause") == true,
                      corrected.outputJSON)
    }

    /// Ownership is asked first: a task that is not the agent's is refused as not its own, paused
    /// by the person or not — the agent learns nothing new about a task it cannot act on.
    func testForeignTask_pausedByThePerson_isRefusedAsNotOwned() async throws {
        try await openExternalFolder()
        let taskID = try await runningTask(origin: nil)
        _ = await sut.pauseRun(taskID: taskID)
        let before = record(taskID)

        let resumed = await control(taskID, "resume")
        let corrected = await correct(taskID)
        for result in [resumed, corrected] {
            XCTAssertEqual(try refusal(result).error["code"] as? String, "NOT_OWNER", result.outputJSON)
        }
        XCTAssertEqual(record(taskID), before)
    }

    /// A closed task answers as closed, not as paused.
    func testClosedTask_answersClosed() async throws {
        try await openExternalFolder()
        let taskID = try await ownTaskPausedByThePerson()
        await sut.mutateTask(taskID: taskID) { $0.closedAt = MonotonicClock.shared.now() }

        let resumed = await control(taskID, "resume")
        let (error, _) = try refusal(resumed)

        XCTAssertEqual(error["code"] as? String, "COMMAND_FAILED")
        XCTAssertTrue((error["message"] as? String)?.contains("already closed") == true, "\(error)")
    }

    // MARK: - The built-in manager

    /// The built-in Autovisor is held to the same rule for the person's Pause — its own Pause it
    /// may lift, as before.
    func testBuiltInManager_isRefusedThePersonsPause_butLiftsItsOwn() async throws {
        await sut.openWorkFolder(tempDir)
        let persons = try await runningTask(origin: nil)
        _ = await sut.pauseRun(taskID: persons)
        let before = record(persons)

        for verb in [AutovisorAction.controlTask(taskID: persons, verb: .resume),
                     .controlTask(taskID: persons, verb: .start),
                     .manageRole(taskID: persons, roleID: "eng", verb: .correct(comment: "Use SQLite."))] {
            let refused = await sut.performAutovisorAction(verb, within: sut.currentFolderLifecycle)
            XCTAssertFalse(refused.ok, "\(verb): \(refused.message)")
            XCTAssertEqual(refused.failure, .pausedByPerson, "\(verb)")
            XCTAssertEqual(refused.message, AutovisorReply.pausedByThePerson(taskID: persons).text)
        }
        XCTAssertEqual(record(persons), before)

        let own = try await runningTask(origin: .builtInAutovisor)
        let ownPause = await sut.performAutovisorAction(
            .controlTask(taskID: own, verb: .pause), within: sut.currentFolderLifecycle)
        XCTAssertTrue(ownPause.ok, ownPause.message)
        let resumed = await sut.performAutovisorAction(
            .controlTask(taskID: own, verb: .resume), within: sut.currentFolderLifecycle)
        XCTAssertTrue(resumed.ok, resumed.message)
        XCTAssertEqual(run(own)?.pauseCause, .resumed)
    }

    // MARK: - Helpers

    /// `true` when `result` is a refusal — so a premise reads `XCTAssertFalse(refusalIfAny(…))`.
    private func refusalIfAny(_ result: ToolExecutionResult) throws -> Bool {
        if result.isError { XCTFail(result.outputJSON) }
        return result.isError
    }
}
