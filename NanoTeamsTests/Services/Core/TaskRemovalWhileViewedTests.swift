import os
import XCTest
@testable import NanoTeams

/// A removal answers for the task it removed, and nothing that still names that task afterwards
/// turns the removal into a failure (D-M18, 2026-11-12).
///
/// The live defect: task #22 — the agent's own, one run, paused by the person, open on the
/// person's screen — was removed by `control_task delete`, and the agent was told
/// `COMMAND_FAILED "Task not found: 22"`. The task was gone from disk. The open board is what
/// read it back: once the folder's active task moves to the fallback, `MainLayoutView`'s detail
/// renders its loader for the still-selected id and the loader calls `switchTask(to: 22)` — while
/// the removal is suspended in its residency reconcile. The switch found no such task and put
/// `taskNotFound` on the banner, and `reportingError` counts every error surfaced during its op.
/// The person's own Delete runs the same removal and showed the same banner.
///
/// The matrix (active / background × not paused / paused by the person / paused by the agent)
/// is green on the code that had the defect: the removal itself raises nothing. Only the loader's
/// switch does, so that is the case pinned red-first (`…WhileTheBoardStillShowsIt…`).
@MainActor
final class TaskRemovalWhileViewedTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agent = AgentIdentity(
        id: UUID(uuidString: "aaaaaaaa-5555-6666-7777-8888888888d1")!,
        label: "Claude Code"
    )

    private var folderID: String!

    override func tearDown() async throws {
        NTMSOrchestrator._testResidencyReconcileGate = nil
        folderID = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private enum PauseShape: CaseIterable { case notPaused, byPerson, byAgent }

    private func openExternalFolder() async throws {
        await sut.openWorkFolder(tempDir)
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)
    }

    /// The agent's task with one run whose step is working; `makeActive` says whether it is the
    /// task the person has open. A second task is created first, so the removal of an active one
    /// has a fallback to move the folder to — as #18 was for #22.
    private func ownTaskWithARun(makeActive: Bool, pause: PauseShape) async throws -> Int {
        let fallback = await sut.createTask(
            title: "Fallback", supervisorTask: "Stays", makeActive: true, origin: .externalAgent(agent))
        _ = try XCTUnwrap(fallback)
        let created = await sut.createTask(
            title: "Calculator", supervisorTask: "Build a calculator",
            makeActive: makeActive, origin: .externalAgent(agent))
        let taskID = try XCTUnwrap(created)
        await sut.ensureTaskLoaded(taskID)
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(id: "eng", role: .softwareEngineer, title: "Engineer", status: .running)],
                roleStatuses: ["eng": .working]
            )]
        }
        switch pause {
        case .notPaused:
            break
        case .byPerson:
            let paused = await sut.pauseRun(taskID: taskID)
            XCTAssertTrue(paused, "premise: the person's Pause stopped the step")
        case .byAgent:
            let paused = await control(taskID, "pause")
            XCTAssertFalse(paused.isError, "premise: \(paused.outputJSON)")
        }
        XCTAssertEqual(sut.activeTaskID == taskID, makeActive, "premise")
        return taskID
    }

    private func control(_ taskID: Int, _ action: String) async -> ToolExecutionResult {
        await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.controlTask,
            args: ["folder_id": folderID as Any, "task_id": taskID, "action": action],
            agent: agent)
    }

    /// What `MainLayoutView`'s detail does once the selected task is no longer the active one:
    /// its loader asks to switch to it. Held at the moment it happens live — while the removal
    /// is suspended in its residency reconcile, after the folder moved to the fallback.
    private func boardStillShows(_ taskID: Int) {
        let fired = OSAllocatedUnfairLock(initialState: false)
        NTMSOrchestrator._testResidencyReconcileGate = { @MainActor [weak self] in
            let first = fired.withLock { state -> Bool in
                defer { state = true }
                return !state
            }
            guard first, let sut = self?.sut else { return }
            await sut.switchTask(to: taskID)
        }
    }

    private func assertGone(_ taskID: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(sut.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID }), file: file, line: line)
        XCTAssertNil(sut.loadedTask(taskID), file: file, line: line)
        XCTAssertNotEqual(sut.activeTaskID, taskID, file: file, line: line)
    }

    private func assertDeletedReply(
        _ result: ToolExecutionResult, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(result.isError, result.outputJSON, file: file, line: line)
        let object = (try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))) as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, true, result.outputJSON, file: file, line: line)
        XCTAssertFalse(result.outputJSON.contains("Task not found"), result.outputJSON, file: file, line: line)
    }

    // MARK: - The matrix: the removal alone

    func testAgentDelete_ofItsOwnTaskWithARun_isOk_inEveryShape() async throws {
        try await openExternalFolder()
        for makeActive in [true, false] {
            for pause in PauseShape.allCases {
                let taskID = try await ownTaskWithARun(makeActive: makeActive, pause: pause)
                let errorsBefore = sut.errorSurfaceCount

                let deleted = await control(taskID, "delete")

                assertDeletedReply(deleted)
                assertGone(taskID)
                XCTAssertEqual(sut.errorSurfaceCount, errorsBefore,
                               "active \(makeActive), \(pause): \(sut.lastErrorMessage ?? "")")
            }
        }
    }

    func testPersonsDelete_ofATaskWithARun_surfacesNothing_inEveryShape() async throws {
        try await openExternalFolder()
        for makeActive in [true, false] {
            for pause in PauseShape.allCases {
                let taskID = try await ownTaskWithARun(makeActive: makeActive, pause: pause)
                let errorsBefore = sut.errorSurfaceCount

                await sut.removeTask(taskID)

                assertGone(taskID)
                XCTAssertEqual(sut.errorSurfaceCount, errorsBefore,
                               "active \(makeActive), \(pause): \(sut.lastErrorMessage ?? "")")
            }
        }
    }

    // MARK: - The board that still shows the removed task

    /// The live shape: #22 open on the person's screen, paused by them, removed by the agent.
    func testAgentDelete_whileTheBoardStillShowsTheTask_isOk_andTheTaskIsGone() async throws {
        try await openExternalFolder()
        let taskID = try await ownTaskWithARun(makeActive: true, pause: .byPerson)
        boardStillShows(taskID)
        let errorsBefore = sut.errorSurfaceCount

        let deleted = await control(taskID, "delete")

        assertDeletedReply(deleted)
        assertGone(taskID)
        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, sut.lastErrorMessage ?? "")
    }

    /// The person's own Delete from the sidebar: `SidebarView` moves the selection to the
    /// Watchtower only after the removal returns, so the loader asks for the task in between.
    func testPersonsDelete_whileTheBoardStillShowsTheTask_surfacesNoBanner() async throws {
        try await openExternalFolder()
        let taskID = try await ownTaskWithARun(makeActive: true, pause: .notPaused)
        boardStillShows(taskID)
        let errorsBefore = sut.errorSurfaceCount

        await sut.removeTask(taskID)

        assertGone(taskID)
        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, sut.lastErrorMessage ?? "")
        XCTAssertNil(sut.lastErrorMessage)
    }

    // MARK: - An error that is not the removal's (D-M18, 2026-11-13)

    /// The class the loader was one instance of: while the agent's delete is suspended in its
    /// residency reconcile, a task the delete never called — another task's failing write, a
    /// view action, a timer — surfaces an error. The delete answers for itself (`ok`), and the
    /// error is the person's to see: the banner suppression that keeps the agent's refusals off
    /// the screen covers the agent's call, not every task that runs while it is in flight.
    /// RED on the process-wide counter and suppression depth: the reply was `COMMAND_FAILED`
    /// carrying the foreign message, and the person's banner was cleared.
    func testAgentDelete_whileAnotherTaskSurfacesAnError_isOk_andThePersonSeesTheError() async throws {
        try await openExternalFolder()
        let taskID = try await ownTaskWithARun(makeActive: false, pause: .notPaused)
        let foreign = ForeignErrorSurface(sut, message: "Failed to save task: disk full")
        defer { foreign.cancel() }
        let fired = OSAllocatedUnfairLock(initialState: false)
        NTMSOrchestrator._testResidencyReconcileGate = {
            let first = fired.withLock { state -> Bool in
                defer { state = true }
                return !state
            }
            guard first else { return }
            await foreign.fire()
        }

        let deleted = await control(taskID, "delete")

        XCTAssertTrue(fired.withLock { $0 }, "premise: the foreign error surfaced during the delete")
        assertDeletedReply(deleted)
        XCTAssertFalse(deleted.outputJSON.contains("disk full"), deleted.outputJSON)
        assertGone(taskID)
        XCTAssertEqual(sut.lastErrorMessage, "Failed to save task: disk full",
                       "the foreign error is the person's banner, not the agent's to suppress")
    }

    /// A switch to a task the folder no longer has switches nothing and says nothing: the active
    /// task stays where the removal put it.
    func testSwitch_toARemovedTask_switchesNothing_andSurfacesNothing() async throws {
        try await openExternalFolder()
        let taskID = try await ownTaskWithARun(makeActive: true, pause: .notPaused)
        await sut.removeTask(taskID)
        let fallback = sut.activeTaskID
        XCTAssertNotNil(fallback, "premise")
        let errorsBefore = sut.errorSurfaceCount

        await sut.switchTask(to: taskID)

        XCTAssertEqual(sut.activeTaskID, fallback)
        XCTAssertEqual(sut.errorSurfaceCount, errorsBefore, sut.lastErrorMessage ?? "")
    }

    /// The guard is the folder's index, not the file: a task the index still lists whose
    /// `task.json` is missing is a real fault, and the switch still reports it.
    func testSwitch_toAnIndexedTaskWhoseFileIsMissing_stillReportsIt() async throws {
        try await openExternalFolder()
        let taskID = try await ownTaskWithARun(makeActive: false, pause: .notPaused)
        let url = try XCTUnwrap(sut.workFolderURL)
        let paths = NTMSPaths(workFolderRoot: url)
        try FileManager.default.removeItem(at: paths.taskJSON(taskID: taskID))
        sut.evictLoadedTask(taskID)
        let errorsBefore = sut.errorSurfaceCount

        await sut.switchTask(to: taskID)

        XCTAssertGreaterThan(sut.errorSurfaceCount, errorsBefore)
        XCTAssertNotEqual(sut.activeTaskID, taskID)
    }
}
