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

    /// The answer field starts empty, and the task draft is left exactly where it is. Both
    /// halves used to be one operation: `savedSupervisorTask` stashed the task draft so the
    /// SAME field could carry the answer. The stash is gone with the sharing — see
    /// `QuickCaptureComposerFieldOwnershipCoverageTests` for the routes it never covered.
    func testEnterAnswerMode_startsAFreshAnswerAndLeavesTheTaskDraftAlone() {
        sut.supervisorTask = "My task draft"
        sut.enterAnswerMode(payload: makePayload())

        XCTAssertTrue(sut.isInAnswerMode)
        XCTAssertEqual(sut.answerText, "")
        XCTAssertEqual(sut.supervisorTask, "My task draft")
        XCTAssertNotNil(sut.pendingAnswer)
    }

    func testExitAnswerMode_clearsTheAnswerAndStillLeavesTheTaskDraftAlone() {
        sut.supervisorTask = "Original"
        sut.enterAnswerMode(payload: makePayload())
        sut.answerText = "an answer"
        sut.exitAnswerMode()

        XCTAssertFalse(sut.isInAnswerMode)
        XCTAssertEqual(sut.answerText, "")
        XCTAssertEqual(sut.supervisorTask, "Original")
        XCTAssertNil(sut.pendingAnswer)
    }

    /// Re-entry for the same task is non-destructive: the in-progress answer stays, and the
    /// task draft — which re-entry never had any reason to touch — stays too.
    func testEnterAnswerMode_reentry_keepsBothDrafts() {
        sut.supervisorTask = "User's task draft"
        sut.enterAnswerMode(payload: makePayload(question: "First"))
        XCTAssertEqual(sut.answerText, "")

        // User types an answer, then `enterAnswerMode` fires again for the same task
        sut.answerText = "typing an answer"
        sut.enterAnswerMode(payload: makePayload(question: "Second"))

        XCTAssertEqual(sut.supervisorTask, "User's task draft")
        XCTAssertEqual(sut.pendingAnswer?.question, "Second")
        XCTAssertEqual(sut.answerText, "typing an answer")
    }

    func testUpdateAnswerPayload_updatesPayloadOnly() {
        sut.enterAnswerMode(payload: makePayload(question: "First"))
        sut.updateAnswerPayload(makePayload(question: "Second"))

        XCTAssertTrue(sut.isInAnswerMode)
        XCTAssertEqual(sut.pendingAnswer?.question, "Second")
    }

    // MARK: - Clear Methods

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

    func testCanSubmit_supervisorAnswer_acceptsTextOrClipsOrAttachments() {
        let mode = QuickCaptureMode.supervisorAnswer(payload: makePayload())

        XCTAssertFalse(sut.canSubmit(mode: mode))

        sut.answerText = "Text answer"
        XCTAssertTrue(sut.canSubmit(mode: mode))

        sut.answerText = ""
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
        sut.answerText = "my answer"
        sut.answerClippedTexts = ["clip A"]

        sut.exitAnswerMode()

        // Draft saved
        let drafts = sut._testAnswerDrafts
        XCTAssertEqual(drafts[1]?.text, "my answer")
        XCTAssertEqual(drafts[1]?.clippedTexts, ["clip A"])

        // Re-enter same task — draft restored
        sut.enterAnswerMode(payload: payload)
        XCTAssertEqual(sut.answerText, "my answer")
        XCTAssertEqual(sut.answerClippedTexts, ["clip A"])
    }

    func testSwitchAnswerTask_preservesBothDrafts() {
        let payloadA = makePayload(taskID: 10, question: "Q for A")
        let payloadB = makePayload(taskID: 20, question: "Q for B")

        sut.enterAnswerMode(payload: payloadA)
        sut.answerText = "answer A"
        sut.answerClippedTexts = ["clip A"]

        // Switch to task B
        sut.switchAnswerTask(from: 10, to: payloadB)
        XCTAssertEqual(sut.answerText, "")
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)

        // Type answer for task B
        sut.answerText = "answer B"
        sut.answerClippedTexts = ["clip B"]

        // Switch back to task A
        sut.switchAnswerTask(from: 20, to: payloadA)
        XCTAssertEqual(sut.answerText, "answer A")
        XCTAssertEqual(sut.answerClippedTexts, ["clip A"])

        // Switch back to B — still there
        sut.switchAnswerTask(from: 10, to: payloadB)
        XCTAssertEqual(sut.answerText, "answer B")
        XCTAssertEqual(sut.answerClippedTexts, ["clip B"])
    }

    /// `clearAnswerSession` is gone. Its comment claimed "Panel close calls
    /// clearAnswerSession", and that was true of exactly one fork of `dismissPanel` — the
    /// one reached only when `isInAnswerMode` is FALSE, where `pendingAnswer` is nil and
    /// the save these tests exercised could never run. What did run was a bare clear of
    /// the two buckets the chat-working composer renders. The behaviour worth keeping
    /// (a dismissed answer survives per task) belongs to `exitAnswerMode`, pinned below
    /// and by `QuickCaptureChatComposerBucketCoverageTests`.
    ///
    /// RED: drop the `saveCurrentAnswerDraft` call from `exitAnswerMode` → both
    /// assertions fail.
    func testDismissDraftPreservation_movedToExitAnswerMode() {
        let payload = makePayload(taskID: 5)
        sut.enterAnswerMode(payload: payload)
        sut.answerText = "draft text"
        sut.answerClippedTexts = ["clip"]

        sut.exitAnswerMode()

        XCTAssertEqual(sut._testAnswerDrafts[5]?.text, "draft text")
        XCTAssertEqual(sut._testAnswerDrafts[5]?.clippedTexts, ["clip"])
    }

    func testDiscardAnswerDraft_removesDraft() {
        let payload = makePayload(taskID: 7)
        sut.enterAnswerMode(payload: payload)
        sut.answerText = "will be discarded"
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
        sut.answerText = "important answer"
        sut.answerClippedTexts = ["code snippet"]

        // Simulate panel dismiss
        sut.exitAnswerMode()
        XCTAssertFalse(sut.isInAnswerMode)
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)

        // Simulate panel reopen on same task
        sut.enterAnswerMode(payload: payload)
        XCTAssertEqual(sut.answerText, "important answer")
        XCTAssertEqual(sut.answerClippedTexts, ["code snippet"])
    }

    func testSwitchAnswerTask_newTaskWithNoDraft_startsFresh() {
        let payloadA = makePayload(taskID: 1, question: "Q1")
        let payloadB = makePayload(taskID: 2, question: "Q2")

        sut.enterAnswerMode(payload: payloadA)
        sut.answerText = "answer for A"

        sut.switchAnswerTask(from: 1, to: payloadB)

        // New task has no draft — starts fresh
        XCTAssertEqual(sut.answerText, "")
        XCTAssertTrue(sut.answerAttachments.isEmpty)
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)
        XCTAssertEqual(sut.pendingAnswer?.taskID, 2)
    }

    // MARK: - Regression: Issue #4 — enterAnswerMode re-entry with different taskID

    func testEnterAnswerMode_reentry_differentTaskID_switchesDrafts() {
        let payloadA = makePayload(taskID: 10, question: "Q for A")
        let payloadB = makePayload(taskID: 20, question: "Q for B")

        sut.enterAnswerMode(payload: payloadA)
        sut.answerText = "answer A"
        sut.answerClippedTexts = ["clip A"]

        // Re-enter with different taskID (without explicit switchAnswerTask)
        sut.enterAnswerMode(payload: payloadB)

        // Must NOT show stale data from task A
        XCTAssertEqual(sut.answerText, "")
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
        sut.answerText = "my answer"
        sut.answerClippedTexts = ["clip"]

        // Re-enter same taskID with updated question
        sut.enterAnswerMode(payload: payload2)

        // Answer text and clips stay as-is (same task, just payload update)
        XCTAssertEqual(sut.answerText, "my answer")
        XCTAssertEqual(sut.answerClippedTexts, ["clip"])
        XCTAssertEqual(sut.pendingAnswer?.question, "Q2")
    }

    /// Regression: discardAnswerDraft + exitAnswerMode must not re-save stale attachments.
    /// Simulates the controller's submitAnswer() cleanup sequence.
    func testDiscardDraft_clearFields_exitAnswerMode_doesNotResaveDraft() {
        let payload = makePayload(taskID: 42)
        sut.enterAnswerMode(payload: payload)
        sut.answerText = "my answer"
        sut.answerClippedTexts = ["clip"]

        // Simulate controller's post-submit cleanup
        sut.discardAnswerDraft(taskID: 42)
        sut.answerText = ""
        sut.answerAttachments = []
        sut.answerClippedTexts = []
        sut.exitAnswerMode()

        // Re-enter for the same task — must start clean
        sut.enterAnswerMode(payload: payload)
        XCTAssertEqual(sut.answerText, "", "Stale answer text should not reappear")
        XCTAssertTrue(sut.answerAttachments.isEmpty, "Stale attachments should not reappear")
        XCTAssertTrue(sut.answerClippedTexts.isEmpty, "Stale clips should not reappear")
    }

    /// Regression: cancelDraft path — same pattern as submit.
    func testCancelDraft_clearFields_exitAnswerMode_doesNotResaveDraft() {
        let payload = makePayload(taskID: 7)
        sut.enterAnswerMode(payload: payload)
        sut.answerText = "partial answer"
        sut.answerClippedTexts = ["snippet"]

        // Simulate controller's cancelDraft cleanup
        sut.discardAnswerDraft(taskID: 7)
        sut.answerText = ""
        sut.answerAttachments = []
        sut.answerClippedTexts = []
        sut.exitAnswerMode()

        // Re-enter — must be clean
        sut.enterAnswerMode(payload: payload)
        XCTAssertEqual(sut.answerText, "")
        XCTAssertTrue(sut.answerAttachments.isEmpty)
        XCTAssertTrue(sut.answerClippedTexts.isEmpty)
    }

    func testEnterAnswerMode_reentry_differentTask_thenBackRestoresDraft() {
        let payloadA = makePayload(taskID: 10, question: "QA")
        let payloadB = makePayload(taskID: 20, question: "QB")

        sut.enterAnswerMode(payload: payloadA)
        sut.answerText = "answer A"

        // Switch to B via re-entry
        sut.enterAnswerMode(payload: payloadB)
        sut.answerText = "answer B"

        // Switch back to A via re-entry
        sut.enterAnswerMode(payload: payloadA)
        XCTAssertEqual(sut.answerText, "answer A")

        // Switch back to B
        sut.enterAnswerMode(payload: payloadA)
        // Same task, no switch — stays on A
        XCTAssertEqual(sut.answerText, "answer A")
    }

    // MARK: - Capture / Restore Across Chat-Working ↔ Answer Mode

    private func makeStagedAttachment(name: String) throws -> StagedAttachment {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QCFormStateTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name, isDirectory: false)
        try "stub".write(to: url, atomically: true, encoding: .utf8)
        return try StagedAttachment(url: url, stagedRelativePath: "draft/\(name)")
    }

    func testCaptureLiveComposerAsAnswerDraft_persistsTextAttachmentsAndClips() throws {
        let attachment = try makeStagedAttachment(name: "spec.txt")
        sut.answerText = "queued message"
        sut.answerAttachments = [attachment]
        sut.answerClippedTexts = ["clip-1"]

        sut.captureLiveComposerAsAnswerDraft(taskID: 42)

        let draft = sut._testAnswerDrafts[42]
        XCTAssertEqual(draft?.text, "queued message")
        XCTAssertEqual(draft?.attachments, [attachment])
        XCTAssertEqual(draft?.clippedTexts, ["clip-1"])
    }

    func testCaptureLiveComposerAsAnswerDraft_emptyContent_removesDraft() throws {
        let attachment = try makeStagedAttachment(name: "stale.txt")
        // Pre-seed a draft via the existing path
        sut.answerText = "stale"
        sut.answerAttachments = [attachment]
        sut.captureLiveComposerAsAnswerDraft(taskID: 99)
        XCTAssertNotNil(sut._testAnswerDrafts[99])

        // Clear live fields then capture again — empty content removes the entry
        sut.answerText = "   "
        sut.answerAttachments = []
        sut.answerClippedTexts = []
        sut.captureLiveComposerAsAnswerDraft(taskID: 99)

        XCTAssertNil(sut._testAnswerDrafts[99])
    }

    func testRestoreAnswerDraftToLiveFields_loadsSavedDraft() throws {
        let attachment = try makeStagedAttachment(name: "doc.txt")
        sut.answerText = "msg"
        sut.answerAttachments = [attachment]
        sut.answerClippedTexts = ["c1", "c2"]
        sut.captureLiveComposerAsAnswerDraft(taskID: 7)

        // Simulate the post-`exitAnswerMode` cleared state
        sut.answerText = ""
        sut.answerAttachments = []
        sut.answerClippedTexts = []

        sut.restoreAnswerDraftToLiveFields(taskID: 7)

        XCTAssertEqual(sut.answerText, "msg")
        XCTAssertEqual(sut.answerAttachments, [attachment])
        XCTAssertEqual(sut.answerClippedTexts, ["c1", "c2"])
    }

    func testRestoreAnswerDraftToLiveFields_noDraft_isNoOp() {
        sut.answerText = "live"
        sut.answerClippedTexts = ["c"]

        sut.restoreAnswerDraftToLiveFields(taskID: 1234)

        // Live fields untouched — no draft existed for that taskID
        XCTAssertEqual(sut.answerText, "live")
        XCTAssertEqual(sut.answerClippedTexts, ["c"])
    }

}
