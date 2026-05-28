import XCTest

@testable import NanoTeams

// MARK: - SupervisorAnswerPayload Tests

@MainActor
final class SupervisorAnswerPayloadTests: XCTestCase {

    func testPayloadStoresAllFields() {
        let stepID = "test_step"
        let taskID = 0
        let payload = SupervisorAnswerPayload(
            stepID: stepID,
            taskID: taskID,
            role: .softwareEngineer,
            roleDefinition: nil,
            question: "Which approach?",
            messageContent: "I analyzed the code.",
            thinking: "Let me think...",
            isChatMode: true
        )

        XCTAssertEqual(payload.stepID, stepID)
        XCTAssertEqual(payload.taskID, taskID)
        XCTAssertEqual(payload.role, .softwareEngineer)
        XCTAssertNil(payload.roleDefinition)
        XCTAssertEqual(payload.question, "Which approach?")
        XCTAssertEqual(payload.messageContent, "I analyzed the code.")
        XCTAssertEqual(payload.thinking, "Let me think...")
        XCTAssertTrue(payload.isChatMode)
    }

    func testPayloadWithNilOptionals() {
        let payload = SupervisorAnswerPayload(
            stepID: "test_step",
            taskID: Int(),
            role: .productManager,
            roleDefinition: nil,
            question: "Priority?",
            messageContent: nil,
            thinking: nil,
            isChatMode: false
        )

        XCTAssertNil(payload.messageContent)
        XCTAssertNil(payload.thinking)
        XCTAssertFalse(payload.isChatMode)
    }
}

// MARK: - QuickCaptureMode Tests

@MainActor
final class QuickCaptureModeTests: XCTestCase {

    func testOverlayMode() {
        let mode = QuickCaptureMode.overlay
        if case .overlay = mode { /* pass */ } else { XCTFail("Expected .overlay") }
    }

    func testSupervisorAnswerMode_carriesPayload() {
        let payload = SupervisorAnswerPayload(
            stepID: "test_step", taskID: Int(), role: .techLead, roleDefinition: nil,
            question: "Test?", messageContent: nil, thinking: nil, isChatMode: false
        )
        let mode = QuickCaptureMode.supervisorAnswer(payload: payload)

        if case .supervisorAnswer(let p) = mode {
            XCTAssertEqual(p.question, "Test?")
        } else {
            XCTFail("Expected .supervisorAnswer")
        }
    }

    func testTaskWorkingMode_carriesRoleName() {
        let mode = QuickCaptureMode.taskWorking(roleName: "Engineer", isChatMode: true)

        if case .taskWorking(let name, let chat) = mode {
            XCTAssertEqual(name, "Engineer")
            XCTAssertTrue(chat)
        } else {
            XCTFail("Expected .taskWorking")
        }
    }
}

// MARK: - QuickCaptureController State Tests

@MainActor
final class QuickCaptureControllerStateTests: XCTestCase {

    var sut: QuickCaptureController!

    override func setUp() {
        super.setUp()
        sut = QuickCaptureController.shared
        if sut._testIsInAnswerMode { sut._testExitAnswerMode() }
        sut.formState._testClearAnswerDrafts()
        sut.formState.supervisorTask = ""
        sut.formState.title = ""
        sut.formState.attachments = []
        sut.formState.clippedTexts = []
        sut.formState.answerAttachments = []
        sut.formState.answerClippedTexts = []
        sut.isTaskSelected = false
        sut._testForceNewTaskMode = false
    }

    override func tearDown() {
        if sut._testIsInAnswerMode { sut._testExitAnswerMode() }
        sut.formState.supervisorTask = ""
        sut.formState.title = ""
        sut.formState.attachments = []
        sut.formState.clippedTexts = []
        sut.formState.answerAttachments = []
        sut.formState.answerClippedTexts = []
        sut.isTaskSelected = false
        sut._testForceNewTaskMode = false
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.quickCaptureKeepOpenInChat)
        sut = nil
        super.tearDown()
    }

    func testInitialState() {
        XCTAssertFalse(sut.isPanelVisible)
        XCTAssertNil(sut.formState.pendingAnswer)
        XCTAssertTrue(sut.formState.answerAttachments.isEmpty)
        XCTAssertFalse(sut.isTaskSelected)
    }

    func testKeepOpenInChat_defaultTrue() {
        let key = UserDefaultsKeys.quickCaptureKeepOpenInChat
        UserDefaults.standard.removeObject(forKey: key)

        let hasKey = UserDefaults.standard.object(forKey: key) != nil
        let value = hasKey ? UserDefaults.standard.bool(forKey: key) : true
        XCTAssertTrue(value, "Default should be true when key doesn't exist")
    }

    func testKeepOpenInChat_persistsToUserDefaults() {
        let key = UserDefaultsKeys.quickCaptureKeepOpenInChat
        sut.keepOpenInChat = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))

        sut.keepOpenInChat = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
    }

    func testShowNewTask_clearsPendingAnswer() {
        sut.isTaskSelected = true
        sut.showNewTask()
        XCTAssertNil(sut.formState.pendingAnswer)
    }

    func testShowNewTask_exitsAnswerMode() {
        let payload = makePayload()
        sut._testEnterAnswerMode(.supervisorAnswer(payload: payload))
        XCTAssertTrue(sut._testIsInAnswerMode)

        sut.showNewTask()

        XCTAssertFalse(sut._testIsInAnswerMode)
        XCTAssertNil(sut.formState.pendingAnswer)
    }
}

// MARK: - Mode Resolution Tests

@MainActor
final class QuickCaptureModeResolutionTests: NTMSOrchestratorTestBase {

    var controller: QuickCaptureController!

    override func setUp() {
        super.setUp()
        controller = QuickCaptureController.shared
        controller.store = sut
        controller.isTaskSelected = false
        controller._testForceNewTaskMode = false
        controller.formState.supervisorTask = ""
    }

    override func tearDown() {
        controller.store = nil
        controller.isTaskSelected = false
        controller._testForceNewTaskMode = false
        controller.formState.supervisorTask = ""
        if controller._testIsInAnswerMode { controller._testExitAnswerMode() }
        controller = nil
        super.tearDown()
    }

    /// Creates a task with a run containing a step that needs supervisor input.
    private func createTaskWithQuestionStep(
        answer: String? = nil,
        attachmentPaths: [String] = []
    ) async -> (taskID: Int, stepID: String)? {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return nil
        }
        await sut.switchTask(to: taskID)

