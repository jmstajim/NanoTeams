import XCTest
@testable import NanoTeams

// MARK: - Helpers (duplicated from TeamEngineTests — private there)

private func makeSupervisorRole(id: String = "supervisor-role", requiredArtifacts: [String] = ["Final Deliverable"]) -> TeamRoleDefinition {
    TeamRoleDefinition(
        id: id, name: "Supervisor", prompt: "", toolIDs: [],
        usePlanningPhase: false,
        dependencies: RoleDependencies(requiredArtifacts: requiredArtifacts, producesArtifacts: ["Supervisor Task"]),
        isSystemRole: true, systemRoleID: "supervisor"
    )
}

private func makeWorkerRole(
    id: String, name: String,
    requiredArtifacts: [String] = ["Supervisor Task"],
    producesArtifacts: [String]
) -> TeamRoleDefinition {
    TeamRoleDefinition(
        id: id, name: name, prompt: "You are \(name).", toolIDs: ["read_file"],
        usePlanningPhase: false,
        dependencies: RoleDependencies(requiredArtifacts: requiredArtifacts, producesArtifacts: producesArtifacts)
    )
}

private func makeObserverRole(id: String, name: String) -> TeamRoleDefinition {
    TeamRoleDefinition(
        id: id, name: name, prompt: "", toolIDs: [],
        usePlanningPhase: false,
        dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: [])
    )
}

private func makeTeamWith(
    roles: [TeamRoleDefinition],
    acceptanceMode: AcceptanceMode = .finalOnly,
    checkpoints: Set<String> = []
) -> (team: Team, settings: TeamSettings) {
    var settings = TeamSettings.default
    settings.defaultAcceptanceMode = acceptanceMode
    settings.acceptanceCheckpoints = checkpoints
    let team = Team(
        name: "Test Team", roles: roles, artifacts: [],
        settings: settings, graphLayout: TeamGraphLayout()
    )
    return (team, settings)
}

// MARK: - Team Engine Scenario Tests

@MainActor
final class TeamEngineScenarioTests: XCTestCase {

