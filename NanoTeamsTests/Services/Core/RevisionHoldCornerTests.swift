import XCTest
@testable import NanoTeams

/// Corner-case coverage for `NTMSOrchestrator.holdDownstreamForRevision(taskID:runningRoleIDs:requesterRoleID:)`
/// (Fix B, strict-pipeline hold). The happy path (one peer + requester, plus the
/// empty-set no-op) is pinned by `ChangeRequestDownstreamPauseTests`; this file
/// exercises the degenerate / boundary / guard-failure paths:
///   - requester-only (no peers) — requester is flagged but otherwise untouched.
///   - multiple peers — all peers cancelled + forced terminal + queued, requester flagged only.
///   - a `runningRoleIDs` entry with NO matching step — must not crash, real roles still handled.
///   - `requesterRoleID` not present in `runningRoleIDs` — every entry is treated as a peer.
///   - the hold does NOT set `revisionComment` (that is propagate's job).
@MainActor
final class RevisionHoldCornerTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - Helpers

    /// Seeds a single run with the given (stepID → status) pairs. Every role's
    /// roleStatus starts at `.working` and `revisionComment` starts nil so tests
    /// can assert the hold does NOT plant a comment.
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

    /// Gives a role a live engine role-wrapper task + an LLM execution state so the
    /// teardown (or its absence, for the requester) is observable.
    private func makeRoleLive(_ tid: Int, _ id: String, engine: TeamEngine) {
        engine.roleTasks[id] = Task<Void, Never> { }
        sut.llmExecutionService._testInjectRunningTask(
            stepID: id, taskID: tid, runningTask: Task<Void, Never> { })
    }

    // MARK: - Requester only (no peers)

    func testHold_requesterOnly_flaggedButNotTornDown() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        await seedRun(tid, steps: [
            (id: "req", status: .running),
            (id: "other", status: .pending),
        ])

        let engine = sut.engineForTask(tid)
        makeRoleLive(tid, "req", engine: engine)

        await sut.holdDownstreamForRevision(
            taskID: tid, runningRoleIDs: ["req"], requesterRoleID: "req")

        XCTAssertEqual(step(tid, "req")?.status, .running,
                       "Requester-only: its step must be left .running to finish naturally")
        XCTAssertEqual(roleStatus(tid, "req"), .revisionRequested,
                       "Requester-only: role must still be flagged .revisionRequested")
        XCTAssertNotNil(engine.roleTasks["req"],
                        "Requester-only: engine role task must NOT be cancelled/removed")
        XCTAssertTrue(sut.llmExecutionService._testHasExecutionState(stepID: "req", taskID: tid),
                      "Requester-only: execution state must be preserved")
    }

    func testHold_requesterOnly_doesNotTouchUnlistedRole() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        await seedRun(tid, steps: [
            (id: "req", status: .running),
            (id: "other", status: .pending),
        ])

        await sut.holdDownstreamForRevision(
            taskID: tid, runningRoleIDs: ["req"], requesterRoleID: "req")

        XCTAssertEqual(step(tid, "other")?.status, .pending,
                       "A role not in runningRoleIDs must keep its step status")
        XCTAssertEqual(roleStatus(tid, "other"), .working,
                       "A role not in runningRoleIDs must keep its roleStatus")
    }

    // MARK: - Multiple peers + requester

    func testHold_multiplePeers_allPeersCancelledAndForcedDone() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        await seedRun(tid, steps: [
            (id: "peerA", status: .running),
            (id: "peerB", status: .running),
            (id: "req",   status: .running),
        ])

        let engine = sut.engineForTask(tid)
        makeRoleLive(tid, "peerA", engine: engine)
        makeRoleLive(tid, "peerB", engine: engine)
        makeRoleLive(tid, "req", engine: engine)

        await sut.holdDownstreamForRevision(
            taskID: tid, runningRoleIDs: ["peerA", "peerB", "req"], requesterRoleID: "req")

        // Both peers fully torn down + forced terminal + queued.
        for peer in ["peerA", "peerB"] {
            XCTAssertEqual(step(tid, peer)?.status, .done,
                           "Peer \(peer) step must be forced terminal (.done) so resetStepForRevision can reset it")
            XCTAssertEqual(roleStatus(tid, peer), .revisionRequested,
                           "Peer \(peer) role must be queued for revision")
            XCTAssertNil(engine.roleTasks[peer],
                         "Peer \(peer) engine role task must be cancelled+removed")
            XCTAssertFalse(sut.llmExecutionService._testHasExecutionState(stepID: peer, taskID: tid),
                           "Peer \(peer) execution state must be torn down")
        }
    }

    func testHold_multiplePeers_requesterFlaggedOnly() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        await seedRun(tid, steps: [
            (id: "peerA", status: .running),
            (id: "peerB", status: .running),
            (id: "req",   status: .running),
        ])

        let engine = sut.engineForTask(tid)
        makeRoleLive(tid, "peerA", engine: engine)
        makeRoleLive(tid, "peerB", engine: engine)
        makeRoleLive(tid, "req", engine: engine)

        await sut.holdDownstreamForRevision(
            taskID: tid, runningRoleIDs: ["peerA", "peerB", "req"], requesterRoleID: "req")

        XCTAssertEqual(step(tid, "req")?.status, .running,
                       "Requester step is left .running even when multiple peers are present")
        XCTAssertEqual(roleStatus(tid, "req"), .revisionRequested,
                       "Requester is still flagged .revisionRequested")
        XCTAssertNotNil(engine.roleTasks["req"],
                        "Requester engine role task must NOT be cancelled when peers are present")
        XCTAssertTrue(sut.llmExecutionService._testHasExecutionState(stepID: "req", taskID: tid),
                      "Requester execution state must be preserved when peers are present")
    }

    // MARK: - Phantom role (no matching step)

    func testHold_phantomRoleWithNoStep_doesNotCrashAndHandlesRealRoles() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        await seedRun(tid, steps: [
            (id: "peer", status: .running),
            (id: "req",  status: .running),
        ])

        let engine = sut.engineForTask(tid)
        makeRoleLive(tid, "peer", engine: engine)
        makeRoleLive(tid, "req", engine: engine)

        // "ghost" has no StepExecution in the run — it is in the running set anyway.
        await sut.holdDownstreamForRevision(
            taskID: tid, runningRoleIDs: ["peer", "ghost", "req"], requesterRoleID: "req")

        // Phantom role contributes no step → no roleStatus is written for it.
        XCTAssertNil(roleStatus(tid, "ghost"),
                     "A running role with no matching step must not get a roleStatus entry")

        // Real peer still handled correctly despite the phantom in the set.
        XCTAssertEqual(step(tid, "peer")?.status, .done,
                       "Real peer is still forced terminal even when a phantom role is in the set")
        XCTAssertEqual(roleStatus(tid, "peer"), .revisionRequested,
                       "Real peer is still queued for revision despite the phantom role")
        XCTAssertNil(engine.roleTasks["peer"],
                     "Real peer engine task still cancelled despite the phantom role")

        // Requester still flagged-only.
        XCTAssertEqual(step(tid, "req")?.status, .running,
                       "Requester step still left .running despite the phantom role")
        XCTAssertEqual(roleStatus(tid, "req"), .revisionRequested,
                       "Requester still flagged .revisionRequested despite the phantom role")
    }

    // MARK: - requesterRoleID not in the running set

    func testHold_requesterNotInRunningSet_allTreatedAsPeers() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        await seedRun(tid, steps: [
            (id: "roleA", status: .running),
            (id: "roleB", status: .running),
        ])

        let engine = sut.engineForTask(tid)
        makeRoleLive(tid, "roleA", engine: engine)
        makeRoleLive(tid, "roleB", engine: engine)

        // requesterRoleID names a role NOT present in runningRoleIDs → no exemption.
        await sut.holdDownstreamForRevision(
            taskID: tid, runningRoleIDs: ["roleA", "roleB"], requesterRoleID: "someoneElse")

        for role in ["roleA", "roleB"] {
            XCTAssertEqual(step(tid, role)?.status, .done,
                           "With requester absent from the set, \(role) is a peer → forced .done")
            XCTAssertEqual(roleStatus(tid, role), .revisionRequested,
                           "With requester absent from the set, \(role) is queued for revision")
            XCTAssertNil(engine.roleTasks[role],
                         "With requester absent from the set, \(role) engine task is cancelled")
            XCTAssertFalse(sut.llmExecutionService._testHasExecutionState(stepID: role, taskID: tid),
                           "With requester absent from the set, \(role) execution state is torn down")
        }
    }

    // MARK: - Does NOT plant revisionComment

    func testHold_doesNotSetRevisionComment() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        await seedRun(tid, steps: [
            (id: "peer", status: .running),
            (id: "req",  status: .running),
        ])

        // Sanity: seeded steps start with no revision comment.
        XCTAssertNil(step(tid, "peer")?.revisionComment, "Precondition: peer revisionComment seeded nil")
        XCTAssertNil(step(tid, "req")?.revisionComment, "Precondition: requester revisionComment seeded nil")

        let engine = sut.engineForTask(tid)
        makeRoleLive(tid, "peer", engine: engine)
        makeRoleLive(tid, "req", engine: engine)

        await sut.holdDownstreamForRevision(
            taskID: tid, runningRoleIDs: ["peer", "req"], requesterRoleID: "req")

        XCTAssertNil(step(tid, "peer")?.revisionComment,
                     "Hold must NOT plant a revisionComment on a peer — that is propagate's job")
        XCTAssertNil(step(tid, "req")?.revisionComment,
                     "Hold must NOT plant a revisionComment on the requester — that is propagate's job")
    }

    // MARK: - Streaming indicator (Fix C interaction)

    /// The hold clears the cancelled PEER's streaming preview (its "Thinking…"
    /// indicator must not linger on a step the hold just stopped), but must NOT
    /// clear the REQUESTER's — the requester's step is left running and is still
    /// genuinely streaming until it completes naturally.
    func testHold_clearsPeerStreaming_preservesRequesterStreaming() async {
        await sut.openWorkFolder(tempDir)
        let tid = await sut.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }
        await seedRun(tid, steps: [
            (id: "peer", status: .running),
            (id: "req",  status: .running),
        ])
        let engine = sut.engineForTask(tid)
        makeRoleLive(tid, "peer", engine: engine)
        makeRoleLive(tid, "req", engine: engine)

        let peerMsg = UUID()
        let reqMsg = UUID()
        sut.streamingPreviewManager.beginStreaming(stepID: "peer", taskID: tid, messageID: peerMsg, role: .softwareEngineer)
        sut.streamingPreviewManager.beginStreaming(stepID: "req", taskID: tid, messageID: reqMsg, role: .softwareEngineer)

        await sut.holdDownstreamForRevision(
            taskID: tid, runningRoleIDs: ["peer", "req"], requesterRoleID: "req")

        XCTAssertFalse(sut.streamingPreviewManager.isStreaming(messageID: peerMsg),
                       "Hold must clear the cancelled peer's streaming indicator (no lingering Thinking…)")
        XCTAssertTrue(sut.streamingPreviewManager.isStreaming(messageID: reqMsg),
                      "Hold must NOT clear the requester's streaming — its step is still running")
    }
}
