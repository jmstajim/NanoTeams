import XCTest

@testable import NanoTeams

/// Deterministic next-fire math for `RecurrenceRule`, exercised with a fixed UTC
/// Gregorian calendar + explicit reference dates so there is no wall-clock or
/// locale dependence.
final class RecurrenceRuleTests: XCTestCase {

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

    // MARK: - Interval

    func testInterval_addsSeconds() {
        let ref = date(2026, 1, 1, 8, 0)
        let next = RecurrenceRule.interval(seconds: 3_600).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, ref.addingTimeInterval(3_600))
    }

    func testInterval_clampsToMinimum() {
        let ref = date(2026, 1, 1, 8, 0)
        // Below the 60s floor → clamped to 60s.
        let next = RecurrenceRule.interval(seconds: 5).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, ref.addingTimeInterval(RecurrenceRule.minIntervalSeconds))
    }

    // MARK: - Once

    func testOnce_futureReturnsDate() {
        let ref = date(2026, 1, 1, 8, 0)
        let target = date(2026, 1, 1, 9, 0)
        XCTAssertEqual(RecurrenceRule.once(date: target).nextFireDate(after: ref, calendar: cal), target)
    }

    func testOnce_pastReturnsNil() {
        let ref = date(2026, 1, 1, 8, 0)
        let target = date(2026, 1, 1, 7, 0)
        XCTAssertNil(RecurrenceRule.once(date: target).nextFireDate(after: ref, calendar: cal))
    }

    func testOnce_isNotRepeating() {
        XCTAssertFalse(RecurrenceRule.once(date: date(2026, 1, 1, 9, 0)).isRepeating)
        XCTAssertTrue(RecurrenceRule.interval(seconds: 60).isRepeating)
        XCTAssertTrue(RecurrenceRule.dailyAt(hour: 9, minute: 0, weekdays: []).isRepeating)
    }

    // MARK: - Daily

    func testDailyAt_sameDayWhenTimeNotYetPassed() {
        let ref = date(2026, 1, 1, 8, 0)
        let next = RecurrenceRule.dailyAt(hour: 9, minute: 0, weekdays: []).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2026, 1, 1, 9, 0))
    }

    func testDailyAt_rollsToNextDayWhenTimePassed() {
        let ref = date(2026, 1, 1, 8, 0)
        let next = RecurrenceRule.dailyAt(hour: 7, minute: 0, weekdays: []).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2026, 1, 2, 7, 0))
    }

    func testDailyAt_restrictedToWeekdayPicksNextMatchingDay() {
        // 2026-01-01 is a Thursday (weekday 5). Restrict to Friday (weekday 6).
        let ref = date(2026, 1, 1, 8, 0)
        let next = RecurrenceRule.dailyAt(hour: 9, minute: 0, weekdays: [6]).nextFireDate(after: ref, calendar: cal)
        let unwrapped = try? XCTUnwrap(next)
        XCTAssertNotNil(unwrapped)
        if let unwrapped {
            XCTAssertEqual(cal.component(.weekday, from: unwrapped), 6, "Must land on Friday")
            XCTAssertGreaterThan(unwrapped, ref)
            XCTAssertEqual(unwrapped, date(2026, 1, 2, 9, 0))
        }
    }

    // MARK: - Monthly

    func testMonthlyAt_sameMonthWhenDayAhead() {
        let ref = date(2026, 1, 15, 10, 0)
        let next = RecurrenceRule.monthlyAt(day: 20, hour: 9, minute: 0).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2026, 1, 20, 9, 0))
    }

    func testMonthlyAt_rollsToNextMonthWhenDayPassed() {
        let ref = date(2026, 1, 15, 10, 0)
        let next = RecurrenceRule.monthlyAt(day: 10, hour: 9, minute: 0).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2026, 2, 10, 9, 0))
    }

    func testMonthlyAt_clampsDayToShortMonth() {
        // Day 31 from late January → February 2026 has only 28 days (not leap).
        let ref = date(2026, 1, 31, 12, 0)
        let next = RecurrenceRule.monthlyAt(day: 31, hour: 9, minute: 0).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2026, 2, 28, 9, 0))
    }

    // MARK: - Corner cases

    func testInterval_exactlyMinimum_notFurtherClamped() {
        let ref = date(2026, 1, 1, 8, 0)
        let next = RecurrenceRule.interval(seconds: 60).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, ref.addingTimeInterval(60))
    }

    func testInterval_alignsToMinuteGrid_fromOffsetReference() {
        // 08:00:37 with a 60s interval snaps to 08:01:00 (the minute boundary),
        // NOT 08:01:37 — fires are grid-aligned and never drift.
        let ref = cal.date(byAdding: .second, value: 37, to: date(2026, 1, 1, 8, 0))!
        let next = RecurrenceRule.interval(seconds: 60).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2026, 1, 1, 8, 1))
    }

    func testInterval_alignsToHourGrid_fromOffsetReference() {
        // 08:20 with a 3600s interval snaps to 09:00, not 09:20.
        let ref = date(2026, 1, 1, 8, 20)
        let next = RecurrenceRule.interval(seconds: 3_600).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2026, 1, 1, 9, 0))
    }

    func testDailyAt_exactlyAtBoundary_rollsToNextDay() {
        // `after:` is exclusive — a reference sitting exactly on hh:mm must roll forward.
        let ref = date(2026, 1, 1, 9, 0)
        let next = RecurrenceRule.dailyAt(hour: 9, minute: 0, weekdays: []).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2026, 1, 2, 9, 0))
    }

    func testDailyAt_weekdayMatchesRefDayButTimePassed_rollsAWeek() {
        // 2026-01-01 is Thursday (weekday 5), restricted to Thursday, but 09:00
        // already passed at the 10:00 reference → next Thursday a week later.
        let ref = date(2026, 1, 1, 10, 0)
        let next = RecurrenceRule.dailyAt(hour: 9, minute: 0, weekdays: [5]).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2026, 1, 8, 9, 0))
        XCTAssertEqual(cal.component(.weekday, from: next!), 5)
    }

    func testDailyAt_allWeekdaysSelected_behavesLikeDaily() {
        let ref = date(2026, 1, 1, 8, 0)
        let next = RecurrenceRule.dailyAt(hour: 7, minute: 0, weekdays: [1, 2, 3, 4, 5, 6, 7]).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2026, 1, 2, 7, 0), "every-weekday set with a passed time rolls to tomorrow, like plain daily")
    }

    func testDailyAt_weekdayWrapsAcrossWeekStart() {
        // 2026-01-03 is Saturday (weekday 7); restrict to Sunday (weekday 1) → next day.
        let ref = date(2026, 1, 3, 12, 0)
        let next = RecurrenceRule.dailyAt(hour: 9, minute: 0, weekdays: [1]).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(cal.component(.weekday, from: next!), 1)
        XCTAssertEqual(next, date(2026, 1, 4, 9, 0))
    }

    func testMonthlyAt_sameDayButTimePassed_rollsToNextMonth() {
        let ref = date(2026, 1, 20, 10, 0)
        let next = RecurrenceRule.monthlyAt(day: 20, hour: 9, minute: 0).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2026, 2, 20, 9, 0))
    }

    func testMonthlyAt_rollsAcrossYearBoundary() {
        let ref = date(2026, 12, 15, 10, 0)
        let next = RecurrenceRule.monthlyAt(day: 1, hour: 9, minute: 0).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2027, 1, 1, 9, 0))
    }

    func testMonthlyAt_leapYear_day29Exists() {
        // 2028 is a leap year — Feb 29 exists, so day 29 must NOT be clamped to 28.
        let ref = date(2028, 1, 31, 12, 0)
        let next = RecurrenceRule.monthlyAt(day: 29, hour: 9, minute: 0).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2028, 2, 29, 9, 0))
    }

    func testIsRepeating_monthly() {
        XCTAssertTrue(RecurrenceRule.monthlyAt(day: 1, hour: 9, minute: 0).isRepeating)
    }

    // MARK: - Summary (locale-independent shapes)

    func testSummary_interval() {
        XCTAssertEqual(RecurrenceRule.interval(seconds: 60).summary, "Every minute")
        XCTAssertEqual(RecurrenceRule.interval(seconds: 120).summary, "Every 2 minutes")
        XCTAssertEqual(RecurrenceRule.interval(seconds: 3_600).summary, "Every hour")
        XCTAssertEqual(RecurrenceRule.interval(seconds: 7_200).summary, "Every 2 hours")
        XCTAssertEqual(RecurrenceRule.interval(seconds: 86_400).summary, "Every day")
        XCTAssertEqual(RecurrenceRule.interval(seconds: 172_800).summary, "Every 2 days")
    }

    func testSummary_dailyEveryDay() {
        XCTAssertEqual(RecurrenceRule.dailyAt(hour: 9, minute: 5, weekdays: []).summary, "Daily at 09:05")
    }

    func testSummary_monthly() {
        XCTAssertEqual(RecurrenceRule.monthlyAt(day: 1, hour: 10, minute: 0).summary, "Monthly on day 1 at 10:00")
    }

    func testSummary_weekdays_namesDaysNotDaily() {
        let summary = RecurrenceRule.dailyAt(hour: 9, minute: 0, weekdays: [2, 6]).summary
        XCTAssertTrue(summary.contains("at 09:00"))
        XCTAssertFalse(summary.hasPrefix("Daily"), "with explicit weekdays it should list days, not say Daily")
    }

    // MARK: - Codable (synthesized enum-with-associated-values)

    // MARK: - More corner cases

    func testDailyAt_outOfRangeWeekdaySet_returnsNil() {
        // A weekday set with no value in 1...7 can never match → the 8-iteration
        // cap returns nil. This is the rule-level nil the `reschedule` self-disable
        // (review H2) relies on.
        let ref = date(2026, 1, 1, 8, 0)
        XCTAssertNil(RecurrenceRule.dailyAt(hour: 9, minute: 0, weekdays: [8, 9]).nextFireDate(after: ref, calendar: cal))
    }

    func testDailyAt_dstSpringForward_resolvesRealFutureFire() {
        // On the US spring-forward day (2026-03-08) the wall-clock time 02:30 does
        // not exist — clocks jump 02:00 → 03:00. `.nextTime` must still resolve a
        // real future fire (not nil, not a crash); a scheduled task can't silently
        // die on a DST boundary.
        var dst = Calendar(identifier: .gregorian)
        dst.timeZone = TimeZone(identifier: "America/New_York")!
        var refComps = DateComponents()
        refComps.year = 2026; refComps.month = 3; refComps.day = 8
        refComps.hour = 0; refComps.minute = 0; refComps.second = 0
        let ref = dst.date(from: refComps)!

        let next = RecurrenceRule.dailyAt(hour: 2, minute: 30, weekdays: []).nextFireDate(after: ref, calendar: dst)

        XCTAssertNotNil(next, "a non-existent wall-clock time on a DST day still resolves a future fire")
        if let next { XCTAssertGreaterThan(next, ref) }
    }

    func testMonthlyAt_clampsDayToThirtyDayMonth() {
        // Day 31 from late March → April has only 30 days → clamps to April 30
        // (complements the 28-day February + 29-day leap cases above).
        let ref = date(2026, 3, 31, 12, 0)
        let next = RecurrenceRule.monthlyAt(day: 31, hour: 9, minute: 0).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2026, 4, 30, 9, 0))
    }

    func testInterval_alignsToFiveMinuteGrid_fromOffsetReference() {
        // 08:02:30 with a 300s (5-min) interval snaps to 08:05:00 — the grid is
        // multiples of the step, not offsets from the reference.
        let ref = cal.date(byAdding: .second, value: 150, to: date(2026, 1, 1, 8, 0))! // 08:02:30
        let next = RecurrenceRule.interval(seconds: 300).nextFireDate(after: ref, calendar: cal)
        XCTAssertEqual(next, date(2026, 1, 1, 8, 5))
    }

    func testSummary_intervalNonDivisor_fallsBackToSmallerUnit() {
        // 90 min is not a whole hour → "minutes"; 25 h is not a whole day → "hours".
        XCTAssertEqual(RecurrenceRule.interval(seconds: 5_400).summary, "Every 90 minutes")
        XCTAssertEqual(RecurrenceRule.interval(seconds: 90_000).summary, "Every 25 hours")
    }

    func testCodableRoundTrip_allCases() throws {
        let cases: [RecurrenceRule] = [
            .interval(seconds: 3_600),
            .dailyAt(hour: 9, minute: 30, weekdays: [2, 4, 6]),
            .dailyAt(hour: 0, minute: 0, weekdays: []),
            .monthlyAt(day: 15, hour: 18, minute: 45),
            .once(date: date(2026, 6, 1, 12, 0)),
        ]
        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let decoder = JSONCoderFactory.makeDateDecoder()
        for rule in cases {
            let data = try encoder.encode(rule)
            let decoded = try decoder.decode(RecurrenceRule.self, from: data)
            XCTAssertEqual(decoded, rule, "round-trip must preserve \(rule)")
        }
    }
}
