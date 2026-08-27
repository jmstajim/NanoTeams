import XCTest

@testable import NanoTeams

/// Pure-function tests for `DefaultQuickCaptureModeCoordinator.resolveMode`. No
/// orchestrator, no task persistence — just inline fixtures exercising every branch
/// of the priority chain: forceNewTaskMode → supervisor question → engine running → overlay.
@MainActor
final class QuickCaptureModeCoordinatorTests: XCTestCase {

    var sut: DefaultQuickCaptureModeCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        sut = DefaultQuickCaptureModeCoordinator()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeTeam() -> Team {
        let role = TeamRoleDefinition(
            id: "eng", name: "Engineer",
            prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        return Team(
            id: "t1", name: "Test Team",
            roles: [role], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
    }

    private func makeTask(withQuestion: Bool = false, isChatMode: Bool = false) -> NTMSTask {
        var task = NTMSTask(id: 0, title: "T", supervisorTask: "G")
        task.setStoredChatMode(isChatMode)
        var run = Run(id: 0, teamID: "t1")
        var step = StepExecution.make(for: TeamRoleDefinition(
            id: "eng", name: "Engineer",
            prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies()
        ))
        if withQuestion {
            step.needsSupervisorInput = true
            step.supervisorQuestion = "What should I do?"
            step.status = .needsSupervisorInput
        } else {
            step.status = .running
        }
        run.steps.append(step)
        task.runs.append(run)
        return task
    }

    // MARK: - Priority Chain

    func testResolveMode_forceNewTaskMode_returnsOverlay() {
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: makeTask(withQuestion: true),
            engineState: .running,
            isInitializingRun: false,
            activeTeam: makeTeam(),
            forceNewTaskMode: true
        )
        if case .overlay = mode { /* pass */ } else {
            XCTFail("forceNewTaskMode must short-circuit to .overlay regardless of state")
        }
    }

    func testResolveMode_noTaskSelected_returnsOverlay() {
        let mode = sut.resolveMode(
            isTaskSelected: false,
            activeTask: makeTask(withQuestion: true),
            engineState: .running,
            isInitializingRun: false,
            activeTeam: makeTeam(),
            forceNewTaskMode: false
        )
        if case .overlay = mode { /* pass */ } else { XCTFail("Expected .overlay") }
    }

    func testResolveMode_nilActiveTask_returnsOverlay() {
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: nil,
            engineState: nil,
            isInitializingRun: false,
            activeTeam: makeTeam(),
            forceNewTaskMode: false
        )
        if case .overlay = mode { /* pass */ } else { XCTFail("Expected .overlay") }
    }

