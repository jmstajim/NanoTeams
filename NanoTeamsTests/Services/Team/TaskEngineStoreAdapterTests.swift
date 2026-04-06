import XCTest
@testable import NanoTeams

/// Tests for `TaskEngineStoreAdapter.computeProducedArtifactNames()`.
final class TaskEngineStoreAdapterTests: XCTestCase {

    // MARK: - Helpers

    private func makeStep(
        id: String? = nil,
        role: Role = .productManager,
        status: StepStatus = .done,
        artifacts: [String] = []
    ) -> StepExecution {
        StepExecution(
            id: id ?? role.baseID,
            role: role,
            title: "Step",
            status: status,
            artifacts: artifacts.map { Artifact(name: $0) }
        )
    }

    private func makeTask(supervisorTask: String = "Goal", runs: [Run] = []) -> NTMSTask {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: supervisorTask)
        task.runs = runs
        return task
    }

    // MARK: - Tests

    func testExcludesArtifactsFromPendingAcceptance() {
        let run = Run(
            id: 0,
            steps: [
                makeStep(id: "pm", artifacts: ["Product Requirements"]),
                makeStep(id: "eng", artifacts: ["Engineering Notes"]),
            ],
            roleStatuses: [
                "pm": .needsAcceptance,
                "eng": .done,
            ]
        )
        let task = makeTask(runs: [run])

        let result = TaskEngineStoreAdapter.computeProducedArtifactNames(task: task, run: run)

        XCTAssertTrue(result.contains("Engineering Notes"))
        XCTAssertFalse(result.contains("Product Requirements"),
                        "Artifacts from roles awaiting acceptance should be excluded")
        XCTAssertTrue(result.contains(SystemTemplates.supervisorTaskArtifactName))
    }

    func testIncludesArtifactsAfterAcceptance() {
        let run = Run(
            id: 0,
            steps: [
                makeStep(artifacts: ["Product Requirements"]),
                makeStep(artifacts: ["Engineering Notes"]),
            ],
            roleStatuses: [
                "pm": .accepted,
                "eng": .done,
            ]
        )
        let task = makeTask(runs: [run])

        let result = TaskEngineStoreAdapter.computeProducedArtifactNames(task: task, run: run)

        XCTAssertTrue(result.contains("Product Requirements"),
                       "Artifacts from accepted roles should be available")
        XCTAssertTrue(result.contains("Engineering Notes"))
    }

    func testAlwaysIncludesSupervisorTask() {
        let run = Run(id: 0, steps: [], roleStatuses: [:])
        let task = makeTask(supervisorTask: "Build a thing", runs: [run])

        let result = TaskEngineStoreAdapter.computeProducedArtifactNames(task: task, run: run)

        XCTAssertTrue(result.contains(SystemTemplates.supervisorTaskArtifactName))
    }

    func testEmptySupervisorTaskExcluded() {
        let run = Run(id: 0, steps: [], roleStatuses: [:])
        let task = makeTask(supervisorTask: "", runs: [run])

        let result = TaskEngineStoreAdapter.computeProducedArtifactNames(task: task, run: run)

        XCTAssertFalse(result.contains(SystemTemplates.supervisorTaskArtifactName))
    }

    func testOnlyDoneStepsCountAsProduced() {
        let run = Run(
            id: 0,
            steps: [
                makeStep(status: .done, artifacts: ["A"]),
                makeStep(status: .running, artifacts: ["B"]),
                makeStep(status: .pending, artifacts: ["C"]),
            ],
            roleStatuses: [
                "pm": .done,
                "eng": .working,
                "tl": .idle,
            ]
        )
        let task = makeTask(runs: [run])

        let result = TaskEngineStoreAdapter.computeProducedArtifactNames(task: task, run: run)

        XCTAssertTrue(result.contains("A"))
        XCTAssertFalse(result.contains("B"))
        XCTAssertFalse(result.contains("C"))
    }

    func testMultiplePendingAcceptanceRoles() {
        let run = Run(
            id: 0,
            steps: [
                makeStep(id: "pm", artifacts: ["A"]),
                makeStep(id: "tl", artifacts: ["B"]),
                makeStep(id: "eng", artifacts: ["C"]),
            ],
            roleStatuses: [
                "pm": .needsAcceptance,
                "tl": .needsAcceptance,
                "eng": .done,
            ]
        )
        let task = makeTask(runs: [run])

        let result = TaskEngineStoreAdapter.computeProducedArtifactNames(task: task, run: run)

        XCTAssertFalse(result.contains("A"))
        XCTAssertFalse(result.contains("B"))
        XCTAssertTrue(result.contains("C"))
    }
}
