import XCTest

@testable import NanoTeams

/// Wave 25 — one text field, three composers.
///
/// `QuickCaptureFormView` binds `formState.supervisorTask` from THREE bodies: `answerModeBody`,
/// `taskCreationBody` and `chatWorkingBody`. The two attachment/clip buckets beside it were split
/// per-purpose long ago (`answerAttachments` / `answerClippedTexts` vs `attachments` /
/// `clippedTexts`), and wave 23 wrote down which modes bind which pair — but the TEXT stayed
/// shared, and `savedSupervisorTask` existed only to stash one meaning while the field held
/// another.
///
/// A stash covers exactly the transition that takes it. Every other route between the two
/// meanings leaves the field holding content the arriving composer was not written for, and both
/// arriving composers have a live send button.
@MainActor
final class QuickCaptureComposerFieldOwnershipCoverageTests: XCTestCase {

    private var store: NTMSOrchestrator!
    private var controller: QuickCaptureController!
    private var workFolder: URL!

    override func setUp() async throws {
        try await super.setUp()
        QuickCaptureController.shared._testReset()
        workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-fields-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        controller = nil
        store = nil
        if let workFolder { try? FileManager.default.removeItem(at: workFolder) }
        workFolder = nil
        QuickCaptureController.shared._testReset()
        try await super.tearDown()
    }

    private func makeWired() async -> QuickCaptureController {
        let made = QuickCaptureController(formState: QuickCaptureFormState())
        store = TestOrchestrator.make()
        await store.openWorkFolder(workFolder)
        made.store = store
        made.dictation = nil
        made.isTaskSelected = true
        made._testIsPanelVisible = true
        controller = made
        return made
    }

    private func settleOnChatWorkingTask(_ sut: QuickCaptureController, taskID: Int) async {
        store.engineState[taskID] = .running
        await store.switchTask(to: taskID)
        sut._testLastRefreshedTaskID = taskID
        sut.refreshPanelIfVisible()
    }

