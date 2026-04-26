import XCTest

@testable import NanoTeams

@MainActor
final class EmbeddingModelLifecycleServiceTests: XCTestCase {

    var client: RecordingLLMClient!
    var sut: EmbeddingModelLifecycleService!

    override func setUp() {
        super.setUp()
        client = RecordingLLMClient()
        sut = EmbeddingModelLifecycleService(client: client)
    }

    override func tearDown() {
        sut = nil
        client = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private let configA = EmbeddingConfig(
        baseURLString: "http://127.0.0.1:1234",
        modelName: "model-a"
    )

    private let configB = EmbeddingConfig(
        baseURLString: "http://127.0.0.1:1234",
        modelName: "model-b"
    )

    // MARK: - ensureLoaded

    func testEnsureLoaded_callsLoadAndStoresInstanceID() async throws {
        client.loadResults = ["instance-a"]
        try await sut.ensureLoaded(configA)

        XCTAssertEqual(sut.loaded?.config, configA)
        XCTAssertEqual(sut.loaded?.instanceID, "instance-a")
        // Sequence: list (server has nothing) → load. Adoption path is gated on
        // listLoadedInstances returning a match, so empty list ≡ pure load.
        XCTAssertEqual(client.calls, [
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
            .load(model: "model-a", baseURL: "http://127.0.0.1:1234"),
        ])
    }

    func testEnsureLoaded_idempotentForSameConfig() async throws {
        client.loadResults = ["instance-a"]
        try await sut.ensureLoaded(configA)
        try await sut.ensureLoaded(configA)

        // The second call short-circuits on the in-memory `loaded?.config == config`
        // check BEFORE hitting the server. Net wire traffic = list + load, ONCE.
        XCTAssertEqual(client.calls, [
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
            .load(model: "model-a", baseURL: "http://127.0.0.1:1234"),
        ], "Second call with same config must not hit the client.")
    }

    func testEnsureLoaded_configChange_unloadsOldThenLoadsNew_inOrder() async throws {
        client.loadResults = ["instance-a", "instance-b"]
        try await sut.ensureLoaded(configA)
        try await sut.ensureLoaded(configB)

        XCTAssertEqual(client.calls, [
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
            .load(model: "model-a", baseURL: "http://127.0.0.1:1234"),
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
            .unload(instanceID: "instance-a", baseURL: "http://127.0.0.1:1234"),
            .load(model: "model-b", baseURL: "http://127.0.0.1:1234"),
        ])
        XCTAssertEqual(sut.loaded?.config, configB)
        XCTAssertEqual(sut.loaded?.instanceID, "instance-b")
    }

    /// C3 regression: prior-unload throwing during a swap MUST propagate
    /// (no `try?`-swallow) and MUST preserve `loaded` so the next reconcile
    /// can retry. Pre-fix, local state was cleared between the unload and
    /// the new load — if the new load also failed, the prior instance was
    /// orphaned (no id to unload it with).
    func testEnsureLoaded_unloadFailsDuringSwap_throwsAndPreservesPriorState() async throws {
        client.loadResults = ["instance-a", "instance-b"]
        try await sut.ensureLoaded(configA)

        client.unloadError = TestError.boom
        do {
            try await sut.ensureLoaded(configB)
            XCTFail("Expected throw")
        } catch let error as EmbeddingLifecycleError {
            guard case .priorUnloadFailedDuringSwap(let prior, _) = error else {
                XCTFail("Wrong error variant: \(error)")
                return
            }
            XCTAssertEqual(prior, configA, "Prior config must be reported so user/caller can retry")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertEqual(sut.loaded?.config, configA,
                       "Local state must be preserved when unload fails — the server may still hold the instance")
        XCTAssertEqual(sut.loaded?.instanceID, "instance-a")
    }

    func testEnsureLoaded_loadFailure_throws_andStateReflectsReality() async {
        client.loadError = TestError.boom
        do {
            try await sut.ensureLoaded(configA)
            XCTFail("Expected throw")
        } catch {
            // expected
        }
        XCTAssertNil(sut.loaded)
    }

    // MARK: - C1 adoption path

    /// User-reported bug: every app restart loaded a duplicate instance
    /// (`name`, `name:2`, `name:3`, …). Fix: query server, adopt existing
    /// instance instead of calling `loadModel`.
    func testEnsureLoaded_serverHasInstance_adoptsExistingID_doesNotCallLoad() async throws {
        // Server-side state: the model is already loaded (e.g., we loaded it
        // last session and quit; LM Studio kept it in VRAM).
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "model-a", instanceID: "model-a"),
        ]
        client.loadResults = ["should-not-be-used"]

        try await sut.ensureLoaded(configA)

        // loadModel must NOT be called.
        XCTAssertEqual(client.calls, [
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
        ])
        XCTAssertEqual(sut.loaded?.instanceID, "model-a",
                       "Service must adopt the server's existing instance_id")
        XCTAssertEqual(sut.loaded?.config, configA)
    }

