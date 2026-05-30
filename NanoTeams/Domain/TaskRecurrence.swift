import Foundation

/// Per-task recurrence schedule. Lives on `NTMSTask`; firing re-runs the same
/// task (a new `Run` is appended). `nextFireAt` is the authoritative "when" —
/// recomputed from `rule` on every edit and after every fire/skip.
nonisolated struct TaskRecurrence: Codable, Hashable {
    var rule: RecurrenceRule
    var isEnabled: Bool
    /// Next scheduled fire. `nil` = no future occurrence (e.g. a past `.once`).
    var nextFireAt: Date?
    /// Last time the schedule actually fired (display only).
    var lastFiredAt: Date?

    init(rule: RecurrenceRule, isEnabled: Bool = true, nextFireAt: Date? = nil, lastFiredAt: Date? = nil) {
        self.rule = rule
        self.isEnabled = isEnabled
        self.nextFireAt = nextFireAt
        self.lastFiredAt = lastFiredAt
    }

    enum CodingKeys: String, CodingKey {
        case rule, isEnabled, nextFireAt, lastFiredAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.rule = try c.decode(RecurrenceRule.self, forKey: .rule)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.nextFireAt = try c.decodeIfPresent(Date.self, forKey: .nextFireAt)
        self.lastFiredAt = try c.decodeIfPresent(Date.self, forKey: .lastFiredAt)
    }

    /// Recompute `nextFireAt` from the rule, anchored strictly after `reference`.
    /// Any rule that resolves to no future occurrence self-disables — a past
    /// `.once` (expected), but also a degenerate repeating rule that can never
    /// match (e.g. a corrupt/imported weekday set outside 1...7, or an
    /// unresolvable month): leaving it `isEnabled` with `nextFireAt == nil` would
    /// silently drop it from the scheduler scan AND the sidebar badge while still
    /// claiming to be on. Disabling makes the dead state honest.
    mutating func reschedule(after reference: Date, calendar: Calendar = .current) {
        nextFireAt = rule.nextFireDate(after: reference, calendar: calendar)
        if nextFireAt == nil {
            isEnabled = false
        }
    }

    /// True when enabled and the next fire time has arrived.
    func isDue(now: Date) -> Bool {
        guard isEnabled, let next = nextFireAt else { return false }
        return next <= now
    }
}
