import XCTest

@testable import NanoTeams

/// A stock Ollama install truncates an oversized prompt from the START and answers HTTP 200.
/// The head it drops is segment 0 — the system prompt and tool catalog the prefix cache keys on —
/// and the truncation point moves as the conversation grows, so the cache misses on every turn.
/// Meanwhile `modelContextLength` deliberately returns nil there rather than overstating the
/// window, so nothing warns before the send, and the ledger reports `.reused` on every turn
/// because it fingerprints what we SENT.
///
/// The way out is to MEASURE, and to measure something the estimator cannot poison. A first cut
/// compared the server's count against `estimateTokens` at a 75% gate; a live calibration
/// (`ornith:35b-q4_K_M`, 2026-07-26) killed it — the estimator is 2.2× high on Cyrillic and 2.6×
/// LOW on emoji, so no single fraction separates "truncated" from "Russian".
///
/// The signal is server-only instead: **the conversation grew but the server's own count did not.**
/// Measured with `num_ctx: 2048` — 1872 tokens reported 1872; doubling the prompt reported 1026;
/// doubling again reported 1026 again. Once it truncates, the count stops tracking what we send.
/// The nil-probe rule ("a failed probe must never manufacture a warning") stays intact.
@MainActor
final class ContextTruncationObservationTests: XCTestCase {

    private var sut: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!

    private let stepID = "engineer"
    private let taskID = 3
    private var config = LLMConfig(
        provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "llama3.1")

    override func setUp() async throws {
        try await super.setUp()
        sut = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        sut.attach(delegate: delegate)
        sut._testRegisterStepTask(stepID: stepID, taskID: taskID)
        sut._testSetPrefixCacheState(stepID: stepID, taskID: taskID)
    }

    override func tearDown() async throws {
        sut = nil; delegate = nil
        try await super.tearDown()
    }

    /// One request. The detector is a delta, so a test that wants a verdict has to drive at least
    /// two — the first only leaves a baseline.
    private func confirm(appended: Int, server: Int?) async {
        await sut.confirmContextTruncation(
            stepID: stepID, taskID: taskID, config: config,
            appendedTokens: appended, serverPromptTokens: server)
    }

    private var warning: String? { delegate.lastErrorMessages.last }

    private func didWarn() -> Bool {
        sut._testDidWarnContextOverflow(stepID: stepID, taskID: taskID) == true
    }

    // MARK: - The pure predicate

    func testShouldReportTruncation_firesWhenWeGrewAndTheServerDidNot() {
        XCTAssertEqual(
            ContextBudgetPolicy.shouldReportTruncation(
                appendedTokens: 3000, serverPromptTokens: 1026,
                previousServerPromptTokens: 1026),
            1026,
            "equal counts across a materially longer prompt is the clamp")
    }

    func testShouldReportTruncation_firesWhenTheServerCountEvenDropped() {
        // Measured: at num_ctx 4096 a doubling took the count from 3675 down to 2050.
        XCTAssertEqual(
            ContextBudgetPolicy.shouldReportTruncation(
                appendedTokens: 4000, serverPromptTokens: 2050,
                previousServerPromptTokens: 3675),
            2050)
    }

    func testShouldReportTruncation_staysQuietWhileTheServerKeepsUp() {
        XCTAssertNil(
            ContextBudgetPolicy.shouldReportTruncation(
                appendedTokens: 3000, serverPromptTokens: 9000,
                previousServerPromptTokens: 6000),
            "the count grew with the conversation — nothing is being dropped")
    }

    /// The whole reason this predicate ignores our own estimate. Every one of these ratios is a
    /// HEALTHY request measured on a live server with the window set wide enough that truncation
    /// was impossible; a fraction-of-estimate gate anywhere near 0.75 reports most of them.
    func testTheEstimatorsLanguageBiasCannotProduceAFalsePositive() {
        let measured: [(String, estimate: Int, server: Int)] = [
            ("ASCII English", 1482, 1154),
            ("Cyrillic", 2812, 1274),
            ("mixed RU/EN", 2224, 1273),
            ("CJK", 1126, 1152),
            ("Swift source", 1266, 1783),
            ("base64", 830, 1873),
            ("emoji-heavy", 621, 1602),
        ]
        for row in measured {
            // Healthy: the count tracks growth. Previous is deliberately SMALLER than current.
            XCTAssertNil(
                ContextBudgetPolicy.shouldReportTruncation(
                    appendedTokens: row.estimate, serverPromptTokens: row.server,
                    previousServerPromptTokens: max(1, row.server / 2)),
                "\(row.0): a healthy request must never be reported, whatever the estimator said")
        }
        XCTAssertLessThan(
            Double(measured[1].server) / Double(measured[1].estimate), 0.75,
            "anti-vacuity: Cyrillic really is below the fraction the first design used as a gate")
    }

    func testShouldReportTruncation_needsAMaterialAppend() {
        XCTAssertNil(
            ContextBudgetPolicy.shouldReportTruncation(
                appendedTokens: 40, serverPromptTokens: 1026,
                previousServerPromptTokens: 1026),
            "a tiny append tokenising to nothing is not evidence of a clamp")
    }

    func testShouldReportTruncation_needsBothCounts() {
        XCTAssertNil(
            ContextBudgetPolicy.shouldReportTruncation(
                appendedTokens: 3000, serverPromptTokens: nil,
                previousServerPromptTokens: 1026))
        XCTAssertNil(
            ContextBudgetPolicy.shouldReportTruncation(
                appendedTokens: 3000, serverPromptTokens: 1026,
                previousServerPromptTokens: nil),
            "the first request of a step has no baseline, so it can only leave one")
        XCTAssertNil(
            ContextBudgetPolicy.shouldReportTruncation(
                appendedTokens: 3000, serverPromptTokens: 0,
                previousServerPromptTokens: 1026),
            "zero is 'not reported', never 'it processed nothing'")
    }

