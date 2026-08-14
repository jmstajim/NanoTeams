import Speech
import XCTest

@testable import NanoTeams

// MARK: - Shared doubles

/// Lets a test decide what `QuickCaptureController.resolveMode()` returns without
/// standing up an orchestrator, a task, and an engine state. The controller takes the
/// coordinator as an init seam precisely so the panel-refresh routing can be driven
/// independently of AppKit and of task storage.
@MainActor
private final class GPlatStubModeCoordinator: QuickCaptureModeCoordinator {
    var mode: QuickCaptureMode = .overlay
    func resolveMode(
        isTaskSelected _: Bool,
        activeTask _: NTMSTask?,
        engineState _: TeamEngineState?,
        activeTeam _: Team?,
        forceNewTaskMode _: Bool
    ) -> QuickCaptureMode {
        mode
    }
}

// MARK: - applyAnswerModeTransition — the "already in answer mode" arm

/// `QuickCaptureController.applyAnswerModeTransition`'s THIRD arm — the one that runs
/// when the panel is already in answer mode and the resolved mode is still
/// `.supervisorAnswer`. It is the whole of "Panel refresh on task switch": without it,
/// switching between two tasks that are BOTH waiting on the Supervisor leaves the panel
/// rendering the previous task's question, because the visual mode did not change and
/// nothing else re-reads the payload.
///
/// Driven through `refreshPanelIfVisible` (the production entry point) with a stubbed
/// mode coordinator, so no NSPanel, no orchestrator, and no engine are involved:
/// `updatePanelContent` skips gracefully when `panel`/`store`/`dictation` are unset.
@MainActor
final class GPlatAnswerModeTransitionTests: XCTestCase {

    private var coordinator: GPlatStubModeCoordinator!
    private var sut: QuickCaptureController!

    override func setUp() {
        super.setUp()
        // The process-global singleton is not used here, but a sibling class may have
        // left state on it; resetting keeps this class from being blamed for a crash
        // in someone else's leaked panel.
        QuickCaptureController.shared._testReset()
        coordinator = GPlatStubModeCoordinator()
        sut = QuickCaptureController(
            modeCoordinator: coordinator,
            formState: QuickCaptureFormState()
        )
    }

    override func tearDown() {
        sut = nil
        coordinator = nil
        QuickCaptureController.shared._testReset()
        super.tearDown()
    }

