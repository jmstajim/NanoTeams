import XCTest
@testable import NanoTeams

/// Net-new corner-case coverage targeting two narrow seams not exercised by
/// `RevisionHoldCornerTests` or `ResetStepRevisionCornerTests`:
///
///  (a) the §7 (CLAUDE.md) post-mutate stranding-verify inside
///      `NTMSOrchestrator.holdDownstreamForRevision`. The verify intentionally
///      filters peers to ONLY those that still HAVE a `StepExecution`
///      (`run.steps.contains(where: ...)`). A PHANTOM peer (a roleID in
///      `runningRoleIDs` with no matching step) is cancelled in name only,
///      writes no roleStatus, and therefore must NOT be flagged as "stranded" —
///      doing so would raise a false `lastErrorMessage`. These tests pin that the
///      phantom never trips the verify and that an all-phantom run is a clean
///      no-op.
///
///  (b) `TaskEngineStoreAdapter.resetStepForRevision` no-op edges: a stepID that
///      does not exist in the run (no crash, no cross-step streaming damage), and
///      a `.failed` step with NO streaming preview registered (clearing an
///      inactive key is a safe no-op while the status still resets).
@MainActor
final class RevisionHoldVerifyCornerTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - Helpers (mirrors RevisionHoldCornerTests / ResetStepRevisionCornerTests)

    /// Seeds a single run with the given (stepID → status) pairs. Every seeded
    /// step's roleStatus starts at `.working`.
    private func seedRun(_ tid: Int, steps stepSpecs: [(id: String, status: StepStatus)]) async {
        _ = await sut.mutateTask(taskID: tid) { task in
            var run = Run(id: 0, teamID: nil)
            run.steps = stepSpecs.map { spec in
                StepExecution(id: spec.id, role: .custom(id: spec.id), title: spec.id, status: spec.status)
            }
            var statuses: [String: RoleExecutionStatus] = [:]
            for spec in stepSpecs { statuses[spec.id] = .working }
            run.roleStatuses = statuses
            task.runs = [run]
        }
    }

    private func step(_ tid: Int, _ id: String) -> StepExecution? {
        sut.loadedTask(tid)?.runs.last?.steps.first { $0.id == id }
    }

    private func roleStatus(_ tid: Int, _ id: String) -> RoleExecutionStatus? {
        sut.loadedTask(tid)?.runs.last?.roleStatuses[id]
    }

    /// Gives a role a live engine role-wrapper task + an LLM execution state so
    /// teardown is observable.
    private func makeRoleLive(_ tid: Int, _ id: String, engine: TeamEngine) {
        engine.roleTasks[id] = Task<Void, Never> { }
        sut.llmExecutionService._testInjectRunningTask(
            stepID: id, taskID: tid, runningTask: Task<Void, Never> { })
    }

    // MARK: - (a) §7 verify: phantom peer alongside a real peer must NOT flag a stranding

    func testHold_phantomPeerAlongsideRealPeer_noFalseStrandingError() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        await seedRun(tid, steps: [
            (id: "realPeer", status: .running),
            (id: "req",      status: .running),
        ])

        let engine = sut.engineForTask(tid)
        makeRoleLive(tid, "realPeer", engine: engine)
        makeRoleLive(tid, "req", engine: engine)

        // Clear any prior banner so we can assert the verify itself stays silent.
        sut.lastErrorMessage = nil

        // "ghostPeer" is a peer (≠ requester) but has NO StepExecution in the run.
        await sut.holdDownstreamForRevision(
            taskID: tid,
            runningRoleIDs: ["realPeer", "ghostPeer", "req"],
            requesterRoleID: "req")

        // The real peer was held: forced terminal + queued for revision.
        XCTAssertEqual(step(tid, "realPeer")?.status, .done,
                       "Real peer must be forced terminal even with a phantom peer in the set")
        XCTAssertEqual(roleStatus(tid, "realPeer"), .revisionRequested,
                       "Real peer must be queued .revisionRequested even with a phantom peer in the set")

        // The §7 verify filters peers to those that still HAVE a step — a phantom
        // peer (no step) is intentionally skipped and is NOT a stranding, so no
        // false banner.
        XCTAssertNil(sut.lastErrorMessage,
                     "A phantom peer (no StepExecution) must NOT trip the §7 stranding verify — lastErrorMessage stays nil")
    }

    func testHold_phantomPeerAlongsideRealPeer_phantomGetsNoRoleStatus() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        await seedRun(tid, steps: [
            (id: "realPeer", status: .running),
            (id: "req",      status: .running),
        ])

        let engine = sut.engineForTask(tid)
        makeRoleLive(tid, "realPeer", engine: engine)
        makeRoleLive(tid, "req", engine: engine)
        sut.lastErrorMessage = nil

        await sut.holdDownstreamForRevision(
            taskID: tid,
            runningRoleIDs: ["realPeer", "ghostPeer", "req"],
            requesterRoleID: "req")

        XCTAssertNil(roleStatus(tid, "ghostPeer"),
                     "A phantom peer with no matching step must not get a roleStatus entry invented for it")
    }

    // MARK: - (a) §7 verify: ALL running roles phantom + phantom requester → clean no-op

    func testHold_allPhantomRolesAndPhantomRequester_isCleanNoOp() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        // A run that exists but has NO steps at all — every running role is phantom.
        await seedRun(tid, steps: [])
        sut.lastErrorMessage = nil

        // Both peers and the requester are phantom (no steps anywhere in the run).
        await sut.holdDownstreamForRevision(
            taskID: tid,
            runningRoleIDs: ["ghostA", "ghostB"],
            requesterRoleID: "ghostReq")

        XCTAssertNil(sut.lastErrorMessage,
                     "An all-phantom hold (no steps in the run) must not surface a stranding error")
    }

    func testHold_allPhantomRoles_inventsNoRoleStatuses() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        await seedRun(tid, steps: [])
        sut.lastErrorMessage = nil

        await sut.holdDownstreamForRevision(
            taskID: tid,
            runningRoleIDs: ["ghostA", "ghostB"],
            requesterRoleID: "ghostReq")

        let statuses = sut.loadedTask(tid)?.runs.last?.roleStatuses ?? [:]
        XCTAssertTrue(statuses.isEmpty,
                      "An all-phantom hold must not invent any roleStatus entries — none of the running roles have a step")
    }

    // MARK: - (b) resetStepForRevision: missing step must not damage an unrelated live stream

    func testResetStepForRevision_missingStep_leavesUnrelatedStreamingIntact() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }

        // A single real step, with a live streaming preview registered for it.
        await seedRun(tid, steps: [(id: "alive", status: .running)])
        let liveMsg = UUID()
        sut.streamingPreviewManager.beginStreaming(
            stepID: "alive", taskID: tid, messageID: liveMsg, role: .softwareEngineer)
        XCTAssertTrue(sut.streamingPreviewManager.isStreaming(messageID: liveMsg),
                      "Precondition: the unrelated step must be streaming")

        let adapter = TaskEngineStoreAdapter(orchestrator: sut, taskID: tid)
        // Reset a stepID that does NOT exist in the run.
        await adapter.resetStepForRevision(stepID: "missing")

        XCTAssertTrue(sut.streamingPreviewManager.isStreaming(messageID: liveMsg),
                      "resetStepForRevision on a missing stepID must not clear another step's live streaming preview")
    }

    func testResetStepForRevision_missingStep_doesNotChangeAnyStepStatus() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }

        await seedRun(tid, steps: [(id: "alive", status: .running)])

        let adapter = TaskEngineStoreAdapter(orchestrator: sut, taskID: tid)
        await adapter.resetStepForRevision(stepID: "missing")

        XCTAssertEqual(step(tid, "alive")?.status, .running,
                       "resetStepForRevision on a missing stepID must not change an existing step's status")
    }

    // MARK: - (b) resetStepForRevision: .failed step with NO streaming preview registered

    func testResetStepForRevision_failedStepNoStreamingRegistered_resetsStatusSafely() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }

        // A .failed step with NO streaming preview ever registered — the gated
        // clear hits an inactive key, which must be a safe no-op.
        await seedRun(tid, steps: [(id: "swe", status: .failed)])

        let adapter = TaskEngineStoreAdapter(orchestrator: sut, taskID: tid)
        await adapter.resetStepForRevision(stepID: "swe")

        XCTAssertEqual(step(tid, "swe")?.status, .pending,
                       "resetStepForRevision must reset a .failed step to .pending even when no streaming preview was registered")
    }

    func testResetStepForRevision_failedStepNoStreamingRegistered_clearsCompletedAt() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }

        await seedRun(tid, steps: [(id: "swe", status: .failed)])

        let adapter = TaskEngineStoreAdapter(orchestrator: sut, taskID: tid)
        await adapter.resetStepForRevision(stepID: "swe")

        XCTAssertNil(step(tid, "swe")?.completedAt,
                     "resetStepForRevision must clear completedAt when resetting a .failed step to .pending")
    }
}
