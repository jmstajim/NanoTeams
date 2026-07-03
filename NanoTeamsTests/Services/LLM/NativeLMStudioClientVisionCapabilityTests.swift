import XCTest

@testable import NanoTeams

/// Pins `NativeLMStudioClient.modelSupportsVision` — the auto-detected
/// replacement for the removed "Main model supports vision" Settings toggle.
/// Contract: definitive `true`/`false` ONLY from the native LM Studio model
/// list; `nil` (undeterminable) on transport failure, non-2xx, OpenAI-shape
/// responses (no capability metadata), or a model missing from the list.
/// Callers treat `nil` as "cannot see images" (vision-model fallback).
final class NativeLMStudioClientVisionCapabilityTests: XCTestCase {

    private final class StubNetworkSession: NetworkSession, @unchecked Sendable {
        var responseBody: Data = Data()
        var statusCode: Int = 200
        var error: Error?

        func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
            if let error { throw error }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            return (responseBody, response)
        }

        func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
            fatalError("not used")
        }
    }

    private func makeConfig(model: String = "main-model") -> LLMConfig {
        LLMConfig(
            provider: .lmStudio,
            baseURLString: "http://localhost:1234",
            modelName: model,
            maxTokens: 1024,
            temperature: nil
        )
    }

    private func probe(body: String, status: Int = 200, model: String = "main-model") async -> Bool? {
        let session = StubNetworkSession()
        session.responseBody = Data(body.utf8)
        session.statusCode = status
        let client = NativeLMStudioClient(session: session, tokenResolver: StubLLMTokenResolver([:]))
        return await client.modelSupportsVision(config: makeConfig(model: model))
    }

    func testVisionCapableModel_returnsTrue() async {
        let verdict = await probe(
            body: #"{"models":[{"key":"main-model","type":"vlm","capabilities":{"vision":true}}]}"#)
        XCTAssertEqual(verdict, true)
    }

    func testTextOnlyModel_returnsFalse() async {
        // Listed model WITHOUT vision capability is a definitive false —
        // both the explicit `vision:false` and the absent-capabilities shapes.
        let explicit = await probe(
            body: #"{"models":[{"key":"main-model","type":"llm","capabilities":{"vision":false}}]}"#)
        XCTAssertEqual(explicit, false)
        let absent = await probe(
            body: #"{"models":[{"key":"main-model","type":"llm"}]}"#)
        XCTAssertEqual(absent, false)
    }

    func testEmptyCapabilitiesObject_returnsFalse() async {
        // `capabilities: {}` (key present, `vision` absent) is a listed model
        // definitively reporting no vision — false, not nil.
        let verdict = await probe(
            body: #"{"models":[{"key":"main-model","type":"llm","capabilities":{}}]}"#)
        XCTAssertEqual(verdict, false)
    }

    func testEmptyModelList_returnsNil() async {
        let verdict = await probe(body: #"{"models":[]}"#)
        XCTAssertNil(verdict)
    }

    func testGarbageBody_returnsNil() async {
        let verdict = await probe(body: "not json at all {{{")
        XCTAssertNil(verdict)
    }

    func testDuplicateModelKeys_firstEntryWins() async {
        // LM Studio can surface the same model from multiple storage paths —
        // the probe must be deterministic (first match), not order-dependent
        // on later duplicates.
        let verdict = await probe(body: #"""
            {"models":[
                {"key":"main-model","type":"vlm","capabilities":{"vision":true}},
                {"key":"main-model","type":"llm","capabilities":{"vision":false}}
            ]}
            """#)
        XCTAssertEqual(verdict, true)
    }

    func testModelNotInList_returnsNil() async {
        let verdict = await probe(
            body: #"{"models":[{"key":"other-model","type":"vlm","capabilities":{"vision":true}}]}"#)
        XCTAssertNil(verdict, "missing model must be undeterminable, not a guess")
    }

    func testOpenAIShape_returnsNil() async {
        // OpenAI-compatible list carries no capability metadata — must NOT
        // guess (the fetchModels fallback returns all models; this probe
        // deliberately does not share that leniency).
        let verdict = await probe(body: #"{"data":[{"id":"main-model"}]}"#)
        XCTAssertNil(verdict)
    }

    func testHTTPError_returnsNil() async {
        let verdict = await probe(
            body: #"{"models":[{"key":"main-model","capabilities":{"vision":true}}]}"#,
            status: 500)
        XCTAssertNil(verdict)
    }

    func testTransportError_returnsNil() async {
        let session = StubNetworkSession()
        session.error = URLError(.cannotConnectToHost)
        let client = NativeLMStudioClient(session: session, tokenResolver: StubLLMTokenResolver([:]))
        let verdict = await client.modelSupportsVision(config: makeConfig())
        XCTAssertNil(verdict)
    }

    func testInvalidBaseURL_returnsNil() async {
        let session = StubNetworkSession()
        let client = NativeLMStudioClient(session: session, tokenResolver: StubLLMTokenResolver([:]))
        let config = LLMConfig(
            provider: .lmStudio, baseURLString: "", modelName: "m",
            maxTokens: 1024, temperature: nil)
        let verdict = await client.modelSupportsVision(config: config)
        XCTAssertNil(verdict)
    }
}
