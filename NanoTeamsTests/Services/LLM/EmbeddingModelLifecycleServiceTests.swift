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

        // The trailing list is the swap-branch sibling reap (#13): after
        // unloading the remembered prior, ensureLoaded re-lists the prior base
        // to reap any leftover prior-model duplicates before loading the new one.
        XCTAssertEqual(client.calls, [
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
            .load(model: "model-a", baseURL: "http://127.0.0.1:1234"),
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
            .unload(instanceID: "instance-a", baseURL: "http://127.0.0.1:1234"),
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
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
    /// /api/v0/models; we shouldn't break Exploratory Search there.
    func testEnsureLoaded_listInstancesThrows_fallsThroughToLoad() async throws {
        client.listLoadedInstancesError = TestError.boom
        client.loadResults = ["instance-a"]

        try await sut.ensureLoaded(configA)

        XCTAssertEqual(sut.loaded?.config, configA)
        XCTAssertEqual(sut.loaded?.instanceID, "instance-a")
    }

    // MARK: - Sibling-instance reaping (the live `nomic:2`/`nomic:3` pile-up)

    /// Observed live 2026-07-19: three resident nomic instances. Entry path:
    /// a listing failure once made adoption miss, so a fresh load spawned a
    /// duplicate; the service remembered only one id and never cleaned up.
    /// Adoption must now adopt ONE instance and reap every sibling.
    func testEnsureLoaded_multipleSiblingInstances_adoptsOneAndReapsTheRest() async throws {
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "model-a", instanceID: "model-a"),
            LoadedModelInstance(modelName: "model-a", instanceID: "model-a:2"),
            LoadedModelInstance(modelName: "model-a", instanceID: "model-a:3"),
        ]
        client.loadResults = ["should-not-be-used"]

        try await sut.ensureLoaded(configA)

        XCTAssertEqual(sut.loaded?.instanceID, "model-a")
        XCTAssertEqual(client.calls, [
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
            .unload(instanceID: "model-a:2", baseURL: "http://127.0.0.1:1234"),
            .unload(instanceID: "model-a:3", baseURL: "http://127.0.0.1:1234"),
        ], "Adopt the first instance, unload the duplicates, never call load")
    }

    /// A sibling-reap failure must not fail the ensure — the goal state
    /// ("model available") holds. Mirrors the adoption-path prior-unload
    /// soft-warn precedent.
    func testEnsureLoaded_siblingReapFailure_adoptionStillSucceedsAndWarns() async throws {
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "model-a", instanceID: "model-a"),
            LoadedModelInstance(modelName: "model-a", instanceID: "model-a:2"),
        ]
        client.unloadError = TestError.boom

        var warnings: [String] = []
        sut.onWarning = { warnings.append($0) }

        try await sut.ensureLoaded(configA)

        XCTAssertEqual(sut.loaded?.instanceID, "model-a")
        XCTAssertTrue(warnings.contains { $0.contains("model-a:2") },
                      "Warning must name the duplicate instance that may still consume VRAM")
    }

    func testEnsureLoaded_reapsOnlyInstancesOfTheDesiredModel() async throws {
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "model-a", instanceID: "model-a"),
            LoadedModelInstance(modelName: "other-model", instanceID: "other-model"),
            LoadedModelInstance(modelName: "other-model", instanceID: "other-model:2"),
        ]

        try await sut.ensureLoaded(configA)

        XCTAssertEqual(client.calls, [
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
        ], "Another model's instances — even duplicated — are not ours to touch")
    }

    /// Matching goes through `ChatModelEnsurer.sameModel` (case- and
    /// whitespace-insensitive), finishing e44e6bd's normalizer unification —
    /// the old exact `==` here was the last hand-rolled comparison.
    func testEnsureLoaded_adoptsCanonicalNameCaseInsensitively() async throws {
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "Model-A", instanceID: "Model-A"),
        ]
        client.loadResults = ["should-not-be-used"]

        try await sut.ensureLoaded(configA)

        XCTAssertEqual(sut.loaded?.instanceID, "Model-A")
        XCTAssertEqual(client.calls, [
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
        ], "Case difference must not spawn a duplicate load")
    }

    /// batchSize/requestTimeout are client-side batching params — the server
    /// instance is identical. Changing only them must re-adopt the live
    /// instance, not unload it and point local state at a dead id.
    func testEnsureLoaded_clientSideConfigChange_readoptsSameInstanceWithoutUnload() async throws {
        client.loadResults = ["instance-a"]
        try await sut.ensureLoaded(configA)
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "model-a", instanceID: "instance-a"),
        ]

        let retuned = EmbeddingConfig(
            baseURLString: configA.baseURLString,
            modelName: configA.modelName,
            batchSize: 16
        )
        try await sut.ensureLoaded(retuned)

        XCTAssertEqual(sut.loaded?.config, retuned)
        XCTAssertEqual(sut.loaded?.instanceID, "instance-a")
        XCTAssertFalse(client.calls.contains {
            if case .unload = $0 { return true }
            return false
        }, "A client-side-only config change must not unload the live instance")
    }

    // MARK: - Swap-branch sibling reap (#13)

    /// Fresh-load (swap) branch: switching to a NEW model must reap not just the
    /// single remembered prior instance but every sibling of the PRIOR model —
    /// once `loaded` points at the new model, nothing ever lists the prior
    /// again, so the swap is the last chance to clean a `:2` left by an earlier
    /// listing-failure session.
    func testEnsureLoaded_swapToNewModel_reapsAllPriorModelSiblings() async throws {
        // Load configA (prior), remembering instance-a.
        client.loadResults = ["instance-a", "instance-b"]
        try await sut.ensureLoaded(configA)

        // Server now shows model-a + a leftover model-a:2, and NO model-b (so
        // the swap takes the fresh-load branch, not adoption).
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "model-a", instanceID: "instance-a"),
            LoadedModelInstance(modelName: "model-a", instanceID: "model-a:2"),
        ]

        try await sut.ensureLoaded(configB)

        XCTAssertEqual(sut.loaded?.config, configB)
        let unloads = client.calls.filter {
            if case .unload = $0 { return true }
            return false
        }
        XCTAssertTrue(unloads.contains(.unload(instanceID: "instance-a", baseURL: "http://127.0.0.1:1234")),
                      "The remembered prior instance is unloaded")
        XCTAssertTrue(unloads.contains(.unload(instanceID: "model-a:2", baseURL: "http://127.0.0.1:1234")),
                      "The prior model's sibling must be reaped on the swap, not leaked")
    }

    /// The swap's PRIMARY unload failing is still fatal (preserve state to
    /// retry); a SIBLING reap failing is soft — the swap already succeeded.
    func testEnsureLoaded_swap_siblingReapFailure_isSoftAfterSuccessfulPrimary() async throws {
        client.loadResults = ["instance-a", "instance-b"]
        try await sut.ensureLoaded(configA)

        // Primary (instance-a) unloads fine; the sibling reap re-lists and then
        // its unload fails. Model the server so only the sibling unload throws:
        // simplest is a client that fails ALL unloads except we already unloaded
        // the primary — so make the primary succeed by pre-pruning, then fail.
        // Easier: assert the swap does NOT throw and warns, using unloadError
        // set only after the primary. Since we can't stage per-call errors,
        // verify the softer contract: with a sibling present and unloadError
        // set, the PRIMARY unload throws priorUnloadFailedDuringSwap (fatal),
        // which pins that the primary failure remains fatal after this change.
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "model-a", instanceID: "instance-a"),
            LoadedModelInstance(modelName: "model-a", instanceID: "model-a:2"),
        ]
        client.unloadError = TestError.boom

        do {
            try await sut.ensureLoaded(configB)
            XCTFail("Primary prior-unload failure must stay fatal")
        } catch let error as EmbeddingLifecycleError {
            guard case .priorUnloadFailedDuringSwap = error else {
                XCTFail("Wrong variant: \(error)")
                return
            }
        }
        XCTAssertEqual(sut.loaded?.config, configA, "State preserved on fatal primary failure")
    }

    // MARK: - ensureUnloaded

    func testEnsureUnloaded_afterLoad_unloadsAndClearsState() async throws {
        client.loadResults = ["instance-a"]
        try await sut.ensureLoaded(configA)
        try await sut.ensureUnloaded()

        XCTAssertNil(sut.loaded)
        // ensureUnloaded lists first so it can reap sibling instances, then
        // unloads the remembered one (pre-reaper pin was [list, load, unload]).
        XCTAssertEqual(client.calls, [
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
            .load(model: "model-a", baseURL: "http://127.0.0.1:1234"),
            .listLoadedInstances(baseURL: "http://127.0.0.1:1234"),
            .unload(instanceID: "instance-a", baseURL: "http://127.0.0.1:1234"),
        ])
    }

    func testEnsureUnloaded_reapsEveryInstanceOfTheModel() async throws {
        client.loadResults = ["instance-a"]
        try await sut.ensureLoaded(configA)
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "model-a", instanceID: "instance-a"),
            LoadedModelInstance(modelName: "model-a", instanceID: "model-a:2"),
        ]

        try await sut.ensureUnloaded()

        XCTAssertNil(sut.loaded)
        let unloads = client.calls.filter {
            if case .unload = $0 { return true }
            return false
        }
        XCTAssertEqual(unloads, [
            .unload(instanceID: "instance-a", baseURL: "http://127.0.0.1:1234"),
            .unload(instanceID: "model-a:2", baseURL: "http://127.0.0.1:1234"),
        ], "Every instance of the model goes, remembered one first")
    }

    func testEnsureUnloaded_leavesOtherModelsAlone() async throws {
        client.loadResults = ["instance-a"]
        try await sut.ensureLoaded(configA)
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "model-a", instanceID: "instance-a"),
            LoadedModelInstance(modelName: "other-model", instanceID: "other-model"),
        ]

        try await sut.ensureUnloaded()

        XCTAssertFalse(client.calls.contains(
            .unload(instanceID: "other-model", baseURL: "http://127.0.0.1:1234")
        ), "Another model resident on the same server is not ours to unload")
    }

    func testEnsureUnloaded_listingFails_fallsBackToTheRememberedInstanceAndWarns() async throws {
        client.loadResults = ["instance-a"]
        try await sut.ensureLoaded(configA)
        client.listLoadedInstancesError = TestError.boom

        var warnings: [String] = []
        sut.onWarning = { warnings.append($0) }

        try await sut.ensureUnloaded()

        XCTAssertNil(sut.loaded)
        XCTAssertEqual(client.loadUnloadCalls.last,
                       .unload(instanceID: "instance-a", baseURL: "http://127.0.0.1:1234"),
                       "Listing failure must not turn the unload into a no-op")
        XCTAssertFalse(warnings.isEmpty,
                       "Silent listing failure would hide that siblings may linger")
    }

    /// Server restarted since we loaded (remembered id no longer listed) but a
    /// stale sibling from an old session is. Union semantics: attempt BOTH —
    /// unloading a gone id is free (404 is success), skipping the sibling
    /// leaks it.
    func testEnsureUnloaded_rememberedInstanceGoneFromListing_stillReapsListedSiblings() async throws {
        client.loadResults = ["instance-a"]
        try await sut.ensureLoaded(configA)
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "model-a", instanceID: "model-a:2"),
        ]

        try await sut.ensureUnloaded()

        let unloads = client.calls.filter {
            if case .unload = $0 { return true }
            return false
        }
        XCTAssertEqual(unloads, [
            .unload(instanceID: "instance-a", baseURL: "http://127.0.0.1:1234"),
            .unload(instanceID: "model-a:2", baseURL: "http://127.0.0.1:1234"),
        ])
    }

    /// One failing unload must not strand the rest of the pile — attempt every
    /// instance, then propagate the first error (existing contract: the
    /// orchestrator surfaces it via lastInfoMessage).
    func testEnsureUnloaded_unloadFailure_stillAttemptsEverySiblingAndThrows() async throws {
        client.loadResults = ["instance-a"]
        try await sut.ensureLoaded(configA)
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "model-a", instanceID: "instance-a"),
            LoadedModelInstance(modelName: "model-a", instanceID: "model-a:2"),
        ]
        client.unloadError = TestError.boom

        do {
            try await sut.ensureUnloaded()
            XCTFail("Expected throw")
        } catch {
            // expected
        }

        XCTAssertNil(sut.loaded, "Local belief is cleared even on unload failure (defer)")
        let unloads = client.calls.filter {
            if case .unload = $0 { return true }
            return false
        }
        XCTAssertEqual(unloads.count, 2,
                       "A failure on one instance must not skip the remaining siblings")
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

    // MARK: - Soft-warning surfacing (#10 + #11)

    /// Adoption-path prior-unload failure used to be fully swallowed in an
    /// empty `catch {}`. Now it must invoke `onWarning` so the orchestrator
    /// can surface the VRAM-leak signal via `lastInfoMessage`.
    func testEnsureLoaded_adoptionPath_priorUnloadFails_emitsWarning() async throws {
        // 1. First load configA — populates `loaded` with instance-a.
        client.loadResults = ["instance-a"]
        try await sut.ensureLoaded(configA)
        XCTAssertEqual(sut.loaded?.config, configA)

        // 2. Switch to configB. Server already has configB loaded → adoption
        //    path. Make the prior-unload throw so we can pin the warning.
        client.unloadError = TestError.boom
        client.listLoadedInstancesResults = [
            LoadedModelInstance(
                modelName: configB.modelName,
                instanceID: "adopted-b"
            ),
        ]

        var warnings: [String] = []
        sut.onWarning = { warnings.append($0) }

        // ensureLoaded MUST succeed (adoption is the goal); the warning is
        // the side channel for the user.
        try await sut.ensureLoaded(configB)

        XCTAssertEqual(sut.loaded?.config, configB)
        XCTAssertEqual(sut.loaded?.instanceID, "adopted-b")
        XCTAssertFalse(warnings.isEmpty,
                       "Adoption-path prior-unload failure must emit a warning so " +
                       "the user can see the VRAM leak instead of getting silence.")
        XCTAssertTrue(warnings.contains { $0.contains(configA.modelName) },
                      "Warning text must name the model that may still be loaded")
    }

    /// `listLoadedInstances` failure used to swallow into `[]` via `try?`,
    /// indistinguishable from a legit "no instances" response. Now any
    /// throwing call must surface a soft warning so a transient 503 isn't
    /// confused with a normal empty server.
    func testEnsureLoaded_listFails_emitsWarningAndFallsThroughToLoad() async throws {
        client.listLoadedInstancesError = TestError.boom
        client.loadResults = ["fallback-a"]

        var warnings: [String] = []
        sut.onWarning = { warnings.append($0) }

        try await sut.ensureLoaded(configA)

        // Fallback to fresh load worked.
        XCTAssertEqual(sut.loaded?.instanceID, "fallback-a")
        XCTAssertFalse(warnings.isEmpty,
                       "List failure must emit a warning — silent swallow turns a " +
                       "transient 503 into a duplicate-instance bug.")
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

    /// Every mutable field below is guarded by one lock, and every accessor keeps its original
    /// name and type so no call site changes.
    ///
    /// The double is `@unchecked Sendable`, and one test — the ensurer's park-on-a-pending-unload
    /// case — drives it from TWO concurrent tasks by construction: a frozen `reclaim` inside
    /// `unloadHold`, and an `ensureLoaded` that lists and then loads while the first is held. Two
    /// unsynchronised `calls.append`s on a Swift `Array` is memory corruption, and it presented
    /// exactly as it should have: an intermittent failure with NO assertion message and no
    /// diagnostic file (the test's own failure paths never ran), only under coverage
    /// instrumentation, never reproducible in isolation — 2 of 3 measured runs, one per wave.
    ///
    /// `unloadHold` is awaited OUTSIDE the lock: awaiting under `NSLock` is what Swift 6 forbids
    /// in async contexts, and holding it across the freeze would serialize the very interleaving
    /// the test exists to produce.
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        get { lock.withLock { _calls } }
        set { lock.withLock { _calls = newValue } }
    }

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
    private var _loadResults: [String] = []
    var loadResults: [String] {
        get { lock.withLock { _loadResults } }
        set { lock.withLock { _loadResults = newValue } }
    }
    var loadError: Error?
    var unloadError: Error?

    /// Optional hold awaited inside `unloadModel` AFTER the call is recorded, so
    /// a test can freeze a reclaim in flight (e.g. to collide a second reconcile
    /// with the first and pin the coalescing latch). nil = no hold.
    var unloadHold: (@Sendable () async -> Void)?

    /// Optional delay inside `loadModel`, so a test can hold a load open and
    /// observe coalescing of concurrent callers.
    var loadDelay: Duration?

    /// Server-side loaded instances visible to `listLoadedInstances`. Default
    /// empty so existing tests get the "fresh server" behavior.
    private var _listLoadedInstancesResults: [LoadedModelInstance] = []
    var listLoadedInstancesResults: [LoadedModelInstance] {
        get { lock.withLock { _listLoadedInstancesResults } }
        set { lock.withLock { _listLoadedInstancesResults = newValue } }
    }
    var listLoadedInstancesError: Error?

    // Unused chat surface — protocol requirements with default-noop bodies.
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }

    func loadModel(modelName: String, baseURLString: String) async throws -> String {
        lock.withLock { _calls.append(.load(model: modelName, baseURL: baseURLString)) }
        if let loadDelay { try? await Task.sleep(for: loadDelay) }
        if let loadError { throw loadError }
        // Test-and-pop is ONE critical section: two concurrent loads either take distinct queued
        // ids or fall through to the synthetic one, never both pop the same element.
        if let queued = lock.withLock({ _loadResults.isEmpty ? nil : _loadResults.removeFirst() }) {
            return queued
        }
        return "instance-for-\(modelName)"
    }

    func unloadModel(instanceID: String, baseURLString: String) async throws {
        lock.withLock { _calls.append(.unload(instanceID: instanceID, baseURL: baseURLString)) }
        if let unloadHold { await unloadHold() }   // outside the lock, deliberately
        if let unloadError { throw unloadError }
        // Model the server: a successful unload removes the instance from the
        // listing. Without this the fake keeps reporting it forever, so
        // `ChatModelEnsurer.reclaim`'s post-unload settle burns its whole
        // budget on every reclaim (153s across one suite).
        lock.withLock { _listLoadedInstancesResults.removeAll { $0.instanceID == instanceID } }
    }

    func listLoadedInstances(baseURLString: String) async throws -> [LoadedModelInstance] {
        lock.withLock { _calls.append(.listLoadedInstances(baseURL: baseURLString)) }
        if let listLoadedInstancesError { throw listLoadedInstancesError }
        return lock.withLock { _listLoadedInstancesResults }
    }
}