        let stepID = "test_step"
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: task.runs.first?.teamID ?? "test_team")
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: "eng", name: "Engineer",
                prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies()
            ))
            step.id = stepID
            step.needsSupervisorInput = true
            step.supervisorQuestion = "What should I do?"
            step.supervisorAnswer = answer
            step.supervisorAnswerAttachmentPaths = attachmentPaths
            step.status = .needsSupervisorInput
            run.steps.append(step)
            task.runs.append(run)
        }
        return (taskID, stepID)
    }

    // MARK: - resolveMode

    func testResolveMode_noTaskSelected_returnsOverlay() async {
        await sut.openWorkFolder(tempDir)
        controller.isTaskSelected = false

        let mode = controller._testResolveMode()
        if case .overlay = mode { /* pass */ } else { XCTFail("Expected .overlay") }
    }

    func testResolveMode_forceNewTaskMode_returnsOverlay() async {
        guard let _ = await createTaskWithQuestionStep() else { return }
        controller.isTaskSelected = true
        controller._testForceNewTaskMode = true

        let mode = controller._testResolveMode()
        if case .overlay = mode { /* pass */ } else { XCTFail("Expected .overlay when forceNewTaskMode") }
    }

    func testResolveMode_supervisorQuestion_returnsAnswerMode() async {
        guard let (taskID, stepID) = await createTaskWithQuestionStep() else { return }
        controller.isTaskSelected = true

        let mode = controller._testResolveMode()
        if case .supervisorAnswer(let payload) = mode {
            XCTAssertEqual(payload.stepID, stepID)
            XCTAssertEqual(payload.question, "What should I do?")
            XCTAssertEqual(payload.taskID, taskID)
        } else {
            XCTFail("Expected .supervisorAnswer")
        }
    }

    func testResolveMode_answeredQuestion_skipsAnswerMode() async {
        guard let _ = await createTaskWithQuestionStep(answer: "Do this") else { return }
        controller.isTaskSelected = true

        let mode = controller._testResolveMode()
        if case .supervisorAnswer = mode {
            XCTFail("Should not return .supervisorAnswer for already-answered question")
        }
    }

    func testResolveMode_usesEffectiveSupervisorAnswer() async {
        // supervisorAnswer=nil but has attachment paths → effectiveSupervisorAnswer is non-nil → skip
        guard let _ = await createTaskWithQuestionStep(
            answer: nil,
            attachmentPaths: ["attachments/file.txt"]
        ) else { return }
        controller.isTaskSelected = true

        let mode = controller._testResolveMode()
        if case .supervisorAnswer = mode {
            XCTFail("Should not return .supervisorAnswer when effectiveSupervisorAnswer is non-nil (has attachments)")
        }
    }

    func testResolveMode_engineRunning_returnsTaskWorking() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return
        }
        await sut.switchTask(to: taskID)
        controller.isTaskSelected = true
        sut.engineState[taskID] = .running

        let mode = controller._testResolveMode()
        if case .taskWorking = mode { /* pass */ } else { XCTFail("Expected .taskWorking") }
    }

    func testResolveMode_engineDone_returnsOverlay() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return
        }
        await sut.switchTask(to: taskID)
        controller.isTaskSelected = true
        sut.engineState[taskID] = .done

        let mode = controller._testResolveMode()
        if case .overlay = mode { /* pass */ } else { XCTFail("Expected .overlay") }
    }

    func testResolveMode_questionTakesPriorityOverRunning() async {
        // Both supervisor question AND engine running — question wins
        guard let (taskID, _) = await createTaskWithQuestionStep() else { return }
        controller.isTaskSelected = true
        sut.engineState[taskID] = .running

        let mode = controller._testResolveMode()
        if case .supervisorAnswer = mode { /* pass */ } else {
            XCTFail("Supervisor question should take priority over .running state")
        }
    }

    // MARK: - refreshPanelIfVisible + forceNewTaskMode

    /// Regression: after `showNewTask()` set `forceNewTaskMode = true` and the user
    /// then selects a task in the sidebar, `refreshPanelIfVisible` must cancel the
    /// flag so the panel reflects the newly-selected task instead of staying stuck
    /// on the new-task form.
    func testRefresh_switchingToTask_cancelsForceNewTaskMode() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return
        }
        await sut.switchTask(to: taskID)
        sut.engineState[taskID] = .running

        controller.isTaskSelected = true
        controller._testForceNewTaskMode = true
        controller._testLastRefreshedTaskID = nil
        controller._testIsPanelVisible = true
        defer { controller._testIsPanelVisible = false }

        controller.refreshPanelIfVisible()

        XCTAssertFalse(controller._testForceNewTaskMode,
                       "Navigating into a task should cancel force-new-task mode")
        if case .taskWorking = controller._testResolveMode() { /* pass */ } else {
            XCTFail("Expected .taskWorking after force flag cleared")
        }
    }

    /// Navigating to Watchtower (`activeTaskID == nil`) must NOT cancel
    /// `forceNewTaskMode` — the new-task form should remain visible after
    /// `showNewTask()` posts `.navigateToWatchtower`.
    func testRefresh_switchingToWatchtower_preservesForceNewTaskMode() async {
        await sut.openWorkFolder(tempDir)
        // Deselect any active task → activeTaskID becomes nil
        await sut.switchTask(to: nil)

        controller.isTaskSelected = false
        controller._testForceNewTaskMode = true
        controller._testLastRefreshedTaskID = 42  // Pretend we were on some task before
        controller._testIsPanelVisible = true
        defer { controller._testIsPanelVisible = false }

        controller.refreshPanelIfVisible()

        XCTAssertTrue(controller._testForceNewTaskMode,
                      "Navigating to Watchtower must preserve force-new-task mode")
        if case .overlay = controller._testResolveMode() { /* pass */ } else {
            XCTFail("Expected .overlay while force-new-task mode is preserved on Watchtower")
        }
    }

    /// Regression: the `taskChanged` part of the guard matters. If a refresh
    /// fires while the user is on the same task as last refresh (same taskID,
    /// `taskChanged == false`), `forceNewTaskMode` must survive — otherwise
    /// any passive refresh (engine-state tick, status change) would wipe the
    /// flag the user just set via `showNewTask()` on that same task.
    func testRefresh_sameTaskID_preservesForceNewTaskMode() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return
        }
        await sut.switchTask(to: taskID)

        controller.isTaskSelected = true
        controller._testForceNewTaskMode = true
        controller._testLastRefreshedTaskID = taskID  // Same task as before → taskChanged=false
        controller._testIsPanelVisible = true
        defer { controller._testIsPanelVisible = false }

        controller.refreshPanelIfVisible()

        XCTAssertTrue(controller._testForceNewTaskMode,
                      "Refresh on the same task must preserve force-new-task mode")
    }

    /// Explicit user navigation must clear `forceNewTaskMode` even when the
    /// re-selected task ID matches the last-refreshed task ID (so `taskChanged
    /// == false`). Without the explicit branch, the panel would stay stuck in
    /// `.newTask` after the user re-selects the currently-active task.
    func testRefresh_explicitTaskNavigation_clearsForceNewTaskModeEvenWhenTaskIDUnchanged() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return
        }
        await sut.switchTask(to: taskID)
        sut.engineState[taskID] = .running

        controller.isTaskSelected = true
        controller._testForceNewTaskMode = true
        controller._testLastRefreshedTaskID = taskID
        controller._testIsPanelVisible = true
        defer { controller._testIsPanelVisible = false }

        controller.refreshPanelIfVisible(explicitTaskNavigation: true)

        XCTAssertFalse(controller._testForceNewTaskMode,
                       "Explicit user navigation must clear force-new-task mode even on the same task")
        if case .taskWorking = controller._testResolveMode() { /* pass */ } else {
            XCTFail("Expected .taskWorking after explicit navigation clears the flag")
        }
    }

    /// `currentTaskID != nil` guard inside the clear branch must hold even under
    /// `explicitTaskNavigation: true`. Watchtower navigation (no active task)
    /// must NEVER clear `forceNewTaskMode`, otherwise pressing `+` while on a
    /// task X would lose the flag the moment `.navigateToWatchtower` lands
    /// (`store.activeTaskID` can also be nil if no task was ever active).
    func testRefresh_explicit_atWatchtowerWithNilActiveTask_preservesForceNewTaskMode() async {
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: nil)

        controller.isTaskSelected = false
        controller._testForceNewTaskMode = true
        controller._testLastRefreshedTaskID = 42
        controller._testIsPanelVisible = true
        defer { controller._testIsPanelVisible = false }

        controller.refreshPanelIfVisible(explicitTaskNavigation: true)

        XCTAssertTrue(controller._testForceNewTaskMode,
                      "Explicit navigation with no active task must NOT clear force-new-task mode")
        if case .overlay = controller._testResolveMode() { /* pass */ } else {
            XCTFail("Expected .overlay when forceNewTaskMode preserved on Watchtower")
        }
    }

    /// `isPanelVisible == false` is the load-bearing precondition of
    /// `refreshPanelIfVisible`. Even an explicit nav must early-return without
    /// touching `lastRefreshedTaskID` or `forceNewTaskMode` — otherwise an
    /// off-screen state mutation can desync the tracker for the next real refresh.
    func testRefresh_explicit_panelNotVisible_earlyReturnsWithoutMutation() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return
        }
        await sut.switchTask(to: taskID)

        let sentinel = 999
        controller.isTaskSelected = true
        controller._testForceNewTaskMode = true
        controller._testLastRefreshedTaskID = sentinel
        controller._testIsPanelVisible = false

        controller.refreshPanelIfVisible(explicitTaskNavigation: true)

        XCTAssertTrue(controller._testForceNewTaskMode,
                      "Hidden panel: explicit nav must not clear force-new-task mode")
        XCTAssertEqual(controller._testLastRefreshedTaskID, sentinel,
                       "Hidden panel: explicit nav must not update the tracker")
    }

    /// Explicit nav covers all task-state branches of `resolveMode`, not just
    /// `.taskWorking`. When the re-selected task has a pending Supervisor
    /// question (`.needsSupervisorInput` step + question text), the panel must
    /// land in answer mode after the flag clears.
    func testRefresh_explicit_resolvesToSupervisorAnswerForPendingQuestion() async {
        guard let (taskID, _) = await createTaskWithQuestionStep() else { return }

        controller.isTaskSelected = true
        controller._testForceNewTaskMode = true
        controller._testLastRefreshedTaskID = taskID
        controller._testIsPanelVisible = true
        defer { controller._testIsPanelVisible = false }

        controller.refreshPanelIfVisible(explicitTaskNavigation: true)

        XCTAssertFalse(controller._testForceNewTaskMode,
                       "Explicit nav must clear the flag regardless of resolved mode")
        if case .supervisorAnswer = controller._testResolveMode() { /* pass */ } else {
            XCTFail("Expected .supervisorAnswer when the re-selected task has a pending question")
        }
        XCTAssertTrue(controller._testIsInAnswerMode,
                      "applyAnswerModeTransition must have entered answer mode")
    }

    /// Idempotency: calling explicit nav when `forceNewTaskMode` was already
    /// `false` is a safe no-op. The flag stays `false`, no exception, mode
    /// resolves based on real state. This pins the "explicit nav can be called
    /// freely from any task-switch site without checking pre-conditions" contract.
    func testRefresh_explicit_whenFlagAlreadyFalse_isIdempotent() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return
        }
        await sut.switchTask(to: taskID)
        sut.engineState[taskID] = .running

        controller.isTaskSelected = true
        controller._testForceNewTaskMode = false
        controller._testLastRefreshedTaskID = taskID
        controller._testIsPanelVisible = true
        defer { controller._testIsPanelVisible = false }

        controller.refreshPanelIfVisible(explicitTaskNavigation: true)

        XCTAssertFalse(controller._testForceNewTaskMode,
                       "Flag stays false — explicit nav is idempotent when nothing to clear")
        if case .taskWorking = controller._testResolveMode() { /* pass */ } else {
            XCTFail("Expected .taskWorking — resolveMode reads real state, not the explicit flag")
        }
    }

    /// `lastRefreshedTaskID` must be updated even when the panel is visible and
    /// nothing else changes — otherwise a stale tracker from a previous panel
    /// session could mis-detect `taskChanged` on the next passive refresh after
    /// re-open. The unconditional assignment at the top of
    /// `refreshPanelIfVisible` is the contract.
    func testRefresh_explicit_updatesLastRefreshedTaskID() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return
        }
        await sut.switchTask(to: taskID)

        controller.isTaskSelected = true
        controller._testForceNewTaskMode = false
        controller._testLastRefreshedTaskID = nil
        controller._testIsPanelVisible = true
        defer { controller._testIsPanelVisible = false }

        controller.refreshPanelIfVisible(explicitTaskNavigation: true)

        XCTAssertEqual(controller._testLastRefreshedTaskID, taskID,
                       "Tracker must catch up to currentTaskID after any refresh, explicit or passive")
    }

    /// Isolates the `currentTaskID != nil` guard from `taskChanged`. Companion
    /// to `testRefresh_explicit_atWatchtowerWithNilActiveTask_…` which sets
    /// `lastRefreshedTaskID = 42` (so `taskChanged = true` and the test could
    /// pass under a buggy `taskChanged && (currentTaskID != nil || explicit)`
    /// rewrite). This test sets `lastRefreshedTaskID = nil` so `taskChanged
    /// == false` — the outer `currentTaskID != nil` guard is the only thing
    /// that can preserve the flag.
    func testRefresh_explicit_cleanWatchtowerEntry_preservesForceNewTaskMode() async {
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: nil)

        controller.isTaskSelected = false
        controller._testForceNewTaskMode = true
        // nil == nil → taskChanged == false. Distinguishes this case from the
        // sibling test where lastRefreshedTaskID is a non-nil sentinel.
        controller._testLastRefreshedTaskID = nil
        controller._testIsPanelVisible = true
        defer { controller._testIsPanelVisible = false }

        controller.refreshPanelIfVisible(explicitTaskNavigation: true)

        XCTAssertTrue(controller._testForceNewTaskMode,
                      "currentTaskID == nil must veto the clear regardless of taskChanged/explicit")
    }

    /// Symmetric to `testRefresh_explicit_resolvesToSupervisorAnswer…` which
    /// pins the .working → .answer transition under explicit nav. This pins
    /// the reverse: when the previously-asked question is resolved, explicit
    /// re-selection of the same task must exit answer mode. Without the
    /// `explicitTaskNavigation` bypass on the panel-update guard (line ~257),
    /// the same-task case (`taskChanged == false` AND
    /// `newVisualMode == currentVisualMode` only when the panel was already
    /// in answer mode → it isn't) would skip the transition.
    func testRefresh_explicit_exitsAnswerModeWhenQuestionResolved() async {
        guard let (taskID, _) = await createTaskWithQuestionStep() else { return }

        controller.isTaskSelected = true
        controller._testForceNewTaskMode = false
        controller._testLastRefreshedTaskID = taskID
        controller._testIsPanelVisible = true
        defer { controller._testIsPanelVisible = false }

        // Step 1: enter answer mode via the pending question.
        controller.refreshPanelIfVisible(explicitTaskNavigation: true)
        XCTAssertTrue(controller._testIsInAnswerMode,
                      "Setup: pending question must drive entry into answer mode")

        // Step 2: resolve the question by clearing the step's input flag,
        // then explicitly re-select the same task. resolveMode now returns
        // .taskWorking (chat) or .overlay (non-chat) — not .supervisorAnswer.
        await sut.mutateTask(taskID: taskID) { task in
            guard var run = task.runs.last else { return }
            for i in run.steps.indices {
                run.steps[i].needsSupervisorInput = false
                run.steps[i].supervisorQuestion = nil
            }
            task.runs.removeLast()
            task.runs.append(run)
        }
        sut.engineState[taskID] = .running

        controller.refreshPanelIfVisible(explicitTaskNavigation: true)

        XCTAssertFalse(controller._testIsInAnswerMode,
                       "Explicit re-selection after question resolved must exit answer mode")
    }

    /// Sequencing: after an explicit nav has cleared the flag, a subsequent
    /// passive refresh (engine tick) on the same task must NOT re-set the flag
    /// — `forceNewTaskMode` is only set by `showNewTask()` / `dismissPanel`.
    /// Pins that the clear is permanent until a fresh `+` press.
    func testRefresh_passiveAfterExplicit_doesNotReintroduceForceMode() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return
        }
        await sut.switchTask(to: taskID)
        sut.engineState[taskID] = .running

        controller.isTaskSelected = true
        controller._testForceNewTaskMode = true
        controller._testLastRefreshedTaskID = taskID
        controller._testIsPanelVisible = true
        defer { controller._testIsPanelVisible = false }

        // Explicit nav clears the flag.
        controller.refreshPanelIfVisible(explicitTaskNavigation: true)
        XCTAssertFalse(controller._testForceNewTaskMode)
        if case .taskWorking = controller._testResolveMode() { /* pass */ } else {
            XCTFail("Expected .taskWorking after explicit clear")
        }

        // Passive tick (engine status change emulation) — flag stays false, mode stable.
        controller.refreshPanelIfVisible()
        XCTAssertFalse(controller._testForceNewTaskMode,
                       "Passive refresh after explicit clear must not re-arm the flag")
        if case .taskWorking = controller._testResolveMode() { /* pass */ } else {
            XCTFail("Passive refresh must not perturb the resolved mode")
        }
    }
}

