import XCTest

@testable import NanoTeams

/// `OllamaClient.streamChat` under `.native`, over real `URLSession.AsyncBytes` (the same
/// data-URL replay `OllamaStreamChatTests` uses): the request carries `tools`, a whole call on
/// the terminal chunk arrives as one `toolCallDeltas` event beside the usage, and an error
/// chunk after generated tokens is `nativeToolCallRejected` — while the same chunk under
/// `.promptTaught`, or before any token without the documented wording, stays a
/// `providerError`.
final class OllamaNativeStreamChatTests: XCTestCase {

    private final class NDJSONBytesSession: NetworkSession, @unchecked Sendable {
        let ndjson: String
        var capturedRequest: URLRequest?
        init(ndjson: String) { self.ndjson = ndjson }

        func sessionData(for _: URLRequest) async throws -> (Data, URLResponse) {
            fatalError("not used")
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            capturedRequest = request
            let dataURL = URL(string: "data:application/x-ndjson;base64,"
                + Data(ndjson.utf8).base64EncodedString())!
            let (bytes, _) = try await URLSession.shared.bytes(from: dataURL)
            let http = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (bytes, http)
        }
    }

    private struct Collected {
        var content = ""
        var thinking = ""
        var calls: [StreamEvent.ToolCallDelta] = []
        var usage: TokenUsage?
        var prefill: ServerPrefillReport?
        var doneReason: String?
        var error: Error?
    }

    private let readFile = ToolSchema(
        name: ToolNames.readFile, description: "Read entire file content.",
        parameters: .object(properties: ["path": JSONSchema.string("Relative path")], required: ["path"]))