    private func payload(
        taskID: Int, question: String, stepID: String = "step"
    ) -> SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: stepID,
            taskID: taskID,
            role: .softwareEngineer,
            roleDefinition: nil,
            question: question,
            messageContent: nil,
            thinking: nil,
            isChatMode: false
        )
    }

    /// Task A → task B while both are waiting: the half-typed answer for A must be
    /// filed as A's draft and B must open with an EMPTY answer box.
    ///
    /// RED: replace `switchAnswerTask(from:to:)` with `updateAnswerPayload(payload)` →
    /// `supervisorTask` still holds "half-typed-for-A", so the answer the user was
    /// writing to task A is now sitting in task B's box, one Send away from being
    /// delivered to the wrong role. The empty-box assertion fails.
    func testRefresh_answerModeTaskSwitch_movesTheDraftInsteadOfLeakingIt() async {
        sut.formState.enterAnswerMode(payload: payload(taskID: 1, question: "A asks?"))
        sut.formState.answerText = "half-typed-for-A"
        sut._testIsPanelVisible = true

        coordinator.mode = .supervisorAnswer(payload: payload(taskID: 2, question: "B asks?"))
        sut.refreshPanelIfVisible()

        XCTAssertEqual(sut.formState.pendingAnswer?.taskID, 2,
                       "the panel must now be answering task B")
        XCTAssertEqual(sut.formState.pendingAnswer?.question, "B asks?")
        XCTAssertEqual(sut.formState.answerText, "",
                       "task B has no draft — its answer box must open empty, not carrying "
                       + "the text the user was writing to task A")
    }

    /// The other half of the same contract: the draft parked by the switch must come
    /// back when the user returns to that task.
    ///
    /// RED: drop the `saveCurrentAnswerDraft(taskID: oldTaskID)` call `switchAnswerTask`
    /// opens with (or route the arm to `updateAnswerPayload`) → returning to task A
    /// shows an empty box and the typed answer is gone.
    func testRefresh_answerModeSwitchBack_restoresTheParkedDraft() async {
        sut.formState.enterAnswerMode(payload: payload(taskID: 1, question: "A asks?"))
        sut.formState.answerText = "half-typed-for-A"
        sut._testIsPanelVisible = true

        coordinator.mode = .supervisorAnswer(payload: payload(taskID: 2, question: "B asks?"))
        sut.refreshPanelIfVisible()
        XCTAssertEqual(sut.formState.answerText, "", "premise: B opened empty")

        sut.formState.answerText = "half-typed-for-B"
        coordinator.mode = .supervisorAnswer(payload: payload(taskID: 1, question: "A asks again?"))
        // The visual mode is unchanged (.answer → .answer) and `store` is nil so
        // `taskChanged` is false — an explicit navigation is what re-enters the arm,
        // exactly as a sidebar re-selection does in production.
        sut.refreshPanelIfVisible(explicitTaskNavigation: true)

        XCTAssertEqual(sut.formState.pendingAnswer?.taskID, 1)
        XCTAssertEqual(sut.formState.answerText, "half-typed-for-A",
                       "returning to task A must restore the draft the switch parked")
    }

    /// Same task, new question — the payload must be refreshed in place and the
    /// in-progress answer left alone.
    ///
    /// RED: make the `else` arm a no-op (`{}`) → `pendingAnswer.question` stays
    /// "first question", which is the exact reported symptom: the panel keeps showing
    /// the previous question after the role asked a new one.
    func testRefresh_answerModeSameTask_refreshesPayloadAndKeepsTheTypedAnswer() async {
        sut.formState.enterAnswerMode(payload: payload(taskID: 7, question: "first question"))
        sut.formState.answerText = "still typing"
        sut._testIsPanelVisible = true

        coordinator.mode = .supervisorAnswer(
            payload: payload(taskID: 7, question: "second question", stepID: "step-2"))
        sut.refreshPanelIfVisible()

        XCTAssertEqual(sut.formState.pendingAnswer?.question, "second question",
                       "a new question on the SAME task must replace the stale payload")
        XCTAssertEqual(sut.formState.pendingAnswer?.stepID, "step-2")
        XCTAssertEqual(sut.formState.answerText, "still typing",
                       "a same-task payload refresh must not clear what the user is writing")
        XCTAssertTrue(sut._testIsInAnswerMode,
                      "the arm must not toggle the mode flag — it is an in-place update")
    }
}

// MARK: - createPanel callback wiring

/// `createPanel` wires three AppKit callbacks. The panel side of each is pinned by
/// `QuickCapturePanelCancelOperationTests` / the focus-retry suites, and the controller
/// side (`handlePanelHidden`, `cancelDraft`) is pinned directly — but the WIRING between
/// them was not. A callback pointed at the wrong method is silent: the panel disappears
/// and the controller still thinks it is on screen, so the next hotkey press "toggles"
/// an already-hidden panel and reads as a dead shortcut.
@MainActor
final class GPlatPanelCallbackWiringTests: XCTestCase {

    var sut: QuickCaptureController!

    override func setUp() {
        super.setUp()
        sut = QuickCaptureController.shared
        sut._testReset()
    }

    override func tearDown() {
        // Order the real NSPanel out before dropping the reference — `_testReset`
        // nils `panel` without hiding it.
        sut.dismissPanel()
        sut._testReset()
        sut = nil
        super.tearDown()
    }

