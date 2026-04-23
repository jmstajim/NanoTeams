import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for **"Close Task"** — Supervisor reviews the
/// final deliverable, clicks "Close Task", the task transitions to `.done`,
/// but the on-disk artifacts + run logs stay put so the Supervisor can
/// re-open the folder later and browse deliverables.
///
/// Pinned behaviors:
/// 1. closeTask returns true, transitions task to `closedAt != nil`.
/// 2. Task's derived status becomes `.done`.
/// 3. Task is NOT removed from the tasks index (still shown under "Done" filter).
/// 4. `task.json` stays on disk.
/// 5. Artifact files under `.nanoteams/tasks/{id}/runs/...` are preserved.
/// 6. Closing a task that's already closed is idempotent.
/// 7. Closing a non-existent task returns false with lastErrorMessage.
/// 8. Engine for the closed task is stopped (no further LLM work).
/// 9. Survives reopen — the closed state persists.
@MainActor
final class EndToEndCloseTaskPreservesArtifactsTests: NTMSOrchestratorTestBase {

    private func seedTaskWithAllDoneSteps() async -> Int {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!

        await sut.mutateTask(taskID: id) { task in
            let step = StepExecution(
                id: "pm", role: .productManager, title: "PM",
                status: .done,
                completedAt: MonotonicClock.shared.now()
            )
            var run = Run(id: 0, steps: [step], roleStatuses: ["pm": .done])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        return id
    }

    // MARK: - Scenario 1: Close sets closedAt

    func testCloseTask_setsClosedAtAndReturnsTrue() async {
        let id = await seedTaskWithAllDoneSteps()

        let ok = await sut.closeTask(taskID: id)
        XCTAssertTrue(ok)
        XCTAssertNotNil(sut.loadedTask(id)?.closedAt,
                        "closeTask must set closedAt")
    }

    // MARK: - Scenario 2: Derived status → done

    func testCloseTask_derivedStatusIsDone() async {
        let id = await seedTaskWithAllDoneSteps()
        _ = await sut.closeTask(taskID: id)

        XCTAssertEqual(sut.loadedTask(id)?.derivedStatusFromActiveRun(), .done,
                       "After close, derived status must be .done")
    }

    // MARK: - Scenario 3: Task stays in index (browse-after-close)

    func testCloseTask_staysInTasksIndex() async {
        let id = await seedTaskWithAllDoneSteps()
        _ = await sut.closeTask(taskID: id)

        let ids = sut.snapshot?.tasksIndex.tasks.map(\.id) ?? []
        XCTAssertTrue(ids.contains(id),
                      "Closed task stays in the index — only explicit delete removes it")
    }

    // MARK: - Scenario 4: task.json stays on disk

    func testCloseTask_taskJSON_staysOnDisk() async {
        let id = await seedTaskWithAllDoneSteps()
        _ = await sut.closeTask(taskID: id)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.taskJSON(taskID: id).path),
                      "task.json must persist after close")
    }

    // MARK: - Scenario 5: Artifacts preserved on disk

    func testCloseTask_runArtifactDir_notDeleted() async throws {
        let id = await seedTaskWithAllDoneSteps()

        // Write a fake artifact file under the task's runs dir
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let roleDir = paths.roleDir(taskID: id, runID: 0, roleID: "pm")
        try FileManager.default.createDirectory(
            at: roleDir, withIntermediateDirectories: true
        )
        let artifactFile = roleDir.appendingPathComponent("artifact_foo.md")
        try "# Deliverable".data(using: .utf8)!.write(to: artifactFile)

        _ = await sut.closeTask(taskID: id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactFile.path),
                      "Artifact file must survive closeTask (deletion only via removeTask)")
    }

    // MARK: - Scenario 6: Idempotency

    func testCloseTask_calledTwice_secondCallIsNoop() async {
        let id = await seedTaskWithAllDoneSteps()

        let first = await sut.closeTask(taskID: id)
        XCTAssertTrue(first)
        let firstClosedAt = sut.loadedTask(id)?.closedAt

        let second = await sut.closeTask(taskID: id)
        XCTAssertTrue(second,
                      "Closing an already-closed task must still return true (not a failure)")

        // closedAt may be updated to a new timestamp, but the task stays closed
        XCTAssertNotNil(sut.loadedTask(id)?.closedAt)
        _ = firstClosedAt  // we don't care if it was bumped or preserved — both are valid
    }

    // MARK: - Scenario 7: Non-existent task

    func testCloseTask_nonExistent_returnsFalse() async {
        await sut.openWorkFolder(tempDir)

        let ok = await sut.closeTask(taskID: 9999)
        XCTAssertFalse(ok, "Closing a non-existent task must return false")
    }

    // MARK: - Scenario 8: Engine is stopped

    func testCloseTask_stopsEngineForTask() async {
        let id = await seedTaskWithAllDoneSteps()
        sut.engineState[id] = .running

        _ = await sut.closeTask(taskID: id)

        // After close, the engine should not be left .running
        XCTAssertNotEqual(sut.engineState[id], .running,
                          "Engine must not remain .running after the task is closed")
    }

    // MARK: - Scenario 9: Persists across reopen

    func testCloseTask_persistsAcrossReopen() async {
        let id = await seedTaskWithAllDoneSteps()
        _ = await sut.closeTask(taskID: id)

        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: id)

        XCTAssertNotNil(sut.activeTask?.closedAt,
                        "closedAt must persist across reopen")
        XCTAssertEqual(sut.activeTask?.derivedStatusFromActiveRun(), .done)
    }

    // MARK: - Scenario 10: Finalizes partial steps (non-chat)

    /// closeTask also finalizes any still-running/paused/needsInput steps
    /// to `.done`. Belt-and-suspenders: for non-chat tasks this should be
    /// rare (the task only surfaces `.needsSupervisorAcceptance` once
    /// everything is `.done` already), but if a step is somehow stranded,
    /// closeTask cleans it up.
    func testCloseTask_finalizesAnyStrandedRunningStep() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "T", supervisorTask: "x")!

        await sut.mutateTask(taskID: id) { task in
            let stranded = StepExecution(
                id: "stranded", role: .techLead, title: "TL",
                status: .running
            )
            var run = Run(id: 0, steps: [stranded],
                          roleStatuses: ["stranded": .working])
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }

        _ = await sut.closeTask(taskID: id)

        let step = sut.loadedTask(id)?.runs.last?.steps.first
        XCTAssertEqual(step?.status, .done,
                       "Stranded running step must be finalized on close")
    }
}
