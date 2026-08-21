import Foundation

/// What LM Studio says about itself — over two transports, because it answers on two.
///
/// The version exists only on the WebSocket RPC: ~15 HTTP paths were probed on 2026-08-19 and
/// every one returned `{"error":"Unexpected endpoint or method"}` — with HTTP status **200**, so
/// on this server a status code proves nothing about whether a path exists. The engine, by
/// contrast, is on plain HTTP, and taking it from there rather than from the socket is not a
/// shortcut: `listEngines` names what is INSTALLED, while a completion's `runtime` block names
/// what actually SERVED it.
nonisolated struct LMStudioServerProvenanceProbe: ServerProvenanceProbe {

    let session: any NetworkSession
    let tokenResolver: any LLMTokenResolver
    let rpc: LMStudioWebSocketRPC

    init(
        session: any NetworkSession = URLSession.shared,
        tokenResolver: any LLMTokenResolver = DefaultLLMTokenResolver(),
        rpc: LMStudioWebSocketRPC? = nil
    ) {
        self.session = session
        self.tokenResolver = tokenResolver
        self.rpc = rpc ?? LMStudioWebSocketRPC(tokenResolver: tokenResolver)
    }

    /// Two independent RPCs, and a failure of either must not cost the other: a server that names
    /// its version but not its engines has still told us something, and partial provenance is
    /// provenance.
    func serverProvenance(config: LLMConfig) async -> ServerProvenance {
        async let version = rpc.call(
            namespace: "system", endpoint: "version",
            baseURLString: config.baseURLString, as: VersionResult.self)
        async let engines = rpc.call(
            namespace: "runtime", endpoint: "listEngines",
            baseURLString: config.baseURLString, as: [EngineEntry].self)

        let versionResult = await version
        return ServerProvenance(
            version: versionResult?.version.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilWhenEmpty,
            build: versionResult?.build.map(String.init),
            installedEngines: (await engines ?? []).map(\.asEngine))
    }

    /// One non-streaming completion of ONE token, whose response names the runtime that served it.
    ///
    /// Non-streaming is not a preference: the `runtime` block is absent from the streamed form —
    /// measured, the final chunk there carries a bare `finish_reason` and then `[DONE]`.
    ///
    /// `max_tokens: 1` is what keeps this a probe rather than a generation, and it is pinned by a
    /// test asserting the encoded body: an edit that dropped it would silently put a full
    /// completion in front of every benchmark run, and nothing else would notice.
    func probeServingEngine(config: LLMConfig) async -> ServerProvenance.Engine? {
        let model = config.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, let baseURL = URL(string: config.baseURLString) else { return nil }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/v0/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.applyLMStudioBearer(baseURL: config.baseURLString, resolver: tokenResolver)
        guard let body = try? JSONCoderFactory.makeWireEncoder().encode(ProbeRequest(model: model))
        else { return nil }
        request.httpBody = body

        guard let (data, response) = try? await session.sessionData(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? JSONCoderFactory.makeWireDecoder()
              .decode(ProbeResponse.self, from: data),
              let runtime = decoded.runtime
        else { return nil }
        return runtime.asEngine
    }

    // MARK: - Wire types

    /// `ws://…/system` rpc `version` → `{"version":"0.4.21","build":2}`.
    struct VersionResult: Decodable, Sendable {
        var version: String
        /// Kept apart from `version` rather than joined: the server spells this pair two different
        /// ways on two different RPCs, and picking one would make our spelling look like its.
        var build: Int?
    }

    /// `ws://…/runtime` rpc `listEngines`. `engine` is the family (`llama.cpp`), `name` the full
    /// build (`llama.cpp-mac-arm64-apple-metal-advsimd`).
    struct EngineEntry: Decodable, Sendable {
        var name: String?
        var version: String?
        var engine: String?
        var gpu: GPU?
        var supportedModelFormatNames: [String]?

        struct GPU: Decodable, Sendable {
            var make: String?
            var framework: String?
        }

        /// Family name where the server gives one, the build name otherwise — never a name of ours.
        var asEngine: ServerProvenance.Engine {
            ServerProvenance.Engine(
                name: engine ?? name ?? "unknown",
                version: version ?? "",
                gpu: gpu?.framework ?? gpu?.make,
                formats: supportedModelFormatNames ?? [])
        }
    }

    /// One token, no stream. Every field here is load-bearing for that.
    private struct ProbeRequest: Encodable {
        let model: String
        let messages: [Message]
        let maxTokens: Int
        let stream: Bool

        /// Spelled out in an initializer rather than as property defaults so the three constants
        /// that make this a PROBE rather than a generation are executable code, reachable from a
        /// test, instead of declarations no assertion can observe.
        init(model: String) {
            self.model = model
            self.messages = [Message(role: "user", content: "hi")]
            self.maxTokens = 1
            self.stream = false
        }

        struct Message: Encodable {
            let role: String
            let content: String
        }

        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case maxTokens = "max_tokens"
        }
    }

    private struct ProbeResponse: Decodable {
        var runtime: Runtime?

        struct Runtime: Decodable {
            var name: String?
            var version: String?
            var supportedFormats: [String]?

            enum CodingKeys: String, CodingKey {
                case name, version
                case supportedFormats = "supported_formats"
            }

            /// The v0 response names only the build, with no family field beside it — so the build
            /// name is what gets recorded. Deriving `llama.cpp` from it would be an inference, and
            /// a short one is still one.
            var asEngine: ServerProvenance.Engine? {
                guard let name, !name.isEmpty, let version, !version.isEmpty else { return nil }
                return ServerProvenance.Engine(
                    name: name, version: version, gpu: nil, formats: supportedFormats ?? [])
            }
        }
    }
}

nonisolated private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
