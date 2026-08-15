import XCTest

@testable import NanoTeams

/// A `SelectionCapturing` double returning a scripted capture.
@MainActor
private final class BucketTestCapturer: SelectionCapturing {
    var scripted = ClipboardCaptureResult(text: nil, fileURLs: [])
    func requestAccessibilityIfNeeded() {}
    func captureSelection(workFolderRoot: URL?) async -> ClipboardCaptureResult { scripted }
}

/// Wave 23 — the two attachment/clip buckets are shared by THREE modes, and the code that
/// files into them asked the wrong question.
///
/// `answerAttachments` / `answerClippedTexts` are not "the answer draft". They are the
/// buckets the `MessageComposer` binds to in **both** `.supervisorAnswer` and chat-mode
/// `.taskWorking` — a fact `applyAnswerModeTransition` states outright in prose
/// ("Chat-mode `.taskWorking` and `.supervisorAnswer` bind the composer to the same three
/// live fields"). The clipboard router and the panel-dismiss teardown were both written as
/// if only answer mode used them.
@MainActor
final class QuickCaptureChatComposerBucketCoverageTests: XCTestCase {

    private var capturer: BucketTestCapturer!
    private var controller: QuickCaptureController!

    override func setUp() async throws {
        try await super.setUp()
        QuickCaptureController.shared._testReset()
        capturer = BucketTestCapturer()
    }

    override func tearDown() async throws {
        controller = nil
        capturer = nil
        QuickCaptureController.shared._testReset()
        try await super.tearDown()
    }

    private func makeController() -> QuickCaptureController {
        let made = QuickCaptureController(
            formState: QuickCaptureFormState(),
            selectionCapturer: capturer
        )
        controller = made
        return made
    }

    private func answerMode(taskID: Int = 1) -> QuickCaptureMode {
        .supervisorAnswer(payload: SupervisorAnswerPayload(
            stepID: "r", taskID: taskID, role: .softwareEngineer, roleDefinition: nil,
            question: "which?", messageContent: nil, thinking: nil, isChatMode: true))
    }

    private let chatWorking = QuickCaptureMode.taskWorking(roleName: "Engineer", isChatMode: true)
    private let loaderWorking = QuickCaptureMode.taskWorking(roleName: "Engineer", isChatMode: false)

    // MARK: - Which bucket does this mode's composer render

    /// The property is the single source of truth the router consumes. Table over every
    /// mode, because the interesting value is the one that differs from
    /// `expectsFocusableField` — `.overlay` renders a composer too, bound to the OTHER pair.
    ///
    /// RED: return `true` for `.overlay`, or `false` for chat `.taskWorking` → one row fails.
    func testComposerBucketBinding_isAPropertyOfTheMode() {
        XCTAssertFalse(QuickCaptureMode.overlay.composerBindsAnswerBuckets,
            "the new-task composer binds `attachments` / `clippedTexts`")
        XCTAssertTrue(answerMode().composerBindsAnswerBuckets)
        XCTAssertTrue(chatWorking.composerBindsAnswerBuckets,
            "chat-mode working docks the SAME composer as answer mode, against the same "
            + "two buckets — that is why queueing a message and answering a question can "
            + "hand off content to each other")
        XCTAssertFalse(loaderWorking.composerBindsAnswerBuckets,
            "non-chat working renders a loader and no composer at all")
    }

    // MARK: - ⌃⌥⌘K routing

    /// The defect. ⌃⌥⌘K while a chat team is working resolved to `.taskWorking(isChatMode:
    /// true)`, which is not `.supervisorAnswer`, so the capture fell to the task bucket —
    /// which that mode renders nowhere. The user saw no card, and the clip rode silently
    /// into whatever new task they created next.
    ///
    /// RED: route on `case .supervisorAnswer = mode` instead of the mode's own binding
    /// property → the clip lands in `clippedTexts` and both assertions fail.
    func testCapture_inChatWorkingMode_landsInTheBucketsThatModeRenders() async {
        let sut = makeController()
        capturer.scripted = ClipboardCaptureResult(text: "stack trace", fileURLs: [])

        await sut.captureClipboardContent(mode: chatWorking)

        XCTAssertEqual(sut.formState.answerClippedTexts, ["stack trace"],
            "the chat-working composer binds the answer buckets, so that is where a "
            + "capture has to land to be visible at all")
        XCTAssertTrue(sut.formState.clippedTexts.isEmpty,
            "the task bucket is invisible in this mode — a clip filed there surfaces "
            + "later, attached to an unrelated new-task draft")
    }

    /// The user-visible consequence, and the reason the two ends have to agree: the Send
    /// button reads the same buckets the composer renders. Routing a capture into the other
    /// pair leaves the panel showing nothing AND refusing to send.
    ///
    /// RED: route to the task bucket → `canSubmit` stays false and this fails.
    func testCapture_inChatWorkingMode_enablesSend() async {
        let sut = makeController()
        capturer.scripted = ClipboardCaptureResult(text: "stack trace", fileURLs: [])
        XCTAssertFalse(sut.formState.canSubmit(mode: chatWorking), "precondition")

        await sut.captureClipboardContent(mode: chatWorking)

        XCTAssertTrue(sut.formState.canSubmit(mode: chatWorking),
            "a capture the composer renders must also satisfy the submit gate — the gate "
            + "reads exactly the buckets the composer is bound to")
    }

