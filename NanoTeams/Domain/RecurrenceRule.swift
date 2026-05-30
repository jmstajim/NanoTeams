import Foundation

/// How a recurring task repeats. Pure value type — the next-fire math is
/// deterministic given an explicit `reference` date + `calendar`, so it is
/// fully testable without touching wall-clock time.
///
/// Weekday integers follow `Calendar`'s convention: 1 = Sunday … 7 = Saturday.
nonisolated enum RecurrenceRule: Codable, Hashable {
    /// Every N seconds, aligned to a fixed wall-clock grid (multiples of N since
    /// the epoch) so fires land on a stable boundary and never drift with run
    /// duration or poll timing. Floored to a 1-minute minimum. "через период".
    case interval(seconds: TimeInterval)
    /// A time of day, optionally restricted to specific weekdays.
    /// `weekdays` empty = every day.
    case dailyAt(hour: Int, minute: Int, weekdays: Set<Int>)
    /// A day-of-month + time of day. `day` is clamped to each month's length
    /// (e.g. 31 → 28/29/30 in shorter months).
    case monthlyAt(day: Int, hour: Int, minute: Int)
    /// A single one-shot fire at an absolute date/time.
    case once(date: Date)

    /// Smallest allowed interval and the schedule granularity floor (1 minute).
    static let minIntervalSeconds: TimeInterval = 60

    /// `false` only for `.once` — every other rule repeats indefinitely.
    var isRepeating: Bool {
        if case .once = self { return false }
        return true
    }

    /// The first fire strictly after `reference`, or `nil` when there is no
    /// future occurrence (a `.once` whose date has already passed, or a
    /// degenerate weekday/month search that can't resolve).
    func nextFireDate(after reference: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case let .interval(seconds):
            // Align to a stable grid (multiples of `step` since the epoch) so
            // fires land on a fixed boundary — the minute mark for a 60s
            // interval, the hour for 3600s — and never drift with poll timing or
            // run duration. Returns the next grid point strictly after `reference`.
            let step = max(seconds, Self.minIntervalSeconds)
            let ref = reference.timeIntervalSince1970
            return Date(timeIntervalSince1970: (floor(ref / step) + 1) * step)

        case let .dailyAt(hour, minute, weekdays):
            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            if weekdays.isEmpty {
                return calendar.nextDate(after: reference, matching: comps, matchingPolicy: .nextTime)
            }
            // Walk forward day-by-day from the next hh:mm match until the
            // weekday is in the set. Cap at 8 (a full week + 1) so a malformed
            // empty-after-filter set can't loop forever.
            var candidate = reference
            for _ in 0..<8 {
                guard let next = calendar.nextDate(after: candidate, matching: comps, matchingPolicy: .nextTime) else {
                    return nil
                }
                if weekdays.contains(calendar.component(.weekday, from: next)) {
                    return next
                }
                candidate = next
            }
            return nil

        case let .monthlyAt(day, hour, minute):
            return Self.nextMonthly(day: day, hour: hour, minute: minute, after: reference, calendar: calendar)

        case let .once(date):
            return date > reference ? date : nil
        }
    }

    /// Next monthly occurrence: tries the reference month, then subsequent
    /// months, clamping `day` to each month's actual length.
    private static func nextMonthly(day: Int, hour: Int, minute: Int, after reference: Date, calendar: Calendar) -> Date? {
        var monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: reference)) ?? reference
        for _ in 0..<13 {
            if let range = calendar.range(of: .day, in: .month, for: monthStart) {
                var comps = calendar.dateComponents([.year, .month], from: monthStart)
                comps.day = min(day, range.count)
                comps.hour = hour
                comps.minute = minute
                comps.second = 0
                if let candidate = calendar.date(from: comps), candidate > reference {
                    return candidate
                }
            }
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return nil }
            monthStart = nextMonth
        }
        return nil
    }

    /// Human-readable label for the toolbar `.help` tooltip and any inline
    /// schedule display.
    var summary: String {
        switch self {
        case let .interval(seconds):
            return Self.intervalSummary(seconds)
        case let .dailyAt(hour, minute, weekdays):
            let time = Self.timeLabel(hour: hour, minute: minute)
            if weekdays.isEmpty { return "Daily at \(time)" }
            return "\(Self.weekdayLabel(weekdays)) at \(time)"
        case let .monthlyAt(day, hour, minute):
            return "Monthly on day \(day) at \(Self.timeLabel(hour: hour, minute: minute))"
        case let .once(date):
            return "Once on \(date.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    private static func intervalSummary(_ seconds: TimeInterval) -> String {
        let s = Int(max(seconds, minIntervalSeconds).rounded())
        if s % 86_400 == 0 { let d = s / 86_400; return d == 1 ? "Every day" : "Every \(d) days" }
        if s % 3_600 == 0 { let h = s / 3_600; return h == 1 ? "Every hour" : "Every \(h) hours" }
        let m = max(1, s / 60); return m == 1 ? "Every minute" : "Every \(m) minutes"
    }

    private static func timeLabel(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    private static func weekdayLabel(_ weekdays: Set<Int>) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols // index 0 = Sunday
        let names = weekdays.sorted().compactMap { wd -> String? in
            (1...7).contains(wd) ? symbols[wd - 1] : nil
        }
        return names.isEmpty ? "Daily" : names.joined(separator: ", ")
    }
}
