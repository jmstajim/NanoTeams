import XCTest

@testable import NanoTeams

/// Pins "exactly one model resident, and it is the one being measured" — the app's H1 check.
/// Pure orchestration over a recording double, so nothing here touches a server.
final class BenchmarkResidencyPreparerTests: XCTestCase {

    private func target(
        provider: LLMProvider = .lmStudio, model: String = "qwen3.6"
    ) -> BenchmarkTarget {
        BenchmarkTarget(
            provider: provider,
            baseURLString: provider.defaultBaseURL,
            modelName: model)
    }

    /// RED: skip the eviction loop → the other model stays resident, competing for memory
    /// bandwidth for the whole run.
    func testUnloadsEveryOtherModel() async {
        let client = RecordingLifecycleClient(resident: ["qwen3.6", "gpt-oss-20b", "nomic-embed"])
        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [], client: client)

        XCTAssertEqual(report.unloadedModels.sorted(), ["gpt-oss-20b", "nomic-embed"])
        XCTAssertEqual(client.unloaded.sorted(), ["gpt-oss-20b", "nomic-embed"])
    }

    /// RED: evict by "everything then reload" → the target is unloaded and loaded again for no
    /// reason, adding a cold load to a run that did not need one.
    func testDoesNotUnloadTheTargetItself() async {
        let client = RecordingLifecycleClient(resident: ["qwen3.6"])
        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [], client: client)

        XCTAssertTrue(client.unloaded.isEmpty)
        XCTAssertTrue(report.targetWasResident)
        XCTAssertTrue(report.unloadedModels.isEmpty)
    }

    func testLoadsTheTargetWhenAbsent_onAProviderThatManagesResidency() async {
        let client = RecordingLifecycleClient(resident: ["gpt-oss-20b"])
        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [], client: client)

        XCTAssertEqual(client.loaded, ["qwen3.6"])
        XCTAssertFalse(report.targetWasResident)
    }

    /// Ollama loads on first use and the app never manages its residency.
    ///
    /// RED: call `loadModel` regardless of the provider → it hits the protocol default, which
    /// THROWS, turning a successful preparation into a recorded failure on the one provider where
    /// nothing was wrong.
    func testDoesNotLoadOnAProviderThatManagesItsOwnResidency() async {
        let client = RecordingLifecycleClient(resident: ["other"])
        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(provider: .ollama, model: "qwen3.8"), otherServers: [], client: client)

        XCTAssertTrue(client.loaded.isEmpty)
        XCTAssertNil(report.failure)
    }

    /// The preparer must forward the TARGET's provider, not a constant. Everything downstream of
    /// this — which client answers, whether the answer describes the server at all — hangs on it,
    /// and a constant compiles.
    ///
    /// RED: pass `.lmStudio` (or any literal) → an Ollama benchmark asks the LM Studio client,
    /// which asks Ollama for `/api/v0/models`, gets 404, and returns an empty list. The run then
    /// records `Residency: already alone` about a machine it never asked.
    func testAsksTheServerAsTheTargetsProvider() async {
        let client = RecordingLifecycleClient(resident: ["other", "qwen3.8"])
        _ = await BenchmarkResidencyPreparer.prepare(
            target: target(provider: .ollama, model: "qwen3.8"), otherServers: [], client: client)

        XCTAssertFalse(client.providers.isEmpty, "the preparer asked nothing at all")
        XCTAssertTrue(
            client.providers.allSatisfy { $0 == .ollama },
            "asked as \(client.providers) — every call must name the target's own provider")
    }

    /// The complement, so the assertion above cannot be satisfied by hardcoding `.ollama` instead.
    func testAsksTheServerAsLMStudioWhenThatIsTheTarget() async {
        let client = RecordingLifecycleClient(resident: ["other"])
        _ = await BenchmarkResidencyPreparer.prepare(
            target: target(provider: .lmStudio, model: "qwen3.6"), otherServers: [], client: client)

        XCTAssertTrue(client.providers.allSatisfy { $0 == .lmStudio }, "\(client.providers)")
    }

    /// A server that ANSWERS but has no listing route is not a clean machine — it is an
    /// unanswered question, and the two used to be the same empty array.
    ///
    /// RED: treat `.unsupported` as `.listed([])` (what `adoptable` does, and what the LM Studio
    /// client used to do for a 404) → `couldInspect` goes true, the summary reads "already alone",
    /// and every run on that server carries a verification that never happened.
    func testListingUnsupported_reportsThatNothingWasVerified() async {
        let client = RecordingLifecycleClient(resident: [], listingUnsupported: true)
        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [], client: client)

        XCTAssertFalse(report.couldInspect)
        XCTAssertEqual(report.summary, "not verified")
        XCTAssertTrue(client.unloaded.isEmpty)
        XCTAssertTrue(client.loaded.isEmpty, "nothing may be loaded off an unverified machine")
        XCTAssertFalse(report.targetResidentAfterPrepare)
    }

    /// The complement, and the reason `.unsupported` had to be a separate case rather than an
    /// empty list: a server that genuinely has nothing loaded IS verified, and the run may say so.
    ///
    /// RED: fold `.listed([])` into the unsupported branch → a clean machine reads as unchecked
    /// and the benchmark stops loading the target it was asked to measure.
    func testEmptyListing_isAnAnswerAndCountsAsVerified() async {
        let client = RecordingLifecycleClient(resident: [])
        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [], client: client)

        XCTAssertTrue(report.couldInspect)
        XCTAssertEqual(report.summary, "already alone")
        XCTAssertEqual(client.loaded, ["qwen3.6"])
    }

    /// RED: report `couldInspect = true` regardless → a run whose machine was never checked reads
    /// exactly like one that was verified clean.
    func testListingFailure_reportsThatNothingWasVerified() async {
        let client = RecordingLifecycleClient(resident: [], listingFails: true)
        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [], client: client)

        XCTAssertFalse(report.couldInspect)
        XCTAssertEqual(report.summary, "not verified")
        XCTAssertTrue(client.unloaded.isEmpty)
    }

    /// A refused eviction must not abort the run: the caveat is more useful than no measurement.
    /// RED: propagate the error → the whole benchmark fails because housekeeping did.
    func testUnloadFailure_isRecordedAndTheRunContinues() async {
        let client = RecordingLifecycleClient(resident: ["stuck"], unloadFails: true)
        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [], client: client)

        XCTAssertTrue(report.couldInspect)
        XCTAssertTrue(report.unloadedModels.isEmpty)
        XCTAssertNotNil(report.failure)
        XCTAssertTrue(try! XCTUnwrap(report.failure).contains("stuck"))
    }

    /// A refused LOAD is the mirror of a refused unload, and must be reported the same way
    /// rather than aborting. RED: propagate → the run dies because the model could not be
    /// pre-loaded, even though the first sample would have loaded it anyway.
    func testLoadFailure_isRecordedAndTheRunContinues() async {
        let client = RecordingLifecycleClient(resident: [], loadFails: true)
        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [], client: client)

        XCTAssertTrue(report.couldInspect)
        XCTAssertFalse(report.targetWasResident)
        XCTAssertNotNil(report.failure)
        XCTAssertTrue(try! XCTUnwrap(report.failure).contains("qwen3.6"))
    }

    func testSummary_distinguishesTheThreeOutcomes() {
        var report = BenchmarkResidencyPreparer.Report()
        XCTAssertEqual(report.summary, "not verified")
        report.couldInspect = true
        XCTAssertEqual(report.summary, "already alone")
        report.targetWasResident = true
        XCTAssertEqual(report.summary, "already alone, resident")
        report.unloadedModels = ["a"]
        XCTAssertEqual(report.summary, "unloaded 1 other model")
        report.unloadedModels = ["a", "b"]
        XCTAssertEqual(report.summary, "unloaded 2 other models")
    }

    /// A target whose name has stray whitespace must still match what the server reported, or the
    /// preparer would evict the very model it is about to measure.
    func testTargetNameIsTrimmedBeforeMatching() async {
        let client = RecordingLifecycleClient(resident: ["qwen3.6"])
        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(model: "  qwen3.6 "), otherServers: [], client: client)

        XCTAssertTrue(client.unloaded.isEmpty)
        XCTAssertTrue(report.targetWasResident)
    }

    // MARK: - Other servers (DEBTS.md D-B1 §2)

    private func otherServer(
        _ provider: LLMProvider = .ollama, url: String? = nil
    ) -> BenchmarkServer {
        BenchmarkServer(provider: provider, baseURLString: url ?? provider.defaultBaseURL)
    }

    /// The whole point: a model resident on the OTHER provider's server competes for the same
    /// unified memory, and until this existed the figure was depressed with nothing saying so.
    ///
    /// RED: ignore `otherServers` → `unloadedElsewhere` is empty, the Ollama model stays resident
    /// for the whole LM Studio run, and `Residency` still reads "already alone".
    func testClearsEveryModelOnTheOtherServer() async {
        let client = RecordingLifecycleClient(
            resident: ["qwen3.6"],
            residentByURL: [LLMProvider.ollama.defaultBaseURL: ["llama3.1:8b", "gpt-oss:20b"]])

        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [otherServer()], client: client)

        XCTAssertEqual(report.otherServers.count, 1)
        XCTAssertEqual(report.otherServers.first?.unloadedModels.sorted(),
                       ["gpt-oss:20b", "llama3.1:8b"])
        XCTAssertEqual(report.otherServers.first?.summary, "unloaded 2 models")
    }

    /// EVERYTHING there, not all-but-one: nothing on that server is being measured, so the
    /// target-name exemption must not travel with it.
    ///
    /// RED: reuse the target's `where instance.modelName != wanted` filter on the other server →
    /// a same-named model on the other provider survives, which is exactly the case a sweep hits
    /// (the same model pulled on both providers).
    func testOtherServer_isEmptiedEvenOfAModelSharingTheTargetsName() async {
        let client = RecordingLifecycleClient(
            resident: [],
            residentByURL: [LLMProvider.ollama.defaultBaseURL: ["qwen3.6"]])

        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(model: "qwen3.6"), otherServers: [otherServer()], client: client)

        XCTAssertEqual(report.otherServers.first?.unloadedModels, ["qwen3.6"])
    }

    /// Nothing is ever LOADED on a server that holds no target — it would be a model nobody asked
    /// for, competing with the measurement.
    ///
    /// RED: run the target's load branch for other servers too → the preparer loads a model on the
    /// other provider, and the pass that exists to empty the machine fills it instead.
    func testOtherServer_isNeverLoadedOnto() async {
        let client = RecordingLifecycleClient(resident: [])

        _ = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [otherServer(.lmStudio, url: "http://other:1234")],
            client: client)

        XCTAssertEqual(client.loaded, ["qwen3.6"],
                       "only the target was loaded — \(client.loaded)")
    }

    /// The listing is the permission slip. An address with nothing behind it is the COMMON case
    /// (the user runs one provider), and it must cost a question and produce a recorded "we did
    /// not check" — never a command.
    ///
    /// RED: unload without switching on the listing result → the preparer fires eviction commands
    /// at a provider's documented default port on every single run, which is the thing the old
    /// one-server scope existed to refuse.
    func testOtherServer_thatAnswersNothing_isRecordedUnverifiedAndUntouched() async {
        let client = RecordingLifecycleClient(
            resident: [], unansweredURLs: [LLMProvider.ollama.defaultBaseURL])

        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [otherServer()], client: client)

        XCTAssertEqual(report.otherServers.count, 1)
        XCTAssertFalse(try! XCTUnwrap(report.otherServers.first).couldInspect)
        XCTAssertEqual(report.otherServers.first?.summary, "not verified")
        XCTAssertTrue(client.unloaded.isEmpty, "no command may be sent to an unanswered address")
    }

    /// A server that answers and is holding nothing IS verified — the same distinction the target
    /// side draws between `.listed([])` and `.unsupported`.
    func testOtherServer_thatIsEmpty_isVerifiedClear() async {
        let client = RecordingLifecycleClient(
            resident: ["qwen3.6"],
            residentByURL: [LLMProvider.ollama.defaultBaseURL: []])

        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [otherServer()], client: client)

        XCTAssertTrue(try! XCTUnwrap(report.otherServers.first).couldInspect)
        XCTAssertEqual(report.otherServers.first?.summary, "already clear")
    }

    /// Self-eviction guard. Both providers pointed at one address is a misconfiguration, and
    /// treating it as two machines would unload the model the run is about to measure.
    ///
    /// RED: drop the same-address skip → the target is evicted by the "other servers" pass, and
    /// the run measures a cold load it never accounted for.
    func testOtherServerAtTheTargetsOwnAddress_isSkipped() async {
        let client = RecordingLifecycleClient(resident: ["qwen3.6"])

        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(provider: .lmStudio, model: "qwen3.6"),
            // Same address, other provider — and a trailing slash, so a raw string compare would
            // not catch it either.
            otherServers: [otherServer(.ollama, url: LLMProvider.lmStudio.defaultBaseURL + "/")],
            client: client)

        XCTAssertTrue(report.otherServers.isEmpty)
        XCTAssertTrue(client.unloaded.isEmpty)
        XCTAssertTrue(report.targetWasResident)
    }

    /// RED: drop the `visited` set → one server named twice is listed and cleared twice, and the
    /// provenance line reads as if the machine had two of it.
    func testDuplicateOtherServers_areClearedOnce() async {
        let client = RecordingLifecycleClient(
            resident: [],
            residentByURL: [LLMProvider.ollama.defaultBaseURL: ["llama3.1:8b"]])

        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(),
            otherServers: [otherServer(), otherServer(.ollama, url: LLMProvider.ollama.defaultBaseURL + "/")],
            client: client)

        XCTAssertEqual(report.otherServers.count, 1)
        XCTAssertEqual(client.unloaded, ["llama3.1:8b"])
    }

    /// RED: drop the blank-address guard → the preparer asks about "" , the client throws
    /// `invalidBaseURL`, and the row records "not verified" about a machine nobody named.
    func testBlankOtherServerAddress_isNotAskedAbout() async {
        let client = RecordingLifecycleClient(resident: [])

        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [otherServer(.ollama, url: "   ")], client: client)

        XCTAssertTrue(report.otherServers.isEmpty)
    }

    /// A refused eviction elsewhere is a caveat, not an abort — the same rule as the target's own.
    func testOtherServerUnloadFailure_isRecordedAndTheRunContinues() async {
        let client = RecordingLifecycleClient(
            resident: [],
            unloadFails: true,
            residentByURL: [LLMProvider.ollama.defaultBaseURL: ["stuck"]])

        let report = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [otherServer()], client: client)

        XCTAssertNotNil(report.otherServers.first?.failure)
        XCTAssertTrue(try! XCTUnwrap(report.otherServers.first?.failure).contains("stuck"))
        XCTAssertTrue(report.couldInspect, "the target's own preparation still happened")
    }

    /// The other servers are cleared BEFORE the target is loaded, so the load lands on a machine
    /// this pass has already emptied rather than beside a model about to be evicted.
    ///
    /// RED: move the loop after the target block → on LM Studio the target is loaded while the
    /// other provider still holds its model, which is the peak-memory moment the whole pass exists
    /// to avoid.
    func testOtherServersAreClearedBeforeTheTargetIsLoaded() async {
        let client = RecordingLifecycleClient(
            resident: [],
            residentByURL: [LLMProvider.ollama.defaultBaseURL: ["llama3.1:8b"]])

        _ = await BenchmarkResidencyPreparer.prepare(
            target: target(), otherServers: [otherServer()], client: client)

        XCTAssertEqual(client.callOrder, ["list", "unload:llama3.1:8b", "list", "load:qwen3.6"],
                       "\(client.callOrder)")
    }

    func testOtherServerSummary_distinguishesTheThreeOutcomes() {
        var report = BenchmarkResidencyPreparer.OtherServerReport(
            server: BenchmarkServer(provider: .ollama, baseURLString: "http://x:11434"))
        XCTAssertEqual(report.summary, "not verified")
        report.couldInspect = true
        XCTAssertEqual(report.summary, "already clear")
        report.unloadedModels = ["a"]
        XCTAssertEqual(report.summary, "unloaded 1 model")
        report.unloadedModels = ["a", "b"]
        XCTAssertEqual(report.summary, "unloaded 2 models")
    }
}

