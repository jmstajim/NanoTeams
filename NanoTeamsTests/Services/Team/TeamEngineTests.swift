import XCTest
@testable import NanoTeams

// MARK: - Mock Team Engine Store

@MainActor
final class MockTeamEngineStore: TeamEngineStore {

    // MARK: - Stored Properties

    var activeTask: NTMSTask?
    var teamSettings: TeamSettings = .default
    var activeTeam: Team?

    // MARK: - Call Tracking

    var stepStatusResults: [String: StepStatus] = [:]
    var producedArtifactNamesResult: Set<String> = []

    var updateRoleStatusCalls: [(roleID: String, status: RoleExecutionStatus)] = []
    var prepareStepCalls: [String] = []
    var runStepCalls: [String] = []
    var findOrCreateStepCalls: [String] = []
    var findOrCreateStepResults: [String: String] = [:]
    var resetStepForRevisionCalls: [String] = []
    var setLastErrorMessageCalls: [String] = []

    // MARK: - Protocol Methods

    func stepStatus(stepID: String) -> StepStatus? {
        stepStatusResults[stepID]
    }

    func producedArtifactNames() -> Set<String> {
        producedArtifactNamesResult
    }

    func updateRoleStatus(roleID: String, status: RoleExecutionStatus) async {
        updateRoleStatusCalls.append((roleID: roleID, status: status))

        // Also update the role status in the active task's latest run
        if var task = activeTask, var run = task.runs.last {
            let runIndex = task.runs.count - 1
            run.roleStatuses[roleID] = status
            task.runs[runIndex] = run
            activeTask = task
        }
    }

    func prepareStepForExecution(stepID: String) async {
        prepareStepCalls.append(stepID)
    }

    func runStep(stepID: String) async {
        runStepCalls.append(stepID)
    }

    func findOrCreateStep(roleID: String) async -> String? {
        findOrCreateStepCalls.append(roleID)
        return findOrCreateStepResults[roleID]
    }

    func resetStepForRevision(stepID: String) async {
        resetStepForRevisionCalls.append(stepID)
    }

    func setLastErrorMessageForUI(_ message: String) async {
        setLastErrorMessageCalls.append(message)
    }
}

// MARK: - Test Helpers

private func makeSupervisorRole(id: String = "supervisor-role", requiredArtifacts: [String] = ["Final Deliverable"]) -> TeamRoleDefinition {
    TeamRoleDefinition(
        id: id,
        name: "Supervisor",
        prompt: "You are the Supervisor.",
        toolIDs: [],
        usePlanningPhase: false,
        dependencies: RoleDependencies(
            requiredArtifacts: requiredArtifacts,
            producesArtifacts: ["Supervisor Task"]
        ),
        isSystemRole: true,
        systemRoleID: "supervisor"
    )
}

private func makeWorkerRole(
    id: String,
    name: String,
    requiredArtifacts: [String] = ["Supervisor Task"],
    producesArtifacts: [String]
) -> TeamRoleDefinition {
    TeamRoleDefinition(
        id: id,
        name: name,
        prompt: "You are \(name).",
        toolIDs: ["read_file"],
        usePlanningPhase: false,
        dependencies: RoleDependencies(
            requiredArtifacts: requiredArtifacts,
            producesArtifacts: producesArtifacts
        )
    )
}

private func makeTeam(roles: [TeamRoleDefinition]) -> Team {
    Team(
        name: "Test Team",
        roles: roles,
        artifacts: [],
        settings: .default,
        graphLayout: TeamGraphLayout()
    )
}

// MARK: - Team Engine Tests

@MainActor
final class TeamEngineTests: XCTestCase {

    var sut: TeamEngine!
    var mockStore: MockTeamEngineStore!

    override func setUp() {
        super.setUp()
        mockStore = MockTeamEngineStore()
        sut = TeamEngine(store: mockStore)
    }

    override func tearDown() {
        sut = nil
        mockStore = nil
        super.tearDown()
    }

    // MARK: - 1. testInitialState_isPending

