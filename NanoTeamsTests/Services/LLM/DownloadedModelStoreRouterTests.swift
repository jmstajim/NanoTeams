import XCTest

@testable import NanoTeams

/// Provider dispatch for downloaded-model operations.
///
/// The counterpart to `LLMClientRouterTests`. It matters more here than there:
/// `LLMClientRouter`'s lifecycle methods take a bare `baseURLString` and
/// therefore always route to LM Studio, and a delete inheriting that shape would
/// send Ollama deletions into LM Studio's filesystem store — which would either
/// silently do nothing or Trash a same-named local folder. Every method on this
/// router takes an `LLMConfig` so it CAN dispatch, and these tests pin that it
/// actually does.
final class DownloadedModelStoreRouterTests: XCTestCase {

    private var lmStudio: RecordingDownloadedModelStore!
    private var ollama: RecordingDownloadedModelStore!
    private var sut: DownloadedModelStoreRouter!

    override func setUp() {
        super.setUp()
        lmStudio = RecordingDownloadedModelStore(tag: "lmstudio")
        ollama = RecordingDownloadedModelStore(tag: "ollama")
        sut = DownloadedModelStoreRouter(lmStudioStore: lmStudio, ollamaStore: ollama)
    }

    override func tearDown() {
        lmStudio = nil
        ollama = nil
        sut = nil
        super.tearDown()
    }

    private func config(_ provider: LLMProvider) -> LLMConfig {
        LLMConfig(provider: provider, baseURLString: "http://127.0.0.1:1", modelName: "m")
    }

    func testListDownloaded_dispatchesByProvider() async throws {
        let viaLMStudio = try await sut.listDownloaded(config: config(.lmStudio)).map(\.id)
        let viaOllama = try await sut.listDownloaded(config: config(.ollama)).map(\.id)

        XCTAssertEqual(viaLMStudio, ["lmstudio"])
        XCTAssertEqual(viaOllama, ["ollama"])
    }

    func testDeletionCapability_dispatchesByProvider() async {
        let viaLMStudio = await sut.deletionCapability(config: config(.lmStudio))
        let viaOllama = await sut.deletionCapability(config: config(.ollama))

        XCTAssertEqual(viaLMStudio, .unavailable(reason: "lmstudio"))
        XCTAssertEqual(viaOllama, .unavailable(reason: "ollama"))
    }

    func testDelete_reachesOnlyTheMatchingStore() async throws {
        try await sut.delete(modelID: "x", config: config(.ollama))

        XCTAssertEqual(ollama.deleted, ["x"])
        XCTAssertTrue(
            lmStudio.deleted.isEmpty,
            "An Ollama delete must never reach LM Studio's filesystem store")
    }

    func testStorageLocation_dispatchesByProvider() async {
        let viaLMStudio = await sut.storageLocationDescription(config: config(.lmStudio))
        let viaOllama = await sut.storageLocationDescription(config: config(.ollama))

        XCTAssertEqual(viaLMStudio, "lmstudio")
        XCTAssertEqual(viaOllama, "ollama")
    }

    /// Every provider must have a store — a `default:`-free switch means a new
    /// provider case fails the build rather than silently doing nothing.
    func testEveryProviderResolvesToAStore() async throws {
        for provider in LLMProvider.allCases {
            let models = try await sut.listDownloaded(config: config(provider))
            XCTAssertFalse(models.isEmpty, "\(provider) resolved to no store")
        }
    }
}

// MARK: - Doubles

/// Echoes its own tag from every method so a dispatch mistake is visible.
private final class RecordingDownloadedModelStore: DownloadedModelStore, @unchecked Sendable {
    let tag: String
    private(set) var deleted: [String] = []

    init(tag: String) { self.tag = tag }

    func listDownloaded(config _: LLMConfig) async throws -> [DownloadedModel] {
        [DownloadedModel(id: tag, displayName: tag)]
    }

    func deletionCapability(config _: LLMConfig) async -> DownloadedModelDeletion {
        .unavailable(reason: tag)
    }

    func delete(modelID: String, config _: LLMConfig) async throws {
        deleted.append(modelID)
    }

    func storageLocationDescription(config _: LLMConfig) async -> String? { tag }
}
