import XCTest

@testable import NanoTeams

/// `Cause.modelReloaded` was unreachable on LM Studio — the default provider.
///
/// The server reports `model_load_time_seconds` as exactly `0` on all 27 baseline rows, so the
/// threshold branch can never fire there; meanwhile that provider's residency is managed by THIS
/// APP, which unloads models on settings changes, team edits, task removal and every engine
/// transition to a non-running state. The most common real reload — a step parks on
/// `ask_supervisor`, the reconciler reclaims the model, the answer arrives and the app loads it
/// again — was therefore completely silent, and the user experienced only "the model got slow".
///
/// The fix gives the same cause a second evidence channel, selected by who owns residency.
@MainActor
final class LocalModelReloadSignalTests: XCTestCase {

    private var sut: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!
    private var ledger: PromptPrefixLedger!

    private let stepID = "engineer"
    private let taskID = 11
    private var config = LLMConfig(baseURLString: "http://127.0.0.1:1234", modelName: "m")

    override func setUp() {
        super.setUp()
        ledger = PromptPrefixLedger()
        sut = LLMExecutionService(repository: NTMSRepository(), prefixLedger: ledger)
        delegate = MockLLMExecutionDelegate()
        sut.attach(delegate: delegate)
        sut._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    override func tearDown() {
        sut = nil; delegate = nil; ledger = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func system(_ t: String) -> ChatMessage { ChatMessage(role: .system, content: t) }
    private func user(_ t: String) -> ChatMessage { ChatMessage(role: .user, content: t) }
    private var bulk: String { String(repeating: "word ", count: 4000) }

    private func record(_ messages: [ChatMessage]) async -> PromptPrefixLedger.Observation {
        await ledger.record(
            baseURL: config.baseURLString, model: config.modelName,
            owner: .step(taskID: taskID, stepID: stepID),
            messages: messages, toolSchemaText: "")
    }

    private func detect(
        _ observation: PromptPrefixLedger.Observation,
        serverPrefill: ServerPrefillReport? = nil,
        residency: ClientResidencyFacts? = nil
    ) async {
        await sut.reportPrefixCacheMissIfAny(
            stepID: stepID, taskID: taskID, runID: 0, config: config,
            observation: observation, serverPrefill: serverPrefill, clientResidency: residency)
    }

    /// An intact prefix on an established chain — the only state in which server or client
    /// residency signals are consulted at all.
    private func intactPrefix() async -> PromptPrefixLedger.Observation {
        _ = await record([system("s"), user(bulk)])
        return await record([system("s"), user(bulk), user("next")])
    }

    private var loadedByUs: ClientResidencyFacts {
        ClientResidencyFacts(appLoadedModelForThisRequest: true, appModelLoadMs: 4300)
    }

    // MARK: - The signal itself

    func testLMStudioLoadedTheModelForThisRequest_isReportedAsModelReloaded() async {
        let observation = await intactPrefix()
        // LM Studio's REAL warm value. Before the local channel this produced no verdict at all.
        await detect(
            observation, serverPrefill: ServerPrefillReport(modelLoadMs: 0),
            residency: loadedByUs)

        XCTAssertEqual(delegate.prefixCacheMisses.count, 1)
        XCTAssertEqual(delegate.prefixCacheMisses.first?.diagnosis.cause, .modelReloaded)
    }

    /// `.adopted` means the instance was already resident — the cache came with it.
    func testAdoptedInstance_isNotAReload() async {
        let observation = await intactPrefix()
        await detect(
            observation, serverPrefill: ServerPrefillReport(modelLoadMs: 0),
            residency: ClientResidencyFacts(appLoadedModelForThisRequest: false))

        XCTAssertTrue(delegate.prefixCacheMisses.isEmpty)
    }

    func testNoResidencyFactsAtAll_changesNothing() async {
        let observation = await intactPrefix()
        await detect(observation, serverPrefill: ServerPrefillReport(modelLoadMs: 0))
        XCTAssertTrue(
            delegate.prefixCacheMisses.isEmpty,
            "absence is never evidence — a provider that reports nothing produces no verdict")
    }

    // MARK: - Ordering and interaction with the other exemptions

    func testStructuralMissDominatesALocalReload() async {
        _ = await record([system("s"), user("a"), user(bulk)])
        let rewrite = await record([system("s"), user("REWRITTEN"), user(bulk)])
        await detect(rewrite, residency: loadedByUs)

        XCTAssertEqual(
            delegate.prefixCacheMisses.first?.diagnosis.cause,
            .conversationRewritten(atSegment: 1),
            "if we broke our own prefix that is the actionable cause, reload or not")
    }

    func testLocalReloadOnAFreshConversation_isNotReported() async {
        let first = await record([system("s"), user(bulk)])
        await detect(first, residency: loadedByUs)

        XCTAssertTrue(
            delegate.prefixCacheMisses.isEmpty,
            "a brand-new conversation has nothing to lose — the load is inherent")
    }

    func testBothChannelsPresent_reportsOneMissNotTwo() async {
        let observation = await intactPrefix()
        await detect(
            observation,
            serverPrefill: ServerPrefillReport(modelLoadMs: 2236.645542),
            residency: loadedByUs)

        XCTAssertEqual(
            delegate.prefixCacheMisses.count, 1,
            "the two channels answer the same question and share one slot in `resolve`")
        XCTAssertEqual(delegate.prefixCacheMisses.first?.diagnosis.cause, .modelReloaded)
    }

    /// The scenario the whole signal exists for: a step parks, the reconciler reclaims the model,
    /// the step resumes and the app loads it again. Nothing in the server's numbers shows it.
    func testUnloadWhileParked_thenResume_isNowObservable() async {
        _ = await record([system("s"), user(bulk)])
        // …park, reconcile unloads the model, the answer arrives, the step replays its transcript
        // and appends one turn. The prefix is intact; the cache behind it is gone.
        let resumed = await record([system("s"), user(bulk), user("Supervisor: proceed")])
        await detect(
            resumed, serverPrefill: ServerPrefillReport(modelLoadMs: 0), residency: loadedByUs)

        XCTAssertEqual(delegate.prefixCacheMisses.first?.diagnosis.cause, .modelReloaded)
    }

    // MARK: - keep-alive interaction (F5)

    func testKeepAliveZeroOnLMStudio_doesNotSuppressTheLocalSignal() async {
        config = LLMConfig(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m",
            keepAliveSeconds: 0)
        let observation = await intactPrefix()
        await detect(
            observation, serverPrefill: ServerPrefillReport(modelLoadMs: 0),
            residency: loadedByUs)

        XCTAssertEqual(
            delegate.prefixCacheMisses.first?.diagnosis.cause, .modelReloaded,
            "the exemption neuters a SERVER figure for a setting LM Studio never reads; it must "
                + "not reach across to what the app knows it did itself")
    }

    /// On Ollama the setting is real, and the exemption still applies to the server figure.
    func testKeepAliveZeroOnOllama_stillNeutersTheServerFigure() async {
        config = LLMConfig(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m",
            keepAliveSeconds: 0)
        let observation = await intactPrefix()
        await detect(observation, serverPrefill: ServerPrefillReport(modelLoadMs: 2236.645542))

        XCTAssertTrue(delegate.prefixCacheMisses.isEmpty)
    }

    // MARK: - The pure policy row

    func testResolve_locallyReloaded_sitsInTheSameSlotAsTheServerFigure() {
        let reused = PrefixCachePolicy.Verdict.reused(segments: 4)

        let local = PrefixCachePolicy.resolve(
            structural: reused, server: .init(modelLoadMs: 0), locallyReloaded: true,
            warmFloorNsPerToken: nil, warmFloorPromptTokens: nil, floorSampleCount: 0,
            suspect: nil, totalPromptTokens: 12_927, appendedTokens: 30)
        XCTAssertEqual(local.diagnosis?.cause, .modelReloaded)
        XCTAssertEqual(
            local.diagnosis?.discardedTokens, 12_927,
            "a reload costs the whole prompt, same as the server-reported channel")

        let none = PrefixCachePolicy.resolve(
            structural: reused, server: .init(modelLoadMs: 0), locallyReloaded: false,
            warmFloorNsPerToken: nil, warmFloorPromptTokens: nil, floorSampleCount: 0,
            suspect: nil, totalPromptTokens: 12_927, appendedTokens: 30)
        XCTAssertEqual(none, reused)
    }

    func testResolve_locallyReloadedDefaultsToFalse_soExistingCallersAreUnchanged() {
        XCTAssertEqual(
            PrefixCachePolicy.resolve(
                structural: .reused(segments: 2), server: .init(modelLoadMs: 0),
                warmFloorNsPerToken: nil, warmFloorPromptTokens: nil, floorSampleCount: 0,
                suspect: nil, totalPromptTokens: 5000, appendedTokens: 10),
            .reused(segments: 2))
    }
}
