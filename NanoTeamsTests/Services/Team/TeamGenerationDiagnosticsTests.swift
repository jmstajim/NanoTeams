import XCTest
@testable import NanoTeams

/// Discriminates the four `GenerationDiagnostics.ParsingPath` values + the
/// stream-throw branch. The trainer's audit signal depends on these labels
/// being assigned to the right strategy — without this, a future refactor
/// could swap the branches and every audit report would be silently wrong.
@MainActor
final class TeamGenerationDiagnosticsTests: XCTestCase {

    // MARK: - Stub

    private final class StubLLMClient: LLMClient, @unchecked Sendable {
        var events: [StreamEvent] = []
        var error: Error?

        func streamChat(
            config: LLMConfig, messages: [ChatMessage], tools: [ToolSchema],
            session: LLMSession?, logger: NetworkLogger?,
            stepID: String?, roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let captured = events
            let captureError = error
            return AsyncThrowingStream { continuation in
                if let captureError {
                    continuation.finish(throwing: captureError)
                    return
                }
                for event in captured { continuation.yield(event) }
                continuation.finish()
            }
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
    }

    private func validConfigJSON() -> String {
        """
        {"name":"Diag Team","description":"x","roles":[{"name":"Eng","prompt":"p","produces_artifacts":["Code"],"requires_artifacts":["Supervisor Task"],"tools":[]}],"artifacts":[{"name":"Code","description":"c"}],"supervisor_requires":["Code"]}
        """
    }

    // MARK: - Parsing path discrimination

    func testDiagnostics_resolvedToolCall_pathIsToolCall() async {
        let stub = StubLLMClient()
        let toolDelta = StreamEvent.ToolCallDelta(
            index: 0, id: "c1", name: ToolNames.createTeam, argumentsDelta: validConfigJSON()
        )
        stub.events = [StreamEvent(toolCallDeltas: [toolDelta])]

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "x", config: LLMConfig(), client: stub
        )

        XCTAssertEqual(outcome.diagnostics.parsingPath, .toolCall)
        if case .failure(let err) = outcome.result {
            XCTFail("Expected success, got failure: \(err)")
        }
    }

    func testDiagnostics_harmonyContent_pathIsHarmony() async {
        let stub = StubLLMClient()
        // CallMarker format: `<|call|>{name, arguments}<|end|>` — canonical Harmony tool call.
        let envelope = #"{"name":"\#(ToolNames.createTeam)","arguments":\#(validConfigJSON())}"#
        let harmony = "<|call|>\(envelope)<|end|>"
        stub.events = [StreamEvent(contentDelta: harmony)]

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "x", config: LLMConfig(), client: stub
        )

        XCTAssertEqual(outcome.diagnostics.parsingPath, .harmony)
        if case .failure(let err) = outcome.result {
            XCTFail("Expected success, got failure: \(err)")
        }
    }

    func testDiagnostics_rawJSONContent_pathIsJSONExtract() async {
        let stub = StubLLMClient()
        stub.events = [StreamEvent(contentDelta: "Here:\n```json\n\(validConfigJSON())\n```")]

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "x", config: LLMConfig(), client: stub
        )

        XCTAssertEqual(outcome.diagnostics.parsingPath, .jsonExtract)
        if case .failure(let err) = outcome.result {
            XCTFail("Expected success, got failure: \(err)")
        }
    }

    func testDiagnostics_noJSONNoCalls_pathIsNone() async {
        let stub = StubLLMClient()
        stub.events = [StreamEvent(contentDelta: "Sorry, I can't help with that.")]

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "x", config: LLMConfig(), client: stub
        )

        XCTAssertEqual(outcome.diagnostics.parsingPath, .none)
        guard case .failure(let err) = outcome.result else {
            return XCTFail("Expected failure")
        }
        XCTAssertTrue(err is TeamGenerationService.GenerationError)
    }

    /// `parsingPath` reflects WHERE the call was found, not WHETHER decoding worked.
    /// A bad payload inside a real tool call must still report `.toolCall` so the
    /// audit can attribute the decode failure to the right strategy.
    func testDiagnostics_toolCallWithInvalidConfig_pathStillToolCall_resultIsFailure() async {
        let stub = StubLLMClient()
        let invalid = #"{"name":"","roles":[],"artifacts":[],"supervisor_requires":[]}"#
        let toolDelta = StreamEvent.ToolCallDelta(
            index: 0, id: "c1", name: ToolNames.createTeam, argumentsDelta: invalid
        )
        stub.events = [StreamEvent(toolCallDeltas: [toolDelta])]

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "x", config: LLMConfig(), client: stub
        )

        XCTAssertEqual(outcome.diagnostics.parsingPath, .toolCall)
        guard case .failure = outcome.result else {
            return XCTFail("Expected failure on invalid config")
        }
    }

    // MARK: - Stream-throw preserves partial state

    func testDiagnostics_streamThrows_failsWithError() async {
        struct StreamError: Error {}
        let stub = StubLLMClient()
        stub.error = StreamError()

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "x", config: LLMConfig(), client: stub
        )

        XCTAssertEqual(outcome.diagnostics.parsingPath, .none)
        guard case .failure(let err) = outcome.result else {
            return XCTFail("Expected failure when stream throws")
        }
        XCTAssertTrue(err is StreamError)
        XCTAssertGreaterThanOrEqual(outcome.diagnostics.elapsedSeconds, 0)
    }

    // MARK: - Token usage

    func testDiagnostics_tokenUsageNotEmitted_remainsNil() async {
        let stub = StubLLMClient()
        stub.events = [StreamEvent(contentDelta: "Sorry.")]

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "x", config: LLMConfig(), client: stub
        )

        XCTAssertNil(outcome.diagnostics.inputTokens, "Provider didn't emit usage — must stay nil, not 0.")
        XCTAssertNil(outcome.diagnostics.outputTokens)
    }

    func testDiagnostics_tokenUsageEmitted_populated() async {
        let stub = StubLLMClient()
        stub.events = [
            StreamEvent(contentDelta: "Sorry."),
            StreamEvent(tokenUsage: TokenUsage(inputTokens: 42, outputTokens: 7)),
        ]

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "x", config: LLMConfig(), client: stub
        )

        XCTAssertEqual(outcome.diagnostics.inputTokens, 42)
        XCTAssertEqual(outcome.diagnostics.outputTokens, 7)
    }
}