    private func answerPayload(taskID: Int) -> SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: "s", taskID: taskID, role: .softwareEngineer, roleDefinition: nil,
            question: "Which framework?", messageContent: nil, thinking: nil, isChatMode: true)
    }

    // MARK: - The two meanings are separately addressable

    /// The structural claim, stated once: the field a composer binds is decided by what the
    /// composer is FOR, and the two purposes have two fields. Everything below is a route that
    /// used to violate it.
    ///
    /// RED: bind the answer composer back to `supervisorTask` → both properties move together
    /// and this fails.
    func testTheTaskDraftAndTheAnswerText_areSeparateFields() {
        let state = QuickCaptureFormState()

        state.supervisorTask = "a task I have not submitted"
        state.answerText = "a reply I am typing"

        XCTAssertEqual(state.supervisorTask, "a task I have not submitted")
        XCTAssertEqual(state.answerText, "a reply I am typing",
            "two composers, two purposes, two fields — neither may overwrite the other")
    }

    /// The submit gates read the field their own composer binds. Sharing made a task draft
    /// enable the chat composer's send button and vice versa.
    ///
    /// RED: point `canSubmit`'s answer/working arms back at `hasSubmittableText` → the
    /// task-draft-only case reports the chat composer as submittable and this fails.
    func testSubmitGates_readTheFieldTheirOwnComposerBinds() {
        let state = QuickCaptureFormState()
        let working = QuickCaptureMode.taskWorking(roleName: "Engineer", isChatMode: true)
        let answering = QuickCaptureMode.supervisorAnswer(payload: answerPayload(taskID: 1))

        state.supervisorTask = "a task I have not submitted"
        XCTAssertTrue(state.canSubmit(mode: .overlay))
        XCTAssertFalse(state.canSubmit(mode: working),
            "there is nothing to queue to the chat task — that text is a task draft")
        XCTAssertFalse(state.canSubmit(mode: answering),
            "and nothing to answer with")

        state.supervisorTask = ""
        state.answerText = "make it blue"
        XCTAssertFalse(state.canSubmit(mode: .overlay),
            "and the reverse: a half-typed chat message is not a task")
        XCTAssertTrue(state.canSubmit(mode: working))
        XCTAssertTrue(state.canSubmit(mode: answering))
    }

    // MARK: - The routes that leaked

    /// Panel opened on Watchtower, a task draft typed, panel dismissed; the user then opens it
    /// again while a chat task is running. `applyAnswerModeTransition`'s fourth arm only fires
    /// for working→working, so nothing touched the field — and `chatWorkingBody` rendered the
    /// task draft with a live Send aimed at the running task.
    ///
    /// RED: point `canSubmit`'s working arm back at `hasSubmittableText` → the send button goes
    /// live for a task draft aimed at the running chat task and this fails.
    func testANewTaskDraft_isNotOfferedToTheChatComposer() async {
        let sut = await makeWired()
        guard let task = await store.createTask(title: "T", supervisorTask: "t") else {
            return XCTFail("task creation failed")
        }
        XCTAssertTrue(store.loadedTask(task)?.isChatMode == true, "precondition: chat team")

        sut.formState.supervisorTask = "Refactor the parser"   // typed in overlay mode
        await settleOnChatWorkingTask(sut, taskID: task)

        let mode = sut._testResolveMode()
        guard case .taskWorking = mode else {
            return XCTFail("expected the chat-working composer")
        }
        XCTAssertEqual(sut.formState.answerText, "",
            "the chat composer starts empty; the task draft is not a message to this task")
        XCTAssertFalse(sut.formState.canSubmit(mode: mode),
            "and the send button aimed at this task has nothing to send")
        XCTAssertEqual(sut.formState.supervisorTask, "Refactor the parser",
            "and the draft is still there for whenever the user goes back to make the task")
    }

    /// The same route, all the way to the queue. The send button reads
    /// `submitQueuedMessageFromForm`, so a leak here is not a rendering detail — it enqueues.
    ///
    /// RED: have `submitQueuedMessageFromForm` read `supervisorTask` again → the task draft is
    /// queued to the chat task and this fails.
    func testANewTaskDraft_isNotQueuedToAChatTask() async {
        let sut = await makeWired()
        guard let task = await store.createTask(title: "T", supervisorTask: "t") else {
            return XCTFail("task creation failed")
        }

        sut.formState.supervisorTask = "Refactor the parser"
        await settleOnChatWorkingTask(sut, taskID: task)
        sut.submitQueuedMessageFromForm()

        XCTAssertTrue(sut.formState.queuedMessages(for: task).isEmpty,
            "a task the user never submitted must not become a message to a running task")
        XCTAssertEqual(sut.formState.supervisorTask, "Refactor the parser",
            "and the send press must not have consumed it either")
    }

    /// The reverse direction, which the stash never covered at all: a half-typed chat message
    /// left in the field while the user navigates to Watchtower, where `taskCreationBody` binds
    /// it and Send creates a task out of it.
    ///
    /// RED: bind `taskCreationBody` to a field the chat composer also writes → the chat text
    /// becomes a submittable task description and this fails.
    func testAChatMessageInProgress_isNotOfferedAsANewTaskDescription() async {
        let sut = await makeWired()
        guard let task = await store.createTask(title: "T", supervisorTask: "t") else {
            return XCTFail("task creation failed")
        }

        await settleOnChatWorkingTask(sut, taskID: task)
        sut.formState.answerText = "make it blue"

        sut.showNewTask()

        XCTAssertEqual(sut.formState.supervisorTask, "",
            "the new-task form opens empty; the chat message was never a task description")
        XCTAssertFalse(sut.formState.canSubmit(mode: .overlay))
    }

    /// The transition the stash DID cover, now covered by not touching anything. Leaving answer
    /// mode used to write `savedSupervisorTask` back over the field unconditionally, which is
    /// correct only when the destination is the task composer.
    ///
    /// RED: restore `savedSupervisorTask` into `supervisorTask` on exit → the answer round trip
    /// overwrites a draft typed while answering and this fails.
    func testAnsweringAndLeaving_leavesTheTaskDraftExactlyAsItWas() {
        let state = QuickCaptureFormState()
        state.supervisorTask = "Refactor the parser"

        state.enterAnswerMode(payload: answerPayload(taskID: 7))
        XCTAssertEqual(state.supervisorTask, "Refactor the parser",
            "entering answer mode does not need to move the task draft anywhere")
        state.answerText = "use SwiftUI"
        state.exitAnswerMode()

        XCTAssertEqual(state.supervisorTask, "Refactor the parser")
        XCTAssertEqual(state.answerText, "", "the answer field is cleared on the way out")
        XCTAssertEqual(state._testAnswerDrafts[7]?.text, "use SwiftUI",
            "and the unsent answer is kept per task, as before")
    }

    /// Both drafts alive at once — the state the shared field made unrepresentable.
    ///
    /// RED: share the field again → one of these two assertions must fail whichever way the
    /// sharing resolves.
    func testATaskDraftAndAnUnsentAnswer_coexist() {
        let state = QuickCaptureFormState()
        state.supervisorTask = "Refactor the parser"
        state.enterAnswerMode(payload: answerPayload(taskID: 7))
        state.answerText = "use SwiftUI"

        XCTAssertEqual(state.supervisorTask, "Refactor the parser")
        XCTAssertEqual(state.answerText, "use SwiftUI")
    }

    // MARK: - Who the live answer bucket belongs to

    /// Wave 24 moved the chat composer's content on a working→working task switch, and asked
    /// "was the PREVIOUS visual mode working?" to decide. That is a proxy for the real question —
    /// which task the live fields currently belong to — and the two come apart the moment the
    /// panel visits any other mode in between. Detour through the new-task form (navigate to
    /// Watchtower, or press ⌃⌥⌘0 there) and the hand-off stops firing, so the message typed for
    /// A is handed to B's send button exactly as before.
    ///
    /// RED: key the hand-off on `previousWasWorking` again → the detour skips it and A's message
    /// is in B's composer.
    func testAChatMessageSurvivesADetourThroughTheNewTaskForm_withoutFollowingTheNextTask() async {
        let sut = await makeWired()
        guard let taskA = await store.createTask(title: "A", supervisorTask: "a"),
              let taskB = await store.createTask(title: "B", supervisorTask: "b")
        else { return XCTFail("task creation failed") }

        await settleOnChatWorkingTask(sut, taskID: taskA)
        sut.formState.answerText = "for A only"

        // Detour: the user goes to the new-task form and back out again.
        sut.showNewTask()
        sut._testForceNewTaskMode = false

        store.engineState[taskB] = .running
        await store.switchTask(to: taskB)
        sut.refreshPanelIfVisible()

        XCTAssertEqual(sut.formState.answerText, "",
            "B's composer is not where A's message goes, however the panel got here")
        XCTAssertEqual(sut.formState._testAnswerDrafts[taskA]?.text, "for A only",
            "and A still has it")
    }

    /// The ownership claim is what makes the above work, and it must be dropped when the fields
    /// are emptied — otherwise a stale owner makes the next arriving composer save an empty draft
    /// for a task it has nothing to do with.
    ///
    /// RED: leave the owner set in `exitAnswerMode` → the nil assertion fails.
    func testTheLiveAnswerBucket_hasNoOwnerOnceItIsEmptied() {
        let state = QuickCaptureFormState()
        state.enterAnswerMode(payload: answerPayload(taskID: 4))
        XCTAssertEqual(state.answerFieldsOwnerTaskID, 4)

        state.exitAnswerMode()

        XCTAssertNil(state.answerFieldsOwnerTaskID)
    }

    // MARK: - Folder scope

    /// `discardFolderScopedState` keeps unsent task text (folder-agnostic — the task is created
    /// in whichever folder is open at submit) and drops everything keyed to a folder-local task
    /// id. The live answer text is the latter: it is a reply to a question asked by a task in the
    /// folder being closed.
    ///
    /// RED: leave `answerText` out of the discard → the reply to the old folder's task survives
    /// into the new folder's composer and this fails.
    func testDiscardingFolderScopedState_dropsTheAnswerTextAndKeepsTheTaskDraft() {
        let state = QuickCaptureFormState()
        state.supervisorTask = "Refactor the parser"
        state.enterAnswerMode(payload: answerPayload(taskID: 3))
        state.answerText = "yes, proceed"

        state.discardFolderScopedState()

        XCTAssertEqual(state.answerText, "",
            "an answer belongs to the task that asked, and that task is in the folder we left")
        XCTAssertEqual(state.supervisorTask, "Refactor the parser",
            "unsent task text outlives the folder — the task is created wherever we are next")
        XCTAssertFalse(state.isInAnswerMode)
    }

    // MARK: - Submission still consumes the right field

    /// End-to-end through the real submit path: answering clears the answer field and leaves the
    /// task draft alone.
    ///
    /// RED: have `submitAnswer` clear `supervisorTask` → the task draft is destroyed by an
    /// unrelated answer and this fails.
    func testSubmittingAnAnswer_clearsOnlyTheAnswerField() async {
        let sut = await makeWired()
        guard let task = await store.createTask(title: "T", supervisorTask: "t") else {
            return XCTFail("task creation failed")
        }
        await store.mutateTask(taskID: task) { t in
            var run = Run(id: 0)
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: "eng", name: "Engineer", prompt: "", toolIDs: [],
                usePlanningPhase: false, dependencies: RoleDependencies()))
            step.status = .needsSupervisorInput
            step.needsSupervisorInput = true
            step.supervisorQuestion = "Which framework?"
            run.steps.append(step)
            t.runs.append(run)
        }

        sut.formState.supervisorTask = "Refactor the parser"
        sut.formState.enterAnswerMode(payload: SupervisorAnswerPayload(
            stepID: "eng", taskID: task, role: .softwareEngineer, roleDefinition: nil,
            question: "Which framework?", messageContent: nil, thinking: nil, isChatMode: true))
        sut.formState.answerText = "SwiftUI"

        await sut.submitAnswer()

        XCTAssertEqual(sut.formState.answerText, "")
        XCTAssertEqual(sut.formState.supervisorTask, "Refactor the parser",
            "the task draft was never part of this submission")
    }
}
