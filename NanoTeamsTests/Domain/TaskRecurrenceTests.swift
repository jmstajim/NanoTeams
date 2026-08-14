import XCTest

@testable import NanoTeams

final class TaskRecurrenceTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return cal.date(from: c)!
    }

    func testReschedule_setsNextFireForRepeatingRule() {
        var rec = TaskRecurrence(rule: .interval(seconds: 3_600))
        // Hour-aligned reference: `.interval` snaps to the epoch grid, so
        // `ref + 3600` is the answer only while `ref` is already on that grid.
        let ref = date(2026, 1, 1, 20, 0)
        rec.reschedule(after: ref, calendar: cal)
        XCTAssertEqual(rec.nextFireAt, ref.addingTimeInterval(3_600))
        XCTAssertTrue(rec.isEnabled)
    }

    func testReschedule_pastOnceDisablesAndClearsNextFire() {
        var rec = TaskRecurrence(rule: .once(date: date(2026, 1, 1, 20, 0)))
        rec.reschedule(after: date(2026, 1, 1, 20, 30), calendar: cal)
        XCTAssertNil(rec.nextFireAt)
        XCTAssertFalse(rec.isEnabled, "A one-shot whose date has passed must self-disable")
    }

    func testReschedule_futureOnceStaysEnabled() {
        var rec = TaskRecurrence(rule: .once(date: date(2026, 1, 1, 21, 0)))
        rec.reschedule(after: date(2026, 1, 1, 20, 30), calendar: cal)
        XCTAssertEqual(rec.nextFireAt, date(2026, 1, 1, 21, 0))
        XCTAssertTrue(rec.isEnabled)
    }

    func testIsDue() {
        let now = date(2026, 1, 1, 20, 30)
        XCTAssertTrue(TaskRecurrence(rule: .interval(seconds: 60), nextFireAt: now.addingTimeInterval(-1)).isDue(now: now))
        XCTAssertFalse(TaskRecurrence(rule: .interval(seconds: 60), nextFireAt: now.addingTimeInterval(60)).isDue(now: now))
        XCTAssertFalse(TaskRecurrence(rule: .interval(seconds: 60), isEnabled: false, nextFireAt: now.addingTimeInterval(-1)).isDue(now: now))
        XCTAssertFalse(TaskRecurrence(rule: .interval(seconds: 60), nextFireAt: nil).isDue(now: now))
    }

    func testCodableRoundTrip() throws {
        let rec = TaskRecurrence(
            rule: .dailyAt(hour: 21, minute: 30, weekdays: [2, 4, 6]),
            isEnabled: true,
            nextFireAt: date(2026, 1, 2, 21, 30),
            lastFiredAt: date(2026, 1, 1, 21, 30)
        )
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(rec)
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(TaskRecurrence.self, from: data)
        XCTAssertEqual(decoded, rec)
    }

    func testReschedule_dailyAt() {
        var rec = TaskRecurrence(rule: .dailyAt(hour: 21, minute: 0, weekdays: []))
        rec.reschedule(after: date(2026, 1, 1, 20, 30), calendar: cal)
        XCTAssertEqual(rec.nextFireAt, date(2026, 1, 1, 21, 0))
        XCTAssertTrue(rec.isEnabled)
    }

    func testReschedule_monthly() {
        var rec = TaskRecurrence(rule: .monthlyAt(day: 20, hour: 21, minute: 0))
        rec.reschedule(after: date(2026, 1, 15, 22, 0), calendar: cal)
        XCTAssertEqual(rec.nextFireAt, date(2026, 1, 20, 21, 0))
    }

    func testIsDue_exactBoundaryEquality_isDue() {
        let now = date(2026, 1, 1, 20, 30)
        // nextFireAt == now → due (the comparison is `<=`).
        XCTAssertTrue(TaskRecurrence(rule: .interval(seconds: 60), nextFireAt: now).isDue(now: now))
    }

    // MARK: - Degenerate repeating rule self-disables (review H2)

    func testReschedule_degenerateRepeatingRule_selfDisables() {
        // A *repeating* rule that can never resolve (a corrupt/imported weekday
        // set outside 1...7 — unreachable from the editor, reachable from a
        // hand-edited or migrated task.json) must self-disable. Leaving it
        // `isEnabled` with `nextFireAt == nil` would silently drop it from BOTH
        // the scheduler scan and the sidebar badge while still reading as "on".
        var rec = TaskRecurrence(rule: .dailyAt(hour: 21, minute: 0, weekdays: [8]))
        rec.reschedule(after: date(2026, 1, 1, 20, 30), calendar: cal)
        XCTAssertNil(rec.nextFireAt, "an unresolvable weekday set yields no future fire")
        XCTAssertFalse(rec.isEnabled, "a repeating rule with no resolvable future self-disables — no silent dead-enabled state")
    }

    func testReschedule_healthyRepeatingRule_staysEnabled() {
        // Guard against over-disabling: the broadened self-disable must NOT touch
        // a repeating rule that resolves to a real future fire.
        var rec = TaskRecurrence(rule: .dailyAt(hour: 21, minute: 0, weekdays: [6]))
        rec.reschedule(after: date(2026, 1, 1, 20, 30), calendar: cal)
        XCTAssertNotNil(rec.nextFireAt, "a valid weekday set resolves a future fire")
        XCTAssertTrue(rec.isEnabled, "a healthy repeating rule stays enabled")
    }
}
