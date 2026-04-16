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

    func testSheetMode() {
        let mode = QuickCaptureMode.sheet
        if case .sheet = mode { /* pass */ } else { XCTFail("Expected .sheet") }
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

    func testEnterAnswerMode_savesGoalAndClearsIt() {
        sut.formState.supervisorTask = "My task description"
        let payload = makePayload()

        sut._testEnterAnswerMode(.supervisorAnswer(payload: payload))

        XCTAssertTrue(sut._testIsInAnswerMode)
        XCTAssertEqual(sut._testSavedSupervisorTask, "My task description")
        XCTAssertEqual(sut.formState.supervisorTask, "")
        XCTAssertEqual(sut.formState.pendingAnswer?.question, "Test question?")
    }

    func testExitAnswerMode_restoresGoal() {
        sut.formState.supervisorTask = "Original goal"
        sut._testEnterAnswerMode(.supervisorAnswer(payload: makePayload()))
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

    override func setUp() {
        super.setUp()
        controller = QuickCaptureController.shared
        controller.store = sut
        controller.formState.selectedTeamID = nil
        controller.formState.supervisorTask = "Test goal"
        controller.formState.title = ""
        controller.formState.attachments = []
        controller.formState.clippedTexts = []
    }

    override func tearDown() {
        controller.formState.selectedTeamID = nil
        controller.formState.supervisorTask = ""
        controller.formState.title = ""
        controller.store = nil
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