    var sut: TeamEngine!
    var mockStore: MockTeamEngineStore!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        mockStore = MockTeamEngineStore()
        sut = TeamEngine(store: mockStore)
    }

    override func tearDown() {
        sut.stop()
        sut = nil
        mockStore = nil
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Scenario 1: afterEachRole acceptance

    /// In afterEachRole mode, every completing role should get .needsAcceptance,
    /// not just the last one (unlike finalOnly).
    func testAfterEachRole_eachCompletingRoleGetsNeedsAcceptance() {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(
            id: "a", name: "RoleA",
            requiredArtifacts: ["Supervisor Task"],
            producesArtifacts: ["Art A"]
        )
        let (team, settings) = makeTeamWith(
            roles: [supervisorRole, roleA],
            acceptanceMode: .afterEachRole
        )
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let stepAID = "a"
        let stepA = StepExecution(
            id: stepAID, role: .softwareEngineer,
            title: "A", status: .done, artifacts: [Artifact(name: "Art A")]
        )
        let run = Run(id: 0, steps: [stepA], roleStatuses: ["a": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A"]
        mockStore.stepStatusResults[stepAID] = .done

        let expectation = XCTestExpectation(description: "Engine reaches needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance { expectation.fulfill() }
        }

        sut.start()
        wait(for: [expectation], timeout: 2.0)

        // In afterEachRole, role A should get .needsAcceptance (not .done)
        let aCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        XCTAssertTrue(aCalls.contains(where: { $0.status == .needsAcceptance }),
                       "In afterEachRole mode, every completing role should get .needsAcceptance")
    }

    // MARK: - Scenario 2: customCheckpoints acceptance

    /// In customCheckpoints mode, only checkpoint roles and the last role get .needsAcceptance.
    /// Non-checkpoint intermediate roles get .done.
    func testCustomCheckpoints_onlyCheckpointRolesGetNeedsAcceptance() {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])
        let roleB = makeWorkerRole(id: "b", name: "B", requiredArtifacts: ["Art A"], producesArtifacts: ["Art B"])

        let (team, settings) = makeTeamWith(
            roles: [supervisorRole, roleA, roleB],
            acceptanceMode: .customCheckpoints,
            checkpoints: ["b"]  // B is a checkpoint
        )
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        // A is done and working — engine should reconcile A to .done (NOT checkpoint, NOT last)
        let stepAID = "a"
        let stepA = StepExecution(
            id: stepAID, role: .softwareEngineer,
            title: "A", status: .done, artifacts: [Artifact(name: "Art A")]
        )

        // B is done and working — engine should reconcile B to .needsAcceptance (checkpoint)
        let stepBID = "b"
        let stepB = StepExecution(
            id: stepBID, role: .softwareEngineer,
            title: "B", status: .done, artifacts: [Artifact(name: "Art B")]
        )

        let run = Run(id: 0, steps: [stepA, stepB], roleStatuses: ["a": .working, "b": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A", "Art B"]
        mockStore.stepStatusResults[stepAID] = .done
        mockStore.stepStatusResults[stepBID] = .done

        let expectation = XCTestExpectation(description: "Engine reaches needsAcceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance { expectation.fulfill() }
        }

        sut.start()
        wait(for: [expectation], timeout: 2.0)

        // A should be .done (not checkpoint, not last)
        let aCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        XCTAssertTrue(aCalls.contains(where: { $0.status == .done }),
                       "Non-checkpoint role A should get .done")
        XCTAssertFalse(aCalls.contains(where: { $0.status == .needsAcceptance }),
                        "Non-checkpoint role A should NOT get .needsAcceptance")

        // B should be .needsAcceptance (checkpoint OR last)
        let bCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "b" }
        XCTAssertTrue(bCalls.contains(where: { $0.status == .needsAcceptance }),
                       "Checkpoint role B should get .needsAcceptance")
    }

    // MARK: - Scenario 3: parallel flow

    /// After a shared dependency is produced, all roles requiring it should become ready simultaneously.
    func testParallelFlow_twoRolesStartSimultaneously() {
        let supervisorRole = makeSupervisorRole()
        let designer = makeWorkerRole(
            id: "designer", name: "Designer",
            requiredArtifacts: ["Supervisor Task"],
            producesArtifacts: ["Design"]
        )
        let ios = makeWorkerRole(
            id: "ios", name: "iOS",
            requiredArtifacts: ["Design"],
            producesArtifacts: ["iOS App"]
        )
        let android = makeWorkerRole(
            id: "android", name: "Android",
            requiredArtifacts: ["Design"],
            producesArtifacts: ["Android App"]
        )

        let (team, settings) = makeTeamWith(roles: [supervisorRole, designer, ios, android])
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        // Designer is done → iOS and Android should both become ready
        let designerStepID = "designer_step"
        let iosStepID = "ios_step"
        let androidStepID = "android_step"

        let designerStep = StepExecution(
            id: designerStepID, role: .softwareEngineer,
            title: "Design", status: .done, artifacts: [Artifact(name: "Design")]
        )

        // Pre-configure findOrCreateStep results for iOS and Android
        mockStore.findOrCreateStepResults = ["ios": iosStepID, "android": androidStepID]
        // Make their steps complete immediately so engine doesn't hang
        mockStore.stepStatusResults[iosStepID] = .done
        mockStore.stepStatusResults[androidStepID] = .done
        mockStore.stepStatusResults[designerStepID] = .done

        let run = Run(
            id: 0,
            steps: [designerStep],
            roleStatuses: ["designer": .done, "ios": .idle, "android": .idle]
        )
        mockStore.activeTask = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Design"]

        let expectation = XCTestExpectation(description: "Engine completes or reaches acceptance")
        sut.onStateChanged = { state in
            if state == .needsAcceptance || state == .done { expectation.fulfill() }
        }

        sut.start()
        wait(for: [expectation], timeout: 3.0)

        // Both iOS and Android should have been started (findOrCreateStep called for both)
        XCTAssertTrue(mockStore.findOrCreateStepCalls.contains("ios"),
                       "iOS should have been started after Design is done")
        XCTAssertTrue(mockStore.findOrCreateStepCalls.contains("android"),
                       "Android should have been started after Design is done")
    }

    // MARK: - Scenario 4: diamond dependency

    /// A role requiring multiple artifacts should only start when ALL are produced.
    func testDiamondDependency_roleWaitsForMultipleInputs() {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])
        let roleB = makeWorkerRole(id: "b", name: "B", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art B"])
        let roleC = makeWorkerRole(id: "c", name: "C", requiredArtifacts: ["Art A", "Art B"], producesArtifacts: ["Art C"])

        let (team, settings) = makeTeamWith(roles: [supervisorRole, roleA, roleB, roleC])
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let stepAID = "a"
        let stepBID = "b"
        let stepCID = "c"

        // A done, B done → C should become ready
        let stepA = StepExecution(id: stepAID, role: .softwareEngineer, title: "A", status: .done, artifacts: [Artifact(name: "Art A")])
        let stepB = StepExecution(id: stepBID, role: .softwareEngineer, title: "B", status: .done, artifacts: [Artifact(name: "Art B")])

        mockStore.findOrCreateStepResults = ["c": stepCID]
        mockStore.stepStatusResults[stepAID] = .done
        mockStore.stepStatusResults[stepBID] = .done
        mockStore.stepStatusResults[stepCID] = .done

        let run = Run(
            id: 0,
            steps: [stepA, stepB],
            roleStatuses: ["a": .done, "b": .done, "c": .idle]
        )
        mockStore.activeTask = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A", "Art B"]

        let expectation = XCTestExpectation(description: "Engine reaches final state")
        sut.onStateChanged = { state in
            if state == .needsAcceptance || state == .done { expectation.fulfill() }
        }

        sut.start()
        wait(for: [expectation], timeout: 3.0)

        // C should have been started (both dependencies satisfied)
        XCTAssertTrue(mockStore.findOrCreateStepCalls.contains("c"),
                       "Role C should start when both Art A and Art B are produced")
    }

    // MARK: - Scenario 5: revision cascade

    /// A role with .revisionRequested status should be restarted by the engine.
    func testRevisionCascade_revisionRequestedRolesGetRestarted() {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])

        let (team, settings) = makeTeamWith(roles: [supervisorRole, roleA])
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let stepAID = "a"
        let stepA = StepExecution(
            id: stepAID, role: .softwareEngineer,
            title: "A", status: .done, artifacts: [Artifact(name: "Art A")]
        )

        // Role A is .revisionRequested — engine should detect and restart it
        let run = Run(id: 0, steps: [stepA], roleStatuses: ["a": .revisionRequested])
        mockStore.activeTask = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A"]
        mockStore.stepStatusResults[stepAID] = .done
        mockStore.findOrCreateStepResults = ["a": stepAID]

        // After revision starts, make step complete so engine reaches a terminal state
        // The engine will call resetStepForRevision, then runStep, then waitForStepCompletion
        let expectation = XCTestExpectation(description: "Engine processes revision")
        sut.onStateChanged = { [weak self] state in
            guard let self else { return }
            if state == .needsAcceptance || state == .done || state == .failed {
                expectation.fulfill()
            }
        }

        sut.start()
        wait(for: [expectation], timeout: 3.0)

        // resetStepForRevision should have been called for A's step
        XCTAssertTrue(mockStore.resetStepForRevisionCalls.contains(stepAID),
                       "Engine should call resetStepForRevision for the revision-requested role")
    }

    // MARK: - Scenario 6: deadlock detection

    /// When no roles can start (circular dependency), the engine should fail with an error message.
    func testDeadlock_noReadyRoles_engineFails() {
        let supervisorRole = makeSupervisorRole()
        // Circular: A requires Art B, B requires Art A
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Art B"], producesArtifacts: ["Art A"])
        let roleB = makeWorkerRole(id: "b", name: "B", requiredArtifacts: ["Art A"], producesArtifacts: ["Art B"])

        let (team, settings) = makeTeamWith(roles: [supervisorRole, roleA, roleB])
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let run = Run(id: 0, roleStatuses: ["a": .idle, "b": .idle])
        mockStore.activeTask = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]

        let expectation = XCTestExpectation(description: "Engine fails on deadlock")
        sut.onStateChanged = { state in
            if state == .failed { expectation.fulfill() }
        }

        sut.start()
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(sut.state, .failed)
        XCTAssertFalse(mockStore.setLastErrorMessageCalls.isEmpty,
                        "Engine should report an error message on deadlock")
        XCTAssertTrue(mockStore.setLastErrorMessageCalls.first?.contains("stalled") ?? false,
                       "Error message should mention stalled execution")
    }
}
