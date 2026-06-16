import XCTest
@testable import NanoTeams

/// Fix C: `resetStepForRevision` (via `TaskEngineStoreAdapter`) must clear the
/// step's streaming state BEFORE resetting it to `.pending`. Without this, a
/// leftover `activeMessageIDs` entry keeps the activity-feed bubble animating
/// "Thinking…" for a step that is no longer running (the symptom on revised/held
/// roles). The base `StreamingPreviewManager.clear` contract is asserted too.
@MainActor
final class ResetStepForRevisionStreamingClearTests: XCTestCase {

    private func makeOrchestrator() -> NTMSOrchestrator {
        NTMSOrchestrator(repository: NTMSRepository(), searchEmbeddingClient: StubSearchEmbeddingClient())
    }

    private func makeWorkFolderRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTeams-streamclear-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Base manager contract

    func testClear_removesMessageFromActiveSet() {
        let manager = StreamingPreviewManager()
        let messageID = UUID()
        manager.beginStreaming(stepID: "s", taskID: 0, messageID: messageID, role: .softwareEngineer)
        XCTAssertTrue(manager.isStreaming(messageID: messageID))

        manager.clear(stepID: "s", taskID: 0)
        XCTAssertFalse(manager.isStreaming(messageID: messageID),
                       "clear must remove the message from activeMessageIDs (no stale Thinking…)")
    }

    func testClear_isStepScoped_doesNotAffectOtherStepsSameTask() {
        let manager = StreamingPreviewManager()
        let a = UUID(); let b = UUID()
        manager.beginStreaming(stepID: "a", taskID: 0, messageID: a, role: .softwareEngineer)
        manager.beginStreaming(stepID: "b", taskID: 0, messageID: b, role: .softwareEngineer)

        manager.clear(stepID: "a", taskID: 0)
        XCTAssertFalse(manager.isStreaming(messageID: a))
        XCTAssertTrue(manager.isStreaming(messageID: b), "clearing one step must not clear another")
    }

    // MARK: - Adapter integration

    func testResetStepForRevision_clearsStreamingPreview() async {
        let store = makeOrchestrator()
        let root = makeWorkFolderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.openWorkFolder(root)

        let tid = await store.createTask(title: "T", supervisorTask: "...")
        guard let tid else { return XCTFail("create failed") }

        // A .done step (resetStepForRevision only acts on .done/.failed) with a live
        // streaming preview still registered.
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
                       "resetStepForRevision must clear the stale streaming indicator")
        XCTAssertEqual(store.loadedTask(tid)?.runs.last?.steps.first?.status, .pending,
                       "resetStepForRevision still resets the step to .pending")
    }
}
