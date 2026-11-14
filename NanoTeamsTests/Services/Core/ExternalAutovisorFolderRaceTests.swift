import XCTest
@testable import NanoTeams

/// An external agent's write that is suspended when the person opens another folder. The call
/// began in folder A; while it waits — on the pending active-task write, or on its own task write
/// — folder B is opened. Task ids are per folder, so B holds a task of the same id, and the call
/// must answer `folder_changed` and touch nothing of B's (`DeferredCallReplies.folderChanged`).
///
/// These are the race arms of `ExternalAutovisorOperations` that the coverage tail of
/// 2026-11-07 left without a test: a create whose flush straddles the open, and a schedule whose
/// write does — on both of its paths, the interval one through the shared Autovisor action and
/// the calendar one through `setTaskRecurrence`.
@MainActor
final class ExternalAutovisorFolderRaceTests: WorkFolderLifecycleTestCase {

    private let agent = AgentIdentity(
        id: UUID(uuidString: "dddddddd-1111-2222-3333-444444444444")!,
        label: "Claude Code"
    )

    /// Opens `folder` ready for the external driver and returns its id. Its active team is one a
    /// managed task can finish on — the default Coding Assistant is a chat team, which a create
    /// with no `team_id` refuses.
    private func openExternalFolder(_ folder: URL) async throws -> String {
        await sut.openWorkFolder(folder)
        let pipeline = try XCTUnwrap(sut.snapshot?.workFolder.teams.first { !$0.isChatMode && !$0.isHiddenFromPickers })
        await sut.mutateWorkFolder { $0.setActiveTeam(pipeline.id) }
        await sut.setAutovisorDriver(.externalAgent)
        _ = await sut.setAutovisorEnabled(true)
        return try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
    }

    /// B with a task of id 0, then A with the agent's task of id 0 — the id B's task also has.
    private func sameIDFolders() async throws -> (folderAID: String, agentTask: Int, bTask: Int) {
        await sut.openWorkFolder(folderB)
        let bCreated = await sut.createTask(title: "B one", supervisorTask: "b", makeActive: false)
        let bTask = try XCTUnwrap(bCreated)
        let folderAID = try await openExternalFolder(folderA)
        let created = await sut.createTask(
            title: "agent task", supervisorTask: "a", makeActive: true, origin: .externalAgent(agent))
        let agentTask = try XCTUnwrap(created)
        XCTAssertEqual(agentTask, bTask, "premise: both folders number their first task the same")
        return (folderAID, agentTask, bTask)
    }

    private func call(_ tool: String, _ args: [String: Any]) async -> (isError: Bool, message: String) {
        let result = await sut.executeExternalAutovisorTool(name: tool, args: args, agent: agent)
        let data = Data(result.outputJSON.utf8)
        let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (envelope?["error"] as? [String: Any])?["message"] as? String ?? ""
        return (result.isError, message)
    }

    private func taskJSON(_ folder: URL, _ taskID: Int) -> URL {
        NTMSPaths(workFolderRoot: folder).taskJSON(taskID: taskID)
    }