    func testInitialState_isPending() {
        XCTAssertEqual(sut.state, .pending)
    }

    // MARK: - 2. testStart_setsStateToRunning

    func testStart_setsStateToRunning() {
        // Provide a valid task so the run loop doesn't immediately fail
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let run = Run(id: 0, roleStatuses: ["eng": .done])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])

        sut.start()

        XCTAssertEqual(sut.state, .running)
    }

    // MARK: - 3. testStop_resetsStateToPending

    func testStop_resetsStateToPending() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let run = Run(id: 0, roleStatuses: ["eng": .done])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])

        sut.start()
        XCTAssertEqual(sut.state, .running)

        sut.stop()
        XCTAssertEqual(sut.state, .pending)
    }

    // MARK: - 4. testPause_fromRunning_setsPaused

    func testPause_fromRunning_setsPaused() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let run = Run(id: 0, roleStatuses: ["eng": .done])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])

        sut.start()
        XCTAssertEqual(sut.state, .running)

        sut.pause()
        XCTAssertEqual(sut.state, .paused)
    }

    // MARK: - 7. testPause_fromPending_doesNothing

    func testPause_fromPending_doesNothing() {
        // Engine starts in .pending — pause guard should prevent state change
        XCTAssertEqual(sut.state, .pending)

        sut.pause()

        XCTAssertEqual(sut.state, .pending)
    }

    // MARK: - 8. testResume_fromPaused_setsRunning

    func testResume_fromPaused_setsRunning() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let run = Run(id: 0, roleStatuses: ["eng": .done])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])

        sut.start()
        sut.pause()
        XCTAssertEqual(sut.state, .paused)

        sut.resume()
        XCTAssertEqual(sut.state, .running)
    }

    // MARK: - 7. testDoubleStart_ignored

    func testDoubleStart_ignored() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let run = Run(id: 0, roleStatuses: ["eng": .done])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])

        sut.start()
        XCTAssertEqual(sut.state, .running)

        // Second start with a different mode should be ignored
        sut.start()

        // State and mode should remain unchanged
        XCTAssertEqual(sut.state, .running)
    }

    // MARK: - 11. testStart_whenNeedsAcceptance_ignored

    func testStart_whenNeedsAcceptance_ignored() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        // Set up a run with a role that needs acceptance so the run loop transitions
        let run = Run(id: 0, roleStatuses: ["eng": .needsAcceptance])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]

        sut.start()

        // Wait a small amount for the run loop to pick up the needsAcceptance status
        let expectation = XCTestExpectation(description: "Engine transitions to needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance {
                expectation.fulfill()
            }
        }
        // Since start is already called, if the run loop reaches needsAcceptance quickly
        // we may need to wait
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(sut.state, .needsAcceptance)

        // Now try to start again — should be ignored because state is .needsAcceptance
        sut.start()

        XCTAssertEqual(sut.state, .needsAcceptance)
    }

    // MARK: - 12. testOnStateChanged_callback_fires

    func testOnStateChanged_callback_fires() {
        var capturedStates: [TeamEngineState] = []
        sut.onStateChanged = { state in
            capturedStates.append(state)
        }

        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let run = Run(id: 0, roleStatuses: ["eng": .done])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])

        sut.start()

        // Should have captured .running
        XCTAssertTrue(capturedStates.contains(.running))

        sut.pause()

        // Should have captured .paused
        XCTAssertTrue(capturedStates.contains(.paused))

        sut.stop()

        // Should have captured .pending
        XCTAssertTrue(capturedStates.contains(.pending))
    }

    // MARK: - 13. testNotifyExternalEvent_resumesFromPaused

    func testNotifyExternalEvent_resumesFromPaused() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let run = Run(id: 0, roleStatuses: ["eng": .done])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])

        sut.start()
        sut.pause()
        XCTAssertEqual(sut.state, .paused)

        sut.notifyExternalEvent()

        XCTAssertEqual(sut.state, .running)
    }

    // MARK: - 14. testNotifyExternalEvent_resumesFromNeedsAcceptance

    func testNotifyExternalEvent_resumesFromNeedsAcceptance() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let run = Run(id: 0, roleStatuses: ["eng": .needsAcceptance])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]

        sut.start()

        // Wait for the engine to reach needsAcceptance
        let expectation = XCTestExpectation(description: "Engine reaches needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance {
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .needsAcceptance)

        // Mark the role as accepted so the engine can proceed after resume
        mockStore.activeTask?.runs[0].roleStatuses["eng"] = .done

        sut.notifyExternalEvent()

        XCTAssertEqual(sut.state, .running)
    }

    // MARK: - 15. testNotifyExternalEvent_resumesFromNeedsSupervisorInput

    func testNotifyExternalEvent_resumesFromNeedsSupervisorInput() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        // Set up a step that needs Supervisor input to trigger the needsSupervisorInput engine state
        let stepID = "test_step"
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "Engineering",
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "What framework?"
        )
        let run = Run(
            id: 0,
            steps: [step],
            roleStatuses: ["eng": .working]
        )
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]
        mockStore.stepStatusResults[stepID] = .needsSupervisorInput

        sut.start()

        // Wait for engine to detect the needsSupervisorInput
        let expectation = XCTestExpectation(description: "Engine reaches needsSupervisorInput")
        sut.onStateChanged = { state in
            if state == .needsSupervisorInput {
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .needsSupervisorInput)

        // Now answer the question and notify
        mockStore.activeTask?.runs[0].steps[0].status = .done
        mockStore.activeTask?.runs[0].steps[0].supervisorAnswer = "Use SwiftUI"
        mockStore.activeTask?.runs[0].roleStatuses["eng"] = .done
        mockStore.stepStatusResults[stepID] = .done

        sut.notifyExternalEvent()

        XCTAssertEqual(sut.state, .running)
    }

    // MARK: - 14. testSetAutoIterationLimit_clampsToMin1

    func testSetAutoIterationLimit_clampsToMin1() {
        // Setting a value of 0 should clamp to 1
        sut.setAutoIterationLimitForTesting(0)

        // We can't directly read the autoIterationLimitOverride, but we can verify
        // behavior indirectly: with limit = 1 in autonomous mode, the engine should
        // pause after 1 iteration.

        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        // Set up a run in autonomous mode with a working role that never finishes
        // so the loop keeps iterating until it hits the limit
        let stepID = "test_step"
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "Engineering",
            status: .running
        )
        let run = Run(
            id: 0,
            steps: [step],
            roleStatuses: ["eng": .working]
        )
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]
        mockStore.stepStatusResults[stepID] = .running

        let expectation = XCTestExpectation(description: "Engine pauses due to iteration limit")
        sut.onStateChanged = { state in
            if state == .paused {
                expectation.fulfill()
            }
        }

        sut.start()
        wait(for: [expectation], timeout: 5.0)

        XCTAssertEqual(sut.state, .paused)
        XCTAssertFalse(mockStore.setLastErrorMessageCalls.isEmpty,
                       "Should have set an error message about iteration limit")

        // Also verify negative value clamps to 1
        sut.stop()
        sut.setAutoIterationLimitForTesting(-5)

        mockStore.setLastErrorMessageCalls.removeAll()
        let expectation2 = XCTestExpectation(description: "Engine pauses again with negative input clamped to 1")
        sut.onStateChanged = { state in
            if state == .paused {
                expectation2.fulfill()
            }
        }

        sut.start()
        wait(for: [expectation2], timeout: 5.0)

        XCTAssertEqual(sut.state, .paused)
    }

    // MARK: - 19. testWorkingRoles_returnsWorkingRoleIDs

    func testWorkingRoles_returnsWorkingRoleIDs() {
        let run = Run(
            id: 0,
            roleStatuses: [
                "eng": .working,
                "pm": .done,
                "designer": .working,
                "qa": .idle,
            ]
        )
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])

        let working = sut.workingRoles()

        XCTAssertEqual(Set(working), Set(["eng", "designer"]))
    }

    // MARK: - 20. testPendingAcceptanceRoles_returnsCorrectIDs

    func testPendingAcceptanceRoles_returnsCorrectIDs() {
        let run = Run(
            id: 0,
            roleStatuses: [
                "eng": .needsAcceptance,
                "pm": .done,
                "designer": .needsAcceptance,
                "qa": .working,
            ]
        )
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])

        let pending = sut.pendingAcceptanceRoles()

        XCTAssertEqual(Set(pending), Set(["eng", "designer"]))
    }

    // MARK: - Additional Edge Case Tests

    func testWorkingRoles_withNoTask_returnsEmpty() {
        mockStore.activeTask = nil

        let working = sut.workingRoles()

        XCTAssertTrue(working.isEmpty)
    }

    func testPendingAcceptanceRoles_withNoTask_returnsEmpty() {
        mockStore.activeTask = nil

        let pending = sut.pendingAcceptanceRoles()

        XCTAssertTrue(pending.isEmpty)
    }

    func testWorkingRoles_withNoRuns_returnsEmpty() {
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [])

        let working = sut.workingRoles()

        XCTAssertTrue(working.isEmpty)
    }

    func testAttach_setsStore() {
        XCTAssertEqual(sut.state, .pending)

        let store = MockTeamEngineStore()
        let run = Run(id: 0, roleStatuses: ["eng": .working])
        store.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])

        sut.attach(store: store)

        // Verify the store is attached by checking that workingRoles reads from it
        let working = sut.workingRoles()
        XCTAssertEqual(working, ["eng"])
    }

    func testOnStateChanged_doesNotFire_whenStateUnchanged() {
        var callbackCount = 0
        sut.onStateChanged = { _ in
            callbackCount += 1
        }

        // State is .pending, calling stop sets it to .pending again — callback should NOT fire
        // because the didSet guard checks oldValue != state
        sut.stop()

        XCTAssertEqual(callbackCount, 0)
    }

    func testPause_fromNeedsAcceptance_setsPaused() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let run = Run(id: 0, roleStatuses: ["eng": .needsAcceptance])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]

        sut.start()

        // Wait for the engine to reach needsAcceptance
        let expectation = XCTestExpectation(description: "Engine reaches needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance {
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .needsAcceptance)

        sut.pause()

        XCTAssertEqual(sut.state, .paused)
    }

    func testPause_fromNeedsSupervisorInput_setsPaused() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let stepID = "test_step"
        let step = StepExecution(
            id: stepID,
            role: .softwareEngineer,
            title: "Engineering",
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "What framework?"
        )
        let run = Run(
            id: 0,
            steps: [step],
            roleStatuses: ["eng": .working]
        )
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]
        mockStore.stepStatusResults[stepID] = .needsSupervisorInput

        sut.start()

        let expectation = XCTestExpectation(description: "Engine reaches needsSupervisorInput")
        sut.onStateChanged = { state in
            if state == .needsSupervisorInput {
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .needsSupervisorInput)

        sut.pause()

        XCTAssertEqual(sut.state, .paused)
    }

    // MARK: - notifyExternalEvent from .done and .failed

    func testNotifyExternalEvent_resumesFromDone() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let stepID = "test_step"
        let step = StepExecution(
            id: stepID, role: .softwareEngineer,
            title: "Engineering", status: .done, artifacts: [Artifact(name: "Code")]
        )
        let run = Run(id: 0, steps: [step], roleStatuses: ["eng": .done])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Code"]
        mockStore.stepStatusResults[stepID] = .done

        // Start engine — it should reach .done since all roles are complete
        let doneExpectation = XCTestExpectation(description: "Engine reaches done")
        sut.onStateChanged = { state in
            if state == .done { doneExpectation.fulfill() }
        }
        sut.start()
        wait(for: [doneExpectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .done)

        // Simulate restartRole: reset the role to .idle and step to .pending
        mockStore.activeTask?.runs[0].roleStatuses["eng"] = .idle
        mockStore.activeTask?.runs[0].steps[0].status = .pending
        mockStore.stepStatusResults[stepID] = .pending

        // notifyExternalEvent should resume the engine from .done
        sut.notifyExternalEvent()
        XCTAssertEqual(sut.state, .running)
    }

    func testNotifyExternalEvent_resumesFromFailed() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let stepID = "test_step"
        let step = StepExecution(
            id: stepID, role: .softwareEngineer,
            title: "Engineering", status: .failed
        )
        let run = Run(id: 0, steps: [step], roleStatuses: ["eng": .failed])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]
        mockStore.stepStatusResults[stepID] = .failed

        // Start engine — it should reach .failed since a role failed
        let failedExpectation = XCTestExpectation(description: "Engine reaches failed")
        sut.onStateChanged = { state in
            if state == .failed { failedExpectation.fulfill() }
        }
        sut.start()
        wait(for: [failedExpectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .failed)

        // Simulate restartRole: reset the role to .idle and step to .pending
        mockStore.activeTask?.runs[0].roleStatuses["eng"] = .idle
        mockStore.activeTask?.runs[0].steps[0].status = .pending
        mockStore.stepStatusResults[stepID] = .pending

        // notifyExternalEvent should resume the engine from .failed
        sut.notifyExternalEvent()
        XCTAssertEqual(sut.state, .running)
    }

    func testNotifyExternalEvent_doesNothing_whenPending() {
        XCTAssertEqual(sut.state, .pending)

        sut.notifyExternalEvent()

        XCTAssertEqual(sut.state, .pending)
    }

    func testNotifyExternalEvent_doesNothing_whenRunning() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        let team = makeTeam(roles: [supervisorRole, workerRole])
        mockStore.activeTeam = team

        let run = Run(id: 0, roleStatuses: ["eng": .done])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])

        sut.start()
        XCTAssertEqual(sut.state, .running)

        // notifyExternalEvent should not change state when already running
        sut.notifyExternalEvent()

        XCTAssertEqual(sut.state, .running)
    }

    // MARK: - handleRoleCompleted Guard Tests

    /// Verifies that reconciliation sets an intermediate role to .done (not .needsAcceptance)
    /// when a downstream role is already .working in .finalOnly mode.
    /// This reproduces the race condition: reconciliation and waitForStepCompletion could both
    /// detect step .done; if the second call ran after the downstream role started (.working),
    /// the old isLastRoleToComplete logic would exclude .working roles and incorrectly return true.
    func testFinalOnly_intermediateRoleGetsDone_whenDownstreamIsWorking() {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(
            id: "a", name: "RoleA",
            requiredArtifacts: ["Supervisor Task"],
            producesArtifacts: ["Art A"]
        )
        let roleB = makeWorkerRole(
            id: "b", name: "RoleB",
            requiredArtifacts: ["Art A"],
            producesArtifacts: ["Art B"]
        )

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .finalOnly
        let team = Team(
            name: "Test", roles: [supervisorRole, roleA, roleB],
            artifacts: [], settings: settings, graphLayout: TeamGraphLayout()
        )
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let stepAID = "a"
        let stepBID = "b"

        // Simulate the race state: A's step is .done, B is already .working
        // B's step is .needsSupervisorInput so the engine transitions immediately
        // (avoids multiple Task.sleep iterations that don't work with synchronous XCTest wait)
        let stepA = StepExecution(
            id: stepAID, role: .softwareEngineer,
            title: "A", status: .done, artifacts: [Artifact(name: "Art A")]
        )
        let stepB = StepExecution(
            id: stepBID, role: .softwareEngineer,
            title: "B", status: .needsSupervisorInput,
            needsSupervisorInput: true, supervisorQuestion: "What next?"
        )
        let run = Run(
            id: 0,
            steps: [stepA, stepB],
            roleStatuses: ["a": .working, "b": .working]
        )
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run]
        )
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A"]
        mockStore.stepStatusResults[stepAID] = .done
        mockStore.stepStatusResults[stepBID] = .needsSupervisorInput

        // Engine will: reconcile A (step .done → handleRoleCompleted → .done because B is .working),
        // then detect B's step .needsSupervisorInput → transition to .needsSupervisorInput.
        // All happens in one iteration — no Task.sleep needed.
        let expectation = XCTestExpectation(description: "Engine transitions to needsSupervisorInput")
        sut.onStateChanged = { state in
            if state == .needsSupervisorInput { expectation.fulfill() }
        }

        sut.start()
        wait(for: [expectation], timeout: 2.0)

        // Role A should be .done, NOT .needsAcceptance (it's not the last role)
        let aStatusCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        let lastAStatus = aStatusCalls.last?.status
        XCTAssertEqual(lastAStatus, .done,
                        "Intermediate role should be .done in .finalOnly mode, not .needsAcceptance")
        XCTAssertFalse(aStatusCalls.contains(where: { $0.status == .needsAcceptance }),
                        "Role A should never have been set to .needsAcceptance")
    }

    /// Verifies that handleRoleCompleted is a no-op when the role's status is already .done.
    /// This guards against the double-call race (reconciliation + waitForStepCompletion).
    func testHandleRoleCompleted_skipsWhenRoleAlreadyDone() {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(
            id: "a", name: "RoleA",
            requiredArtifacts: ["Supervisor Task"],
            producesArtifacts: ["Art A"]
        )

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .finalOnly
        let team = Team(
            name: "Test", roles: [supervisorRole, roleA],
            artifacts: [], settings: settings, graphLayout: TeamGraphLayout()
        )
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let stepAID = "a"
        let stepA = StepExecution(
            id: stepAID, role: .softwareEngineer,
            title: "A", status: .done, artifacts: [Artifact(name: "Art A")]
        )

        // Role A is ALREADY .done (not .working) — handleRoleCompleted should skip it
        let run = Run(
            id: 0,
            steps: [stepA],
            roleStatuses: ["a": .done]
        )
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run]
        )
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A"]
        mockStore.stepStatusResults[stepAID] = .done

        // The engine should see all roles complete and transition to .done
        let expectation = XCTestExpectation(description: "Engine completes")
        sut.onStateChanged = { state in
            if state == .done { expectation.fulfill() }
        }

        sut.start()
        wait(for: [expectation], timeout: 2.0)

        // Reconciliation should NOT have called handleRoleCompleted for "a"
        // because its roleStatus is .done (not .working). Verify no re-update.
        let aStatusCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        XCTAssertTrue(aStatusCalls.isEmpty,
                       "Role A was already .done — handleRoleCompleted should not have updated it")
    }

    /// Verifies that the last role in a .finalOnly chain correctly gets .needsAcceptance.
    func testFinalOnly_lastRoleGetsNeedsAcceptance() {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(
            id: "a", name: "RoleA",
            requiredArtifacts: ["Supervisor Task"],
            producesArtifacts: ["Art A"]
        )

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .finalOnly
        let team = Team(
            name: "Test", roles: [supervisorRole, roleA],
            artifacts: [], settings: settings, graphLayout: TeamGraphLayout()
        )
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let stepAID = "a"
        let stepA = StepExecution(
            id: stepAID, role: .softwareEngineer,
            title: "A", status: .done, artifacts: [Artifact(name: "Art A")]
        )

        // Only role in the team, step is .done, role is .working → should get .needsAcceptance
        let run = Run(
            id: 0,
            steps: [stepA],
            roleStatuses: ["a": .working]
        )
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run]
        )
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A"]
        mockStore.stepStatusResults[stepAID] = .done

        let expectation = XCTestExpectation(description: "Engine reaches needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance { expectation.fulfill() }
        }

        sut.start()
        wait(for: [expectation], timeout: 2.0)

        let aStatusCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        XCTAssertTrue(aStatusCalls.contains(where: { $0.status == .needsAcceptance }),
                       "The only (last) role should get .needsAcceptance in .finalOnly mode")
    }

    /// Three-role chain A → B → C with .finalOnly: only C (last) should get .needsAcceptance.
    func testFinalOnly_threeRoleChain_onlyLastGetsNeedsAcceptance() {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])
        let roleB = makeWorkerRole(id: "b", name: "B", requiredArtifacts: ["Art A"], producesArtifacts: ["Art B"])
        let roleC = makeWorkerRole(id: "c", name: "C", requiredArtifacts: ["Art B"], producesArtifacts: ["Art C"])

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .finalOnly
        let team = Team(
            name: "Test", roles: [supervisorRole, roleA, roleB, roleC],
            artifacts: [], settings: settings, graphLayout: TeamGraphLayout()
        )
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let stepAID = "a"
        let stepBID = "b"
        let stepCID = "c"

        // State: A and B are done, C is .working with step .done
        let stepA = StepExecution(id: stepAID, role: .softwareEngineer, title: "A", status: .done, artifacts: [Artifact(name: "Art A")])
        let stepB = StepExecution(id: stepBID, role: .softwareEngineer, title: "B", status: .done, artifacts: [Artifact(name: "Art B")])
        let stepC = StepExecution(id: stepCID, role: .softwareEngineer, title: "C", status: .done, artifacts: [Artifact(name: "Art C")])

        let run = Run(
            id: 0,
            steps: [stepA, stepB, stepC],
            roleStatuses: ["a": .done, "b": .done, "c": .working]
        )
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A", "Art B", "Art C"]
        mockStore.stepStatusResults[stepAID] = .done
        mockStore.stepStatusResults[stepBID] = .done
        mockStore.stepStatusResults[stepCID] = .done

        let expectation = XCTestExpectation(description: "Engine reaches needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance { expectation.fulfill() }
        }

        sut.start()
        wait(for: [expectation], timeout: 2.0)

        // Only C should have been set to .needsAcceptance
        let cCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "c" }
        XCTAssertTrue(cCalls.contains(where: { $0.status == .needsAcceptance }),
                       "Last role C should get .needsAcceptance")

        // A and B should NOT have been touched (already .done, guard prevents re-entry)
        let aCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        let bCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "b" }
        XCTAssertTrue(aCalls.isEmpty, "Role A already .done — should not be updated again")
        XCTAssertTrue(bCalls.isEmpty, "Role B already .done — should not be updated again")
    }

    // MARK: - Observer Roles Skipped in finalOnly (Round 4 regression)

    /// Observer roles (no required/produced artifacts, not Supervisor) should not block
    /// the "last role" check in finalOnly mode.
    func testFinalOnly_ObserverRolesSkipped_InLastRoleCheck() {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(
            id: "worker", name: "Worker",
            requiredArtifacts: ["Supervisor Task"],
            producesArtifacts: ["Art"]
        )
        // Observer: no required, no produced artifacts, not supervisor
        let observerRole = TeamRoleDefinition(
            id: "observer",
            name: "Observer",
            prompt: "You observe.",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
        )

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .finalOnly
        let team = Team(
            name: "Test", roles: [supervisorRole, workerRole, observerRole],
            artifacts: [], settings: settings, graphLayout: TeamGraphLayout()
        )
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let workerStepID = "worker"
        let workerStep = StepExecution(
            id: workerStepID, role: .softwareEngineer,
            title: "Worker", status: .done,
            artifacts: [Artifact(name: "Art")]
        )

        // Worker is .working (step done), Observer is .idle (skipped by engine)
        let run = Run(
            id: 0,
            steps: [workerStep],
            roleStatuses: ["worker": .working, "observer": .idle]
        )
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run]
        )
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art"]
        mockStore.stepStatusResults[workerStepID] = .done

        let expectation = XCTestExpectation(description: "Engine reaches needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance { expectation.fulfill() }
        }

        sut.start()
        wait(for: [expectation], timeout: 2.0)

        // Worker should get .needsAcceptance (observer doesn't block "last" check)
        let workerCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "worker" }
        XCTAssertTrue(workerCalls.contains(where: { $0.status == .needsAcceptance }),
                       "Worker should get .needsAcceptance — observer must not block last-role check")

        // Observer should NOT get .needsAcceptance
        let observerCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "observer" }
        XCTAssertFalse(observerCalls.contains(where: { $0.status == .needsAcceptance }),
                        "Observer should not get .needsAcceptance")
    }
}
