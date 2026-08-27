import XCTest

@testable import NanoTeams

/// Wave 22 — the QuickCapture state that is keyed by a **folder-local** task id but lives
/// in a **process-global** singleton.
///
/// `NTMSOrchestrator.apply(_:)` already states the premise verbatim — *"Task IDs are
/// sequential ints per folder, so collisions across folders are the norm"* — and already
/// drops `loadedTasks` on a folder change for exactly that reason. The QuickCapture
/// Supervisor-message queue and the per-task answer drafts are the same class of state,
/// keyed the same way, and were simply not included in that teardown.
///
/// The first test pins the PREMISE (ids really do collide, on the first task of every
/// folder), because every other test in this file is only interesting if it holds.
@MainActor
final class QuickCaptureFolderScopeCoverageTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// The orchestrator holds `quickCaptureFormState` weakly, so the test must own it.
    var formState: QuickCaptureFormState!
    var folderB: URL!

    override func setUp() async throws {
        try await super.setUp()
        formState = QuickCaptureFormState()
        sut.quickCaptureFormState = formState
        folderB = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let folderB { try? FileManager.default.removeItem(at: folderB) }
        folderB = nil
        formState = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func msg(_ text: String, target: String? = nil) -> QuickCaptureFormState.QueuedChatMessage {
        QuickCaptureFormState.QueuedChatMessage(
            text: text, attachments: [], clippedTexts: [], targetRoleID: target
        )!
    }

    private func payload(taskID: Int, question: String) -> SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: "step-\(taskID)",
            taskID: taskID,
            role: .softwareEngineer,
            roleDefinition: nil,
            question: question,
            messageContent: nil,
            thinking: nil,
            isChatMode: true
        )
    }

    // MARK: - The premise

    /// The premise the whole file rests on: if task ids were globally unique, cross-folder
    /// delivery would be unreachable and every other test here would be theatre.
    ///
    /// The escape hatch was the first instinct here — "no single production edit reds
    /// this" — and naming the edit disproved it, which is exactly what the pin's own
    /// message predicts.
    ///
    /// RED: allocate ids from a process-global counter instead of the folder's
    /// `TasksIndex.nextTaskID` in `NTMSRepository+TaskOperations` → the two ids differ and
    /// this fails, correctly: under that allocation the defect class this file exists for
    /// would no longer exist.
    func testTaskIDsAreAllocatedPerFolder_soACollisionAcrossFoldersIsTheNorm() async {
        await sut.openWorkFolder(tempDir)
        let inA = await sut.createTask(title: "A", supervisorTask: "first task of folder A")

        await sut.openWorkFolder(folderB)
        let inB = await sut.createTask(title: "B", supervisorTask: "first task of folder B")

        XCTAssertNotNil(inA)
        XCTAssertEqual(inA, inB,
                       "Each folder allocates from its own TasksIndex.nextTaskID, so the FIRST task of "
                           + "every folder carries the same id. Collision is the norm, not an edge case.")
    }

    // MARK: - The queue

    /// RED: delete the `quickCaptureFormState?.discardFolderScopedState()` call from
    /// `apply(_:)`'s `!sameFolder` branch → this fails: the message queued against folder
    /// A's task is still queued against the same-numbered task of folder B.
    func testOpenWorkFolder_dropsQueuedMessagesFromThePreviousFolder() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "A", supervisorTask: "a") else {
            return XCTFail("task creation failed")
        }
        formState.appendQueuedMessage(msg("delete the old migration scripts"), for: taskID)
        XCTAssertTrue(formState.hasQueuedMessage(for: taskID), "precondition")

        await sut.openWorkFolder(folderB)

        XCTAssertFalse(formState.hasQueuedMessage(for: taskID),
                       "A message the user typed for folder A's task must not be delivered to the "
                           + "same-numbered task of folder B.")
        XCTAssertTrue(formState.taskIDsWithQueuedMessages.isEmpty,
                      "No folder-A key may survive — `tryFlushQueuedMessages` iterates this list and "
                          + "wakes runs for every id in it.")
    }

    /// The gate is on folder IDENTITY, not on "openWorkFolder was called". Re-opening the
    /// same folder must not destroy the user's pending message.
    ///
    /// RED: replace the `!sameFolder` condition with an unconditional call → this fails.
    func testReopeningTheSameFolder_keepsTheQueue() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "A", supervisorTask: "a") else {
            return XCTFail("task creation failed")
        }
        formState.appendQueuedMessage(msg("still relevant"), for: taskID)

        await sut.openWorkFolder(tempDir)

        XCTAssertTrue(formState.hasQueuedMessage(for: taskID),
                      "Same folder id → same task-id namespace → the message is still for this task.")
    }

    /// `apply(_:)` runs on every snapshot-level change, not just folder opens. An ordinary
    /// task creation must not be mistaken for a folder change.
    ///
    /// RED: hoist the discard above the `sameFolder` check → this fails.
    func testCreatingAnotherTaskInTheSameFolder_keepsTheQueue() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "A", supervisorTask: "a") else {
            return XCTFail("task creation failed")
        }
        formState.appendQueuedMessage(msg("hold this thought"), for: taskID)

        _ = await sut.createTask(title: "B", supervisorTask: "b")

        XCTAssertTrue(formState.hasQueuedMessage(for: taskID),
                      "A same-folder snapshot change must leave folder-scoped state alone.")
    }

    // MARK: - Answer drafts

    /// The half-typed answer is the worse leak of the two: it is loaded straight back into
    /// the composer for the same-numbered task in the new folder, so a user who hits send
    /// without re-reading transmits the previous project's text.
    ///
    /// RED: drop `answerDrafts.removeAll()` from `discardFolderScopedState()` → this fails.
    func testOpenWorkFolder_dropsAnswerDraftsFromThePreviousFolder() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "A", supervisorTask: "a") else {
            return XCTFail("task creation failed")
        }
        formState.answerText = "use the client's staging token"
        formState.captureLiveComposerAsAnswerDraft(taskID: taskID)
        XCTAssertNotNil(formState._testAnswerDrafts[taskID], "precondition")

        await sut.openWorkFolder(folderB)

        XCTAssertNil(formState._testAnswerDrafts[taskID],
                     "A draft written against folder A's task must not pre-fill the answer composer "
                         + "for the same-numbered task of folder B.")
    }

    /// The LIVE answer session points at a step id that only exists in the folder being
    /// left. Leaving it armed makes the next panel open resolve into answer mode for a
    /// question the new folder never asked.
    ///
    /// RED: drop the `exitAnswerMode()` / session clear from `discardFolderScopedState()`
    /// → `isInAnswerMode` stays true and `pendingAnswer` still names folder A's step.
    func testOpenWorkFolder_disarmsTheLiveAnswerSession() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "A", supervisorTask: "a") else {
            return XCTFail("task creation failed")
        }
        formState.enterAnswerMode(payload: payload(taskID: taskID, question: "which credentials?"))
        formState.answerClippedTexts = [Clip].minting(["secret-ish clip"])
        XCTAssertTrue(formState.isInAnswerMode, "precondition")

        await sut.openWorkFolder(folderB)

        XCTAssertFalse(formState.isInAnswerMode,
                       "The pending question belongs to a folder that is no longer open.")
        XCTAssertNil(formState.pendingAnswer)
        XCTAssertTrue(formState.answerClippedTexts.isEmpty,
                      "Clips captured for folder A's answer must not ride into folder B.")
    }

    // MARK: - Scope boundary

    /// Deliberate boundary: what is dropped is what is keyed by a folder-local task id or
    /// points at a file staged inside the folder being left. The task draft's TEXT is
    /// neither — it is an unsent thought, and the Drafts-app pattern keeps it.
    ///
    /// RED: add `title`/`supervisorTask` clearing to `discardFolderScopedState()` → this fails.
    func testOpenWorkFolder_keepsTheUnsentTaskDraftText() async {
        await sut.openWorkFolder(tempDir)
        formState.title = "Refactor the login flow"
        formState.supervisorTask = "start with AuthService"

        await sut.openWorkFolder(folderB)

        XCTAssertEqual(formState.title, "Refactor the login flow")
        XCTAssertEqual(formState.supervisorTask, "start with AuthService",
                       "Unsent text is folder-agnostic — the task it becomes will be created in "
                           + "whichever folder is open when the user submits.")
    }

    /// Staged files live under the CLOSED folder's `.nanoteams/staged/`, so their relative
    /// paths resolve to nothing under the new root. Keeping them would hand `createTask`
    /// a set of dead references.
    ///
    /// RED: drop the attachment clearing / draftID rotation → this fails.
    func testOpenWorkFolder_dropsStagedAttachmentsAndRotatesTheDraftID() async throws {
        await sut.openWorkFolder(tempDir)
        let before = formState.draftID
        let staged = tempDir.appendingPathComponent("shot.png")
        try Data("png".utf8).write(to: staged)
        formState.attachments = [
            try StagedAttachment(url: staged, stagedRelativePath: ".nanoteams/staged/x/shot.png")
        ]

        await sut.openWorkFolder(folderB)

        XCTAssertTrue(formState.attachments.isEmpty,
                      "Files staged inside the closed folder cannot be finalized against the new root.")
        XCTAssertNotEqual(formState.draftID, before,
                          "A fresh staging directory for the new folder, so the next drop does not land "
                              + "in a directory keyed to the old one.")
    }
}
