import XCTest

@testable import NanoTeams

/// Wave 24 — who the content in the composer is FOR, and what the panel claims about it.
///
/// The chat-working composer and the answer composer bind the same three live fields
/// (`QuickCaptureMode.composerBindsAnswerBuckets`). Re-resolving the panel onto a different
/// task swaps which task those fields are read against without moving what is in them, so a
/// message typed for one task is submitted against another — silently, and through the send
/// button the user was already aiming at.
@MainActor
final class QuickCaptureComposerHandoffCoverageTests: XCTestCase {

    private var store: NTMSOrchestrator!
    private var controller: QuickCaptureController!
    private var workFolder: URL!

    override func setUp() async throws {
        try await super.setUp()
        QuickCaptureController.shared._testReset()
        workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-handoff-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - The pure decision

    private func chatWorking(_ isChatMode: Bool = true) -> QuickCaptureMode {
        .taskWorking(roleName: "Engineer", isChatMode: isChatMode)
    }

    private var anAnswer: QuickCaptureMode {
        .supervisorAnswer(payload: SupervisorAnswerPayload(
            stepID: "s", taskID: 2, role: .softwareEngineer, roleDefinition: nil,
            question: "?", messageContent: nil, thinking: nil, isChatMode: true))
    }

    /// The rule in one table. A hand-off is owed exactly when the live answer bucket already
    /// holds content for one task and the arriving chat composer belongs to another — the
    /// `.overlay` destination binds a different composer entirely, and the `.supervisorAnswer`
    /// destination loads its own draft inside `enterAnswerMode`.
    ///
    /// The row that used to read "overlay → chat working B" is gone, and its absence is the
    /// point: which surface came BEFORE is not part of the question. What the bucket holds does
    /// not change by being looked away from.
    ///
    /// RED: drop the `from != to` clause → the same-task row returns `.reassign` and this fails.
    func testHandoff_isOwedOnlyWhenAChatComposerChangesTask() {
        let cases: [(String, Int?, QuickCaptureMode, Int?, QuickCapturePresentationPolicy.ChatComposerHandoff)] = [
            ("bucket owned by A → chat working B", 1, chatWorking(), 2, .reassign(from: 1, to: 2)),
            ("bucket owned by A → chat working A", 1, chatWorking(), 1, .none),
            ("bucket owned by A → non-chat working B", 1, chatWorking(false), 2, .none),
            ("bucket owned by A → overlay", 1, .overlay, 2, .none),
            ("bucket owned by A → answer for B", 1, anAnswer, 2, .none),
            ("unclaimed bucket → chat working B", nil, chatWorking(), 2, .none),
            ("no arriving task → chat working", 1, chatWorking(), nil, .none),
        ]
        for (label, from, mode, to, expected) in cases {
            XCTAssertEqual(
                QuickCapturePresentationPolicy.chatComposerHandoff(
                    liveFieldsOwnerTaskID: from, resolvedMode: mode, newTaskID: to),
                expected, label)
        }
    }

    // MARK: - The wiring

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

    /// Puts the panel in chat-working mode for `taskID`, as if the user had been looking at it.
    private func settleOnChatWorkingTask(_ sut: QuickCaptureController, taskID: Int) async {
        store.engineState[taskID] = .running
        await store.switchTask(to: taskID)
        sut._testLastRefreshedTaskID = taskID
        sut.refreshPanelIfVisible()
    }

    /// Two running chat tasks, one composer. Switching from A to B left A's half-typed message
    /// in the fields the send button reads against `store.activeTaskID` — so pressing it queued
    /// A's message to B. Nothing in the three branches of `applyAnswerModeTransition` matched
    /// a working→working transition, so nothing moved.
    ///
    /// RED: remove the `.reassign` arm from `applyAnswerModeTransition` → A's text is still in
    /// the composer after the switch and this fails.
    func testSwitchingBetweenTwoChatTasks_doesNotCarryOnesMessageIntoTheOther() async {
        let sut = await makeWired()
        guard let taskA = await store.createTask(title: "A", supervisorTask: "a"),
              let taskB = await store.createTask(title: "B", supervisorTask: "b")
        else { return XCTFail("task creation failed") }
        XCTAssertTrue(store.loadedTask(taskA)?.isChatMode == true, "precondition: chat team")

        await settleOnChatWorkingTask(sut, taskID: taskA)
        sut.formState.answerText = "for A only"
        sut.formState.answerClippedTexts = ["A's clip"]

        store.engineState[taskB] = .running
        await store.switchTask(to: taskB)
        sut.refreshPanelIfVisible()

        XCTAssertEqual(sut.formState.answerText, "",
                       "the send button now reads these fields against task B; A's message must not be "
                           + "what it sends")
        XCTAssertEqual(sut.formState.answerClippedTexts, [])
    }

    /// The other half: what was typed for A is kept, and comes back when the user returns.
    /// Clearing without saving would be a different silent loss.
    ///
    /// RED: drop `captureLiveComposerAsAnswerDraft` from the arm and keep only the clear →
    /// returning to A finds an empty composer and this fails.
    func testSwitchingBackToTheFirstChatTask_bringsItsMessageBack() async {
        let sut = await makeWired()
        guard let taskA = await store.createTask(title: "A", supervisorTask: "a"),
              let taskB = await store.createTask(title: "B", supervisorTask: "b")
        else { return XCTFail("task creation failed") }

        await settleOnChatWorkingTask(sut, taskID: taskA)
        sut.formState.answerText = "for A only"

        store.engineState[taskB] = .running
        await store.switchTask(to: taskB)
        sut.refreshPanelIfVisible()
        await store.switchTask(to: taskA)
        sut.refreshPanelIfVisible()

        XCTAssertEqual(sut.formState.answerText, "for A only",
                       "the message was kept under the task it was typed for, and this is that task")
    }

    /// The same misfiling one arm over: a question arriving on ANOTHER task made
    /// `applyAnswerModeTransition` snapshot the live composer under the ARRIVING task's id, so
    /// the message typed for A was loaded straight back as the draft answer to B's question.
    ///
    /// RED: capture under `payload.taskID` again → the composer shows "for A only" while
    /// answering B and this fails.
    func testAQuestionOnAnotherTask_doesNotBecomeThisTasksAnswerDraft() async {
        let sut = await makeWired()
        guard let taskA = await store.createTask(title: "A", supervisorTask: "a"),
              let taskB = await store.createTask(title: "B", supervisorTask: "b")
        else { return XCTFail("task creation failed") }
        await store.mutateTask(taskID: taskB) { task in
            var run = Run(id: 0)
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: "eng", name: "Engineer", prompt: "", toolIDs: [],
                usePlanningPhase: false, dependencies: RoleDependencies()))
            step.status = .needsSupervisorInput
            step.needsSupervisorInput = true
            step.supervisorQuestion = "Which framework?"
            run.steps.append(step)
            task.runs.append(run)
        }

