import XCTest
@testable import NanoTeams

/// Fix B (strict pipeline): `holdDownstreamForRevision` must stop downstream roles
/// caught running on a revised role's now-stale output. PEER downstream roles are
/// cancelled + forced terminal + queued for revision; the REQUESTER (which triggered
/// the change from inside its own live tool loop) is only flagged `.revisionRequested`
/// — NOT task-cancelled and NOT step-forced — so its tool-result write commits and its
/// step completes naturally (then re-runs, gated behind the target).
@MainActor
final class ChangeRequestDownstreamPauseTests: NTMSOrchestratorTestBase {

    private func seedRun(_ tid: Int) async {
        _ = await sut.mutateTask(taskID: tid) { task in
            var run = Run(id: 0, teamID: nil)
            run.steps = [
                StepExecution(id: "cr",  role: .custom(id: "cr"),  title: "CR",  status: .running),
                StepExecution(id: "tpm", role: .custom(id: "tpm"), title: "TPM", status: .running),
                StepExecution(id: "uxr", role: .custom(id: "uxr"), title: "UXR", status: .pending),
            ]
            run.roleStatuses = ["cr": .working, "tpm": .working, "uxr": .working]
            task.runs = [run]
        }
    }

    private func step(_ tid: Int, _ id: String) -> StepExecution? {
        sut.loadedTask(tid)?.runs.last?.steps.first { $0.id == id }
    }

    func testHold_peerCancelledAndQueued_requesterFlaggedOnly() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        await seedRun(tid)

        // Give both peer + requester live engine tasks and execution state.
        let engine = sut.engineForTask(tid)
        engine.roleTasks["cr"] = Task<Void, Never> { }
        engine.roleTasks["tpm"] = Task<Void, Never> { }
        sut.llmExecutionService._testInjectRunningTask(stepID: "cr", taskID: tid, runningTask: Task<Void, Never> { })
        sut.llmExecutionService._testInjectRunningTask(stepID: "tpm", taskID: tid, runningTask: Task<Void, Never> { })

        await sut.holdDownstreamForRevision(
            taskID: tid,
            runningRoleIDs: ["cr", "tpm"],
            requesterRoleID: "tpm"
        )

        // Peer (cr): forced terminal + queued for revision, engine task + exec state torn down.
        XCTAssertEqual(step(tid, "cr")?.status, .done, "Peer step forced terminal so resetStepForRevision can reset it")
        XCTAssertEqual(sut.loadedTask(tid)?.runs.last?.roleStatuses["cr"], .revisionRequested)
        XCTAssertNil(engine.roleTasks["cr"], "Peer engine task must be cancelled+removed")
        XCTAssertFalse(sut.llmExecutionService._testHasExecutionState(stepID: "cr", taskID: tid),
                       "Peer execution state must be torn down")

        // Requester (tpm): flagged only — step left running, NOT task-cancelled, exec state preserved.
        XCTAssertEqual(step(tid, "tpm")?.status, .running, "Requester step is left running to finish naturally")
        XCTAssertEqual(sut.loadedTask(tid)?.runs.last?.roleStatuses["tpm"], .revisionRequested)
        XCTAssertNotNil(engine.roleTasks["tpm"], "Requester engine task must NOT be cancelled")
        XCTAssertTrue(sut.llmExecutionService._testHasExecutionState(stepID: "tpm", taskID: tid),
                      "Requester execution state must be preserved so its tool-result write can commit")