    /// AppKit ordered the panel out by a route we did not initiate. The controller's
    /// visibility mirror must follow, or `togglePanel` takes its `.dismiss` branch on a
    /// panel that is already gone.
    ///
    /// RED: rewire `newPanel.onPanelHidden` to `{ }` (or to `self?.dismissPanel()`,
    /// which re-enters `panel.hide()`) → `_testIsPanelVisible` stays `true` and the
    /// assertion fails.
    func testCreatePanel_onPanelHidden_clearsTheControllerVisibilityMirror() async {
        sut._testPresentPanelSync()
        XCTAssertTrue(sut._testIsPanelVisible, "premise: the show pipeline marks it visible")
        XCTAssertNotNil(sut._testPanel, "premise: presentPanelSync created a panel")
        // Assert the callback EXISTS before invoking it — an optional-chained call on a
        // nil closure is a silent no-op, and the assertion below would then pass for the
        // wrong reason (the mirror was never true in the first place).
        XCTAssertTrue(sut._testPanel?.onPanelHidden != nil,
                      "createPanel must wire onPanelHidden")

        sut._testPanel?.onPanelHidden?()

        XCTAssertFalse(sut._testIsPanelVisible,
                       "an externally-ordered-out panel must leave the controller "
                       + "believing it is hidden, or the next hotkey press is a no-op")
    }

    /// Escape must route to `cancelDraft` — which discards the staged draft and CLEARS
    /// the form — not to the bare `dismissPanel`, which preserves the draft by design.
    ///
    /// RED: rewire `newPanel.onCancelKeyPressed` to `self?.dismissPanel()` (the pattern
    /// the comment above it warns against) → `supervisorTask` still reads
    /// "abandoned draft" and the first assertion fails.
    func testCreatePanel_onCancelKeyPressed_routesToCancelDraftNotBareDismiss() async {
        sut._testPresentPanelSync()
        sut.formState.supervisorTask = "abandoned draft"
        sut.formState.clippedTexts = ["a clip"]
        XCTAssertTrue(sut._testPanel?.onCancelKeyPressed != nil,
                      "createPanel must wire the AppKit Escape route")

        sut._testPanel?.onCancelKeyPressed?()

        XCTAssertEqual(sut.formState.supervisorTask, "",
                       "Escape is a cancel: the task draft must be cleared, which only "
                       + "`cancelDraft` does — `dismissPanel` deliberately preserves it")
        XCTAssertTrue(sut.formState.clippedTexts.isEmpty,
                      "clips are part of the discarded draft")
        XCTAssertFalse(sut._testIsPanelVisible, "cancelling also dismisses the overlay")
    }
}

// MARK: - Queue wake: the `.start` route

/// The `.done`-chat queue wake. `resumeRun` is useless for a chat task whose run already
/// ended — it re-enters the all-terminal run and bounces straight back to `.done`. The
/// `.start` mode exists to append a FRESH run whose step has no session, so the queued
/// message drains on iteration 1. Nothing pinned that `.start` actually starts anything:
/// the two production-facing lines (`performStartWake`'s `startRun` call and the Task
/// that dispatches it) were both unreached, because every existing test injects the
/// `startRunForTesting` seam that short-circuits them.
@MainActor
final class GPlatQueueStartWakeTests: NTMSOrchestratorTestBase {

    private var controller: QuickCaptureController!

    override func setUp() {
        super.setUp()
        QuickCaptureController.shared._testReset()
        controller = QuickCaptureController(formState: QuickCaptureFormState())
    }

    override func tearDown() {
        controller = nil
        QuickCaptureController.shared._testReset()
        super.tearDown()
    }

