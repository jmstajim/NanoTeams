import XCTest
@testable import NanoTeams

final class PrefixCachePolicyTests: XCTestCase {

    // MARK: - compare

    func testCompare_noPrevious_isFirstRequestForOwner() {
        XCTAssertEqual(
            PrefixCachePolicy.compare(previous: nil, current: [1, 2], discardedTokens: 9999),
            .firstRequestForOwner)
        XCTAssertEqual(
            PrefixCachePolicy.compare(previous: [], current: [1, 2], discardedTokens: 9999),
            .firstRequestForOwner,
            "an empty chain is no chain — never manufacture a miss out of it")
    }

    func testCompare_appendOnly_isReuse() {
        let verdict = PrefixCachePolicy.compare(
            previous: [1, 2], current: [1, 2, 3], discardedTokens: 0)
        XCTAssertEqual(verdict, .reused(segments: 2))
        XCTAssertNil(verdict.diagnosis)
    }

    func testCompare_identical_isReuse() {
        XCTAssertEqual(
            PrefixCachePolicy.compare(previous: [1, 2], current: [1, 2], discardedTokens: 0),
            .reused(segments: 2))
    }

    func testCompare_midArrayRewrite_reportsTheIndex() {
        let verdict = PrefixCachePolicy.compare(
            previous: [1, 2, 3, 4], current: [1, 2, 99, 4], discardedTokens: 5000)
        guard let diagnosis = verdict.diagnosis else { return XCTFail("expected a miss") }
        XCTAssertEqual(diagnosis.cause, .conversationRewritten(atSegment: 2))
        XCTAssertEqual(diagnosis.commonSegments, 2)
        XCTAssertEqual(diagnosis.previousSegments, 4)
        XCTAssertEqual(diagnosis.discardedTokens, 5000)
    }

    func testCompare_segmentZeroDiffers_isSystemPromptChanged() {
        let verdict = PrefixCachePolicy.compare(
            previous: [1, 2], current: [99, 2], discardedTokens: 13000)
        XCTAssertEqual(verdict.diagnosis?.cause, .systemPromptChanged)
        XCTAssertEqual(verdict.diagnosis?.commonSegments, 0)
    }

    func testCompare_truncationWithIntactHead_isReuseNotAMiss() {
        // The planning-phase boundary slices the tail off but keeps the head byte-identical.
        // The surviving head IS reused; whether to report the dropped tail is the caller's
        // exemption decision, not this function's.
        XCTAssertEqual(
            PrefixCachePolicy.compare(previous: [1, 2, 3, 4], current: [1, 2], discardedTokens: 8000),
            .reused(segments: 2))
    }

    // MARK: - resolve: structural vs server

    /// Every literal below is traceable to `bench_baseline/results.jsonl`, so the truth table is
    /// pinned against measurement rather than against invention.
    ///
    /// Ollama, one genuine cold load: `load_ms 2236.645542`, `6481.31675 ms / 12927 tok`.
    /// Ollama, every other row: `load_ms` 20.565666…25.062167 — never 0.
    /// Warm floor on that baseline: `74.861541 ms / 12960 tok` = 5776 ns/token.
    private enum Bench {
        static let coldLoadMs = 2236.645542
        static let warmLoadMs = 22.247709
        static let warmLoadCeilingMs = 25.062167
        /// Highest warm figure observed in a live run, above the bench ceiling.
        static let liveWarmLoadMs = 30.5
        static let warmFloorNsPerToken = 5776.0
        static let warmFloorPromptTokens = 12960
        static let coldPrefillNsPerToken = 501_378.0
        static let deepWarmPrefillNsPerToken = 9337.0
        /// `cont` K=1000 sample 6: 185.155083 ms / 902 tok. Warm, but 35.5× the deep floor —
        /// `prompt_eval_duration / prompt_eval_count` is ≈ `overhead / depth` on a hit.
        static let shallowWarmPrefillNsPerToken = 205_271.0
        static let shallowPromptTokens = 902
    }

    private func resolve(
        _ structural: PrefixCachePolicy.Verdict,
        server: PrefixCachePolicy.ServerSignals = .init(),
        floor: Double? = nil,
        floorPromptTokens: Int? = Bench.warmFloorPromptTokens,
        samples: Int = 0,
        suspect: String? = nil,
        tokens: Int = 12_927,
        appended: Int = 30
    ) -> PrefixCachePolicy.Verdict {
        PrefixCachePolicy.resolve(
            structural: structural, server: server, warmFloorNsPerToken: floor,
            warmFloorPromptTokens: floorPromptTokens, floorSampleCount: samples,
            suspect: suspect, totalPromptTokens: tokens, appendedTokens: appended)
    }