// MARK: - Answer Mode Transition Tests

@MainActor
final class QuickCaptureAnswerModeTests: XCTestCase {

    var sut: QuickCaptureController!

    override func setUp() {
        super.setUp()
        sut = QuickCaptureController.shared
        if sut._testIsInAnswerMode { sut._testExitAnswerMode() }
        sut.formState._testClearAnswerDrafts()
        sut.formState.supervisorTask = ""
        sut.formState.title = ""
        sut.formState.attachments = []
        sut.formState.clippedTexts = []
        sut.formState.answerAttachments = []
        sut.formState.answerClippedTexts = []
        sut.isTaskSelected = false
        sut._testForceNewTaskMode = false
    }

    override func tearDown() {
        if sut._testIsInAnswerMode { sut._testExitAnswerMode() }
        sut.formState.supervisorTask = ""
        sut.formState.title = ""
        sut.formState.attachments = []
        sut.formState.clippedTexts = []
        sut.formState.answerAttachments = []
        sut.formState.answerClippedTexts = []
        sut.isTaskSelected = false
        sut._testForceNewTaskMode = false
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.quickCaptureKeepOpenInChat)
        sut = nil
        super.tearDown()
    }

    func testEnterAnswerMode_savesGoalAndClearsAnswerField() {
        sut.formState.supervisorTask = "My task description"
        let payload = makePayload()

        sut._testEnterAnswerMode(.supervisorAnswer(payload: payload))

        XCTAssertTrue(sut._testIsInAnswerMode)
        XCTAssertEqual(sut._testSavedSupervisorTask, "My task description")
        // Answer field starts empty — user's task draft is preserved via
        // `savedSupervisorTask` and restored on exit, not leaked into the answer.
        XCTAssertEqual(sut.formState.supervisorTask, "")
        XCTAssertEqual(sut.formState.pendingAnswer?.question, "Test question?")
    }

    func testExitAnswerMode_restoresGoal() {
        sut.formState.supervisorTask = "Original goal"
        sut._testEnterAnswerMode(.supervisorAnswer(payload: makePayload()))
        // Answer field starts empty on entry.
        XCTAssertEqual(sut.formState.supervisorTask, "")

        sut._testExitAnswerMode()

        XCTAssertFalse(sut._testIsInAnswerMode)
        XCTAssertEqual(sut.formState.supervisorTask, "Original goal")
        XCTAssertNil(sut.formState.pendingAnswer)
        XCTAssertNil(sut._testSavedSupervisorTask)
        XCTAssertTrue(sut.formState.answerAttachments.isEmpty)
    }

    func testEnterAnswerMode_withNonAnswerMode_doesNothing() {
        sut.formState.supervisorTask = "Keep this"

        sut._testEnterAnswerMode(.overlay)

        XCTAssertFalse(sut._testIsInAnswerMode)
        XCTAssertEqual(sut.formState.supervisorTask, "Keep this")
        XCTAssertNil(sut.formState.pendingAnswer)
    }

    func testExitAnswerMode_withNilSavedGoal_restoresEmpty() {
        sut.formState.supervisorTask = ""
        sut._testEnterAnswerMode(.supervisorAnswer(payload: makePayload()))

        sut._testExitAnswerMode()
        XCTAssertEqual(sut.formState.supervisorTask, "")
    }

    func testCancelDraft_inAnswerMode_exitsWithoutClearingTaskForm() {
        sut.formState.supervisorTask = "Task in progress"
        sut.formState.title = "My Title"
        sut._testEnterAnswerMode(.supervisorAnswer(payload: makePayload()))

        sut.cancelDraft()

        XCTAssertFalse(sut._testIsInAnswerMode)
        XCTAssertEqual(sut.formState.supervisorTask, "Task in progress")
        XCTAssertEqual(sut.formState.title, "My Title")
    }

    func testCancelDraft_inTaskMode_clearsFormState() {
        sut.formState.supervisorTask = "Some goal"
        sut.formState.title = "Some title"

        sut.cancelDraft()

        XCTAssertEqual(sut.formState.supervisorTask, "")
        XCTAssertEqual(sut.formState.title, "")
    }

    // MARK: - Answer Mode Clips

    func testAnswerClippedTexts_initiallyEmpty() {
        XCTAssertTrue(sut.formState.answerClippedTexts.isEmpty)
    }

    func testAnswerClippedTexts_appendedInAnswerMode() {
        sut._testEnterAnswerMode(.supervisorAnswer(payload: makePayload()))

        sut.formState.answerClippedTexts.append("clipped code snippet")

        XCTAssertEqual(sut.formState.answerClippedTexts.count, 1)
        XCTAssertEqual(sut.formState.answerClippedTexts.first, "clipped code snippet")
        // Goal should remain empty — clips don't go to supervisorTask
        XCTAssertEqual(sut.formState.supervisorTask, "")
    }

    func testAnswerClippedTexts_multipleClips() {
        sut._testEnterAnswerMode(.supervisorAnswer(payload: makePayload()))

        sut.formState.answerClippedTexts.append("first clip")
        sut.formState.answerClippedTexts.append("second clip")

        XCTAssertEqual(sut.formState.answerClippedTexts.count, 2)
    }

    func testExitAnswerMode_clearsAnswerClippedTexts() {
        sut._testEnterAnswerMode(.supervisorAnswer(payload: makePayload()))
        sut.formState.answerClippedTexts.append("some clip")

        sut._testExitAnswerMode()

        XCTAssertTrue(sut.formState.answerClippedTexts.isEmpty)
    }

    func testCancelDraft_inAnswerMode_clearsAnswerClippedTexts() {
        sut._testEnterAnswerMode(.supervisorAnswer(payload: makePayload()))
        sut.formState.answerClippedTexts.append("will be discarded")

        sut.cancelDraft()

        XCTAssertTrue(sut.formState.answerClippedTexts.isEmpty)
    }

    func testAnswerClippedTexts_separateFromTaskClippedTexts() {
        sut.formState.clippedTexts = ["task clip"]
        sut._testEnterAnswerMode(.supervisorAnswer(payload: makePayload()))
        sut.formState.answerClippedTexts.append("answer clip")

        XCTAssertEqual(sut.formState.clippedTexts, ["task clip"])
        XCTAssertEqual(sut.formState.answerClippedTexts, ["answer clip"])

        sut._testExitAnswerMode()

        // Task clips preserved, answer clips cleared
        XCTAssertEqual(sut.formState.clippedTexts, ["task clip"])
        XCTAssertTrue(sut.formState.answerClippedTexts.isEmpty)
    }
}

