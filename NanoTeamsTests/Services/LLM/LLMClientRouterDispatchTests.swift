import XCTest

@testable import NanoTeams

/// Discriminating-stub dispatch pins for `LLMClientRouter`. The error-signature
/// routing tests in `LLMClientRouterTests` cannot distinguish WHICH client was
/// hit (both throw the byte-identical `invalidBaseURL("")`), so a regression
/// collapsing `client(for:)` to always-native would stay green there. These
/// tests inject two recording clients and assert the call landed on the right
/// one — the model-lifecycle surface included, which is where the router used
/// to be always-native by omission rather than by decision.
final class LLMClientRouterDispatchTests: XCTestCase {

    private final class MarkerClient: LLMClient, @unchecked Sendable {
        let marker: String
        private(set) var calls: [String] = []

        init(marker: String) { self.marker = marker }

        func streamChat(
            config: LLMConfig, messages: [ChatMessage], tools: [ToolSchema],
            logger: NetworkLogger?, stepID: String?,
            roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            calls.append("streamChat")
            let marker = marker
            return AsyncThrowingStream { continuation in
                continuation.yield(StreamEvent(contentDelta: marker))
                continuation.finish()
            }
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] {
            calls.append("fetchModels")
            return [LLMModelInfo(name: marker)]
        }

        func fetchEmbeddingModels(config: LLMConfig) async throws -> [String] {
            calls.append("fetchEmbeddingModels")
            return [marker]
        }

        func loadModel(
            provider: LLMProvider, modelName: String, baseURLString: String
        ) async throws -> String {
            calls.append("loadModel")
            return marker
        }

        func unloadModel(
            provider: LLMProvider, instanceID: String, baseURLString: String
        ) async throws {
            calls.append("unloadModel")
        }

        func listLoadedInstances(
            provider: LLMProvider, baseURLString: String
        ) async throws -> LoadedInstanceListing {
            calls.append("listLoadedInstances")
            return .listed([LoadedModelInstance(modelName: marker, instanceID: marker)])
        }

        func modelSupportsVision(config: LLMConfig) async -> Bool? {
            calls.append("modelSupportsVision")
            return marker == "native"
        }

        func modelContextLength(config: LLMConfig) async -> Int? {
            calls.append("modelContextLength")
            return marker == "native" ? 1234 : 11434
        }

        func modelLoadDetails(config: LLMConfig) async -> ModelLoadDetails? {
            calls.append("modelLoadDetails")
            return ModelLoadDetails(fields: [.init(label: "marker", value: marker)])
        }

    }

    private var native: MarkerClient!
    private var ollama: MarkerClient!
    private var router: LLMClientRouter!

    override func setUp() {
        super.setUp()
        native = MarkerClient(marker: "native")
        ollama = MarkerClient(marker: "ollama")
        router = LLMClientRouter(nativeClient: native, ollamaClient: ollama)
    }

    override func tearDown() {
        native = nil
        ollama = nil
        router = nil
        super.tearDown()
    }

    private func config(_ provider: LLMProvider) -> LLMConfig {
        LLMConfig(provider: provider, baseURLString: "http://x:1", modelName: "m")
    }

    private func firstContent(_ stream: AsyncThrowingStream<StreamEvent, Error>) async -> String {
        var out = ""
        do {
            for try await event in stream { out += event.contentDelta }
        } catch {}
        return out
    }

    // MARK: - Config-carrying methods dispatch on provider

    func testStreamChat_dispatchesPerProvider() async {
        let fromNative = await firstContent(router.streamChat(
            config: config(.lmStudio), messages: [], tools: [],
            logger: nil, stepID: nil))
        let fromOllama = await firstContent(router.streamChat(
            config: config(.ollama), messages: [], tools: [],
            logger: nil, stepID: nil))
        XCTAssertEqual(fromNative, "native")
        XCTAssertEqual(fromOllama, "ollama")
    }

