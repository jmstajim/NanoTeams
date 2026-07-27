import XCTest
@testable import NanoTeams

/// Corner-case coverage for `TaskEngineStoreAdapter.resetStepForRevision` (Fix C:
/// the streaming preview is cleared ONLY when the step is actually being reset —
/// i.e. it is `.done`/`.failed`, the same gate as the status reset — so a
/// `.pending`/`.running` no-op reset cannot wipe a genuinely live indicator)
/// and for `StreamingPreviewManager` clear/commit task-isolation invariants.
@MainActor
final class ResetStepRevisionCornerTests: XCTestCase {

    private func makeOrchestrator() -> NTMSOrchestrator {
        TestOrchestrator.make()
    }

    private func makeWorkFolderRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-resetrev-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Adapter integration: clear runs unconditionally, status guard scoped to .done/.failed

    func testResetStepForRevision_pendingStep_preservesLiveStreamingAndStatus() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)

        let tid = await store.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }

        // A .pending step (NOT .done/.failed) with a live streaming preview registered.
        _ = await store.mutateTask(taskID: tid) { task in
            var run = Run(id: 0, teamID: nil)
            run.steps = [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .pending)]
            task.runs = [run]
        }
        let messageID = UUID()
        store.streamingPreviewManager.beginStreaming(stepID: "swe", taskID: tid, messageID: messageID, role: .softwareEngineer)
        XCTAssertTrue(store.streamingPreviewManager.isStreaming(messageID: messageID))

        let adapter = TaskEngineStoreAdapter(orchestrator: store, taskID: tid)
        await adapter.resetStepForRevision(stepID: "swe")

        // The reset is a no-op for a non-terminal step — so it must NOT wipe a
        // genuinely live indicator. The clear is gated on `.done`/`.failed`.
        XCTAssertTrue(store.streamingPreviewManager.isStreaming(messageID: messageID),
                      "resetStepForRevision must NOT clear streaming for a .pending step (no-op reset must not wipe a live indicator)")
        XCTAssertEqual(store.loadedTask(tid)?.runs.last?.steps.first?.status, .pending,
                       "resetStepForRevision must NOT change status for a .pending step (status reset is gated to .done/.failed)")
    }

    func testResetStepForRevision_failedStep_clearsStreamingAndResetsStatus() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)

        let tid = await store.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }

        _ = await store.mutateTask(taskID: tid) { task in
            var run = Run(id: 0, teamID: nil)
            run.steps = [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .failed)]
            task.runs = [run]
        }
        let messageID = UUID()
        store.streamingPreviewManager.beginStreaming(stepID: "swe", taskID: tid, messageID: messageID, role: .softwareEngineer)
        XCTAssertTrue(store.streamingPreviewManager.isStreaming(messageID: messageID))

        let adapter = TaskEngineStoreAdapter(orchestrator: store, taskID: tid)
        await adapter.resetStepForRevision(stepID: "swe")

        XCTAssertFalse(store.streamingPreviewManager.isStreaming(messageID: messageID),
                       "resetStepForRevision must clear the streaming preview for a .failed step")
        XCTAssertEqual(store.loadedTask(tid)?.runs.last?.steps.first?.status, .pending,
                       "resetStepForRevision must reset a .failed step to .pending")
    }

    func testResetStepForRevision_doneStep_clearsStreamingAndResetsStatus() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)

        let tid = await store.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }

        _ = await store.mutateTask(taskID: tid) { task in
            var run = Run(id: 0, teamID: nil)
            run.steps = [StepExecution(id: "swe", role: .softwareEngineer, title: "SWE", status: .done)]
            task.runs = [run]
        }
        let messageID = UUID()
        store.streamingPreviewManager.beginStreaming(stepID: "swe", taskID: tid, messageID: messageID, role: .softwareEngineer)
        XCTAssertTrue(store.streamingPreviewManager.isStreaming(messageID: messageID))

        let adapter = TaskEngineStoreAdapter(orchestrator: store, taskID: tid)
        await adapter.resetStepForRevision(stepID: "swe")

        XCTAssertFalse(store.streamingPreviewManager.isStreaming(messageID: messageID),
                       "resetStepForRevision must clear the streaming preview for a .done step")
        XCTAssertEqual(store.loadedTask(tid)?.runs.last?.steps.first?.status, .pending,
                       "resetStepForRevision must reset a .done step to .pending")
    }

    // MARK: - StreamingPreviewManager task isolation (same stepID, two taskIDs)

    func testClear_isTaskScoped_sameStepIDDifferentTaskIDsStreamIndependently() {
        let manager = StreamingPreviewManager()
        let a = UUID()
        let b = UUID()
        // SAME stepID string, two different tasks (stepID == roleID is shared across same-team tasks).
        manager.beginStreaming(stepID: "swe", taskID: 1, messageID: a, role: .softwareEngineer)
        manager.beginStreaming(stepID: "swe", taskID: 2, messageID: b, role: .softwareEngineer)

        manager.clear(stepID: "swe", taskID: 1)

        XCTAssertFalse(manager.isStreaming(messageID: a),
                       "clearing (swe, task 1) must clear task 1's message")
        XCTAssertTrue(manager.isStreaming(messageID: b),
                      "clearing (swe, task 1) must NOT clear (swe, task 2) — keys are composite (taskID + stepID)")
    }

    // MARK: - Commit clears the active set

    func testCommit_clearsActiveSet_isStreamingFalseAfterwards() {
        let manager = StreamingPreviewManager()
        let messageID = UUID()
        manager.beginStreaming(stepID: "swe", taskID: 7, messageID: messageID, role: .softwareEngineer)
        manager.append(stepID: "swe", taskID: 7, messageID: messageID, role: .softwareEngineer, content: "result")
        XCTAssertTrue(manager.isStreaming(messageID: messageID))

        _ = manager.commit(stepID: "swe", taskID: 7)

        XCTAssertFalse(manager.isStreaming(messageID: messageID),
                       "commit must remove the message from the active set")
    }

    // MARK: - Clear on an inactive key is a safe no-op

    func testClear_onInactiveKey_isNoOp_doesNotTouchUnrelatedStream() {
        let manager = StreamingPreviewManager()
        let live = UUID()
        manager.beginStreaming(stepID: "alive", taskID: 0, messageID: live, role: .softwareEngineer)
        XCTAssertTrue(manager.isStreaming(messageID: live))

        // Clear a key that has nothing streaming — must not crash and must leave the live one alone.
        manager.clear(stepID: "ghost", taskID: 0)

        XCTAssertTrue(manager.isStreaming(messageID: live),
                      "clearing an inactive key must be a no-op and leave the unrelated live stream intact")
    }
}