    /// RED: make the router unconditional (always answer buckets) → this fails. The
    /// new-task composer binds the task pair; a capture into the answer pair would be
    /// invisible there for the mirror-image reason.
    func testCapture_inOverlayMode_stillLandsInTheTaskBucket() async {
        let sut = makeController()
        capturer.scripted = ClipboardCaptureResult(text: "prose", fileURLs: [])

        await sut.captureClipboardContent(mode: .overlay)

        XCTAssertEqual(sut.formState.clippedTexts, ["prose"])
        XCTAssertTrue(sut.formState.answerClippedTexts.isEmpty)
    }

    /// RED: route `.taskWorking` unconditionally to the answer bucket → this fails.
    /// Non-chat working renders a loader only; neither bucket is visible, and the task
    /// draft is the one the user will eventually submit, so it is the honest destination.
    func testCapture_inLoaderOnlyWorkingMode_landsInTheTaskBucket() async {
        let sut = makeController()
        capturer.scripted = ClipboardCaptureResult(text: "prose", fileURLs: [])

        await sut.captureClipboardContent(mode: loaderWorking)

        XCTAssertEqual(sut.formState.clippedTexts, ["prose"])
        XCTAssertTrue(sut.formState.answerClippedTexts.isEmpty)
    }

    /// RED: route on the mode's binding property but negate it → this fails. Answer mode's
    /// existing behaviour is unchanged by the fix; the property agrees with it.
    func testCapture_inAnswerMode_isUnchanged() async {
        let sut = makeController()
        capturer.scripted = ClipboardCaptureResult(text: "selected prose", fileURLs: [])

        await sut.captureClipboardContent(mode: answerMode())

        XCTAssertEqual(sut.formState.answerClippedTexts, ["selected prose"])
        XCTAssertTrue(sut.formState.clippedTexts.isEmpty)
    }

    // MARK: - Dismiss

    /// `dismissPanel`'s non-answer fork called `clearAnswerSession()`, whose documented job
    /// is "saves draft first so it persists across open/close". That save is gated on
    /// `pendingAnswer`, and `pendingAnswer` is non-nil exactly when `isInAnswerMode` is —
    /// i.e. exactly when the OTHER fork runs. So on this fork the save could never fire and
    /// the method was a bare destructive clear of the chat composer's two buckets.
    ///
    /// The asymmetry is the tell: the typed text survived a dismiss (nothing clears
    /// `supervisorTask` here) while the attachments and clips beside it did not.
    ///
    /// RED: restore `else { formState.clearAnswerSession() }` in `dismissPanel` → both
    /// bucket assertions fail.
    func testDismiss_inChatWorkingMode_keepsWhatTheComposerWasHolding() {
        let sut = makeController()
        sut.formState.answerText = "have a look at this"
        sut.formState.answerClippedTexts = ["the failing assertion"]

        sut.dismissPanel()

        XCTAssertEqual(sut.formState.answerText, "have a look at this",
            "unchanged — the text was never the half that got dropped")
        XCTAssertEqual(sut.formState.answerClippedTexts, ["the failing assertion"],
            "a dismiss is not a submit and not a task switch; the composer content "
            + "belongs to a task the panel will reopen onto")
    }

    /// The answer fork is untouched: it still saves the draft and restores the stashed
    /// task text, which is what makes an answer survive a close/open cycle.
    ///
    /// RED: replace `exitAnswerMode()` with the deleted `clearAnswerSession()` → the draft
    /// is still saved but `isInAnswerMode` stays true and the last assertion fails.
    func testDismiss_inAnswerMode_stillSavesTheDraftAndExits() {
        let sut = makeController()
        sut.formState.supervisorTask = "a task draft"
        sut.formState.enterAnswerMode(payload: SupervisorAnswerPayload(
            stepID: "r", taskID: 7, role: .softwareEngineer, roleDefinition: nil,
            question: "which?", messageContent: nil, thinking: nil, isChatMode: true))
        sut.formState.answerText = "half an answer"
        sut.formState.answerClippedTexts = ["clip"]

        sut.dismissPanel()

        XCTAssertEqual(sut.formState._testAnswerDrafts[7]?.text, "half an answer",
            "the answer is preserved per task, so reopening the panel restores it")
        XCTAssertEqual(sut.formState._testAnswerDrafts[7]?.clippedTexts, ["clip"])
        XCTAssertEqual(sut.formState.supervisorTask, "a task draft",
            "and the stashed new-task draft comes back")
        XCTAssertFalse(sut.formState.isInAnswerMode)
    }
}
