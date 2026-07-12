import XCTest

@testable import NanoTeams

/// Pins the `/api/v0/models` context-length decode and the `modelContextLength`
/// probe used to size the work-folder-context prompt.
final class NativeLMStudioContextLengthTests: XCTestCase {

    private func makeConfig(model: String) -> LLMConfig {
        LLMConfig(baseURLString: "http://localhost:1234", modelName: model)
    }

    private func client(body: String, status: Int = 200) -> NativeLMStudioClient {
        let session = ContextLengthStubSession(
            response: HTTPURLResponse(
                url: URL(string: "http://localhost:1234/api/v0/models")!,
                statusCode: status, httpVersion: nil, headerFields: nil
            )!,
            data: Data(body.utf8)
        )
        return NativeLMStudioClient(session: session)
    }

    // MARK: - Wire decode

    func testDecode_loadedEntry_withContextFieldsAndCapabilitiesArray() throws {
        // Verbatim live-server shape: capabilities is an ARRAY of strings here
        // (unlike /api/v1/models where it is an object). Decode must not break.
        let body = #"""
        {
          "data": [
            {
              "id": "qwen/qwen3.6-35b-a3b",
              "object": "model",
              "type": "vlm",
              "state": "loaded",
              "max_context_length": 262144,
              "loaded_context_length": 131072,
              "capabilities": ["tool_use"]
            }
          ]
        }
        """#
        let decoded = try JSONCoderFactory.makeWireDecoder()
            .decode(NativeLMStudioClient.V0ModelListResponse.self, from: Data(body.utf8))
        let entry = try XCTUnwrap(decoded.data.first)
        XCTAssertEqual(entry.maxContextLength, 262144)
        XCTAssertEqual(entry.loadedContextLength, 131072)
    }

    func testDecode_notLoadedEntry_withoutLoadedContextLength() throws {
        let body = #"""
        { "data": [ { "id": "m", "state": "not-loaded", "max_context_length": 8192 } ] }
        """#
        let decoded = try JSONCoderFactory.makeWireDecoder()
            .decode(NativeLMStudioClient.V0ModelListResponse.self, from: Data(body.utf8))
        let entry = try XCTUnwrap(decoded.data.first)
        XCTAssertEqual(entry.maxContextLength, 8192)
        XCTAssertNil(entry.loadedContextLength)
    }

    // MARK: - modelContextLength probe

    func testProbe_prefersLoadedContextLengthOverMax() async {
        let body = #"""
        { "data": [ { "id": "m", "state": "loaded", "max_context_length": 262144, "loaded_context_length": 8192 } ] }
        """#
        let ctx = await client(body: body).modelContextLength(config: makeConfig(model: "m"))
        XCTAssertEqual(ctx, 8192, "A model loaded below its max must report the LOADED window.")
    }

    func testProbe_fallsBackToMaxContextLength() async {
        let body = #"""
        { "data": [ { "id": "m", "state": "not-loaded", "max_context_length": 4096 } ] }
        """#
        let ctx = await client(body: body).modelContextLength(config: makeConfig(model: "m"))
        XCTAssertEqual(ctx, 4096)
    }

    func testProbe_matchesDuplicateInstanceSuffix() async {
        // config asks for "m"; server lists a ":2" duplicate instance — canonical
        // matching must still find it.
        let body = #"""
        { "data": [ { "id": "m:2", "state": "loaded", "loaded_context_length": 16384 } ] }
        """#
        let ctx = await client(body: body).modelContextLength(config: makeConfig(model: "m"))
        XCTAssertEqual(ctx, 16384)
    }

    func testProbe_modelNotListed_returnsNil() async {
        let body = #"""
        { "data": [ { "id": "other", "state": "loaded", "loaded_context_length": 8192 } ] }
        """#
        let ctx = await client(body: body).modelContextLength(config: makeConfig(model: "m"))
        XCTAssertNil(ctx)
    }

    func testProbe_http404_returnsNil() async {
        let ctx = await client(body: "not found", status: 404)
            .modelContextLength(config: makeConfig(model: "m"))
        XCTAssertNil(ctx, "Older LM Studio without v0 → nil, not a crash.")
    }

    func testProbe_matchingEntryWithoutAnyContextField_returnsNil() async {
        let body = #"""
        { "data": [ { "id": "m", "state": "loaded" } ] }
        """#
        let ctx = await client(body: body).modelContextLength(config: makeConfig(model: "m"))
        XCTAssertNil(ctx)
    }

    // MARK: - Corner cases

    func testProbe_multipleInstances_prefersLoadedOne() async {
        // Two instances of the same model: one not-loaded (max only), one loaded.
        // The loaded instance's loaded_context_length must win.
        let body = #"""
        {
          "data": [
            { "id": "m",   "state": "not-loaded", "max_context_length": 262144 },
            { "id": "m:2", "state": "loaded",     "loaded_context_length": 4096 }
          ]
        }
        """#
        let ctx = await client(body: body).modelContextLength(config: makeConfig(model: "m"))
        XCTAssertEqual(ctx, 4096)
    }

    func testProbe_configModelHasSuffix_matchesCanonicalEntry() async {
        // config asks for "m:2"; server lists plain "m" — canonical match both ways.
        let body = #"""
        { "data": [ { "id": "m", "state": "loaded", "loaded_context_length": 8192 } ] }
        """#
        let ctx = await client(body: body).modelContextLength(config: makeConfig(model: "m:2"))
        XCTAssertEqual(ctx, 8192)
    }

    func testProbe_malformedJSON_returnsNil() async {
        let ctx = await client(body: "{ not json").modelContextLength(config: makeConfig(model: "m"))
        XCTAssertNil(ctx)
    }

    func testProbe_emptyDataArray_returnsNil() async {
        let ctx = await client(body: #"{ "data": [] }"#).modelContextLength(config: makeConfig(model: "m"))
        XCTAssertNil(ctx)
    }

    func testProbe_http500_returnsNil() async {
        let body = #"{ "data": [ { "id": "m", "state": "loaded", "loaded_context_length": 8192 } ] }"#
        let ctx = await client(body: body, status: 500).modelContextLength(config: makeConfig(model: "m"))
        XCTAssertNil(ctx, "A non-2xx status must degrade to nil (undeterminable), not a stale value.")
    }
}

private final class ContextLengthStubSession: NetworkSession, @unchecked Sendable {
    let response: URLResponse
    let data: Data

    init(response: URLResponse, data: Data) {
        self.response = response
        self.data = data
    }

    func sessionData(for _: URLRequest) async throws -> (Data, URLResponse) {
        (data, response)
    }

    func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        fatalError("ContextLengthStubSession.sessionBytes not supported")
    }
}