    /// If we rewrote the prefix ourselves that is both the true cause and the actionable one.
    /// Blaming the server would send the reader looking in the wrong place — and would also
    /// overwrite the honest per-segment cost with the whole-request one.
    func testResolve_structuralMissDominatesEveryServerSignal() {
        let structural = PrefixCachePolicy.Verdict.missed(.init(
            cause: .conversationRewritten(atSegment: 2),
            commonSegments: 2, previousSegments: 9, discardedTokens: 8000))

        let verdict = resolve(
            structural,
            server: .init(
                modelLoadMs: Bench.coldLoadMs,
                prefillNsPerToken: Bench.coldPrefillNsPerToken),
            floor: Bench.warmFloorNsPerToken, samples: 10)

        XCTAssertEqual(verdict, structural, "the structural verdict must survive intact")
    }

    func testResolve_firstRequestForOwner_neverConsultsTheServer() {
        XCTAssertEqual(
            resolve(
                .firstRequestForOwner,
                server: .init(
                    modelLoadMs: Bench.coldLoadMs,
                    prefillNsPerToken: Bench.coldPrefillNsPerToken),
                floor: Bench.warmFloorNsPerToken, samples: 10),
            .firstRequestForOwner,
            "a brand new conversation has nothing to lose, so a load there is inherent")
    }

    /// Ollama reports `load_duration` on EVERY request, resident model included. `> 0` therefore
    /// fired on every warm turn — and because this branch returns first, it also made the
    /// calibrated branch below it unreachable.
    func testResolve_warmOllamaModelLoad_isNotAReload() {
        for load in [Bench.warmLoadMs, Bench.warmLoadCeilingMs, Bench.liveWarmLoadMs] {
            let verdict = resolve(.reused(segments: 12), server: .init(modelLoadMs: load))
            XCTAssertEqual(
                verdict, .reused(segments: 12),
                "\(load) ms is Ollama's per-request bookkeeping, not a model load")
            XCTAssertNil(verdict.diagnosis)
        }
    }

    func testResolve_coldModelLoad_isStillAReload() {
        let verdict = resolve(
            .reused(segments: 12), server: .init(modelLoadMs: Bench.coldLoadMs), tokens: 12_927)

        guard let diagnosis = verdict.diagnosis else { return XCTFail("expected a miss") }
        XCTAssertEqual(diagnosis.cause, .modelReloaded)
        XCTAssertEqual(diagnosis.commonSegments, 0, "a cold cache reuses nothing")
        XCTAssertEqual(diagnosis.previousSegments, 12)
        XCTAssertEqual(diagnosis.discardedTokens, 12_927, "the whole prompt re-prefills")
    }

    /// The threshold is a measurement, not a taste. Lowering it toward the warm band re-arms the
    /// permanent false positive; raising it past the measured cold load disables the signal.
    func testMinimumLoadMsForReload_isBracketedByTheMeasurement() {
        XCTAssertGreaterThan(
            PrefixCachePolicy.minimumLoadMsForReload, Bench.liveWarmLoadMs,
            "must clear every warm figure ever observed")
        XCTAssertLessThan(
            PrefixCachePolicy.minimumLoadMsForReload, Bench.coldLoadMs,
            "must still catch the measured cold load")

        // Pins the operator: exactly-at does NOT fire, one ULP above does.
        XCTAssertNil(
            resolve(
                .reused(segments: 3),
                server: .init(modelLoadMs: PrefixCachePolicy.minimumLoadMsForReload)
            ).diagnosis)
        XCTAssertEqual(
            resolve(
                .reused(segments: 3),
                server: .init(modelLoadMs: PrefixCachePolicy.minimumLoadMsForReload.nextUp)
            ).diagnosis?.cause,
            .modelReloaded)
    }

    /// The branch that had never run in production: on Ollama the load branch always won, and on
    /// LM Studio `prefillNs` is never populated. Carries the production-shaped warm
    /// `modelLoadMs` — `nil` is not a shape Ollama ever produces.
    func testResolve_warmLoadWithAColdPrefill_isServerDroppedCache() {
        let verdict = resolve(
            .reused(segments: 12),
            server: .init(
                modelLoadMs: Bench.warmLoadMs,
                prefillNsPerToken: Bench.coldPrefillNsPerToken,
                promptTokens: 12_927),
            floor: Bench.warmFloorNsPerToken, samples: 3, suspect: "bash judge")

        XCTAssertEqual(
            verdict.diagnosis?.cause, .serverDroppedCache(suspect: "bash judge"),
            "prefix intact, model resident, yet the server re-prefilled — the one measured claim")
    }

