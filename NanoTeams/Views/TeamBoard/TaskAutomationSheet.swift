import SwiftUI

/// Task-detail sheet for the two automation controls: a recurrence schedule
/// (re-run this task on a timer / time-of-day / monthly / once) and a per-run
/// timeout. Matches the local TeamBoard sheet convention (`RestartRoleSheet` /
/// `CorrectRoleSheet`): `@Binding isPresented` + an `onSave` callback so the
/// parent owns the orchestrator mutation. Editable state lives inside the sheet
/// as a single draft value, seeded from the task's current settings in `init`.
struct TaskAutomationSheet: View {
    @Binding var isPresented: Bool
    let onSave: (TaskRecurrence?, TimeInterval?) -> Void

    @State private var draft: AutomationDraft

    init(
        currentRecurrence: TaskRecurrence?,
        currentTimeoutSeconds: TimeInterval?,
        isPresented: Binding<Bool>,
        onSave: @escaping (TaskRecurrence?, TimeInterval?) -> Void
    ) {
        self._isPresented = isPresented
        self.onSave = onSave
        self._draft = State(initialValue: AutomationDraft(
            recurrence: currentRecurrence,
            timeoutSeconds: currentTimeoutSeconds
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SheetHeader(
                title: "Automation",
                subtitle: "Repeat this task on a schedule, or limit how long a single run may take",
                systemImage: "arrow.triangle.2.circlepath",
                tintColor: Colors.accent
            )

            repeatSection
            TerminalDivider()
            timeoutSection

            HStack {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.terminalSecondary)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    onSave(draft.toRecurrence(), draft.toTimeoutSeconds())
                    isPresented = false
                }
                .buttonStyle(.terminalPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.l)
        .frame(width: SheetLayout.standardWidth)
    }

    // MARK: - Repeat

    private var repeatSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Toggle(isOn: $draft.repeatEnabled) {
                Text("Repeat")
                    .font(Typography.subheadlineMedium)
            }
            .toggleStyle(.terminal)

            if draft.repeatEnabled {
                TerminalSegmentedPicker(
                    selection: $draft.kind,
                    options: AutomationDraft.Kind.allCases.map { ($0, $0.label) }
                )

                Group {
                    switch draft.kind {
                    case .interval: intervalEditor
                    case .timeOfDay: timeOfDayEditor
                    case .monthly: monthlyEditor
                    case .once: onceEditor
                    }
                }

                nextRunLabel
            }
        }
    }

    private var intervalEditor: some View {
        HStack(spacing: Spacing.s) {
            Text("Every")
                .foregroundStyle(Colors.textSecondary)
            Text("\(draft.intervalHours) h")
                .monospacedDigit()
            TerminalStepperButtons(value: intervalHoursBinding, range: 0...999)
            Text("\(draft.intervalMinutes) m")
                .monospacedDigit()
            TerminalStepperButtons(value: intervalMinutesBinding, range: 0...59)
        }
    }

    private var timeOfDayEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text("At")
                    .foregroundStyle(Colors.textSecondary)
                TerminalDatePicker(selection: $draft.timeOfDay, components: .hourAndMinute)
            }
            HStack(spacing: Spacing.xs) {
                ForEach(AutomationDraft.weekdayOrder, id: \.self) { wd in
                    Toggle(AutomationDraft.weekdaySymbol(wd), isOn: weekdayBinding(wd))
                        .toggleStyle(.terminalChip)
                        .accessibilityLabel(AutomationDraft.weekdayName(wd))
                }
            }
            Text(draft.weekdays.isEmpty ? "Every day" : "Selected days only")
                .font(Typography.caption2)
                .foregroundStyle(Colors.textTertiary)
        }
    }

    private var monthlyEditor: some View {
        HStack(spacing: Spacing.s) {
            Text("On day")
                .foregroundStyle(Colors.textSecondary)
            Text("\(draft.dayOfMonth)")
                .monospacedDigit()
            TerminalStepperButtons(value: $draft.dayOfMonth, range: 1...31)
            Text("at")
                .foregroundStyle(Colors.textSecondary)
            TerminalDatePicker(selection: $draft.timeOfDay, components: .hourAndMinute)
        }
    }

    private var onceEditor: some View {
        TerminalDatePicker(selection: $draft.onceDate, components: [.date, .hourAndMinute])
    }

    @ViewBuilder
    private var nextRunLabel: some View {
        if let next = draft.previewNextFire() {
            Text("Next run: \(next.formatted(date: .abbreviated, time: .shortened))")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
        } else {
            Text("This schedule has no upcoming run (the date is in the past).")
                .font(Typography.caption)
                .foregroundStyle(Colors.warning)
        }
    }

    private func weekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { draft.weekdays.contains(weekday) },
            set: { isOn in
                if isOn { draft.weekdays.insert(weekday) } else { draft.weekdays.remove(weekday) }
            }
        )
    }

    // MARK: - Hours/minutes bindings (enforce a 1-minute floor — never 0h 0m)
    //
    // Minutes can be 0 only when hours ≥ 1, so the total is always ≥ 1 minute.
    // The moment a change lands on 0h 0m we snap minutes back to 1, so the UI
    // never displays a meaningless "every 0h 0m" / "pause after 0h 0m".

    private var intervalHoursBinding: Binding<Int> {
        Binding(get: { draft.intervalHours }, set: { draft.intervalHours = $0; floorInterval() })
    }
    private var intervalMinutesBinding: Binding<Int> {
        Binding(get: { draft.intervalMinutes }, set: { draft.intervalMinutes = $0; floorInterval() })
    }
    private func floorInterval() {
        if draft.intervalHours == 0 && draft.intervalMinutes == 0 { draft.intervalMinutes = 1 }
    }

    private var timeoutHoursBinding: Binding<Int> {
        Binding(get: { draft.timeoutHours }, set: { draft.timeoutHours = $0; floorTimeout() })
    }
    private var timeoutMinutesBinding: Binding<Int> {
        Binding(get: { draft.timeoutMinutes }, set: { draft.timeoutMinutes = $0; floorTimeout() })
    }
    private func floorTimeout() {
        if draft.timeoutHours == 0 && draft.timeoutMinutes == 0 { draft.timeoutMinutes = 1 }
    }

    // MARK: - Timeout

    private var timeoutSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Toggle(isOn: $draft.timeoutEnabled) {
                Text("Run timeout")
                    .font(Typography.subheadlineMedium)
            }
            .toggleStyle(.terminal)

            if draft.timeoutEnabled {
                HStack(spacing: Spacing.m) {
                    Text("Pause after")
                        .foregroundStyle(Colors.textSecondary)
                    Text("\(draft.timeoutHours) h")
                        .monospacedDigit()
                    TerminalStepperButtons(value: timeoutHoursBinding, range: 0...999)
                    Text("\(draft.timeoutMinutes) m")
                        .monospacedDigit()
                    TerminalStepperButtons(value: timeoutMinutesBinding, range: 0...59)
                }
                Text("If a run lasts longer, it's paused and you're notified.")
                    .font(Typography.caption2)
                    .foregroundStyle(Colors.textTertiary)
            }
        }
    }
}

