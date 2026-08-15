import XCTest

@testable import NanoTeams

/// `PrefixCacheReporter.resetCounters(forTaskID:)` shipped with no production caller, so the
/// always-on `CACHE ×N` pill counted every miss since launch and its banner latch never cleared
/// for a task. `createNewRun` is the seam: a new run IS the "fresh look" the reset was written
/// for.
///
/// The risk this wiring carries is the reason the reset is task-scoped rather than global — the
/// Autovisor starts a run every minute, so a global reset there would discard the counts of the
/// user's own tasks on the manager's cadence. Both directions are pinned below.
@MainActor
final class PrefixCacheCounterResetTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private func reportMiss(task: Int, run: Int) {
        sut.prefixCacheReporter.report(PrefixCacheMiss(
            owner: .step(taskID: task, stepID: "engineer"),
            runID: run,
            modelName: "m",
            diagnosis: .init(
                cause: .conversationRewritten(atSegment: 3),
                commonSegments: 3, previousSegments: 20, discardedTokens: 10_000)))
    }

    func testNewRun_zeroesTheCountersForTheTaskBeingWatched() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "A", supervisorTask: "x")!
        sut.prefixCacheReporter.onScreenTaskID = id

        reportMiss(task: id, run: 0)
        reportMiss(task: id, run: 0)
        XCTAssertEqual(sut.prefixCacheReporter.missCount, 2, "precondition")

        await sut.createNewRun(taskID: id)

        XCTAssertEqual(
            sut.prefixCacheReporter.missCount, 0,
            "the pill must count THIS run's misses, not every miss since launch")
        XCTAssertEqual(sut.prefixCacheReporter.discardedTokensTotal, 0)
        XCTAssertTrue(sut.prefixCacheReporter.countsByCause.isEmpty)
        XCTAssertTrue(sut.prefixCacheReporter.countsByOwner.isEmpty)
    }

    /// The Autovisor creates a run on every wake. If that wiped the aggregate, the user's own
    /// counts would vanish roughly once a minute while they were looking at something else.
    func testNewRun_onAnotherTask_leavesTheWatchedTasksCountsAlone() async {
        await sut.openWorkFolder(tempDir)
        let watched = await sut.createTask(title: "watched", supervisorTask: "x")!
        let other = await sut.createTask(title: "other", supervisorTask: "y")!
        sut.prefixCacheReporter.onScreenTaskID = watched

        reportMiss(task: watched, run: 0)
        reportMiss(task: watched, run: 0)

        await sut.createNewRun(taskID: other)

        XCTAssertEqual(
            sut.prefixCacheReporter.missCount, 2,
            "a background task starting a run must not zero the pill the user is reading")
    }

    /// The latch half of the reset: `bannerFired` is keyed `(taskID, runID, causeClass)`, so a
    /// new run re-arms it anyway — but the reset must not leave a stale entry that suppresses
    /// the FIRST banner of the new run.
    func testNewRun_reArmsTheBannerForTheSameCause() async {
        await sut.openWorkFolder(tempDir)
        let id = await sut.createTask(title: "A", supervisorTask: "x")!
        sut.prefixCacheReporter.onScreenTaskID = id

        reportMiss(task: id, run: 0)
        XCTAssertEqual(
            sut.prefixCacheReporter._testBannerFiredCount(), 1, "precondition: one latch entry")

        await sut.createNewRun(taskID: id)

        XCTAssertEqual(
            sut.prefixCacheReporter._testBannerFiredCount(), 0,
            "the latch must clear for this task, so the new run can banner its first real miss")
    }
}
