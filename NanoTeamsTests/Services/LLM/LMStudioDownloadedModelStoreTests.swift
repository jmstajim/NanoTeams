import XCTest

@testable import NanoTeams

/// I/O half of LM Studio's filesystem model deletion. Every test builds its own
/// temp "home" and injects it, so nothing here can read — let alone Trash —
/// the developer's real `~/.lmstudio/models`.
final class LMStudioDownloadedModelStoreTests: XCTestCase {

    private var home: URL!
    private var root: URL!

    override func setUp() {
        super.setUp()
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "nt-lmstudio-store-\(UUID().uuidString)")
        root = home.appending(path: ".lmstudio/models")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let home { try? FileManager.default.removeItem(at: home) }
        home = nil
        root = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeModel(publisher: String, repo: String, files: [(String, Int)]) throws {
        let dir = root.appending(path: publisher).appending(path: repo)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, bytes) in files {
            try Data(repeating: 0x41, count: bytes).write(to: dir.appending(path: name))
        }
    }

    private func makeStore(fileManager: FileManager = .default) -> LMStudioDownloadedModelStore {
        LMStudioDownloadedModelStore(fileManager: fileManager, homeDirectory: home)
    }

    private func localConfig() -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
    }

    private func remoteConfig() -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://192.168.1.5:1234", modelName: "m")
    }

    // MARK: - Listing

    func testList_walksExactlyTwoLevels() async throws {
        try makeModel(publisher: "pubA", repo: "repo1-GGUF", files: [("m.gguf", 10)])
        try makeModel(publisher: "pubB", repo: "repo2-MLX-4bit", files: [("model.safetensors", 20)])
        // A stray file directly under the root is not a model.
        try Data("x".utf8).write(to: root.appending(path: "loose.txt"))

        let models = try await makeStore().listDownloaded(config: localConfig())

        XCTAssertEqual(models.map(\.id), ["pubA/repo1-GGUF", "pubB/repo2-MLX-4bit"])
    }

    func testList_aggregatesSizeAcrossNestedFiles() async throws {
        try makeModel(
            publisher: "pub", repo: "split",
            files: [("model-00001-of-00002.safetensors", 1000), ("model-00002-of-00002.safetensors", 500)])
        // Nested subdirectory contents count too.
        let nested = root.appending(path: "pub/split/extra")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 250).write(to: nested.appending(path: "config.json"))

        let models = try await makeStore().listDownloaded(config: localConfig())

        // Allocated size rounds up to block boundaries, so assert a floor
        // rather than an exact byte count.
        let size = try XCTUnwrap(models.first?.sizeBytes)
        XCTAssertGreaterThanOrEqual(size, 1750)
    }

    /// A GGUF folder holding several quantizations is ONE delete target — the
    /// picker shows them as separate models, but they share a directory. Saying
    /// so is the only honest framing of what Remove will do.
    func testList_reportsQuantizationCountForMultiGGUFFolder() async throws {
        try makeModel(
            publisher: "pub", repo: "multi-GGUF",
            files: [("a-Q4_K_M.gguf", 10), ("a-Q8_0.gguf", 10), ("README.md", 5)])

        let models = try await makeStore().listDownloaded(config: localConfig())

        XCTAssertEqual(models.first?.detail, "2 quantizations")
    }

    func testList_singleQuantizationHasNoDetail() async throws {
        try makeModel(publisher: "pub", repo: "single-GGUF", files: [("a.gguf", 10)])
        let models = try await makeStore().listDownloaded(config: localConfig())
        XCTAssertNil(models.first?.detail)
    }

    /// Listed ⇒ deletable. A symlink pointing outside the models root is
    /// rejected by `delete`, so offering it as a row would produce a dead
    /// button that reads as a bug rather than a policy.
    func testList_skipsEntriesThatDeleteWouldRefuse() async throws {
        try makeModel(publisher: "pub", repo: "real", files: [("a.gguf", 10)])
        let outside = home.appending(path: "outside-the-root")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "pub").appending(path: "linked"), withDestinationURL: outside)

        let models = try await makeStore().listDownloaded(config: localConfig())

        XCTAssertEqual(models.map(\.id), ["pub/real"])
    }

    func testList_remoteEndpointReturnsNothing() async throws {
        try makeModel(publisher: "pub", repo: "repo", files: [("a.gguf", 10)])
        let models = try await makeStore().listDownloaded(config: remoteConfig())
        XCTAssertTrue(
            models.isEmpty,
            "A remote LM Studio's downloads are on another machine — listing this machine's "
                + "folder there would be a lie, not a degraded view")
    }

    func testList_missingRootReturnsNothing() async throws {
        try FileManager.default.removeItem(at: root)
        let models = try await makeStore().listDownloaded(config: localConfig())
        XCTAssertTrue(models.isEmpty)
    }

    func testList_neverReportsLoaded_becauseTheStoreNeverTalksToTheServer() async throws {
        try makeModel(publisher: "pub", repo: "repo", files: [("a.gguf", 10)])
        let models = try await makeStore().listDownloaded(config: localConfig())
        XCTAssertEqual(models.first?.isLoaded, false)
    }

    // MARK: - Capability

    func testCapability_localWithRootMovesToTrash() async {
        let capability = await makeStore().deletionCapability(config: localConfig())
        XCTAssertEqual(capability, .movesToTrash)
    }

    func testCapability_remoteIsUnavailableWithReason() async {
        let capability = await makeStore().deletionCapability(config: remoteConfig())
        guard case .unavailable(let reason) = capability else {
            return XCTFail("expected .unavailable, got \(capability)")
        }
        XCTAssertTrue(reason.contains("local"), "reason should name the actual blocker: \(reason)")
    }

    func testCapability_missingRootIsUnavailable() async throws {
        try FileManager.default.removeItem(at: root)
        let capability = await makeStore().deletionCapability(config: localConfig())
        XCTAssertFalse(capability.isAvailable)
    }

    func testStorageLocation_namesTheRootLocallyAndNothingRemotely() async {
        let store = makeStore()
        let local = await store.storageLocationDescription(config: localConfig())
        let remote = await store.storageLocationDescription(config: remoteConfig())

        XCTAssertEqual(local, root.path)
        XCTAssertNil(remote)
    }

    // MARK: - Deletion

    func testDelete_trashesTheModelDirectory() async throws {
        try makeModel(publisher: "pub", repo: "repo", files: [("a.gguf", 10)])
        let fm = RecordingFileManager()

        try await makeStore(fileManager: fm).delete(modelID: "pub/repo", config: localConfig())

        XCTAssertEqual(
            fm.trashed.map(\.standardizedFileURL),
            [root.appending(path: "pub").appending(path: "repo").standardizedFileURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "pub/repo").path))
    }

    /// The decisive safety property: if trashing fails, the files must still be
    /// there. Silently upgrading a reversible action into a permanent one is
    /// exactly the surprise this feature must never spring on someone deleting
    /// a 20 GB download.
    func testDelete_trashFailureDoesNotFallBackToPermanentRemoval() async throws {
        try makeModel(publisher: "pub", repo: "repo", files: [("a.gguf", 10)])
        let fm = RecordingFileManager()
        fm.trashError = NSError(domain: "test", code: 1)

        do {
            try await makeStore(fileManager: fm).delete(modelID: "pub/repo", config: localConfig())
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? LMStudioModelDeletionError, .trashFailed(underlying: error))
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appending(path: "pub/repo/a.gguf").path),
            "A failed trash must leave the model on disk")
    }

    func testDelete_rejectsRemoteEndpoint() async throws {
        try makeModel(publisher: "pub", repo: "repo", files: [("a.gguf", 10)])
        let fm = RecordingFileManager()

        do {
            try await makeStore(fileManager: fm).delete(modelID: "pub/repo", config: remoteConfig())
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? LMStudioModelDeletionError, .remoteServer)
        }
        XCTAssertTrue(fm.trashed.isEmpty)
    }

    func testDelete_rejectsIDsThatDoNotNameAModelFolder() async throws {
        try makeModel(publisher: "pub", repo: "repo", files: [("a.gguf", 10)])
        let fm = RecordingFileManager()
        let store = makeStore(fileManager: fm)

        for id in ["pub", "pub/repo/a.gguf", "../../etc", "/etc", "", "pub/.."] {
            do {
                try await store.delete(modelID: id, config: localConfig())
                XCTFail("expected a throw for id \"\(id)\"")
            } catch {
                XCTAssertEqual(error as? LMStudioModelDeletionError, .invalidModelID(id))
            }
        }
        XCTAssertTrue(fm.trashed.isEmpty, "no rejected id may reach the filesystem")
    }

    /// Already-gone is the outcome the caller asked for — same rule the Ollama
    /// store applies to a 404, so a double-tap isn't a spurious error.
    func testDelete_absentModelIsIdempotentSuccess() async throws {
        let fm = RecordingFileManager()
        try await makeStore(fileManager: fm).delete(modelID: "pub/never-existed", config: localConfig())
        XCTAssertTrue(fm.trashed.isEmpty)
    }
}

// MARK: - Doubles

/// Records `trashItem` targets instead of populating the developer's Trash
/// during a test run, and can be told to fail so the no-permanent-fallback
/// guarantee is observable.
private final class RecordingFileManager: FileManager, @unchecked Sendable {
    var trashed: [URL] = []
    var trashError: Error?

    override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        if let trashError { throw trashError }
        trashed.append(url)
        try removeItem(at: url)
    }
}