    private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 3.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !predicate() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Creates a chat-mode task and returns (id, run count before the wake).
    private func makeChatTask() async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "Chat", supervisorTask: "Talk")!
        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(true)
        }
        return taskID
    }

    /// `performStartWake` on a healthy, loaded, open task must APPEND a run. Its two
    /// bail-out arms (task will not load / task already closed) were both covered; the
    /// success line was not, so nothing verified that the wake does the one thing it
    /// exists for.
    ///
    /// RED: delete `await store.startRun(taskID: taskID)` → the run count is unchanged
    /// and the assertion fails.
    func testPerformStartWake_openTask_appendsAFreshRun() async {
        let taskID = await makeChatTask()
        controller.store = sut
        let before = sut.loadedTask(taskID)?.runs.count ?? -1
        XCTAssertGreaterThanOrEqual(before, 0, "premise: the task is loaded")

        await controller.performStartWake(
            taskID: taskID,
            newlyStampedIDs: Set(controller.formState.queuedMessages(for: taskID).map(\.id)))

        XCTAssertEqual(sut.loadedTask(taskID)?.runs.count, before + 1,
                       "the chat wake's whole purpose is a FRESH run — a fresh run's step "
                       + "has no session, which is what lets the queued message drain on "
                       + "iteration 1")
        XCTAssertNil(sut.loadedTask(taskID)?.closedAt)

        await sut.pauseRun(taskID: taskID)
        sut.stopEngineForTask(taskID)
    }

    /// End-to-end through the production dispatch: a queued message on a `.done`
    /// chat task must reach `performStartWake` via the un-stubbed `Task`, not via
    /// `resumeRun`.
    ///
    /// RED: point the `.start` case at `store.resumeRun(taskID:)` (what `.resume` does)
    /// → no run is appended and the wait times out on an unchanged run count.
    func testDoneChatTask_withQueuedMessage_dispatchesTheStartWakeForReal() async {
        let taskID = await makeChatTask()
        controller.store = sut
        // No `startRunForTesting` seam — this test is about the production dispatch.
        XCTAssertTrue(controller.startRunForTesting == nil,
                      "premise: the seam that short-circuits the production Task is unset")

        let before = sut.loadedTask(taskID)?.runs.count ?? -1
        let beforeLastRunID = sut.loadedTask(taskID)?.runs.last?.id
        sut.engineState[taskID] = .done
        controller.formState.appendQueuedMessage(
            QuickCaptureFormState.QueuedChatMessage(
                text: "keep talking", attachments: [], clippedTexts: [])!,
            for: taskID
        )

        controller.tryFlushQueuedMessages()
        await waitUntil { (self.sut.loadedTask(taskID)?.runs.count ?? -1) > before }

        XCTAssertEqual(sut.loadedTask(taskID)?.runs.count, before + 1,
                       "a chat task at `.done` is an ended turn, not a finished pipeline — "
                       + "a queued message must continue it with a new run")
        XCTAssertNotEqual(sut.loadedTask(taskID)?.runs.last?.id, beforeLastRunID,
                          "`.start` must APPEND a run, not re-enter the all-terminal one — "
                          + "`resumeRun` there executes no step and bounces back to `.done`")

        await sut.pauseRun(taskID: taskID)
        sut.stopEngineForTask(taskID)
    }
}

// MARK: - Backstop flush: undelivered batch is returned to the queue

/// The `.needsSupervisorInput` backstop's failure arm. Its doc names
/// "attachment finalize" as a trigger, and the existing suite says triggering the real
/// failure "is a race we can't simulate deterministically" — so it pinned the downstream
/// `prependQueuedMessages` helper instead and left the arm itself unreached. Attachment
/// finalization is not a race: a staged path with no file behind it fails every time.
@MainActor
final class GPlatBackstopFlushFailureTests: NTMSOrchestratorTestBase {

    private var controller: QuickCaptureController!

    override func setUp() {
        super.setUp()
        QuickCaptureController.shared._testReset()
        controller = QuickCaptureController(formState: QuickCaptureFormState())
    }

    override func tearDown() {
        controller = nil
        QuickCaptureController.shared._testReset()
        super.tearDown()
    }

