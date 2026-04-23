import XCTest

@testable import NanoTeams

/// Direct unit tests for `QuickCaptureFormState` — the answer-mode state machine,
/// submission guards, and draft-content predicates. No controller, no orchestrator.
@MainActor
final class QuickCaptureFormStateTests: XCTestCase {

    var sut: QuickCaptureFormState!

    override func setUp() {
        super.setUp()
        sut = QuickCaptureFormState()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makePayload(
        taskID: Int = 0,
        question: String = "Q?",
        isChatMode: Bool = false
    ) -> SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: "step_\(taskID)",
            taskID: taskID,
            role: .softwareEngineer,
            roleDefinition: nil,
            question: question,
            messageContent: nil,
            thinking: nil,
            isChatMode: isChatMode
        )
    }

    // MARK: - Answer Mode Transitions

    func testEnterAnswerMode_savesGoalAndClearsAnswerField() {
        sut.supervisorTask = "My task draft"
        sut.enterAnswerMode(payload: makePayload())

        XCTAssertTrue(sut.isInAnswerMode)
        // Answer field starts empty so the user's task draft does not leak into
        // the answer. The original text is preserved via `savedSupervisorTask`
        // and restored on `exitAnswerMode`.
        XCTAssertEqual(sut.supervisorTask, "")
        XCTAssertEqual(sut._testSavedSupervisorTask, "My task draft")
        XCTAssertNotNil(sut.pendingAnswer)
    }

    func testExitAnswerMode_restoresSavedGoal() {
        sut.supervisorTask = "Original"
        sut.enterAnswerMode(payload: makePayload())
        sut.exitAnswerMode()

        XCTAssertFalse(sut.isInAnswerMode)
        XCTAssertEqual(sut.supervisorTask, "Original")
        XCTAssertNil(sut._testSavedSupervisorTask)
        XCTAssertNil(sut.pendingAnswer)
    }

    /// Critical: calling `enterAnswerMode` while already in answer mode must NOT
    /// overwrite `savedSupervisorTask` with the current (cleared) `supervisorTask`. Regression would
    /// silently destroy the user's task draft on `exitAnswerMode`.
    func testEnterAnswerMode_reentry_preservesSavedGoal() {
        sut.supervisorTask = "User's task draft"
        sut.enterAnswerMode(payload: makePayload(question: "First"))
        XCTAssertEqual(sut._testSavedSupervisorTask, "User's task draft")
        // Initial entry starts the answer field empty — task draft is stashed.
        XCTAssertEqual(sut.supervisorTask, "")

        // User types an answer, then `enterAnswerMode` fires again for the same task
        sut.supervisorTask = "typing an answer"
        sut.enterAnswerMode(payload: makePayload(question: "Second"))

        // Saved task must still be the original task draft, NOT the partial answer
        XCTAssertEqual(sut._testSavedSupervisorTask, "User's task draft")
        XCTAssertEqual(sut.pendingAnswer?.question, "Second")
        // The in-progress answer text stays as-is — re-entry is non-destructive.
        XCTAssertEqual(sut.supervisorTask, "typing an answer")
    }

    func testUpdateAnswerPayload_updatesPayloadOnly() {
        sut.enterAnswerMode(payload: makePayload(question: "First"))
        sut.updateAnswerPayload(makePayload(question: "Second"))

        XCTAssertTrue(sut.isInAnswerMode)
        XCTAssertEqual(sut.pendingAnswer?.question, "Second")
    }

    // MARK: - Clear Methods

    func testClearAnswerSession_clearsOnlyClipsAndAttachments() {
        sut.supervisorTask = "base"
        sut.enterAnswerMode(payload: makePayload())
        sut.answerClippedTexts = ["clip"]
        // Note: answerAttachments population requires store staging — just clippedTexts here

        sut.clearAnswerSession()

        XCTAssertTrue(sut.answerClippedTexts.isEmpty)
        XCTAssertTrue(sut.answerAttachments.isEmpty)
        // clearAnswerSession does NOT exit answer mode — pendingAnswer and isInAnswerMode persist
        XCTAssertTrue(sut.isInAnswerMode)
        XCTAssertNotNil(sut.pendingAnswer)
    }

    func testClearTaskDraft_resetsAllTaskFields() {
        sut.title = "t"
        sut.supervisorTask = "g"
        sut.selectedTeamID = "team"
        sut.clippedTexts = ["clip"]
        let oldDraftID = sut.draftID

        sut.clearTaskDraft()

        XCTAssertTrue(sut.title.isEmpty)
        XCTAssertTrue(sut.supervisorTask.isEmpty)
        XCTAssertNil(sut.selectedTeamID)
        XCTAssertTrue(sut.clippedTexts.isEmpty)
        XCTAssertTrue(sut.attachments.isEmpty)
        XCTAssertNotEqual(sut.draftID, oldDraftID)
    }

    // MARK: - canSubmit(mode:)

    func testCanSubmit_overlayMode_requiresText() {
        XCTAssertFalse(sut.canSubmit(mode: .overlay))
        sut.supervisorTask = "  "
        XCTAssertFalse(sut.canSubmit(mode: .overlay))
        sut.supervisorTask = "Do X"
        XCTAssertTrue(sut.canSubmit(mode: .overlay))
    }

    func testCanSubmit_sheetMode_requiresText() {
        XCTAssertFalse(sut.canSubmit(mode: .sheet))
        sut.supervisorTask = "Do X"
        XCTAssertTrue(sut.canSubmit(mode: .sheet))
    }

    func testCanSubmit_supervisorAnswer_acceptsTextOrClipsOrAttachments() {
        let mode = QuickCaptureMode.supervisorAnswer(payload: makePayload())

        XCTAssertFalse(sut.canSubmit(mode: mode))

        sut.supervisorTask = "Text answer"
        XCTAssertTrue(sut.canSubmit(mode: mode))

        sut.supervisorTask = ""
        sut.answerClippedTexts = ["clipped snippet"]
        XCTAssertTrue(sut.canSubmit(mode: mode))
    }

    // MARK: - hasTaskDraftContent

    func testHasTaskDraftContent_falseWhenEmpty() {
        XCTAssertFalse(sut.hasTaskDraftContent)
    }

    func testHasTaskDraftContent_ignoresWhitespace() {
        sut.title = "   "
        sut.supervisorTask = "\n\t"
        XCTAssertFalse(sut.hasTaskDraftContent)
    }

    func testHasTaskDraftContent_trueWithGoal() {
        sut.supervisorTask = "Build something"
        XCTAssertTrue(sut.hasTaskDraftContent)
    }

    // MARK: - Per-Task Answer Draft Persistence

    func testExitAnswerMode_savesDraft_reenterRestores() {
        let payload = makePayload(taskID: 1)
        sut.enterAnswerMode(payload: payload)
        sut.supervisorTask = "my answer"
        sut.answerClippedTexts = ["clip A"]

        sut.exitAnswerMode()

        // Draft saved
        let drafts = sut._testAnswerDrafts
        XCTAssertEqual(drafts[1]?.text, "my answer")
        XCTAssertEqual(drafts[1]?.clippedTexts, ["clip A"])

        // Re-enter same task — draft restored
        sut.enterAnswerMode(payload: payload)
        XCTAssertEqual(sut.supervisorTask, "my answer")
        XCTAssertEqual(sut.answerClippedTexts, ["clip A"])
    }

    func testSwitchAnswerTask_preservesBothDrafts() {
        let payloadA = makePayload(taskID: 10, question: "Q for A")
        let payloadB = makePayload(taskID: 20, question: "Q for B")

        sut.enterAnswerMode(payload: payloadA)
        sut.supervisorTask = "answer A"
        sut.answerClippedTexts = ["clip A"]

        // Switch to task B
        sut.switchAnswerTask(from: 10, to: payloadB)
        XCTAssertEqual(sut.supervisorTask, "")
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)

        // Type answer for task B
        sut.supervisorTask = "answer B"
        sut.answerClippedTexts = ["clip B"]

        // Switch back to task A
        sut.switchAnswerTask(from: 20, to: payloadA)
        XCTAssertEqual(sut.supervisorTask, "answer A")
        XCTAssertEqual(sut.answerClippedTexts, ["clip A"])

        // Switch back to B — still there
        sut.switchAnswerTask(from: 10, to: payloadB)
        XCTAssertEqual(sut.supervisorTask, "answer B")
        XCTAssertEqual(sut.answerClippedTexts, ["clip B"])
    }

    func testClearAnswerSession_savesDraftBeforeClearing() {
        let payload = makePayload(taskID: 5)
        sut.enterAnswerMode(payload: payload)
        sut.supervisorTask = "draft text"
        sut.answerClippedTexts = ["clip"]

        // Panel close calls clearAnswerSession
        sut.clearAnswerSession()

        // Active state cleared
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)

        // But draft preserved
        let drafts = sut._testAnswerDrafts
        XCTAssertEqual(drafts[5]?.text, "draft text")
        XCTAssertEqual(drafts[5]?.clippedTexts, ["clip"])
    }

    func testDiscardAnswerDraft_removesDraft() {
        let payload = makePayload(taskID: 7)
        sut.enterAnswerMode(payload: payload)
        sut.supervisorTask = "will be discarded"
        sut.exitAnswerMode()

        XCTAssertNotNil(sut._testAnswerDrafts[7])

        sut.discardAnswerDraft(taskID: 7)
        XCTAssertNil(sut._testAnswerDrafts[7])
    }

    func testExitAnswerMode_emptyDraft_notSaved() {
        let payload = makePayload(taskID: 3)
        sut.enterAnswerMode(payload: payload)
        // Don't type anything, leave empty
        sut.exitAnswerMode()

        XCTAssertNil(sut._testAnswerDrafts[3])
    }

    func testDismissAndReopen_preservesDraft() {
        let payload = makePayload(taskID: 42)
        sut.enterAnswerMode(payload: payload)
        sut.supervisorTask = "important answer"
        sut.answerClippedTexts = ["code snippet"]

        // Simulate panel dismiss
        sut.exitAnswerMode()
        XCTAssertFalse(sut.isInAnswerMode)
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)

        // Simulate panel reopen on same task
        sut.enterAnswerMode(payload: payload)
        XCTAssertEqual(sut.supervisorTask, "important answer")
        XCTAssertEqual(sut.answerClippedTexts, ["code snippet"])
    }

    func testSwitchAnswerTask_newTaskWithNoDraft_startsFresh() {
        let payloadA = makePayload(taskID: 1, question: "Q1")
        let payloadB = makePayload(taskID: 2, question: "Q2")

        sut.enterAnswerMode(payload: payloadA)
        sut.supervisorTask = "answer for A"

        sut.switchAnswerTask(from: 1, to: payloadB)

        // New task has no draft — starts fresh
        XCTAssertEqual(sut.supervisorTask, "")
        XCTAssertTrue(sut.answerAttachments.isEmpty)
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)
        XCTAssertEqual(sut.pendingAnswer?.taskID, 2)
    }

    // MARK: - Regression: Issue #4 — enterAnswerMode re-entry with different taskID

    func testEnterAnswerMode_reentry_differentTaskID_switchesDrafts() {
        let payloadA = makePayload(taskID: 10, question: "Q for A")
        let payloadB = makePayload(taskID: 20, question: "Q for B")

        sut.enterAnswerMode(payload: payloadA)
        sut.supervisorTask = "answer A"
        sut.answerClippedTexts = ["clip A"]

        // Re-enter with different taskID (without explicit switchAnswerTask)
        sut.enterAnswerMode(payload: payloadB)

        // Must NOT show stale data from task A
        XCTAssertEqual(sut.supervisorTask, "")
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)
        XCTAssertEqual(sut.pendingAnswer?.taskID, 20)

        // Task A draft must be preserved
        XCTAssertEqual(sut._testAnswerDrafts[10]?.text, "answer A")
        XCTAssertEqual(sut._testAnswerDrafts[10]?.clippedTexts, ["clip A"])
    }

    func testEnterAnswerMode_reentry_sameTaskID_keepsState() {
        let payload1 = makePayload(taskID: 5, question: "Q1")
        let payload2 = makePayload(taskID: 5, question: "Q2")

        sut.enterAnswerMode(payload: payload1)
        sut.supervisorTask = "my answer"
        sut.answerClippedTexts = ["clip"]

        // Re-enter same taskID with updated question
        sut.enterAnswerMode(payload: payload2)

        // Answer text and clips stay as-is (same task, just payload update)
        XCTAssertEqual(sut.supervisorTask, "my answer")
        XCTAssertEqual(sut.answerClippedTexts, ["clip"])
        XCTAssertEqual(sut.pendingAnswer?.question, "Q2")
    }

    /// Regression: discardAnswerDraft + exitAnswerMode must not re-save stale attachments.
    /// Simulates the controller's submitAnswer() cleanup sequence.
    func testDiscardDraft_clearFields_exitAnswerMode_doesNotResaveDraft() {
        let payload = makePayload(taskID: 42)
        sut.enterAnswerMode(payload: payload)
        sut.supervisorTask = "my answer"
        sut.answerClippedTexts = ["clip"]

        // Simulate controller's post-submit cleanup
        sut.discardAnswerDraft(taskID: 42)
        sut.supervisorTask = ""
        sut.answerAttachments = []
        sut.answerClippedTexts = []
        sut.exitAnswerMode()

        // Re-enter for the same task — must start clean
        sut.enterAnswerMode(payload: payload)
        XCTAssertEqual(sut.supervisorTask, "", "Stale answer text should not reappear")
        XCTAssertTrue(sut.answerAttachments.isEmpty, "Stale attachments should not reappear")
        XCTAssertTrue(sut.answerClippedTexts.isEmpty, "Stale clips should not reappear")
    }

    /// Regression: cancelDraft path — same pattern as submit.
    func testCancelDraft_clearFields_exitAnswerMode_doesNotResaveDraft() {
        let payload = makePayload(taskID: 7)
        sut.enterAnswerMode(payload: payload)
        sut.supervisorTask = "partial answer"
        sut.answerClippedTexts = ["snippet"]

        // Simulate controller's cancelDraft cleanup
        sut.discardAnswerDraft(taskID: 7)
        sut.supervisorTask = ""
        sut.answerAttachments = []
        sut.answerClippedTexts = []
        sut.exitAnswerMode()

        // Re-enter — must be clean
        sut.enterAnswerMode(payload: payload)
        XCTAssertEqual(sut.supervisorTask, "")
        XCTAssertTrue(sut.answerAttachments.isEmpty)
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)
    }

    func testEnterAnswerMode_reentry_differentTask_thenBackRestoresDraft() {
        let payloadA = makePayload(taskID: 10, question: "QA")
        let payloadB = makePayload(taskID: 20, question: "QB")

        sut.enterAnswerMode(payload: payloadA)
        sut.supervisorTask = "answer A"

        // Switch to B via re-entry
        sut.enterAnswerMode(payload: payloadB)
        sut.supervisorTask = "answer B"

        // Switch back to A via re-entry
        sut.enterAnswerMode(payload: payloadA)
        XCTAssertEqual(sut.supervisorTask, "answer A")

        // Switch back to B
        sut.enterAnswerMode(payload: payloadA)
        // Same task, no switch — stays on A
        XCTAssertEqual(sut.supervisorTask, "answer A")
    }

}
