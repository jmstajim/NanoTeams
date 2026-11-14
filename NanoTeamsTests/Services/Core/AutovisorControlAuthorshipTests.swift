import XCTest
@testable import NanoTeams

/// Who paused, resumed, closed or deleted an agent's task — recorded where the action lands
/// (`ControlActor`) and read back the same way by every surface (2026-11-09):
/// - an agent's own Pause reads `by_agent`, in `task_status` and in a snapshot, and is never
///   echoed to it as a live event; a person's reads `by_person` and is;
/// - a Resume of a pause says who resumed it — `resumed` with `by`, and a timeline event — and an
///   agent is not told its own Resume, close or delete back;
/// - an automated Supervisor's message or answer does not lift a pause pressed in the app, and
///   since 2026-11-12 neither does its `control_task resume` or `manage_role correct`
///   (`PersonsPauseGateTests`); the person's own message still does;
/// - the requester and the request key survive a cold relaunch (CLAUDE.md #366);
/// - a cursor of another launch restarts, whatever its position.
@MainActor
final class AutovisorControlAuthorshipTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agentA = AgentIdentity(
        id: UUID(uuidString: "cccccccc-1111-2222-3333-444444444441")!,
        label: "Claude Code"
    )

    private var formState: QuickCaptureFormState!

    override func setUp() async throws {
        try await super.setUp()
        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState
    }

    override func tearDown() async throws {
        formState = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private var agent: AutovisorActor { .externalAgent(agentA) }

    @discardableResult
    private func openExternalFolder() async throws -> String {
        await sut.openWorkFolder(tempDir)
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        return try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
    }

    /// An agent's task with one step running — what a Pause actually stops.
    private func runningOwnTask(_ title: String = "Own task") async throws -> Int {
        let created = await sut.createTask(
            title: title, supervisorTask: "Brief", makeActive: false, origin: .externalAgent(agentA))
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

    /// An agent's task whose step asks a question — answerable, and stoppable by a Pause.
    private func questionOwnTask() async throws -> Int {
        let created = await sut.createTask(
            title: "Asks", supervisorTask: "Brief", makeActive: false, origin: .externalAgent(agentA))
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "eng", role: .softwareEngineer, title: "Engineer", status: .needsSupervisorInput,
                    toolCalls: [StepToolCall(
                        name: ToolNames.askSupervisor,
                        argumentsJSON: #"{"question":"Which database?"}"#,
                        resultJSON: #"{"ok":true}"#)],
                    needsSupervisorInput: true,
                    supervisorQuestion: "Which database?")],
                roleStatuses: ["eng": .working]
            )]
        }
        return taskID
    }

    private func act(_ action: AutovisorAction) async -> AutovisorActionResult {
        await sut.performAutovisorAction(action, as: agent, within: sut.currentFolderLifecycle)
    }

    private func poll(after cursor: String?) async -> AutovisorWaitResult {
        await sut.autovisorEventFeed.waitForEvents(agentID: agentA.id, after: cursor, timeoutSeconds: 0)
    }

    private func describe(_ events: [AutovisorEvent]) -> [String] {
        events.map { event in
            var text = "\(event.kind.rawValue)#\(event.taskID)"
            if let reason = event.pauseReason { text += "(\(reason.rawValue))" }
            if let by = event.by { text += "<\(ExternalAutovisorReadOperationsWire.actor(by))" }
            return text
        }
    }

    private func taskStatusData(_ taskID: Int, folderID: String) async throws -> [String: Any] {
        let result = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.taskStatus,
            args: ["folder_id": folderID, "task_id": taskID],
            agent: agentA)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        return try XCTUnwrap(envelope["data"] as? [String: Any], result.outputJSON)
    }

    private func timeline(_ taskID: Int) -> [SupervisorTimelineEvent] {
        sut.loadedTask(taskID)?.runs.last?.supervisorEvents ?? []
    }

    // MARK: - Who paused

    func testAgentsOwnPause_readsByAgent_isNotEchoed_andStandsInASnapshot() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        let paused = await act(.controlTask(taskID: taskID, verb: .pause))
        XCTAssertTrue(paused.ok, paused.message)
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.pauseRequestedBy, .externalAgent(agentA))
        let status = try await taskStatusData(taskID, folderID: folderID)
        XCTAssertEqual(status["pause_reason"] as? String, "by_agent")

        let live = await poll(after: cursor)
        XCTAssertEqual(describe(live.events), [], "the agent has the result of its own pause from its call")

        let snapshot = await poll(after: nil)
        XCTAssertEqual(describe(snapshot.events), ["paused#\(taskID)(by_agent)"], "a snapshot reports what stands")
        XCTAssertNil(snapshot.events.first?.seq)
        XCTAssertEqual(timeline(taskID).map(\.kind), [.runPaused])
        XCTAssertEqual(timeline(taskID).first?.actor, .externalAgent(agentA))
    }

    func testPersonsPause_readsByPerson_andIsDelivered() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        let paused = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(paused)

        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.pauseRequestedBy, .person)
        let status = try await taskStatusData(taskID, folderID: folderID)
        XCTAssertEqual(status["pause_reason"] as? String, "by_person")
        let polled = await poll(after: cursor)
        XCTAssertEqual(describe(polled.events), ["paused#\(taskID)(by_person)"])
        XCTAssertEqual(timeline(taskID).first?.actor, .person)
        XCTAssertFalse(try XCTUnwrap(timeline(taskID).first).isDrawnInTheFeed, "the person's own pause is not drawn")
    }

    /// A requested Pause over a run whose earlier pause was the agent's records the new
    /// requester: the cause stays `.requested`, so a guard on the cause alone kept the agent's.
    func testSecondPause_byAnotherRequester_recordsTheNewOne() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        _ = await act(.controlTask(taskID: taskID, verb: .pause))
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].steps[0].status = .running }

        let paused = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(paused)

        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.pauseRequestedBy, .person)
        XCTAssertEqual(timeline(taskID).map(\.actor), [.externalAgent(agentA), .person])
    }

    /// The watchdog's pause is nobody's request: its requester is cleared with the cause.
    func testTimeoutPause_clearsTheRequester() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        _ = await act(.controlTask(taskID: taskID, verb: .pause))
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].steps[0].status = .running }

        let paused = await sut.pauseRun(taskID: taskID, cause: .runTimedOut)
        XCTAssertTrue(paused)

        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.pauseCause, .runTimedOut)
        XCTAssertNil(sut.loadedTask(taskID)?.runs.last?.pauseRequestedBy)
        XCTAssertEqual(timeline(taskID).count, 1, "a timeout writes no timeline event")
    }

    func testPauseReason_resolvesTheRequesterOfARequestedPause() {
        func reason(_ requester: ControlActor?) -> AutovisorPauseReason? {
            var run = Run(id: 0, steps: [], roleStatuses: [:])
            run.pauseCause = .requested
            run.pauseRequestedBy = requester
            return AutovisorPauseReason.resolve(
                run: run, taskStatus: .running, isPaused: true, liveIterationLimitPause: false)
        }
        XCTAssertEqual(reason(.externalAgent(agentA)), .byAgent)
        XCTAssertEqual(reason(.person), .byPerson)
        XCTAssertEqual(reason(.builtInAutovisor), .byPerson, "the in-app Autovisor pauses in the app")
        XCTAssertEqual(reason(nil), .byPerson, "a pause recorded before the requester reads as it always did")
    }

    // MARK: - Who resumed

    func testPersonsResume_isDeliveredWithBy_andRecorded() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let paused = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(paused)
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        await sut.resumeRun(taskID: taskID)

        // Unfiltered: a stray `paused` read off the Resume's own write (2026-11-12) shows here.
        let events = await poll(after: cursor).events
        XCTAssertEqual(describe(events), ["resumed#\(taskID)<person"])
        XCTAssertNotNil(events.first?.seq)
        XCTAssertEqual(timeline(taskID).map(\.kind), [.runPaused, .runResumed])
        XCTAssertEqual(timeline(taskID).last?.actor, .person)
    }

    /// Of its own Pause: the person's is refused to it (`PersonsPauseGateTests`, D-M18).
    func testAgentsResume_isNotEchoed_butIsRecorded() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let paused = await act(.controlTask(taskID: taskID, verb: .pause))
        XCTAssertTrue(paused.ok, paused.message)
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        let resumed = await act(.controlTask(taskID: taskID, verb: .resume))
        XCTAssertTrue(resumed.ok, resumed.message)

        // Unfiltered: nothing at all — neither its own Resume echoed nor a `paused` read off it.
        let polled = await poll(after: cursor)
        XCTAssertEqual(describe(polled.events), [])
        XCTAssertEqual(timeline(taskID).last?.kind, .runResumed)
        XCTAssertEqual(timeline(taskID).last?.actor, .externalAgent(agentA))
        XCTAssertTrue(try XCTUnwrap(timeline(taskID).last).isDrawnInTheFeed)
    }

    /// A Resume of a task that stands in no pause — an answer resuming a parked question's step —
    /// says nothing: there was no `paused` to answer.
    func testResumeOfATaskNotPaused_recordsNoResume() async throws {
        try await openExternalFolder()
        let taskID = try await questionOwnTask()
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        await sut.resumeRun(taskID: taskID)

        let polled = await poll(after: cursor)
        XCTAssertEqual(describe(polled.events.filter { $0.kind == .resumed }), [])
        XCTAssertEqual(timeline(taskID), [])
    }

    /// The person's Resume, then their Pause, read by one wait from a cursor taken before both
    /// (2026-11-12, task 21 in a live check): the agent got `paused(by_person)` at seq 5 and
    /// `resumed` at seq 6 — the last event said the task ran while it stood paused. Seq 5 was the
    /// Resume's own row write, the run's steps still parked: a standing candidate is read at the
    /// wait, so it told the Pause that came after the Resume, and the Pause's own candidate, seq
    /// 7, was the same pause already told.
    func testResumeThenPause_readByOneWait_endsOnThePause() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let agentsPause = await act(.controlTask(taskID: taskID, verb: .pause))
        XCTAssertTrue(agentsPause.ok, agentsPause.message)
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        await sut.resumeRun(taskID: taskID)
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].steps[0].status = .running }
        let personsPause = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(personsPause, "premise: the person's Pause stopped the step")

        let events = await poll(after: cursor).events
        XCTAssertEqual(describe(events), ["resumed#\(taskID)<person", "paused#\(taskID)(by_person)"])
        let seqs = events.compactMap(\.seq)
        XCTAssertEqual(seqs.count, events.count, "every live event has its place")
        XCTAssertEqual(seqs, seqs.sorted(), "the events read in the order they happened")
    }

    /// The same order when nothing reads in between three of the person's clicks — Pause, Resume,
    /// Pause: the first pause's candidate reads the pause that stands now, which came after the
    /// Resume.
    func testPauseResumePause_readByOneWait_endsOnThePauseThatStands() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        let first = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(first, "premise")
        await sut.resumeRun(taskID: taskID)
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].steps[0].status = .running }
        let second = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(second, "premise")

        let events = await poll(after: cursor).events
        XCTAssertEqual(describe(events), ["resumed#\(taskID)<person", "paused#\(taskID)(by_person)"])
        XCTAssertEqual(events.compactMap(\.seq), events.compactMap(\.seq).sorted())
    }

    /// A wait open while the person's Resume lifts the agent's pause (2026-11-12, the review of
    /// task 21's fix): the Resume's own write records `.resumed` while the steps it is about to
    /// restart still stand parked, and that write's row edge woke the wait, which read the parked
    /// run as `paused(by_person)` — "do not resume, the person paused" about a pause nobody
    /// pressed, told at the moment the person lifted one.
    func testPersonsResumeOfTheAgentsPause_toAWaitOpenDuringIt_tellsNoPause() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let agentsPause = await act(.controlTask(taskID: taskID, verb: .pause))
        XCTAssertTrue(agentsPause.ok, agentsPause.message)
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        let waiting = await openWait(after: cursor)

        await sut.resumeRun(taskID: taskID)

        let live = await waiting.value
        let next = await poll(after: live.cursor)
        XCTAssertEqual(describe(live.events + next.events), ["resumed#\(taskID)<person"])
        XCTAssertEqual(sut.loadedTask(taskID)?.derivedStatusFromActiveRun(), .running, "premise: the Resume restarted the step")
    }

    /// The agent's own Resume, with its wait open: nothing to tell — the Resume is its own, and
    /// no pause stands while the steps restart.
    func testAgentsResume_toItsWaitOpenDuringIt_tellsNothing() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let agentsPause = await act(.controlTask(taskID: taskID, verb: .pause))
        XCTAssertTrue(agentsPause.ok, agentsPause.message)
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        let waiting = await openWait(after: cursor, timeoutSeconds: 1)

        let resumed = await act(.controlTask(taskID: taskID, verb: .resume))
        XCTAssertTrue(resumed.ok, resumed.message)

        let live = await waiting.value
        XCTAssertEqual(describe(live.events), [])
    }

    /// A run a Resume lifted, its steps still parked while the Resume restarts them: no pause
    /// stands (`Run.PauseCause.resumed`) — not the person's, which the fall-through for a run with
    /// no recorded cause told — unless status recovery latched it since.
    func testPauseReason_ofALiftedPauseWhoseStepsAreStillParked_isNone() {
        var run = Run(
            id: 0,
            steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .paused)],
            roleStatuses: ["eng": .working])
        run.pauseCause = .resumed
        XCTAssertNil(AutovisorPauseReason.resolve(
            run: run, taskStatus: .running, isPaused: true, liveIterationLimitPause: false))
        XCTAssertEqual(AutovisorPauseReason.resolve(
            run: run, taskStatus: .paused, isPaused: true, liveIterationLimitPause: false), .recovered)
        XCTAssertEqual(AutovisorPauseReason.resolve(
            run: run, taskStatus: .running, isPaused: true, liveIterationLimitPause: true), .iterationLimit)
    }

    /// A wait of the agent's, begun and parked before the caller goes on.
    private func openWait(after cursor: String, timeoutSeconds: TimeInterval = 5) async -> Task<AutovisorWaitResult, Never> {
        let feed = sut.autovisorEventFeed
        let agentID = agentA.id
        let waiting = Task { @MainActor in
            await feed.waitForEvents(agentID: agentID, after: cursor, timeoutSeconds: timeoutSeconds)
        }
        while !feed.hasWaitInProgress(forAgentID: agentID) { await Task.yield() }
        return waiting
    }

    // MARK: - Who closed, who deleted

    func testAgentsCloseAndDelete_areNotEchoed_thePersonsAre() async throws {
        try await openExternalFolder()
        let byAgent = try await runningOwnTask("Closed by the agent")
        let byPerson = try await runningOwnTask("Closed by the person")
        let deletedByAgent = try await runningOwnTask("Deleted by the agent")
        let deletedByPerson = try await runningOwnTask("Deleted by the person")
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        let acted = await act(.controlTask(taskID: byAgent, verb: .close))
        XCTAssertTrue(acted.ok)
        let closed = await sut.closeTask(taskID: byPerson)
        XCTAssertTrue(closed)
        let actedAgain = await act(.controlTask(taskID: deletedByAgent, verb: .delete))
        XCTAssertTrue(actedAgain.ok)
        await sut.removeTask(deletedByPerson)

        let delivered = await poll(after: cursor)
        XCTAssertEqual(
            describe(delivered.events),
            ["closed#\(byPerson)<person", "deleted#\(deletedByPerson)<person"])
        XCTAssertEqual(timeline(byAgent).map(\.kind), [.taskClosed], "the agent's close is drawn in the feed")
        XCTAssertEqual(timeline(byPerson), [], "the person's close is not a Supervisor timeline event")
    }

    /// Only conditions that wait on somebody stand: a closed task is in no snapshot, not even
    /// one whose last run failed — which derives `failed` for ever.
    func testSnapshot_leavesOutAClosedTask_evenOneWithAFailedStep() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps[0].status = .failed
            task.runs[0].roleStatuses["eng"] = .failed
        }
        let closed = await sut.closeTask(taskID: taskID)
        XCTAssertTrue(closed)
        XCTAssertEqual(sut.loadedTask(taskID)?.derivedStatusFromActiveRun(), .failed, "premise")

        let polled = await poll(after: nil)
        XCTAssertEqual(describe(polled.events), [])
    }

    // MARK: - A pause pressed in the app stands

    func testAgentsMessage_leavesThePersonsPauseStanding() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let paused = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(paused)

        let result = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.messageTask,
            args: ["folder_id": folderID, "task_id": taskID, "message": "Carry on with the tests"],
            agent: agentA)

        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let data = try XCTUnwrap(envelope["data"] as? [String: Any], result.outputJSON)
        XCTAssertEqual(data["status"] as? String, "queued_paused_by_person")
        XCTAssertEqual(
            data["message"] as? String, AutovisorReply.messageQueuedWhilePausedInTheApp(taskID: taskID).text)
        XCTAssertEqual(formState.queuedMessages(for: taskID).count, 1, "the message waits")
        XCTAssertEqual(sut.loadedTask(taskID)?.derivedStatusFromActiveRun(), .paused)
        XCTAssertFalse(timeline(taskID).contains { $0.kind == .runResumed })
    }

    /// The agent's own pause is the agent's to lift, and its message lifts it as before.
    func testAgentsMessage_resumesItsOwnPause() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        _ = await act(.controlTask(taskID: taskID, verb: .pause))

        let result = await act(.messageTask(taskID: taskID, text: "Go on", roleID: nil))

        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(result.message, AutovisorReply.messageQueuedAndResumed(taskID: taskID).text)
        XCTAssertNil(result.outcome)
        XCTAssertEqual(timeline(taskID).last?.kind, .runResumed)
    }

    func testAgentsAnswer_landsAndLeavesThePersonsPauseStanding() async throws {
        let folderID = try await openExternalFolder()
        let taskID = try await questionOwnTask()
        let paused = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(paused)
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.steps.first?.status, .paused, "premise")

        let result = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.answerTaskQuestion,
            args: ["folder_id": folderID, "task_id": taskID, "answer": "SQLite"],
            agent: agentA)

        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let data = try XCTUnwrap(envelope["data"] as? [String: Any], result.outputJSON)
        XCTAssertEqual(data["status"] as? String, "answered_paused_by_person")
        let step = try XCTUnwrap(sut.loadedTask(taskID)?.runs.last?.steps.first)
        XCTAssertEqual(step.supervisorAnswer, "SQLite", "the answer lands")
        XCTAssertEqual(step.status, .paused, "and waits for the person's Resume")
        XCTAssertFalse(timeline(taskID).contains { $0.kind == .runResumed })
    }

    /// The queue's backstop wakes a paused task for a message — but not a pause pressed in the
    /// app for one only automated Supervisors wrote. The person's own message still wakes it.
    func testBackstop_wakesAPersonsPauseOnlyForThePersonsMessage() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let paused = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(paused)
        sut.engineState[taskID] = .paused
        var woken: [Int] = []
        sut.messageQueue.resumeRunForTesting = { woken.append($0) }

        let fromAgent = try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(
            text: "agent's", attachments: [], clippedTexts: [], isFromAutomatedSupervisor: true,
            authorLabel: agentA.label, actor: .externalAgent(agentA)))
        formState.appendQueuedMessage(fromAgent, for: taskID)
        sut.messageQueue.tryFlushQueuedMessages(formState: formState)
        XCTAssertEqual(woken, [], "an automated message waits for the person")

        let fromPerson = try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(
            text: "person's", attachments: [], clippedTexts: []))
        formState.appendQueuedMessage(fromPerson, for: taskID)
        sut.messageQueue.tryFlushQueuedMessages(formState: formState)
        XCTAssertEqual(woken, [taskID], "the person's own message lifts their pause")
    }

    func testResumerOfAQueue_isThePersonUnlessEveryMessageIsAutomated() throws {
        let person = try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(text: "p", attachments: [], clippedTexts: []))
        let fromAgent = try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(
            text: "a", attachments: [], clippedTexts: [], isFromAutomatedSupervisor: true,
            actor: .externalAgent(agentA)))
        let unattributedAutomated = try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(
            text: "m", attachments: [], clippedTexts: [], isFromAutomatedSupervisor: true))

        XCTAssertEqual(SupervisorMessageQueueService.resumer(of: []), .person)
        XCTAssertEqual(SupervisorMessageQueueService.resumer(of: [person]), .person)
        XCTAssertEqual(SupervisorMessageQueueService.resumer(of: [fromAgent]), .externalAgent(agentA))
        XCTAssertEqual(SupervisorMessageQueueService.resumer(of: [fromAgent, person]), .person)
        XCTAssertEqual(SupervisorMessageQueueService.resumer(of: [unattributedAutomated]), .builtInAutovisor)
        XCTAssertEqual(SupervisorMessageQueueService.resumer(of: [unattributedAutomated, fromAgent]), .externalAgent(agentA))
    }

    // MARK: - After a relaunch

    func testRequesterAndRequestKey_surviveAColdRelaunch() async throws {
        let folderID = try await openExternalFolder()
        let created = await sut.createTask(
            title: "Keyed", supervisorTask: "Brief", makeActive: false, origin: .externalAgent(agentA),
            requestKey: "req-42")
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .running)],
                roleStatuses: ["eng": .working])]
        }
        _ = await act(.controlTask(taskID: taskID, verb: .pause))

        sut.evictLoadedTask(taskID)
        await sut.openWorkFolder(tempDir)

        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first { $0.id == taskID }?.requestKey, "req-42")
        await sut.ensureTaskLoaded(taskID)
        XCTAssertEqual(sut.loadedTask(taskID)?.requestKey, "req-42")
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.pauseRequestedBy, .externalAgent(agentA))
        let status = try await taskStatusData(taskID, folderID: folderID)
        XCTAssertEqual(status["pause_reason"] as? String, "by_agent")
    }

    // MARK: - A cursor of another launch

    /// The counter alone starts over at every launch, so a cursor of the previous process names
    /// this process's epoch number — with a position in a ring this process never had.
    func testCursorOfAnotherLaunch_restarts_whateverItsPosition() async throws {
        try await openExternalFolder()
        let folderID = try XCTUnwrap(sut.snapshot?.projection.id)
        let feed = sut.autovisorEventFeed
        for i in 0..<5 {
            feed.recordDeleted(taskID: 70_000 + i, origin: .builtInAutovisor, title: "Noise", by: .person)
        }
        let otherLaunch = "00000000.\(feed.epoch)"
        XCTAssertNotEqual(otherLaunch, feed.epochToken, "premise: same counter, another launch")

        for seq in [0, 3, feed.headSeq, feed.headSeq + 7] {
            let cursor = AutovisorEventFeed.formatCursor(folderID: folderID, epoch: otherLaunch, seq: seq)
            let result = await poll(after: cursor)
            XCTAssertEqual(result.cursorResetReason, .restarted, "seq \(seq)")
            XCTAssertEqual(result.cursor, feed.currentCursor)
        }
        let builtByAnEarlierBuild = "\(folderID.uuidString):\(feed.epoch):1"
        let polled = await poll(after: builtByAnEarlierBuild)
        XCTAssertEqual(polled.cursorResetReason, .restarted)
    }

    /// Two launches that opened the folder and started the server in either order hold the same
    /// counter, and still never take each other's cursors.
    func testEpochToken_differsAcrossLaunches_inEitherOrderOfOpenAndServerStart() {
        let folder = UUID()
        let first = AutovisorEventFeed(launchID: "aaaaaaaa")
        first.activateFolder(folderID: folder)
        first.bumpEpochForServerEnable()
        let second = AutovisorEventFeed(launchID: "bbbbbbbb")
        second.bumpEpochForServerEnable()
        second.activateFolder(folderID: folder)
        second.bumpEpochForServerEnable()

        XCTAssertEqual(first.epoch, second.epoch, "premise: the counters agree")
        XCTAssertNotEqual(first.epochToken, second.epochToken)
        XCTAssertEqual(first.epochToken, "aaaaaaaa.2")
        XCTAssertEqual(AutovisorEventFeed.processLaunchID.count, 8)
    }

    // MARK: - A wait begun while the folder cannot be supervised

    func testWaitBegunWhileTheAutovisorIsOff_endsAtOnceWithNotReady() async throws {
        try await openExternalFolder()
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        await sut.setAutovisorEnabled(false)

        let started = Date()
        let result = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.waitForEvents,
            args: ["after": cursor, "timeout_seconds": 30],
            agent: agentA)

        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a wait that cannot be answered does not park")
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let data = try XCTUnwrap(envelope["data"] as? [String: Any], result.outputJSON)
        XCTAssertEqual(data["stop_reason"] as? String, "not_ready")
        XCTAssertEqual(data["cursor"] as? String, cursor, "the agent keeps its place")
        XCTAssertEqual(data["timed_out"] as? Bool, false)
    }

    func testWaitBegunUnderTheBuiltInDriver_endsAtOnceWithDriverChanged() async throws {
        try await openExternalFolder()
        await sut.setAutovisorDriver(.builtInModel)

        let result = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.waitForEvents,
            args: ["timeout_seconds": 30],
            agent: agentA)

        XCTAssertTrue(result.outputJSON.contains(#""stop_reason":"driver_changed""#), result.outputJSON)
    }

    func testImmediateStop_perReadinessState() {
        XCTAssertNil(AutovisorWaitStopReason.immediate(for: .ready))
        XCTAssertEqual(AutovisorWaitStopReason.immediate(for: .folderTransition), .folderChanged)
        XCTAssertEqual(AutovisorWaitStopReason.immediate(for: .builtInDriver), .driverChanged)
        XCTAssertEqual(AutovisorWaitStopReason.immediate(for: .noWorkFolder), .notReady)
        XCTAssertEqual(AutovisorWaitStopReason.immediate(for: .folderInUse), .notReady)
        XCTAssertEqual(AutovisorWaitStopReason.immediate(for: .autovisorDisabled), .notReady)
    }

    func testWaitWithNoFolderOpen_endsAtOnceWithNotReady() async throws {
        let result = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.waitForEvents,
            args: ["timeout_seconds": 30],
            agent: agentA)

        XCTAssertTrue(result.outputJSON.contains(#""stop_reason":"not_ready""#), result.outputJSON)
    }

    // MARK: - Who switched the Autovisor off

    /// A flip records what flipped it, and `folder_status` reads it back: the agent whose calls
    /// start being refused can tell the person why. Switching to the state it is in records nothing.
    func testSwitch_isRecordedOnAFlip_andReadBackByFolderStatus() async throws {
        try await openExternalFolder()
        let enabledAt = try XCTUnwrap(sut.snapshot?.workFolder.settings.autovisorLastSwitch)
        XCTAssertEqual(enabledAt.by, .person)

        await sut.setAutovisorEnabled(true)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorLastSwitch, enabledAt, "no flip, no record")

        await sut.setAutovisorEnabled(false)
        let offSwitch = try XCTUnwrap(sut.snapshot?.workFolder.settings.autovisorLastSwitch)
        XCTAssertEqual(offSwitch.by, .person)
        XCTAssertGreaterThan(offSwitch.at, enabledAt.at)

        let status = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.folderStatus, args: [:], agent: agentA)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(status.outputJSON.utf8)) as? [String: Any])
        let readiness = try XCTUnwrap((envelope["data"] as? [String: Any])?["readiness"] as? [String: Any])
        XCTAssertEqual(readiness["state"] as? String, "autovisor_disabled")
        XCTAssertEqual(readiness["changed_by"] as? String, "person")
        XCTAssertEqual(readiness["since"] as? String, JSONCoderFactory.iso8601Formatter.string(from: offSwitch.at))
    }

    func testAutoOff_recordsItself() async throws {
        try await openExternalFolder()
        await sut.mutateWorkFolder {
            $0.settings.autovisorActivation.autoDisableEnabled = true
            $0.settings.autovisorActivation.autoDisableAfterSeconds = 60
        }
        let armedAt = Date()
        sut.rearmAutovisorAutoDisable(now: armedAt)

        await sut.evaluateAutovisorAutoDisable(now: armedAt.addingTimeInterval(120), within: sut.currentFolderLifecycle)

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorLastSwitch?.by, .autoOff)
        XCTAssertEqual(sut.externalAutovisorReadiness.changedBy, "auto_off")
    }

    func testDeletingTheAutovisor_recordsTheDeletion_onlyWhenItWasOn() async throws {
        await sut.openWorkFolder(tempDir)
        await sut.setAutovisorEnabled(true)
        XCTAssertNotNil(sut.autovisorTaskID, "premise: the built-in manager exists")

        await sut.deleteAutovisor()

        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorEnabled, false)
        XCTAssertEqual(sut.snapshot?.workFolder.settings.autovisorLastSwitch?.by, .deleted)
    }

    // MARK: - Review of W1 (2026-11-09)

    /// A task on the active (non-chat) team with one role at its acceptance gate and another
    /// still working — what a Pause stops, and what `manage_role` decides on meanwhile. Real
    /// roster roles: `request_changes` refuses a role the team does not have.
    private func gatedOwnTask() async throws -> (taskID: Int, gated: String, working: String) {
        try await openExternalFolderForCreates()
        let roles = try XCTUnwrap(sut.snapshot?.workFolder.activeTeam?.nonSupervisorRoles)
        XCTAssertGreaterThanOrEqual(roles.count, 2, "premise: a team of two roles at least")
        let gated = roles[0].id, working = roles[1].id
        let created = await sut.createTask(
            title: "Gated", supervisorTask: "Brief", makeActive: false, origin: .externalAgent(agentA))
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(false)
            task.runs = [Run(
                id: 0,
                steps: [
                    StepExecution(id: gated, role: .custom(id: gated), title: "Gated", status: .done),
                    StepExecution(id: working, role: .custom(id: working), title: "Working", status: .running),
                ],
                roleStatuses: [gated: .needsAcceptance, working: .working]
            )]
        }
        return (taskID, gated, working)
    }

    /// `correct` is an explicit verb: it resumes the agent's own pause, and the agent's own Resume is not
    /// told back to it. Until this review the parked-question branch answered as the built-in
    /// Autovisor — the agent got a `resumed` by "person" for its own call.
    func testAgentsCorrect_ofItsOwnPause_resumesAsTheAgent_andIsNotEchoed() async throws {
        try await openExternalFolder()
        let taskID = try await questionOwnTask()
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)
        _ = await act(.controlTask(taskID: taskID, verb: .pause))

        let corrected = await act(.manageRole(taskID: taskID, roleID: "eng", verb: .correct(comment: "Use SQLite.")))

        XCTAssertTrue(corrected.ok, corrected.message)
        XCTAssertEqual(timeline(taskID).map(\.kind), [.runPaused, .runResumed])
        XCTAssertEqual(timeline(taskID).last?.actor, .externalAgent(agentA))
        XCTAssertNotEqual(sut.taskEngineStates[taskID], .paused)
        let live = await poll(after: cursor)
        XCTAssertEqual(describe(live.events), [], "both are the agent's own")
    }

    /// Not of the person's Pause: until 2026-11-12 `correct` lifted it as the agent (this test
    /// pinned that); since then it is refused and the task stays paused — only the person lifts
    /// their Pause (D-M18; the whole contract is `PersonsPauseGateTests`).
    func testAgentsCorrect_ofThePersonsPause_isRefused() async throws {
        try await openExternalFolder()
        let taskID = try await questionOwnTask()
        _ = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(sut.isPausedInTheApp(taskID: taskID), "premise")

        let corrected = await act(.manageRole(taskID: taskID, roleID: "eng", verb: .correct(comment: "Use SQLite.")))

        XCTAssertFalse(corrected.ok, corrected.message)
        XCTAssertEqual(corrected.failure, .pausedByPerson)
        XCTAssertEqual(timeline(taskID).map(\.actor), [.person])
        XCTAssertEqual(sut.taskEngineStates[taskID], .paused)
    }

    /// Accept on a task the person paused: recorded, and the run stays asleep — waking the engine
    /// resumed a paused one, so the decision lifted the person's Pause as a side effect.
    func testAgentsAccept_onThePersonsPause_isRecorded_andTheRunStaysPaused() async throws {
        let (taskID, gated, working) = try await gatedOwnTask()
        _ = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(sut.isPausedInTheApp(taskID: taskID), "premise")

        let accepted = await act(.manageRole(taskID: taskID, roleID: gated, verb: .accept))

        XCTAssertTrue(accepted.ok, accepted.message)
        XCTAssertEqual(accepted.outcome, .recordedPausedByPerson)
        XCTAssertTrue(accepted.message.hasSuffix(AutovisorReply.decisionWaitsForThePersonsResume(taskID: taskID).text),
                      accepted.message)
        let run = try XCTUnwrap(sut.loadedTask(taskID)?.runs.last)
        XCTAssertEqual(run.roleStatuses[gated], .accepted, "the decision stands")
        XCTAssertEqual(run.steps.first { $0.id == working }?.status, .paused, "the work stays stopped")
        XCTAssertNotEqual(sut.taskEngines[taskID]?.state, .running)
        XCTAssertTrue(sut.isPausedInTheApp(taskID: taskID))
        XCTAssertFalse(timeline(taskID).contains { $0.kind == .runResumed })
    }

    func testAgentsRequestChanges_onThePersonsPause_isRecorded_withNoStallBanner() async throws {
        let (taskID, gated, _) = try await gatedOwnTask()
        _ = await sut.pauseRun(taskID: taskID)
        sut.lastErrorMessage = nil

        let requested = await act(.manageRole(taskID: taskID, roleID: gated, verb: .requestChanges(comment: "Add tests.")))

        XCTAssertTrue(requested.ok, requested.message)
        XCTAssertEqual(requested.outcome, .recordedPausedByPerson)
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.roleStatuses[gated], .revisionRequested)
        XCTAssertNil(sut.lastErrorMessage, "a wake withheld on purpose is no stall: \(sut.lastErrorMessage ?? "")")
        XCTAssertTrue(sut.isPausedInTheApp(taskID: taskID))
    }

    /// The same decision with no Pause standing reports nothing extra; the person's own decision
    /// never waits for anyone.
    func testDecisionWaits_onlyForTheAutovisor_andOnlyOnThePersonsPause() async throws {
        let (taskID, _, _) = try await gatedOwnTask()
        XCTAssertFalse(sut.decisionWaitsForThePersonsResume(taskID: taskID, by: agent), "nothing paused")
        _ = await sut.pauseRun(taskID: taskID)
        XCTAssertTrue(sut.decisionWaitsForThePersonsResume(taskID: taskID, by: agent))
        XCTAssertFalse(sut.decisionWaitsForThePersonsResume(taskID: taskID, by: nil), "the person's own")
    }

    /// The built-in Autovisor's own Pause is its to lift: `isPausedInTheApp` is the person's alone.
    /// On the wire both read `by_person`.
    func testBuiltInsOwnPause_isNotThePersons() async throws {
        let folderID = try await openExternalFolder()
        let builtInsTask = try await runningOwnTask("Built-in's")
        let personsTask = try await runningOwnTask("Person's")

        _ = await sut.pauseRun(taskID: builtInsTask, by: .builtInAutovisor)
        _ = await sut.pauseRun(taskID: personsTask, by: .person)

        XCTAssertFalse(sut.isPausedInTheApp(taskID: builtInsTask))
        XCTAssertTrue(sut.isPausedInTheApp(taskID: personsTask))
        let status = try await taskStatusData(builtInsTask, folderID: folderID)
        XCTAssertEqual(status["pause_reason"] as? String, "by_person")
    }

    /// A delegating task's Pause leaves the step suspended on `delegate_to_team` running, so the
    /// task derives `.running` with its engine paused — still the person's Pause.
    func testEnginePausedUnderARunningStep_isThePersonsPauseToo() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].pauseCause = .requested
            task.runs[0].pauseRequestedBy = .person
        }
        XCTAssertFalse(sut.isPausedInTheApp(taskID: taskID), "premise: nothing says paused yet")
        let engine = sut.engineForTask(taskID)
        engine.transition(to: .paused)

        XCTAssertTrue(sut.isPausedInTheApp(taskID: taskID))
    }

    /// An iteration-limit pause is the engine's alone: the steps stay unparked, the task derives
    /// `.running`, and the Resume recorded nothing — the agent told `paused(iteration_limit)`
    /// never heard it lifted.
    func testResumeOfAnIterationLimitPause_isRecordedAndDelivered() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        let engine = sut.engineForTask(taskID)
        engine.pausedIterationLimit = 50
        engine.transition(to: .paused)
        XCTAssertEqual(sut.loadedTask(taskID).flatMap { sut.autovisorPauseReason(of: $0) }, .iterationLimit, "premise")
        let cursor = try XCTUnwrap(sut.autovisorEventFeed.currentCursor)

        await sut.resumeRun(taskID: taskID, by: .person)

        XCTAssertEqual(timeline(taskID).map(\.kind), [.runResumed])
        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.pauseCause, .resumed)
        let live = await poll(after: cursor)
        XCTAssertEqual(describe(live.events), ["resumed#\(taskID)<person"])
    }

    /// A Resume lifts the cause with the pause: a later pause that records no cause of its own —
    /// the recovery latch armed over a role left `.working` beside a `.pending` step — reads
    /// `recovered`, not the lifted pause's requester (an agent's would have been echo-dropped).
    func testResumedRun_laterLatchedByRecovery_readsRecovered() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        _ = await act(.controlTask(taskID: taskID, verb: .pause))
        _ = await act(.controlTask(taskID: taskID, verb: .resume))
        let run = try XCTUnwrap(sut.loadedTask(taskID)?.runs.last)
        XCTAssertEqual(run.pauseCause, .resumed)
        XCTAssertNil(run.pauseRequestedBy)

        XCTAssertEqual(AutovisorPauseReason.resolve(run: run, taskStatus: .paused, isPaused: true, liveIterationLimitPause: false),
                       .recovered)
    }

    func testResumedCause_isNotTheTimeout() {
        var run = Run(id: 0, steps: [], roleStatuses: [:])
        run.timedOutAt = Date()
        run.pauseCause = .resumed
        XCTAssertFalse(run.latestPauseIsItsTimeout, "the timeout's pause was lifted")
        run.pauseCause = nil
        XCTAssertTrue(run.latestPauseIsItsTimeout, "a run from before the cause still reads as it did")
    }

    /// An agent's Pause landing while the person's is still stopping the run (its cancellations
    /// await their handlers) pauses nothing more, and is not recorded over the person's.
    func testAgentsPause_whileThePersonsStillStops_keepsThePersons() async throws {
        try await openExternalFolder()
        let taskID = try await runningOwnTask()
        _ = await sut.pauseRun(taskID: taskID)
        _ = await sut.mutateTask(taskID: taskID) { $0.runs[0].steps[0].status = .running }

        _ = await act(.controlTask(taskID: taskID, verb: .pause))

        XCTAssertEqual(sut.loadedTask(taskID)?.runs.last?.pauseRequestedBy, .person)
        XCTAssertEqual(timeline(taskID).map(\.actor), [.person])
    }

    func testKeepsThePersonsPause_table() {
        func keeps(_ cause: Run.PauseCause?, standing: ControlActor?, against requester: ControlActor?) -> Bool {
            var run = Run(id: 0, steps: [], roleStatuses: [:])
            run.pauseCause = cause
            run.pauseRequestedBy = standing
            return NTMSOrchestrator.keepsThePersonsPause(of: run, against: requester)
        }
        let agent = ControlActor.externalAgent(agentA)
        XCTAssertTrue(keeps(.requested, standing: .person, against: agent))
        XCTAssertTrue(keeps(.requested, standing: nil, against: agent), "recorded before the requester: the person's")
        XCTAssertTrue(keeps(.requested, standing: .person, against: .builtInAutovisor))
        XCTAssertFalse(keeps(.requested, standing: .person, against: .person), "the person re-pausing")
        XCTAssertFalse(keeps(.requested, standing: .person, against: nil), "a timeout or other cause")
        XCTAssertFalse(keeps(.requested, standing: agent, against: agent))
        XCTAssertFalse(keeps(.resumed, standing: nil, against: agent), "lifted: nothing to keep")
        XCTAssertFalse(keeps(.runTimedOut, standing: nil, against: agent))
        XCTAssertFalse(keeps(nil, standing: nil, against: agent))
    }

    // MARK: Stopped waits agree

    func testStoppedWait_dropsTheCursorOnlyAcrossAFolderChange_andSaysSo() {
        for reason in AutovisorWaitStopReason.allCases {
            let result = AutovisorWaitResult.stopped(reason, keeping: "e.3:7", waitedSeconds: 2)
            XCTAssertEqual(result.stopReason, reason)
            XCTAssertEqual(result.waitedSeconds, 2)
            if reason == .folderChanged {
                XCTAssertNil(result.cursor)
                XCTAssertEqual(result.cursorResetReason, .folderChanged)
            } else {
                XCTAssertEqual(result.cursor, "e.3:7", "\(reason)")
                XCTAssertNil(result.cursorResetReason, "\(reason)")
            }
        }
    }

    // MARK: request_key outlives the ledger

    /// A folder whose active team can take a task created with no `team_id`.
    @discardableResult
    private func openExternalFolderForCreates() async throws -> String {
        let folderID = try await openExternalFolder()
        if let nonChat = sut.snapshot?.workFolder.teams.first(where: { !$0.isChatMode && !$0.isHiddenFromPickers }) {
            await sut.mutateWorkFolder { $0.setActiveTeam(nonChat.id) }
        }
        return folderID
    }

    private func createVia(_ agentIdentity: AgentIdentity, folderID: String, key: String, title: String = "Keyed") async throws -> [String: Any] {
        try parse(await createOutput(agentIdentity, folderID: folderID, key: key, title: title))
    }

    /// The envelope as text — `Sendable`, so two creates can run at once (`async let`).
    private func createOutput(_ agentIdentity: AgentIdentity, folderID: String, key: String, title: String) async -> String {
        await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: ["folder_id": folderID, "title": title, "brief": "Brief", "request_key": key],
            agent: agentIdentity
        ).outputJSON
    }

    private func parse(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// The key is the task's own, on its index row: a retry after the ledger is gone — a
    /// relaunch, a folder switch and back — finds the task instead of creating a second.
    func testRetryAfterTheLedgerIsGone_findsTheTaskByItsRequestKey() async throws {
        let folderID = try await openExternalFolderForCreates()
        let first = try await createVia(agentA, folderID: folderID, key: "k1")
        let taskID = try XCTUnwrap((first["data"] as? [String: Any])?["task_id"] as? Int, "\(first)")

        await sut.openWorkFolder(tempDir)
        let reopenedID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
        XCTAssertFalse(sut.autovisorCreationLedger.isRequestInFlight("k1", for: agentA.id))
        let tasksBefore = sut.snapshot?.tasksIndex.tasks.count

        let retry = try await createVia(agentA, folderID: reopenedID, key: "k1")
        let data = try XCTUnwrap(retry["data"] as? [String: Any], "\(retry)")
        XCTAssertEqual(data["status"] as? String, "already_created")
        XCTAssertEqual(data["task_id"] as? Int, taskID)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, tasksBefore)
    }

    func testRequestKey_isPerAgent_andADeletedTaskFreesIt() async throws {
        let folderID = try await openExternalFolderForCreates()
        let agentB = AgentIdentity(id: UUID(uuidString: "cccccccc-1111-2222-3333-444444444442")!, label: "Codex")
        let rows = { self.sut.snapshot?.tasksIndex.tasks ?? [] }
        let first = try await createVia(agentA, folderID: folderID, key: "k1")
        let taskA = try XCTUnwrap((first["data"] as? [String: Any])?["task_id"] as? Int)
        let other = try await createVia(agentB, folderID: folderID, key: "k1")
        let taskB = try XCTUnwrap((other["data"] as? [String: Any])?["task_id"] as? Int, "\(other)")
        XCTAssertNotEqual(taskA, taskB, "another agent's key is not this one's")
        XCTAssertEqual(NTMSOrchestrator.taskCreated(forRequestKey: "k1", by: agentA.id, in: rows()), taskA)
        XCTAssertEqual(NTMSOrchestrator.taskCreated(forRequestKey: "k1", by: agentB.id, in: rows()), taskB)
        XCTAssertNil(NTMSOrchestrator.taskCreated(forRequestKey: "k2", by: agentA.id, in: rows()))

        let deleted = await act(.controlTask(taskID: taskA, verb: .delete))
        XCTAssertTrue(deleted.ok, deleted.message)
        XCTAssertNil(NTMSOrchestrator.taskCreated(forRequestKey: "k1", by: agentA.id, in: rows()))
    }

    /// A retry that arrives while the first create is still under way has no task to find yet:
    /// it is refused, never a second task — and once that create gave up, the key is free.
    func testRetryWhileTheCreateIsUnderWay_isRequestInProgress() async throws {
        let folderID = try await openExternalFolderForCreates()
        let tasksBefore = sut.snapshot?.tasksIndex.tasks.count ?? 0
        // The first create, held between its slot's reservation and its commit.
        let inFlight = try sut.autovisorCreationLedger.tryReserveSlot(
            for: agent, tuning: AutovisorTuning.default, runningCount: 0, requestKey: "k-race").get()

        let refused = try await createVia(agentA, folderID: folderID, key: "k-race")

        let error = try XCTUnwrap(refused["error"] as? [String: Any], "\(refused)")
        XCTAssertEqual(error["code"] as? String, "REQUEST_IN_PROGRESS")
        XCTAssertEqual((refused["next"] as? [String: Any])?["suggested_cmd"] as? String, ExternalAutovisorToolNames.listTasks)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, tasksBefore)

        sut.autovisorCreationLedger.rollback(inFlight)
        let retried = try await createVia(agentA, folderID: folderID, key: "k-race")
        XCTAssertEqual(retried["ok"] as? Bool, true, "\(retried)")
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, tasksBefore + 1)
    }

    /// Two creates with one key at once: one task, whichever order they interleave in.
    func testTwoCreatesWithOneKeyAtOnce_makeOneTask() async throws {
        let folderID = try await openExternalFolderForCreates()
        let tasksBefore = sut.snapshot?.tasksIndex.tasks.count ?? 0

        async let a = createOutput(agentA, folderID: folderID, key: "k-pair", title: "One")
        async let b = createOutput(agentA, folderID: folderID, key: "k-pair", title: "Two")
        let outcomes = try await [a, b].map(parse)

        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.count, tasksBefore + 1, "\(outcomes)")
        let statuses = outcomes.map { ($0["data"] as? [String: Any])?["status"] as? String
            ?? (($0["error"] as? [String: Any])?["code"] as? String ?? "?") }
        XCTAssertEqual(statuses.filter { $0 == "created_and_started" }.count, 1, "\(statuses)")
        XCTAssertTrue(statuses.allSatisfy { ["created_and_started", "already_created", "REQUEST_IN_PROGRESS"].contains($0) },
                      "\(statuses)")
        XCTAssertFalse(sut.autovisorCreationLedger.isRequestInFlight("k-pair", for: agentA.id), "released at the commit")
    }

    func testLedger_holdsAKeyInFlight_untilCommitOrRollback() throws {
        var ledger = AutovisorCreationLedger()
        var tuning = AutovisorTuning.default
        tuning.maxExternalCreationsPerWindow = 10
        tuning.maxOpenExternalTasks = 10
        tuning.maxConcurrentManagedTasks = 10
        let actor = AutovisorActor.externalAgent(agentA)

        let first = try ledger.tryReserveSlot(for: actor, tuning: tuning, runningCount: 0, requestKey: "k").get()
        XCTAssertTrue(ledger.isRequestInFlight("k", for: agentA.id))
        XCTAssertFalse(ledger.isRequestInFlight("k", for: UUID()), "per agent")
        ledger.commit(first)
        XCTAssertFalse(ledger.isRequestInFlight("k", for: agentA.id))

        let second = try ledger.tryReserveSlot(for: actor, tuning: tuning, runningCount: 0, requestKey: "k").get()
        ledger.rollback(second)
        XCTAssertFalse(ledger.isRequestInFlight("k", for: agentA.id))

        _ = try ledger.tryReserveSlot(for: actor, tuning: tuning, runningCount: 0, requestKey: "k").get()
        ledger.resetForFolderTransition()
        XCTAssertFalse(ledger.isRequestInFlight("k", for: agentA.id))

        _ = try ledger.tryReserveSlot(for: actor, tuning: tuning, runningCount: 0).get()
        XCTAssertFalse(ledger.isRequestInFlight("k", for: agentA.id), "a create without a key holds none")
    }

    // MARK: - Wave W8.2: Soft Role Completion Pause Reason Seam

    func testPauseReason_returnsNilForSoftRoleCompletionAtAcceptanceGate() {
        let run = Run(
            id: 0,
            steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .needsApproval)],
            roleStatuses: ["eng": .needsAcceptance]
        )
        let reason = AutovisorPauseReason.resolve(
            run: run,
            taskStatus: .running,
            isPaused: true,
            liveIterationLimitPause: false
        )
        XCTAssertNil(reason, "Soft role completion at acceptance gate must NOT resolve to a pause reason")
    }

    func testPauseReason_returnsByPersonWhenExplicitlyPausedAtAcceptanceGate() {
        var run = Run(
            id: 0,
            steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .needsApproval)],
            roleStatuses: ["eng": .needsAcceptance]
        )
        run.pauseCause = .requested
        run.pauseRequestedBy = .person
        let reason = AutovisorPauseReason.resolve(
            run: run,
            taskStatus: .running,
            isPaused: true,
            liveIterationLimitPause: false
        )
        XCTAssertEqual(reason, .byPerson, "Explicit human pause at acceptance gate must resolve to byPerson")
    }
}

/// The wire's word for an actor, as the tests read events back.
private enum ExternalAutovisorReadOperationsWire {
    static func actor(_ actor: ControlActor) -> String { NTMSOrchestrator.wireActor(actor) }
}
