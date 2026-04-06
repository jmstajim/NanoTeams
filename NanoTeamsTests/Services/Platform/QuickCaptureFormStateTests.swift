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

    private func makePayload(question: String = "Q?", isChatMode: Bool = false) -> SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: "test_step",
            taskID: Int(),
            role: .softwareEngineer,
            roleDefinition: nil,
            question: question,
            messageContent: nil,
            thinking: nil,
            isChatMode: isChatMode
        )
    }

    // MARK: - Answer Mode Transitions

    func testEnterAnswerMode_savesGoalAndClearsIt() {
        sut.supervisorTask = "My task draft"
        sut.enterAnswerMode(payload: makePayload())

        XCTAssertTrue(sut.isInAnswerMode)
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
        XCTAssertEqual(sut.supervisorTask, "")

        // User types an answer, then the active task changes and enterAnswerMode fires again
        sut.supervisorTask = "typing an answer"
        sut.enterAnswerMode(payload: makePayload(question: "Second"))

        // Saved task must still be the original task draft, NOT the partial answer
        XCTAssertEqual(sut._testSavedSupervisorTask, "User's task draft")
        XCTAssertEqual(sut.pendingAnswer?.question, "Second")
        // The in-progress answer text stays as-is (new answer for new question)
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
}