        // Unrelated role: untouched.
        XCTAssertEqual(step(tid, "uxr")?.status, .pending)
        XCTAssertEqual(sut.loadedTask(tid)?.runs.last?.roleStatuses["uxr"], .working)
    }

    func testHold_emptyRunningSet_isNoOp() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        await seedRun(tid)

        await sut.holdDownstreamForRevision(taskID: tid, runningRoleIDs: [], requesterRoleID: "tpm")

        XCTAssertEqual(sut.loadedTask(tid)?.runs.last?.roleStatuses["cr"], .working,
                       "Empty running set must not touch any role")
    }

    /// END-TO-END: reach the strict-pipeline hold THROUGH `executeAmendment` (real
    /// orchestrator delegate, not the recording mock), so the full handoff is
    /// validated — `propagateAmendmentDownstream` reports `runningRoleIDs`, and the
    /// real `holdDownstreamForRevision` tears down the peer + flags the requester.
    /// This is the seam that unit tests split across files miss: it proves the
    /// `runningRoleIDs` (keyed on `effectiveRoleID`) match what the hook treats as
    /// the requester (`requesterStepID` == `step.id` == `effectiveRoleID`).
    func testExecuteAmendment_endToEnd_holdsRunningPeer_preservesRequester() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }

        // A→B→C artifact chain so getDownstreamRoles(of: A) == {B, C}.
        func role(_ id: String, req: [String], prod: [String]) -> TeamRoleDefinition {
            TeamRoleDefinition(id: id, name: id, prompt: "", toolIDs: [],
                               usePlanningPhase: false,
                               dependencies: RoleDependencies(requiredArtifacts: req, producesArtifacts: prod))
        }
        let team = Team(
            id: NTMSID.from(name: "chain-\(UUID().uuidString)"), name: "Chain", description: "",
            roles: [role("A", req: [], prod: ["ArtX"]),
                    role("B", req: ["ArtX"], prod: ["ArtY"]),
                    role("C", req: ["ArtY"], prod: [])],
            artifacts: [], settings: .default, graphLayout: .default
        )

        // A done (revision target), B running (downstream peer), C running (requester).
        _ = await sut.mutateTask(taskID: tid) { task in
            var run = Run(id: 0, teamID: team.id)
            run.steps = [
                StepExecution(id: "A", role: .custom(id: "A"), title: "A", status: .done),
                StepExecution(id: "B", role: .custom(id: "B"), title: "B", status: .running),
                StepExecution(id: "C", role: .custom(id: "C"), title: "C", status: .running),
            ]
            run.roleStatuses = ["A": .done, "B": .working, "C": .working]
            task.runs = [run]
        }
        let engine = sut.engineForTask(tid)
        engine.roleTasks["B"] = Task<Void, Never> { }
        engine.roleTasks["C"] = Task<Void, Never> { }
        sut.llmExecutionService._testInjectRunningTask(stepID: "B", taskID: tid, runningTask: Task<Void, Never> { })
        sut.llmExecutionService._testInjectRunningTask(stepID: "C", taskID: tid, runningTask: Task<Void, Never> { })

        _ = await sut.llmExecutionService._testExecuteAmendment(
            taskID: tid, targetRoleID: "A", changes: "fix", reasoning: "because",
            requestingRoleID: "C", requesterStepID: "C", meetingID: nil, team: team
        )

        let run = sut.loadedTask(tid)?.runs.last
        // Target queued for revision.
        XCTAssertEqual(run?.roleStatuses["A"], .revisionRequested, "target A must be queued for revision")
        // Peer B: cancelled + forced terminal + queued; exec state torn down.
        XCTAssertEqual(run?.steps.first(where: { $0.id == "B" })?.status, .done)
        XCTAssertEqual(run?.roleStatuses["B"], .revisionRequested)
        XCTAssertNil(engine.roleTasks["B"], "peer B engine task must be cancelled")
        XCTAssertFalse(sut.llmExecutionService._testHasExecutionState(stepID: "B", taskID: tid))
        // Requester C: flagged only — step running, NOT cancelled, exec state preserved.
        XCTAssertEqual(run?.steps.first(where: { $0.id == "C" })?.status, .running)
        XCTAssertEqual(run?.roleStatuses["C"], .revisionRequested)
        XCTAssertNotNil(engine.roleTasks["C"], "requester C engine task must NOT be cancelled")
        XCTAssertTrue(sut.llmExecutionService._testHasExecutionState(stepID: "C", taskID: tid))
    }
}
