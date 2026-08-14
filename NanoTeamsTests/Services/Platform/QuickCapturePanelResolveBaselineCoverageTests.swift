import XCTest

@testable import NanoTeams

/// Wave 26 — the baseline two resolvers share, and the arrival nobody loaded a draft for.
///
/// `refreshPanelIfVisible` decides two things from `taskChanged`: whether to rebuild the hosting
/// view, and whether to drop `forceNewTaskMode`. Both questions mean "has the active task moved
/// since the panel last resolved its content for one" — and the panel has exactly TWO resolvers,
/// `presentPanelSync` and `refreshPanelIfVisible`. Only the second recorded the baseline, so the
/// first refresh after every open compared against whatever the last refresh had seen.
///
/// The sibling baseline `lastRenderedIdentity` already got this right and says so in its own doc
/// comment — "written by `updatePanelContent` (the only builder) so the rebuild decision compares
/// rendered-vs-resolved rather than two independently-maintained opinions". `lastRefreshedTaskID`
/// is the other half of the same decision and stayed an independently-maintained opinion.
@MainActor
final class QuickCapturePanelResolveBaselineCoverageTests: XCTestCase {

    private var store: NTMSOrchestrator!
    private var controller: QuickCaptureController!
    private var workFolder: URL!

    override func setUp() {
        super.setUp()
        QuickCaptureController.shared._testReset()
        workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-baseline-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        controller = nil
        store = nil
        if let workFolder { try? FileManager.default.removeItem(at: workFolder) }
        workFolder = nil
        QuickCaptureController.shared._testReset()
        super.tearDown()
    }

    /// Wired but NOT yet visible — `presentPanelSync` guards on `!isPanelVisible`, so every test
    /// that drives the show pipeline has to start off screen.
    private func makeWired() async -> QuickCaptureController {
        let made = QuickCaptureController(formState: QuickCaptureFormState())
        store = await TestOrchestrator.make()
        await store.openWorkFolder(workFolder)
        made.store = store
        made.dictation = nil
        made.isTaskSelected = true
        controller = made
        return made
    }

