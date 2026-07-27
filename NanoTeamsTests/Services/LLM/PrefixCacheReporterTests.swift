import XCTest
@testable import NanoTeams

/// The reporter is the only thing standing between an always-on detector and a banner storm.
/// These pin the bound it promises.
@MainActor
final class PrefixCacheReporterTests: XCTestCase {

    var sut: PrefixCacheReporter!

    override func setUp() {
        super.setUp()
        sut = PrefixCacheReporter()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
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
