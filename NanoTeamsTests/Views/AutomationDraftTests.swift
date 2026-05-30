import XCTest

@testable import NanoTeams

/// Pure decompose ⇄ recompose logic of `AutomationDraft` (the editable working
/// state behind `TaskAutomationSheet`). The round-trip is the load-bearing
/// invariant: editing a schedule and saving it must not silently mutate it.
///
/// Interval + timeout are edited as hours + minutes (1-minute granularity) so
/// values like "1 h 1 m" / "10 h 1 m" are expressible.
@MainActor
final class AutomationDraftTests: XCTestCase {

    // MARK: - Defaults (no existing settings)

    func testInit_nilInputs_disabledWithSaneDefaults() {
        let draft = AutomationDraft(recurrence: nil, timeoutSeconds: nil)
        XCTAssertFalse(draft.repeatEnabled)
        XCTAssertFalse(draft.timeoutEnabled)
        XCTAssertEqual(draft.kind, .interval)
        XCTAssertNil(draft.toRecurrence(), "repeat disabled → no recurrence")
        XCTAssertNil(draft.toTimeoutSeconds(), "timeout disabled → nil")
    }

    // MARK: - Interval decomposition (hours + minutes)

    func testInit_intervalDecomposesToHoursAndMinutes() {
        assertInterval(seconds: 600, hours: 0, minutes: 10)      // every 10 minutes
        assertInterval(seconds: 3_600, hours: 1, minutes: 0)     // every hour
        assertInterval(seconds: 3_660, hours: 1, minutes: 1)     // 1 h 1 m
        assertInterval(seconds: 36_060, hours: 10, minutes: 1)   // 10 h 1 m
        assertInterval(seconds: 172_800, hours: 48, minutes: 0)  // 2 days as hours
    }

    private func assertInterval(seconds: TimeInterval, hours: Int, minutes: Int, line: UInt = #line) {
        let draft = AutomationDraft(recurrence: TaskRecurrence(rule: .interval(seconds: seconds)), timeoutSeconds: nil)
        XCTAssertEqual(draft.intervalHours, hours, "hours for \(seconds)s", line: line)
        XCTAssertEqual(draft.intervalMinutes, minutes, "minutes for \(seconds)s", line: line)
    }

    // MARK: - Kind decomposition