    private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 3.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !predicate() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// RED: delete the `formState.prependQueuedMessages(popped, for: taskID)` line →
    /// the batch was popped before the await and is now lost, so the queue is empty and
    /// the restore assertions fail. RED (second mutation): delete the whole `if
    /// !delivered` block → the count-bearing banner never appears and the wait times out.
    func testBackstopFlush_whenDeliveryFails_returnsTheBatchAndSaysHowMany() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "G")!
        let roleID = "worker"

        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0)
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: roleID, name: "Worker",
                prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies()
            ))
            step.status = .needsSupervisorInput
            step.needsSupervisorInput = true
            step.supervisorQuestion = "What now?"
            run.steps = [step]
            task.runs = [run]
        }
        sut.engineState[taskID] = .needsSupervisorInput

        // A staged attachment whose staged file does not exist. `StagedAttachment.init`
        // only stats `url`, so the record is constructible; `finalizeAttachments` copies
        // from `stagedRelativePath`, which resolves inside the work folder and has
        // nothing behind it — `answerSupervisorQuestion` returns `false`.
        let anchor = tempDir.appendingPathComponent("anchor.txt")
        try "anchor".write(to: anchor, atomically: true, encoding: .utf8)
        let ghost = try StagedAttachment(
            url: anchor,
            stagedRelativePath: ".nanoteams/staged/ghost-draft/missing.txt",
            isProjectReference: false
        )

        let queued = try XCTUnwrap(QuickCaptureFormState.QueuedChatMessage(
            text: "please look at this",
            attachments: [ghost],
            clippedTexts: []
        ))
        controller.store = sut
        controller.formState.appendQueuedMessage(queued, for: taskID)

        controller.tryFlushQueuedMessages()
        await waitUntil { self.sut.lastErrorMessage?.contains("kept") == true }

        let banner = sut.lastErrorMessage ?? ""
        XCTAssertTrue(banner.contains("1 queued message(s) kept"),
                      "the user must be told how many messages survived the failure; got: \(banner)")
        XCTAssertEqual(controller.formState.queuedMessages(for: taskID).map(\.id), [queued.id],
                       "an undelivered batch must go BACK to the queue — it was popped "
                       + "synchronously before the await and is otherwise lost")
        XCTAssertNil(sut.loadedTask(taskID)?.runs.last?.steps.first?.supervisorAnswer,
                     "nothing was delivered, so no answer may be recorded against the step")
        XCTAssertTrue(sut.loadedTask(taskID)?.runs.last?.steps.first?.needsSupervisorInput ?? false,
                      "the role is still waiting — a failed delivery must not clear the gate")
    }
}

// MARK: - submitAnswer: embed failures are reported, not fatal

/// `createTask`'s embed-failure banner is covered; `submitAnswer`'s twin was not. The
/// two must behave the same way: report which files could not be embedded, and still
/// submit, because the user's typed answer is independent of the attachments.
@MainActor
final class GPlatSubmitAnswerEmbedFailureTests: NTMSOrchestratorTestBase {

    private var controller: QuickCaptureController!

    override func setUp() {
        super.setUp()
        QuickCaptureController.shared._testReset()
        controller = QuickCaptureController(formState: QuickCaptureFormState())
    }

    override func tearDown() {
        controller = nil
        QuickCaptureController.shared._testReset()
        super.tearDown()
    }

    /// RED: delete the `if !result.failedFiles.isEmpty { ... }` block → no banner, and
    /// the user silently sends an answer that references a file whose contents never
    /// made it into the prompt. RED (second mutation): turn that block into an early
    /// `return` → the answer is never delivered and `supervisorAnswer` stays nil.
    func testSubmitAnswer_unembeddableAttachment_bannersTheFileAndStillDelivers() async throws {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "G")!
        let stepID = "worker"

        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0)
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: stepID, name: "Worker",
                prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies()
            ))
            step.status = .needsSupervisorInput
            step.needsSupervisorInput = true
            step.supervisorQuestion = "Which file?"
            run.steps = [step]
            task.runs = [run]
        }

        // Not valid UTF-8 and not a format `DocumentTextExtractor` handles, so
        // `AnswerTextBuilder.embedSection` reports `.failed`. `.bin` is not an image
        // extension, so it is NOT silently skipped as binary either.
        let bad = tempDir.appendingPathComponent("bad.bin")
        try Data([0xFF, 0xFE, 0xFF, 0xFE]).write(to: bad)
        let staged = try XCTUnwrap(
            sut.stageAttachment(url: bad, draftID: controller.formState.draftID),
            "premise: the attachment stages"
        )
        sut.configuration.embedFilesInPrompt = true

        controller.store = sut
        controller.formState.enterAnswerMode(payload: SupervisorAnswerPayload(
            stepID: stepID, taskID: taskID, role: .softwareEngineer, roleDefinition: nil,
            question: "Which file?", messageContent: nil, thinking: nil, isChatMode: false))
        controller.formState.answerText = "the attached one"
        controller.formState.answerAttachments = [staged]

        await controller.submitAnswer()

        let banner = sut.lastErrorMessage ?? ""
        XCTAssertTrue(banner.contains("Could not embed 1 file(s)"),
                      "the count must be reported so the user knows the prompt is short "
                      + "one file; got: \(banner)")
        XCTAssertTrue(banner.contains("bad.bin"),
                      "and it must name the file, or there is nothing actionable; got: \(banner)")

        let step = sut.loadedTask(taskID)?.runs.last?.steps.first
        XCTAssertEqual(step?.supervisorAnswer, "the attached one",
                       "an unembeddable attachment must not block the answer — the typed "
                       + "text is independent of it")
        XCTAssertFalse(step?.needsSupervisorInput ?? true)
    }
}