        await settleOnChatWorkingTask(sut, taskID: taskA)
        sut.formState.answerText = "for A only"

        await store.switchTask(to: taskB)
        sut.refreshPanelIfVisible()

        XCTAssertTrue(sut.formState.isInAnswerMode, "precondition: B's question took the panel")
        XCTAssertEqual(sut.formState.answerText, "",
                       "B's question gets an empty answer field, not the message meant for A")
        XCTAssertEqual(sut.formState._testAnswerDrafts[taskA]?.text, "for A only",
                       "and A keeps it")
    }

    // MARK: - What the overlay will accept

    /// ⌃⌥⌘K text capture files into `clippedTexts`, never into `supervisorTask` — so the panel
    /// opened showing a clip chip with the send button dead, for a submission that would have
    /// worked (`AnswerTextBuilder` folds clips into the task text, which is where the title is
    /// derived from). `hasTaskDraftContent` counted the same clip as content worth confirming
    /// the discard of; the two disagreed about whether a clip is anything.
    ///
    /// RED: return `hasSubmittableText` alone for `.overlay` → this fails.
    func testOverlaySubmit_isEnabledByACapturedClipAlone() {
        let state = QuickCaptureFormState()
        state.clippedTexts = ["\u{200B}// Source: a.swift:1-2\nlet x = 1"]

        XCTAssertTrue(state.canSubmit(mode: .overlay),
                      "the clip is the request; the hotkey that captured it is the whole point")
        XCTAssertTrue(state.hasTaskDraftContent, "precondition: already counted as content")
    }

    /// Whitespace is not a clip. Mirrors `hasTaskDraftContent`, which applies the same trim.
    ///
    /// RED: test only `!clippedTexts.isEmpty` → this fails.
    func testOverlaySubmit_ignoresAWhitespaceOnlyClip() {
        let state = QuickCaptureFormState()
        state.clippedTexts = ["   \n  "]

        XCTAssertFalse(state.canSubmit(mode: .overlay))
    }

    /// Attachments deliberately stay excluded: with no text and no clip the built task body is
    /// empty, `createPreparedTaskAndStart` can derive no title, and it returns nil without a
    /// word. Enabling the button there trades a dead button for a dead press.
    ///
    /// RED: widen `canSubmit(.overlay)` to `|| !attachments.isEmpty` → the button goes live for
    /// a draft that task creation refuses without a word, and this fails.
    func testOverlaySubmit_staysDisabledForAnAttachmentAlone() throws {
        let file = workFolder.appendingPathComponent("only.png")
        try Data("x".utf8).write(to: file)
        let state = QuickCaptureFormState()
        state.attachments = [try StagedAttachment(url: file, stagedRelativePath: "only.png")]

        XCTAssertFalse(state.canSubmit(mode: .overlay),
                       "no text and no clip means no title, and task creation refuses silently")
        XCTAssertTrue(state.hasTaskDraftContent,
                      "still content for the discard prompt — the two questions differ")
    }

    // MARK: - Who the working title names

    private func makeTeam() -> Team {
        Team(
            id: "t1", name: "Team",
            roles: [
                TeamRoleDefinition(id: "designer", name: "Designer", prompt: "", toolIDs: [],
                                   usePlanningPhase: false, dependencies: RoleDependencies()),
                TeamRoleDefinition(id: "eng", name: "Engineer", prompt: "", toolIDs: [],
                                   usePlanningPhase: false, dependencies: RoleDependencies()),
            ],
            artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())
    }

    /// The title and the queue target are supposed to be the same role — both are documented as
    /// going through `firstRunningStepRoleID`. They were not: when no step is running the title
    /// fell back to the team's FIRST role while the queue target fell back to nil (untargeted).
    /// So the panel said "Designer is thinking…" and the message went to whoever asked first.
    ///
    /// RED: restore the `?? fallbackName` arm → the title names Designer and this fails.
    func testWorkingTitle_namesNoRoleWhenNoStepIsRunning() {
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "G")
        task.setStoredChatMode(true)
        var run = Run(id: 0, teamID: "t1")
        var step = StepExecution.make(for: makeTeam().roles[1])
        step.status = .pending
        run.steps.append(step)
        task.runs.append(run)

        let mode = DefaultQuickCaptureModeCoordinator().resolveMode(
            isTaskSelected: true, activeTask: task, engineState: .running,
            activeTeam: makeTeam(), forceNewTaskMode: false)

        guard case .taskWorking(let roleName, _) = mode else {
            return XCTFail("expected working mode, got \(mode)")
        }
        XCTAssertEqual(roleName, "",
                       "no running step means no target; the form renders \"Thinking…\" for an empty "
                           + "name, which is the honest thing to say")
        XCTAssertNil(QuickCaptureController.firstRunningStepRoleID(in: task),
                     "precondition: this is exactly what the queue would target")
    }

    /// Counter-test: a real running step is still named. Without it the fix could degenerate
    /// into "never name a role", which loses the whole point of the title.
    ///
    /// RED: return "" unconditionally → this fails.
    func testWorkingTitle_namesTheRunningRole() {
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "G")
        task.setStoredChatMode(true)
        var run = Run(id: 0, teamID: "t1")
        var step = StepExecution.make(for: makeTeam().roles[1])
        step.status = .running
        run.steps.append(step)
        task.runs.append(run)

        let mode = DefaultQuickCaptureModeCoordinator().resolveMode(
            isTaskSelected: true, activeTask: task, engineState: .running,
            activeTeam: makeTeam(), forceNewTaskMode: false)

        guard case .taskWorking(let roleName, _) = mode else {
            return XCTFail("expected working mode, got \(mode)")
        }
        XCTAssertEqual(roleName, "Engineer")
        XCTAssertEqual(QuickCaptureController.firstRunningStepRoleID(in: task), "eng",
                       "title and queue target agree, which is the invariant the fallback broke")
    }
}
