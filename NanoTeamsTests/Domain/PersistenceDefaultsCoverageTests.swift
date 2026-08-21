import XCTest

@testable import NanoTeams

/// Coverage wave 1 — the `decodeIfPresent(...) ?? default` arms that every legacy file on disk
/// passes through, and the identity conformances nothing exercised.
///
/// These arms are the codebase's entire migration strategy: there are no migration scripts, so a
/// field added last month is read out of a file written last year by exactly one `??`. A wrong
/// default here does not throw — it produces a plausible value, which is why this is the class of
/// defect with the longest fuse.
///
/// Note on what a whole-line reading of the coverage report shows: most of these are **sub-line**
/// regions (the autoclosure on the right of `??`), so they are invisible to `xccov`'s per-line
/// view and only appear in the region counts. `TeamSettings` was 12 such lines of its 14.
final class PersistenceDefaultsCoverageTests: XCTestCase {

    // MARK: - WorkFolderState

    /// `schemaVersion` uses `max(storedVersion, 8)` rather than a plain assignment, and the reason
    /// is CLAUDE.md #48: a successful legacy decode that re-encodes under the OLD version makes
    /// the legacy branch fire forever. The `max` also has to let a NEWER file keep its version, or
    /// opening a folder with an older build silently downgrades it.
    ///
    /// RED: change `max(storedVersion, 8)` to `8` → the newer-file assertion fails, and this build
    /// would quietly rewrite a future-version work folder as version 8.
    func testWorkFolderState_migratesVersionForwardButNeverBackward() throws {
        let decoder = JSONCoderFactory.makeDateDecoder()

        let legacy = try decoder.decode(WorkFolderState.self, from: Data("{}".utf8))
        XCTAssertGreaterThanOrEqual(legacy.schemaVersion, 8,
                                    "a legacy decode must migrate the in-memory version forward, or "
                                        + "the legacy branch re-fires on every open (CLAUDE.md #48)")

        let newer = try decoder.decode(
            WorkFolderState.self, from: Data(#"{"schemaVersion":99}"#.utf8))
        XCTAssertEqual(newer.schemaVersion, 99,
                       "a file written by a newer build must keep its version — clamping it down "
                           + "is a silent downgrade of someone else's data")
    }

    /// RED: change `?? ""` on `name` to `?? "Untitled"` → this fails. The empty string is
    /// load-bearing: callers treat it as "derive the name from the folder", and a placeholder
    /// would be persisted as if the user had chosen it.
    func testWorkFolderState_takesEveryDecoderDefault() throws {
        let state = try JSONCoderFactory.makeDateDecoder()
            .decode(WorkFolderState.self, from: Data("{}".utf8))

        XCTAssertEqual(state.name, "")
        XCTAssertEqual(state.lastAppliedAppVersion, "",
                       "an empty applied-version means 'never reconciled', which is what makes the "
                           + "first version-bump pass run")
        XCTAssertNil(state.activeTeamID, "nil active team is resolved to teams.first downstream")
        XCTAssertNil(state.activeTaskID)
        XCTAssertNotNil(state.id, "a missing id must be minted, not left invalid")
    }

    // MARK: - TaskLineage

    /// `normalized()` re-applies the depth clamp after decode, guarding a hand-edited `task.json`
    /// carrying `depth: 99`. The `.root` arm — a plain passthrough — was the uncovered half.
    ///
    /// RED: make the `.root` arm return a `.delegated` value, or drop the clamp from the
    /// `.delegated` arm → the matching assertion fails.
    func testTaskLineageNormalization_clampsDepthAndLeavesRootAlone() {
        XCTAssertEqual(TaskLineage.root.normalized(), .root,
                       "root has no depth to clamp and must pass through untouched")

        let tooDeep = TaskLineage.delegated(parentTaskID: 1, parentRoleID: "r", depth: 99)
        guard case let .delegated(_, _, depth) = tooDeep.normalized() else {
            return XCTFail("normalizing a delegated lineage must stay delegated")
        }
        XCTAssertEqual(depth, DelegationConstants.maxDelegationDepth,
                       "a hand-edited depth must be clamped to the cap, not trusted")

        let tooShallow = TaskLineage.delegated(parentTaskID: 1, parentRoleID: "r", depth: 0)
        guard case let .delegated(_, _, floor) = tooShallow.normalized() else {
            return XCTFail("still delegated")
        }
        XCTAssertEqual(floor, 1,
                       "a delegated task is at least depth 1 — depth 0 is the root's value and "
                           + "would break the (parent == nil) ↔ (depth == 0) invariant")
    }

    /// Normalization must be idempotent, or replaying a decode changes the value.
    func testTaskLineageNormalizationIsIdempotent() {
        for lineage: TaskLineage in [
            .root,
            .delegated(parentTaskID: 1, parentRoleID: "r", depth: 1),
            .delegated(parentTaskID: 2, parentRoleID: "s", depth: 99),
        ] {
            XCTAssertEqual(lineage.normalized(), lineage.normalized().normalized(),
                           "\(lineage) is not idempotent under normalization")
        }
    }

    // MARK: - TeamMessage identity

    /// `TeamMessage` hashes on `id` alone — it is rendered in a `ForEach` over a meeting's
    /// messages, so identity has to survive content edits (a streaming turn is appended to while
    /// on screen). Neither the `hash(into:)` body nor `==` had run.
    ///
    /// RED: fold `content` into `==` → the content-edit assertion fails, and a streaming meeting
    /// message would change identity mid-render.
    func testTeamMessageIdentityIsTheIdAlone() {
        let a = TeamMessage(role: .techLead, content: "first", messageType: .proposal)
        var b = a
        b.content = "edited while streaming"

        XCTAssertEqual(a, b,
                       "identity must survive a content edit, or a streaming meeting message "
                           + "changes ForEach identity mid-render")
        XCTAssertEqual(Set<TeamMessage>([a, b]).count, 1, "hash(into:) must agree with ==")

        let other = TeamMessage(role: .techLead, content: "first", messageType: .proposal)
        XCTAssertNotEqual(a, other,
                          "two separately created messages with identical content are still "
                              + "different messages")
        XCTAssertEqual(Set<TeamMessage>([a, other]).count, 2)
    }

    // MARK: - RecurrenceRule branch arms

    /// The weekday-matching loop bails after 8 candidate probes so an empty-after-filter weekday
    /// set cannot spin forever. That guard is what makes a degenerate rule *self-disable* rather
    /// than hang the scheduler.
    ///
    /// RED: remove the `for _ in 0..<8` bound → this test hangs instead of failing, which is why
    /// the bound exists.
    func testDailyAtWithAnUnmatchableWeekdaySet_resolvesToNoNextDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let reference = Date(timeIntervalSince1970: 1_786_000_000)

        // Weekday 9 does not exist (Calendar weekdays are 1...7), so no candidate can ever match.
        let impossible = RecurrenceRule.dailyAt(hour: 21, minute: 0, weekdays: [9])
        XCTAssertNil(impossible.nextFireDate(after: reference, calendar: calendar),
                     "an unmatchable weekday set must resolve to nil so TaskRecurrence.reschedule "
                         + "self-disables, instead of staying enabled and never firing")

        // The reachable neighbour, so the test above is not passing for the wrong reason.
        let everyDay = RecurrenceRule.dailyAt(hour: 21, minute: 0, weekdays: [])
        XCTAssertNotNil(everyDay.nextFireDate(after: reference, calendar: calendar),
                        "an empty weekday set means EVERY day, not no day")
    }

    /// `.monthlyAt` walks forward a month at a time and gives up rather than looping. A day past
    /// the end of a month must land inside the month, which is the clamp the doc promises.
    func testMonthlyAtClampsToTheMonthLength() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2026-01-15
        let reference = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!

        let rule = RecurrenceRule.monthlyAt(day: 31, hour: 23, minute: 0)
        guard let next = rule.nextFireDate(after: reference, calendar: calendar) else {
            return XCTFail("a monthly rule must resolve a next date from mid-January")
        }
        let day = calendar.component(.day, from: next)
        let month = calendar.component(.month, from: next)
        XCTAssertEqual(month, 1, "the next 31st after Jan 15 is still in January")
        XCTAssertEqual(day, 31)

        // February has no 31st: the clamp must land on the last day, not skip the month.
        let feb = calendar.date(from: DateComponents(year: 2026, month: 2, day: 1))!
        guard let inFeb = rule.nextFireDate(after: feb, calendar: calendar) else {
            return XCTFail("February must still resolve — the day is clamped, not skipped")
        }
        XCTAssertEqual(calendar.component(.month, from: inFeb), 2)
        XCTAssertEqual(calendar.component(.day, from: inFeb), 28,
                       "day 31 in a 28-day month clamps to the month length")
    }
}
