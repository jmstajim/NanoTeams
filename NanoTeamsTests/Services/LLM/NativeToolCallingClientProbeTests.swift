import XCTest

@testable import NanoTeams

/// `LLMClient.toolCallingSupport` on both real clients: a definitive answer from the
/// provider's own capability report, `nil` for everything that is not one. Mirrors the
/// vision probe's contract — the same three `nil`s, the same decode.
final class NativeToolCallingClientProbeTests: XCTestCase {

    private final class StubSession: NetworkSession, @unchecked Sendable {
        var body = Data()
        var status = 200
        var error: Error?
        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            if let error { throw error }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("not used")
        }
    }

    // MARK: - LM Studio: `capabilities.trained_for_tool_use`

    private func lmStudio(_ body: String, status: Int = 200) async -> Bool? {
        let session = StubSession()
        session.body = Data(body.utf8); session.status = status
        let client = NativeLMStudioClient(session: session, tokenResolver: StubLLMTokenResolver([:]))
        return await client.toolCallingSupport(config: LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "m"))
    }

    func testLMStudio_trainedForToolUse_isTrue() async {
        let r1 = await lmStudio(#"{"models":[{"key":"m","type":"llm","capabilities":{"vision":false,"trained_for_tool_use":true}}]}"#)
        XCTAssertEqual(r1, true)
    }

    func testLMStudio_notTrained_orKeyAbsent_isFalse() async {
        let r2 = await lmStudio(#"{"models":[{"key":"m","type":"llm","capabilities":{"trained_for_tool_use":false}}]}"#)
        XCTAssertEqual(r2, false)
        let r3 = await lmStudio(#"{"models":[{"key":"m","type":"llm","capabilities":{"vision":true}}]}"#)
        XCTAssertEqual(r3, false)
        let r4 = await lmStudio(#"{"models":[{"key":"m","type":"llm"}]}"#)
        XCTAssertEqual(r4, false)
    }

    func testLMStudio_undeterminable_isNil() async {
        let r5 = await lmStudio(#"{"models":[{"key":"other","capabilities":{"trained_for_tool_use":true}}]}"#)
        XCTAssertNil(r5, "not listed")
        let r6 = await lmStudio(#"{"data":[{"id":"m"}]}"#)
        XCTAssertNil(r6, "the OpenAI shape carries no capabilities")
        let r7 = await lmStudio("{{{")
        XCTAssertNil(r7, "garbage")
        let r8 = await lmStudio(#"{"models":[]}"#, status: 500)
        XCTAssertNil(r8, "non-2xx")
    }

    /// The OpenAI-compat client answers with the native client's probe — one LM Studio answer.
    func testOpenAICompatClient_delegatesTheProbe() async {
        let session = StubSession()
        session.body = Data(#"{"models":[{"key":"m","capabilities":{"trained_for_tool_use":true}}]}"#.utf8)
        let native = NativeLMStudioClient(session: session, tokenResolver: StubLLMTokenResolver([:]))
        let compat = OpenAICompatLMStudioClient(session: session, tokenResolver: StubLLMTokenResolver([:]), native: native)
        let r9 = await compat.toolCallingSupport(config: LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "m"))
        XCTAssertEqual(r9, true)
    }

    // MARK: - Ollama: `/api/show` `capabilities ∋ "tools"`

    private func ollama(_ body: String, status: Int = 200) async -> Bool? {
        let session = StubSession()
        session.body = Data(body.utf8); session.status = status
        let client = OllamaClient(session: session, tokenResolver: StubLLMTokenResolver([:]))
        return await client.toolCallingSupport(config: LLMConfig(provider: .ollama, baseURLString: "http://localhost:11434", modelName: "m"))
    }

    func testOllama_toolsCapability_isTrue() async {
        let r10 = await ollama(#"{"capabilities":["completion","tools","thinking"]}"#)
        XCTAssertEqual(r10, true)
    }

    func testOllama_withoutTheCapability_isFalse() async {
        let r11 = await ollama(#"{"capabilities":["completion","vision"]}"#)
        XCTAssertEqual(r11, false)
        let r12 = await ollama(#"{"capabilities":[]}"#)
        XCTAssertEqual(r12, false)
    }

    func testOllama_undeterminable_isNil() async {
        let r13 = await ollama(#"{"license":"x"}"#)
        XCTAssertNil(r13, "an old build without `capabilities`")
        let r14 = await ollama("{}", status: 404)
        XCTAssertNil(r14, "model not found")
        let r15 = await ollama("garbage")
        XCTAssertNil(r15, "undecodable")
    }

    func testOllama_capabilityLiteral_isTheOneTheProbeReads() {
        XCTAssertEqual(OllamaClient.toolsCapability, "tools")
    }
}