// MARK: - Draft

/// Mutable working state for the sheet — decomposes a `TaskRecurrence` /
/// timeout into editable fields and re-composes them on save.
struct AutomationDraft {
    enum Kind: String, CaseIterable, Identifiable {
        case interval, timeOfDay, monthly, once
        var id: String { rawValue }
        var label: String {
            switch self {
            case .interval: return "Interval"
            case .timeOfDay: return "Time of day"
            case .monthly: return "Monthly"
            case .once: return "Once"
            }
        }
    }

    var repeatEnabled: Bool
    var kind: Kind
    /// Interval is edited as hours + minutes (1-minute granularity), so values
    /// like "1 h 1 m" or "10 h 1 m" are expressible — a single value+unit picker
    /// can't represent those.
    var intervalHours: Int
    var intervalMinutes: Int
    var timeOfDay: Date
    var weekdays: Set<Int>
    var dayOfMonth: Int
    var onceDate: Date

    var timeoutEnabled: Bool
    var timeoutHours: Int
    var timeoutMinutes: Int

    init(recurrence: TaskRecurrence?, timeoutSeconds: TimeInterval?) {
        let calendar = Calendar.current
        // Defaults: 9:00 today, one hour out for one-shot.
        let defaultTime = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()

        self.repeatEnabled = recurrence?.isEnabled ?? false
        self.kind = .interval
        self.intervalHours = 1
        self.intervalMinutes = 0
        self.timeOfDay = defaultTime
        self.weekdays = []
        self.dayOfMonth = 1
        self.onceDate = Date().addingTimeInterval(3_600)

        if let rule = recurrence?.rule {
            switch rule {
            case let .interval(seconds):
                self.kind = .interval
                let totalMinutes = Int(max(seconds, RecurrenceRule.minIntervalSeconds)) / 60
                self.intervalHours = totalMinutes / 60
                self.intervalMinutes = totalMinutes % 60
            case let .dailyAt(hour, minute, weekdays):
                self.kind = .timeOfDay
                self.weekdays = weekdays
                self.timeOfDay = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? defaultTime
            case let .monthlyAt(day, hour, minute):
                self.kind = .monthly
                self.dayOfMonth = min(max(day, 1), 31)
                self.timeOfDay = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? defaultTime
            case let .once(date):
                self.kind = .once
                self.onceDate = date
            }
        }

        if let timeoutSeconds {
            self.timeoutEnabled = true
            let totalMinutes = Int(max(timeoutSeconds, RecurrenceRule.minIntervalSeconds)) / 60
            self.timeoutHours = totalMinutes / 60
            self.timeoutMinutes = totalMinutes % 60
        } else {
            self.timeoutEnabled = false
            self.timeoutHours = 0
            self.timeoutMinutes = 30
        }
    }

