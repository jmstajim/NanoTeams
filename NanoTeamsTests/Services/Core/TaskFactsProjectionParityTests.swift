import XCTest

@testable import NanoTeams

/// Pins the ONE hazard a derived projection carries: drifting from the thing it
/// mirrors.
///
/// `TaskFactsProjection` exists so the shell's `onChange` key is an `Int` compare
/// instead of a whole-index `Dictionary` rebuild evaluated on every
/// body pass (i.e. on every `mutateTask`). That trade is only sound while the
/// projection agrees with `snapshot.tasksIndex.tasks` after EVERY path that can
/// move a row — so each path is driven for real and the projection is re-derived
/// from the index and compared.
@MainActor
final class TaskFactsProjectionParityTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// Re-derives what the projection should hold, straight from the index.
    private func expected() -> (status: [Int: TaskStatus], wait: [Int: SupervisorWaitState], updatedAt: [Int: Date]) {
        let rows = sut.snapshot?.tasksIndex.tasks ?? []
        var status: [Int: TaskStatus] = [:]
        var wait: [Int: SupervisorWaitState] = [:]
        var updatedAt: [Int: Date] = [:]
        for row in rows {
            status[row.id] = row.status
            wait[row.id] = SupervisorWaitState(row)
            updatedAt[row.id] = row.updatedAt
        }
        return (status, wait, updatedAt)
    }

    /// RED: delete `updatedAtByTaskID[summary.id] = summary.updatedAt` from
    /// `TaskFactsProjection.apply` → the stamp assertion fails at the label
    /// "mutateTask (active)" (the row re-stamps, the projection keeps the stale value).
    private func assertParity(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let want = expected()
        XCTAssertEqual(sut.taskFacts.statusByTaskID, want.status,
                       "status projection drifted after \(label)", file: file, line: line)
        XCTAssertEqual(sut.taskFacts.waitStateByTaskID, want.wait,
                       "wait projection drifted after \(label)", file: file, line: line)
        XCTAssertEqual(sut.taskFacts.updatedAtByTaskID, want.updatedAt,
                       "stamp projection drifted after \(label)", file: file, line: line)
    }

    private func setRun(_ taskID: Int) async {
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "engineer", role: .softwareEngineer, title: "Work")
            ])]
        }
    }

    private func appendMessage(_ taskID: Int, _ i: Int) async {
        _ = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps[0].llmConversation.append(
                LLMMessage(role: .assistant, content: "turn \(i)"))
        }
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
        XCTAssertTrue(sut.taskFacts.updatedAtByTaskID.isEmpty)
    }

    /// `waitRevision` is the `onChange` key, `statusByTaskID` feeds the retirement
    /// seam, and `rowsRevision` keys the sidebar's row memo — so an `updatedAt`-only
    /// mutation of a row that keeps its index — the overwhelming majority — must move
    /// NONE of them. Without this the projection would be correct but useless: the shell
    /// would churn exactly as before, every write would look like a status transition,
    /// and the sidebar would rebuild its rows per message.
    ///
    /// RED: replace the guarded bump in `TaskFactsProjection.apply` with an unconditional
    /// `rowsRevision &+= 1` → the `rowsRevision` assertion fails (five appends, five bumps).
    func testUpdatedAtOnlyMutation_movesNeitherFact() async throws {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: "A", supervisorTask: "s") else {
            return XCTFail("createTask returned nil")
        }
        await sut.switchTask(to: id)
        await setRun(id)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first?.id, id,
                       "precondition: the row is at the head, so a re-stamp cannot move it")

        let statuses = sut.taskFacts.statusByTaskID
        let waitRev = sut.taskFacts.waitRevision
        let rowsRev = sut.taskFacts.rowsRevision
        let stampBefore = sut.taskFacts.updatedAtByTaskID[id]
        for i in 0..<5 {
            await appendMessage(id, i)
        }
        XCTAssertEqual(sut.taskFacts.statusByTaskID, statuses,
                       "appending a message changes no derived status — so the seam sees no "
                           + "transition and retires none of the Autovisor's attention keys")
        XCTAssertEqual(sut.taskFacts.waitRevision, waitRev,
                       "…and no durable wait fact either")
        XCTAssertEqual(sut.taskFacts.rowsRevision, rowsRev,
                       "…and the row LIST did not change: same rows, same order, only the "
                           + "stamp moved — which lives beside the memo, not inside it")
        XCTAssertNotEqual(sut.taskFacts.updatedAtByTaskID[id], stampBefore,
                          "anti-vacuum: the stamp really did move — the revision stayed put "
                              + "because the stamp is excluded, not because nothing happened")
        assertParity("five appends")
    }

    /// The move term: a BACKGROUND task re-stamped past the head changes the order the
    /// sidebar shows, and nothing but its `updatedAt` differs — so only `moved` can carry
    /// the bump. `mutateTask` re-stamps unconditionally on both branches
    /// (`NTMSOrchestrator+StateMutation.swift`) and `TasksIndex.upsert` reorders on it.
    ///
    /// RED: drop `outcome.moved ||` from `apply`'s condition → the `rowsRevision` assertion
    /// fails (b's fields are stamp-only different, so only the move term can fire).
    func testBackgroundMutationThatReordersRows_movesRowsRevision() async throws {
        await sut.openWorkFolder(tempDir)
        guard let a = await sut.createTask(title: "A", supervisorTask: "sa"),
              let b = await sut.createTask(title: "B", supervisorTask: "sb")
        else { return XCTFail("createTask returned nil") }
        await sut.switchTask(to: a)
        await setRun(b) // background; gives b a run so the later append is stamp-only
        await setRun(a) // active; a re-stamps newest and takes the head
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.map(\.id), [a, b],
                       "precondition: a is the head row, b sits behind it")

        let rowsRev = sut.taskFacts.rowsRevision
        await appendMessage(b, 0) // background path: `refreshBackgroundTaskInMemory`
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.map(\.id), [b, a],
                       "anti-vacuum: the append really re-ordered the rows")
        XCTAssertGreaterThan(sut.taskFacts.rowsRevision, rowsRev,
                             "a row that changed index changes the list the sidebar shows")
        assertParity("background reorder")
    }

    /// The field term: the head row neither moves nor is new, so a status flip on it can
    /// bump the revision only through the whole-row-minus-stamp comparison.
    ///
    /// RED: replace the `differsIgnoringStamp` term (and its `?? true`) with `false` in
    /// `apply` → the `rowsRevision` assertion fails while `statusByTaskID` still reads `.failed`.
    func testFieldChangeOnTheHeadRow_movesRowsRevision() async throws {
        await sut.openWorkFolder(tempDir)
        guard let id = await sut.createTask(title: "A", supervisorTask: "s") else {
            return XCTFail("createTask returned nil")
        }
        await sut.switchTask(to: id)
        await setRun(id)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first?.id, id, "precondition: head row")

        let rowsRev = sut.taskFacts.rowsRevision
        _ = await sut.mutateTask(taskID: id) { task in
            task.runs[0].steps[0].status = .failed
        }
        XCTAssertEqual(sut.taskFacts.statusByTaskID[id], .failed, "anti-vacuum: the status moved")
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first?.id, id, "…and the row did not move")
        XCTAssertGreaterThan(sut.taskFacts.rowsRevision, rowsRev,
                             "a rendered field changed on a row that stayed put")
        assertParity("status flip on the head row")
    }

    /// Whole-index paths bump unconditionally: `removeTask` rebuilds the snapshot through
    /// `apply(_:)` → `replaceAll`, and closing the folder goes through `clear()`.
    ///
    /// RED: delete `rowsRevision &+= 1` from `replaceAll` → the delete-step assertion fails
    /// (outside this class `SidebarRowsMemoTests` notices too: the createTask block of
    /// `testEachKeyInputInvalidates` reads 5 builds where 6 are asserted, and the miss count of
    /// `testCachedRowsEqualAFreshBuild` reads 3 where 4 is asserted); deleting it from `clear()`
    /// fails the `beforeClear` half instead, and nothing else in this class notices either edit.
    func testWholeIndexReplacementAndClear_moveRowsRevision() async throws {
        await sut.openWorkFolder(tempDir)
        guard let a = await sut.createTask(title: "A", supervisorTask: "sa"),
              let b = await sut.createTask(title: "B", supervisorTask: "sb")
        else { return XCTFail("createTask returned nil") }
        await sut.switchTask(to: a)

        let beforeDelete = sut.taskFacts.rowsRevision
        await sut.removeTask(b)
        XCTAssertNil(sut.taskFacts.updatedAtByTaskID[b], "anti-vacuum: b's row is gone")
        XCTAssertGreaterThan(sut.taskFacts.rowsRevision, beforeDelete,
                             "a whole-index replacement is a new list")
        assertParity("deleteTask")

        let beforeClear = sut.taskFacts.rowsRevision
        sut.discardWorkFolderState()
        XCTAssertTrue(sut.taskFacts.updatedAtByTaskID.isEmpty)
        XCTAssertGreaterThan(sut.taskFacts.rowsRevision, beforeClear,
                             "an emptied list is a new list too")
    }

    /// The two facts are deliberately separate: merging them would make a status
    /// change sweep the seen set, and a wait flip the only thing the shell reacts to.
    func testStatusAndWaitFacts_moveIndependently() async throws {
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
        _ = await sut.mutateTask(taskID: id) { task in
            task.runs[0].steps[0].status = .failed
        }
        XCTAssertEqual(sut.taskFacts.statusByTaskID[id], .failed,
                       "a `.failed` step must move the status fact")
        XCTAssertEqual(sut.taskFacts.waitRevision, waitRev,
                       "…and must NOT move the wait revision — failing is not waiting")
    }
}