// MARK: - Answer Supervisor Question Resume Tests

@MainActor
final class AnswerSupervisorQuestionResumeTests: NTMSOrchestratorTestBase {

    private func createTaskWithSupervisorQuestion(answer: String? = nil) async -> (Int, String)? {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(
            title: "Test", supervisorTask: "Goal"
        ) else {
            XCTFail("Failed to create task")
            return nil
        }
        await sut.switchTask(to: taskID)

        let stepID = "test_step"
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: task.runs.first?.teamID ?? "test_team")
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: "assistant", name: "Assistant",
                prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies()
            ))
            step.id = stepID
            step.needsSupervisorInput = true
            step.supervisorQuestion = "What to do?"
            step.supervisorAnswer = answer
            step.status = .needsSupervisorInput
            run.steps.append(step)
            task.runs.append(run)
        }
        return (taskID, stepID)
    }

    func testAnswerSupervisorQuestion_setsAnswerOnStep() async {
        guard let (taskID, stepID) = await createTaskWithSupervisorQuestion() else { return }

        let success = await sut.answerSupervisorQuestion(
            stepID: stepID, taskID: taskID, answer: "Do this"
        )

        XCTAssertTrue(success)
        let step = sut.activeTask?.runs.last?.steps.first(where: { $0.id == stepID })
        XCTAssertEqual(step?.supervisorAnswer, "Do this")
        XCTAssertFalse(step?.needsSupervisorInput ?? true)
    }

    func testAnswerSupervisorQuestion_emptyAnswer_setsNilAnswer() async {
        guard let (taskID, stepID) = await createTaskWithSupervisorQuestion() else { return }

        await sut.answerSupervisorQuestion(
            stepID: stepID, taskID: taskID, answer: ""
        )

        let step = sut.activeTask?.runs.last?.steps.first(where: { $0.id == stepID })
        XCTAssertNil(step?.supervisorAnswer)
    }

    func testAnswerSupervisorQuestion_returnsTrueOnSuccess() async {
        guard let (taskID, stepID) = await createTaskWithSupervisorQuestion() else { return }

        let result = await sut.answerSupervisorQuestion(
            stepID: stepID, taskID: taskID, answer: "Answer"
        )
        XCTAssertTrue(result)
    }
}