    func testResolve_warmPrefillAtAComparableDepth_isNotAMiss() {
        XCTAssertNil(
            resolve(
                .reused(segments: 12),
                server: .init(
                    prefillNsPerToken: Bench.deepWarmPrefillNsPerToken,
                    promptTokens: Bench.warmFloorPromptTokens),
                floor: Bench.warmFloorNsPerToken, samples: 3
            ).diagnosis)
    }

    /// `prompt_eval_count` is the WHOLE prompt while `prompt_eval_duration` on a hit is only the
    /// new tokens plus fixed overhead, so the rate is ≈ `overhead / depth`: on the baseline it
    /// falls 11× from K=1000 to K=16000 on warm turns alone. Comparing a shallow request against
    /// a floor sampled deep compares two different amortizations — 9 of 20 warm rows clear a 4×
    /// gate that way.
    func testResolve_warmPrefillAtAShallowerDepth_isNotAMiss() {
        XCTAssertNil(
            resolve(
                .reused(segments: 12),
                server: .init(
                    prefillNsPerToken: Bench.shallowWarmPrefillNsPerToken,
                    promptTokens: Bench.shallowPromptTokens),
                floor: Bench.warmFloorNsPerToken,
                floorPromptTokens: Bench.warmFloorPromptTokens,
                samples: 3
            ).diagnosis,
            "35.5× the floor, and still a cache HIT — depth, not eviction")
    }

    /// The failure this branch produced the first time it ever ran in production: a Software
    /// Engineer appended a `read_file` result, and the server honestly re-prefilled those new
    /// tokens. `prompt_eval_duration / prompt_eval_count` cannot tell that apart from an
    /// eviction — on a hit it is `overhead/total + (appended/total) × coldRate`, and the second
    /// term alone clears a 4× gate past ~450 appended tokens.
    ///
    /// Rates here are the measured COLD ones because that is exactly what a big append looks
    /// like: 2000 new tokens into a 3555-token prompt is 56% of the work of a full re-prefill.
    func testResolve_largeAppendedTail_isNotAnEviction() {
        XCTAssertNil(
            resolve(
                .reused(segments: 6),
                server: .init(
                    prefillNsPerToken: Bench.coldPrefillNsPerToken * 0.56,
                    promptTokens: 3555),
                floor: Bench.warmFloorNsPerToken,
                floorPromptTokens: 3300,
                samples: 3,
                tokens: 3555,
                appended: 2000
            ).diagnosis,
            "a `read_file` result is work the server owes on a perfect hit — not eviction")
    }

    /// The complement, and the reason the guard NARROWS rather than disables: an eviction's
    /// signature is a large re-prefill for a SMALL append. Same rate, same depth, tiny tail.
    func testResolve_smallAppendedTail_stillReportsAnEviction() {
        XCTAssertEqual(
            resolve(
                .reused(segments: 6),
                server: .init(
                    prefillNsPerToken: Bench.coldPrefillNsPerToken * 0.56,
                    promptTokens: 3555),
                floor: Bench.warmFloorNsPerToken,
                floorPromptTokens: 3300,
                samples: 3,
                tokens: 3555,
                appended: 40
            ).diagnosis?.cause.causeClass,
            .serverDroppedCache)
    }

    /// The cap must stay under the tightest measured break-even, or a legitimate hit reaches the
    /// gate on its own cost. `bench_baseline` puts that point at 453 appended tokens (K=1000,
    /// `4 × 57.5 ms ÷ 0.5086 ms/token`).
    func testMaxAppendedTokens_staysUnderTheMeasuredBreakEven() {
        XCTAssertLessThan(
            PrefixCachePolicy.maxAppendedTokensForRateComparison, 453,
            "past this many appended tokens a cache HIT alone clears the 4x gate")
        XCTAssertGreaterThan(
            PrefixCachePolicy.maxAppendedTokensForRateComparison, 0,
            "zero would retire the branch rather than narrow it")
    }

    func testResolve_insufficientFloorSamples_neverFires() {
        XCTAssertNil(
            resolve(
                .reused(segments: 12),
                server: .init(
                    prefillNsPerToken: Bench.coldPrefillNsPerToken,
                    promptTokens: Bench.warmFloorPromptTokens),
                floor: Bench.warmFloorNsPerToken, samples: 2
            ).diagnosis,
            "two samples is not a floor, it is two measurements — the first is usually cold")
    }

    func testResolve_absentOrZeroFloor_neverFires() {
        for floor in [nil, 0.0] as [Double?] {
            XCTAssertNil(
                resolve(
                    .reused(segments: 12),
                    server: .init(
                        prefillNsPerToken: Bench.coldPrefillNsPerToken,
                        promptTokens: Bench.warmFloorPromptTokens),
                    floor: floor, samples: 10
                ).diagnosis)
        }
    }