    private func answerPayload(taskID: Int, isChatMode: Bool = true) -> SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: "s", taskID: taskID, role: .softwareEngineer, roleDefinition: nil,
            question: "Which framework?", messageContent: nil, thinking: nil,
            isChatMode: isChatMode)
    }

    // MARK: - The baseline moves at every resolve, not only at a refresh

    /// The structural claim. Showing the panel resolves the mode, takes the composer hand-off and
    /// decides on a rebuild — that is a resolve, and it has to leave the same footprint a refresh
    /// leaves, or the next refresh re-answers a question this one already answered.
    ///
    /// RED: drop the record from `presentPanelSync` → the baseline stays nil and this fails.
    func testShowingThePanel_recordsWhichTaskItResolvedFor() async {
        let sut = await makeWired()
        guard let taskA = await store.createTask(title: "A", supervisorTask: "a") else {
            return XCTFail("task creation failed")
        }
        store.engineState[taskA] = .running
        await store.switchTask(to: taskA)

        XCTAssertNil(sut._testLastRefreshedTaskID, "precondition: nothing resolved yet")

        sut._testPresentPanelSync()

        XCTAssertEqual(sut._testLastRefreshedTaskID, taskA,
            "the show pipeline resolved content for A, so A is what the next refresh compares against")
    }

    /// The sharp symptom. `showNewTask` sets `forceNewTaskMode` and posts a navigation to
    /// Watchtower; the navigation is asynchronous, so an engine transition routinely lands while
    /// `activeTaskID` is still the task the user came from. With the baseline never recorded by
    /// the open, that refresh read a task change that had not happened and dropped the flag — the
    /// new-task form the user had just asked for collapsed back into the task's own mode.
    ///
    /// RED: drop the record from `presentPanelSync` → `taskChanged` is true on the first refresh
    /// and `_testForceNewTaskMode` comes back false.
    func testTheNewTaskForm_survivesTheFirstPassiveRefreshAfterOpening() async {
        let sut = await makeWired()
        guard let taskA = await store.createTask(title: "A", supervisorTask: "a") else {
            return XCTFail("task creation failed")
        }
        store.engineState[taskA] = .running
        await store.switchTask(to: taskA)

        sut._testPresentPanelSync()
        sut._testIsPanelVisible = true

        sut.showNewTask()
        XCTAssertTrue(sut._testForceNewTaskMode, "precondition: the user asked for the new-task form")

        // The Watchtower navigation has not landed yet — `activeTaskID` is still A.
        sut.refreshPanelIfVisible()

        XCTAssertTrue(sut._testForceNewTaskMode,
            "nothing about the active task changed, so nothing may cancel the form")
    }

    /// The same reading in the other direction: a task change that DID happen must still be seen.
    /// A baseline that is merely always-fresh would pass the test above and break this one.
    ///
    /// RED: hardcode `taskChanged` to `false` → the flag survives a navigation that should have
    /// cancelled it. Pairing this with the test above is what keeps the fix from degenerating
    /// into "never report a change".
    func testARealTaskChange_stillCancelsTheNewTaskForm() async {
        let sut = await makeWired()
        guard let taskA = await store.createTask(title: "A", supervisorTask: "a"),
              let taskB = await store.createTask(title: "B", supervisorTask: "b")
        else { return XCTFail("task creation failed") }
        store.engineState[taskA] = .running
        await store.switchTask(to: taskA)

        sut._testPresentPanelSync()
        sut._testIsPanelVisible = true
        sut._testForceNewTaskMode = true

        store.engineState[taskB] = .running
        await store.switchTask(to: taskB)
        sut.refreshPanelIfVisible()

        XCTAssertFalse(sut._testForceNewTaskMode,
            "the user navigated INTO another task — that is what clears the flag")
    }

    /// Watchtower keeps the flag whatever the baseline says: the guard there is
    /// `currentTaskID != nil`, not the task comparison.
    func testAtWatchtower_theFormIsKeptRegardlessOfTheBaseline() async {
        let sut = await makeWired()
        guard let taskA = await store.createTask(title: "A", supervisorTask: "a") else {
            return XCTFail("task creation failed")
        }
        await store.switchTask(to: taskA)
        sut._testPresentPanelSync()
        sut._testIsPanelVisible = true
        sut._testForceNewTaskMode = true

        sut.isTaskSelected = false
        await store.switchTask(to: nil)
        sut.refreshPanelIfVisible()

        XCTAssertTrue(sut._testForceNewTaskMode,
            "no task is selected, so there is no task to resolve back to")
    }

    // MARK: - Arriving at a chat composer with an unclaimed bucket

    /// `dismissPanel` in answer mode saves the draft and releases the bucket. Reopening onto the
    /// same task's CHAT composer binds the very same three fields — and loaded nothing, because
    /// the restore was gated on having just left answer mode rather than on the bucket being
    /// unclaimed. The user watched their own text disappear.
    ///
    /// RED: drop the unclaimed-arrival restore → `answerText` comes back empty.
    func testReopeningOntoTheChatComposer_loadsTheDraftTheDismissJustSaved() async {
        let sut = await makeWired()
        guard let taskA = await store.createTask(title: "A", supervisorTask: "a") else {
            return XCTFail("task creation failed")
        }
        store.engineState[taskA] = .running
        await store.switchTask(to: taskA)

        sut.formState.enterAnswerMode(payload: answerPayload(taskID: taskA))
        sut.formState.answerText = "half an answer"

        sut.dismissPanel()
        XCTAssertNil(sut.formState.answerFieldsOwnerTaskID, "the dismiss released the bucket")
        XCTAssertEqual(sut.formState.answerText, "", "and cleared it")
        XCTAssertEqual(sut.formState._testAnswerDrafts[taskA]?.text, "half an answer",
            "precondition: the dismiss saved it rather than discarding it")

        // The question was answered elsewhere; the task is back to plain chat working.
        sut._testPresentPanelSync()

        XCTAssertEqual(sut.formState.answerText, "half an answer",
            "the chat composer binds the same bucket — the text belongs on screen")
        XCTAssertEqual(sut.formState.answerFieldsOwnerTaskID, taskA)
    }

    /// Why loading on an unclaimed arrival is safe rather than merely convenient: the only two
    /// writers that release the bucket clear its three fields in the same breath, so an unclaimed
    /// bucket is provably empty and a load can displace nothing.
    ///
    /// RED: stop clearing the three fields in either releaser (`exitAnswerMode` or
    /// `discardFolderScopedState`) → an unclaimed bucket keeps content, and the unclaimed-arrival
    /// load above turns from a restore into a clobber.
    func testAnUnclaimedBucket_isAlwaysEmpty() {
        let state = QuickCaptureFormState()

        state.enterAnswerMode(payload: SupervisorAnswerPayload(
            stepID: "s", taskID: 1, role: .softwareEngineer, roleDefinition: nil,
            question: "q", messageContent: nil, thinking: nil, isChatMode: true))
        state.answerText = "typed"
        state.answerClippedTexts = ["clip"]
        state.exitAnswerMode()

        XCTAssertNil(state.answerFieldsOwnerTaskID)
        XCTAssertEqual(state.answerText, "")
        XCTAssertTrue(state.answerAttachments.isEmpty)
        XCTAssertTrue(state.answerClippedTexts.isEmpty)

        state.claimAnswerFields(for: 2)
        state.answerText = "typed again"
        state.discardFolderScopedState()

        XCTAssertNil(state.answerFieldsOwnerTaskID)
        XCTAssertEqual(state.answerText, "")
    }

    /// The bucket already holding this task's content is the one arrival that must NOT reload:
    /// the live text is newer than the saved draft, and clobbering it would destroy the edit the
    /// user is in the middle of.
    ///
    /// RED: restore unconditionally in the arrival block → the live edit is replaced by the stale
    /// draft and this fails.
    func testArrivingAtTheTaskTheBucketAlreadyHolds_doesNotClobberTheLiveEdit() async {
        let sut = await makeWired()
        guard let taskA = await store.createTask(title: "A", supervisorTask: "a") else {
            return XCTFail("task creation failed")
        }
        store.engineState[taskA] = .running
        await store.switchTask(to: taskA)
        sut._testPresentPanelSync()
        sut._testIsPanelVisible = true

        // A stale draft exists for A, and the live composer has moved on past it.
        sut.formState.claimAnswerFields(for: taskA)
        sut.formState.answerText = "stale"
        sut.formState.captureLiveComposerAsAnswerDraft(taskID: taskA)
        sut.formState.answerText = "what the user is typing now"

        sut.refreshPanelIfVisible()

        XCTAssertEqual(sut.formState.answerText, "what the user is typing now",
            "the bucket already holds A's content — there is nothing to load back over it")
    }

    /// A non-chat working task binds no composer at all, so arriving there must neither claim the
    /// bucket nor load anything into it.
    ///
    /// RED: drop the `isChatMode` condition from the arrival block → the bucket is claimed for a
    /// task whose surface renders none of it.
    func testArrivingAtANonChatWorkingTask_leavesTheBucketAlone() async {
        let sut = await makeWired()
        guard let taskA = await store.createTask(title: "A", supervisorTask: "a") else {
            return XCTFail("task creation failed")
        }
        await store.mutateTask(taskID: taskA) { $0.setStoredChatMode(false) }
        store.engineState[taskA] = .running
        await store.switchTask(to: taskA)

        sut.formState.claimAnswerFields(for: 999)
        sut._testPresentPanelSync()

        XCTAssertEqual(sut.formState.answerFieldsOwnerTaskID, 999,
            "a loader-only surface has no composer to hand the bucket to")
    }
}
