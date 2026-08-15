import XCTest

@testable import NanoTeams

/// Pins that every teardown path cancels the DETACHED tool batch, and records why the guard that
/// claimed to protect the same window could not.
///
/// `executeToolCalls` runs its batch in a `Task.detached` and parks the handle on
/// `StepExecutionState.currentToolBatchTask`. That handle is the only way to stop a long tool —
/// `run_xcodebuild`, `run_xcodetests`, a `bash` command — once it is in flight. Three teardown
/// paths cancelled it (`cleanup()`, `cancelAllExecutions`, and the meeting-turn equivalent); the
/// fourth, `cancelStepExecution`, did not. `cancelStepExecution` is the PAUSE path, which is
/// exactly when a user expects work to stop, and it nils the state entry — dropping the handle —
/// so nothing downstream could cancel it either.
@MainActor
final class ToolBatchTeardownCoverageTests: XCTestCase {

    private var service: LLMExecutionService!
    private let stepID = "engineer"
    private let taskID = 7

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    /// A batch that never finishes on its own, so `isCancelled` is the only way it can end.
    private func makeNeverEndingBatch() -> Task<[ToolExecutionResult], Never> {
        Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return []
        }
    }

    /// RED: remove the `currentToolBatchTask?.cancel()` from `cancelStepExecution` → the detached
    /// batch keeps running after Pause with no handle left to stop it, because the same method
    /// clears the state entry on the next line.
    func testCancelStepExecution_cancelsTheDetachedToolBatch() async {
        let batch = makeNeverEndingBatch()
        service._testInjectToolBatchTask(stepID: stepID, taskID: taskID, batchTask: batch)

        await service.cancelStepExecution(stepID: stepID, taskID: taskID)

        _ = await batch.value
        XCTAssertTrue(batch.isCancelled, "Pause must stop the in-flight tool batch")
        XCTAssertFalse(service._testHasExecutionState(stepID: stepID, taskID: taskID))
    }

    /// The bulk path already did this; pinned so a future consolidation of the two cannot quietly
    /// drop it from one side.
    ///
    /// RED: remove `state.currentToolBatchTask?.cancel()` from `cancelAllExecutions` → the batch
    /// survives a work-folder switch.
    func testCancelAllExecutions_cancelsTheDetachedToolBatch() async {
        let batch = makeNeverEndingBatch()
        service._testInjectToolBatchTask(stepID: stepID, taskID: taskID, batchTask: batch)

        service.cancelAllExecutions()

        _ = await batch.value
        XCTAssertTrue(batch.isCancelled)
    }
}