    /// LM Studio's steady state: `model_load_time_seconds` is 0 on every one of its baseline
    /// rows and `prefillNs` is deliberately never populated there.
    func testResolve_noServerSignalsAtAll_returnsStructural() {
        XCTAssertEqual(
            resolve(.reused(segments: 12), server: .init(modelLoadMs: 0)),
            .reused(segments: 12))
        XCTAssertEqual(resolve(.reused(segments: 12)), .reused(segments: 12))
    }

    // MARK: - resolve: boundaries and degenerate inputs

    /// Every gate in this branch is an inequality, and each one decides whether an always-on
    /// banner fires. Exactly-at vs one-past is pinned for all four so a `>`/`>=` flip cannot pass
    /// review as a no-op.
    func testResolve_everyGateIsPinnedAtItsBoundary() {
        func fires(appended: Int, requestTokens: Int, ratio: Double, samples: Int) -> Bool {
            resolve(
                .reused(segments: 6),
                server: .init(prefillNsPerToken: ratio, promptTokens: requestTokens),
                floor: Bench.warmFloorNsPerToken,
                floorPromptTokens: Bench.warmFloorPromptTokens,
                samples: samples,
                appended: appended
            ).diagnosis != nil
        }
        let gate = Bench.warmFloorNsPerToken * PrefixCachePolicy.serverRePrefillFactor
        let cap = PrefixCachePolicy.maxAppendedTokensForRateComparison
        let halfDepth = Bench.warmFloorPromptTokens / 2

        // Appended tail: `<=` the cap is still comparable.
        XCTAssertTrue(fires(appended: cap, requestTokens: 12_960, ratio: gate * 2, samples: 3))
        XCTAssertFalse(fires(appended: cap + 1, requestTokens: 12_960, ratio: gate * 2, samples: 3))

        // Depth: `>=` half the floor's depth is still comparable.
        XCTAssertTrue(fires(appended: 10, requestTokens: halfDepth, ratio: gate * 2, samples: 3))
        XCTAssertFalse(fires(appended: 10, requestTokens: halfDepth - 1, ratio: gate * 2, samples: 3))

        // Rate: strictly ABOVE the gate. Landing exactly on it is not evidence.
        XCTAssertFalse(fires(appended: 10, requestTokens: 12_960, ratio: gate, samples: 3))
        XCTAssertTrue(fires(appended: 10, requestTokens: 12_960, ratio: gate.nextUp, samples: 3))

        // Samples: the minimum itself is enough.
        let minimum = PrefixCachePolicy.minimumPrefillSamplesForFloor
        XCTAssertTrue(fires(appended: 10, requestTokens: 12_960, ratio: gate * 2, samples: minimum))
        XCTAssertFalse(
            fires(appended: 10, requestTokens: 12_960, ratio: gate * 2, samples: minimum - 1))
    }

    /// `isComparableDepth` is the one gate that can be asked about a request the server said
    /// nothing about. Unknown on either side means the comparison cannot be made honestly, so it
    /// is skipped — never assumed comparable.
    func testIsComparableDepth_treatsAnyUnknownAsNotComparable() {
        XCTAssertFalse(PrefixCachePolicy.isComparableDepth(requestTokens: nil, floorTokens: 1000))
        XCTAssertFalse(PrefixCachePolicy.isComparableDepth(requestTokens: 1000, floorTokens: nil))
        XCTAssertFalse(PrefixCachePolicy.isComparableDepth(requestTokens: nil, floorTokens: nil))
        XCTAssertFalse(
            PrefixCachePolicy.isComparableDepth(requestTokens: 1000, floorTokens: 0),
            "a zero-depth floor is not a floor — treating it as comparable would make every "
                + "request pass the gate")
        XCTAssertFalse(
            PrefixCachePolicy.isComparableDepth(requestTokens: 1000, floorTokens: -5))
        XCTAssertFalse(
            PrefixCachePolicy.isComparableDepth(requestTokens: 0, floorTokens: 0),
            "both degenerate is still not comparable")
    }

    func testIsComparableDepth_aDeeperRequestIsAlwaysComparable() {
        XCTAssertTrue(
            PrefixCachePolicy.isComparableDepth(requestTokens: 40_000, floorTokens: 1000),
            "the rate falls with depth, so a deeper request can only look FASTER than the floor "
                + "— it can never trip the gate by amortization alone")
    }

