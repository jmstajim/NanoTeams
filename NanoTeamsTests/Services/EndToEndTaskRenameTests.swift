import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for the **task rename workflow** — Supervisor
/// right-clicks a task in the sidebar → "Rename..." → edits the title →
/// confirms/cancels.
///
/// This covers the full `TaskManagementState.requestRename` +
/// `confirmRename` / `cancelRename` contract as it integrates with the
/// orchestrator's `updateTaskTitle`.
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
final class EndToEndTaskRenameTests: NTMSOrchestratorTestBase {

    private var tms: TaskManagementState!

    override func setUp() {
        super.setUp()
        tms = TaskManagementState()
    }

    override func tearDown() {
        tms = nil
        super.tearDown()
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

        await tms.confirmRename(store: sut)

        XCTAssertNil(tms.taskToRename, "State cleared after confirm")
        XCTAssertEqual(tms.renameText, "")

        await sut.switchTask(to: id)
        XCTAssertEqual(sut.activeTask?.title, "Renamed Title",
                       "Task title reflects the confirmed rename")
    }

    func testConfirmRename_persistsToDisk_surviveRestart() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "Original", supervisorTask: "x")!

        tms.requestRename(taskID: id, currentName: "Original")
        tms.renameText = "Persists"
        await tms.confirmRename(store: sut)

        // Simulate app restart
        sut = NTMSOrchestrator(repository: NTMSRepository())
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

        await tms.confirmRename(store: sut)

        XCTAssertNil(tms.taskToRename, "State cleared (via cancelRename fallback)")

        await sut.switchTask(to: id)
        XCTAssertEqual(sut.activeTask?.title, "KeepMe",
                       "Empty rename must not clobber the existing title")
    }

    // MARK: - Scenario 5: Siblings untouched

    func testConfirmRename_onlyAffectsTargetTask() async {
        await sut.openWorkFolder(tempDir)
        let idA = await sut.createTask(title: "A original", supervisorTask: "x")!
        let idB = await sut.createTask(title: "B original", supervisorTask: "y")!

        tms.requestRename(taskID: idA, currentName: "A original")
        tms.renameText = "A renamed"
        await tms.confirmRename(store: sut)

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
        await tms.confirmRename(store: sut)

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
        await tms.confirmRename(store: sut)

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
}
