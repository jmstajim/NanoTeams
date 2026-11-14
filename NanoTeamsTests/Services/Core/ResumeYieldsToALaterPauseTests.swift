import XCTest
@testable import NanoTeams

/// A Pause that lands while a Resume is still under way is the later click, and it stands
/// (D-M18, 2026-11-13).
///
/// `resumeRun` records the Resume in memory, then suspends on that record's disk write — and on
/// every later write, child resume and step start — before it restarts anything. It re-reads the
/// task to find the steps to restart (branch 3 restarts every `.paused` step it finds). Where the
/// steps are not parked when the Resume begins — an iteration-limit pause, which is the engine's
/// alone, and a delegating task, whose step suspended on `delegate_to_team` stays `.running` — a
/// Pause pressed in that window parks them, and the Resume then restarted exactly the steps the
/// Pause had parked: the person's last click was lost, the task ran, and the agent was told
/// `paused`, then `resumed`.
///
/// The window is made deterministic with a held task write (`TaskWriteHold`): the Resume's own
/// record is blocked on its writer until the Pause has returned.
///
/// A Resume of a task whose steps ARE parked is stopped the same way: once it has lifted the pause
/// (`.resumed` recorded) a Pause in its window parks no step but stops the Resume, and stands
/// (`interruptsAResume`, the review of 2026-11-13 — until then that Pause "stopped nothing").
@MainActor
final class ResumeYieldsToALaterPauseTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agentA = AgentIdentity(
        id: UUID(uuidString: "cccccccc-1111-2222-3333-4444444444f1")!,
        label: "Claude Code"
    )

    private var repository: SelectivelyFailingRepository!
    private var handlers: [Task<Void, Never>] = []
    private var awaitedChildren: [Int] = []

    override func setUp() async throws {
        try await super.setUp()
        repository = SelectivelyFailingRepository(wrapping: NTMSRepository())
        sut = TestOrchestrator.make(
            repository: repository,
            embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient)
    }

    override func tearDown() async throws {
        repository?.taskWriteHold?.release()
        for childID in awaitedChildren { sut?.completionAwaiter.cancelAll(taskID: childID) }
        for handler in handlers { handler.cancel() }
        handlers = []
        awaitedChildren = []
        repository = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func openExternalFolder() async throws {
        await sut.openWorkFolder(tempDir)
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
    }

    /// An agent's task with one step running.
    private func runningOwnTask() async throws -> Int {
        let created = await sut.createTask(
            title: "Own task", supervisorTask: "Brief", makeActive: false, origin: .externalAgent(agentA))
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

    private func poll(after cursor: String?) async -> AutovisorWaitResult {
        await sut.autovisorEventFeed.waitForEvents(agentID: agentA.id, after: cursor, timeoutSeconds: 0)
    }

    private func describe(_ events: [AutovisorEvent]) -> [String] {
        events.map { event in
            var text = "\(event.kind.rawValue)#\(event.taskID)"
            if let reason = event.pauseReason { text += "(\(reason.rawValue))" }
            return text
        }
    }

    private func stepStatus(_ taskID: Int, _ stepID: String = "eng") -> StepStatus? {
        sut.loadedTask(taskID)?.runs.last?.steps.first(where: { $0.id == stepID })?.status
    }

    /// Runs `resume` with the first write of `heldTaskID` held on its writer, presses the person's
    /// Pause on `pausedTaskID` while it is held, then lets the write through and waits for both.
    /// Returns the Pause's verdict.
    private func pauseDuringTheResumesWrite(
        heldTaskID: Int,
        pausedTaskID: Int,
        resume: @escaping @MainActor () async -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Bool {
        let hold = TaskWriteHold(matching: { _, task in task.id == heldTaskID })
        repository.taskWriteHold = hold
        let resuming = Task { @MainActor in await resume() }
        for _ in 0..<1000 where !hold.isHeld {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(hold.isHeld, "premise: the Resume reached its write", file: file, line: line)

        let paused = await sut.pauseRun(taskID: pausedTaskID)

        hold.release()
        await resuming.value
        return paused
    }

    // MARK: - Iteration-limit pause

    /// The engine stopped at its iteration limit; the step it started is still running. The
    /// person's Resume, then their Pause during the Resume's write: the Pause parks the step and
    /// the Resume must not restart it.
    func testIterationLimitPause_pauseDuringTheResumesWrite_stands() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let engine = sut.engineForTask(taskID)
        engine.pausedIterationLimit = 50
        engine.transition(to: .paused)
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].pauseCause = .iterationLimit }
        XCTAssertEqual(sut.loadedTask(taskID).flatMap { sut.autovisorPauseReason(of: $0) }, .iterationLimit, "premise")
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        let paused = try await pauseDuringTheResumesWrite(heldTaskID: taskID, pausedTaskID: taskID) { [sut] in
            await sut!.resumeRun(taskID: taskID, by: .person)
        }

        XCTAssertTrue(paused, "premise: the Pause stopped the running step")
        XCTAssertEqual(stepStatus(taskID), .paused, "the person's Pause stands: the Resume restarted its step")
        XCTAssertEqual(sut.taskEngineStates[taskID], .paused, "the person's Pause stands: the Resume woke the engine")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.pauseCause, .requested)
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.supervisorEvents.map(\.kind), [.runResumed, .runPaused])
        let events = await poll(after: cursor).events
        XCTAssertEqual(events.last?.kind, .paused, "the feed ends on the Pause: \(describe(events))")
        XCTAssertEqual(events.last?.pauseReason, .byPerson, describe(events).joined(separator: ", "))
        XCTAssertTrue(sut.isPausedInTheApp(taskID: taskID), "the agent's resume is refused the person's Pause")
    }

    /// The same Pause without a Resume racing it: pressed on a run the engine stopped at its
    /// iteration limit, with the step still running, it parks the step and is the person's.
    func testIterationLimitPause_thenThePersonsPause_isThePersons() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let engine = sut.engineForTask(taskID)
        engine.pausedIterationLimit = 50
        engine.transition(to: .paused)
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].pauseCause = .iterationLimit }

        let paused = await sut.pauseRun(taskID: taskID)

        XCTAssertTrue(paused)
        XCTAssertEqual(stepStatus(taskID), .paused)
        XCTAssertEqual(sut.loadedTask(taskID).flatMap { sut.autovisorPauseReason(of: $0) }, .byPerson)
        XCTAssertTrue(sut.isPausedInTheApp(taskID: taskID), "the agent's resume is refused the person's Pause")
    }

    /// Not only the Resume's first write: a Pause pressed at a later suspension — here the write
    /// that hands a parked question back to the Supervisor (branch 1) — stands as well, and the
    /// running step it parked is not restarted after it.
    func testIterationLimitPause_pauseDuringALaterWriteOfTheResume_stands() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps.append(StepExecution(
                id: "ask", role: .productManager, title: "Asks", status: .paused,
                needsSupervisorInput: true, supervisorQuestion: "Which database?"))
            task.runs[0].roleStatuses["ask"] = .working
            task.runs[0].pauseCause = .iterationLimit
        }
        let engine = sut.engineForTask(taskID)
        engine.pausedIterationLimit = 50
        engine.transition(to: .paused)
        let hold = TaskWriteHold(matching: { _, task in
            task.runs.last?.steps.first(where: { $0.id == "ask" })?.status == .needsSupervisorInput
        })
        repository.taskWriteHold = hold
        let store = sut!
        let resuming = Task { @MainActor in await store.resumeRun(taskID: taskID, by: .person) }
        for _ in 0..<1000 where !hold.isHeld {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(hold.isHeld, "premise: the Resume reached the question's write")

        let paused = await sut.pauseRun(taskID: taskID)
        hold.release()
        await resuming.value

        XCTAssertTrue(paused, "premise")
        XCTAssertEqual(stepStatus(taskID), .paused, "the person's Pause stands: the Resume restarted its step")
        XCTAssertEqual(sut.taskEngineStates[taskID], .paused)
        XCTAssertTrue(sut.isPausedInTheApp(taskID: taskID))
    }

    // MARK: - Delegating task

    /// A delegating task, paused by the person: its step suspended on `delegate_to_team` stays
    /// running, the child's step is parked. The person's Resume reaches the child's write; their
    /// Pause in that window must keep the child parked and the parent's engine paused.
    func testDelegatingTask_pauseDuringTheChildsResumeWrite_stands() async throws {
        try await openExternalFolder()
        let parentID = try await runningOwnTask()
        let childCreated = await sut.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "eng", title: "Child", supervisorTask: "Sub-brief",
            preferredTeamID: nil, depth: 1)
        let childID = try XCTUnwrap(childCreated)
        await sut.ensureTaskLoaded(childID)
        _ = await sut.mutateTask(taskID: childID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .running)],
                roleStatuses: ["eng": .working]
            )]
        }
        _ = await sut.mutateTask(taskID: parentID) { $0.runs[0].steps[0].setActiveDelegation(childID: childID) }
        awaitedChildren.append(childID)
        handlers.append(await registerSuspendedDelegationHandler(on: sut, childID: childID))
        sut.engineForTask(parentID).transition(to: .running)
        let firstPause = await sut.pauseRun(taskID: parentID)
        XCTAssertTrue(firstPause, "premise")
        XCTAssertEqual(stepStatus(parentID), .running, "premise: the delegating step keeps awaiting its child")
        XCTAssertEqual(stepStatus(childID), .paused, "premise: the cascade parked the child")

        let paused = try await pauseDuringTheResumesWrite(heldTaskID: childID, pausedTaskID: parentID) { [sut] in
            await sut!.resumeRun(taskID: parentID, by: .person)
        }

        XCTAssertTrue(paused, "premise: the parent's engine stood paused")
        XCTAssertEqual(stepStatus(childID), .paused, "the person's Pause stands: the Resume restarted the child's step")
        XCTAssertEqual(sut.taskEngineStates[parentID], .paused, "the person's Pause stands: the Resume woke the parent's engine")
        XCTAssertTrue(sut.isPausedInTheApp(taskID: parentID))
    }

    // MARK: - The steps are parked

    /// The ordinary pause: the steps stand parked when the Resume begins. Once the Resume has
    /// recorded itself the task no longer reads paused — the pause it lifted is `.resumed`, and
    /// the agent may already have been told `resumed` — so a Pause pressed in the window of that
    /// write is the later click and stands, although it parks nothing: the Resume is what it stops.
    /// Until the review of 2026-11-13 it "stopped nothing", the Resume went on and the task ran
    /// — the person's last click lost, and an agent's `control_task pause` answered `paused` for
    /// a task about to run.
    func testParkedSteps_pauseDuringTheResumesWrite_stands() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let firstPause = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(firstPause, "premise")

        let paused = try await pauseDuringTheResumesWrite(heldTaskID: taskID, pausedTaskID: taskID) { [sut] in
            await sut!.resumeRun(taskID: taskID, by: .person)
        }

        XCTAssertTrue(paused)
        XCTAssertEqual(stepStatus(taskID), .paused, "the person's Pause stands: the Resume restarted the step")
        XCTAssertEqual(sut.taskEngineStates[taskID], .paused, "the person's Pause stands: the Resume woke the engine")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.pauseCause, .requested)
        XCTAssertEqual(
            sut.loadedTask(taskID)?.runs.last?.supervisorEvents.map(\.kind), [.runPaused, .runResumed, .runPaused])
        XCTAssertTrue(sut.isPausedInTheApp(taskID: taskID))
    }

    /// The same window after a restart: no engine, the role reset to idle, so the Resume flips
    /// the role back to `.working` — a write — before it restarts the step. An agent's Pause in
    /// that write is not "already paused" (the task it reads was resumed), and it stands: the
    /// reply says paused and the task is paused, by the agent.
    func testEnginelessResume_agentsPauseDuringTheRoleWrite_isNotAlreadyPaused_andStands() async throws {
        try await openExternalFolder()
        let folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
        let taskID = try await runningOwnTask()
        let firstPause = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(firstPause, "premise")
        sut.stopEngineForTask(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].roleStatuses["eng"] = .idle
            task.runs[0].steps[0].llmConversation = [LLMMessage(role: .user, content: "Brief")]
        }
        XCTAssertNil(sut.taskEngines[taskID], "premise: no engine, as after a restart")
        let hold = TaskWriteHold(matching: { _, task in task.runs.last?.roleStatuses["eng"] == .working })
        repository.taskWriteHold = hold
        let store = sut!
        let resuming = Task { @MainActor in await store.resumeRun(taskID: taskID, by: .person) }
        for _ in 0..<1000 where !hold.isHeld {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(hold.isHeld, "premise: the Resume reached the role's write")

        let reply = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.controlTask,
            args: ["folder_id": folderID, "task_id": taskID, "action": "pause"],
            agent: agentA)
        hold.release()
        await resuming.value

        XCTAssertTrue(reply.outputJSON.contains("\"ok\":true"), reply.outputJSON)
        XCTAssertEqual(stepStatus(taskID), .paused, "the agent's Pause stands: the Resume restarted the step")
        XCTAssertNotEqual(sut.taskEngineStates[taskID], .running)
        XCTAssertEqual(sut.loadedTask(taskID).flatMap { sut.autovisorPauseReason(of: $0) }, .byAgent)
    }
}
