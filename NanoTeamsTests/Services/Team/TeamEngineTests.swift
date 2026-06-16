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

    func setLastErrorMessageForUI(_ message: String) {
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

    func testStart_whenNeedsAcceptance_ignored() async {
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
        await fulfillment(of: [expectation], timeout: 2.0)

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

    func testNotifyExternalEvent_resumesFromNeedsAcceptance() async {
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
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .needsAcceptance)

        // Mark the role as accepted so the engine can proceed after resume
        mockStore.activeTask?.runs[0].roleStatuses["eng"] = .done

        sut.notifyExternalEvent()

        XCTAssertEqual(sut.state, .running)
    }

    // MARK: - 15. testNotifyExternalEvent_resumesFromNeedsSupervisorInput

    func testNotifyExternalEvent_resumesFromNeedsSupervisorInput() async {
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
        await fulfillment(of: [expectation], timeout: 2.0)
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

    func testSetAutoIterationLimit_clampsToMin1() async {
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
        await fulfillment(of: [expectation], timeout: 5.0)

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
        await fulfillment(of: [expectation2], timeout: 5.0)

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

    func testPause_fromNeedsAcceptance_setsPaused() async {
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
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .needsAcceptance)

        sut.pause()

        XCTAssertEqual(sut.state, .paused)
    }

    func testPause_fromNeedsSupervisorInput_setsPaused() async {
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
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .needsSupervisorInput)

        sut.pause()

        XCTAssertEqual(sut.state, .paused)
    }

    // MARK: - notifyExternalEvent from .done and .failed

    func testNotifyExternalEvent_resumesFromDone() async {
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
        await fulfillment(of: [doneExpectation], timeout: 2.0)
        XCTAssertEqual(sut.state, .done)

        // Simulate restartRole: reset the role to .idle and step to .pending
        mockStore.activeTask?.runs[0].roleStatuses["eng"] = .idle
        mockStore.activeTask?.runs[0].steps[0].status = .pending
        mockStore.stepStatusResults[stepID] = .pending

        // notifyExternalEvent should resume the engine from .done
        sut.notifyExternalEvent()
        XCTAssertEqual(sut.state, .running)
    }

    func testNotifyExternalEvent_resumesFromFailed() async {
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
        await fulfillment(of: [failedExpectation], timeout: 2.0)
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
    /// when a downstream role is already .working in .finalOnly mode. In finalOnly no producing
    /// role is gated per-role, so every role completes to .done — this guards that intermediate
    /// completions don't surface a spurious per-role acceptance regardless of reconcile timing.
    func testFinalOnly_intermediateRoleGetsDone_whenDownstreamIsWorking() async {
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
        await fulfillment(of: [expectation], timeout: 2.0)

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
    func testHandleRoleCompleted_skipsWhenRoleAlreadyDone() async {
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
        await fulfillment(of: [expectation], timeout: 2.0)

        // Reconciliation should NOT have called handleRoleCompleted for "a"
        // because its roleStatus is .done (not .working). Verify no re-update.
        let aStatusCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        XCTAssertTrue(aStatusCalls.isEmpty,
                       "Role A was already .done — handleRoleCompleted should not have updated it")
    }

    /// Fix B load-bearing invariant: a role flagged `.revisionRequested` (the held
    /// requester, whose `.running` step completes naturally after the change request)
    /// must NOT be clobbered back to `.done`/`.needsAcceptance` by
    /// `handleRoleCompleted` — its `.working` guard short-circuits. Without this the
    /// requester would lose its revision flag and never re-run against the upstream's
    /// fresh artifact. Drives `handleRoleCompleted` directly.
    func testHandleRoleCompleted_skipsWhenRoleRevisionRequested() async {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(
            id: "a", name: "RoleA",
            requiredArtifacts: ["Supervisor Task"],
            producesArtifacts: ["Art A"]
        )
        let team = Team(
            name: "Test", roles: [supervisorRole, roleA],
            artifacts: [], settings: .default, graphLayout: TeamGraphLayout()
        )
        mockStore.activeTeam = team
        mockStore.teamSettings = .default

        // Step completed (.done) but the role is flagged .revisionRequested (held).
        let stepA = StepExecution(
            id: "a", role: .softwareEngineer,
            title: "A", status: .done, artifacts: [Artifact(name: "Art A")]
        )
        let run = Run(id: 0, steps: [stepA], roleStatuses: ["a": .revisionRequested])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])

        await sut.handleRoleCompleted(roleID: "a")

        let aCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        XCTAssertTrue(aCalls.isEmpty,
                      "handleRoleCompleted must skip a .revisionRequested role (it only acts on .working) — the held requester keeps its revision flag and re-runs after the upstream")
    }

    /// In .finalOnly the last role is NOT gated per-role — it goes straight to .done and the
    /// engine reaches .done (the task-level final review is the sole approval). Pins the
    /// "Final Result Only shows only the final-review window, not a per-role card" fix.
    func testFinalOnly_lastRoleGetsDone_notNeedsAcceptance() async {
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

        // Only role in the team, step is .done, role is .working → should get .done (not gated)
        let run = Run(
            id: 0,
            steps: [stepA],
            roleStatuses: ["a": .working]
        )
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run]
        )
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A"]
        mockStore.stepStatusResults[stepAID] = .done

        let expectation = XCTestExpectation(description: "Engine reaches done")
        sut.onStateChanged = { state in
            if state == .done { expectation.fulfill() }
        }

        sut.start()
        await fulfillment(of: [expectation], timeout: 2.0)

        let aStatusCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        XCTAssertEqual(aStatusCalls.last?.status, .done,
                       "The only (last) role should get .done in .finalOnly mode")
        XCTAssertFalse(aStatusCalls.contains(where: { $0.status == .needsAcceptance }),
                        "finalOnly must NOT gate the last role with .needsAcceptance")
    }

    /// Three-role chain A → B → C with .finalOnly: NO role is gated per-role; C goes to .done
    /// and the engine reaches .done (final review is the sole approval).
    func testFinalOnly_threeRoleChain_noRoleGetsNeedsAcceptance() async {
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

        let expectation = XCTestExpectation(description: "Engine reaches done")
        sut.onStateChanged = { state in
            if state == .done { expectation.fulfill() }
        }

        sut.start()
        await fulfillment(of: [expectation], timeout: 2.0)

        // C (last) should go to .done, NOT .needsAcceptance
        let cCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "c" }
        XCTAssertEqual(cCalls.last?.status, .done, "Last role C should get .done in .finalOnly")
        XCTAssertFalse(cCalls.contains(where: { $0.status == .needsAcceptance }),
                        "No role should be gated with .needsAcceptance in .finalOnly")

        // A and B should NOT have been touched (already .done, guard prevents re-entry)
        let aCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        let bCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "b" }
        XCTAssertTrue(aCalls.isEmpty, "Role A already .done — should not be updated again")
        XCTAssertTrue(bCalls.isEmpty, "Role B already .done — should not be updated again")
    }

    // MARK: - Observer Roles Skipped in finalOnly (Round 4 regression)

    /// Observer roles (no required/produced artifacts, not Supervisor) must not block
    /// completion in finalOnly: the lone worker goes .done and the engine reaches .done
    /// with the observer skipped by `allRolesComplete`. No per-role acceptance is involved.
    func testFinalOnly_ObserverRolesSkipped_doesNotBlockCompletion() async {
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

        let expectation = XCTestExpectation(description: "Engine reaches done")
        sut.onStateChanged = { state in
            if state == .done { expectation.fulfill() }
        }

        sut.start()
        await fulfillment(of: [expectation], timeout: 2.0)

        // Worker goes .done (finalOnly does not gate it); observer must not block completion.
        let workerCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "worker" }
        XCTAssertEqual(workerCalls.last?.status, .done,
                       "Worker should get .done — observer must not block completion")
        XCTAssertFalse(workerCalls.contains(where: { $0.status == .needsAcceptance }),
                        "finalOnly must not gate the worker with .needsAcceptance")

        // Observer is never gated with .needsAcceptance (it's marked .done at completion).
        let observerCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "observer" }
        XCTAssertFalse(observerCalls.contains(where: { $0.status == .needsAcceptance }),
                        "Observer should not get .needsAcceptance")
    }

    // MARK: - finalOnly / customCheckpoints routing corner cases

    /// Two INDEPENDENT terminal producing roles (each requires only "Supervisor Task", neither
    /// depends on the other) in .finalOnly: BOTH go .done, NEITHER is gated with .needsAcceptance,
    /// and the engine reaches .done having NEVER transitioned through .needsAcceptance. Old code
    /// would gate whichever finished last (it appeared "last to complete"); the fix removes that.
    func testFinalOnly_twoParallelTerminalRoles_bothDone_neverNeedsAcceptance() async {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])
        let roleB = makeWorkerRole(id: "b", name: "B", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art B"])

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .finalOnly
        mockStore.activeTeam = Team(name: "Test", roles: [supervisorRole, roleA, roleB],
                                    artifacts: [], settings: settings, graphLayout: TeamGraphLayout())
        mockStore.teamSettings = settings

        let stepA = StepExecution(id: "a", role: .softwareEngineer, title: "A", status: .done, artifacts: [Artifact(name: "Art A")])
        let stepB = StepExecution(id: "b", role: .softwareEngineer, title: "B", status: .done, artifacts: [Artifact(name: "Art B")])
        let run = Run(id: 0, steps: [stepA, stepB], roleStatuses: ["a": .working, "b": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A", "Art B"]
        mockStore.stepStatusResults["a"] = .done
        mockStore.stepStatusResults["b"] = .done

        var seenStates: [TeamEngineState] = []
        let expectation = XCTestExpectation(description: "Engine reaches done")
        sut.onStateChanged = { state in
            seenStates.append(state)
            if state == .done { expectation.fulfill() }
        }

        sut.start()
        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }.last?.status, .done)
        XCTAssertEqual(mockStore.updateRoleStatusCalls.filter { $0.roleID == "b" }.last?.status, .done)
        XCTAssertFalse(mockStore.updateRoleStatusCalls.contains { $0.status == .needsAcceptance },
                       "finalOnly: no parallel terminal role should be gated with .needsAcceptance")
        XCTAssertFalse(seenStates.contains(.needsAcceptance),
                       "finalOnly: engine must never transition through .needsAcceptance")
    }

    /// customCheckpoints with the checkpoint on an INTERMEDIATE role and the other (terminal-like)
    /// role NOT a checkpoint: only the checkpoint role is gated. Pins that the last role is no
    /// longer auto-gated — only Supervisor-selected checkpoints gate.
    func testCustomCheckpoints_checkpointOnIntermediate_otherRoleNotGated() async {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])
        let roleB = makeWorkerRole(id: "b", name: "B", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art B"])

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .customCheckpoints
        settings.acceptanceCheckpoints = ["a"]   // only A is a checkpoint
        mockStore.activeTeam = Team(name: "Test", roles: [supervisorRole, roleA, roleB],
                                    artifacts: [], settings: settings, graphLayout: TeamGraphLayout())
        mockStore.teamSettings = settings

        let stepA = StepExecution(id: "a", role: .softwareEngineer, title: "A", status: .done, artifacts: [Artifact(name: "Art A")])
        let stepB = StepExecution(id: "b", role: .softwareEngineer, title: "B", status: .done, artifacts: [Artifact(name: "Art B")])
        let run = Run(id: 0, steps: [stepA, stepB], roleStatuses: ["a": .working, "b": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A", "Art B"]
        mockStore.stepStatusResults["a"] = .done
        mockStore.stepStatusResults["b"] = .done

        let expectation = XCTestExpectation(description: "Engine reaches needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance { expectation.fulfill() }
        }

        sut.start()
        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }.last?.status, .needsAcceptance,
                       "Checkpoint role A should be gated")
        let bCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "b" }
        XCTAssertEqual(bCalls.last?.status, .done, "Non-checkpoint role B should go .done")
        XCTAssertFalse(bCalls.contains { $0.status == .needsAcceptance },
                       "Non-checkpoint role B must NOT be auto-gated as the last role")
    }

    /// A step at `.needsApproval` (the advisory open-ended-role review path) reconciles to role
    /// `.needsAcceptance` REGARDLESS of acceptance mode — it does NOT route through
    /// `shouldRequestAcceptance`. Pins that the finalOnly fix did not alter this independent path.
    func testNeedsApprovalStep_routesToNeedsAcceptance_evenInFinalOnly() async {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .finalOnly
        mockStore.activeTeam = Team(name: "Test", roles: [supervisorRole, roleA],
                                    artifacts: [], settings: settings, graphLayout: TeamGraphLayout())
        mockStore.teamSettings = settings

        // Step is .needsApproval (NOT .done) — the advisory review path, reconciled directly.
        let stepA = StepExecution(id: "a", role: .softwareEngineer, title: "A", status: .needsApproval)
        let run = Run(id: 0, steps: [stepA], roleStatuses: ["a": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]
        mockStore.stepStatusResults["a"] = .needsApproval

        let expectation = XCTestExpectation(description: "Engine reaches needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance { expectation.fulfill() }
        }

        sut.start()
        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }.last?.status, .needsAcceptance,
                       ".needsApproval step → role .needsAcceptance regardless of finalOnly")
    }

    /// Contrast / regression guard: the fix did NOT touch .afterEachRole. The single (last) role
    /// still gets gated with .needsAcceptance and the engine stops at .needsAcceptance.
    func testAfterEachRole_singleRole_getsNeedsAcceptance() async {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .afterEachRole
        mockStore.activeTeam = Team(name: "Test", roles: [supervisorRole, roleA],
                                    artifacts: [], settings: settings, graphLayout: TeamGraphLayout())
        mockStore.teamSettings = settings

        let stepA = StepExecution(id: "a", role: .softwareEngineer, title: "A", status: .done, artifacts: [Artifact(name: "Art A")])
        let run = Run(id: 0, steps: [stepA], roleStatuses: ["a": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A"]
        mockStore.stepStatusResults["a"] = .done

        let expectation = XCTestExpectation(description: "Engine reaches needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance { expectation.fulfill() }
        }

        sut.start()
        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }.last?.status, .needsAcceptance,
                       "afterEachRole still gates the last role — fix is finalOnly/customCheckpoints only")
    }

    /// The effective acceptance MODE can come from a per-task override (`task.acceptanceMode`),
    /// not just the team default. A per-task `.finalOnly` override must beat an `.afterEachRole`
    /// team default — the role goes `.done` (no per-role gate). Pins `effectiveAcceptanceMode`
    /// resolution at the engine layer (the fix must apply via the override path, not only the default).
    func testFinalOnly_perTaskModeOverride_beatsAfterEachRoleTeamDefault() async {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .afterEachRole   // team default WOULD gate every role
        mockStore.activeTeam = Team(name: "Test", roles: [supervisorRole, roleA],
                                    artifacts: [], settings: settings, graphLayout: TeamGraphLayout())
        mockStore.teamSettings = settings

        let stepA = StepExecution(id: "a", role: .softwareEngineer, title: "A", status: .done, artifacts: [Artifact(name: "Art A")])
        let run = Run(id: 0, steps: [stepA], roleStatuses: ["a": .working])
        // Per-task override flips the EFFECTIVE mode to .finalOnly.
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal",
                                        runs: [run], acceptanceMode: .finalOnly)
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A"]
        mockStore.stepStatusResults["a"] = .done

        let expectation = XCTestExpectation(description: "Engine reaches done")
        sut.onStateChanged = { state in
            if state == .done { expectation.fulfill() }
        }

        sut.start()
        await fulfillment(of: [expectation], timeout: 2.0)

        let aCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        XCTAssertEqual(aCalls.last?.status, .done,
                       "Per-task .finalOnly override must win over the afterEachRole team default")
        XCTAssertFalse(aCalls.contains { $0.status == .needsAcceptance },
                       "finalOnly (via per-task override) must not gate the role")
    }

    /// Symmetric direction: a per-task override can also ADD gating. A `.afterEachRole` per-task
    /// override over a `.finalOnly` team default must gate the role with `.needsAcceptance` (the
    /// team default alone would have let it through as `.done`). Guards against a subtler bug than
    /// the remove-gating test — e.g. reading the override for the mode but the team default for the
    /// gate decision would pass the remove case yet silently drop the tightened review here.
    func testAfterEachRole_perTaskModeOverride_beatsFinalOnlyTeamDefault() async {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .finalOnly   // team default would NOT gate
        mockStore.activeTeam = Team(name: "Test", roles: [supervisorRole, roleA],
                                    artifacts: [], settings: settings, graphLayout: TeamGraphLayout())
        mockStore.teamSettings = settings

        let stepA = StepExecution(id: "a", role: .softwareEngineer, title: "A", status: .done, artifacts: [Artifact(name: "Art A")])
        let run = Run(id: 0, steps: [stepA], roleStatuses: ["a": .working])
        // Per-task override flips the EFFECTIVE mode to .afterEachRole (which gates every role).
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal",
                                        runs: [run], acceptanceMode: .afterEachRole)
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A"]
        mockStore.stepStatusResults["a"] = .done

        let expectation = XCTestExpectation(description: "Engine reaches needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance { expectation.fulfill() }
        }

        sut.start()
        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }.last?.status, .needsAcceptance,
                       "Per-task .afterEachRole override must win over the finalOnly team default and ADD the gate")
    }

    /// The effective CHECKPOINTS can come from a per-task override (`task.acceptanceCheckpoints`)
    /// that differs from the team settings. The engine must gate by the per-task override: role B
    /// (in the override `["b"]`) gates; role A (only in the team settings `["a"]`) does NOT.
    /// Pins `effectiveCheckpoints` resolution at the engine layer.
    func testCustomCheckpoints_perTaskCheckpointOverride_winsOverTeamSettings() async {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])
        let roleB = makeWorkerRole(id: "b", name: "B", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art B"])

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .customCheckpoints
        settings.acceptanceCheckpoints = ["a"]   // team-settings checkpoint = A
        mockStore.activeTeam = Team(name: "Test", roles: [supervisorRole, roleA, roleB],
                                    artifacts: [], settings: settings, graphLayout: TeamGraphLayout())
        mockStore.teamSettings = settings

        let stepA = StepExecution(id: "a", role: .softwareEngineer, title: "A", status: .done, artifacts: [Artifact(name: "Art A")])
        let stepB = StepExecution(id: "b", role: .softwareEngineer, title: "B", status: .done, artifacts: [Artifact(name: "Art B")])
        let run = Run(id: 0, steps: [stepA, stepB], roleStatuses: ["a": .working, "b": .working])
        // Per-task override switches the checkpoint from A (team settings) to B.
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal",
                                        runs: [run], acceptanceCheckpoints: ["b"])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A", "Art B"]
        mockStore.stepStatusResults["a"] = .done
        mockStore.stepStatusResults["b"] = .done

        let expectation = XCTestExpectation(description: "Engine reaches needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance { expectation.fulfill() }
        }

        sut.start()
        await fulfillment(of: [expectation], timeout: 2.0)

        let aCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        XCTAssertEqual(aCalls.last?.status, .done,
                       "Role A is in the TEAM checkpoints but NOT the per-task override → not gated")
        XCTAssertFalse(aCalls.contains { $0.status == .needsAcceptance })
        XCTAssertEqual(mockStore.updateRoleStatusCalls.filter { $0.roleID == "b" }.last?.status, .needsAcceptance,
                       "Role B is in the per-task checkpoint override → gated")
    }

    // MARK: - Acceptance gate RELEASE (gate → accept → resume → proceed)

    /// A customCheckpoints gate is a real, releasable pause. While the checkpoint role is
    /// `.needsAcceptance` the engine halts the WHOLE run — the downstream role does NOT start.
    /// Once the Supervisor accepts it (role → `.accepted`) and an external event fires, the engine
    /// resumes and starts the downstream role. The gating tests prove the engine STOPS; this proves
    /// it RELEASES (the existing resume test only checks the state flips to `.running`).
    func testCustomCheckpoints_acceptingGatedCheckpoint_releasesEngine_andStartsDownstream() async {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])
        let roleB = makeWorkerRole(id: "b", name: "B", requiredArtifacts: ["Art A"], producesArtifacts: ["Art B"])

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .customCheckpoints
        settings.acceptanceCheckpoints = ["a"]   // A is a checkpoint that gates progression
        mockStore.activeTeam = Team(name: "Test", roles: [supervisorRole, roleA, roleB],
                                    artifacts: [], settings: settings, graphLayout: TeamGraphLayout())
        mockStore.teamSettings = settings

        // A finished (step .done); B is idle, downstream of A's artifact.
        let stepA = StepExecution(id: "a", role: .softwareEngineer, title: "A", status: .done, artifacts: [Artifact(name: "Art A")])
        let run = Run(id: 0, steps: [stepA], roleStatuses: ["a": .working, "b": .idle])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A"]
        mockStore.findOrCreateStepResults = ["b": "b_step"]
        mockStore.stepStatusResults["b_step"] = .done

        // Phase 1: engine halts at the checkpoint; B must NOT have started.
        let gated = XCTestExpectation(description: "Engine halts at needsAcceptance")
        sut.onStateChanged = { state in if state == .needsAcceptance { gated.fulfill() } }
        sut.start()
        await fulfillment(of: [gated], timeout: 2.0)

        XCTAssertEqual(mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }.last?.status, .needsAcceptance)
        XCTAssertFalse(mockStore.findOrCreateStepCalls.contains("b"),
                       "Downstream B must NOT start while the checkpoint is awaiting acceptance")

        // Phase 2: Supervisor accepts A → external event → engine resumes and starts B.
        let proceeded = XCTestExpectation(description: "Engine resumes and completes")
        sut.onStateChanged = { state in if state == .done { proceeded.fulfill() } }
        mockStore.activeTask?.runs[0].roleStatuses["a"] = .accepted
        sut.notifyExternalEvent()
        await fulfillment(of: [proceeded], timeout: 2.0)

        XCTAssertTrue(mockStore.findOrCreateStepCalls.contains("b"),
                      "Downstream B must start once the checkpoint is accepted")
    }

    /// Multiple checkpoints: accepting ONE does not release the run while another checkpoint is
    /// still pending — the engine stays gated until ALL checkpoints are accepted.
    func testCustomCheckpoints_multipleCheckpoints_engineStaysPausedUntilAllAccepted() async {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])
        let roleB = makeWorkerRole(id: "b", name: "B", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art B"])

        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .customCheckpoints
        settings.acceptanceCheckpoints = ["a", "b"]   // BOTH are checkpoints
        mockStore.activeTeam = Team(name: "Test", roles: [supervisorRole, roleA, roleB],
                                    artifacts: [], settings: settings, graphLayout: TeamGraphLayout())
        mockStore.teamSettings = settings

        let stepA = StepExecution(id: "a", role: .softwareEngineer, title: "A", status: .done, artifacts: [Artifact(name: "Art A")])
        let stepB = StepExecution(id: "b", role: .softwareEngineer, title: "B", status: .done, artifacts: [Artifact(name: "Art B")])
        let run = Run(id: 0, steps: [stepA, stepB], roleStatuses: ["a": .working, "b": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A", "Art B"]

        // Phase 1: both gated → engine halts at needsAcceptance.
        let gated = XCTestExpectation(description: "Engine halts at needsAcceptance")
        sut.onStateChanged = { state in if state == .needsAcceptance { gated.fulfill() } }
        sut.start()
        await fulfillment(of: [gated], timeout: 2.0)

        // Phase 2: accept ONLY A → engine re-evaluates but B is still pending → stays gated.
        let reGated = XCTestExpectation(description: "Engine re-enters needsAcceptance with B still pending")
        sut.onStateChanged = { state in if state == .needsAcceptance { reGated.fulfill() } }
        mockStore.activeTask?.runs[0].roleStatuses["a"] = .accepted
        sut.notifyExternalEvent()
        await fulfillment(of: [reGated], timeout: 2.0)
        XCTAssertEqual(sut.state, .needsAcceptance, "One pending checkpoint must keep the run gated")

        // Phase 3: accept B → all checkpoints accepted → engine completes.
        let done = XCTestExpectation(description: "Engine completes once all accepted")
        sut.onStateChanged = { state in if state == .done { done.fulfill() } }
        mockStore.activeTask?.runs[0].roleStatuses["b"] = .accepted
        sut.notifyExternalEvent()
        await fulfillment(of: [done], timeout: 2.0)
        XCTAssertEqual(sut.state, .done)
    }

    // MARK: - Restart re-execution (cancelRoleTasks)

    /// A returned (normally-completed) Task is NOT `.isCancelled`. This is the
    /// condition that makes `startRoles`' skip-guard skip a restarted role forever.
    private func makeFinishedTask() async -> Task<Void, Never> {
        let t = Task<Void, Never> {}
        _ = await t.value
        return t
    }

    func testCancelRoleTasks_removesOnlyNamedRoles() async {
        let a = await makeFinishedTask()
        let b = await makeFinishedTask()
        sut.roleTasks["a"] = a
        sut.roleTasks["b"] = b

        sut.cancelRoleTasks(for: ["a"])

        XCTAssertNil(sut.roleTasks["a"], "named role's task should be cancelled + removed")
        XCTAssertNotNil(sut.roleTasks["b"], "unnamed role's task should be untouched")
    }

    /// Reproduces the restart bug: a lingering completed task makes `startRoles`
    /// skip the role, so it never re-runs. Drives `startRoles` directly (NOT `start()`,
    /// which calls `stop()` → `roleTasks.removeAll()` and would mask the bug).
    func testStartRoles_skipsRoleWithLingeringCompletedTask() async {
        let roleID = "eng"
        let stepID = "eng-step"
        mockStore.findOrCreateStepResults[roleID] = stepID

        let stale = await makeFinishedTask()
        XCTAssertFalse(stale.isCancelled, "precondition: a returned Task is not cancelled")
        sut.roleTasks[roleID] = stale

        await sut.startRoles(roleIDs: [roleID])

        XCTAssertTrue(mockStore.runStepCalls.isEmpty,
                      "stale non-cancelled task makes the skip-guard skip the role — it never re-runs")
        XCTAssertTrue(mockStore.findOrCreateStepCalls.isEmpty)
    }

    /// The fix: clearing the stale task lets `startRoles` re-spawn and run the role.
    func testCancelRoleTasks_thenStartRoles_reSpawnsRole() async {
        let supervisorRole = makeSupervisorRole()
        let workerRole = makeWorkerRole(id: "eng", name: "Engineer", producesArtifacts: ["Code"])
        mockStore.activeTeam = makeTeam(roles: [supervisorRole, workerRole])
        let run = Run(id: 0, roleStatuses: ["eng": .idle])
        mockStore.activeTask = NTMSTask(id: 0, title: "Test", supervisorTask: "Build", runs: [run])

        let roleID = "eng"
        let stepID = "eng-step"
        mockStore.findOrCreateStepResults[roleID] = stepID
        mockStore.stepStatusResults[stepID] = .done  // waitForStepCompletion returns promptly

        let stale = await makeFinishedTask()
        sut.roleTasks[roleID] = stale

        sut.cancelRoleTasks(for: [roleID])
        await sut.startRoles(roleIDs: [roleID])
        await sut.roleTasks[roleID]?.value  // wait for the spawned role task to finish

        XCTAssertTrue(mockStore.runStepCalls.contains(stepID),
                      "after clearing the stale task, the role is re-spawned and runStep is called")
    }

    // MARK: - cancelRoleTasks corner cases

    func testCancelRoleTasks_emptySetAndUnknownRole_areNoOps() async {
        let keep = await makeFinishedTask()
        sut.roleTasks["keep"] = keep

        sut.cancelRoleTasks(for: [])
        XCTAssertNotNil(sut.roleTasks["keep"], "empty set must not touch the registry")

        sut.cancelRoleTasks(for: ["does-not-exist"])
        XCTAssertNotNil(sut.roleTasks["keep"], "cancelling an absent role must not touch other entries")
        XCTAssertNil(sut.roleTasks["does-not-exist"])
    }

    /// A genuinely live (suspended) task — the `.working` mid-flight restart case.
    /// `cancelRoleTasks` must actually CANCEL it (so `waitForStepCompletion`'s
    /// `while !Task.isCancelled` exits), not merely drop the dictionary reference.
    func testCancelRoleTasks_cancelsLiveTask() async {
        let started = expectation(description: "live task started")
        let live = Task<Void, Never> {
            started.fulfill()
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        }
        await fulfillment(of: [started], timeout: 2.0)
        sut.roleTasks["live"] = live

        sut.cancelRoleTasks(for: ["live"])

        XCTAssertNil(sut.roleTasks["live"], "task must be removed from the registry")
        _ = await live.value  // returns only because the task observed cancellation
        XCTAssertTrue(live.isCancelled,
                      "cancelRoleTasks must cancel the task, not just drop the reference")
    }
}