    func testInit_dailyAt() {
        let draft = AutomationDraft(recurrence: TaskRecurrence(rule: .dailyAt(hour: 9, minute: 30, weekdays: [2, 4, 6])), timeoutSeconds: nil)
        XCTAssertTrue(draft.repeatEnabled)
        XCTAssertEqual(draft.kind, .timeOfDay)
        XCTAssertEqual(draft.weekdays, [2, 4, 6])
        let comps = Calendar.current.dateComponents([.hour, .minute], from: draft.timeOfDay)
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 30)
    }

    func testInit_monthly() {
        let draft = AutomationDraft(recurrence: TaskRecurrence(rule: .monthlyAt(day: 15, hour: 18, minute: 45)), timeoutSeconds: nil)
        XCTAssertEqual(draft.kind, .monthly)
        XCTAssertEqual(draft.dayOfMonth, 15)
    }

    func testInit_once() {
        let target = Date().addingTimeInterval(10_000)
        let draft = AutomationDraft(recurrence: TaskRecurrence(rule: .once(date: target)), timeoutSeconds: nil)
        XCTAssertEqual(draft.kind, .once)
        XCTAssertEqual(draft.onceDate, target)
    }

    // MARK: - Timeout decomposition (hours + minutes)

    func testInit_timeoutDecomposition() {
        let half = AutomationDraft(recurrence: nil, timeoutSeconds: 1_800)
        XCTAssertTrue(half.timeoutEnabled)
        XCTAssertEqual(half.timeoutHours, 0)
        XCTAssertEqual(half.timeoutMinutes, 30)

        let composite = AutomationDraft(recurrence: nil, timeoutSeconds: 3_660)
        XCTAssertEqual(composite.timeoutHours, 1)
        XCTAssertEqual(composite.timeoutMinutes, 1)

        let twoHours = AutomationDraft(recurrence: nil, timeoutSeconds: 7_200)
        XCTAssertEqual(twoHours.timeoutHours, 2)
        XCTAssertEqual(twoHours.timeoutMinutes, 0)
    }

    func testToTimeoutSeconds_recomposes() {
        XCTAssertEqual(AutomationDraft(recurrence: nil, timeoutSeconds: 1_800).toTimeoutSeconds(), 1_800)
        XCTAssertEqual(AutomationDraft(recurrence: nil, timeoutSeconds: 3_660).toTimeoutSeconds(), 3_660)
        XCTAssertEqual(AutomationDraft(recurrence: nil, timeoutSeconds: 7_200).toTimeoutSeconds(), 7_200)
    }

    // MARK: - Round-trip (decompose ∘ recompose == identity)

    func testRoundTrip_preservesRuleForAllKinds() {
        let rules: [RecurrenceRule] = [
            .interval(seconds: 600),       // 10 min
            .interval(seconds: 3_600),     // 1 h
            .interval(seconds: 3_660),     // 1 h 1 m
            .interval(seconds: 36_060),    // 10 h 1 m
            .interval(seconds: 172_800),   // 48 h
            .dailyAt(hour: 9, minute: 30, weekdays: [2, 4, 6]),
            .dailyAt(hour: 0, minute: 0, weekdays: []),
            .monthlyAt(day: 15, hour: 18, minute: 45),
            .once(date: Date().addingTimeInterval(5_000)),
        ]
        for rule in rules {
            let draft = AutomationDraft(recurrence: TaskRecurrence(rule: rule), timeoutSeconds: nil)
            XCTAssertEqual(draft.toRecurrence()?.rule, rule, "decompose∘recompose must preserve \(rule)")
        }
    }

    // MARK: - Composite interval (the user's examples)

    func testToRecurrence_compositeHoursAndMinutes() {
        var draft = AutomationDraft(recurrence: nil, timeoutSeconds: nil)
        draft.repeatEnabled = true
        draft.kind = .interval

        draft.intervalHours = 1
        draft.intervalMinutes = 1
        XCTAssertEqual(draft.toRecurrence()?.rule, .interval(seconds: 3_660), "1 h 1 m → 3660s")

        draft.intervalHours = 10
        draft.intervalMinutes = 1
        XCTAssertEqual(draft.toRecurrence()?.rule, .interval(seconds: 36_060), "10 h 1 m → 36060s")
    }

    func testToRecurrence_clampsToMinimumGranularity() {
        var draft = AutomationDraft(recurrence: nil, timeoutSeconds: nil)
        draft.repeatEnabled = true
        draft.kind = .interval
        draft.intervalHours = 0
        draft.intervalMinutes = 0 // 0 → clamped up to the 1-minute floor
        if case let .interval(seconds) = draft.toRecurrence()!.rule {
            XCTAssertEqual(seconds, 60)
        } else {
            XCTFail("expected interval rule")
        }
    }

    func testToRecurrence_enabledFlagGatesOutput() {
        var draft = AutomationDraft(recurrence: nil, timeoutSeconds: nil)
        draft.kind = .interval
        draft.intervalHours = 2
        draft.intervalMinutes = 0
        XCTAssertNil(draft.toRecurrence(), "repeatEnabled=false suppresses output regardless of fields")
        draft.repeatEnabled = true
        XCTAssertEqual(draft.toRecurrence()?.rule, .interval(seconds: 7_200))
    }

    func testToTimeoutSeconds_clampsToMinimum() {
        var draft = AutomationDraft(recurrence: nil, timeoutSeconds: nil)
        draft.timeoutEnabled = true
        draft.timeoutHours = 0
        draft.timeoutMinutes = 0
        XCTAssertEqual(draft.toTimeoutSeconds(), 60, "0 → clamped to the 1-minute floor")
    }

    // MARK: - Sub-minute truncation (1-minute granularity is intentional)

    func testInit_subMinuteInterval_truncatesToWholeMinutes() {
        // 90s (1 m 30 s) decomposes through whole-minute math → 0 h 1 m, and
        // recomposes to 60s. The 30s is intentionally dropped — the editor works
        // at 1-minute granularity, so this is an *asserted* property, not an
        // accidental loss (round-trip identity only holds on the minute grid).
        let draft = AutomationDraft(recurrence: TaskRecurrence(rule: .interval(seconds: 90)), timeoutSeconds: nil)
        XCTAssertEqual(draft.intervalHours, 0)
        XCTAssertEqual(draft.intervalMinutes, 1, "90s truncates to 1 whole minute")
        XCTAssertEqual(draft.toRecurrence()?.rule, .interval(seconds: 60), "round-trip snaps 90s → 60s")
    }

    func testInit_subMinuteTimeout_truncatesToOneMinute() {
        let draft = AutomationDraft(recurrence: nil, timeoutSeconds: 90)
        XCTAssertEqual(draft.timeoutHours, 0)
        XCTAssertEqual(draft.timeoutMinutes, 1)
        XCTAssertEqual(draft.toTimeoutSeconds(), 60)
    }

    func testToTimeoutSeconds_compositeHoursAndMinutes() {
        var draft = AutomationDraft(recurrence: nil, timeoutSeconds: nil)
        draft.timeoutEnabled = true
        draft.timeoutHours = 2
        draft.timeoutMinutes = 30
        XCTAssertEqual(draft.toTimeoutSeconds(), 9_000, "2 h 30 m → 9000s")
    }

    // MARK: - Past one-shot passes through (orchestrator disables it)

    func testToRecurrence_oncePast_stillEmitsRule() {
        // The editor lets a past .once through; `setTaskRecurrence` reschedules it
        // and `reschedule` self-disables. `buildRule` must NOT silently drop it.
        let past = Date().addingTimeInterval(-10_000)
        let draft = AutomationDraft(recurrence: TaskRecurrence(rule: .once(date: past)), timeoutSeconds: nil)
        XCTAssertTrue(draft.repeatEnabled, "providing any recurrence enables the repeat toggle")
        XCTAssertEqual(draft.toRecurrence()?.rule, .once(date: past))
    }
}
