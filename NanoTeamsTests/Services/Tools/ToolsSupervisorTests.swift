import XCTest

@testable import NanoTeams

final class ToolsSupervisorTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var registry: ToolRegistry!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        let (reg, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        registry = reg
        runtime = run

        context = ToolExecutionContext(
            workFolderRoot: tempDir,
            taskID: Int(),
            runID: 0,
            roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        registry = nil
//        runtime = nil
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - ask_supervisor Tool Registration

    func testAskSupervisorToolRegistered() {
        let toolNames = registry.registeredToolNames

        XCTAssertTrue(toolNames.contains("ask_supervisor"))
    }

    // MARK: - ask_supervisor Basic Functionality

    func testAskSupervisor_withQuestion() async {
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"Should we proceed with the refactoring?\"}"
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .supervisorQuestion("Should we proceed with the refactoring?"))
    }

    func testAskSupervisor_alwaysPauses() async {
        // Even if LLM passes "required": false, the step always pauses
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"Any preferences?\", \"required\": false}"
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .supervisorQuestion("Any preferences?"))
        // Output should contain "pending" status (always pauses)
        XCTAssertTrue(results[0].outputJSON.contains("pending"))
    }

    // MARK: - ask_supervisor refuses the questionnaire's shape when the form is there

    /// Two questions in one plain ask with the form in the batch: an error, not a park —
    /// nothing was asked. `next` names the form, and the signal is nil so the dispatcher
    /// cannot park on it.
    func testAskSupervisor_severalQuestions_withFormAvailable_isRefusedNotParked() async {
        var formContext = context!
        formContext.questionnaireAvailable = true
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"Which view hides the badge? Should the choice persist?\"}"
        )
        let results = await runtime.executeAll(context: formContext, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError, results[0].outputJSON)
        XCTAssertTrue(results[0].outputJSON.contains("QUESTIONNAIRE_REQUIRED"), results[0].outputJSON)
        XCTAssertTrue(results[0].outputJSON.contains("ask_supervisor_form"), results[0].outputJSON)
        XCTAssertTrue(results[0].outputJSON.contains("`questions`"), results[0].outputJSON)
        XCTAssertNil(results[0].signal, "a refused call must not emit a park signal")
    }

    /// A questionnaire a role reaches through ANALYSIS has a body, and the form has nowhere
    /// to put it. Told only to send the questions, the model sent the questions and dropped
    /// 2.4 KB of analysis the Supervisor never read (MeditationApp task 67 run 1). The turn's
    /// own text is the channel that carries it, and the refusal is where that is said —
    /// nowhere else knows the questionnaire's shape is what refused the turn.
    ///
    /// RED: delete the last sentence of `questionnaireRequiredReason` → the refusal tells the
    /// model what to keep and says nothing about what to do with the rest, so it drops it.
    func testTheQuestionnaireRefusal_saysWhereTheAnalysisGoes() async {
        var formContext = context!
        formContext.questionnaireAvailable = true
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"Which view hides the badge? Should the choice persist?\"}"
        )
        let results = await runtime.executeAll(context: formContext, toolCalls: [call])
        XCTAssertTrue(
            results[0].outputJSON.contains("the turn's own text"), results[0].outputJSON)
    }

    /// The same text with the plain ask alone parks: the numbered list is that role's
    /// sanctioned fallback, and a refusal naming a tool it lacks is the 2026-07-25 defect.
    func testAskSupervisor_severalQuestions_withoutForm_parks() async {
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"Which view hides the badge? Should the choice persist?\"}"
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError, results[0].outputJSON)
        XCTAssertEqual(results[0].signal, .supervisorQuestion("Which view hides the badge? Should the choice persist?"))
    }

    /// One question with the form available still parks: the plain ask is the channel for
    /// one question and for a chat reply.
    func testAskSupervisor_oneQuestion_withFormAvailable_parks() async {
        var formContext = context!
        formContext.questionnaireAvailable = true
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"Should the badge hide instantly?\"}"
        )
        let results = await runtime.executeAll(context: formContext, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError, results[0].outputJSON)
        XCTAssertEqual(results[0].signal, .supervisorQuestion("Should the badge hide instantly?"))
    }

    // MARK: - ask_supervisor Error Cases

    func testAskSupervisor_missingQuestion() async {
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{}"
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
        XCTAssertTrue(results[0].outputJSON.contains("question"))
    }

    /// This test used to assert the OPPOSITE, on the reasoning that "empty string
    /// is still a valid string" and that "validation of empty questions would be a
    /// business logic concern". The second half was checkable and false: the
    /// business logic it deferred to is `+ToolResultDispatching`'s
    /// `!trimmed.isEmpty` guard, which DROPS the question — so nobody validated
    /// it, the step never parked, and the handler had already answered `ok: true`.
    /// The model then waited for an answer nobody had been asked for until the
    /// non-productive-turn ceiling ended the step.
    ///
    /// It is the third instance of the class the 2026-08-08 post-mortem names: a
    /// characterization test that records a defect as the contract, greppable by
    /// its FIXTURE (`"question": ""`) rather than by its message.
    ///
    /// RED: revert `ask_supervisor` to `requiredString` → the call succeeds and
    /// emits `.supervisorQuestion("")`, which is exactly what the old assertions
    /// pinned.
    func testAskSupervisor_emptyQuestion_isRejected() async {
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"\"}"
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError, "got \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
        XCTAssertTrue(results[0].outputJSON.contains("must not be empty"))
        XCTAssertNil(results[0].signal, "a rejected call must not emit a park signal")
    }

    func testAskSupervisor_invalidJSON_recoversViaRawInput() async {
        // Invalid JSON is recovered — plain string treated as the question
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "invalid json"
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .supervisorQuestion("invalid json"))
    }

    // MARK: - ask_supervisor Output Format

    func testAskSupervisor_outputContainsPendingStatus() async {
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"Test question?\"}"
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].outputJSON.contains("pending"))
    }

    func testAskSupervisor_outputContainsQuestion() async {
        let question = "What color should the button be?"
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"\(question)\"}"
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].outputJSON.contains(question))
    }

    func testAskSupervisor_outputIsValidJSON() async {
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"Test?\"}"
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)

        // Verify output is valid JSON
        let outputData = results[0].outputJSON.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: outputData))
    }

    // MARK: - ask_supervisor with Special Characters

    func testAskSupervisor_questionWithSpecialCharacters() async {
        let question = "Should we use 'single quotes' or \"double quotes\"?"
        let escapedQuestion = question
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"\(escapedQuestion)\"}"
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .supervisorQuestion(question))
    }

    func testAskSupervisor_questionWithNewlines() async {
        let question = "Line 1\\nLine 2\\nLine 3"
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"\(question)\"}"
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
    }

    func testAskSupervisor_questionWithUnicode() async {
        let question = "Should we support emoji? 🎉"
        let call = StepToolCall(
            name: "ask_supervisor",
            argumentsJSON: "{\"question\": \"\(question)\"}"
        )
        let results = await runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .supervisorQuestion(question))
    }

    // MARK: - AskSupervisorData Structure Tests

    func testAskSupervisorData_codable() throws {
        let data = AskSupervisorData(
            question: "Test question",
            status: "pending"
        )

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(data)
        let decoded = try JSONDecoder().decode(AskSupervisorData.self, from: encoded)

        XCTAssertEqual(decoded.question, "Test question")
        XCTAssertEqual(decoded.status, "pending")
    }
}
