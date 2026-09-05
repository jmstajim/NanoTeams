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

    /// `upsert` hands back the row it REPLACED, because that value exists only for the
    /// duration of the call and `NTMSOrchestrator.upsertTaskSummary` needs it to retire the
    /// Autovisor's spent attention keys on the edge where a condition's level clears.
    ///
    /// Pinned directly rather than only through that consumer: the mutation `return summary`
    /// — handing back the row just written — makes every transition compare new-against-new,
    /// silently disabling the whole retirement, and nothing else in the tree reads this value.
    /// Covers all three exit paths, since the insert and the two replace branches each return
    /// separately. `previous` rides `UpsertOutcome` beside `moved` (next test).
    func testUpsert_returnsTheRowItReplaced() {
        var idx = index([summary(1, 0), summary(2, 10)])

        XCTAssertNil(idx.upsert(summary(9, 5)).previous, "a row seen for the first time replaced nothing")

        // Replace branch #1: a moved stamp (remove + re-insert).
        let movedStamp = idx.upsert(summary(2, -5, title: "touched"))
        XCTAssertEqual(movedStamp.previous?.title, "task-2", "the value handed back is the OLD row")
        XCTAssertEqual(idx.tasks.first(where: { $0.id == 2 })?.title, "touched",
                       "…while the index holds the new one")

        // Replace branch #2: an unchanged stamp (converge write, replaced in place).
        let sameStamp = idx.upsert(summary(1, 0, title: "converged"))
        XCTAssertEqual(sameStamp.previous?.title, "task-1",
                       "the in-place converge branch must return the old row too — it is the "
                           + "branch a recovery-sweep re-summarize takes")
    }

    /// `moved` is "the row's index changed" — the bit `TaskFactsProjection.rowsRevision`
    /// keys on, so a message append that re-stamps the HEAD row (the hot path: it stays at
    /// index 0) must read `false`, while a background task re-stamped past the head must
    /// read `true`. Pinned here because the index is the only party that holds both slots;
    /// a consumer re-deriving it would pay two scans per `mutateTask`.
    ///
    /// RED: in the move branch replace `moved: slot != existing` with `moved: true` → the
    /// head-row and in-between cases fail (`XCTAssertFalse(head.moved)`); `moved: false`
    /// fails the tail-row case instead; in the INSERT arm `moved: true` → `moved: false`
    /// fails `XCTAssertTrue(fresh.moved)`.
    func testUpsert_reportsWhetherTheRowMoved() {
        var idx = index([summary(1, 0), summary(2, 10), summary(3, 20)])

        // Head row re-stamped newer: removed and re-inserted at the same index 0.
        let head = idx.upsert(summary(1, -5, title: "head"))
        XCTAssertFalse(head.moved, "a head row that stays at the head did not move")
        XCTAssertEqual(head.previous?.title, "task-1")
        XCTAssertEqual(idx.tasks.map(\.id), [1, 2, 3], "anti-vacuum: the re-stamp really happened")
        XCTAssertEqual(idx.tasks[0].title, "head")

        // Tail row re-stamped newest: jumps to the front.
        let tail = idx.upsert(summary(3, -10))
        XCTAssertTrue(tail.moved)
        XCTAssertEqual(idx.tasks.map(\.id), [3, 1, 2])

        // Unchanged stamp: the converge write replaces in place.
        let same = idx.upsert(summary(2, 10, title: "converged"))
        XCTAssertFalse(same.moved)
        XCTAssertEqual(same.previous?.title, "task-2")

        // First-seen id: it had no index, so it counts as moved.
        let fresh = idx.upsert(summary(9, 999))
        XCTAssertNil(fresh.previous)
        XCTAssertTrue(fresh.moved)
        XCTAssertEqual(idx.tasks.map(\.id), [3, 1, 2, 9])

        // A middle row re-stamped to a value BETWEEN its neighbours: same index → not moved.
        let between = idx.upsert(summary(2, 5))
        XCTAssertFalse(between.moved)
        XCTAssertEqual(idx.tasks.map(\.id), [3, 1, 2, 9])
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

    // MARK: - upsert(_:at:) — the positioned spelling `updateTaskOnly` feeds from its one pass

    /// The probe is WIRED into the searching spelling, and the positioned spelling pays no
    /// pass of its own. Anti-vacuum for every bound asserted against `fullScans()`
    /// (`TasksIndexConcurrencyTests.testUpdateTaskOnly_walksTheIndexRowsExactlyOnce`): if the
    /// first assertion read 0, that bound would hold for a hot path that scanned ten times.
    ///
    /// RED: delete `TasksIndexWorkProbe.noteFullScan()` from the one-argument `upsert(_:)` →
    /// the first assertion reads 0.
    func testUpsert_searchingSpellingIsOneScan_positionedSpellingIsNone() {
        var idx = index([summary(1, 0), summary(2, 10), summary(3, 20)])
        TasksIndexWorkProbe.reset()

        idx.upsert(summary(2, -5))
        XCTAssertEqual(TasksIndexWorkProbe.fullScans(), 1,
                       "the searching upsert(_:) walks the rows for its slot — if this is 0 the "
                           + "probe is not wired and every bound against it is vacuous")

        idx.upsert(summary(3, -6), at: idx.tasks.firstIndex { $0.id == 3 })
        XCTAssertEqual(TasksIndexWorkProbe.fullScans(), 1,
                       "the positioned upsert(_:at:) does no pass of its own — the caller "
                           + "already paid for the slot")
        XCTAssertEqual(idx.tasks.map(\.id), [3, 2, 1], "and both landed where their stamps say")
    }

    /// `upsert(_:at:)` fed the FIRST row's position is indistinguishable from `upsert(_:)`:
    /// same order, same tie handling, same returned `previous`, no duplicate ids. Asserted
    /// over the seeded workload above on TWO copies, step by step, so every arm (insert,
    /// in-place tie, moved stamp) is compared rather than three hand-picked rows.
    ///
    /// RED: in `upsert(_:at:)` ignore `position` and always take the insert arm → `b` grows
    /// a duplicate on the first repeated id and `a.tasks == b.tasks` fails.
    func testUpsert_atPosition_matchesTheSearchingSpelling() {
        var a = index([])
        var b = index([])
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }

        var replaced = 0
        for step in 0..<400 {
            let id = Int(next() % 40)
            let age = TimeInterval(Int(next() % 60)) - TimeInterval(step) * 0.5
            let s = summary(id, age, title: "step-\(step)")

            let previousA = a.upsert(s)
            let previousB = b.upsert(s, at: b.tasks.firstIndex { $0.id == s.id })
            if previousA.previous != nil { replaced += 1 }

            XCTAssertEqual(previousA, previousB, "returned outcome diverged at step \(step)")
            XCTAssertEqual(a.tasks, b.tasks, "the two spellings diverged at step \(step) (id \(id))")
        }
        XCTAssertGreaterThan(replaced, 100, "anti-vacuum: the workload exercised the replace arms")
        XCTAssertEqual(Set(b.tasks.map(\.id)).count, b.tasks.count, "no duplicate ids")
    }

    /// The positioned spelling with `nil` is a plain insert — the arm `updateTaskOnly` takes
    /// for a task created by another process/window whose row the pass did not find.
    func testUpsert_atNil_isAnInsertInOrder() {
        var idx = index([summary(1, 0), summary(3, 20)])
        XCTAssertNil(idx.upsert(summary(2, 10), at: nil).previous)
        XCTAssertEqual(idx.tasks.map(\.id), [1, 2, 3])
    }
}
