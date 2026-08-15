import XCTest
@testable import NanoTeams

/// The reporter is the only thing standing between an always-on detector and a banner storm.
/// These pin the bound it promises.
@MainActor
final class PrefixCacheReporterTests: XCTestCase {

    var sut: PrefixCacheReporter!

    override func setUp() async throws {
        try await super.setUp()
        sut = PrefixCacheReporter()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    private func diagnosis(
        _ cause: PrefixCachePolicy.Cause = .conversationRewritten(atSegment: 3),
        tokens: Int = 10_000
    ) -> PrefixCachePolicy.Diagnosis {
        .init(cause: cause, commonSegments: 3, previousSegments: 20, discardedTokens: tokens)
    }

    @discardableResult
    private func report(
        task: Int, run: Int, owner: String = "engineer",
        cause: PrefixCachePolicy.Cause = .conversationRewritten(atSegment: 3),
        tokens: Int = 10_000
    ) -> String? {
        sut.report(PrefixCacheMiss(
            owner: .step(taskID: task, stepID: owner),
            runID: run,
            modelName: "m",
            diagnosis: diagnosis(cause, tokens: tokens)))
    }

    // MARK: - The count is the always-on surface

    func testCountAlwaysMoves_evenWhenNoBannerFires() {
        sut.onScreenTaskID = nil // nothing on screen — no banner is possible
        for _ in 0..<5 { report(task: 1, run: 0) }

        XCTAssertEqual(sut.missCount, 5)
        XCTAssertEqual(sut.discardedTokensTotal, 50_000)
        XCTAssertEqual(sut.countsByCause[.conversationRewritten], 5)
        XCTAssertEqual(sut.countsByOwner["engineer"], 5)
    }

    func testEstimatedSecondsLost_usesTheMeasuredColdRate() {
        report(task: 1, run: 0, tokens: 12_927)
        XCTAssertEqual(sut.estimatedSecondsLost, 5.81, accuracy: 0.3)
    }

    // MARK: - Measured cost beats the estimate

    /// The popover's headline is the only number the user reads, and the constant behind it was
    /// calibrated on one model (`qwen3_5_moe` 35.1B): a live `qwen3.8:27b-mlx` run measured
    /// 2.78 ms/token cold, 6.2× the constant, so a real ~21 s eviction was shown as "3.4s".
    /// RED: drop `measuredExtraSeconds` from `Diagnosis.estimatedSeconds` (or stop accumulating
    /// per-miss in `report`) → the server's own figure is discarded and the estimate is shown.
    func testEstimatedSecondsLost_prefersTheServerMeasuredCost() {
        sut.report(PrefixCacheMiss(
            owner: .step(taskID: 1, stepID: "engineer"),
            runID: 0,
            modelName: "m",
            diagnosis: .init(
                cause: .serverDroppedCache(suspect: nil),
                commonSegments: 0, previousSegments: 9,
                discardedTokens: 12_927,
                measuredExtraSeconds: 20.8)))

        XCTAssertEqual(sut.estimatedSecondsLost, 20.8, accuracy: 0.01)
    }

    /// Mixed aggregate: a measured miss and an unmeasured one must both count, which is why the
    /// total is accumulated per miss instead of derived from `discardedTokensTotal`.
    /// RED: derive `estimatedSecondsLost` from `discardedTokensTotal` again → the measured miss
    /// is re-priced with the constant and the total collapses to the estimate.
    func testEstimatedSecondsLost_sumsMeasuredAndEstimatedMisses() {
        sut.report(PrefixCacheMiss(
            owner: .step(taskID: 1, stepID: "a"), runID: 0, modelName: "m",
            diagnosis: .init(
                cause: .modelReloaded, commonSegments: 0, previousSegments: 1,
                discardedTokens: 12_927, measuredExtraSeconds: 20.8)))
        report(task: 1, run: 0, owner: "b", tokens: 12_927)

        XCTAssertEqual(sut.estimatedSecondsLost, 20.8 + 5.817, accuracy: 0.05)
    }

    // MARK: - Suspect lead

    /// `countsByCause` keys on `CauseClass`, which erases the suspect — correct for banner dedup,
    /// and the reason the popover row could never name anyone. Collected separately.
    /// RED: delete the `suspectsByCause` insert in `report` → `suspectLead` is nil and the row
    /// goes back to the bare, unactionable "Server dropped the cached prefix".
    func testSuspectLead_namesTheSingleDistinctSuspect() {
        report(task: 1, run: 0, cause: .serverDroppedCache(suspect: "step:7:startup_software_engineer"))
        XCTAssertEqual(sut.suspectLead(for: .serverDroppedCache), "startup_software_engineer")
    }

    /// The ledger's ring stores `LLMCallOwner.key`, while the BY CALLER rows beside it show
    /// `displayName`. Two spellings of one caller in one popover read as two callers.
    /// RED: insert the raw suspect key instead of projecting it → the row shows
    /// `step:7:startup_software_engineer` next to a `startup_software_engineer` row.
    func testSuspectLead_isProjectedToTheSameSpellingAsTheCallerRows() {
        report(task: 1, run: 0, cause: .serverDroppedCache(suspect: "oneShot:bash judge"))
        XCTAssertEqual(sut.suspectLead(for: .serverDroppedCache), "bash judge")
    }

    /// Several distinct suspects is a scatter, not a lead — naming one would be an accusation the
    /// aggregate cannot support.
    /// RED: return `suspects.first` regardless of count → the popover blames whichever caller the
    /// Set happens to order first, which is seeded per process.
    func testSuspectLead_isSilentWhenSuspectsDisagree() {
        report(task: 1, run: 0, cause: .serverDroppedCache(suspect: "step:7:a"))
        report(task: 1, run: 0, cause: .serverDroppedCache(suspect: "step:8:b"))
        XCTAssertNil(sut.suspectLead(for: .serverDroppedCache))
    }

    /// The same suspect twice is still one lead.
    /// RED: use an array and compare `count == 1` → a repeated eviction by one caller stops
    /// naming it, which is the case the lead exists for.
    func testSuspectLead_survivesRepeatsFromTheSameSuspect() {
        report(task: 1, run: 0, cause: .serverDroppedCache(suspect: "step:7:autovisor_autovisor"))
        report(task: 1, run: 0, cause: .serverDroppedCache(suspect: "step:7:autovisor_autovisor"))
        XCTAssertEqual(sut.suspectLead(for: .serverDroppedCache), "autovisor_autovisor")
    }

    func testSuspectLead_nilSuspectRecordsNothing() {
        report(task: 1, run: 0, cause: .serverDroppedCache(suspect: nil))
        XCTAssertNil(sut.suspectLead(for: .serverDroppedCache))
    }

    /// RED: omit `estimatedSecondsLost`/`suspectsByCause` from `resetCounters` → the popover keeps
    /// quoting a cost and a suspect from a run the user already restarted.
    func testResetCounters_clearsTheSecondsTotalAndTheSuspects() {
        sut.onScreenTaskID = 1
        report(task: 1, run: 0, cause: .serverDroppedCache(suspect: "step:7:a"), tokens: 12_927)
        XCTAssertGreaterThan(sut.estimatedSecondsLost, 0)

        sut.resetCounters(forTaskID: 1)

        XCTAssertEqual(sut.estimatedSecondsLost, 0)
        XCTAssertNil(sut.suspectLead(for: .serverDroppedCache))
    }

    // MARK: - Banner-storm bound

    func testParallelTeamRun_producesOneBannerPerCauseNotPerRole() {
        sut.onScreenTaskID = 1
        let roles = ["pm", "uxr", "uxd", "techLead", "engineer", "reviewer", "sre", "tpm"]

        var banners: [String] = []
        // 8 concurrent roles × 15 tool-loop iterations, all missing on the same cause.
        for role in roles {
            for _ in 0..<15 {
                if let message = report(task: 1, run: 0, owner: role) { banners.append(message) }
            }
        }

        XCTAssertEqual(sut.missCount, 120, "every miss still counts")
        XCTAssertEqual(
            banners.count, 1,
            "a per-STEP latch would give 8 banners as the FLOOR; the key is (task, run, cause)")
    }

    func testDistinctCauses_eachEarnOneBanner() {
        sut.onScreenTaskID = 1
        var banners: [String] = []
        for cause in [
            PrefixCachePolicy.Cause.systemPromptChanged,
            .conversationRewritten(atSegment: 2),
            .degradedReplay,
            .modelReloaded,
            .serverDroppedCache(suspect: "bash judge"),
        ] {
            for _ in 0..<10 {
                if let message = report(task: 1, run: 0, cause: cause) { banners.append(message) }
            }
        }
        XCTAssertEqual(banners.count, 5, "different causes call for different actions")
    }

    func testRewritesAtDifferentIndices_shareOneBanner() {
        sut.onScreenTaskID = 1
        let first = report(task: 1, run: 0, cause: .conversationRewritten(atSegment: 3))
        let second = report(task: 1, run: 0, cause: .conversationRewritten(atSegment: 17))
        XCTAssertNotNil(first)
        XCTAssertNil(second, "the user's remedy is identical, so the payload must not re-arm")
    }

    // MARK: - The latch key must carry the task

    func testTwoTasksAtRunZero_doNotSuppressEachOther() {
        sut.onScreenTaskID = 1
        XCTAssertNotNil(report(task: 1, run: 0))
        sut.onScreenTaskID = 2
        XCTAssertNotNil(
            report(task: 2, run: 0),
            "Run.id is per-task sequential, so a bare runID latch would eat task 2's first miss")
    }

    func testANewRunOfTheSameTask_reArms() {
        sut.onScreenTaskID = 1
        XCTAssertNotNil(report(task: 1, run: 0))
        XCTAssertNil(report(task: 1, run: 0))
        XCTAssertNotNil(report(task: 1, run: 1), "a fresh run is a fresh report")
    }

    // MARK: - On-screen routing

    func testOffScreenTask_countsButNeverBanners() {
        sut.onScreenTaskID = 1
        XCTAssertNil(
            report(task: 99, run: 0),
            "a background task or the hidden Autovisor must not banner")
        XCTAssertEqual(sut.missCount, 1, "but it is still visible in the count")
    }

    func testAutovisorWakingEveryMinute_neverBannersWhileOffScreen() {
        sut.onScreenTaskID = 1 // the user is looking at their own task
        var banners = 0
        // The manager starts a NEW run on every wake — a bare runID latch would re-arm each time.
        for wake in 0..<60 where report(task: 42, run: wake) != nil { banners += 1 }
        XCTAssertEqual(banners, 0)
        XCTAssertEqual(sut.missCount, 60)
    }

    func testMissingRunID_countsButNeverBanners() {
        sut.onScreenTaskID = 1
        XCTAssertNil(sut.report(PrefixCacheMiss(
            owner: .step(taskID: 1, stepID: "engineer"), runID: nil, modelName: "m",
            diagnosis: diagnosis())))
        XCTAssertEqual(sut.missCount, 1)
    }

    // MARK: - Reset

    func testResetCounters_forTheOnScreenTask_zeroesTheAggregateAndReArms() {
        sut.onScreenTaskID = 1
        XCTAssertNotNil(report(task: 1, run: 0))
        sut.resetCounters(forTaskID: 1)

        XCTAssertEqual(sut.missCount, 0)
        XCTAssertTrue(sut.countsByCause.isEmpty)
        XCTAssertNotNil(report(task: 1, run: 0), "the latch cleared with the counters")
    }

    func testResetCounters_forABackgroundTask_leavesTheAggregateAlone() {
        sut.onScreenTaskID = 1
        report(task: 1, run: 0)
        report(task: 2, run: 0)
        XCTAssertEqual(sut.missCount, 2)

        // The Autovisor starts a run on every wake; a global reset there would discard the
        // user's own counts on the manager's cadence.
        sut.resetCounters(forTaskID: 2)
        XCTAssertEqual(sut.missCount, 2)
    }
}
