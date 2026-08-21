import XCTest

@testable import NanoTeams

/// `ChatModelEnsurer` guarantees the chat model is EXPLICITLY loaded before a
/// chat request, so LM Studio never JIT-loads it — JIT instances are subject
/// to Auto-Evict (at most ONE resident) and a 60-minute idle TTL, which is
/// what would otherwise make the chat, Vision and embedding models evict each
/// other.
///
/// Pinned behavior:
/// - adopt when already loaded (no duplicate `name:2` instance),
/// - load through the client otherwise,
/// - coalescing of concurrent ensures,
/// - fail-open when the loaded-instances listing fails,
/// - NEVER unloads (unloading lives solely in the model-switch hook).
final class ChatModelEnsurerTests: XCTestCase, @unchecked Sendable {

    private let baseURL = "http://127.0.0.1:1234"

    // MARK: - Adopt (never load the same model twice)

    func testEnsureLoaded_alreadyLoaded_adoptsWithoutLoading() async throws {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen")
        ]
        let sut = ChatModelEnsurer()

        try await sut.ensureLoaded(modelName: "qwen", baseURLString: baseURL, client: client)

        XCTAssertEqual(client.loadUnloadCalls, [], "An already-loaded model must not be re-loaded")
    }

    /// LM Studio names duplicate instances `model:2`; `listLoadedInstances`
    /// reports the canonical name, so a `:N` instance is still an adoption.
    func testEnsureLoaded_canonicalMatchOnSuffixedInstance_adopts() async throws {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen:2")
        ]
        let sut = ChatModelEnsurer()

        try await sut.ensureLoaded(modelName: "qwen", baseURLString: baseURL, client: client)

        XCTAssertEqual(client.loadUnloadCalls, [])
    }

    /// A hand-typed per-role override can differ in case from the LM Studio
    /// key. Treating that as a different model would load a redundant
    /// duplicate instance of the SAME model.
    func testEnsureLoaded_caseAndWhitespaceDifference_stillAdopts() async throws {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "qwen/Qwen3.6-35B", instanceID: "qwen/Qwen3.6-35B")
        ]
        let sut = ChatModelEnsurer()

        try await sut.ensureLoaded(
            modelName: "  qwen/qwen3.6-35b  ", baseURLString: baseURL, client: client)

        XCTAssertEqual(client.loadUnloadCalls, [], "The same model must never be loaded twice")
    }

    /// Repeated ensures for a model that stays loaded must keep adopting — the
    /// check runs per call, so a warm model costs a listing and nothing else.
    func testEnsureLoaded_repeatedCallsWhileLoaded_neverReload() async throws {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen")
        ]
        let sut = ChatModelEnsurer()

        for _ in 0..<3 {
            try await sut.ensureLoaded(modelName: "qwen", baseURLString: baseURL, client: client)
        }

        XCTAssertEqual(client.loadUnloadCalls, [])
    }

    func testSameModel_truthTable() {
        XCTAssertTrue(ChatModelEnsurer.sameModel("qwen", "qwen"))
        XCTAssertTrue(ChatModelEnsurer.sameModel("QWEN", "qwen"))
        XCTAssertTrue(ChatModelEnsurer.sameModel(" qwen ", "qwen"))
        XCTAssertFalse(ChatModelEnsurer.sameModel("qwen", "qwen-2"))
        XCTAssertFalse(ChatModelEnsurer.sameModel("qwen", ""))
    }

    // MARK: - Load

    func testEnsureLoaded_notLoaded_loadsExplicitly() async throws {
        let client = RecordingLLMClient()
        let sut = ChatModelEnsurer()

        try await sut.ensureLoaded(modelName: "qwen", baseURLString: baseURL, client: client)

        XCTAssertEqual(client.loadUnloadCalls, [.load(model: "qwen", baseURL: baseURL)])
    }

    /// A model loaded under a DIFFERENT name is not ours — the requested one
    /// must still be loaded (both then coexist; explicit loads don't evict).
    func testEnsureLoaded_otherModelLoaded_stillLoadsRequested() async throws {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "other-model", instanceID: "other-model")
        ]
        let sut = ChatModelEnsurer()

        try await sut.ensureLoaded(modelName: "qwen", baseURLString: baseURL, client: client)

        XCTAssertEqual(client.loadUnloadCalls, [.load(model: "qwen", baseURL: baseURL)])
    }

    // MARK: - Failure handling

    /// Listing failure is fail-OPEN: the chat call itself surfaces the
    /// canonical connection error, and test doubles that don't implement the
    /// lifecycle API keep working.
    func testEnsureLoaded_listFailure_skipsSilently() async throws {
        let client = RecordingLLMClient()
        client.listLoadedInstancesError = TestError.boom
        let sut = ChatModelEnsurer()

        try await sut.ensureLoaded(modelName: "qwen", baseURLString: baseURL, client: client)

        XCTAssertEqual(client.loadUnloadCalls, [])
    }

    /// A server that ANSWERS but cannot list is the opposite decision from one we could not
    /// reach — and this is the pin that says so, because both used to be an empty array.
    ///
    /// Skipping here would defeat the only reason this type exists: an unloaded model would then
    /// be JIT-loaded by the chat request, and a JIT instance is Auto-Evict eligible with a
    /// 60-minute idle TTL. Adoption is impossible (nothing was listed), so the load must happen.
    ///
    /// RED: route `.unsupported` into the `catch` (`return .skipped`) → no load is issued, and
    /// LM Studio JIT-loads the chat model behind the ensurer's back.
    func testEnsureLoaded_listingUnsupported_stillLoadsExplicitly() async throws {
        let client = RecordingLLMClient()
        client.listLoadedInstancesUnsupported = true
        let sut = ChatModelEnsurer()

        try await sut.ensureLoaded(modelName: "qwen", baseURLString: baseURL, client: client)

        XCTAssertEqual(
            client.loadUnloadCalls, [.load(model: "qwen", baseURL: baseURL)],
            "a listing-less server must still get an explicit load, not a JIT one")
    }

    /// A load failure is actionable ("model not found") — surfacing it beats a
    /// vague downstream chat error.
    func testEnsureLoaded_loadFailure_throws() async {
        let client = RecordingLLMClient()
        client.loadError = TestError.boom
        let sut = ChatModelEnsurer()

        do {
            try await sut.ensureLoaded(modelName: "qwen", baseURLString: baseURL, client: client)
            XCTFail("Expected the load failure to propagate")
        } catch {
            // expected
        }
    }

    // MARK: - Coalescing

    /// Parallel roles (CLAUDE.md #45) must await ONE load — concurrent
    /// `loadModel` calls would otherwise spawn duplicate `name:2` instances.
    func testEnsureLoaded_concurrentCalls_coalesceIntoOneLoad() async throws {
        let client = RecordingLLMClient()
        client.loadDelay = .milliseconds(120)
        let sut = ChatModelEnsurer()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { [baseURL] in
                    _ = try? await sut.ensureLoaded(
                        modelName: "qwen", baseURLString: baseURL, client: client)
                }
            }
        }

        let loads = client.calls.filter { if case .load = $0 { return true } else { return false } }
        XCTAssertEqual(loads.count, 1, "Concurrent ensures must share one in-flight load")
    }

    // MARK: - Additivity

    /// Unloading belongs to the model-switch hook only. A per-call unload would
    /// swap-thrash when parallel roles use different per-role-override models,
    /// and would break chat/Vision/embedding coexistence.
    func testEnsureLoaded_neverUnloads() async throws {
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "other-model", instanceID: "other-model")
        ]
        let sut = ChatModelEnsurer()

        try await sut.ensureLoaded(modelName: "qwen", baseURLString: baseURL, client: client)

        let unloads = client.calls.filter { if case .unload = $0 { return true } else { return false } }
        XCTAssertTrue(unloads.isEmpty, "ensureLoaded must never unload a sibling model")
    }

    /// The coalescing key folds the base URL the same way every other
    /// normalizer does, so two spellings of one server share the in-flight
    /// load instead of racing two loads of the same model.
    func testEnsureLoaded_baseURLSpellingVariants_shareOneLoad() async throws {
        let client = RecordingLLMClient()
        client.loadDelay = .milliseconds(120)
        let sut = ChatModelEnsurer()
        let spellings = ["http://127.0.0.1:1234", "http://127.0.0.1:1234/", "HTTP://127.0.0.1:1234"]

        await withTaskGroup(of: Void.self) { group in
            for spelling in spellings {
                group.addTask {
                    _ = try? await sut.ensureLoaded(
                        modelName: "qwen", baseURLString: spelling, client: client)
                }
            }
        }

        let loads = client.calls.filter { if case .load = $0 { return true } else { return false } }
        XCTAssertEqual(loads.count, 1, "Trailing slash / casing must not split the coalescing key")
    }

    // MARK: - Request census

    /// The census is what lets `switchChatModel` refuse to unload a model
    /// mid-stream. It is the ONLY in-use signal that sees the taskless one-shot
    /// callers (work-folder context, prompt improvement, Team Editor team
    /// generation), which have no task, step or engine to observe.
    func testRequestCensus_openRequest_isVisible() async {
        let sut = ChatModelEnsurer()

        await sut.beginRequest(modelName: "qwen", baseURLString: baseURL)

        let open = await sut.hasOpenRequest(modelName: "qwen", baseURLString: baseURL)
        XCTAssertTrue(open)
    }

    func testRequestCensus_balancedBeginEnd_leavesNothingOpen() async {
        let sut = ChatModelEnsurer()

        await sut.beginRequest(modelName: "qwen", baseURLString: baseURL)
        await sut.endRequest(modelName: "qwen", baseURLString: baseURL)

        let open = await sut.hasOpenRequest(modelName: "qwen", baseURLString: baseURL)
        XCTAssertFalse(open, "A balanced bracket must not leave the model pinned forever")
    }

    /// A count, not a flag: parallel roles (CLAUDE.md #45) stream against the
    /// same model, and the first one to finish must not clear the protection
    /// the others still need.
    func testRequestCensus_nestedRequests_stayOpenUntilTheLastOneEnds() async {
        let sut = ChatModelEnsurer()

        await sut.beginRequest(modelName: "qwen", baseURLString: baseURL)
        await sut.beginRequest(modelName: "qwen", baseURLString: baseURL)
        await sut.endRequest(modelName: "qwen", baseURLString: baseURL)

        var open = await sut.hasOpenRequest(modelName: "qwen", baseURLString: baseURL)
        XCTAssertTrue(open, "One of two concurrent requests finishing must not unpin the model")

        await sut.endRequest(modelName: "qwen", baseURLString: baseURL)
        open = await sut.hasOpenRequest(modelName: "qwen", baseURLString: baseURL)
        XCTAssertFalse(open)
    }

    /// An unbalanced extra `endRequest` (a double-decrement) must not drive the
    /// count negative and leave a phantom entry that reads as "in use".
    func testRequestCensus_extraEnd_isHarmless() async {
        let sut = ChatModelEnsurer()

        await sut.endRequest(modelName: "qwen", baseURLString: baseURL)
        await sut.beginRequest(modelName: "qwen", baseURLString: baseURL)
        await sut.endRequest(modelName: "qwen", baseURLString: baseURL)
        await sut.endRequest(modelName: "qwen", baseURLString: baseURL)

        let open = await sut.hasOpenRequest(modelName: "qwen", baseURLString: baseURL)
        XCTAssertFalse(open)
    }

    /// The census keys models the same way `sameModel` compares them, so a
    /// casing/whitespace variant of an open request is still seen as open.
    func testRequestCensus_foldsModelCaseAndURLShape() async {
        let sut = ChatModelEnsurer()

        await sut.beginRequest(modelName: "Qwen/Model", baseURLString: "http://127.0.0.1:1234/")

        let open = await sut.hasOpenRequest(
            modelName: "  qwen/model  ", baseURLString: "HTTP://127.0.0.1:1234")
        XCTAssertTrue(open)
    }

    /// A census entry is per (base, model) — an open request must not pin an
    /// unrelated model, or the switch hook would never unload anything.
    func testRequestCensus_isScopedToItsOwnModelAndServer() async {
        let sut = ChatModelEnsurer()

        await sut.beginRequest(modelName: "qwen", baseURLString: baseURL)

        var other = await sut.hasOpenRequest(modelName: "other-model", baseURLString: baseURL)
        XCTAssertFalse(other)
        other = await sut.hasOpenRequest(modelName: "qwen", baseURLString: "http://elsewhere:1234")
        XCTAssertFalse(other)
    }

    // MARK: - Degenerate input

    func testEnsureLoaded_emptyModelName_isNoOp() async throws {
        let client = RecordingLLMClient()
        let sut = ChatModelEnsurer()

        try await sut.ensureLoaded(modelName: "   ", baseURLString: baseURL, client: client)

        XCTAssertEqual(client.calls, [], "A blank model name must not reach the server")
    }

    func testRequestCensus_blankModelName_isNotTracked() async {
        let sut = ChatModelEnsurer()

        await sut.beginRequest(modelName: "   ", baseURLString: baseURL)

        let open = await sut.hasOpenRequest(modelName: "   ", baseURLString: baseURL)
        XCTAssertFalse(open, "A blank model can't be unloaded, so it needs no protection")
    }
}
