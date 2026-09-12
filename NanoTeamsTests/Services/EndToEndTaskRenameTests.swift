import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for the **task rename workflow** — Supervisor
/// right-clicks a task in the sidebar → "Rename..." → edits the title →
/// confirms/cancels.
///
/// This covers the full `TaskManagementState.requestRename` +
/// `takePendingRename` / `cancelRename` contract as it integrates with the
/// orchestrator's `updateTaskTitle`. Every confirm below is spelled the way the
/// alert's button spells it — snapshot synchronously, then await the mutation —
/// so the suite exercises production's composition rather than a shortcut past it.
///
/// Pinned behavior:
/// 1. Request rename seeds `renameText` with the current title.
/// 2. Cancel clears rename state without mutating the task.
/// 3. Confirm with new text updates the task title AND persists to disk.
/// 4. Confirm with empty text is refused (no mutation, state cleared).
/// 5. Rename only affects the target task — siblings untouched.
/// 6. Rename persists across app restart.
/// 7. Rename of the active task is reflected in the in-memory active task.
/// 8. Tasks index entry's title stays in sync with `task.json`.
@MainActor
final class EndToEndTaskRenameTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var tms: TaskManagementState!

    override func setUp() async throws {
        try await super.setUp()
        tms = TaskManagementState()
    }

    override func tearDown() async throws {
        tms = nil
        try await super.tearDown()
    }

    // MARK: - Scenario 1: Request seeds rename state

    func testRequestRename_seedsTextAndTargetID() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Original", supervisorTask: "x")!

        tms.requestRename(taskID: id, currentName: "Original")

        XCTAssertEqual(tms.taskToRename, id)
        XCTAssertEqual(tms.renameText, "Original")
    }

    // MARK: - Scenario 2: Cancel clears state

    func testCancelRename_clearsStateWithoutMutation() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Original", supervisorTask: "x")!
        tms.requestRename(taskID: id, currentName: "Original")
        tms.renameText = "Edited but not confirmed"

        tms.cancelRename()

        XCTAssertNil(tms.taskToRename)
        XCTAssertEqual(tms.renameText, "")

        // Underlying task must be unchanged
        await sut.switchTask(to: id)
        XCTAssertEqual(sut.activeTask?.title, "Original",
                       "Cancel must not mutate the task title")
    }

    // MARK: - Scenario 3: Confirm with new text updates title

    func testConfirmRename_withNewText_updatesTitleAndPersists() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Original", supervisorTask: "x")!

        tms.requestRename(taskID: id, currentName: "Original")
        tms.renameText = "Renamed Title"

        if let pending = tms.takePendingRename() {
            await sut.updateTaskTitle(id: pending.taskID, title: pending.title)
        }

        XCTAssertNil(tms.taskToRename, "State cleared after confirm")
        XCTAssertEqual(tms.renameText, "")

        await sut.switchTask(to: id)
        XCTAssertEqual(sut.activeTask?.title, "Renamed Title",
                       "Task title reflects the confirmed rename")
    }

    /// Pin: the PRODUCTION ordering, which no other test in this file reproduces.
    ///
    /// `SidebarView`'s rename alert binds `isPresented` to a getter over the
    /// payload itself (`taskToRename != nil`), so its setter calls
    /// `cancelRename()` on every dismissal — the confirm dismissal included.
    /// The button action and that setter both run inside ONE synchronous
    /// main-thread turn; a `Task { }` body cannot start until that turn's stack
    /// unwinds. So any read of `taskToRename` / `renameText` performed after an
    /// actor hop sees state the dismissal has already cleared, and the rename
    /// silently becomes a no-op indistinguishable from Cancel.
    ///
    /// Broken from `9834e2d8` ("God Object Refactoring", 2026-03-06), which
    /// moved the `if let id = taskToRename` out of the button action and into
    /// the confirm method — i.e. behind the hop. Nothing in the suite could see it:
    /// no test constructs `SidebarView`, so the binding's setter — the only
    /// production caller of `cancelRename()` between request and confirm — is
    /// unreachable from here. This test stands in for it.
    func testConfirmRename_survivesAlertDismissalClearingState() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Original", supervisorTask: "x")!

        tms.requestRename(taskID: id, currentName: "Original")
        tms.renameText = "Renamed"

        guard let pending = tms.takePendingRename() else {
            return XCTFail("Confirm must snapshot the pending rename synchronously")
        }
        // The alert's `isPresented` setter, firing before any enqueued work runs.
        tms.cancelRename()

        await sut.updateTaskTitle(id: pending.taskID, title: pending.title)

        await sut.switchTask(to: id)
        XCTAssertEqual(sut.activeTask?.title, "Renamed",
                       "The rename must survive the alert's dismissal clearing the payload")
    }

    func testConfirmRename_persistsToDisk_surviveRestart() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Original", supervisorTask: "x")!

        tms.requestRename(taskID: id, currentName: "Original")
        tms.renameText = "Persists"
        if let pending = tms.takePendingRename() {
            await sut.updateTaskTitle(id: pending.taskID, title: pending.title)
        }

        // Simulate app restart
        sut = TestOrchestrator.make()
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: id)

        XCTAssertEqual(sut.activeTask?.title, "Persists",
                       "Renamed title survives orchestrator recreation")
    }

    // MARK: - Scenario 4: Confirm with empty text is refused

    func testConfirmRename_emptyText_refused_titleUnchanged() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "KeepMe", supervisorTask: "x")!

        tms.requestRename(taskID: id, currentName: "KeepMe")
        tms.renameText = ""

        if let pending = tms.takePendingRename() {
            await sut.updateTaskTitle(id: pending.taskID, title: pending.title)
        }

        XCTAssertNil(tms.taskToRename, "State cleared (via cancelRename fallback)")

        await sut.switchTask(to: id)
        XCTAssertEqual(sut.activeTask?.title, "KeepMe",
                       "Empty rename must not clobber the existing title")
    }

    // MARK: - Corner cases of the synchronous take

    /// Blankness is judged on the TRIMMED text: a title of nothing but spaces would
    /// render as an empty sidebar row (`SidebarTaskRow` draws a bare `Text`, and the
    /// app has no "Untitled" fallback), and neither sibling write path can produce
    /// one — creation derives a title and refuses an empty result, the Autovisor's
    /// `rename` verb trims and rejects. Rename must not be able to produce what the
    /// others cannot.
    func testTakePendingRename_whitespaceOnly_refused_titleUnchanged() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "KeepMe", supervisorTask: "x")!

        tms.requestRename(taskID: id, currentName: "KeepMe")
        tms.renameText = "   \n  "

        XCTAssertNil(tms.takePendingRename(),
                     "A title that is blank once trimmed is not a rename the user meant")
        XCTAssertNil(tms.taskToRename, "The refusal still dismisses the dialog")
        XCTAssertEqual(tms.renameText, "")

        await sut.switchTask(to: id)
        XCTAssertEqual(sut.activeTask?.title, "KeepMe")
    }

    /// The take CONSUMES the payload, so a second call yields nothing — which is
    /// what makes the alert's own `set(false)` → `cancelRename()` a harmless no-op
    /// after a confirm.
    func testTakePendingRename_isIdempotentAfterConsuming() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Original", supervisorTask: "x")!

        tms.requestRename(taskID: id, currentName: "Original")
        tms.renameText = "Renamed"

        XCTAssertEqual(tms.takePendingRename(),
                       TaskManagementState.PendingRename(taskID: id, title: "Renamed"))
        XCTAssertNil(tms.takePendingRename(), "The payload is consumed, not merely read")
    }

    /// Renaming to the SAME string still persists and still restamps: `MonotonicClock`
    /// is strictly increasing, so `TasksIndex.upsert` reports `moved` and the row
    /// travels to slot 0. Pins that a no-change rename is not silently dropped.
    func testTakePendingRename_sameTitle_stillPersistsAndRestamps() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "x")!
        _ = await sut.createTask(title: "B", supervisorTask: "y")!
        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first?.title, "B",
                       "Setup: the newest task heads the index")

        tms.requestRename(taskID: idA, currentName: "A")
        tms.renameText = "A"
        if let pending = tms.takePendingRename() {
            await sut.updateTaskTitle(id: pending.taskID, title: pending.title)
        }

        XCTAssertEqual(sut.snapshot?.tasksIndex.tasks.first?.id, idA,
                       "The restamp moves the renamed row to the head even with an identical title")
    }

    // MARK: - Scenario 5: Siblings untouched

    func testConfirmRename_onlyAffectsTargetTask() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A original", supervisorTask: "x")!
        let idB = await sut.createTask(title: "B original", supervisorTask: "y")!

        tms.requestRename(taskID: idA, currentName: "A original")
        tms.renameText = "A renamed"
        if let pending = tms.takePendingRename() {
            await sut.updateTaskTitle(id: pending.taskID, title: pending.title)
        }

        await sut.switchTask(to: idB)
        XCTAssertEqual(sut.activeTask?.title, "B original",
                       "Renaming Task A must not touch Task B")

        await sut.switchTask(to: idA)
        XCTAssertEqual(sut.activeTask?.title, "A renamed")
    }

    // MARK: - Scenario 6: Rename active task reflects in-memory + index

    func testConfirmRename_activeTask_indexStaysConsistent() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Original", supervisorTask: "x")!

        tms.requestRename(taskID: id, currentName: "Original")
        tms.renameText = "Fresh Name"
        if let pending = tms.takePendingRename() {
            await sut.updateTaskTitle(id: pending.taskID, title: pending.title)
        }

        let summary = sut.snapshot?.tasksIndex.tasks.first { $0.id == id }
        XCTAssertEqual(summary?.title, "Fresh Name",
                       "Tasks index must reflect the renamed title (used by sidebar)")
    }

    // MARK: - Scenario 7: Confirm with trailing whitespace keeps exact string

    /// The rename path does NOT trim — whatever the user typed is what
    /// gets stored. (Trimming is a separate UX concern that happens at
    /// input validation in the sheet.)
    func testConfirmRename_preservesExactTextIncludingTrailingSpaces() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Original", supervisorTask: "x")!

        tms.requestRename(taskID: id, currentName: "Original")
        tms.renameText = "With trailing space "
        if let pending = tms.takePendingRename() {
            await sut.updateTaskTitle(id: pending.taskID, title: pending.title)
        }

        await sut.switchTask(to: id)
        XCTAssertEqual(sut.activeTask?.title, "With trailing space ",
                       "Rename must not transparently trim whitespace")
    }

    // MARK: - Scenario 8: Request + re-request on another task updates target

    func testRequestRename_secondRequest_updatesTargetAndText() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A", supervisorTask: "x")!
        let idB = await sut.createTask(title: "B", supervisorTask: "y")!

        tms.requestRename(taskID: idA, currentName: "A")
        XCTAssertEqual(tms.taskToRename, idA)

        tms.requestRename(taskID: idB, currentName: "B")
        XCTAssertEqual(tms.taskToRename, idB, "Second request overrides target")
        XCTAssertEqual(tms.renameText, "B", "Seed text updates to new task's title")
    }

    // MARK: - Scenario 9: Rename of evicted background task (post-restart state)

    /// Pin: sidebar → right-click → "Rename..." on a task that hasn't been
    /// re-loaded since app restart. After `openWorkFolder`, only the active
    /// task is hydrated; every other task lives on disk only. Pre-fix
    /// `updateTaskTitle` called `mutateTask` directly, whose background branch
    /// requires the task already be in memory and otherwise sets
    /// `lastErrorMessage = "Cannot persist task N: task not loaded."` (same
    /// root cause as the user-reported "Close Chat" bug, latent here because
    /// existing rename tests create both tasks in one session — `apply()`
    /// preserves the previously-active task in `loadedTasks`).
    func testConfirmRename_evictedBackgroundTask_persistsToDisk() async throws {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "Original", supervisorTask: "x")!
        let idB = await sut.createTask(title: "B", supervisorTask: "y")!
        XCTAssertEqual(sut.activeTaskID, idB)

        // Evict A to simulate post-restart state where only the active task
        // was hydrated by `openWorkFolder`.
        sut.evictLoadedTask(idA)
        XCTAssertNil(sut.loadedTask(idA),
                     "Setup: task A must be evicted to reproduce the post-restart state")

        sut.lastErrorMessage = nil

        tms.requestRename(taskID: idA, currentName: "Original")
        tms.renameText = "Renamed"
        if let pending = tms.takePendingRename() {
            await sut.updateTaskTitle(id: pending.taskID, title: pending.title)
        }

        XCTAssertNil(sut.lastErrorMessage,
                     "No error banner should surface — pre-fix this was 'Cannot persist task N: task not loaded.'")

        // Verify the rename actually persisted to disk (not just in-memory).
        let reloaded = try sut.repository.loadTask(at: tempDir, taskID: idA)
        XCTAssertEqual(reloaded.title, "Renamed",
                       "Renamed title must be persisted on disk for the cold task")
    }

    /// Pin: cold-task rename of a non-chat task with a `.needsAcceptance` role
    /// must NOT close-finalize. `closeTask` flips `.needsAcceptance` to `.done`
    /// as implicit acceptance ([CloseTaskTests.testCloseTask_finalizesNeedsAcceptanceRoleStatuses_toDone]);
    /// rename must do nothing of the sort. Guards against a future change that
    /// accidentally borrows `closeTask`'s finalization logic into
    /// `updateTaskTitle`. Mirrors the "non-chat" branch of the closeTask matrix
    /// on the cold-task variant.
    ///
    /// Caveat: this test does NOT pin step/role state byte-for-byte because
    /// `ensureTaskLoaded` legitimately runs `StatusRecoveryService.recoverStaleStatuses`
    /// (which can flip stale `.running`/`.needsSupervisorInput` steps to
    /// `.paused` and `.working` roles to `.idle` for app-restart recovery).
    /// We pin the close-specific invariants only: `closedAt` stays nil, and a
    /// `.needsAcceptance` role does NOT get auto-promoted to `.done`.
    func testConfirmRename_evictedNonChatTaskWithCompletedRun_doesNotCloseFinalize() async throws {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "Original", supervisorTask: "Build")!

        await sut.mutateTask(taskID: idA) { task in
            task.setStoredChatMode(false)
            task.runs = [Run(
                id: 0,
                steps: [StepExecution(
                    id: "engineer",
                    role: .softwareEngineer,
                    title: "Build",
                    status: .done,
                    completedAt: MonotonicClock.shared.now()
                )],
                roleStatuses: ["engineer": .needsAcceptance]
            )]
        }

        let idB = await sut.createTask(title: "B", supervisorTask: "y")!
        XCTAssertEqual(sut.activeTaskID, idB)
        sut.evictLoadedTask(idA)
        sut.lastErrorMessage = nil

        tms.requestRename(taskID: idA, currentName: "Original")
        tms.renameText = "Renamed"
        if let pending = tms.takePendingRename() {
            await sut.updateTaskTitle(id: pending.taskID, title: pending.title)
        }

        XCTAssertNil(sut.lastErrorMessage)
        let reloaded = try sut.repository.loadTask(at: tempDir, taskID: idA)
        XCTAssertEqual(reloaded.title, "Renamed")
        XCTAssertNil(reloaded.closedAt,
                     "Rename must not set closedAt — that's closeTask's job")
        XCTAssertEqual(reloaded.runs.last?.roleStatuses["engineer"], .needsAcceptance,
                       "Rename must not auto-promote .needsAcceptance to .done — that's closeTask's implicit-acceptance behavior")
    }

    /// Pin: cold-task rename of a chat task with a mid-flight `.running` step
    /// must not close-finalize. `closeTask` flips `.running` steps to `.done`
    /// and sets `closedAt`; rename must do neither. Same close-finalization-
    /// avoidance invariant as the non-chat variant, on the chat code path.
    ///
    /// Caveat: same as the non-chat sibling — `ensureTaskLoaded` runs
    /// `StatusRecoveryService.recoverStaleStatuses` for app-restart recovery,
    /// which IS allowed to flip a stale `.running` step to `.paused`. The
    /// close-specific marker we pin is `.done` (close's terminal finalization),
    /// not `.running` (recovery's intermediate state).
    func testConfirmRename_evictedChatTaskWithRunningStep_doesNotCloseFinalize() async throws {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "Chat A", supervisorTask: "Help")!

        await sut.mutateTask(taskID: idA) { task in
            task.setStoredChatMode(true)
            task.runs = [Run(id: 0, steps: [
                StepExecution(id: "assistant", role: .custom(id: "assistant"), title: "Chat", status: .running),
            ], roleStatuses: ["assistant": .working])]
        }

        let idB = await sut.createTask(title: "B", supervisorTask: "y")!
        XCTAssertEqual(sut.activeTaskID, idB)
        sut.evictLoadedTask(idA)
        sut.lastErrorMessage = nil

        tms.requestRename(taskID: idA, currentName: "Chat A")
        tms.renameText = "Renamed Chat"
        if let pending = tms.takePendingRename() {
            await sut.updateTaskTitle(id: pending.taskID, title: pending.title)
        }

        XCTAssertNil(sut.lastErrorMessage)
        let reloaded = try sut.repository.loadTask(at: tempDir, taskID: idA)
        XCTAssertEqual(reloaded.title, "Renamed Chat")
        XCTAssertNil(reloaded.closedAt,
                     "Rename must not set closedAt — that's closeTask's job")
        XCTAssertNotEqual(reloaded.runs.last?.steps.first?.status, .done,
                          "Rename must not finalize the step to .done — that's closeTask's job (recovery flipping to .paused is fine)")
        XCTAssertNotEqual(reloaded.runs.last?.roleStatuses["assistant"], .done,
                          "Rename must not finalize the role to .done — that's closeTask's job")

        // Positive pin of the recovery side effect: `ensureTaskLoaded` runs
        // `StatusRecoveryService.recoverStaleStatuses` on a freshly-loaded cold
        // task BEFORE `mutateTask` runs. For a stale `.running` step from a
        // pre-restart session, recovery flips it to `.paused` and persists.
        // Documenting this side effect explicitly so a future reader understands
        // why the post-rename disk state isn't `.running` (it's not the rename's
        // doing — it's recovery firing transparently for any cold-task entry).
        XCTAssertEqual(reloaded.runs.last?.steps.first?.status, .paused,
                       "ensureTaskLoaded's recovery must flip stale .running to .paused — by-design side effect of any cold-task entry, not specific to rename")
        XCTAssertEqual(reloaded.runs.last?.roleStatuses["assistant"], .idle,
                       "ensureTaskLoaded's recovery must flip stale .working role to .idle — by-design side effect")
    }

    /// Pin: when `ensureTaskLoaded` fails (e.g. `task.json` deleted between
    /// sidebar render and click), `updateTaskTitle` must short-circuit BEFORE
    /// `mutateTask` overwrites the actionable disk error in `lastErrorMessage`
    /// with the generic "Cannot persist task N: task not loaded." string. Same
    /// invariant as `CloseTaskTests.testCloseTask_evictedTaskWithMissingDisk_preservesDiskErrorMessage`.
    func testConfirmRename_evictedTaskWithMissingDisk_preservesDiskErrorMessage() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "Original", supervisorTask: "x")!
        _ = await sut.createTask(title: "B", supervisorTask: "y")!
        sut.evictLoadedTask(idA)

        // Delete A's task.json on disk to force `repository.loadTask` to throw.
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try? FileManager.default.removeItem(at: paths.taskJSON(taskID: idA))

        sut.lastErrorMessage = nil

        tms.requestRename(taskID: idA, currentName: "Original")
        tms.renameText = "Renamed"
        if let pending = tms.takePendingRename() {
            await sut.updateTaskTitle(id: pending.taskID, title: pending.title)
        }

        XCTAssertNotNil(sut.lastErrorMessage, "Disk error must surface to the user")
        XCTAssertFalse(
            sut.lastErrorMessage?.contains("task not loaded") ?? false,
            "Generic 'task not loaded' must NOT mask the actionable disk error — got: \(sut.lastErrorMessage ?? "nil")"
        )
    }
}
