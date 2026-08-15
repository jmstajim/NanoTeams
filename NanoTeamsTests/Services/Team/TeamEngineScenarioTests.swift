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

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        mockStore = MockTeamEngineStore()
        sut = TeamEngine(store: mockStore)
    }

    override func tearDown() async throws {
        sut.stop()
        sut = nil
        mockStore = nil
        MonotonicClock.shared.reset()
        try await super.tearDown()
    }

    // MARK: - Scenario 1: afterEachRole acceptance

    /// In afterEachRole mode, every completing role should get .needsAcceptance,
    /// not just the last one (unlike finalOnly).
    func testAfterEachRole_eachCompletingRoleGetsNeedsAcceptance() async {
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
        await fulfillment(of: [expectation], timeout: 2.0)

        // In afterEachRole, role A should get .needsAcceptance (not .done)
        let aCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        XCTAssertTrue(aCalls.contains(where: { $0.status == .needsAcceptance }),
                       "In afterEachRole mode, every completing role should get .needsAcceptance")
    }

    // MARK: - Scenario 2: customCheckpoints acceptance

    /// In customCheckpoints mode, only Supervisor-selected checkpoint roles get .needsAcceptance.
    /// Non-checkpoint roles (including the terminal role) get .done — the final deliverable is
    /// covered by the task-level final review, not a per-role gate.
    func testCustomCheckpoints_onlyCheckpointRolesGetNeedsAcceptance() async {
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

        // A is done and working — engine should reconcile A to .done (NOT a checkpoint)
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
        await fulfillment(of: [expectation], timeout: 2.0)

        // A should be .done (not a checkpoint)
        let aCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "a" }
        XCTAssertTrue(aCalls.contains(where: { $0.status == .done }),
                       "Non-checkpoint role A should get .done")
        XCTAssertFalse(aCalls.contains(where: { $0.status == .needsAcceptance }),
                        "Non-checkpoint role A should NOT get .needsAcceptance")

        // B should be .needsAcceptance (it is a checkpoint)
        let bCalls = mockStore.updateRoleStatusCalls.filter { $0.roleID == "b" }
        XCTAssertTrue(bCalls.contains(where: { $0.status == .needsAcceptance }),
                       "Checkpoint role B should get .needsAcceptance")
    }

    // MARK: - Scenario 3: parallel flow

    /// After a shared dependency is produced, all roles requiring it should become ready simultaneously.
    func testParallelFlow_twoRolesStartSimultaneously() async {
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
        await fulfillment(of: [expectation], timeout: 3.0)

        // Both iOS and Android should have been started (findOrCreateStep called for both)
        XCTAssertTrue(mockStore.findOrCreateStepCalls.contains("ios"),
                       "iOS should have been started after Design is done")
        XCTAssertTrue(mockStore.findOrCreateStepCalls.contains("android"),
                       "Android should have been started after Design is done")
    }

    // MARK: - Scenario 4: diamond dependency

    /// A role requiring multiple artifacts should only start when ALL are produced.
    func testDiamondDependency_roleWaitsForMultipleInputs() async {
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
        await fulfillment(of: [expectation], timeout: 3.0)

        // C should have been started (both dependencies satisfied)
        XCTAssertTrue(mockStore.findOrCreateStepCalls.contains("c"),
                       "Role C should start when both Art A and Art B are produced")
    }

    // MARK: - Scenario 5: revision cascade

    /// A role with .revisionRequested status should be restarted by the engine.
    func testRevisionCascade_revisionRequestedRolesGetRestarted() async {
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
        sut.onStateChanged = { state in
            if state == .needsAcceptance || state == .done || state == .failed {
                expectation.fulfill()
            }
        }

        sut.start()
        await fulfillment(of: [expectation], timeout: 3.0)

        // resetStepForRevision should have been called for A's step
        XCTAssertTrue(mockStore.resetStepForRevisionCalls.contains(stepAID),
                       "Engine should call resetStepForRevision for the revision-requested role")
    }

    /// Regression (reported bug): after request_changes, the engine must NOT start a
    /// downstream revision role while its upstream revision is still in progress.
    /// B depends on A's artifact; both are .revisionRequested. A's step is held .running
    /// (never completes), so B must remain gated and never start.
    func testRevisionCascade_downstreamDoesNotStartWhileUpstreamRevising() async {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art A"])
        let roleB = makeWorkerRole(id: "b", name: "B", requiredArtifacts: ["Art A"], producesArtifacts: ["Art B"])

        let (team, settings) = makeTeamWith(roles: [supervisorRole, roleA, roleB])
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let stepAID = "a"
        // A's step is mid-revision (.running), so it does NOT auto-complete via the
        // run-loop reconcile pass — A stays .working and B must remain gated behind it.
        let stepA = StepExecution(id: stepAID, role: .softwareEngineer, title: "A", status: .running, artifacts: [Artifact(name: "Art A")])
        let stepB = StepExecution(id: "b", role: .codeReviewer, title: "B", status: .running, artifacts: [Artifact(name: "Art B")])

        let run = Run(id: 0, steps: [stepA, stepB], roleStatuses: ["a": .revisionRequested, "b": .revisionRequested])
        mockStore.activeTask = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art A", "Art B"]
        // A's revision step keeps polling .running — so B stays gated behind A.
        mockStore.stepStatusResults[stepAID] = .running
        mockStore.findOrCreateStepResults = ["a": stepAID, "b": "b"]

        sut.start()
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertTrue(mockStore.resetStepForRevisionCalls.contains(stepAID),
                       "Upstream A's revision should start")
        XCTAssertFalse(mockStore.findOrCreateStepCalls.contains("b"),
                        "Downstream B must NOT start while A is still revising")
    }

    /// Defensive: a cyclic revision set (a⇐b, b⇐a both .revisionRequested) leaves no role
    /// startable. The engine must fail loudly rather than busy-loop to the iteration cap.
    func testRevisionCascade_cyclicRevisionRolesFailLoudly() async {
        let supervisorRole = makeSupervisorRole()
        let roleA = makeWorkerRole(id: "a", name: "A", requiredArtifacts: ["Art B"], producesArtifacts: ["Art A"])
        let roleB = makeWorkerRole(id: "b", name: "B", requiredArtifacts: ["Art A"], producesArtifacts: ["Art B"])

        let (team, settings) = makeTeamWith(roles: [supervisorRole, roleA, roleB])
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let run = Run(id: 0, roleStatuses: ["a": .revisionRequested, "b": .revisionRequested])
        mockStore.activeTask = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task"]

        let expectation = XCTestExpectation(description: "Engine fails on cyclic revision")
        sut.onStateChanged = { state in
            if state == .failed { expectation.fulfill() }
        }

        sut.start()
        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(sut.state, .failed)
        // Assert on "dependency cycle" — unique to the new revision fail-loud arm.
        // (The pre-existing deadlock branch says "Execution stalled", so matching "stall"
        // would also pass if the new arm were deleted and execution fell through.)
        XCTAssertTrue(mockStore.setLastErrorMessageCalls.contains(where: { $0.lowercased().contains("dependency cycle") }),
                       "Should surface the revision dependency-cycle error rather than spin")
        XCTAssertTrue(mockStore.setLastErrorMessageCalls.contains(where: { $0.contains("[a, b]") }),
                       "Error should name the blocked roles so the Supervisor knows what to fix")
    }

    /// Regression (request_changes deadlock): when the role that requested a change is
    /// still .working, the engine must start the (upstream) target's revision in parallel
    /// rather than waiting forever on the still-working requester.
    ///
    /// Mirrors production: the TPM calls request_changes against the Software Engineer
    /// from inside its own still-.working tool loop; SWE flips to .revisionRequested while
    /// TPM stays .working. TPM is DOWNSTREAM of SWE, so it must not gate SWE's revision.
    func testRevision_startsWhileDownstreamRequesterStillWorking() async {
        let supervisorRole = makeSupervisorRole()
        let target = makeWorkerRole(id: "swe", name: "SWE", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art SWE"])
        let requester = makeWorkerRole(id: "req", name: "REQ", requiredArtifacts: ["Art SWE"], producesArtifacts: ["Release"])

        let (team, settings) = makeTeamWith(roles: [supervisorRole, target, requester])
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let sweStep = StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .done, artifacts: [Artifact(name: "Art SWE")])
        let reqStep = StepExecution(id: "req", role: .tpm, title: "REQ", status: .running, artifacts: [])

        // SWE just had a change request approved → .revisionRequested. REQ (the downstream
        // requester) is still .working executing its own step (held .running below).
        let run = Run(id: 0, steps: [sweStep, reqStep], roleStatuses: ["swe": .revisionRequested, "req": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art SWE"]
        mockStore.stepStatusResults["swe"] = .done    // after reset+runStep, the revision completes
        mockStore.stepStatusResults["req"] = .running  // held — requester never finishes
        mockStore.findOrCreateStepResults = ["swe": "swe", "req": "req"]

        sut.start()
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertTrue(mockStore.resetStepForRevisionCalls.contains("swe"),
                       "Target revision must start even though the (downstream) requesting role is still .working")
    }

    /// Re-gating pin: when a revision role is gated (its upstream is still revising) and the
    /// ONLY other working role is INDEPENDENT of it, the engine must keep waiting — NOT
    /// false-fail as a dependency cycle. Guards the `!roleStatuses.contains(.working)` cycle
    /// guard against a future refactor that narrows "working" to only revision-related roles.
    func testRevision_gatedRoleWaits_whenOnlyIndependentRoleIsWorking() async {
        let supervisorRole = makeSupervisorRole()
        let up = makeWorkerRole(id: "up", name: "UP", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art Up"])
        let down = makeWorkerRole(id: "down", name: "DOWN", requiredArtifacts: ["Art Up"], producesArtifacts: ["Art Down"])
        let indep = makeWorkerRole(id: "indep", name: "INDEP", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art Indep"])

        let (team, settings) = makeTeamWith(roles: [supervisorRole, up, down, indep])
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        // up: revision in progress (step held .running so it keeps gating down).
        // down: gated behind up. indep: an unrelated role still working.
        let upStep = StepExecution(id: "up", role: .softwareEngineer, title: "UP", status: .running, artifacts: [Artifact(name: "Art Up")])
        let downStep = StepExecution(id: "down", role: .codeReviewer, title: "DOWN", status: .done, artifacts: [Artifact(name: "Art Down")])
        let indepStep = StepExecution(id: "indep", role: .tpm, title: "INDEP", status: .running, artifacts: [])

        let run = Run(id: 0, steps: [upStep, downStep, indepStep],
                      roleStatuses: ["up": .revisionRequested, "down": .revisionRequested, "indep": .working])
        mockStore.activeTask = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art Up", "Art Down", "Art Indep"]
        mockStore.stepStatusResults["up"] = .running    // held — up stays .working, gating down
        mockStore.findOrCreateStepResults = ["up": "up", "down": "down"]

        sut.start()
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertTrue(mockStore.resetStepForRevisionCalls.contains("up"),
                       "Upstream revision should start")
        XCTAssertFalse(mockStore.findOrCreateStepCalls.contains("down"),
                        "Downstream revision must stay gated behind the still-revising upstream")
        XCTAssertNotEqual(sut.state, .failed,
                          "Must NOT false-fail as a cycle while a role is still working")
        XCTAssertFalse(mockStore.setLastErrorMessageCalls.contains(where: { $0.lowercased().contains("dependency cycle") }),
                        "No dependency-cycle error should be surfaced while work is in flight")
    }

    /// Mixed iteration: a startable revision role and an independent idle/ready role both
    /// exist. The ready role starts first (the empty-ready revision branch is skipped while
    /// readyRoleIDs is non-empty), then the revision role starts on the next iteration —
    /// neither is starved.
    func testRevision_andIndependentReadyRole_bothEventuallyStart() async {
        let supervisorRole = makeSupervisorRole()
        let swe = makeWorkerRole(id: "swe", name: "SWE", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art SWE"])
        let other = makeWorkerRole(id: "other", name: "OTHER", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art Other"])

        let (team, settings) = makeTeamWith(roles: [supervisorRole, swe, other])
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let sweStep = StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .done, artifacts: [Artifact(name: "Art SWE")])

        // swe: .revisionRequested (startable). other: .idle with satisfied deps (ready).
        let run = Run(id: 0, steps: [sweStep], roleStatuses: ["swe": .revisionRequested, "other": .idle])
        mockStore.activeTask = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art SWE", "Art Other"]
        mockStore.stepStatusResults["swe"] = .done       // revision completes after reset+runStep
        mockStore.stepStatusResults["other"] = .running   // held — keeps the engine alive
        mockStore.findOrCreateStepResults = ["swe": "swe", "other": "other"]

        sut.start()
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertTrue(mockStore.resetStepForRevisionCalls.contains("swe"),
                       "The startable revision role must eventually start")
        XCTAssertTrue(mockStore.findOrCreateStepCalls.contains("other"),
                       "The independent ready role must also start — neither is starved")
    }

    /// Un-gating handoff: a downstream revision role gated behind a revising upstream must
    /// START once the upstream's revision COMPLETES — the gate releases, it doesn't just
    /// hold. Complements `testRevision_gatedRoleWaits_...` and `testRevisionCascade_downstream...`
    /// which hold the upstream `.running` forever and so only pin the gate HOLDING.
    func testRevision_downstreamStartsAfterUpstreamRevisionCompletes() async {
        let supervisorRole = makeSupervisorRole()
        let up = makeWorkerRole(id: "up", name: "UP", requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Art Up"])
        let down = makeWorkerRole(id: "down", name: "DOWN", requiredArtifacts: ["Art Up"], producesArtifacts: ["Art Down"])

        let (team, settings) = makeTeamWith(roles: [supervisorRole, up, down])
        mockStore.activeTeam = team
        mockStore.teamSettings = settings

        let upStep = StepExecution(id: "up", role: .softwareEngineer, title: "UP", status: .done, artifacts: [Artifact(name: "Art Up")])
        let downStep = StepExecution(id: "down", role: .codeReviewer, title: "DOWN", status: .done, artifacts: [Artifact(name: "Art Down")])

        // Both .revisionRequested; down gated behind up. up's revision COMPLETES (step → .done),
        // which must release the gate so down's revision then starts.
        let run = Run(id: 0, steps: [upStep, downStep], roleStatuses: ["up": .revisionRequested, "down": .revisionRequested])
        mockStore.activeTask = NTMSTask(id: 0, title: "T", supervisorTask: "G", runs: [run])
        mockStore.producedArtifactNamesResult = ["Supervisor Task", "Art Up", "Art Down"]
        mockStore.stepStatusResults["up"] = .done    // up's revision completes → gate releases
        mockStore.stepStatusResults["down"] = .done
        mockStore.findOrCreateStepResults = ["up": "up", "down": "down"]

        let expectation = XCTestExpectation(description: "Engine reaches a terminal state")
        sut.onStateChanged = { state in
            if state == .done || state == .needsAcceptance || state == .failed { expectation.fulfill() }
        }

        sut.start()
        await fulfillment(of: [expectation], timeout: 3.0)

        XCTAssertTrue(mockStore.resetStepForRevisionCalls.contains("up"),
                       "Upstream revision should start")
        XCTAssertTrue(mockStore.resetStepForRevisionCalls.contains("down"),
                       "Downstream revision must start once the upstream revision completes (gate releases)")
        XCTAssertNotEqual(sut.state, .failed, "A valid acyclic revision cascade should complete, not fail")
    }

    // MARK: - Scenario 6: deadlock detection

    /// When no roles can start (circular dependency), the engine should fail with an error message.
    func testDeadlock_noReadyRoles_engineFails() async {
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
        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(sut.state, .failed)
        XCTAssertFalse(mockStore.setLastErrorMessageCalls.isEmpty,
                        "Engine should report an error message on deadlock")
        XCTAssertTrue(mockStore.setLastErrorMessageCalls.first?.contains("stalled") ?? false,
                       "Error message should mention stalled execution")
    }
}