    /// A missing signal must never be read as a benign one. Each of these leaves the structural
    /// verdict untouched rather than clearing or firing anything.
    func testResolve_eachAbsentServerSignal_leavesTheVerdictAlone() {
        let loud = PrefixCachePolicy.ServerSignals(
            prefillNsPerToken: Bench.coldPrefillNsPerToken, promptTokens: 12_960)

        XCTAssertEqual(
            resolve(.reused(segments: 6), server: .init(modelLoadMs: nil), samples: 3),
            .reused(segments: 6), "no signal at all")
        XCTAssertEqual(
            resolve(.reused(segments: 6), server: .init(prefillNsPerToken: nil, promptTokens: 12_960),
                    floor: Bench.warmFloorNsPerToken, samples: 3),
            .reused(segments: 6), "no rate — LM Studio's steady state")
        XCTAssertEqual(
            resolve(.reused(segments: 6), server: loud, floor: nil, samples: 3),
            .reused(segments: 6), "no floor yet")
        XCTAssertEqual(
            resolve(.reused(segments: 6), server: loud,
                    floor: Bench.warmFloorNsPerToken, floorPromptTokens: nil, samples: 3),
            .reused(segments: 6), "floor with no depth recorded")
    }

    /// `load_duration` is a duration, so a server reporting 0 — LM Studio on every warm row — or
    /// a negative number from a broken build must both stay quiet.
    func testResolve_nonPositiveModelLoad_isNeverAReload() {
        for load in [0.0, -1.0, -2236.6] {
            XCTAssertNil(
                resolve(.reused(segments: 6), server: .init(modelLoadMs: load)).diagnosis,
                "\(load) ms cannot mean the model was loaded")
        }
    }

    /// A `Double` decoded from a wire number can be infinite. It must land on the definite side
    /// of the threshold rather than tripping some comparison quirk.
    func testResolve_infiniteModelLoad_isAReload() {
        XCTAssertEqual(
            resolve(.reused(segments: 6), server: .init(modelLoadMs: .infinity)).diagnosis?.cause,
            .modelReloaded)
    }

    /// NaN fails every comparison, so it can neither fire a branch nor suppress the one below it.
    func testResolve_naNSignals_fallThroughToTheStructuralVerdict() {
        XCTAssertEqual(
            resolve(.reused(segments: 6), server: .init(modelLoadMs: .nan)),
            .reused(segments: 6))
        XCTAssertEqual(
            resolve(
                .reused(segments: 6),
                server: .init(prefillNsPerToken: .nan, promptTokens: 12_960),
                floor: Bench.warmFloorNsPerToken, samples: 3),
            .reused(segments: 6))
    }

    /// `compare` cannot produce this (segment 0 always exists), but the type can — and it must
    /// not divide, index or otherwise misbehave on the way to a diagnosis.
    func testResolve_reusedWithZeroSegments_isStillAWellFormedMiss() {
        let diagnosis = resolve(
            .reused(segments: 0), server: .init(modelLoadMs: Bench.coldLoadMs), tokens: 5000
        ).diagnosis
        XCTAssertEqual(diagnosis?.cause, .modelReloaded)
        XCTAssertEqual(diagnosis?.previousSegments, 0)
        XCTAssertEqual(diagnosis?.discardedTokens, 5000)
    }

    /// The materiality gate lives in the caller, so `resolve` itself must still produce an
    /// honest zero-cost diagnosis rather than dividing by the total or asserting.
    func testResolve_zeroTokenRequest_producesAZeroCostDiagnosis() {
        let diagnosis = resolve(
            .reused(segments: 2), server: .init(modelLoadMs: Bench.coldLoadMs), tokens: 0
        ).diagnosis
        XCTAssertEqual(diagnosis?.discardedTokens, 0)
        XCTAssertEqual(diagnosis?.estimatedSeconds, 0)
    }

    /// A structural miss keeps its own per-segment cost. Overwriting it with the whole-request
    /// figure would inflate the banner AND lose the segment index that makes it actionable.
    func testResolve_structuralMiss_keepsItsOwnCostNotTheWholeRequest() {
        let structural = PrefixCachePolicy.Verdict.missed(.init(
            cause: .conversationRewritten(atSegment: 4),
            commonSegments: 4, previousSegments: 30, discardedTokens: 900))

        let verdict = resolve(
            structural,
            server: .init(
                modelLoadMs: Bench.coldLoadMs,
                prefillNsPerToken: Bench.coldPrefillNsPerToken, promptTokens: 12_960),
            floor: Bench.warmFloorNsPerToken, samples: 10, tokens: 99_999)

        XCTAssertEqual(verdict.diagnosis?.discardedTokens, 900)
        XCTAssertEqual(verdict.diagnosis?.commonSegments, 4)
    }

    // MARK: - Cause classes

