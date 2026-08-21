import XCTest

@testable import NanoTeams

/// What Ollama says about itself. Moved here from `OllamaClientTests` when `serverVersion` left
/// `LLMClient`: the subject of the fact is the server process, not a model on it.
final class OllamaServerProvenanceProbeTests: XCTestCase {

    private func makeConfig(model: String = "gpt-oss:20b") -> LLMConfig {
        LLMConfig(provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: model)
    }

    private func makeProbe(status: Int = 200, body: String) -> OllamaServerProvenanceProbe {
        let response = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:11434")!,
            statusCode: status, httpVersion: nil, headerFields: nil)!
        return OllamaServerProvenanceProbe(
            session: StubProvenanceSession(response: response, data: Data(body.utf8)),
            tokenResolver: StubLLMTokenResolver())
    }

    // MARK: - Version (/api/version)

    /// Measured against a live Ollama 0.32.14: `GET /api/version` → `{"version":"0.32.14"}`.
    func testServerProvenance_decodesTheVersionShape() async {
        let provenance = await makeProbe(body: #"{"version":"0.32.14"}"#)
            .serverProvenance(config: makeConfig())
        XCTAssertEqual(provenance.version, "0.32.14")
    }

    /// RED: throwing (or trapping) here → would abort a benchmark because its PROVENANCE probe
    /// failed, discarding measurements that were already taken.
    func testServerProvenance_nonSuccessStatus_isEmptyNotAThrow() async {
        let provenance = await makeProbe(status: 404, body: "not found")
            .serverProvenance(config: makeConfig())
        XCTAssertNil(provenance.version)
        XCTAssertTrue(provenance.isEmpty)
    }

    func testServerProvenance_malformedBody_isEmpty() async {
        let provenance = await makeProbe(body: "not json at all")
            .serverProvenance(config: makeConfig())
        XCTAssertNil(provenance.version)
    }

    /// RED: returning the raw string → would persist `""` as if the server had named itself, and an
    /// empty version sorts and groups differently from an absent one.
    func testServerProvenance_emptyString_isNil() async {
        let provenance = await makeProbe(body: #"{"version":"   "}"#)
            .serverProvenance(config: makeConfig())
        XCTAssertNil(provenance.version)
    }

    func testServerProvenance_invalidBaseURL_isNil() async {
        var config = makeConfig()
        config.baseURLString = ""
        let provenance = await makeProbe(body: #"{"version":"0.32.14"}"#)
            .serverProvenance(config: config)
        XCTAssertNil(provenance.version)
    }

    /// Ollama reports no build number anywhere — the field stays absent rather than being filled
    /// from the version string, which would be our spelling of something the server never said.
    func testServerProvenance_reportsNoBuild() async {
        let provenance = await makeProbe(body: #"{"version":"0.32.14"}"#)
            .serverProvenance(config: makeConfig())
        XCTAssertNil(provenance.build)
    }

    // MARK: - Engines

    /// Measured 2026-08-19 across `/api/version`, `/api/ps`, `/api/tags` and `/api/show`: not one
    /// contains `llama.cpp`, `ggml`, `engine` or `runner`. So this provider states that it does
    /// not say, rather than issuing a request that could only come back empty.
    func testEngines_areAbsentAndCostNoRequest() async {
        let session = CountingProvenanceSession()
        let probe = OllamaServerProvenanceProbe(
            session: session, tokenResolver: StubLLMTokenResolver())

        let engine = await probe.probeServingEngine(config: makeConfig())

        XCTAssertNil(engine)
        XCTAssertEqual(session.requestCount, 0, "a probe that cannot answer must not ask")
    }

    func testServerProvenance_reportsNoInstalledEngines() async {
        let provenance = await makeProbe(body: #"{"version":"0.32.14"}"#)
            .serverProvenance(config: makeConfig())
        XCTAssertTrue(provenance.installedEngines.isEmpty)
    }
}

/// Replays one canned `(Data, URLResponse)` for any request.
private final class StubProvenanceSession: NetworkSession, @unchecked Sendable {
    let response: URLResponse
    let data: Data

    init(response: URLResponse, data: Data) {
        self.response = response
        self.data = data
    }

    func sessionData(for _: URLRequest) async throws -> (Data, URLResponse) { (data, response) }

    func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        fatalError("StubProvenanceSession.sessionBytes not supported")
    }
}

/// Counts requests, so "spends no request" can be asserted rather than assumed.
private final class CountingProvenanceSession: NetworkSession, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requestCount: Int { lock.withLock { count } }

    func sessionData(for _: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { count += 1 }
        throw LLMClientError.missingResponse
    }

    func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        fatalError("CountingProvenanceSession.sessionBytes not supported")
    }
}