// MARK: - Team Selection Fallback Tests

@MainActor
final class QuickCaptureTeamSelectionTests: NTMSOrchestratorTestBase {

    var controller: QuickCaptureController!

    /// Remembered across the test so `tearDown` can restore the real user
    /// preference after forcing it off in `setUp`.
    private var savedKeepOpenInChat: Bool!

    override func setUp() {
        super.setUp()
        controller = QuickCaptureController.shared
        controller.store = sut
        controller.formState.selectedTeamID = nil
        controller.formState.supervisorTask = "Test goal"
        controller.formState.title = ""
        controller.formState.attachments = []
        controller.formState.clippedTexts = []
        // The default first team (Personal Assistant) is chat-mode. With the
        // UserDefaults-backed `keepOpenInChat` defaulting to true on fresh CI
        // runners, `createTask` would take the keep-open branch that requires
        // a dictation instance set via `setup(store:dictation:)`. These tests
        // only verify team resolution, not the panel-content refresh path, so
        // force the non-chat post-create branch (dismissPanel).
        savedKeepOpenInChat = controller.keepOpenInChat
        controller.keepOpenInChat = false
    }

    override func tearDown() {
        controller.formState.selectedTeamID = nil
        controller.formState.supervisorTask = ""
        controller.formState.title = ""
        controller.store = nil
        controller.keepOpenInChat = savedKeepOpenInChat
        savedKeepOpenInChat = nil
        controller = nil
        super.tearDown()
    }

    /// When selectedTeamID is nil and activeTeamID is nil, task creation should
    /// still use the first team (via repository fallback) and set isChatMode correctly.
    func testCreateTask_nilSelectedTeamID_nilActiveTeamID_usesFirstTeam() async {
        await sut.openWorkFolder(tempDir)

        // Clear activeTeamID to simulate fresh state
        await sut.mutateWorkFolder { workFolder in
            workFolder.activeTeamID = nil
        }

        XCTAssertNil(sut.snapshot?.workFolder.activeTeamID)
        let firstTeam = sut.snapshot?.workFolder.teams.first
        XCTAssertNotNil(firstTeam)

        controller.formState.selectedTeamID = nil

        // Create task via controller — selectedTeamID=nil, activeTeamID=nil
        await controller.createTask()

        // Task should have been created with the first team's isChatMode
        let task = sut.activeTask
        XCTAssertNotNil(task, "Task should be created even with nil team IDs")
        XCTAssertEqual(task?.isChatMode, firstTeam?.isChatMode,
                       "isChatMode should match first team's isChatMode")
    }

    /// When selectedTeamID is nil and activeTeamID is nil, but the first team is
    /// chat-mode, the task should be created with isChatMode=true.
    func testCreateTask_nilTeamIDs_chatModeFirstTeam_detectsChatMode() async {
        await sut.openWorkFolder(tempDir)

        // Replace all teams with a single chat-mode team (supervisor has no required artifacts)
        await sut.mutateWorkFolder { workFolder in
            let supervisor = TeamRoleDefinition(
                id: "supervisor", name: "Supervisor",
                prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies(), systemRoleID: "supervisor"
            )
            let assistant = TeamRoleDefinition(
                id: "assistant", name: "Assistant",
                prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies()
            )
            let chatTeam = Team(
                id: "chat_team", name: "Chat Team",
                roles: [supervisor, assistant], artifacts: [],
                settings: TeamSettings(), graphLayout: TeamGraphLayout()
            )
            workFolder.teams = [chatTeam]
            workFolder.activeTeamID = nil
        }

        XCTAssertNil(sut.snapshot?.workFolder.activeTeamID)
        XCTAssertTrue(sut.snapshot?.workFolder.teams.first?.isChatMode ?? false)

        controller.formState.selectedTeamID = nil
        controller.formState.supervisorTask = "Chat goal"

        await controller.createTask()

        let task = sut.activeTask
        XCTAssertNotNil(task, "Task should be created")
        XCTAssertTrue(task?.isChatMode ?? false, "isChatMode should be true for chat-mode first team")
    }