// MARK: - The inert selection capturer

/// `InertSelectionCapturer` is the default the controller resolves INWARD to, so that a
/// test (or any bare construction) that forgets to inject a capturer gets "no selection"
/// instead of a synthesized ⌘C fired into whatever app is frontmost. The existing pin
/// calls `captureSelection` directly; nothing drove the real ⌃⌥⌘K route through it, which
/// is the route that also calls `requestAccessibilityIfNeeded()`.
@MainActor
final class GPlatInertSelectionCapturerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        QuickCaptureController.shared._testReset()
    }

    override func tearDown() {
        QuickCaptureController.shared._testReset()
        super.tearDown()
    }

    /// RED: change `init`'s `?? InertSelectionCapturer()` to `?? SystemSelectionCapturer()`
    /// → the type assertion fails (and the run would synthesize a real ⌘C).
    /// RED (second mutation): give `InertSelectionCapturer.captureSelection` any non-empty
    /// result → the clip lands in the task bucket and the "stages nothing" assertions fail.
    ///
    /// Honest limitation: `requestAccessibilityIfNeeded()`'s empty body has no in-process
    /// observable — a mutation that forwarded it to `ClipboardCaptureService` would raise
    /// a system Accessibility prompt, which no assertion here can see. This test pins the
    /// route reaching it and the outcome staying inert.
    func testCaptureRoute_withTheDefaultCapturer_stagesNothingAndSurfacesNoError() async {
        let bare = QuickCaptureController(formState: QuickCaptureFormState())
        XCTAssertTrue(bare.selectionCapturer is InertSelectionCapturer,
                      "a forgotten injection must not reach the real ⌘C synthesis")

        // The production route: `showPanel(withClip: true)` calls exactly this.
        await bare.captureClipboardContent(mode: .overlay)

        XCTAssertTrue(bare.formState.clippedTexts.isEmpty,
                      "an inert capture must stage no clip into the task draft")
        XCTAssertTrue(bare.formState.attachments.isEmpty)
        XCTAssertTrue(bare.formState.answerClippedTexts.isEmpty,
                      "and none into the answer draft either")
        XCTAssertTrue(bare.formState.answerAttachments.isEmpty)
    }

    /// Both protocol members must be inert, and calling them repeatedly must stay a
    /// no-op — the seam's safety argument is that a forgotten injection is *harmless*,
    /// not merely quiet once.
    ///
    /// RED: return a non-nil `text` (or a non-empty `fileURLs`) from
    /// `InertSelectionCapturer.captureSelection` → the emptiness assertions fail.
    func testInertCapturer_bothMembersAreSafeToCallRepeatedly() async {
        let capturer = InertSelectionCapturer()
        capturer.requestAccessibilityIfNeeded()
        capturer.requestAccessibilityIfNeeded()

        let first = await capturer.captureSelection(workFolderRoot: nil)
        let second = await capturer.captureSelection(
            workFolderRoot: URL(fileURLWithPath: "/tmp"))

        XCTAssertNil(first.text)
        XCTAssertTrue(first.fileURLs.isEmpty)
        XCTAssertFalse(first.restoreFailed,
                       "an inert capturer never touches the pasteboard, so it can never "
                       + "report a failed restore — that banner would be a lie")
        XCTAssertNil(second.text, "a work-folder root must not switch it on")
        XCTAssertTrue(second.fileURLs.isEmpty)
    }
}

