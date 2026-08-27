import XCTest

@testable import NanoTeams

/// Pins the ONE hazard a derived projection carries: drifting from the thing it
/// mirrors.
///
/// `TaskFactsProjection` exists so `MainLayoutView`'s two `onChange` keys are
/// `Int` compares instead of whole-index `Dictionary` rebuilds evaluated on every
/// body pass (i.e. on every `mutateTask`). That trade is only sound while the
/// projection agrees with `snapshot.tasksIndex.tasks` after EVERY path that can
/// move a row — so each path is driven for real and the projection is re-derived
/// from the index and compared.
@MainActor
final class TaskFactsProjectionParityTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// Re-derives what the projection should hold, straight from the index.
    private func expected() -> (status: [Int: TaskStatus], wait: [Int: SupervisorWaitState]) {
        let rows = sut.snapshot?.tasksIndex.tasks ?? []
        var status: [Int: TaskStatus] = [:]
        var wait: [Int: SupervisorWaitState] = [:]
        for row in rows {
            status[row.id] = row.status
            wait[row.id] = SupervisorWaitState(row)
        }
        return (status, wait)
    }

    private func assertParity(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let want = expected()
        XCTAssertEqual(sut.taskFacts.statusByTaskID, want.status,
                       "status projection drifted after \(label)", file: file, line: line)
        XCTAssertEqual(sut.taskFacts.waitStateByTaskID, want.wait,
                       "wait projection drifted after \(label)", file: file, line: line)
    }

    func testParity_acrossOpenCreateMutateDeleteAndClose() async throws {
        await sut.openWorkFolder(tempDir)
        assertParity("openWorkFolder")

        guard let a = await sut.createTask(title: "A", supervisorTask: "sa"),
              let b = await sut.createTask(title: "B", supervisorTask: "sb")
        else { return XCTFail("createTask returned nil") }
        assertParity("createTask x2")
        XCTAssertEqual(sut.taskFacts.statusByTaskID.count, 2,
                       "anti-vacuum: an always-empty projection would satisfy parity trivially")

        // Active-task path: `applyTaskUpdate`.
        await sut.switchTask(to: a)
        _ = await sut.mutateTask(taskID: a) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "engineer", role: .softwareEngineer, title: "Work")
            ])]
        }
        assertParity("mutateTask (active)")

        // Background path: `refreshBackgroundTaskInMemory`.
        _ = await sut.mutateTask(taskID: b) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "engineer", role: .softwareEngineer, title: "Work")
            ])]
        }
        assertParity("mutateTask (background)")

        // The wait fact specifically — it must move, not just stay parallel.
        let waitBefore = sut.taskFacts.waitRevision
        _ = await sut.mutateTask(taskID: a) { task in
            task.runs[0].steps[0].needsSupervisorInput = true
            task.runs[0].steps[0].status = .needsSupervisorInput
        }
        assertParity("mutateTask (raises the wait flag)")
        XCTAssertEqual(sut.taskFacts.waitStateByTaskID[a], .waiting)
        XCTAssertGreaterThan(sut.taskFacts.waitRevision, waitBefore,
                             "a wait flip must move the wait revision, or the seen-set "
                                 + "sweep never runs")

        // Delete rebuilds the snapshot wholesale.
        await sut.removeTask(b)
        assertParity("deleteTask")
        XCTAssertNil(sut.taskFacts.statusByTaskID[b])

        sut.discardWorkFolderState()
        XCTAssertTrue(sut.taskFacts.statusByTaskID.isEmpty,
                      "folder-scoped ids must not survive the folder")
        XCTAssertTrue(sut.taskFacts.waitStateByTaskID.isEmpty)
    }

    /// The revisions are the `onChange` keys, so an `updatedAt`-only mutation —
    /// the overwhelming majority — must move NEITHER. Without this the projection
    /// would be correct but useless: the shell would churn exactly as before.
    func testUpdatedAtOnlyMutation_movesNeitherRevision() async throws {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: "A", supervisorTask: "s") else {
            return XCTFail("createTask returned nil")
        }
        await sut.switchTask(to: id)
        _ = await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "engineer", role: .softwareEngineer, title: "Work")
            ])]
        }

        let statusRev = sut.taskFacts.statusRevision
        let waitRev = sut.taskFacts.waitRevision
        for i in 0..<5 {
            _ = await sut.mutateTask(taskID: id) { task in
                task.runs[0].steps[0].llmConversation.append(
                    LLMMessage(role: .assistant, content: "turn \(i)"))
            }
        }
        XCTAssertEqual(sut.taskFacts.statusRevision, statusRev,
                       "appending a message changes no derived status — the Autovisor "
                           + "wake must not fire for it")
        XCTAssertEqual(sut.taskFacts.waitRevision, waitRev,
                       "…and no durable wait fact either")
        assertParity("five appends")
    }

    /// The two revisions are deliberately separate: merging them would make a
    /// status change sweep the seen set, and a wait flip the only Autovisor wake.
    func testStatusAndWaitRevisions_moveIndependently() async throws {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: "A", supervisorTask: "s") else {
            return XCTFail("createTask returned nil")
        }
        await sut.switchTask(to: id)
        _ = await sut.mutateTask(taskID: id) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "engineer", role: .softwareEngineer, title: "Work")
            ])]
        }

        let waitRev = sut.taskFacts.waitRevision
        let statusRev = sut.taskFacts.statusRevision
        _ = await sut.mutateTask(taskID: id) { task in
            task.runs[0].steps[0].status = .failed
        }
        XCTAssertGreaterThan(sut.taskFacts.statusRevision, statusRev,
                             "a `.failed` step must move the status revision")
        XCTAssertEqual(sut.taskFacts.waitRevision, waitRev,
                       "…and must NOT move the wait revision — failing is not waiting")
    }
}
