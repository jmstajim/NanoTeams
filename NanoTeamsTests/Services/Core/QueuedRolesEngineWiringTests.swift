import XCTest

@testable import NanoTeams

/// The wire between `TeamEngine.onQueuedRolesChanged` and the observable projection every
/// graph node reads — and its teardown, which is the half a leaked set would show up in.
@MainActor
final class QueuedRolesEngineWiringTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func makeTask() async -> Int {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.createTask(title: "T", supervisorTask: "build", makeActive: false)!
        await sut.ensureTaskLoaded(taskID)
        return taskID
    }

    func testEngineCallback_reachesTheObservableProjection() async {
        let taskID = await makeTask()
        let engine = sut.engineForTask(taskID)

        engine.publishQueuedRoles(["bravo"])

        XCTAssertEqual(sut.engineState.queuedRoleIDs[taskID], ["bravo"])
    }

    /// `stopEngine` is the verb that says this task's engine is gone. A queue left behind
    /// would keep a "Queued" pill on a graph nothing is driving.
    func testStopEngine_clearsTheQueue() async {
        let taskID = await makeTask()
        let engine = sut.engineForTask(taskID)
        engine.publishQueuedRoles(["bravo"])
        XCTAssertEqual(sut.engineState.queuedRoleIDs[taskID], ["bravo"])

        sut.stopEngine(for: taskID)

        XCTAssertNil(sut.engineState.queuedRoleIDs[taskID])
    }
}