    private func buildRule() -> RecurrenceRule {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute], from: timeOfDay)
        let hour = comps.hour ?? 9
        let minute = comps.minute ?? 0
        switch kind {
        case .interval:
            let seconds = Double((intervalHours * 60 + intervalMinutes) * 60)
            return .interval(seconds: max(seconds, RecurrenceRule.minIntervalSeconds))
        case .timeOfDay:
            return .dailyAt(hour: hour, minute: minute, weekdays: weekdays)
        case .monthly:
            return .monthlyAt(day: dayOfMonth, hour: hour, minute: minute)
        case .once:
            return .once(date: onceDate)
        }
    }

    /// The recurrence to persist, or `nil` when repeat is disabled. `nextFireAt`
    /// is left for the orchestrator to compute via `setTaskRecurrence`.
    func toRecurrence() -> TaskRecurrence? {
        guard repeatEnabled else { return nil }
        return TaskRecurrence(rule: buildRule(), isEnabled: true)
    }

    func toTimeoutSeconds() -> TimeInterval? {
        guard timeoutEnabled else { return nil }
        let seconds = Double((timeoutHours * 60 + timeoutMinutes) * 60)
        return max(seconds, RecurrenceRule.minIntervalSeconds)
    }

    func previewNextFire() -> Date? {
        buildRule().nextFireDate(after: Date())
    }

    // MARK: - Weekday helpers (Calendar weekday: 1 = Sunday … 7 = Saturday)

    static let weekdayOrder: [Int] = [1, 2, 3, 4, 5, 6, 7]

    static func weekdaySymbol(_ weekday: Int) -> String {
        let symbols = Calendar.current.veryShortWeekdaySymbols // index 0 = Sunday
        return (1...7).contains(weekday) ? symbols[weekday - 1] : "?"
    }

    static func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        return (1...7).contains(weekday) ? symbols[weekday - 1] : "Day \(weekday)"
    }
}

#Preview {
    @Previewable @State var isPresented = true
    TaskAutomationSheet(
        currentRecurrence: TaskRecurrence(rule: .dailyAt(hour: 9, minute: 0, weekdays: [2, 3, 4, 5, 6])),
        currentTimeoutSeconds: 1_800,
        isPresented: $isPresented,
        onSave: { _, _ in }
    )
}