/// Records the lifecycle calls the preparer makes.
private final class RecordingLifecycleClient: LLMClient, @unchecked Sendable {
    private let resident: [String]
    private let listingFails: Bool
    private let unloadFails: Bool
    private let lock = NSLock()
    private var _unloaded: [String] = []
    private var _loaded: [String] = []
    /// Every provider the preparer named, in call order. The preparer has to forward the
    /// TARGET's provider — a constant here would compile and would route every Ollama run
    /// through the LM Studio client, which is the defect this parameter exists to end.
    private var _providers: [LLMProvider] = []

    var unloaded: [String] { lock.withLock { _unloaded } }
    var loaded: [String] { lock.withLock { _loaded } }
    var providers: [LLMProvider] { lock.withLock { _providers } }

    private let loadFails: Bool
    /// The server answers, but has no listing route — LM Studio without `/api/v0/models`.
    /// Distinct from `listingFails`, which is a transport error.
    private let listingUnsupported: Bool
    /// Residency per ADDRESS, for the multi-server pass. An address not listed here falls back to
    /// `resident`, which keeps every single-server test reading as it did.
    private let residentByURL: [String: [String]]
    /// Addresses where nothing is listening: the listing throws, as it does for a port with no
    /// server behind it. The common real case — the user runs one provider.
    private let unansweredURLs: Set<String>
    /// Every call in order, so a test can pin that other servers are cleared BEFORE the target is
    /// loaded. The three per-kind arrays cannot say that: they are filtered by kind, and order
    /// across kinds is exactly the fact in question.
    private var _callOrder: [String] = []