    /// When selectedTeamID is explicitly set, it should override any fallback.
    func testCreateTask_explicitSelectedTeamID_usesSelectedTeam() async {
        await sut.openWorkFolder(tempDir)

        let teams = sut.snapshot?.workFolder.teams ?? []
        guard teams.count >= 2 else {
            XCTFail("Need at least 2 teams for this test")
            return
        }
        let secondTeam = teams[1]

        controller.formState.selectedTeamID = secondTeam.id
        controller.formState.supervisorTask = "Test"

        await controller.createTask()

        let task = sut.activeTask
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.preferredTeamID, secondTeam.id)
    }
}

// MARK: - Chat-Working ↔ Answer Mode Composer Preservation

/// Drives `applyAnswerModeTransition` via `refreshPanelIfVisible` to verify that the
/// composer's text / attachments / clips survive `.taskWorking` (chat) ↔ `.supervisorAnswer`
/// transitions for the same task. See plan in `recursive-hopping-cocke.md` and
/// CLAUDE.md "Quick Capture System" section.
@MainActor
final class QuickCaptureChatWorkingComposerTests: NTMSOrchestratorTestBase {

    var controller: QuickCaptureController!

    override func setUp() {
        super.setUp()
        controller = QuickCaptureController.shared
        controller.store = sut
        if controller._testIsInAnswerMode { controller._testExitAnswerMode() }
        controller.formState._testClearAnswerDrafts()
        controller.formState.supervisorTask = ""
        controller.formState.title = ""
        controller.formState.attachments = []
        controller.formState.clippedTexts = []
        controller.formState.answerAttachments = []
        controller.formState.answerClippedTexts = []
        controller.isTaskSelected = false
        controller._testForceNewTaskMode = false
    }

    override func tearDown() {
        if controller._testIsInAnswerMode { controller._testExitAnswerMode() }
        controller.formState._testClearAnswerDrafts()
        controller.formState.supervisorTask = ""
        controller.formState.answerAttachments = []
        controller.formState.answerClippedTexts = []
        controller.isTaskSelected = false
        controller._testForceNewTaskMode = false
        controller._testIsPanelVisible = false
        controller._testLastRefreshedTaskID = nil
        controller.store = nil
        controller = nil
        super.tearDown()
    }