    func testFetchModels_dispatchesPerProvider() async throws {
        let fromNative = try await router.fetchModels(config: config(.lmStudio), visionOnly: false)
        let fromOllama = try await router.fetchModels(config: config(.ollama), visionOnly: false)
        XCTAssertEqual(fromNative.map(\.name), ["native"])
        XCTAssertEqual(fromOllama.map(\.name), ["ollama"])
    }

    func testFetchEmbeddingModels_dispatchesPerProvider() async throws {
        let fromOllama = try await router.fetchEmbeddingModels(config: config(.ollama))
        let fromNative = try await router.fetchEmbeddingModels(config: config(.lmStudio))
        XCTAssertEqual(fromOllama, ["ollama"])
        XCTAssertEqual(fromNative, ["native"])
    }

    func testModelProbes_dispatchPerProvider() async {
        let nativeVision = await router.modelSupportsVision(config: config(.lmStudio))
        let ollamaVision = await router.modelSupportsVision(config: config(.ollama))
        let nativeCtx = await router.modelContextLength(config: config(.lmStudio))
        let ollamaCtx = await router.modelContextLength(config: config(.ollama))
        let ollamaDetails = await router.modelLoadDetails(config: config(.ollama))
        XCTAssertEqual(nativeVision, true)
        XCTAssertEqual(ollamaVision, false)
        XCTAssertEqual(nativeCtx, 1234)
        XCTAssertEqual(ollamaCtx, 11434)
        XCTAssertEqual(ollamaDetails?.fields.first?.value, "ollama")
    }

    // MARK: - Lifecycle surface dispatches like everything else

    func testLifecycle_withAnLMStudioProvider_routesToTheNativeClient() async throws {
        _ = try await router.loadModel(
            provider: .lmStudio, modelName: "m", baseURLString: "http://x:1")
        try await router.unloadModel(
            provider: .lmStudio, instanceID: "i", baseURLString: "http://x:1")
        _ = try await router.listLoadedInstances(
            provider: .lmStudio, baseURLString: "http://x:1")

        XCTAssertEqual(native.calls, ["loadModel", "unloadModel", "listLoadedInstances"])
        XCTAssertTrue(ollama.calls.isEmpty)
    }

    /// The defect this parameter exists to fix, and the reason this file's previous assertion —
    /// "lifecycle ALWAYS routes to the native client" — was pinning a bug as a design.
    ///
    /// With a bare base URL the router had nothing to dispatch on, so an Ollama server was asked
    /// for `/api/v0/models`; Ollama answers `404 page not found` (measured against 0.32.14), and
    /// the native client's 404 branch — which means "an older LM Studio without v0" — returns an
    /// empty list. `BenchmarkResidencyPreparer` then set `couldInspect = true` and every Ollama
    /// benchmark row recorded `Residency: already alone` about a machine nobody had asked. The
    /// Ollama client had implemented both calls for exactly this consumer and neither was
    /// reachable.
    ///
    /// RED: route the lifecycle surface to `nativeClient` again → `ollama.calls` is empty and
    /// residency provenance goes back to being fiction on that provider.
    func testLifecycle_withAnOllamaProvider_routesToTheOllamaClient() async throws {
        try await router.unloadModel(
            provider: .ollama, instanceID: "i", baseURLString: "http://x:11434")
        _ = try await router.listLoadedInstances(
            provider: .ollama, baseURLString: "http://x:11434")

        XCTAssertEqual(ollama.calls, ["unloadModel", "listLoadedInstances"])
        XCTAssertTrue(native.calls.isEmpty, "the LM Studio client must not be asked about Ollama")
    }

    /// `loadModel` is the one that stays LM-Studio-only in EFFECT — Ollama loads on first use and
    /// exposes no load endpoint — but it is the provider's client that says so now, not the
    /// router. Here the double answers, which only proves dispatch; the real `OllamaClient`
    /// inherits the throwing protocol default.
    func testLoadModel_withAnOllamaProvider_reachesTheOllamaClientRatherThanBeingRerouted()
        async throws
    {
        _ = try await router.loadModel(
            provider: .ollama, modelName: "m", baseURLString: "http://x:11434")
        XCTAssertEqual(ollama.calls, ["loadModel"])
        XCTAssertTrue(native.calls.isEmpty)
    }
}