    // MARK: - The wiring

    func testStockOllama_theCountStopsGrowing_isReported() async {
        await confirm(appended: 3000, server: 1026)   // baseline only
        await confirm(appended: 3000, server: 1026)   // grew, server didn't

        XCTAssertTrue(didWarn(), "the overflow latch must be set")
        XCTAssertTrue(warning?.contains("1026") ?? false, "the banner names what WAS processed")
        XCTAssertTrue(warning?.contains("llama3.1") ?? false)
        XCTAssertTrue(
            warning?.contains("OLLAMA_CONTEXT_LENGTH") ?? false,
            "the remedy must be the provider-specific one")
        XCTAssertFalse(
            warning?.contains("context window is") ?? false,
            "the reported count is about HALF the window — the banner must not claim otherwise")
    }

    func testAHealthyConversation_isNeverReported() async {
        await confirm(appended: 3000, server: 4000)
        await confirm(appended: 3000, server: 7100)
        await confirm(appended: 3000, server: 10_200)
        XCTAssertFalse(didWarn())
        XCTAssertNil(warning)
    }

    func testTheFirstRequestOnlyLeavesABaseline() async {
        await confirm(appended: 5000, server: 1026)
        XCTAssertFalse(didWarn(), "one sample cannot show a delta")
    }

    /// A request that says nothing must still move the baseline, or the next comparison is against
    /// a stale number.
    func testEveryRequestUpdatesTheBaseline_evenWhenItReportsNothing() async {
        await confirm(appended: 10, server: 4000)     // below the material append
        await confirm(appended: 3000, server: 3900)   // grew, server went DOWN vs 4000
        XCTAssertTrue(didWarn(), "the quiet request had to leave 4000 behind for this to fire")
    }

    /// The pre-send surface owns the case where the window IS known — it warns before the tokens
    /// are spent, which is strictly better than after.
    func testSuccessfulProbe_neverEntersTheTruncationPath() async {
        sut._testSeedProbedContextLength(
            baseURL: config.baseURLString, model: config.modelName, contextLength: 32_768)
        await confirm(appended: 3000, server: 1026)
        await confirm(appended: 3000, server: 1026)

        XCTAssertFalse(
            didWarn(),
            "a known window means the pre-send check already decided; this must stay quiet")
    }

    /// The count is NOT the window (measured at roughly half of it), so writing it into the probe
    /// memo would make every later pre-send verdict confidently wrong.
    func testTheObservedCountIsNotMemoizedAsAContextWindow() async {
        await confirm(appended: 3000, server: 1026)
        await confirm(appended: 3000, server: 1026)
        XCTAssertNil(
            sut._testProbedContextLength(
                baseURL: config.baseURLString, model: config.modelName),
            "a fabricated window is worse than an unknown one")
    }

    func testTheLatchFiresOncePerStep() async {
        await confirm(appended: 3000, server: 1026)
        await confirm(appended: 3000, server: 1026)
        await confirm(appended: 3000, server: 1026)

        XCTAssertEqual(
            delegate.lastErrorMessages.count, 1,
            "one banner per step, like the pre-send warning")
    }

    /// A step with no execution state is torn down; `?.` yields nil, which fails the
    /// `== false` comparison, so nothing probes or warns for it.
    func testTornDownStep_neverWarns() async {
        await sut.confirmContextTruncation(
            stepID: "never_registered", taskID: taskID, config: config,
            appendedTokens: 3000, serverPromptTokens: 1026)
        await sut.confirmContextTruncation(
            stepID: "never_registered", taskID: taskID, config: config,
            appendedTokens: 3000, serverPromptTokens: 1026)
        XCTAssertNil(warning)
    }

    /// Severity ordering: a prompt whose head is being dropped has no cache to reason about, so
    /// the truncation banner must win and the cache report must stand down (exemption 3).
    func testTruncationLatch_suppressesTheCacheBanner() async {
        let ledger = PromptPrefixLedger()
        let service = LLMExecutionService(repository: NTMSRepository(), prefixLedger: ledger)
        let spy = MockLLMExecutionDelegate()
        service.attach(delegate: spy)
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        service._testSetPrefixCacheState(stepID: stepID, taskID: taskID)

        let bulk = String(repeating: "word ", count: 4000)
        _ = await ledger.record(
            baseURL: config.baseURLString, model: config.modelName,
            owner: .step(taskID: taskID, stepID: stepID),
            messages: [ChatMessage(role: .system, content: "s"),
                       ChatMessage(role: .user, content: bulk)],
            toolSchemaText: "")
        let rewritten = await ledger.record(
            baseURL: config.baseURLString, model: config.modelName,
            owner: .step(taskID: taskID, stepID: stepID),
            messages: [ChatMessage(role: .system, content: "s"),
                       ChatMessage(role: .user, content: "REWRITTEN"),
                       ChatMessage(role: .user, content: bulk)],
            toolSchemaText: "")

        for _ in 0..<2 {
            await service.confirmContextTruncation(
                stepID: stepID, taskID: taskID, config: config,
                appendedTokens: 3000, serverPromptTokens: 1026)
        }
        await service.reportPrefixCacheMissIfAny(
            stepID: stepID, taskID: taskID, runID: 0, config: config,
            observation: rewritten, serverPrefill: nil)

        XCTAssertTrue(
            spy.prefixCacheMisses.isEmpty,
            "the overflow banner is strictly more severe and fires first")
    }
}
