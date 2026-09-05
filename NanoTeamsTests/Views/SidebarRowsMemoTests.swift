import XCTest

@testable import NanoTeams

/// The sidebar's row memo, driven through the REAL write side.
///
/// `SidebarView` is mounted for the app's lifetime and reads `store.snapshot`, so its body
/// re-runs on every `mutateTask` — every LLM message. Until 2026-09-03 each pass rebuilt the
/// whole `[SidebarTaskItem]` array from the index (Θ(T) filter + map, then the row filter
/// and four pill counts over it). The memo in `TaskManagementState.sidebarRows` is a
/// condition AROUND that build, so a test that merely calls the builder proves nothing
/// (CLAUDE.md #57): these tests pin the WIRING with a work counter placed inside the builder
/// (`SidebarRowsBuildProbe`, CLAUDE.md #62) — builds per N head-task appends == 1 — and the
/// output with `SidebarTaskItem: Equatable` against a fresh build. Work counters only, never
/// wall-clock (`Ratchet/WallClockPerformancePinTests`). The premise the memo rests on — the
/// index walk has exactly one app-target caller, the miss closure — is a source pin and lives
/// where source pins live: `Ratchet/SidebarRowsMemoSourcePinTests`.
///
/// Every scenario goes through `openWorkFolder` → `createTask` → `mutateTask`, i.e. through
/// the two write-side paths a body pass keys on: `TasksIndex.upsert` →
/// `TaskFactsProjection.apply(_:outcome:)` → `rowsRevision` for every `mutateTask`, and
/// `apply(_:)` → `replaceAll` for `openWorkFolder` / `createTask` / `switchTask`. A fixture
/// that poked the projection directly would pin the memo against a revision nobody produces. A fixture failure is an `XCTFail`, never
/// an `XCTSkip`: a skipped test exits 0 and reads green.
@MainActor
final class SidebarRowsMemoTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// Class-level, built in `setUp` — never a local (Testing Conventions: a `@MainActor`
    /// class constructed inside a test body aborts on the CI runner).
    var taskState: TaskManagementState!

    override func setUp() async throws {
        try await super.setUp()
        taskState = TaskManagementState()
    }

    override func tearDown() async throws {
        taskState = nil
        try await super.tearDown()
    }

    // MARK: - Fixture

    /// What `SidebarView.body` asks on every pass.
    private func rows() -> [SidebarTaskItem] {
        taskState.sidebarRows(store: sut, engineState: sut.engineState)
    }

    /// A fresh, un-memoised build of the same pipeline — the oracle for the cached array.
    private func freshBuild() -> [SidebarTaskItem] {
        SidebarViewLogic.buildSidebarTaskItems(
            summaries: sut.taskSummaries(filter: .all),
            seenSupervisorInputTaskIDs: taskState.seenSupervisorInputTaskIDs,
            bashApprovalTaskIDs: Set(sut.bashApprovalRequests.keys.map(\.taskID)),
            engineStates: sut.engineState.taskEngineStates,
            initializingTaskIDs: sut.engineState.initializingRunTaskIDs)
    }

    /// Both helpers assert `mutateTask`'s `Bool`: a task that is not in `loadedTasks` makes
    /// it return `false` having done nothing (invariant #7), which would leave every count
    /// below trivially satisfied by a fixture that never wrote.
    private func setRun(_ taskID: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "engineer", role: .softwareEngineer, title: "Work")
            ])]
        }
        XCTAssertTrue(ok, "setRun(\(taskID)) did not persist — is the task loaded?", file: file, line: line)
    }

    /// The hot path: an `updatedAt`-only tick of one row.
    private func appendMessage(_ taskID: Int, _ i: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await sut.mutateTask(taskID: taskID) { task in
            task.runs[0].steps[0].llmConversation.append(
                LLMMessage(role: .assistant, content: "turn \(i)"))
        }
        XCTAssertTrue(ok, "appendMessage(\(taskID)) did not persist — is the task loaded?", file: file, line: line)
    }

    /// Creates `title` as the ACTIVE task and hands focus back to `previous`, so the new
    /// task stays in `loadedTasks`. A task created with `makeActive: false` is never loaded,
    /// and a background `mutateTask` on it returns `false` having done nothing (and surfaces
    /// `lastErrorMessage`, invariant #7) — which is why `setRun` / `appendMessage` assert the
    /// `Bool`.
    private func createLoadedTask(_ title: String, thenSwitchBackTo previous: Int) async -> Int? {
        guard let id = await sut.createTask(title: title, supervisorTask: "s-\(title)") else { return nil }
        await sut.switchTask(to: previous)
        return id
    }

    /// Opens the folder, creates one active task with a run at the head, and zeroes the probe.
    /// `nil` only after an `XCTFail` — the caller returns and the test is red, not skipped.
    private func openWithOneHeadTask() async -> Int? {
        await sut.openWorkFolder(tempDir)
        guard let a = await sut.createTask(title: "A", supervisorTask: "sa") else {
            XCTFail("createTask returned nil — fixture, not the memo")
            return nil
        }
        await setRun(a)
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first?.id, a, "precondition: a is the head row")
        SidebarRowsBuildProbe.reset()
        return a
    }

    // MARK: - The bound

    /// Builds per N head-task mutations == 1. The first ask is a miss and MUST build (the
    /// anti-vacuum half: `builds() == 1`, and the rows are the index's rows); twenty message
    /// appends on the head task then re-stamp a row that stays at index 0, and the memo
    /// must not notice.
    ///
    /// RED: in `TaskManagementState.sidebarRows` replace `rowsMemo.items(for: key) { … }`
    /// with the bare build → `builds()` reads 21 at the end. The same assertion also bites
    /// on the projection mutation (unconditional `rowsRevision &+= 1` in `apply`) and on the
    /// upsert mutation (`moved: true` in the move branch), each of which makes every append
    /// look like a new list.
    func testTwentyMessageAppendsOnTheHeadTask_buildRowsOnce() async {
        guard let a = await openWithOneHeadTask() else { return }

        let first = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), 1,
                       "anti-vacuum: the first ask is a miss and must run the builder — 0 means "
                           + "the probe is not wired and every bound below is vacuous")
        XCTAssertEqual(first.map(\.id), sut.taskSummaries(filter: .all).map(\.id),
                       "anti-vacuum: the rows are the index's rows")
        XCTAssertEqual(first.map(\.id), [a])

        let stampBefore = sut.taskFacts.updatedAtByTaskID[a]
        for i in 0..<20 {
            await appendMessage(a, i)
            _ = rows()
        }
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), 1,
                       "20 appends on the head task must not rebuild the sidebar rows once")
        XCTAssertNotEqual(sut.taskFacts.updatedAtByTaskID[a], stampBefore,
                          "anti-vacuum: the stamp the row renders DID move — it lives beside "
                              + "the memo (`updatedAtByTaskID`), not inside the cached item")
        XCTAssertEqual(rows(), freshBuild(), "a hit equals a fresh build")
    }

    // MARK: - Every key input invalidates

    /// One build per perturbed input, and the returned rows reflect the change: engine
    /// state, the seen set, a status flip on the head row, a background reorder, a new task,
    /// a held `bash` command, a run-start claim, the manager id. Exact counts, so a key that
    /// over-fires (two builds for one change) is caught too. The last three use counts
    /// RELATIVE to the build before them, so a key blind to one input reds that input's
    /// assertions and nothing downstream.
    ///
    /// RED: in `TaskManagementState.sidebarRows` build the key with `engineStates: [:]` and
    /// let the miss closure read `engineState.taskEngineStates` directly → the key compares
    /// equal after `engineState[a] = .running`, no rebuild, `isEngineRunning` stays false and
    /// `builds()` reads 1 where 2 is asserted. The same shape against `bashApprovalTaskIDs`
    /// / `initializingTaskIDs` reds the held-command / run-start-claim blocks below.
    func testEachKeyInputInvalidates() async {
        guard let a = await openWithOneHeadTask() else { return }
        _ = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), 1)

        // Engine state (view-side input, not in the index at all).
        sut.engineState[a] = .running
        let afterEngine = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), 2, "an engine flip is a new key")
        XCTAssertEqual(afterEngine.first?.isEngineRunning, true)
        _ = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), 2, "…and asking again is a hit")

        // A wait flip on the head row (field change → rowsRevision), then the seen set.
        _ = await sut.mutateTask(taskID: a) { task in
            task.runs[0].steps[0].needsSupervisorInput = true
            task.runs[0].steps[0].status = .needsSupervisorInput
        }
        let waiting = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), 3, "a non-stamp field changed on the head row")
        XCTAssertEqual(sut.taskSummaries(filter: .all).first?.isChatMode, true,
                       "fixture: the default team is chat-mode, so the wait flag lights the dot")
        XCTAssertEqual(waiting.first?.hasUnreadInput, true)

        taskState.markSupervisorInputSeen(taskID: a)
        let seen = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), 4, "the seen set is a key input")
        XCTAssertEqual(seen.first?.hasUnreadInput, false, "seen ⇒ the dot goes out")

        // Status flip on the head row: no move, no new row — only the field term can fire.
        _ = await sut.mutateTask(taskID: a) { task in
            task.runs[0].steps[0].status = .failed
        }
        let failed = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), 5)
        XCTAssertEqual(failed.first?.status, .failed)

        // A new task: `createTask` → `apply` → `replaceAll` bumps unconditionally (and so
        // does the `switchTask` back to a — still ONE build, because nothing asked between).
        guard let b = await createLoadedTask("B", thenSwitchBackTo: a) else {
            return XCTFail("createTask returned nil")
        }
        let created = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), 6, "a new row is a new list")
        XCTAssertEqual(created.map(\.id), [b, a], "b is newest, so it leads")

        // Background reorder: a re-stamps to the head (active path), then b's stamp-only
        // append (background path) carries b past it — the `moved` term alone.
        await setRun(b)
        _ = rows()
        await appendMessage(a, 0)
        let aLeads = rows()
        XCTAssertEqual(aLeads.map(\.id), [a, b], "precondition: a is back at the head")
        let before = SidebarRowsBuildProbe.builds()
        await appendMessage(b, 0)
        let bLeads = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), before + 1, "a row that changed index is a new list")
        XCTAssertEqual(bLeads.map(\.id), [b, a])
        _ = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), before + 1, "…and asking again is a hit")

        // A held `bash` command (view-side, not in the index): the terminal badge on a's row
        // lights while the command awaits Allow/Deny and goes out when the hold ends.
        let bashKey = TaskStepKey(taskID: a, stepID: "engineer")
        let beforeBash = SidebarRowsBuildProbe.builds()
        sut.bashApprovalRequests[bashKey] = BashApprovalRequest(
            taskID: a, stepID: "engineer", commandKey: "ls", command: "ls",
            workingDirectory: nil, offerAlways: false, createdAt: MonotonicClock.shared.now())
        let held = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), beforeBash + 1, "a held bash command is a new key")
        XCTAssertEqual(held.first { $0.id == a }?.hasPendingBashApproval, true)
        sut.bashApprovalRequests[bashKey] = nil
        let released = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), beforeBash + 2, "…and releasing it is another")
        XCTAssertEqual(released.first { $0.id == a }?.hasPendingBashApproval, false)

        // A run-start claim (`beginRunStart`, before `engine.start()` is reached) drives the
        // row's spinner; ending it puts the spinner out.
        let beforeInit = SidebarRowsBuildProbe.builds()
        XCTAssertTrue(sut.engineState.beginRunStart(a), "fixture: a had no run start claimed")
        let initializing = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), beforeInit + 1, "a run-start claim is a new key")
        XCTAssertEqual(initializing.first { $0.id == a }?.isInitializing, true)
        sut.engineState.endRunStart(a)
        let started = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), beforeInit + 2, "…and ending it is another")
        XCTAssertEqual(started.first { $0.id == a }?.isInitializing, false)

        // The manager id — `TaskService.taskSummaries`' second input: naming b hides its row,
        // clearing it brings the row back. Every write to `autovisorTaskID` goes through
        // `mutateWorkFolder` → `apply` → `replaceAll`, which bumps `rowsRevision` as well, so
        // this proves the ROWS follow the id; it cannot tell the key's `autovisorTaskID` term
        // apart from the revision (the pure key test in `SidebarViewLogicTests` covers the term).
        let beforeManager = SidebarRowsBuildProbe.builds()
        await sut.mutateWorkFolder { $0.state.autovisorTaskID = b }
        let hidden = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), beforeManager + 1, "naming the manager is a new list")
        XCTAssertEqual(hidden.map(\.id), [a], "the manager row is hidden from the task list")
        await sut.mutateWorkFolder { $0.state.autovisorTaskID = nil }
        let shown = rows()
        XCTAssertEqual(SidebarRowsBuildProbe.builds(), beforeManager + 2, "…and clearing it is another")
        XCTAssertEqual(Set(shown.map(\.id)), [a, b], "…with b's row back")
    }

    // MARK: - Output equality

    /// After a mix of hits and misses the cached array is exactly what a fresh build of the
    /// same pipeline returns — the invariant the whole memo rests on: the cache IS a previous
    /// output, and the key covers every input.
    ///
    /// RED: in `RowsMemo.items(for:build:)` hand back the PREVIOUS array on a miss
    /// (`defer { cachedItems = built }; return cachedItems`) → the one-step-stale array is
    /// returned (empty, `[a]`, `[b, a]`, then `[a, b]` with b still not running) and
    /// `XCTAssertEqual(cached, freshBuild())` fails on b's `isEngineRunning`.
    func testCachedRowsEqualAFreshBuild() async {
        guard let a = await openWithOneHeadTask() else { return }
        _ = rows() // miss
        _ = rows() // hit
        guard let b = await createLoadedTask("B", thenSwitchBackTo: a) else {
            return XCTFail("createTask returned nil")
        }
        await setRun(b)
        _ = rows() // miss (new row: createTask → replaceAll; `setRun(b)` moves no summary field)
        await appendMessage(a, 0) // a to the head — moved
        _ = rows() // miss
        await appendMessage(a, 1) // stamp-only on the head — hit
        // The last perturbation must change a RENDERED field, or a stale array handed back
        // on the miss would equal the fresh build by coincidence and this test would say
        // nothing: `.running` flips `isEngineRunning` on b's row.
        sut.engineState[b] = .running
        taskState.markSupervisorInputSeen(taskID: b)

        let cached = rows()
        let missesBeforeOracle = SidebarRowsBuildProbe.builds() // read BEFORE the oracle — it builds too
        XCTAssertEqual(cached, freshBuild())
        XCTAssertEqual(cached.map(\.id), [a, b], "anti-vacuum: two rows, in index order")
        XCTAssertEqual(cached.last?.isEngineRunning, true, "anti-vacuum: the final miss changed a rendered field")
        XCTAssertEqual(missesBeforeOracle, 4,
                       "anti-vacuum: the mix really missed — first ask, new row, a moved, engine + seen")
    }
}
