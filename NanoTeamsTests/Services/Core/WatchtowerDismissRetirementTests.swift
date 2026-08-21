import XCTest

@testable import NanoTeams

/// Event-driven retirement of Watchtower dismissals — the half the sampling GC
/// cannot do. `WatchtowerInboxBuilder.staleDismissals` only expires a key whose
/// banner is ABSENT while its task is loaded, so a dismissal that survives into
/// the NEXT instance of the same banner (the same step failing again after a
/// restart, a second acceptance round after a revision) would suppress a banner
/// nobody has read. The orchestrator therefore retires keys at the transitions
/// that CONSUME the state a banner reported.
///
/// Pinned twice per CLAUDE.md #58: the helper directly, and through real callers
/// (`closeTask`, `resumeRun`'s failed-revive).
@MainActor
final class WatchtowerDismissRetirementTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func folderID() -> UUID { sut.snapshot!.projection.id }

    /// Plants a task whose only step is `.failed` (role reconciled `.failed` too),
    /// the shape `resumeRun`'s revive loop looks for.
    private func makeFailedTask() async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "goal")!
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0)
            var step = StepExecution(
                id: "worker", role: .softwareEngineer, title: "Work", status: .failed)
            step.completedAt = MonotonicClock.shared.now()
            run.steps = [step]
            run.roleStatuses = ["worker": .failed]
            task.runs = [run]
        }
        return taskID
    }

    // MARK: - The helper, directly

    func testRetire_dropsBothFamilies_leavesOtherKeysAlone() async {
        let taskID = await makeFailedTask()
        let fid = folderID()
        let failedKey = WatchtowerDismissKey.failed(taskID: taskID, stepID: "worker")
        let acceptanceKey = WatchtowerDismissKey.acceptance(taskID: taskID, stepID: "worker")
        let questionKey = WatchtowerDismissKey(taskID: taskID, typeID: "worker::\(UUID().uuidString)")
        for key in [failedKey, acceptanceKey, questionKey] {
            sut.configuration.dismissNotification(workFolderID: fid, key: key)
        }

        sut.retireRoleBannerDismissals(taskID: taskID, roleIDs: ["worker"])

        XCTAssertFalse(sut.configuration.isDismissed(workFolderID: fid, key: failedKey))
        XCTAssertFalse(sut.configuration.isDismissed(workFolderID: fid, key: acceptanceKey))
        XCTAssertTrue(sut.configuration.isDismissed(workFolderID: fid, key: questionKey),
                      "a supervisor-question dismissal has per-call identity and is not this helper's business")
    }

    // MARK: - Through resumeRun's failed-revive

    /// The user retries a failed run: the failure the dismissed banner reported is
    /// being re-attempted, so a NEW failure must produce a visible banner again.
    func testResumeRun_failedRevive_retiresTheFailedDismissal() async {
        let taskID = await makeFailedTask()
        let fid = folderID()
        let failedKey = WatchtowerDismissKey.failed(taskID: taskID, stepID: "worker")
        sut.configuration.dismissNotification(workFolderID: fid, key: failedKey)

        await sut.resumeRun(taskID: taskID)

        XCTAssertFalse(sut.configuration.isDismissed(workFolderID: fid, key: failedKey),
                       "reviving the failed step must retire its banner's dismissal")
    }

    // MARK: - Through closeTask

    func testCloseTask_forgetsEveryDismissalOfThatTaskOnly() async {
        let taskID = await makeFailedTask()
        let otherID = await sut.createTask(title: "Other", supervisorTask: "x")!
        let fid = folderID()
        let mine = WatchtowerDismissKey.failed(taskID: taskID, stepID: "worker")
        let other = WatchtowerDismissKey.failed(taskID: otherID, stepID: "worker")
        sut.configuration.dismissNotification(workFolderID: fid, key: mine)
        sut.configuration.dismissNotification(workFolderID: fid, key: other)

        let closed = await sut.closeTask(taskID: taskID)

        XCTAssertTrue(closed)
        XCTAssertFalse(sut.configuration.isDismissed(workFolderID: fid, key: mine),
                       "a closed task produces no banners, so its dismissals are garbage")
        XCTAssertTrue(sut.configuration.isDismissed(workFolderID: fid, key: other),
                      "closing one task must not touch a sibling's dismissals")
    }
}