    /// Same scenario but the existing instance has the LM Studio dedup
    /// suffix (`:2`). Canonical-name matching must still detect it.
    func testEnsureLoaded_serverHasSuffixedInstance_adoptsByCanonicalName() async throws {
        client.listLoadedInstancesResults = [
            // Server says: "I have model-a:2 loaded" (e.g., the original was
            // unloaded but a duplicate from a prior buggy session lingers).
            LoadedModelInstance(modelName: "model-a", instanceID: "model-a:2"),
        ]
        try await sut.ensureLoaded(configA)

        XCTAssertEqual(sut.loaded?.instanceID, "model-a:2")
        XCTAssertEqual(client.calls, [
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
        ])
    }

    /// listLoadedInstances throwing must not block the load — the adoption
    /// optimization is best-effort. Older LM Studio builds may not expose
    /// /api/v0/models; we shouldn't break Expanded Search there.
    func testEnsureLoaded_listInstancesThrows_fallsThroughToLoad() async throws {
        client.listLoadedInstancesError = TestError.boom
        client.loadResults = ["instance-a"]

        try await sut.ensureLoaded(configA)

        XCTAssertEqual(sut.loaded?.config, configA)
        XCTAssertEqual(sut.loaded?.instanceID, "instance-a")
    }

    // MARK: - ensureUnloaded

    func testEnsureUnloaded_afterLoad_unloadsAndClearsState() async throws {
        client.loadResults = ["instance-a"]
        try await sut.ensureLoaded(configA)
        try await sut.ensureUnloaded()

        XCTAssertNil(sut.loaded)
        XCTAssertEqual(client.calls, [
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
            .load(model: "model-a", baseURL: "http://127.0.0.1:1234"),
            .unload(instanceID: "instance-a", baseURL: "http://127.0.0.1:1234"),
        ])
    }

    func testEnsureUnloaded_whenNothingLoaded_isNoOp() async throws {
        try await sut.ensureUnloaded()
        XCTAssertTrue(client.calls.isEmpty)
    }

    func testEnsureUnloaded_clientError_clearsStateAndPropagates() async throws {
        client.loadResults = ["instance-a"]
        try await sut.ensureLoaded(configA)

        client.unloadError = TestError.boom
        do {
            try await sut.ensureUnloaded()
            XCTFail("Expected throw")
        } catch {
            // expected
        }
        XCTAssertNil(sut.loaded, "Local belief is cleared even on unload failure (defer).")
    }
}

// MARK: - Test Doubles

enum TestError: Error { case boom }

/// Records every call so tests can assert ordering.
final class RecordingLLMClient: LLMClient, @unchecked Sendable {

    enum Call: Equatable {
        case load(model: String, baseURL: String)
        case unload(instanceID: String, baseURL: String)
        case listLoadedInstances(baseURL: String)
    }

    var calls: [Call] = []

    /// Filtered view of `calls` excluding `.listLoadedInstances`. Useful for
    /// orchestrator-scenario tests that only care about the user-visible
    /// lifecycle (load/unload) and don't want to thread the new adoption-path
    /// list calls through every assertion. The lifecycle-service unit tests
    /// use the raw `calls` to assert the full sequence including listing.
    var loadUnloadCalls: [Call] {
        calls.filter { call in
            if case .listLoadedInstances = call { return false }
            return true
        }
    }

    /// FIFO queue of instance_ids to return from `loadModel`. If empty, returns
    /// a synthetic id derived from the model name.
    var loadResults: [String] = []
    var loadError: Error?
    var unloadError: Error?

    /// Server-side loaded instances visible to `listLoadedInstances`. Default
    /// empty so existing tests get the "fresh server" behavior.
    var listLoadedInstancesResults: [LoadedModelInstance] = []
    var listLoadedInstancesError: Error?

    // Unused chat surface — protocol requirements with default-noop bodies.
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        session _: LLMSession?,
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }

    func loadModel(modelName: String, baseURLString: String) async throws -> String {
        calls.append(.load(model: modelName, baseURL: baseURLString))
        if let loadError { throw loadError }
        if !loadResults.isEmpty { return loadResults.removeFirst() }
        return "instance-for-\(modelName)"
    }

    func unloadModel(instanceID: String, baseURLString: String) async throws {
        calls.append(.unload(instanceID: instanceID, baseURL: baseURLString))
        if let unloadError { throw unloadError }
    }

    func listLoadedInstances(baseURLString: String) async throws -> [LoadedModelInstance] {
        calls.append(.listLoadedInstances(baseURL: baseURLString))
        if let listLoadedInstancesError { throw listLoadedInstancesError }
        return listLoadedInstancesResults
    }
}
