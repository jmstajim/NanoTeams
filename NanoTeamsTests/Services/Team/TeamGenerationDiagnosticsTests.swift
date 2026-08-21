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
            logger: NetworkLogger?,
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

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
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

    // MARK: - Wave 11 — cascade continuation after a mid-path decode failure

    /// Content carrying a ```json fence AND a Harmony envelope, so paths 2 and 3 see DIFFERENT
    /// payloads — the only arrangement in which their two catch arms are independently observable.
    private func fencedPlusHarmony(fenced: String, harmonyArgs: String) -> String {
        let envelope = "{\"name\":\"\(ToolNames.createTeam)\",\"arguments\":\(harmonyArgs)}"
        return """
        ```json
        \(fenced)
        ```
        <|call|>\(envelope)<|end|>
        """
    }

    /// A payload path 2 extracts but cannot decode must not END the cascade: it records the error
    /// and falls through, so path 3 still gets to scan the content. That fall-through is the whole
    /// reason the arm assigns to `lastError` instead of returning, and it is what makes the
    /// three-path design a cascade rather than a chain of exits.
    ///
    /// RED: replace `lastError = error` in the HARMONY catch (path 2) with
    /// `return GenerationOutcome(result: .failure(error), diagnostics: diagnostics)` → `parsingPath`
    /// reads `.harmony` and the outcome is a failure, so both assertions below fail.
    /// Deleting the assignment outright does NOT red this test, and cannot red any test: path 3
    /// re-extracts and overwrites `lastError` before anything reads it.
    func testHarmonyPayloadThatCannotDecode_stillLetsTheContentScanSucceed() async {
        let stub = StubLLMClient()
        stub.events = [
            StreamEvent(contentDelta: fencedPlusHarmony(
                fenced: validConfigJSON(),
                harmonyArgs: "{\"name\":\"Broken Team\",\"description\":\"d\",\"roles\":[]}"
            ))
        ]

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "x", config: LLMConfig(), client: stub
        )

        XCTAssertEqual(
            outcome.diagnostics.parsingPath, .jsonExtract,
            "a Harmony decode failure must fall through to the content scan, not end the cascade")
        guard case .success(let build) = outcome.result else {
            return XCTFail("path 3 carried a valid config, so the outcome must be a success")
        }
        XCTAssertEqual(build.team.name, "Diag Team", "the fenced config is the one that won")
    }

    /// When every path that extracted something failed to decode it, the caller sees the LAST
    /// path's error — the one describing the payload the parser actually reached last.
    /// `generate`'s corrective retry hands that sentence back to the model verbatim, so surfacing
    /// an earlier path's error would ask it to fix a payload it is no longer looking at.
    ///
    /// RED: delete `lastError = error` from the JSON-EXTRACT catch (path 3) → the Harmony error
    /// survives and the surfaced message becomes the roles-empty one, failing both assertions.
    func testEveryExtractedPayloadUndecodable_surfacesTheLastPathsError() async {
        let brokenFence = "{\"name\":\"Fenced Team\",\"description\":\"d\","
            + "\"supervisor_mode\":\"autnomous\",\"roles\":[{\"name\":\"E\",\"prompt\":\"p\"}]}"
        let stub = StubLLMClient()
        stub.events = [
            StreamEvent(contentDelta: fencedPlusHarmony(
                fenced: brokenFence,
                harmonyArgs: "{\"name\":\"Broken Team\",\"description\":\"d\",\"roles\":[]}"
            ))
        ]

        let outcome = await TeamGenerationService.generateWithDiagnostics(
            taskDescription: "x", config: LLMConfig(), client: stub
        )

        XCTAssertEqual(outcome.diagnostics.parsingPath, .jsonExtract)
        guard case .failure(let error) = outcome.result else {
            return XCTFail("both extracted payloads are undecodable, so this must be a failure")
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        XCTAssertTrue(
            message.lowercased().contains("supervisor_mode"),
            "path 3's own decode error must be the surfaced one; got: \(message)")
        XCTAssertFalse(
            message.contains("at least one role"),
            "the earlier path's error must not survive; got: \(message)")
    }
}