    private func collect(
        _ ndjson: String, mode: ToolCallingMode, tools: [ToolSchema]
    ) async -> (Collected, NDJSONBytesSession) {
        let session = NDJSONBytesSession(ndjson: ndjson)
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver())
        let config = LLMConfig(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "ornith-1.5:35b",
            toolCallingMode: mode)
        let stream = client.streamChat(
            config: config, messages: [ChatMessage(role: .user, content: "Read App.swift")],
            tools: tools, logger: nil, stepID: nil)
        var out = Collected()
        do {
            for try await event in stream {
                out.content += event.contentDelta
                out.thinking += event.thinkingDelta
                out.calls += event.toolCallDeltas
                if let usage = event.tokenUsage { out.usage = usage }
                if let prefill = event.serverPrefill { out.prefill = prefill }
                if let reason = event.serverDoneReason { out.doneReason = reason }
            }
        } catch {
            out.error = error
        }
        return (out, session)
    }

    /// Recorded 2026-09-13 (`ornith-1.5:35b`, Ollama 0.34.0): the call rides the `done:true`
    /// chunk itself.
    private static let callOnTheTerminalChunk = """
    {"model":"ornith-1.5:35b","created_at":"2026-09-13T08:37:45.632588Z","message":{"role":"assistant","content":"","tool_calls":[{"id":"Aeu8czDi2vLdHojVqS7dgemauTBH7qxh","function":{"index":0,"name":"read_file","arguments":{"path":"MeditationApp/App.swift"}}}]},"done":true,"done_reason":"stop","total_duration":7741185750,"load_duration":6966900917,"prompt_eval_count":368,"prompt_eval_cached_count":0,"prompt_eval_duration":363373000,"eval_count":30,"eval_duration":385566000}
    """

    func testNative_callOnTheTerminalChunk_arrivesWithTheUsageAndPrefill() async {
        let (out, session) = await collect(Self.callOnTheTerminalChunk, mode: .native, tools: [readFile])
        XCTAssertNil(out.error)
        XCTAssertEqual(out.calls.count, 1)
        XCTAssertEqual(out.calls.first?.name, ToolNames.readFile)
        XCTAssertEqual(out.calls.first?.id, "Aeu8czDi2vLdHojVqS7dgemauTBH7qxh")
        XCTAssertEqual(out.calls.first?.argumentsDelta, #"{"path":"MeditationApp/App.swift"}"#)
        XCTAssertEqual(out.usage?.inputTokens, 368)
        XCTAssertEqual(out.usage?.outputTokens, 30)
        XCTAssertEqual(out.prefill?.cachedPromptTokens, 0)
        XCTAssertEqual(out.prefill?.promptTokens, 368)
        XCTAssertEqual(out.doneReason, "stop")
        XCTAssertEqual(out.content, "")
        let body = String(decoding: session.capturedRequest?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#""tools":[{"function":{"description":"Read entire file content.""#), body)
        XCTAssertFalse(body.contains("<|call|>"))
    }

    func testPromptTaught_requestCarriesNoToolsField() async {
        let (_, session) = await collect(
            #"{"model":"m","message":{"role":"assistant","content":"hi"},"done":true}"#,
            mode: .promptTaught, tools: [readFile])
        let body = String(decoding: session.capturedRequest?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertFalse(body.contains("\"tools\""), body)
        XCTAssertTrue(body.contains("Call tools using this Harmony format"), "the lesson rides the system prompt instead")
    }

    // MARK: - The error chunk

    private static let rejectionAfterTokens = """
    {"model":"m","message":{"role":"assistant","thinking":"I will call read_file."},"done":false}
    {"error":"tool call does not match the expected peg-native format"}
    """

    func testNative_errorAfterGeneratedTokens_isARejection() async {
        let (out, _) = await collect(Self.rejectionAfterTokens, mode: .native, tools: [readFile])
        XCTAssertEqual(out.thinking, "I will call read_file.")
        XCTAssertEqual(
            out.error as? LLMClientError,
            .nativeToolCallRejected("tool call does not match the expected peg-native format"))
    }

    func testNative_documentedWordingBeforeAnyToken_isARejection() async {
        let (out, _) = await collect(
            #"{"error":"failed to parse tool call"}"#, mode: .native, tools: [readFile])
        XCTAssertEqual(out.error as? LLMClientError, .nativeToolCallRejected("failed to parse tool call"))
    }

    func testNative_outageBeforeAnyToken_staysAProviderError() async {
        let (out, _) = await collect(
            #"{"error":"model runner has unexpectedly stopped"}"#, mode: .native, tools: [readFile])
        XCTAssertEqual(out.error as? LLMClientError, .providerError("model runner has unexpectedly stopped"))
    }

    /// The gate is the MODE, not the tools: a prompt-taught request never made a native call
    /// the server could reject, so its errors keep their old meaning.
    func testPromptTaught_errorAfterTokens_staysAProviderError() async {
        let (out, _) = await collect(Self.rejectionAfterTokens, mode: .promptTaught, tools: [readFile])
        XCTAssertEqual(
            out.error as? LLMClientError,
            .providerError("tool call does not match the expected peg-native format"))
    }


    // MARK: - What a mid-stream error after tokens is NOT

    /// A runner death after the first token is the server's health: `providerError`, retried
    /// by the policy — not three nudges telling the model its call syntax is wrong.
    func testNative_runnerDeathAfterTokens_staysAProviderError() async {
        let (out, _) = await collect("""
        {"model":"m","message":{"role":"assistant","thinking":"I will call read_file."},"done":false}
        {"error":"an error was encountered while running the model: CUDA error 700"}
        """, mode: .native, tools: [readFile])
        XCTAssertEqual(out.error as? LLMClientError,
                       .providerError("an error was encountered while running the model: CUDA error 700"))
    }

    /// A native-stamped request that carried no `tools` armed no grammar: its errors after
    /// tokens keep the old meaning (the auto-answer and a tool-less meeting speaker send
    /// the step's stamped config unchanged).
    func testNative_toolLessRequest_errorAfterTokens_staysAProviderError() async {
        let (out, _) = await collect(Self.rejectionAfterTokens.replacingOccurrences(
            of: "tool call does not match the expected peg-native format", with: "internal error"),
        mode: .native, tools: [])
        XCTAssertEqual(out.error as? LLMClientError, .providerError("internal error"))
    }
}