    func testCauseClass_erasesPayloadSoRewritesDedup() {
        XCTAssertEqual(
            PrefixCachePolicy.Cause.conversationRewritten(atSegment: 3).causeClass,
            PrefixCachePolicy.Cause.conversationRewritten(atSegment: 17).causeClass)
        XCTAssertEqual(
            PrefixCachePolicy.Cause.serverDroppedCache(suspect: "bash judge").causeClass,
            PrefixCachePolicy.Cause.serverDroppedCache(suspect: nil).causeClass)
    }

    func testCauseClass_distinctAcrossKinds() {
        let classes: [PrefixCachePolicy.CauseClass] = [
            PrefixCachePolicy.Cause.systemPromptChanged.causeClass,
            PrefixCachePolicy.Cause.conversationRewritten(atSegment: 1).causeClass,
            PrefixCachePolicy.Cause.degradedReplay.causeClass,
            PrefixCachePolicy.Cause.modelReloaded.causeClass,
            PrefixCachePolicy.Cause.serverDroppedCache(suspect: nil).causeClass,
        ]
        XCTAssertEqual(Set(classes).count, classes.count)
        XCTAssertEqual(Set(classes), Set(PrefixCachePolicy.CauseClass.allCases))
    }

    // MARK: - Materiality

    func testMaterialThreshold_isBelowASecondOfRePrefill() {
        let seconds = Double(PrefixCachePolicy.materialTokenThreshold)
            * PrefixCachePolicy.estimatedColdPrefillMsPerToken / 1000
        XCTAssertLessThan(seconds, 1.0)
        XCTAssertGreaterThan(seconds, 0.5, "a threshold this low would fire on trivia")
    }

    func testEstimatedSeconds_tracksTheMeasuredColdRate() {
        let diagnosis = PrefixCachePolicy.Diagnosis(
            cause: .modelReloaded, commonSegments: 0, previousSegments: 5, discardedTokens: 12927)
        // bench_baseline recorded 6064 ms for 12927 tokens.
        XCTAssertEqual(diagnosis.estimatedSeconds, 5.81, accuracy: 0.3)
    }

    // MARK: - Presentation

    func testWarningMessage_opensWithTheShouldNotHaveHappenedFraming() {
        let message = PrefixCachePolicy.warningMessage(
            modelName: "qwen3.5-35b",
            diagnosis: .init(
                cause: .conversationRewritten(atSegment: 12),
                commonSegments: 12, previousSegments: 30, discardedTokens: 12927))

        XCTAssertTrue(message.hasPrefix("Prompt cache miss — this shouldn't have happened."))
        XCTAssertTrue(message.contains("qwen3.5-35b"), "must name the model")
        XCTAssertTrue(message.contains("12.9k"), "must name the tokens")
        XCTAssertTrue(message.contains("s)"), "must carry the seconds estimate")
        XCTAssertTrue(message.contains("message 12"), "must name the cause")
    }

    func testWarningMessage_staysWithinTwoBannerLines() {
        for cause in [
            PrefixCachePolicy.Cause.systemPromptChanged,
            .conversationRewritten(atSegment: 100),
            .degradedReplay,
            .modelReloaded,
            .serverDroppedCache(suspect: "supervisor auto-answer"),
        ] {
            let message = PrefixCachePolicy.warningMessage(
                modelName: "a-fairly-long-model-name-v2.5",
                diagnosis: .init(
                    cause: cause, commonSegments: 0, previousSegments: 40, discardedTokens: 131072))
            XCTAssertLessThan(message.count, 200, "banner is .lineLimit(2): \(message)")
        }
    }

    func testExplanation_namesTheSuspectOnlyWhenThereIsOne() {
        XCTAssertTrue(
            PrefixCachePolicy.explanation(for: .serverDroppedCache(suspect: "bash judge"))
                .contains("bash judge"))
        let anonymous = PrefixCachePolicy.explanation(for: .serverDroppedCache(suspect: nil))
        XCTAssertFalse(anonymous.contains("last other caller"))
        XCTAssertFalse(anonymous.isEmpty)
    }

    func testExplanation_isNeverEmptyForAnyCause() {
        for cause in [
            PrefixCachePolicy.Cause.systemPromptChanged,
            .conversationRewritten(atSegment: 1),
            .degradedReplay,
            .modelReloaded,
            .serverDroppedCache(suspect: ""),
        ] {
            XCTAssertFalse(PrefixCachePolicy.explanation(for: cause).isEmpty)
        }
    }

    /// The popover row label. Lives on the enum rather than on the view so a reader adding a
    /// case meets it beside `explanation(for:)`; the `switch` keeps the compiler enforcing
    /// coverage, which a metadata dictionary would have traded away.
    func testCauseClassLabel_isPresentAndDistinctForEveryCase() {
        var seen: Set<String> = []
        for cause in PrefixCachePolicy.CauseClass.allCases {
            XCTAssertFalse(cause.label.isEmpty, "\(cause) has no popover label")
            XCTAssertNotEqual(
                cause.label, cause.rawValue,
                "\(cause) shows its raw case name in the popover")
            XCTAssertTrue(seen.insert(cause.label).inserted, "\(cause) duplicates another label")
        }
    }

