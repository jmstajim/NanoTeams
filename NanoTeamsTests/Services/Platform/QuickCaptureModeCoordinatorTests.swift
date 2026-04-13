import XCTest

@testable import NanoTeams

/// Pure-function tests for `DefaultQuickCaptureModeCoordinator.resolveMode`. No
/// orchestrator, no task persistence — just inline fixtures exercising every branch
/// of the priority chain: forceNewTaskMode → supervisor question → engine running → overlay.
@MainActor
final class QuickCaptureModeCoordinatorTests: XCTestCase {

    var sut: DefaultQuickCaptureModeCoordinator!

    override func setUp() {
        super.setUp()
        sut = DefaultQuickCaptureModeCoordinator()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
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
            activeTeam: makeTeam(),
            forceNewTaskMode: false
        )
        if case .taskWorking(_, let isChat) = mode {
            XCTAssertTrue(isChat)
        } else {
            XCTFail("Expected .taskWorking with isChatMode=true")
        }
    }

    // MARK: - QuickCaptureVisualMode classification

    func testVisualMode_classification() {
        XCTAssertEqual(QuickCaptureVisualMode(.overlay), .newTask)
        XCTAssertEqual(QuickCaptureVisualMode(.sheet), .newTask)
        XCTAssertEqual(QuickCaptureVisualMode(.taskWorking(roleName: "", isChatMode: false)), .working)

        let payload = SupervisorAnswerPayload(
            stepID: "test_step", taskID: Int(), role: .softwareEngineer,
            roleDefinition: nil, question: "?", messageContent: nil,
            thinking: nil, isChatMode: false
        )
        XCTAssertEqual(QuickCaptureVisualMode(.supervisorAnswer(payload: payload)), .answer)
    }
}
