import XCTest

@testable import NanoTeams

/// Discriminating-stub dispatch pins for `LLMClientRouter`. The error-signature
/// routing tests in `LLMClientRouterTests` cannot distinguish WHICH client was
/// hit (both throw the byte-identical `invalidBaseURL("")`), so a regression
/// collapsing `client(for:)` to always-native would stay green there. These
/// tests inject two recording clients and assert the call landed on the right
/// one — including the deliberate always-native lifecycle surface.
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

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] {
            calls.append("fetchModels")
            return [marker]
        }

        func fetchEmbeddingModels(config: LLMConfig) async throws -> [String] {
            calls.append("fetchEmbeddingModels")
            return [marker]
        }

        func loadModel(modelName: String, baseURLString: String) async throws -> String {
            calls.append("loadModel")
            return marker
        }

        func unloadModel(instanceID: String, baseURLString: String) async throws {
            calls.append("unloadModel")
        }

        func listLoadedInstances(baseURLString: String) async throws -> [LoadedModelInstance] {
            calls.append("listLoadedInstances")
            return [LoadedModelInstance(modelName: marker, instanceID: marker)]
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
        XCTAssertEqual(fromNative, ["native"])
        XCTAssertEqual(fromOllama, ["ollama"])
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

    // MARK: - Lifecycle surface is deliberately always-native

    func testLifecycle_alwaysRoutesToNativeClient() async throws {
        _ = try await router.loadModel(modelName: "m", baseURLString: "http://x:1")
        try await router.unloadModel(instanceID: "i", baseURLString: "http://x:1")
        _ = try await router.listLoadedInstances(baseURLString: "http://x:1")
        XCTAssertEqual(native.calls, ["loadModel", "unloadModel", "listLoadedInstances"])
        XCTAssertTrue(ollama.calls.isEmpty,
                      "Explicit model lifecycle is an LM-Studio-only concept — the ledger only ever holds instances the native client loaded")
    }
}