    /// One spelling of the ms→s conversion, so re-deriving the rate from a real run cannot land
    /// on the banner and miss the status pill (or vice versa).
    func testEstimatedSeconds_hasASingleOwner() {
        let tokens = 12_927
        XCTAssertEqual(
            PrefixCachePolicy.Diagnosis(
                cause: .degradedReplay, commonSegments: 0, previousSegments: 1,
                discardedTokens: tokens
            ).estimatedSeconds,
            PrefixCachePolicy.estimatedSeconds(forTokens: tokens),
            accuracy: 0.0001,
            "Diagnosis must route through the type that owns the rate, not re-spell the formula")
    }

    func testFormatTokens_switchesToKAtAThousand() {
        XCTAssertEqual(PrefixCachePolicy.formatTokens(840), "~840")
        XCTAssertEqual(PrefixCachePolicy.formatTokens(999), "~999")
        XCTAssertEqual(PrefixCachePolicy.formatTokens(1000), "~1.0k")
        XCTAssertEqual(PrefixCachePolicy.formatTokens(12927), "~12.9k")
    }

    func testFormatSeconds_dropsTheDecimalWhenItStopsMattering() {
        XCTAssertEqual(PrefixCachePolicy.formatSeconds(4.24), "4.2s")
        XCTAssertEqual(PrefixCachePolicy.formatSeconds(0.9), "0.9s")
        XCTAssertEqual(PrefixCachePolicy.formatSeconds(58.9), "59s")
    }

    // MARK: - discardedTokens

    /// The `commonSegments == 0` / `> 0` asymmetry is the whole reason `systemPromptChanged` is
    /// the most expensive cause there is, and it had no direct test — only indirect coverage
    /// through the ledger.

    private func discarded(_ messages: [ChatMessage], tools: String = "", common: Int) -> Int {
        PrefixCachePolicy.discardedTokens(
            messages: messages, toolSchemaText: tools, commonSegments: common)
    }

    private func sys(_ t: String) -> ChatMessage { ChatMessage(role: .system, content: t) }
    private func usr(_ t: String) -> ChatMessage { ChatMessage(role: .user, content: t) }

    func testDiscardedTokens_commonSegmentsZero_pricesTheWholeRequestIncludingSchemaText() {
        let messages = [sys("system prompt here"), usr("one"), usr("two")]
        let schema = String(repeating: "tool catalog ", count: 200)

        let withSchema = discarded(messages, tools: schema, common: 0)
        let withoutSchema = discarded(messages, tools: "", common: 0)

        XCTAssertGreaterThan(
            withSchema, withoutSchema,
            "losing segment 0 loses the tool catalog too — it renders into the system prompt")
        XCTAssertEqual(
            withSchema,
            ContextBudgetPolicy.estimateTokens(messages: messages, toolSchemaText: schema))
    }

    func testDiscardedTokens_commonSegmentsPositive_pricesTheTailAndExcludesSchemaText() {
        let messages = [sys("system prompt here"), usr("one"), usr("two"), usr("three")]
        let schema = String(repeating: "tool catalog ", count: 200)

        // common == 2 ⇒ segment 0 (system+tools) and segment 1 (the FIRST non-system message)
        // survive; everything from the second non-system message on is discarded.
        XCTAssertEqual(
            discarded(messages, tools: schema, common: 2),
            ContextBudgetPolicy.estimateTokens(messages: [usr("two"), usr("three")]),
            "a surviving segment 0 means the catalog is still cached — never price it again")
    }

    func testDiscardedTokens_commonSegmentsOne_dropsEveryNonSystemMessage() {
        let messages = [sys("s"), usr("one"), usr("two")]
        XCTAssertEqual(
            discarded(messages, tools: "ignored", common: 1),
            ContextBudgetPolicy.estimateTokens(messages: [usr("one"), usr("two")]),
            "segment 1 is the FIRST non-system message, so common==1 keeps only the system half")
    }

    func testDiscardedTokens_commonSegmentsBeyondTheConversation_isZero() {
        let messages = [sys("s"), usr("one")]
        XCTAssertEqual(discarded(messages, common: 5), 0)
        XCTAssertEqual(
            discarded(messages, common: 2), 0,
            "exactly one non-system message, all of it reused ⇒ nothing was discarded")
    }

