import XCTest

@testable import NanoTeams

/// `TasksIndex.upsert` — the single home for "put this summary back, keep the order".
///
/// It replaced five open-coded copies of `firstIndex(where:)` → replace-or-append →
/// `sort(by:)`, three of them on the MainActor inside `mutateTask`, which runs on every
/// LLM message. The order it maintains is a live contract:
/// `StaleStatusSweepTests.testSweep_multipleStale_indexStaysSortedByUpdatedAt` and the
/// `tasks[0].title` assertions in `TaskServiceTests` / sidebar rendering all read it.
final class TasksIndexUpsertTests: XCTestCase {

    private func summary(_ id: Int, _ secondsAgo: TimeInterval, title: String? = nil) -> TaskSummary {
        TaskSummary(
            id: id, title: title ?? "task-\(id)", status: .running,
            updatedAt: Date(timeIntervalSince1970: 10_000 - secondsAgo))
    }

    private func index(_ rows: [TaskSummary]) -> TasksIndex {
        TasksIndex(schemaVersion: 1, tasks: rows, nextTaskID: 99)
    }

    /// The common case: the mutated row carries a fresh `MonotonicClock` stamp, so it is
    /// provably the newest and belongs at the front.
    ///
    /// RED: insert at `tasks.count` instead of `insertionSlot(for:)` -> the row lands last.
    func testUpsert_newestStamp_movesRowToTheFront() {
        var idx = index([summary(1, 0), summary(2, 10), summary(3, 20)])
        idx.upsert(summary(3, -5, title: "touched"))

        XCTAssertEqual(idx.tasks.map(\.id), [3, 1, 2])
        XCTAssertEqual(idx.tasks[0].title, "touched")
        XCTAssertEqual(idx.tasks.count, 3, "upsert replaces, never duplicates")
    }

    /// NOT every caller re-stamps. `refreshBackgroundTaskInMemory` is reached from the
    /// open-time recovery sweep with a probe whose `updatedAt` never moved, so "insert at
    /// the front" would be wrong and the slot has to be searched.
    ///
    /// RED: replace `insertionSlot(for:)` with `0` -> the untouched row jumps the queue.
    func testUpsert_unchangedStamp_staysInItsPlace() {
        var idx = index([summary(1, 0), summary(2, 10), summary(3, 20)])
        idx.upsert(summary(2, 10, title: "converged"))

        XCTAssertEqual(idx.tasks.map(\.id), [1, 2, 3])
        XCTAssertEqual(idx.tasks[1].title, "converged")
    }

    /// A row older than everything present belongs at the end.
    func testUpsert_oldestStamp_landsLast() {
        var idx = index([summary(1, 0), summary(2, 10)])
        idx.upsert(summary(9, 999))
        XCTAssertEqual(idx.tasks.map(\.id), [1, 2, 9])
    }

    /// An id that isn't in the index yet is an insert, not a no-op — `updateTaskOnly`
    /// reaches this for a task created by another process/window.
    func testUpsert_unknownID_isInsertedInOrder() {
        var idx = index([summary(1, 0), summary(3, 20)])
        idx.upsert(summary(2, 10))
        XCTAssertEqual(idx.tasks.map(\.id), [1, 2, 3])
    }

    func testUpsert_emptyIndex_insertsTheOnlyRow() {
        var idx = index([])
        idx.upsert(summary(1, 0))
        XCTAssertEqual(idx.tasks.map(\.id), [1])
    }

    /// The property the whole change rests on: whatever the caller hands it, the order
    /// invariant survives. Asserted over a randomized workload rather than three hand-
    /// picked rows, because the five call sites feed it every shape there is.
    ///
    /// RED: any wrong comparison direction in `insertionSlot` -> the descending check trips.
    func testUpsert_manyMixedOperations_keepOrderDescending() {
        var idx = index([])
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }

        for step in 0..<400 {
            let id = Int(next() % 40)
            // Mix fresh stamps (the mutation path) with repeats of stamps already present
            // (the converge path) so ties are exercised, not just distinct values.
            let age = TimeInterval(Int(next() % 60)) - TimeInterval(step) * 0.5
            idx.upsert(summary(id, age))

            let stamps = idx.tasks.map(\.updatedAt)
            XCTAssertEqual(
                stamps, stamps.sorted(by: >),
                "order broke after upserting id \(id) at step \(step)")
            XCTAssertEqual(
                Set(idx.tasks.map(\.id)).count, idx.tasks.count,
                "upsert duplicated id \(id) at step \(step)")
        }
        XCTAssertFalse(idx.tasks.isEmpty, "anti-vacuum: the workload really populated the index")
    }

    /// `Array.sort` is introsort — unstable — so the five removed copies could reorder
    /// rows sharing an `updatedAt` arbitrarily. `upsert` is deterministic: re-inserting an
    /// unchanged row must reproduce the same array, every time.
    ///
    /// RED: drop the `updatedAt == summary.updatedAt` replace-in-place arm -> the row is
    /// removed and re-inserted at the back of its tie group, giving `[1, 3, 2]`.
    func testUpsert_tiedStamps_isDeterministicUnderRepetition() {
        let tied = [summary(1, 5), summary(2, 5), summary(3, 5)]
        var idx = index(tied)
        let before = idx.tasks.map(\.id)

        for _ in 0..<10 { idx.upsert(summary(2, 5)) }

        XCTAssertEqual(idx.tasks.map(\.id), before,
                       "an unchanged row must land back where it was, not rotate its tie group")
    }
}
