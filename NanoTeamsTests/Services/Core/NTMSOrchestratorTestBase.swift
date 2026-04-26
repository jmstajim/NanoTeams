import XCTest

@testable import NanoTeams

/// Base class for tests that need a fresh NTMSOrchestrator + temp directory.
/// Subclass and add test methods. setUp/tearDown are handled automatically.
///
/// Uses an in-memory `ConfigurationStorage` so each test starts with clean
/// defaults — otherwise settings (e.g. `expandedSearchEnabled`) leak between
/// tests via `UserDefaults.standard` and the order of execution starts to
/// matter.
@MainActor
class NTMSOrchestratorTestBase: XCTestCase {

    var sut: NTMSOrchestrator!
    var tempDir: URL!

    /// Recording client behind the orchestrator's `embeddingLifecycle`. Tests
    /// can inspect `embeddingClient.loadUnloadCalls` for load/unload sequencing
    /// (filtered view), or `.calls` for the full sequence including the
    /// adoption-path `listLoadedInstances` calls. Pre-installed here so every
    /// existing scenario test runs without touching the real LM Studio endpoint.
    var embeddingClient: RecordingLLMClient!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        embeddingClient = RecordingLLMClient()
        sut = NTMSOrchestrator(
            repository: NTMSRepository(),
            configuration: StoreConfiguration(storage: InMemoryConfigurationStorage()),
            embeddingLifecycle: EmbeddingModelLifecycleService(client: embeddingClient)
        )
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        sut = nil
        embeddingClient = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }
}

/// In-memory `ConfigurationStorage` used by `NTMSOrchestratorTestBase` to
/// isolate tests from `UserDefaults.standard`.
final class InMemoryConfigurationStorage: ConfigurationStorage, @unchecked Sendable {
    private var store: [String: Any] = [:]
    func string(forKey key: String) -> String? { store[key] as? String }
    func bool(forKey key: String) -> Bool { (store[key] as? Bool) ?? false }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) {
        if let value { store[key] = value } else { store.removeValue(forKey: key) }
    }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
}