    var callOrder: [String] { lock.withLock { _callOrder } }

    init(resident: [String], listingFails: Bool = false, unloadFails: Bool = false,
         loadFails: Bool = false, listingUnsupported: Bool = false,
         residentByURL: [String: [String]] = [:], unansweredURLs: Set<String> = []) {
        self.resident = resident
        self.listingFails = listingFails
        self.unloadFails = unloadFails
        self.loadFails = loadFails
        self.listingUnsupported = listingUnsupported
        self.residentByURL = residentByURL.reduce(into: [:]) { $0[$1.key.normalizedBaseURL] = $1.value }
        self.unansweredURLs = Set(unansweredURLs.map(\.normalizedBaseURL))
    }

    func listLoadedInstances(
        provider: LLMProvider, baseURLString: String
    ) async throws -> LoadedInstanceListing {
        lock.withLock { _providers.append(provider); _callOrder.append("list") }
        if unansweredURLs.contains(baseURLString.normalizedBaseURL) {
            throw LLMClientError.missingResponse
        }
        if listingFails { throw LLMClientError.missingResponse }
        if listingUnsupported { return .unsupported }
        let names = residentByURL[baseURLString.normalizedBaseURL] ?? resident
        return .listed(names.map { LoadedModelInstance(modelName: $0, instanceID: $0) })
    }

    func unloadModel(
        provider: LLMProvider, instanceID: String, baseURLString _: String
    ) async throws {
        lock.withLock { _providers.append(provider) }
        if unloadFails { throw LLMClientError.providerError("busy") }
        lock.withLock { _unloaded.append(instanceID); _callOrder.append("unload:\(instanceID)") }
    }

    func loadModel(
        provider: LLMProvider, modelName: String, baseURLString _: String
    ) async throws -> String {
        lock.withLock { _providers.append(provider) }
        if loadFails { throw LLMClientError.providerError("out of memory") }
        lock.withLock { _loaded.append(modelName); _callOrder.append("load:\(modelName)") }
        return modelName
    }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}