    func testResolveMode_supervisorQuestion_returnsAnswerMode() {
        let task = makeTask(withQuestion: true)
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: task,
            engineState: .needsSupervisorInput,
            isInitializingRun: false,
            activeTeam: makeTeam(),
            forceNewTaskMode: false
        )
        if case .supervisorAnswer(let payload) = mode {
            XCTAssertEqual(payload.question, "What should I do?")
            XCTAssertEqual(payload.taskID, task.id)
        } else {
            XCTFail("Expected .supervisorAnswer")
        }
    }

    func testResolveMode_questionTakesPriorityOverRunning() {
        // Task has both a pending question AND is running — question wins.
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: makeTask(withQuestion: true),
            engineState: .running,
            isInitializingRun: false,
            activeTeam: makeTeam(),
            forceNewTaskMode: false
        )
        if case .supervisorAnswer = mode { /* pass */ } else {
            XCTFail("Supervisor question must take priority over .running")
        }
    }

    func testResolveMode_engineRunning_returnsTaskWorking() {
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: makeTask(withQuestion: false),
            engineState: .running,
            isInitializingRun: false,
            activeTeam: makeTeam(),
            forceNewTaskMode: false
        )
        if case .taskWorking(_, let isChat) = mode {
            XCTAssertFalse(isChat)
        } else {
            XCTFail("Expected .taskWorking")
        }
    }

    func testResolveMode_engineDone_returnsOverlay() {
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: makeTask(withQuestion: false),
            engineState: .done,
            isInitializingRun: false,
            activeTeam: makeTeam(),
            forceNewTaskMode: false
        )
        if case .overlay = mode { /* pass */ } else { XCTFail("Expected .overlay") }
    }

    func testResolveMode_taskWorking_carriesChatModeFlag() {
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: makeTask(withQuestion: false, isChatMode: true),
            engineState: .running,
            isInitializingRun: false,
            activeTeam: makeTeam(),
            forceNewTaskMode: false
        )
        if case .taskWorking(_, let isChat) = mode {
            XCTAssertTrue(isChat)
        } else {
            XCTFail("Expected .taskWorking with isChatMode=true")
        }
    }

    // MARK: - Role Name Resolution

    func testResolveMode_taskWorking_resolvesRoleNameFromTeam() {
        let team = makeTeam() // has role "eng" named "Engineer"
        let task = makeTask(withQuestion: false) // running step with id "eng"
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: task,
            engineState: .running,
            isInitializingRun: false,
            activeTeam: team,
            forceNewTaskMode: false
        )
        if case .taskWorking(let roleName, _) = mode {
            XCTAssertEqual(roleName, "Engineer")
        } else {
            XCTFail("Expected .taskWorking")
        }
    }

    func testResolveMode_taskWorking_wrongTeam_fallsBackToStepRole() {
        // Simulate the bug scenario: task runs with team A (role "eng" = "Engineer"),
        // but activeTeam is team B (role "cm" = "Content Manager") — role lookup fails.
        let wrongTeam = Team(
            id: "t2", name: "Wrong Team",
            roles: [TeamRoleDefinition(
                id: "cm", name: "Content Manager",
                prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies()
            )],
            artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        let task = makeTask(withQuestion: false) // step id = "eng", not in wrongTeam
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: task,
            engineState: .running,
            isInitializingRun: false,
            activeTeam: wrongTeam,
            forceNewTaskMode: false
        )
        // roleDef is nil (no "eng" in wrongTeam), falls back to step.role.displayName
        // then to nonSupervisorRoles.first — should NOT be "Content Manager" ideally,
        // but the coordinator's fallback chain makes this the last resort.
        if case .taskWorking(let roleName, _) = mode {
            // The role name should NOT be empty — some fallback must fire.
            XCTAssertFalse(roleName.isEmpty)
        } else {
            XCTFail("Expected .taskWorking")
        }
    }

    func testResolveMode_taskWorking_correctTeam_resolvesCorrectRole() {
        // The fix: when activeTeam matches the task's team, role name resolves correctly.
        let assistant = TeamRoleDefinition(
            id: "assistant", name: "Assistant",
            prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies()
        )
        let correctTeam = Team(
            id: "pa", name: "Personal Assistant",
            roles: [assistant], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
        // Create a task with a running step whose id matches the team's role
        var task = NTMSTask(id: 1, title: "T", supervisorTask: "G")
        var run = Run(id: 0, teamID: "pa")
        var step = StepExecution.make(for: assistant)
        step.status = .running
        run.steps.append(step)
        task.runs.append(run)

        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: task,
            engineState: .running,
            isInitializingRun: false,
            activeTeam: correctTeam,
            forceNewTaskMode: false
        )
        if case .taskWorking(let roleName, _) = mode {
            XCTAssertEqual(roleName, "Assistant")
        } else {
            XCTFail("Expected .taskWorking with roleName 'Assistant'")
        }
    }

    func testResolveMode_answerMode_resolvesRoleFromTeam() {
        let task = makeTask(withQuestion: true)
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: task,
            engineState: .needsSupervisorInput,
            isInitializingRun: false,
            activeTeam: makeTeam(),
            forceNewTaskMode: false
        )
        if case .supervisorAnswer(let payload) = mode {
            XCTAssertEqual(payload.roleDefinition?.name, "Engineer")
        } else {
            XCTFail("Expected .supervisorAnswer with roleDefinition")
        }
    }

    // MARK: - QC ↔ Activity Feed sync contract

    /// Both surfaces (QC overlay header + activity-feed question card / composer
    /// chip preview) MUST display the same question text for the same step.
    /// QC reads `step.supervisorQuestion` directly via this coordinator; the
    /// activity feed reads through `ActivityFeedBuilder.activeSupervisorQuestions`.
    /// They diverged when escalation overwrote `step.supervisorQuestion` while a
    /// stale ask_supervisor tool call still sat in `step.toolCalls` — the user
    /// saw two different texts for the same waiting step (see the bug
    /// reproduction in `ActivityFeedBuilderTests.testActiveSupervisorQuestions_prefersStepSupervisorQuestionOverStaleToolCallArg`).
    /// This test pins the contract end-to-end across both surfaces.
    func testQCAndActivityFeed_agreeOnQuestion_afterEscalationOverwrite() {
        // Build a task whose step has BOTH a stale ask_supervisor tool call
        // (with original question text) AND an escalation-overwritten
        // `step.supervisorQuestion`. Both surfaces must report the escalation
        // text, not the stale tool-call argument.
        let staleAsk = StepToolCall(
            name: ToolNames.askSupervisor,
            argumentsJSON: #"{"question":"Original ask before escalation"}"#,
            resultJSON: "{}"
        )
        var task = NTMSTask(id: 0, title: "T", supervisorTask: "G")
        var run = Run(id: 0, teamID: "t1")
        var step = StepExecution.make(for: TeamRoleDefinition(
            id: "eng", name: "Engineer",
            prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies()
        ))
        step.needsSupervisorInput = true
        step.supervisorQuestion = "ESCALATION: Role X emitted 3 refusal messages."
        step.status = .needsSupervisorInput
        step.toolCalls.append(staleAsk)
        run.steps.append(step)
        task.runs.append(run)

        // QC surface
        let qcMode = sut.resolveMode(
            isTaskSelected: true, activeTask: task,
            engineState: .needsSupervisorInput, isInitializingRun: false,
            activeTeam: makeTeam(), forceNewTaskMode: false
        )
        guard case .supervisorAnswer(let qcPayload) = qcMode else {
            XCTFail("Expected .supervisorAnswer mode"); return
        }

        // Activity-feed surface
        let activeQuestions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(activeQuestions.count, 1)

        // Contract: both surfaces show the SAME text.
        XCTAssertEqual(
            qcPayload.question, activeQuestions.first?.question,
            "QC overlay and activity-feed composer must show the same question for the same step — divergence reintroduces the escalation/stale-tool-call desync bug."
        )
        XCTAssertEqual(
            qcPayload.question, "ESCALATION: Role X emitted 3 refusal messages.",
            "Both surfaces must show the CURRENT (escalation) text, not the stale tool-call argument."
        )
    }

    /// Companion sync test for the normal path: when only a real ask_supervisor
    /// call exists (no escalation), both surfaces still agree. Without this,
    /// a Green-phase change to `activeSupervisorQuestions` could break the
    /// normal path while fixing the escalation path — silently breaking the
    /// common case.
    func testQCAndActivityFeed_agreeOnQuestion_normalAskSupervisorPath() {
        // step.supervisorQuestion mirrors the tool-call arg (what
        // setNeedsSupervisorInput does on the normal ask_supervisor path).
        let ask = StepToolCall(
            name: ToolNames.askSupervisor,
            argumentsJSON: #"{"question":"Which scheme should I use?"}"#,
            resultJSON: "{}"
        )
        var task = NTMSTask(id: 0, title: "T", supervisorTask: "G")
        var run = Run(id: 0, teamID: "t1")
        var step = StepExecution.make(for: TeamRoleDefinition(
            id: "eng", name: "Engineer",
            prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies()
        ))
        step.needsSupervisorInput = true
        step.supervisorQuestion = "Which scheme should I use?"
        step.status = .needsSupervisorInput
        step.toolCalls.append(ask)
        run.steps.append(step)
        task.runs.append(run)

        let qcMode = sut.resolveMode(
            isTaskSelected: true, activeTask: task,
            engineState: .needsSupervisorInput, isInitializingRun: false,
            activeTeam: makeTeam(), forceNewTaskMode: false
        )
        guard case .supervisorAnswer(let qcPayload) = qcMode else {
            XCTFail("Expected .supervisorAnswer mode"); return
        }

        let activeQuestions = ActivityFeedBuilder.activeSupervisorQuestions(steps: [step])
        XCTAssertEqual(activeQuestions.count, 1)
        XCTAssertEqual(
            qcPayload.question, activeQuestions.first?.question,
            "Normal path: both surfaces show same question text"
        )
    }

    // MARK: - QuickCaptureVisualMode classification

    func testVisualMode_classification() {
        XCTAssertEqual(QuickCaptureVisualMode(.overlay), .newTask)
        XCTAssertEqual(QuickCaptureVisualMode(.taskWorking(roleName: "", isChatMode: false)), .working)

        let payload = SupervisorAnswerPayload(
            stepID: "test_step", taskID: Int(), role: .softwareEngineer,
            roleDefinition: nil, question: "?", messageContent: nil,
            thinking: nil, isChatMode: false
        )
        XCTAssertEqual(QuickCaptureVisualMode(.supervisorAnswer(payload: payload)), .answer)
    }

    // MARK: - Initializing

    /// The branch the reported bug was missing. With the run start claimed and no engine
    /// yet, the resolver used to fall through to `.overlay` — so the panel flipped back
    /// to the new-task composer on the first refresh after Send, telling the user their
    /// message had gone nowhere while the run was in fact starting.
    ///
    /// RED: delete the `isInitializingRun` branch → `.overlay`, which is the bug verbatim.
    func testResolveMode_runStartClaimed_returnsInitializing() {
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: makeTask(withQuestion: false),
            engineState: nil,
            isInitializingRun: true,
            activeTeam: makeTeam(),
            forceNewTaskMode: false
        )
        guard case .taskInitializing = mode else {
            return XCTFail("Expected .taskInitializing, got \(mode)")
        }
    }

    /// Ordering, stated as an assertion rather than left to the reading. A task parked on
    /// a question while a NEW start is claimed must still show the question — losing it
    /// would strand the run behind a spinner nobody can answer.
    func testResolveMode_supervisorQuestionOutranksInitializing() {
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: makeTask(withQuestion: true),
            engineState: nil,
            isInitializingRun: true,
            activeTeam: makeTeam(),
            forceNewTaskMode: false
        )
        guard case .supervisorAnswer = mode else {
            return XCTFail("The question outranks the phase, got \(mode)")
        }
    }

    /// The other end of the ordering: once the engine reports `.running` its answer wins,
    /// because the claim is still held for the tick in which `engine.start()` returns
    /// (CLAUDE.md #95). A caption reading `Initializing…` over a working role is the
    /// failure this pins.
    func testResolveMode_runningOutranksAStillHeldClaim() {
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: makeTask(withQuestion: false),
            engineState: .running,
            isInitializingRun: true,
            activeTeam: makeTeam(),
            forceNewTaskMode: false
        )
        guard case .taskWorking = mode else {
            return XCTFail("Expected .taskWorking, got \(mode)")
        }
    }

    /// `forceNewTaskMode` is the user asking for the new-task composer explicitly — it
    /// short-circuits ahead of everything, this phase included.
    func testResolveMode_forceNewTaskMode_beatsInitializing() {
        let mode = sut.resolveMode(
            isTaskSelected: true,
            activeTask: makeTask(withQuestion: false),
            engineState: nil,
            isInitializingRun: true,
            activeTeam: makeTeam(),
            forceNewTaskMode: true
        )
        guard case .overlay = mode else {
            return XCTFail("Expected .overlay, got \(mode)")
        }
    }

    // MARK: - What the new case carries

    /// Everything a live-task mode does with the composer, `.taskInitializing` does
    /// identically — the six sites that used to destructure `.taskWorking` alone now ask
    /// `liveTaskChatMode`, and this is that contract stated once.
    func testInitializingMode_behavesAsALiveTaskModeForTheComposer() {
        let chat = QuickCaptureMode.taskInitializing(isChatMode: true)
        let nonChat = QuickCaptureMode.taskInitializing(isChatMode: false)

        XCTAssertEqual(chat.liveTaskChatMode, true)
        XCTAssertEqual(nonChat.liveTaskChatMode, false)
        XCTAssertNil(QuickCaptureMode.overlay.liveTaskChatMode,
                     "Anti-vacuum: the accessor must DISTINGUISH, not answer true for all")

        XCTAssertTrue(chat.expectsFocusableField)
        XCTAssertFalse(nonChat.expectsFocusableField,
                       "Loader-only working is the one legitimate no-field case")
        XCTAssertTrue(chat.composerBindsAnswerBuckets)

        XCTAssertEqual(QuickCapturePresentationPolicy.submitAction(for: chat), .queueChatMessage,
                       "The next prompt during initialization is the FIRST one — the most "
                           + "useful moment to line a message up")
        XCTAssertEqual(QuickCapturePresentationPolicy.submitAction(for: nonChat), .disabled)
    }

    /// A distinct render identity from "working with no role name yet". Collapsing them
    /// would leave the panel showing `Initializing…` after the engine came up, because
    /// the controller rebuilds content only when the identity changes.
    func testInitializingMode_hasItsOwnRenderIdentity() {
        let initializing = QuickCapturePresentationPolicy.renderIdentity(
            of: .taskInitializing(isChatMode: true))
        let anonymousWorking = QuickCapturePresentationPolicy.renderIdentity(
            of: .taskWorking(roleName: "", isChatMode: true))

        XCTAssertNotEqual(initializing, anonymousWorking)
        XCTAssertNotEqual(
            initializing,
            QuickCapturePresentationPolicy.renderIdentity(of: .taskInitializing(isChatMode: false)),
            "Chat mode changes what the surface renders, so it must change the identity")
    }
}
