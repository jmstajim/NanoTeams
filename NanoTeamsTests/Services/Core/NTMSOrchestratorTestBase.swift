import XCTest

@testable import NanoTeams

/// Base class for tests that need a fresh NTMSOrchestrator + temp directory.
/// Subclass and add test methods. setUp/tearDown are handled automatically.
///
/// Uses an in-memory `ConfigurationStorage` so each test starts with clean
/// defaults — otherwise settings (e.g. `exploratorySearchEnabled`) leak between
/// tests via `UserDefaults.standard` and the order of execution starts to
/// matter.
@MainActor
class NTMSOrchestratorTestBase: XCTestCase, @unchecked Sendable {

    var sut: NTMSOrchestrator!
    var tempDir: URL!

    /// Recording client behind the orchestrator's `embeddingLifecycle`. Tests
    /// can inspect `embeddingClient.loadUnloadCalls` for load/unload sequencing
    /// (filtered view), or `.calls` for the full sequence including the
    /// adoption-path `listLoadedInstances` calls. Pre-installed here so every
    /// existing scenario test runs without touching the real LM Studio endpoint.
    var embeddingClient: RecordingLLMClient!

    /// Stubs the chat-residency reconcile that `openWorkFolder` now runs.
    /// Tests that assert on residency inject their own client per call; this
    /// exists so the other ~700 `openWorkFolder` sites do no network I/O.
    var chatLifecycleClient: RecordingLLMClient!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        embeddingClient = RecordingLLMClient()
        chatLifecycleClient = RecordingLLMClient()
        // Through the shared factory, not inline: the base and the ~90 suites
        // that build their own orchestrator must not be able to drift on which
        // seams are stubbed. `TestOrchestratorFactory` owns that list.
        sut = TestOrchestrator.make(
            embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient
        )
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        sut = nil
        embeddingClient = nil
        chatLifecycleClient = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }
}

// `StubSearchEmbeddingClient` and `InMemoryConfigurationStorage` moved to
// `NanoTeamsTests/Support/TestOrchestratorFactory.swift` — they are the
// factory's own dependencies, and leaving them here inverted the direction.