// MARK: - The Speech-framework install seam

/// `SystemDictationAssetInventory` is the production conformance of the seam
/// `DictationModelInstaller` drives. Every installer test runs against a fake, so the
/// real adapter's two query/rollback members had no coverage at all — and both are
/// load-bearing: `isInstalled` is the "verify rather than trust" gate that decides
/// whether a nil installation request means "already installed" or "nothing was
/// installed", and `release` is the rollback that undoes a cancelled download.
///
/// Safe to run: `status(for:)` and `release(reservedLocale:)` are the same calls
/// `DictationModelCatalogQueryTests` and `DictationModelCatalogTests` already make.
/// Neither downloads anything, and releasing a locale this process never reserved is a
/// no-op by construction.
final class GPlatDictationInstallSeamTests: XCTestCase {

    private func skipIfUnavailable() throws {
        guard #unavailable(macOS 26, iOS 26, visionOS 26) else { return }
        throw XCTSkip("The dictation install seam requires macOS 26+.")
    }

    /// The gate `DictationModelInstaller.install` consults when Apple hands back a nil
    /// installation request. For an unsupported locale nothing can be installed, so it
    /// must answer `false` — answering `true` makes the installer `return` success and
    /// the user is left with dictation that silently does nothing, which is exactly the
    /// failure the "verify rather than trust" comment exists to prevent.
    ///
    /// RED: write the predicate as `!= .installed` (or return `true` unconditionally) →
    /// an unsupported locale reports installed and this fails.
    func testIsInstalled_unsupportedLocale_isFalse() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let locale = Locale(identifier: "xx_ZZ")
        let status = await DictationModelCatalog.status(for: locale)
        XCTAssertEqual(status, .unsupported, "premise: this locale has no model at all")

        let installed = await SystemDictationAssetInventory().isInstalled(locale: locale)
        XCTAssertFalse(installed,
                       "a locale with no model must never be reported as installed — the "
                       + "installer treats `true` as 'the nil request meant already done'")
    }

    /// The adapter must be a faithful projection of `status(for:)`, not an independent
    /// opinion. Asserted against the catalogue's own listing so it holds on a machine
    /// with models installed and on one without.
    ///
    /// RED: compare against `.downloading` or `.supported` instead of `.installed` →
    /// the two disagree for at least one locale on any machine with a model installed,
    /// and for every locale on one without.
    func testIsInstalled_agreesWithTheCatalogueForEveryLocale() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let infos = await DictationModelCatalog.allLocales()
        try XCTSkipIf(infos.isEmpty, "device reports no dictation locales")

        let inventory = SystemDictationAssetInventory()
        // Bounded: the full list is dozens of locales and each probe is a real query.
        for info in infos.prefix(4) {
            let adapter = await inventory.isInstalled(locale: info.locale)
            XCTAssertEqual(adapter, info.status == .installed,
                           "\(info.locale.identifier): the install seam and the Settings "
                           + "row must never disagree about whether a model is on disk")
        }
    }

    /// The rollback. `DictationModelInstaller` calls it on both cancellation paths, and
    /// its return value is the "was it actually reserved" answer the settings row uses.
    /// A locale this process never reserved must report `false` — reporting `true` would
    /// tell the UI a model was removed when nothing happened.
    ///
    /// RED: `return true` (or drop the delegation and return a literal) → this fails.
    func testRelease_neverReservedLocale_reportsNothingWasReleased() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let released = await SystemDictationAssetInventory()
            .release(reservedLocale: Locale(identifier: "xx_ZZ"))
        XCTAssertFalse(released,
                       "releasing a reservation that was never taken must be a no-op that "
                       + "says so, or the settings row claims an uninstall that never ran")
    }

    /// The adapter and the catalogue's own `uninstall` are the same operation reached by
    /// two names; the settings UI uses one and the installer's rollback uses the other.
    ///
    /// RED: point `SystemDictationAssetInventory.release` at anything other than
    /// `AssetInventory.release(reservedLocale:)` (e.g. return `true`) → the two answers
    /// diverge and this fails.
    func testRelease_matchesCatalogUninstallForTheSameLocale() async throws {
        try skipIfUnavailable()
        guard #available(macOS 26, iOS 26, visionOS 26, *) else { return }

        let locale = Locale(identifier: "qq_ZZ")
        let viaCatalog = await DictationModelCatalog.uninstall(locale: locale)
        let viaSeam = await SystemDictationAssetInventory().release(reservedLocale: locale)
        XCTAssertEqual(viaSeam, viaCatalog,
                       "the installer's rollback and the settings row's uninstall must be "
                       + "the same operation")
    }
}

