import XCTest

@testable import NanoTeams

/// Extended tests for SupervisorAutoAnswerService covering edge cases
/// around context building, artifact reading, and multi-run tasks.
final class SupervisorAutoAnswerExtendedTests: XCTestCase {

    // MARK: - Connection Error Fallback

    func testGenerateAnswer_ReturnsFallbackOnConnectionError() async {
        let step1 = makeStep(role: .productManager, status: .done)
        let step2 = makeStep(role: .tpm, status: .running)
        let run = Run(id: 0, steps: [step1, step2])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])

        let client = NativeLMStudioClient()
        let config = LLMConfig(
            baseURLString: "http://invalid-host-that-does-not-exist.test:9999",
            modelName: "test-model"
        )

        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "Test question",
            task: task,
            runIndex: 0,
            stepIndex: 1,
            client: client,
            config: config,
            artifactReader: { _ in nil }
        )

        XCTAssertEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    // MARK: - Multi-Run Tasks

    func testGenerateAnswer_WorksWithMultipleRuns() async {
        let step = makeStep(role: .productManager, status: .running)
        let run1 = Run(id: 0, steps: [makeStep(role: .productManager, status: .done)])
        let run2 = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run1, run2])

        let client = NativeLMStudioClient()
        let config = LLMConfig(
            baseURLString: "http://invalid-host-that-does-not-exist.test:9999",
            modelName: "test-model"
        )

        // Request answer for step in second run
        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "What priority?",
            task: task,
            runIndex: 1,
            stepIndex: 0,
            client: client,
            config: config,
            artifactReader: { _ in nil }
        )

        // Should return fallback (unreachable server) but NOT crash
        XCTAssertEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    // MARK: - Empty Goal

    func testGenerateAnswer_WorksWithEmptyGoal() async {
        let step = makeStep(role: .productManager, status: .running)
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "", runs: [Run(id: 0, steps: [step])])

        let client = NativeLMStudioClient()
        let config = LLMConfig(
            baseURLString: "http://invalid-host-that-does-not-exist.test:9999",
            modelName: "test-model"
        )

        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "What to do?",
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: config,
            artifactReader: { _ in nil }
        )

        XCTAssertEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    // MARK: - Whitespace-Only Goal

    func testGenerateAnswer_WorksWithWhitespaceGoal() async {
        let step = makeStep(role: .productManager, status: .running)
        let task = NTMSTask(id: 0, title: "Test",
            supervisorTask: "   \n\t   ",
            runs: [Run(id: 0, steps: [step])]
        )

        let client = NativeLMStudioClient()
        let config = LLMConfig(
            baseURLString: "http://invalid-host-that-does-not-exist.test:9999",
            modelName: "test-model"
        )

        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "Test?",
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: config,
            artifactReader: { _ in nil }
        )

        // Should return fallback, not crash
        XCTAssertEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    // MARK: - Artifact Reader Integration

    func testPipelineContextBuilding_readsMultipleArtifacts() {
        var step1 = makeStep(role: .productManager, status: .done)
        let reqArtifact = Artifact(name: "Product Requirements", relativePath: "req.md")
        step1.artifacts = [reqArtifact]

        var step2 = makeStep(role: .tpm, status: .done)
        let planArtifact = Artifact(name: "Implementation Plan", relativePath: "plan.md")
        step2.artifacts = [planArtifact]

        let step3 = makeStep(role: .uxDesigner, status: .running)
        let run = Run(id: 0, steps: [step1, step2, step3])

        let context = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 2,
            artifactReader: { art in
                switch art.name {
                case "Product Requirements": return "Requirements content"
                case "Implementation Plan": return "Plan content"
                default: return nil
                }
            }
        )

        XCTAssertTrue(context.contains("- Product Requirements"))
        XCTAssertTrue(context.contains("- Implementation Plan"))
    }

    func testPipelineContextBuilding_handlesNilArtifactContent() {
        var step1 = makeStep(role: .productManager, status: .done)
        step1.artifacts = [Artifact(name: "Missing", relativePath: "missing.md")]
        let step2 = makeStep(role: .tpm, status: .running)
        let run = Run(id: 0, steps: [step1, step2])

        let context = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil }
        )

        // Should not crash and should contain step info even without artifact content
        XCTAssertTrue(context.contains("Product Manager"))
    }

    // MARK: - Helpers

    private func makeStep(
        role: Role = .productManager,
        status: StepStatus = .running
    ) -> StepExecution {
        StepExecution(
            id: role.baseID,
            role: role,
            title: "\(role.displayName) Step",
            status: status
        )
    }
}
