import XCTest
@testable import NanoTeams

/// Every exemption in `reportPrefixCacheMissIfAny`, individually.
///
/// These matter more than the happy path: the banner is always on, so a DELIBERATE reset that is
/// not exempted becomes a permanent false positive, and a warning nobody believes is worse than
/// no warning at all.
@MainActor
final class PrefixCacheWiringTests: XCTestCase {

    var sut: LLMExecutionService!
    var delegate: MockLLMExecutionDelegate!
    var ledger: PromptPrefixLedger!
    var repository: NTMSRepository!

    private let stepID = "engineer"
    private let taskID = 7
    private var config = LLMConfig(baseURLString: "http://127.0.0.1:1234", modelName: "m")

    override func setUp() {
        super.setUp()
        repository = NTMSRepository()
        ledger = PromptPrefixLedger()
        sut = LLMExecutionService(repository: repository, prefixLedger: ledger)
        delegate = MockLLMExecutionDelegate()
        sut.attach(delegate: delegate)
        sut._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    override func tearDown() {
        sut = nil
        delegate = nil
        ledger = nil
        repository = nil
        super.tearDown()
    }

    // MARK: - Ledger ownership

    /// The seam that made every suite share one process-global ledger (CLAUDE.md Swift Style
    /// #49). Behavioural complement to `PrefixCacheLedgerOwnershipPinTests`: that one proves the
    /// global is unrepresentable, this one proves the default actually yields a private ledger.
    ///
    /// The owner key is deliberately IDENTICAL across the two services — same base, model, task
    /// and step. That collision is exactly what the global leak produced (test task ids are small
    /// ints and step ids are role names, so they repeat across suites), so a shared ledger turns
    /// service B's genuinely-first request into a reported miss.
    func testTwoServices_doNotShareLedgerState() async {
        let a = LLMExecutionService(repository: NTMSRepository())
        let b = LLMExecutionService(repository: NTMSRepository())
        XCTAssertFalse(
            a.prefixLedger === b.prefixLedger,
            "each service must own its ledger — a shared one lets one suite's chain become "
                + "another suite's miss")

        let owner = LLMCallOwner.step(taskID: taskID, stepID: stepID)
        _ = await a.prefixLedger.record(
            baseURL: config.baseURLString, model: config.modelName,
            owner: owner, messages: [system("sys"), user(bulk)], toolSchemaText: "")

        let observation = await b.prefixLedger.record(
            baseURL: config.baseURLString, model: config.modelName,
            owner: owner, messages: [system("sys"), user("different")], toolSchemaText: "")

        guard case .firstRequestForOwner = observation.structural else {
            return XCTFail("b saw a's chain — the ledger is shared. Got \(observation.structural)")
        }
        XCTAssertNil(observation.suspect, "b must not see a's activity either")
    }

    // MARK: - Helpers

    private func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text) }
    private func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text) }

    /// Long enough that the discarded tail clears `materialTokenThreshold`.
    private var bulk: String { String(repeating: "word ", count: 4000) }

    private func record(_ messages: [ChatMessage]) async -> PromptPrefixLedger.Observation {
        await ledger.record(
            baseURL: config.baseURLString, model: config.modelName,
            owner: .step(taskID: taskID, stepID: stepID),
            messages: messages, toolSchemaText: "")
    }

    private func detect(
        _ observation: PromptPrefixLedger.Observation,
        serverPrefill: ServerPrefillReport? = nil
    ) async {
        await sut.reportPrefixCacheMissIfAny(
            stepID: stepID, taskID: taskID, runID: 0, config: config,
            observation: observation, serverPrefill: serverPrefill)
    }

    /// Drives a real rewrite: first request establishes the chain, second rewrites its middle.
    private func observeRealRewrite() async -> PromptPrefixLedger.Observation {
        _ = await record([system("s"), user("a"), user(bulk)])
        return await record([system("s"), user("REWRITTEN"), user(bulk)])
    }

    /// `promptTokens` rides the floor because the rate is ~`overhead / depth` on a hit; every
    /// caller here measures at the same depth it later reports, unless it says otherwise.
    private func seedWarmFloor(
        nsPerToken: Double, promptTokens: Int = 1000, samples: Int = 3
    ) async {
        for _ in 0..<samples {
            await ledger.noteServerPrefill(
                baseURL: config.baseURLString, model: config.modelName,
                nsPerToken: nsPerToken, promptTokens: promptTokens)
        }
    }

    /// What `startStepExecution` does when `ConversationReplay.resume(from:)` is nil — a new
    /// run, or `restartRole`'s deliberate re-synthesis.
    private func startFreshConversation() async {
        sut._testSetPrefixCacheState(stepID: stepID, taskID: taskID, replaySource: nil)
        await sut.forgetPrefixChainForFreshConversation(stepID: stepID, taskID: taskID)
    }

    // MARK: - The happy path fires

    func testMidArrayRewrite_isReported() async {
        let observation = await observeRealRewrite()
        await detect(observation)

        XCTAssertEqual(delegate.prefixCacheMisses.count, 1)
        XCTAssertEqual(delegate.prefixCacheMisses.first.flatMap(\.taskID), taskID)
        XCTAssertEqual(
            delegate.prefixCacheMisses.first?.owner, .step(taskID: taskID, stepID: stepID),
            "the reported owner is the SAME value the ledger keyed by — not a string that "
                + "happens to equal its displayName")
        XCTAssertEqual(
            delegate.prefixCacheMisses.first?.diagnosis.cause,
            .conversationRewritten(atSegment: 1))
    }

    func testAppendOnly_isNotReported() async {
        _ = await record([system("s"), user("a")])
        let observation = await record([system("s"), user("a"), user(bulk)])
        await detect(observation)
        XCTAssertTrue(delegate.prefixCacheMisses.isEmpty, "an append is exactly what should happen")
    }

    // MARK: - Exemption: a torn-down step

    func testTornDownStep_neverReports() async {
        let observation = await observeRealRewrite()
        sut.executionStates.removeAll()
        await detect(observation)
        XCTAssertTrue(delegate.prefixCacheMisses.isEmpty)
    }

    // MARK: - Exemption: the planning-phase boundary

    func testPlanningBoundary_isNotReported_andTheFlagIsConsumed() async {
        let observation = await observeRealRewrite()
        sut._testSetPrefixCacheState(
            stepID: stepID, taskID: taskID, expectedPrefixResetPending: true)

        await detect(observation)
        XCTAssertTrue(
            delegate.prefixCacheMisses.isEmpty,
            "the boundary slices the conversation on purpose")
        XCTAssertEqual(
            sut._testExpectedPrefixResetPending(stepID: stepID, taskID: taskID), false,
            "one-shot: the next real miss must still be reported")
    }

    func testAfterTheBoundaryFlagIsConsumed_thenextMissIsReported() async {
        sut._testSetPrefixCacheState(
            stepID: stepID, taskID: taskID, expectedPrefixResetPending: true)
        await detect(await observeRealRewrite())
        XCTAssertTrue(delegate.prefixCacheMisses.isEmpty)

        _ = await record([system("s"), user("x"), user(bulk)])
        await detect(await record([system("s"), user("CHANGED"), user(bulk)]))
        XCTAssertEqual(delegate.prefixCacheMisses.count, 1)
    }

    // MARK: - Exemption: the single-use image strip

    func testImageStrip_isNotReported() async {
        let observation = await observeRealRewrite()
        sut._testSetPrefixCacheState(
            stepID: stepID, taskID: taskID, lastRequestCarriedImages: true)
        await detect(observation)
        XCTAssertTrue(
            delegate.prefixCacheMisses.isEmpty,
            "images are nilled AFTER sending, so the next request legitimately diverges")
    }

    // MARK: - Exemption: do not clobber the overflow banner

    func testContextOverflowAlreadyWarned_suppressesTheCacheBanner() async {
        let observation = await observeRealRewrite()
        sut._testSetPrefixCacheState(
            stepID: stepID, taskID: taskID, didWarnContextOverflow: true)
        await detect(observation)
        XCTAssertTrue(
            delegate.prefixCacheMisses.isEmpty,
            "overflow means the model may never have received its instructions — strictly worse")
    }

    // MARK: - Exemption: materiality

    func testSmallDiscard_isNotReported() async {
        _ = await record([system("s"), user("a"), user("tiny")])
        let observation = await record([system("s"), user("b"), user("tiny")])
        await detect(observation)
        XCTAssertTrue(
            delegate.prefixCacheMisses.isEmpty,
            "under ~1s of re-prefill a banner is noise")
    }

    // MARK: - First request vs a degraded replay

    func testFreshStepsFirstRequest_isNotReported() async {
        let observation = await record([system("s"), user(bulk)])
        await detect(observation)
        XCTAssertTrue(
            delegate.prefixCacheMisses.isEmpty,
            "a new conversation has to be prefilled once; that is inherent")
    }

    func testDegradedReplay_ISReported_eventhoughItIsAlsoAFirstRequest() async {
        sut._testSetPrefixCacheState(
            stepID: stepID, taskID: taskID, replaySource: .legacyConversation)
        let observation = await record([system("s"), user(bulk)])
        await detect(observation)

        XCTAssertEqual(
            delegate.prefixCacheMisses.count, 1,
            "a rebuilt conversation is a DOCUMENTED guaranteed miss — exempting all first "
                + "requests would hide the most valuable case")
        XCTAssertEqual(delegate.prefixCacheMisses.first?.diagnosis.cause, .degradedReplay)
    }

    func testFaithfulReplay_isNotReported() async {
        sut._testSetPrefixCacheState(
            stepID: stepID, taskID: taskID, replaySource: .wireTranscript)
        await detect(await record([system("s"), user(bulk)]))
        XCTAssertTrue(delegate.prefixCacheMisses.isEmpty)
    }

    // MARK: - Server-reported causes

    func testModelReload_onAnOtherwiseIntactPrefix_isReported() async {
        _ = await record([system("s"), user(bulk)])
        let observation = await record([system("s"), user(bulk), user("next")])
        await detect(observation, serverPrefill: ServerPrefillReport(modelLoadMs: 2236.645542))

        XCTAssertEqual(delegate.prefixCacheMisses.first?.diagnosis.cause, .modelReloaded)
    }

    func testModelReload_withKeepAliveZero_onOllama_isNotReported() async {
        config = LLMConfig(
            provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m",
            keepAliveSeconds: 0)
        _ = await record([system("s"), user(bulk)])
        let observation = await record([system("s"), user(bulk), user("next")])
        await detect(observation, serverPrefill: ServerPrefillReport(modelLoadMs: 2236.645542))

        XCTAssertTrue(
            delegate.prefixCacheMisses.isEmpty,
            "the user configured immediate unload; a reload is what they asked for")
    }

    /// `keepAliveSeconds` is written onto every config regardless of provider, but only Ollama
    /// reads it off the wire. Applying the exemption on LM Studio blinds the reload signal for a
    /// setting that provider never saw — and LM Studio's own `model_load_time_seconds` is 0 on
    /// every warm row, so there is nothing left to detect a reload with.
    func testModelReload_withKeepAliveZero_onLMStudio_isStillReported() async {
        config = LLMConfig(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m",
            keepAliveSeconds: 0)
        _ = await record([system("s"), user(bulk)])
        let observation = await record([system("s"), user(bulk), user("next")])
        await detect(observation, serverPrefill: ServerPrefillReport(modelLoadMs: 2236.645542))

        XCTAssertEqual(
            delegate.prefixCacheMisses.first?.diagnosis.cause, .modelReloaded,
            "this app manages LM Studio residency itself — an Ollama keep-alive setting must "
                + "not suppress the evidence")
    }

    func testModelReload_onAFreshConversation_isNotReported() async {
        let observation = await record([system("s"), user(bulk)])
        await detect(observation, serverPrefill: ServerPrefillReport(modelLoadMs: 2236.645542))
        XCTAssertTrue(
            delegate.prefixCacheMisses.isEmpty,
            "a brand new conversation has no cached prefix to lose")
    }

    func testSlowPrefillOnAnIntactPrefix_needsAnEstablishedWarmFloor() async {
        _ = await record([system("s"), user(bulk)])
        // Only ONE sample: not a floor, just the first measurement — and a first measurement is
        // usually cold.
        await seedWarmFloor(nsPerToken: 27, samples: 1)

        let observation = await record([system("s"), user(bulk), user("next")])
        await detect(observation, serverPrefill: ServerPrefillReport(
            prefillNs: 450_000_000, promptTokens: 1000))
        XCTAssertTrue(delegate.prefixCacheMisses.isEmpty)
    }

    func testSlowPrefillOnAnIntactPrefix_isReportedOnceTheFloorIsEstablished() async {
        _ = await record([system("s"), user(bulk)])
        await seedWarmFloor(nsPerToken: 27_000)
        // 450 µs/token against a 27 µs/token floor — the measured cold-vs-warm gap.
        let observation = await record([system("s"), user(bulk), user("next")])
        await detect(observation, serverPrefill: ServerPrefillReport(
            prefillNs: 450_000_000, promptTokens: 1000))

        guard case .serverDroppedCache = delegate.prefixCacheMisses.first?.diagnosis.cause else {
            return XCTFail("expected serverDroppedCache, got \(delegate.prefixCacheMisses)")
        }
    }

    func testWarmPrefill_isNotReported() async {
        _ = await record([system("s"), user(bulk)])
        await seedWarmFloor(nsPerToken: 27_000)
        let observation = await record([system("s"), user(bulk), user("next")])
        await detect(observation, serverPrefill: ServerPrefillReport(
            prefillNs: 30_000_000, promptTokens: 1000))
        XCTAssertTrue(delegate.prefixCacheMisses.isEmpty)
    }

    /// `prompt_eval_duration / prompt_eval_count` on a HIT is ≈ `overhead / depth`, so a
    /// shallow request routinely lands many times above a floor sampled deep — on
    /// `bench_baseline`, 9 of 20 warm rows clear a 4× gate that way. Comparing them is comparing
    /// two different amortizations, not warm against cold.
    func testSlowPrefillAtAShallowerDepthThanTheFloor_isNotReported() async {
        _ = await record([system("s"), user(bulk)])
        await seedWarmFloor(nsPerToken: 5_776, promptTokens: 12_960)

        let observation = await record([system("s"), user(bulk), user("next")])
        // bench `cont` K=1000 sample 6: 185.155083 ms / 902 tok — warm, yet 35.5× that floor.
        await detect(observation, serverPrefill: ServerPrefillReport(
            prefillNs: 185_155_083, promptTokens: 902))
        XCTAssertTrue(
            delegate.prefixCacheMisses.isEmpty,
            "a 902-token request cannot be judged against a floor measured at 12960")
    }

    /// End-to-end shape of the first false positive this branch produced in production: a
    /// Software Engineer appended a `read_file` result, so the server honestly prefilled
    /// thousands of new tokens on a perfectly reused prefix.
    func testSlowPrefillAfterALargeToolResult_isNotReported() async {
        _ = await record([system("s"), user("brief")])
        await seedWarmFloor(nsPerToken: 5_776, promptTokens: 12_960)

        // The appended turn IS the file — `bulk` is ~4000 words.
        let observation = await record([system("s"), user("brief"), user(bulk)])
        XCTAssertGreaterThan(
            observation.appendedTokens,
            PrefixCachePolicy.maxAppendedTokensForRateComparison,
            "precondition: this tail is big enough to make the rate uninterpretable")

        await detect(observation, serverPrefill: ServerPrefillReport(
            modelLoadMs: 22.247709, prefillNs: 3_000_000_000, promptTokens: 12_960))

        XCTAssertTrue(
            delegate.prefixCacheMisses.isEmpty,
            "the server re-processed the tokens we just handed it — that is a HIT doing its job")
    }

    func testAppendedTokens_areZeroOnAFirstRequestAndOnAMiss() async {
        let first = await record([system("s"), user(bulk)])
        XCTAssertEqual(first.appendedTokens, 0, "nothing was cached, so nothing was appended TO")

        let rewrite = await record([system("s"), user("REWRITTEN"), user(bulk)])
        XCTAssertNotNil(rewrite.structural.diagnosis, "precondition: this is a miss")
        XCTAssertEqual(
            rewrite.appendedTokens, 0,
            "on a miss the whole discarded prefix is the cost — `discardedTokens` carries it")
    }

    // MARK: - Ollama's per-request `load_duration` is not a reload

    /// The shape straight out of a live `network_log.json`: Ollama reports `load_duration` on
    /// EVERY request, resident model included, so `> 0` bannered on every warm turn.
    func testWarmOllamaTurn_wholeReport_isNotReported() async {
        _ = await record([system("s"), user(bulk)])
        await seedWarmFloor(nsPerToken: 5_776, promptTokens: 12_960)

        let observation = await record([system("s"), user(bulk), user("next")])
        await detect(observation, serverPrefill: ServerPrefillReport(
            modelLoadMs: 22.247709, prefillNs: 74_861_541, promptTokens: 12_960))

        XCTAssertTrue(
            delegate.prefixCacheMisses.isEmpty,
            "22 ms is Ollama's per-request bookkeeping — the model never left memory")
    }

    /// End-to-end proof that the branch below the load check was unreachable: same warm
    /// `modelLoadMs` as above, but a genuinely cold prefill rate.
    func testWarmLoadWithAColdPrefill_reportsServerDroppedCache_notModelReloaded() async {
        _ = await record([system("s"), user(bulk)])
        await seedWarmFloor(nsPerToken: 5_776, promptTokens: 12_960)

        let observation = await record([system("s"), user(bulk), user("next")])
        // bench cold K=16000: 6481.31675 ms / 12927 tok.
        await detect(observation, serverPrefill: ServerPrefillReport(
            modelLoadMs: 22.247709, prefillNs: 6_481_316_750, promptTokens: 12_927))

        XCTAssertEqual(
            delegate.prefixCacheMisses.first?.diagnosis.cause.causeClass, .serverDroppedCache,
            "prefix intact, model resident, server still re-prefilled")
    }

    // MARK: - A new run is a NEW conversation, not a rewrite of the old one

    /// `StepExecution.id` is the ROLE id, so the ledger's owner key survives every run — but the
    /// conversation does not. Pre-fix this returned `.reused(segments: 2)`: `compare` bounds at
    /// `min(previous.count, current.count)`, so a brand-new short chain is a strict PREFIX of the
    /// previous run's long one and a genuinely cold prefill was judged a hit.
    func testSecondRunOfTheSameStep_isNotJudgedAgainstTheFirstRunsChain() async {
        _ = await record([system("s"), user("goal"), user(bulk), user(bulk)])

        await startFreshConversation()

        let observation = await record([system("s"), user("goal")])
        XCTAssertEqual(observation.structural, .firstRequestForOwner)
    }

    /// The user-visible symptom: an Autovisor pass wakes every minute on a new run, so the
    /// banner latch re-arms each time.
    func testFreshRunAfterAModelUnload_isNotBlamedOnTheServer() async {
        _ = await record([system("s"), user("goal"), user(bulk)])
        await startFreshConversation()

        let observation = await record([system("s"), user("goal"), user(bulk)])
        await detect(observation, serverPrefill: ServerPrefillReport(modelLoadMs: 2236.645542))

        XCTAssertTrue(
            delegate.prefixCacheMisses.isEmpty,
            "server signals are consulted only on `.reused`; a fresh conversation has nothing "
                + "to lose, so even a real reload there is inherent")
    }

    /// The Autovisor rewrites `## Current Memory` into its own system prompt between passes, so
    /// segment 0 legitimately moves — that is a new conversation, not a rewritten one.
    func testFreshRunWithARewrittenSystemPrompt_isNotReported() async {
        _ = await record([system("sys + memory v1"), user(bulk)])
        await startFreshConversation()

        let observation = await record([system("sys + memory v2"), user(bulk)])
        await detect(observation)

        XCTAssertTrue(delegate.prefixCacheMisses.isEmpty)
    }

    /// The fence on the other side: an append-only re-entry MUST keep its chain. Forgetting here
    /// would silence every server-reported cause across a long human pause — the exact case
    /// `keep_alive` exists for.
    func testResumedStep_keepsItsChain() async {
        _ = await record([system("s"), user("goal"), user(bulk)])
        sut._testSetPrefixCacheState(
            stepID: stepID, taskID: taskID, replaySource: .wireTranscript)
        await sut.forgetPrefixChainForFreshConversation(stepID: stepID, taskID: taskID)

        // 3 segments: one for the merged system prompt, one per non-system message.
        let observation = await record([system("s"), user("goal"), user(bulk), user("answer")])
        XCTAssertEqual(observation.structural, .reused(segments: 3))
    }

    /// A `.legacyConversation` re-entry keeps its chain, and that is deliberate. It only ever
    /// happens WITHIN a run, after requests that already recorded one, so the rebuilt
    /// conversation genuinely diverges from what was sent — a real miss the detector should name
    /// by where it diverged. Dropping the chain here would relabel it as an inherent first
    /// request and lose the report entirely.
    func testLegacyReplay_keepsItsChainSoTheDivergenceIsStillReported() async {
        _ = await record([system("s"), user("goal"), user(bulk)])
        sut._testSetPrefixCacheState(
            stepID: stepID, taskID: taskID, replaySource: .legacyConversation)
        await sut.forgetPrefixChainForFreshConversation(stepID: stepID, taskID: taskID)

        let observation = await record([system("s"), user("REBUILT"), user(bulk)])
        XCTAssertNotNil(
            observation.structural.diagnosis,
            "a rebuilt conversation is not byte-identical to what was sent — that IS the miss")
    }

    /// Idempotent: the seam runs once per step start, but a retry or a re-entry must not need to
    /// care whether it already ran.
    func testForgettingTwice_isTheSameAsForgettingOnce() async {
        _ = await record([system("s"), user("goal"), user(bulk)])
        await startFreshConversation()
        await startFreshConversation()

        let observation = await record([system("s"), user("goal")])
        XCTAssertEqual(observation.structural, .firstRequestForOwner)
    }

    /// The drop is scoped to ONE step. A sibling role running in parallel on the same team
    /// (`TeamEngine` starts ready roles concurrently) must keep its own chain.
    func testAFreshConversation_doesNotDropASiblingRolesChain() async {
        let sibling = LLMCallOwner.step(taskID: taskID, stepID: "reviewer")
        _ = await record([system("s"), user("goal"), user(bulk)])
        _ = await ledger.record(
            baseURL: config.baseURLString, model: config.modelName,
            owner: sibling, messages: [system("s"), user("review")], toolSchemaText: "")

        await startFreshConversation()

        let siblingObservation = await ledger.record(
            baseURL: config.baseURLString, model: config.modelName,
            owner: sibling, messages: [system("s"), user("review"), user("more")],
            toolSchemaText: "")
        XCTAssertEqual(
            siblingObservation.structural, .reused(segments: 2),
            "one role restarting its conversation says nothing about another role's")
    }

    func testTornDownStep_doesNotForget() async {
        _ = await record([system("s"), user("goal"), user(bulk)])
        sut.executionStates.removeAll()
        await sut.forgetPrefixChainForFreshConversation(stepID: stepID, taskID: taskID)

        let observation = await record([system("s"), user("goal"), user(bulk)])
        XCTAssertEqual(
            observation.structural, .reused(segments: 3),
            "a torn-down step is not a fresh conversation — the same write barrier every other "
                + "prefix-cache seam uses")
    }

    // MARK: - Interleaving callers become suspects, never victims

    func testAJudgeInterleaving_isRecordedAsASuspect() async {
        _ = await record([system("s"), user(bulk)])
        await sut.noteInterleavingCall(label: "bash judge", config: config)

        let observation = await record([system("s"), user(bulk), user("next")])
        XCTAssertEqual(
            observation.suspect, LLMCallOwner.oneShot(label: "bash judge").key,
            "named as a lead for serverDroppedCache — never as a verdict on its own")
        XCTAssertEqual(
            observation.structural, .reused(segments: 2),
            "the judge does NOT make our own append look like a miss")
    }
}
