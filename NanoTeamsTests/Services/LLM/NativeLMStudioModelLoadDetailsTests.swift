import XCTest

@testable import NanoTeams

/// `NativeLMStudioClient.modelLoadDetails` — the Model Details card source for
/// LM Studio (`GET /api/v0/models`).
final class NativeLMStudioModelLoadDetailsTests: XCTestCase {

    private func makeConfig(model: String = "qwen3.5-35b") -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: model)
    }

    private func makeClient(status: Int = 200, body: String) -> NativeLMStudioClient {
        let response = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:1234")!,
            statusCode: status, httpVersion: nil, headerFields: nil)!
        return NativeLMStudioClient(
            session: CannedDataSession(response: response, data: Data(body.utf8)),
            tokenResolver: StubLLMTokenResolver(),
            modelEnsurer: ChatModelEnsurer()
        )
    }

    func testLoadedEntry_reportsEffectiveAndMaxContext() async {
        let body = #"""
        {"data":[{"id":"qwen3.5-35b","object":"model","type":"llm","publisher":"qwen",
          "arch":"qwen3","compatibility_type":"gguf","quantization":"Q4_K_M",
          "state":"loaded","max_context_length":262144,"loaded_context_length":32768}]}
        """#
        let details = await makeClient(body: body).modelLoadDetails(config: makeConfig())

        func value(_ label: String) -> String? {
            details?.fields.first { $0.label == label }?.value
        }
        XCTAssertEqual(value("State"), "Loaded")
        XCTAssertEqual(value("Loaded context length"), "32768",
                       "the EFFECTIVE window — can be smaller than max")
        XCTAssertEqual(value("Max context length"), "262144")
        XCTAssertEqual(value("Quantization"), "Q4_K_M")
        XCTAssertEqual(value("Architecture"), "qwen3")
        XCTAssertEqual(value("Type"), "llm")
        XCTAssertEqual(value("Format"), "gguf")
        XCTAssertEqual(value("Publisher"), "qwen")
    }

    func testNotLoadedEntry_hasNoLoadedContextRow() async {
        let body = #"""
        {"data":[{"id":"qwen3.5-35b","state":"not-loaded","max_context_length":262144}]}
        """#
        let details = await makeClient(body: body).modelLoadDetails(config: makeConfig())
        XCTAssertEqual(details?.fields.first?.value, "Not loaded")
        XCTAssertFalse(details?.fields.contains { $0.label == "Loaded context length" } ?? true)
        XCTAssertTrue(details?.fields.contains { $0.label == "Max context length" } ?? false)
    }

    func testLoadedEntryPreferredOverNotLoadedDuplicate() async {
        let body = #"""
        {"data":[
          {"id":"qwen3.5-35b","state":"not-loaded","max_context_length":262144},
          {"id":"qwen3.5-35b:2","state":"loaded","max_context_length":262144,"loaded_context_length":8192}
        ]}
        """#
        let details = await makeClient(body: body).modelLoadDetails(config: makeConfig())
        XCTAssertEqual(details?.fields.first?.value, "Loaded")
        XCTAssertEqual(
            details?.fields.first { $0.label == "Loaded context length" }?.value, "8192")
    }

    func testLoadedEntryWithoutLoadedContextLength_olderBuild_degradesToMaxOnly() async {
        // `loaded_context_length` is undocumented and absent on older LM
        // Studio builds — the row is omitted, never fabricated from max.
        let body = #"""
        {"data":[{"id":"qwen3.5-35b","state":"loaded","max_context_length":262144}]}
        """#
        let details = await makeClient(body: body).modelLoadDetails(config: makeConfig())
        XCTAssertEqual(details?.fields.first?.value, "Loaded")
        XCTAssertFalse(details?.fields.contains { $0.label == "Loaded context length" } ?? true)
        XCTAssertTrue(details?.fields.contains { $0.label == "Max context length" } ?? false)
    }

    func testEmptyStringMetadataFields_omittedNotRenderedBlank() async {
        let body = #"""
        {"data":[{"id":"qwen3.5-35b","state":"loaded","quantization":"","arch":"","type":"","publisher":""}]}
        """#
        let details = await makeClient(body: body).modelLoadDetails(config: makeConfig())
        XCTAssertEqual(details?.fields.map(\.label), ["State"],
                       "empty-string metadata must not render as blank rows")
    }

    func testCanonicalMatching_suffixedInstanceIDStillMatches() async {
        // LM Studio dedup suffix `:2` on the instance id must not defeat the
        // model-name match (canonicalModelName strips trailing :N).
        let body = #"""
        {"data":[{"id":"qwen3.5-35b:2","state":"loaded","max_context_length":1000,"loaded_context_length":500}]}
        """#
        let details = await makeClient(body: body).modelLoadDetails(config: makeConfig())
        XCTAssertEqual(details?.fields.first?.value, "Loaded")
    }

    func testModelNotListed_returnsNil() async {
        let details = await makeClient(body: #"{"data":[]}"#)
            .modelLoadDetails(config: makeConfig())
        XCTAssertNil(details)
    }

    func testHTTPError_returnsNil() async {
        let details = await makeClient(status: 500, body: "boom")
            .modelLoadDetails(config: makeConfig())
        XCTAssertNil(details)
    }
}

/// Replays one canned `(Data, URLResponse)` for any request.
private final class CannedDataSession: NetworkSession, @unchecked Sendable {
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
        fatalError("CannedDataSession.sessionBytes not supported")
    }
}