    func testDiscardedTokens_degenerateInputs_neverTrap() {
        XCTAssertEqual(discarded([], common: 0), 0)
        XCTAssertEqual(discarded([], common: 3), 0)
        XCTAssertEqual(
            discarded([sys("s")], common: 3), 0,
            "a system-only conversation has no tail to discard")

        // A negative count is not producible by `compare`, but the guard must be total rather
        // than trap on a `nonSystem[(-2)...]` slice.
        XCTAssertEqual(
            discarded([sys("s"), usr("a")], tools: "t", common: -2),
            ContextBudgetPolicy.estimateTokens(
                messages: [sys("s"), usr("a")], toolSchemaText: "t"),
            "anything non-positive is treated as 'nothing survived'")
    }

    func testDiscardedTokens_systemMessagesAreNeverPartOfTheTail() {
        // Two system messages collapse into segment 0, so neither may reappear in a tail price.
        let messages = [sys("a"), sys("b"), usr("one"), usr("two")]
        XCTAssertEqual(
            discarded(messages, common: 2),
            ContextBudgetPolicy.estimateTokens(messages: [usr("two")]))
    }
    // MARK: - measuredExtraSeconds

    /// The honest price of a miss: what the server actually spent, minus what the same request
    /// would have cost had the prefix held. No estimate on either side — unlike
    /// `estimatedSeconds(forTokens:)`, which multiplies a hardware-independent constant by
    /// `discardedTokens`, itself a `ContextBudgetPolicy` estimate measured 0.78–2.26× off.
    /// RED: return the full prefill instead of the difference → the popover charges the user for
    /// the warm cost they would have paid anyway.
    func testMeasuredExtraSeconds_isTheDifferenceFromTheWarmFloor() {
        // 2.78 ms/token measured cold, 0.055 ms/token warm floor, 7500-token prompt.
        let seconds = PrefixCachePolicy.measuredExtraSeconds(
            prefillNsPerToken: 2_780_000, warmFloorNsPerToken: 55_000, promptTokens: 7_500)
        XCTAssertEqual(seconds ?? 0, 20.4, accuracy: 0.1)
    }

    /// RED: drop the `extraNs > 0` guard → a request at or below the warm floor reports a
    /// negative cost, which renders as a negative number of seconds "lost".
    func testMeasuredExtraSeconds_refusesWhenTheRequestWasNotSlowerThanWarm() {
        XCTAssertNil(PrefixCachePolicy.measuredExtraSeconds(
            prefillNsPerToken: 50_000, warmFloorNsPerToken: 55_000, promptTokens: 7_500))
        XCTAssertNil(PrefixCachePolicy.measuredExtraSeconds(
            prefillNsPerToken: 55_000, warmFloorNsPerToken: 55_000, promptTokens: 7_500))
    }

    /// Missing terms mean the miss cannot be priced, not that it was free.
    /// RED: default a missing floor to zero → the whole prefill is charged as "extra", which is
    /// the estimate's error in the other direction and just as wrong.
    func testMeasuredExtraSeconds_refusesOnAnyMissingTerm() {
        XCTAssertNil(PrefixCachePolicy.measuredExtraSeconds(
            prefillNsPerToken: nil, warmFloorNsPerToken: 55_000, promptTokens: 7_500))
        XCTAssertNil(PrefixCachePolicy.measuredExtraSeconds(
            prefillNsPerToken: 2_780_000, warmFloorNsPerToken: nil, promptTokens: 7_500))
        XCTAssertNil(PrefixCachePolicy.measuredExtraSeconds(
            prefillNsPerToken: 2_780_000, warmFloorNsPerToken: 55_000, promptTokens: nil))
        XCTAssertNil(PrefixCachePolicy.measuredExtraSeconds(
            prefillNsPerToken: 2_780_000, warmFloorNsPerToken: 55_000, promptTokens: 0))
    }

    /// Measured when we have it, estimated when we do not — never a blend, which would be
    /// neither and unreadable by the caller.
    /// RED: sum the two instead of preferring the measurement → a priced miss is double-charged.
    func testDiagnosisEstimatedSeconds_prefersTheMeasurementAndFallsBackWithoutIt() {
        let measured = PrefixCachePolicy.Diagnosis(
            cause: .modelReloaded, commonSegments: 0, previousSegments: 5,
            discardedTokens: 12_927, measuredExtraSeconds: 20.8)
        XCTAssertEqual(measured.estimatedSeconds, 20.8, accuracy: 0.001)

        let unmeasured = PrefixCachePolicy.Diagnosis(
            cause: .modelReloaded, commonSegments: 0, previousSegments: 5,
            discardedTokens: 12_927)
        XCTAssertEqual(unmeasured.estimatedSeconds, 5.81, accuracy: 0.3)
    }

}
