import XCTest

@testable import NanoTeams

final class SupervisorAutoAnswerServiceTests: XCTestCase {

    // MARK: - Fallback Answer Tests

    func testFallbackAnswer_hasExpectedContent() {
        let fallback = SupervisorAutoAnswerService.fallbackAnswer

        XCTAssertFalse(fallback.isEmpty)
        XCTAssertTrue(fallback.contains("reasonable assumption"))
    }

    // MARK: - Invalid Index Tests

    func testGenerateAnswer_returnsDefaultForInvalidRunIndex() async {
        let task = makeTask(withSteps: [makeStep()])
        let client = NativeLMStudioClient()
        let config = LLMConfig()

        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "What should I do?",
            task: task,
            runIndex: 999, // Invalid
            stepIndex: 0,
            client: client,
            config: config,
            artifactReader: { _ in nil }
        )

        XCTAssertEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    func testGenerateAnswer_returnsDefaultForInvalidStepIndex() async {
        let task = makeTask(withSteps: [makeStep()])
        let client = NativeLMStudioClient()
        let config = LLMConfig()

        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "What should I do?",
            task: task,
            runIndex: 0,
            stepIndex: 999, // Invalid
            client: client,
            config: config,
            artifactReader: { _ in nil }
        )

        XCTAssertEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    func testGenerateAnswer_returnsDefaultForNegativeIndices() async {
        let task = makeTask(withSteps: [makeStep()])
        let client = NativeLMStudioClient()
        let config = LLMConfig()

        // Negative runIndex - will fail bounds check
        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "What should I do?",
            task: task,
            runIndex: -1, // Negative
            stepIndex: 0,
            client: client,
            config: config,
            artifactReader: { _ in nil }
        )

        XCTAssertEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    func testGenerateAnswer_returnsDefaultForEmptyRuns() async {
        let task = NTMSTask(id: 0, title: "Empty", supervisorTask: "Goal", runs: [])
        let client = NativeLMStudioClient()
        let config = LLMConfig()

        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "What should I do?",
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: config,
            artifactReader: { _ in nil }
        )

        XCTAssertEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    func testGenerateAnswer_returnsDefaultForEmptySteps() async {
        let run = Run(id: 0, steps: [])
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", runs: [run])
        let client = NativeLMStudioClient()
        let config = LLMConfig()

        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "What should I do?",
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: config,
            artifactReader: { _ in nil }
        )

        XCTAssertEqual(answer, SupervisorAutoAnswerService.fallbackAnswer)
    }

    // MARK: - Context Building Tests (via PromptBuilder)

    func testPipelineContextBuilding_emptyForFirstStep() {
        let step = makeStep()
        let run = Run(id: 0, steps: [step])

        let context = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 0,
            artifactReader: { _ in nil }
        )

        XCTAssertTrue(context.isEmpty, "First step should have no prior context")
    }

    func testPipelineContextBuilding_includesPreviousSteps() {
        var step1 = makeStep(role: .productManager, status: .done)
        step1.workNotes = "Important note from PO"
        let step2 = makeStep(role: .tpm, status: .running)
        let run = Run(id: 0, steps: [step1, step2])

        let context = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil }
        )

        XCTAssertTrue(context.contains("Product Manager"))
        XCTAssertTrue(context.contains("Important note from PO"))
        XCTAssertTrue(context.contains("Step 1"))
    }

    func testPipelineContextBuilding_includesSupervisorQA() {
        var step1 = makeStep(role: .productManager, status: .done)
        step1.supervisorQuestion = "What is the priority?"
        step1.supervisorAnswer = "Focus on performance"
        let step2 = makeStep(role: .tpm, status: .running)
        let run = Run(id: 0, steps: [step1, step2])

        let context = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { _ in nil }
        )

        XCTAssertTrue(context.contains("Supervisor Q: What is the priority?"))
        XCTAssertTrue(context.contains("Supervisor A: Focus on performance"))
    }

    func testPipelineContextBuilding_readsArtifacts() {
        var step1 = makeStep(role: .supervisor, status: .done)
        let artifact = Artifact(name: "Product Requirements", relativePath: "test.md")
        step1.artifacts = [artifact]
        let step2 = makeStep(role: .tpm, status: .running)
        let run = Run(id: 0, steps: [step1, step2])

        let context = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: 1,
            artifactReader: { art in
                if art.name == "Product Requirements" {
                    return "# Requirements\n\nBuild a login feature"
                }
                return nil
            }
        )

        XCTAssertTrue(context.contains("Build a login feature"))
    }

    // MARK: - Helper Methods

    private func makeTask(withSteps steps: [StepExecution]) -> NTMSTask {
        let run = Run(id: 0, steps: steps)
        return NTMSTask(id: 0, title: "Test Task", supervisorTask: "Build something great", runs: [run])
    }

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

// MARK: - Integration Tests (require running LLM server)

extension SupervisorAutoAnswerServiceTests {

    /// This test documents the expected behavior but requires an LLM server.
    /// It is skipped by default to avoid test failures in CI.
    func testGenerateAnswer_integration_MANUAL() async throws {
        // Skip this test in automated runs
        try XCTSkipIf(true, "Integration test requires running LLM server")

        let step = makeStep(role: .productManager, status: .running)
        let task = makeTask(withSteps: [step])

        let client = NativeLMStudioClient()
        let config = LLMConfig(
            baseURLString: "http://localhost:1234",
            modelName: "test-model"
        )

        let answer = await SupervisorAutoAnswerService.generateAnswer(
            question: "Should we prioritize performance or features?",
            task: task,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: config,
            artifactReader: { _ in nil }
        )

        // The answer should either be from LLM or fallback
        XCTAssertFalse(answer.isEmpty)
    }
}
