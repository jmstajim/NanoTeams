import XCTest
@testable import NanoTeams

@MainActor
final class ArtifactCaptureTests: XCTestCase {
    func testToolLoopLimitProducesWarningWithDoneStatus() async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let store = NTMSOrchestrator(repository: NTMSRepository())
        await store.openWorkFolder(tempDir)
        await store.createTask(title: "Change greeting", supervisorTask: "Update greeting text.")
        await store.ensureTaskHasInitialRunIfNeeded(taskID: store.activeTaskID!)

        let engineerStep = StepExecution(id: "test_step", role: .softwareEngineer, title: "Software Engineer", expectedArtifacts: ["Engineering Notes"], status: .running)
        let taskID = store.activeTaskID!
        await store.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }
            task.runs[runIndex].steps.append(engineerStep)
        }

        store._testRegisterStepTask(stepID: engineerStep.id, taskID: taskID)
        await store._testFinishStepWithWarning(stepID: engineerStep.id, warning: "Tool loop iteration limit reached.")

        let updatedStep = try XCTUnwrap(store.activeTask?.runs.last?.steps.first(where: { $0.id == engineerStep.id }))
        XCTAssertEqual(updatedStep.status, .done)
        XCTAssertTrue(updatedStep.messages.contains {
            $0.role == updatedStep.role
                && $0.content.hasPrefix("LLM warning:")
                && $0.content.contains("Tool loop iteration limit reached.")
        })
    }
}