    /// Creates a chat-mode task in `.running`, drives `refreshPanelIfVisible` once so
    /// `currentVisualMode` becomes `.working`. Returns the taskID.
    private func setUpChatWorkingPanel() async -> Int? {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return nil
        }
        await sut.switchTask(to: taskID)
        // Default team for fresh work folder is the chat-mode Coding Assistant.
        guard sut.activeTask?.isChatMode == true else {
            XCTFail("Default team should be chat-mode (Coding Assistant)"); return nil
        }
        sut.engineState[taskID] = .running
        controller.isTaskSelected = true
        controller._testIsPanelVisible = true
        controller._testLastRefreshedTaskID = taskID
        controller.refreshPanelIfVisible()
        return taskID
    }

    /// Mutates the active run to add a step that needs supervisor input. Triggers the
    /// `.taskWorking` → `.supervisorAnswer` transition on the next `refreshPanelIfVisible`.
    private func addSupervisorQuestionStep(taskID: Int, stepID: String = "q_step") async {
        await sut.mutateTask(taskID: taskID) { task in
            var run: Run
            if let last = task.runs.last {
                run = last
                task.runs.removeLast()
            } else {
                run = Run(id: 0, teamID: task.preferredTeamID ?? "test_team")
            }
            var step = StepExecution.make(for: TeamRoleDefinition(
                id: "assistant", name: "Assistant",
                prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies()
            ))
            step.id = stepID
            step.needsSupervisorInput = true
            step.supervisorQuestion = "Pick one?"
            step.status = .needsSupervisorInput
            run.steps.append(step)
            task.runs.append(run)
        }
    }

    private func makeStagedAttachment(name: String) throws -> StagedAttachment {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QCControllerTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name, isDirectory: false)
        try "stub".write(to: url, atomically: true, encoding: .utf8)
        return try StagedAttachment(url: url, stagedRelativePath: "draft/\(name)")
    }

    func testTransition_chatWorkingToAnswerMode_preservesComposerState() async throws {
        guard let taskID = await setUpChatWorkingPanel() else { return }

        let attachment = try makeStagedAttachment(name: "spec.txt")
        controller.formState.supervisorTask = "in-progress msg"
        controller.formState.answerAttachments = [attachment]
        controller.formState.answerClippedTexts = ["clip-A"]

        await addSupervisorQuestionStep(taskID: taskID)
        controller.refreshPanelIfVisible()

        XCTAssertTrue(controller._testIsInAnswerMode,
                      "Engine .needsSupervisorInput should drive the panel into answer mode")
        XCTAssertEqual(controller.formState.supervisorTask, "in-progress msg",
                       "Composer text must survive the .working → .answer transition")
        XCTAssertEqual(controller.formState.answerAttachments, [attachment],
                       "Attachments must survive the transition")
        XCTAssertEqual(controller.formState.answerClippedTexts, ["clip-A"],
                       "Clips must survive the transition")
    }

    func testTransition_answerModeToChatWorking_restoresComposerState() async throws {
        guard let taskID = await setUpChatWorkingPanel() else { return }

        let attachment = try makeStagedAttachment(name: "doc.txt")
        controller.formState.supervisorTask = "msg"
        controller.formState.answerAttachments = [attachment]
        controller.formState.answerClippedTexts = ["c1"]

        await addSupervisorQuestionStep(taskID: taskID)
        controller.refreshPanelIfVisible()
        XCTAssertTrue(controller._testIsInAnswerMode)

        // Engine returns to .running (e.g. queue flush or external resume) — the question
        // disappears. We model it by clearing the step and switching engine back to .running.
        await sut.mutateTask(taskID: taskID) { task in
            guard var run = task.runs.last else { return }
            run.steps.removeAll()
            task.runs.removeLast()
            task.runs.append(run)
        }
        sut.engineState[taskID] = .running
        controller.refreshPanelIfVisible()

        XCTAssertFalse(controller._testIsInAnswerMode,
                       "Returning to .running with no question must exit answer mode")
        XCTAssertEqual(controller.formState.supervisorTask, "msg",
                       "Composer text must be restored from the saved draft")
        XCTAssertEqual(controller.formState.answerAttachments, [attachment],
                       "Attachments must be restored from the saved draft")
        XCTAssertEqual(controller.formState.answerClippedTexts, ["c1"],
                       "Clips must be restored from the saved draft")
    }

    func testTransition_chatWorkingToAnswerMode_nonChatTask_doesNotCaptureDraft() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return
        }
        await sut.switchTask(to: taskID)
        // Force the task to non-chat mode regardless of the default team.
        await sut.mutateTask(taskID: taskID) { task in
            task.setStoredChatMode(false)
        }
        XCTAssertFalse(sut.activeTask?.isChatMode ?? true)

        sut.engineState[taskID] = .running
        controller.isTaskSelected = true
        controller._testIsPanelVisible = true
        controller._testLastRefreshedTaskID = taskID
        controller.refreshPanelIfVisible()

        // Pre-seed `supervisorTask` with a stale value (would happen if the user typed
        // it earlier in `.newTask` and then navigated to this running non-chat task).
        controller.formState.supervisorTask = "stale new-task draft"
        controller.formState.answerAttachments = []
        controller.formState.answerClippedTexts = []

        await addSupervisorQuestionStep(taskID: taskID)
        controller.refreshPanelIfVisible()

        XCTAssertTrue(controller._testIsInAnswerMode)
        XCTAssertNil(controller.formState._testAnswerDrafts[taskID],
                     "Non-chat task transition must NOT capture live composer into answerDrafts (payload.isChatMode gate)")
    }

    /// Regression: after capturing chat-working composer into the answer draft, the
    /// branch-1 path must also clear the live fields so `enterAnswerMode`'s
    /// `savedSupervisorTask` stash is empty. Otherwise `submitAnswer`'s post-submit
    /// `exitAnswerMode` restores the just-sent text into the composer.
    func testTransition_chatWorkingToAnswer_savedSupervisorTaskIsEmpty() async throws {
        guard let taskID = await setUpChatWorkingPanel() else { return }

        controller.formState.supervisorTask = "queued msg"
        await addSupervisorQuestionStep(taskID: taskID)
        controller.refreshPanelIfVisible()

        XCTAssertTrue(controller._testIsInAnswerMode)
        // The draft now owns the user's text; the savedSupervisorTask stash that
        // `submitAnswer`'s exit path would restore must be empty.
        XCTAssertEqual(controller._testSavedSupervisorTask, "",
                       "savedSupervisorTask must not hold chat-working text — the draft is the source of truth")
        // And the composer still shows the user's content (loaded from the draft).
        XCTAssertEqual(controller.formState.supervisorTask, "queued msg")
    }

    /// End-to-end regression for the user-reported bug: typed in chat-working,
    /// transitioned to answer, simulated submit (clears + discardDraft + exitAnswerMode).
    /// Composer must be empty afterwards — no leftover text from the just-sent message.
    func testQueuedThenSubmitted_composerEmptyAfterExit() async throws {
        guard let taskID = await setUpChatWorkingPanel() else { return }

        controller.formState.supervisorTask = "фвы"
        await addSupervisorQuestionStep(taskID: taskID)
        controller.refreshPanelIfVisible()
        XCTAssertTrue(controller._testIsInAnswerMode)
        XCTAssertEqual(controller.formState.supervisorTask, "фвы")

        // Simulate the post-`answerSupervisorQuestion` cleanup that `submitAnswer` does:
        controller.formState.discardAnswerDraft(taskID: taskID)
        controller.formState.supervisorTask = ""
        controller.formState.answerAttachments = []
        controller.formState.answerClippedTexts = []
        controller._testExitAnswerMode()

        XCTAssertEqual(controller.formState.supervisorTask, "",
                       "Composer must be empty after submit — no echo of the just-sent message")
        XCTAssertTrue(controller.formState.answerAttachments.isEmpty)
        XCTAssertTrue(controller.formState.answerClippedTexts.isEmpty)
    }

    /// `currentVisualMode` defaults to `.newTask`. Opening a panel directly into
    /// `.supervisorAnswer` (engine in `.needsSupervisorInput` from the start) must NOT
    /// capture the live `supervisorTask` — that text could be a stale new-task draft.
    func testInitialPanelShow_intoSupervisorAnswer_doesNotCaptureFromCurrentVisualMode() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "G") else {
            XCTFail("Failed to create task"); return
        }
        await sut.switchTask(to: taskID)
        await addSupervisorQuestionStep(taskID: taskID)
        XCTAssertTrue(sut.activeTask?.isChatMode ?? false,
                      "Default team should be chat-mode for this regression check")

        // Pre-seed a stale new-task draft. `currentVisualMode` is still `.newTask`.
        controller.formState.supervisorTask = "stale new-task draft"
        controller.isTaskSelected = true
        controller._testIsPanelVisible = true
        controller._testLastRefreshedTaskID = nil
        controller.refreshPanelIfVisible()

        XCTAssertTrue(controller._testIsInAnswerMode)
        XCTAssertNil(controller.formState._testAnswerDrafts[taskID],
                     "Initial transition with currentVisualMode==.newTask must NOT capture live fields")
    }

    // MARK: - Helpers for full round-trip simulation

    /// Mimics `submitAnswer`'s post-`answerSupervisorQuestion` cleanup in chat-keep-open
    /// mode (lines 300-309 of QuickCaptureController.swift) without going through the
    /// real orchestrator's `answerSupervisorQuestion` async flow.
    private func simulatePostSubmitInChatKeepOpen(taskID: Int) {
        controller.formState.discardAnswerDraft(taskID: taskID)
        controller.formState.supervisorTask = ""
        controller.formState.answerAttachments = []
        controller.formState.answerClippedTexts = []
        controller._testExitAnswerMode()
    }

    /// Clears the supervisor-input step so the next `refreshPanelIfVisible` resolves to
    /// `.taskWorking` chat. Mimics the engine receiving an answer and resuming.
    private func simulateEngineResume(taskID: Int) async {
        await sut.mutateTask(taskID: taskID) { task in
            guard var run = task.runs.last else { return }
            run.steps.removeAll()
            task.runs.removeLast()
            task.runs.append(run)
        }
        sut.engineState[taskID] = .running
        controller.refreshPanelIfVisible()
    }

    // MARK: - Multi-round-trip user scenarios

    /// User typed in chat-working, transitioned to answer, submitted, returned to
    /// chat-working, typed a fresh message, transitioned to answer again. The second
    /// answer composer must show only the second-typed text — no echo of the first.
    func testMultipleRoundTrips_eachQuestionGetsFreshComposer() async throws {
        guard let taskID = await setUpChatWorkingPanel() else { return }

        // ROUND 1: type "msg1", LLM asks, preserved into answer mode
        controller.formState.supervisorTask = "msg1"
        await addSupervisorQuestionStep(taskID: taskID, stepID: "q1")
        controller.refreshPanelIfVisible()
        XCTAssertEqual(controller.formState.supervisorTask, "msg1",
                       "Round 1: chat-working text preserved into answer mode")

        // User submits "msg1" → cleanup → engine resumes
        simulatePostSubmitInChatKeepOpen(taskID: taskID)
        await simulateEngineResume(taskID: taskID)
        XCTAssertEqual(controller.formState.supervisorTask, "",
                       "Composer empty after submit + engine resume")
        XCTAssertNil(controller.formState._testAnswerDrafts[taskID],
                     "Draft discarded on submit — no leftover for next round")

        // ROUND 2: type "msg2", LLM asks again — only "msg2" appears (no echo of msg1)
        controller.formState.supervisorTask = "msg2"
        await addSupervisorQuestionStep(taskID: taskID, stepID: "q2")
        controller.refreshPanelIfVisible()

        XCTAssertEqual(controller.formState.supervisorTask, "msg2",
                       "Round 2: only the second-typed message appears in the answer composer")
        XCTAssertEqual(controller._testSavedSupervisorTask, "",
                       "savedSupervisorTask must remain empty across rounds")
    }

    /// User typed "x" in chat-working, transitioned to answer, then added "y" inside
    /// answer mode making it "xy", submitted "xy", resumed chat-working. The composer
    /// must be empty — neither "x" nor "xy" should echo back.
    func testTypedInBoth_chatWorkingAndAnswerMode_submitClearsCompletely() async throws {
        guard let taskID = await setUpChatWorkingPanel() else { return }

        // Type partial in chat-working
        controller.formState.supervisorTask = "x"
        await addSupervisorQuestionStep(taskID: taskID)
        controller.refreshPanelIfVisible()
        XCTAssertEqual(controller.formState.supervisorTask, "x")

        // User extends the message inside answer mode
        controller.formState.supervisorTask = "xy"

        // Submit + resume
        simulatePostSubmitInChatKeepOpen(taskID: taskID)
        await simulateEngineResume(taskID: taskID)

        XCTAssertEqual(controller.formState.supervisorTask, "",
                       "Composer must be fully empty after submit, including the extended portion")
        XCTAssertTrue(controller.formState.answerAttachments.isEmpty)
        XCTAssertTrue(controller.formState.answerClippedTexts.isEmpty)
    }

    /// User typed in chat-working, transitioned to answer, then **cancelled** the
    /// answer (X / Esc). After cancel the panel dismisses and the saved per-task
    /// draft is discarded — reopening the panel must show empty composer.
    func testCancelInAnswerMode_afterChatWorking_discardsDraft() async throws {
        guard let taskID = await setUpChatWorkingPanel() else { return }

        controller.formState.supervisorTask = "draft to cancel"
        await addSupervisorQuestionStep(taskID: taskID)
        controller.refreshPanelIfVisible()
        XCTAssertTrue(controller._testIsInAnswerMode)
        XCTAssertNotNil(controller.formState._testAnswerDrafts[taskID],
                        "After branch-1 capture, the draft entry should exist")

        // Mimic `cancelDraft` in answer mode (lines 501-516 of QuickCaptureController.swift):
        // discards the per-task draft and clears live fields.
        controller.formState.discardAnswerDraft(taskID: taskID)
        controller.formState.supervisorTask = ""
        controller.formState.answerAttachments = []
        controller.formState.answerClippedTexts = []
        controller._testExitAnswerMode()

        XCTAssertNil(controller.formState._testAnswerDrafts[taskID],
                     "Cancel must discard the per-task draft entirely")
        XCTAssertEqual(controller.formState.supervisorTask, "",
                       "Cancel + exit must leave the composer empty")
    }

    /// Empty composer in chat-working transitioning to answer must NOT create a phantom
    /// draft entry. Pre-existing `saveCurrentAnswerDraft` empty-removal contract — verified
    /// at the controller level.
    func testEmptyChatWorking_thenTransition_noPhantomDraft() async throws {
        guard let taskID = await setUpChatWorkingPanel() else { return }

        XCTAssertEqual(controller.formState.supervisorTask, "")
        XCTAssertTrue(controller.formState.answerAttachments.isEmpty)
        XCTAssertTrue(controller.formState.answerClippedTexts.isEmpty)

        await addSupervisorQuestionStep(taskID: taskID)
        controller.refreshPanelIfVisible()

        XCTAssertTrue(controller._testIsInAnswerMode)
        XCTAssertNil(controller.formState._testAnswerDrafts[taskID],
                     "Empty composer must not create a phantom draft on transition")
        XCTAssertEqual(controller.formState.supervisorTask, "",
                       "Composer stays empty when nothing was typed")
    }

    /// User attached files + typed in chat-working, transitioned to answer, **added a
    /// second attachment** inside answer mode. All three (text + both attachments)
    /// must survive when the user submits — and the composer must be cleared after.
    func testAttachmentsAccumulate_acrossTransition_thenClearOnSubmit() async throws {
        guard let taskID = await setUpChatWorkingPanel() else { return }

        let first = try makeStagedAttachment(name: "a.txt")
        let second = try makeStagedAttachment(name: "b.txt")

        controller.formState.supervisorTask = "with files"
        controller.formState.answerAttachments = [first]

        await addSupervisorQuestionStep(taskID: taskID)
        controller.refreshPanelIfVisible()

        XCTAssertEqual(controller.formState.answerAttachments, [first],
                       "First attachment survived the transition")

        // User adds another attachment inside answer mode
        controller.formState.answerAttachments.append(second)
        XCTAssertEqual(controller.formState.answerAttachments, [first, second])

        // Submit + resume
        simulatePostSubmitInChatKeepOpen(taskID: taskID)
        await simulateEngineResume(taskID: taskID)

        XCTAssertTrue(controller.formState.answerAttachments.isEmpty,
                      "All attachments cleared after submit — no leftover")
        XCTAssertEqual(controller.formState.supervisorTask, "")
    }

    /// User queues a message via `submitQueuedMessageFromForm` (clears live fields),
    /// then types a NEW message. When the LLM asks a question, the answer composer
    /// must show only the newly-typed message — the queued one is owned by the queue
    /// and delivered separately.
    func testQueueThenTypeMore_secondMessagePreservedNotEchoed() async throws {
        guard let taskID = await setUpChatWorkingPanel() else { return }

        // Queue "first" via submitQueuedMessageFromForm
        controller.formState.supervisorTask = "first"
        controller.submitQueuedMessageFromForm()
        XCTAssertEqual(controller.formState.supervisorTask, "",
                       "Queue submit clears the live composer")
        XCTAssertTrue(controller.formState.hasQueuedMessage(for: taskID),
                      "Queue must contain the first message")

        // User types another message
        controller.formState.supervisorTask = "second"

        // LLM asks → transition into answer mode
        await addSupervisorQuestionStep(taskID: taskID)
        controller.refreshPanelIfVisible()

        XCTAssertEqual(controller.formState.supervisorTask, "second",
                       "Only the just-typed message appears — not the queued 'first'")
        // The queued message stays in the queue — the backstop will deliver it separately.
        XCTAssertTrue(controller.formState.hasQueuedMessage(for: taskID),
                      "Queue is untouched by the chat-working → answer transition")
    }

    /// Two chat-mode tasks. User types "msgA" in task A's chat-working, switches to
    /// task B (also chat-mode, also running), types "msgB". Switching back to A,
    /// then triggering a question on A, must restore "msgA" — not leak "msgB".
    /// Currently this verifies the branch-1 capture is per-task.
    func testTwoTaskChatWorking_perTaskCaptureIsolated() async throws {
        await sut.openWorkFolder(tempDir)
        guard let taskA = await sut.createTask(title: "A", supervisorTask: "GA") else {
            XCTFail("Failed to create task A"); return
        }
        guard let taskB = await sut.createTask(title: "B", supervisorTask: "GB") else {
            XCTFail("Failed to create task B"); return
        }
        XCTAssertNotEqual(taskA, taskB)

        await sut.switchTask(to: taskA)
        sut.engineState[taskA] = .running
        sut.engineState[taskB] = .running
        controller.isTaskSelected = true
        controller._testIsPanelVisible = true
        controller._testLastRefreshedTaskID = taskA
        controller.refreshPanelIfVisible()

        // Type msgA in task A's chat-working
        controller.formState.supervisorTask = "msgA"

        // Trigger A's question — branch 1 captures into answerDrafts[A]
        await addSupervisorQuestionStep(taskID: taskA, stepID: "qA")
        controller.refreshPanelIfVisible()
        XCTAssertEqual(controller.formState.supervisorTask, "msgA")
        XCTAssertEqual(controller.formState._testAnswerDrafts[taskA]?.text, "msgA")
        XCTAssertNil(controller.formState._testAnswerDrafts[taskB],
                     "Task B's draft must remain absent — capture is per-task")
    }
}

// MARK: - Helpers

private func makePayload(
    question: String = "Test question?",
    isChatMode: Bool = false
) -> SupervisorAnswerPayload {
    SupervisorAnswerPayload(
        stepID: "test_step",
        taskID: Int(),
        role: .softwareEngineer,
        roleDefinition: nil,
        question: question,
        messageContent: "Some response",
        thinking: nil,
        isChatMode: isChatMode
    )
}