    /// Whether `folder` holds a task of `taskID` on disk — read without opening the folder.
    private func hasTask(_ taskID: Int, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: taskJSON(folder, taskID).path)
    }

    // MARK: - create_managed_task

    /// The create waits on the pending active-task write before it writes the new task; B commits
    /// meanwhile. RED if the `.folderChanged` outcome were read as a creation: a task would be
    /// reported, and a later write would go to the folder now open.
    func testACreateWhoseFlushStraddlesAnOpen_answersFolderChanged_andCreatesNothing() async throws {
        let (folderAID, agentTask, _) = try await sameIDFolders()
        let next = agentTask + 1
        XCTAssertFalse(hasTask(next, in: folderA), "premise")
        XCTAssertFalse(hasTask(next, in: folderB), "premise")
        let released = holdPendingPointerWrite()

        let creating = Task {
            await self.call(ExternalAutovisorToolNames.createManagedTask, ["folder_id": folderAID, "brief": "Write a script"])
        }
        for _ in 0..<5 { await Task.yield() }
        await sut.openWorkFolder(folderB)
        released.yield()
        released.finish()
        let answer = await creating.value

        XCTAssertTrue(answer.isError)
        XCTAssertEqual(answer.message, DeferredCallReplies.folderChanged)
        XCTAssertFalse(hasTask(next, in: folderA), "a task was created in the folder that was left")
        XCTAssertFalse(hasTask(next, in: folderB), "a task was created in the folder now open")
    }

    // MARK: - A call that arrives while an open is in progress

    /// The call begins while B's open is reading: no folder changed during the CALL, the call
    /// arrived in a transition — so it is told that, in the same words a write is told, and not
    /// the race reply. RED before `ExternalFolderRefusal`: `validateActiveFolderID` answered
    /// every unready state with `DeferredCallReplies.folderChanged`.
    func testACallDuringAnOpen_isToldATransitionIsInProgress_notThatTheFolderChanged() async throws {
        let (folderAID, agentTask, _) = try await sameIDFolders()
        let read = holdReads(of: folderB)
        let opening = try await startOpen(of: folderB)
        XCTAssertTrue(sut.isFolderTransitionInProgress, "premise: B's open is between its start and its commit")

        let result = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.taskStatus,
            args: ["folder_id": folderAID, "task_id": agentTask],
            agent: agent)
        read.release()
        await opening.value

        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let error = try XCTUnwrap(envelope["error"] as? [String: Any], result.outputJSON)
        XCTAssertEqual(error["message"] as? String, ExternalFolderRefusal.folderTransitionInProgress.message)
        XCTAssertEqual(error["code"] as? String, ToolErrorCode.commandFailed.rawValue)
        XCTAssertNotEqual(error["message"] as? String, DeferredCallReplies.folderChanged)
    }

    // MARK: - schedule_task

    /// Holds the write that stores the agent task's recurrence, opens B, then releases it.
    private func scheduleStraddlingAnOpen(_ schedule: [String: Any]) async throws -> (isError: Bool, message: String, bBefore: Data, bTask: Int) {
        let (folderAID, agentTask, bTask) = try await sameIDFolders()
        let bBefore = try Data(contentsOf: taskJSON(folderB, bTask))
        let path = folderA.path
        let write = TaskWriteHold { folder, task in
            folder.path == path && task.id == agentTask && task.recurrence != nil
        }
        repository.taskWriteHold = write

        var args: [String: Any] = ["folder_id": folderAID, "task_id": agentTask]
        args.merge(schedule) { $1 }
        let scheduling = Task { await self.call(ExternalAutovisorToolNames.scheduleTask, args) }
        try await waitHeld(write, "the schedule's recurrence write")
        await sut.openWorkFolder(folderB)
        write.release()
        let answer = await scheduling.value
        return (answer.isError, answer.message, bBefore, bTask)
    }

    /// The calendar path writes through `setTaskRecurrence` and asks its lifecycle after the write.
    func testAScheduleWhoseRecurrenceWriteStraddlesAnOpen_answersFolderChanged() async throws {
        let answer = try await scheduleStraddlingAnOpen(["repeat_daily_at": "09:00"])

        XCTAssertTrue(answer.isError)
        XCTAssertEqual(answer.message, DeferredCallReplies.folderChanged)
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderB, answer.bTask)), answer.bBefore,
                       "B's task of the same id was written")
        XCTAssertNil(sut.loadedTask(answer.bTask)?.recurrence, "B's task was scheduled")
    }

    /// The interval path writes through the shared Autovisor action, whose own lifecycle check
    /// answers; the tool relays that failure rather than reporting the schedule.
    func testAnIntervalScheduleWhoseWriteStraddlesAnOpen_relaysTheFolderChange() async throws {
        let answer = try await scheduleStraddlingAnOpen(["repeat_every_minutes": 30])

        XCTAssertTrue(answer.isError)
        XCTAssertEqual(answer.message, DeferredCallReplies.folderChanged)
        XCTAssertEqual(try Data(contentsOf: taskJSON(folderB, answer.bTask)), answer.bBefore,
                       "B's task of the same id was written")
        XCTAssertNil(sut.loadedTask(answer.bTask)?.recurrence, "B's task was scheduled")
    }
}