// MARK: - AppUpdateState.lastCheckedAt

/// `lastCheckedAt` is the Updates tab's "last checked" line. It is a read-through to
/// `StoreConfiguration` on purpose: the timestamp survives relaunches there, and the
/// same field is what `refresh`'s throttle measures against. A snapshot taken in `init`
/// would compile, look right on launch, and then never move again.
@MainActor
final class GPlatAppUpdateLastCheckedTests: XCTestCase {

    private final class GPlatUnusedSession: NetworkSession, @unchecked Sendable {
        func sessionData(for _: URLRequest) async throws -> (Data, URLResponse) {
            throw URLError(.cannotConnectToHost)
        }
        func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            throw URLError(.cannotConnectToHost)
        }
    }

    /// RED: capture the value once in `init` (`self.lastCheckedAt = config.lastAppUpdateCheckAt`)
    /// → the second and third assertions read the stale snapshot and fail.
    /// RED (second mutation): return a constant `nil` → the second assertion fails.
    func testLastCheckedAt_readsThroughToConfigurationOnEveryAccess() async {
        let config = TestOrchestrator.makeConfiguration()
        config.lastAppUpdateCheckAt = nil
        let sut = AppUpdateState(
            checker: AppUpdateChecker(session: GPlatUnusedSession()),
            config: config
        )

        XCTAssertNil(sut.lastCheckedAt, "never checked → nothing to show")

        let first = Date(timeIntervalSince1970: 1_700_000_000)
        config.lastAppUpdateCheckAt = first
        XCTAssertEqual(sut.lastCheckedAt, first,
                       "a check recorded after construction must be visible — the value is "
                       + "owned by the configuration, not snapshotted at init")

        let second = Date(timeIntervalSince1970: 1_800_000_000)
        config.lastAppUpdateCheckAt = second
        XCTAssertEqual(sut.lastCheckedAt, second,
                       "and every subsequent check must move it, or the Updates tab shows "
                       + "a timestamp that stopped advancing")
    }

    /// The read-through must survive a relaunch, which is the reason it lives on
    /// `StoreConfiguration` at all: a second `AppUpdateState` over the same storage sees
    /// the timestamp the first one recorded.
    ///
    /// RED: drop the `storage.set(date, forKey:)` half of `lastAppUpdateCheckAt`'s
    /// `didSet` → the rehydrated configuration reports nil and this fails.
    func testLastCheckedAt_survivesReconstructionOverTheSameStorage() async {
        let storage = InMemoryConfigurationStorage()
        let stamp = Date(timeIntervalSince1970: 1_650_000_000)

        let first = StoreConfiguration(storage: storage)
        first.lastAppUpdateCheckAt = stamp

        let rehydrated = StoreConfiguration(storage: storage)
        let sut = AppUpdateState(
            checker: AppUpdateChecker(session: GPlatUnusedSession()),
            config: rehydrated
        )

        XCTAssertEqual(sut.lastCheckedAt, stamp,
                       "the 'last checked' line must persist across launches, or every "
                       + "restart re-arms a background probe that just ran")
    }
}
