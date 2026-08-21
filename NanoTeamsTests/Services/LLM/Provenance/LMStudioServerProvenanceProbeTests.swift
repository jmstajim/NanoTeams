import XCTest

@testable import NanoTeams

/// LM Studio answers about itself on two transports, and this pins both — including the fact that
/// a failure of one must not cost the other.
final class LMStudioServerProvenanceProbeTests: XCTestCase {

    private let base = "http://127.0.0.1:1234"

    private func makeConfig(model: String = "qwen3.8-4b") -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: base, modelName: model)
    }

    private let versionFrames = [
        WebSocketFrame.text(#"{"success":true}"#),
        WebSocketFrame.text(
            #"{"type":"rpcResult","callId":1,"result":{"version":"0.4.21","build":2}}"#),
    ]

    /// Verbatim from a live `listEngines` on 2026-08-19.
    private let engineFrames = [
        WebSocketFrame.text(#"{"success":true}"#),
        WebSocketFrame.text(
            #"""
            {"type":"rpcResult","callId":1,"result":[\#
            {"name":"llama.cpp-mac-arm64-apple-metal-advsimd","version":"2.29.0","engine":"llama.cpp",\#
            "gpu":{"make":"Apple","framework":"Metal"},"supportedModelFormatNames":["GGUF"]},\#
            {"name":"mlx-llm-mac-arm64-apple-metal-nax-advsimd","version":"1.11.0","engine":"mlx-llm",\#
            "gpu":{"make":"Apple","framework":"Metal"},"supportedModelFormatNames":["MLX"]}]}
            """#),
    ]

    private func makeProbe(
        system: [WebSocketFrame],
        runtime: [WebSocketFrame],
        session: any NetworkSession = UnusedSession()
    ) -> LMStudioServerProvenanceProbe {
        LMStudioServerProvenanceProbe(
            session: session,
            tokenResolver: StubLLMTokenResolver(),
            rpc: LMStudioWebSocketRPC(
                connector: NamespacedConnector(byNamespace: ["system": system, "runtime": runtime]),
                tokenResolver: StubLLMTokenResolver(),
                timeout: .milliseconds(300)))
    }

    // MARK: - Version and build

    func testServerProvenance_readsVersionAndBuild() async {
        let provenance = await makeProbe(system: versionFrames, runtime: engineFrames)
            .serverProvenance(config: makeConfig())

        XCTAssertEqual(provenance.version, "0.4.21")
        XCTAssertEqual(provenance.build, "2")
    }

    /// The server spells this pair two ways on two RPCs (`{version, build}` and `"0.4.21+2"`).
    /// Joining them here would make our formatting indistinguishable from something it said.
    func testServerProvenance_neverJoinsVersionAndBuild() async {
        let provenance = await makeProbe(system: versionFrames, runtime: engineFrames)
            .serverProvenance(config: makeConfig())

        XCTAssertEqual(provenance.version, "0.4.21")
        XCTAssertFalse(provenance.version?.contains("+") ?? false)
    }

    func testServerProvenance_missingBuild_leavesItNil() async {
        let frames = [
            WebSocketFrame.text(#"{"success":true}"#),
            WebSocketFrame.text(#"{"type":"rpcResult","callId":1,"result":{"version":"0.3.9"}}"#),
        ]
        let provenance = await makeProbe(system: frames, runtime: engineFrames)
            .serverProvenance(config: makeConfig())

        XCTAssertEqual(provenance.version, "0.3.9")
        XCTAssertNil(provenance.build)
    }

    // MARK: - Installed engines

    func testServerProvenance_listsInstalledEnginesVerbatim() async {
        let provenance = await makeProbe(system: versionFrames, runtime: engineFrames)
            .serverProvenance(config: makeConfig())

        XCTAssertEqual(
            provenance.installedEngines.map(\.label).sorted(),
            ["llama.cpp 2.29.0", "mlx-llm 1.11.0"])
        XCTAssertEqual(provenance.installedEngines.first?.gpu, "Metal")
        XCTAssertEqual(provenance.installedEngines.first?.formats, ["GGUF"])
    }

    /// Partial provenance is provenance: a server that names its version but not its engines has
    /// still told us the thing a stale row most needs.
    func testServerProvenance_engineCallFails_stillReportsTheVersion() async {
        let provenance = await makeProbe(system: versionFrames, runtime: [])
            .serverProvenance(config: makeConfig())

        XCTAssertEqual(provenance.version, "0.4.21")
        XCTAssertTrue(provenance.installedEngines.isEmpty)
    }

    func testServerProvenance_versionCallFails_stillReportsTheEngines() async {
        let provenance = await makeProbe(system: [], runtime: engineFrames)
            .serverProvenance(config: makeConfig())

        XCTAssertNil(provenance.version)
        XCTAssertEqual(provenance.installedEngines.count, 2)
    }

    func testServerProvenance_bothCallsFail_isEmptyRatherThanFabricated() async {
        let provenance = await makeProbe(system: [], runtime: [])
            .serverProvenance(config: makeConfig())
        XCTAssertTrue(provenance.isEmpty)
    }

    // MARK: - The serving-engine probe

    /// The body is the pin. An edit that dropped `max_tokens` would silently put a FULL completion
    /// in front of every benchmark run, and no other test would notice — the response shape, and
    /// therefore every assertion about it, would be unchanged.
    func testProbeServingEngine_sendsOneTokenNonStreaming() async {
        let session = CapturingProbeSession(body: Self.runtimeResponse)
        _ = await makeProbe(system: [], runtime: [], session: session)
            .probeServingEngine(config: makeConfig())

        let body = session.lastBodyString ?? ""
        XCTAssertTrue(body.contains("\"max_tokens\":1"), body)
        XCTAssertTrue(body.contains("\"stream\":false"), body)
        XCTAssertTrue(body.contains("\"model\":\"qwen3.8-4b\""), body)
        XCTAssertTrue(
            session.lastURL?.path.hasSuffix("/api/v0/chat/completions") ?? false,
            String(describing: session.lastURL))
    }

    /// Measured live: the v0 completion names the runtime that served THAT request.
    func testProbeServingEngine_readsTheRuntimeBlock() async {
        let session = CapturingProbeSession(body: Self.runtimeResponse)
        let engine = await makeProbe(system: [], runtime: [], session: session)
            .probeServingEngine(config: makeConfig())

        XCTAssertEqual(engine?.name, "llama.cpp-mac-arm64-apple-metal-advsimd")
        XCTAssertEqual(engine?.version, "2.29.0")
        XCTAssertEqual(engine?.formats, ["gguf"])
    }

    /// The streamed form of the same endpoint carries no `runtime` block — measured. A response
    /// without one must yield nil rather than a half-built engine.
    func testProbeServingEngine_withoutARuntimeBlock_isNil() async {
        let session = CapturingProbeSession(body: #"{"object":"chat.completion","model":"m"}"#)
        let engine = await makeProbe(system: [], runtime: [], session: session)
            .probeServingEngine(config: makeConfig())
        XCTAssertNil(engine)
    }

    func testProbeServingEngine_degenerateResponses_areNil() async {
        let cases = [
            #"{"runtime":{"name":"llama.cpp","version":""}}"#,
            #"{"runtime":{"version":"2.29.0"}}"#,
            "not json",
        ]
        for body in cases {
            let engine = await makeProbe(
                system: [], runtime: [], session: CapturingProbeSession(body: body))
                .probeServingEngine(config: makeConfig())
            XCTAssertNil(engine, "expected nil for \(body)")
        }
    }

    func testProbeServingEngine_httpError_isNil() async {
        let session = CapturingProbeSession(body: Self.runtimeResponse, status: 404)
        let engine = await makeProbe(system: [], runtime: [], session: session)
            .probeServingEngine(config: makeConfig())
        XCTAssertNil(engine)
    }

    /// No model, no request: a probe with nothing to ask about must not spend a completion finding
    /// that out.
    func testProbeServingEngine_emptyModelName_makesNoRequest() async {
        let session = CapturingProbeSession(body: Self.runtimeResponse)
        let engine = await makeProbe(system: [], runtime: [], session: session)
            .probeServingEngine(config: makeConfig(model: "   "))

        XCTAssertNil(engine)
        XCTAssertEqual(session.requestCount, 0)
    }

    private static let runtimeResponse = #"""
    {"object":"chat.completion","model":"qwen3.8-4b",
     "runtime":{"name":"llama.cpp-mac-arm64-apple-metal-advsimd","version":"2.29.0",
                "supported_formats":["gguf"]}}
    """#
}

// MARK: - Doubles

/// Hands each namespace its own scripted channel, so the two concurrent RPCs cannot read each
/// other's frames.
private struct NamespacedConnector: WebSocketConnecting {
    let byNamespace: [String: [WebSocketFrame]]

    func connect(_ request: URLRequest) async throws -> any WebSocketChannel {
        let namespace = request.url?.lastPathComponent ?? ""
        guard let frames = byNamespace[namespace], !frames.isEmpty else {
            throw LLMClientError.missingResponse
        }
        return ReplayChannel(frames: frames)
    }
}

private final class ReplayChannel: WebSocketChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [WebSocketFrame]

    init(frames: [WebSocketFrame]) { self.frames = frames }

    func send(_: WebSocketFrame) async throws {}

    func receive() async throws -> WebSocketFrame {
        let next: WebSocketFrame? = lock.withLock { frames.isEmpty ? nil : frames.removeFirst() }
        guard let next else { throw WebSocketChannelError.unsupportedFrame }
        return next
    }

    func close() {}
}

private final class CapturingProbeSession: NetworkSession, @unchecked Sendable {
    private let lock = NSLock()
    private var lastRequest: URLRequest?
    private var count = 0
    private let body: String
    private let status: Int

    init(body: String, status: Int = 200) {
        self.body = body
        self.status = status
    }

    var lastBodyString: String? {
        lock.withLock { lastRequest?.httpBody.flatMap { String(data: $0, encoding: .utf8) } }
    }
    var lastURL: URL? { lock.withLock { lastRequest?.url } }
    var requestCount: Int { lock.withLock { count } }

    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            lastRequest = request
            count += 1
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1:1234")!,
            statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        fatalError("CapturingProbeSession.sessionBytes not supported")
    }
}

/// For tests that must never reach HTTP at all.
private struct UnusedSession: NetworkSession {
    func sessionData(for _: URLRequest) async throws -> (Data, URLResponse) {
        throw LLMClientError.missingResponse
    }

    func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        fatalError("UnusedSession.sessionBytes not supported")
    }
}
