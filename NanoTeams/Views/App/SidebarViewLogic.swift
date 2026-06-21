import Foundation

/// Pure (presentation-free) logic lifted out of `SidebarView`'s computed properties so
/// the row-building, filter-counting, CTA-label, and Autovisor-row decisions are
/// separately unit-testable (the view keeps only rendering). Mirrors the established
/// view-logic-helper pattern (`TeamActivityComposer` routing statics): the helpers stay
/// `@MainActor` because they operate on view-adjacent types (`TaskFilter`,
/// `TeamEngineState`, `SidebarTaskItem`) and are exercised from a `@MainActor` test.
enum SidebarViewLogic {

    /// Live state for the Autovisor nav entry. `nil` (entry hidden) only when there's
    /// no real work folder — Autovisor is folder-scoped, and `setAutovisorEnabled`
    /// itself refuses to turn on in default storage. In a folder the row is ALWAYS
    /// visible; `isEnabled` distinguishes "configured manager" (chat surface) from
    /// "first-time setup" (goal + enable pane). `needsInput` means GENUINELY waiting
    /// on the human (escalation question) — the deliberate `wait_for_events` idle
    /// park shares the same engine state but is excluded so the icon doesn't pulse
    /// while just idle. `running`/`needsInput` are forced false when `!isEnabled`
    /// (defense-in-depth so a stale `engineState` from a deleted manager can't paint
    /// a status badge over the setup row).
    struct ManagerRowInfo: Equatable {
        let isEnabled: Bool
        let running: Bool
        let needsInput: Bool
    }

    /// Projects the task index into sidebar rows. `hasUnreadInput` lights only for a
    /// chat-mode task waiting on the Supervisor whose prompt the user hasn't seen yet;
    /// `isEngineRunning` / `isRecurring` are read straight off the live engine map and
    /// the recurrence schedule.
    static func buildSidebarTaskItems(
        summaries: [TaskSummary],
        seenSupervisorInputTaskIDs: Set<Int>,
        engineStates: [Int: TeamEngineState]
    ) -> [SidebarTaskItem] {
        summaries.map { task in
            let hasUnread = task.isChatMode
                && task.status == .needsSupervisorInput
                && !seenSupervisorInputTaskIDs.contains(task.id)
            return SidebarTaskItem(
                id: task.id,
                title: task.title,
                status: task.status,
                updatedAt: task.updatedAt,
                isChatMode: task.isChatMode,
                hasUnreadInput: hasUnread,
                isEngineRunning: engineStates[task.id] == .running,
                isRecurring: task.nextRecurrenceFireAt != nil
            )
        }
    }

    /// Count for a filter pill. `.running` is "not done" (covers running/paused/review),
    /// matching the row filter; `.recurring` keys on the schedule flag.
    static func filterCount(_ filter: TaskFilter, from items: [SidebarTaskItem]) -> Int {
        switch filter {
        case .all:       return items.count
        case .running:   return items.filter { $0.status != .done }.count
        case .done:      return items.filter { $0.status == .done }.count
        case .recurring: return items.filter { $0.isRecurring }.count
        }
    }

    /// Empty-state primary-button label: a live search clears first, then a non-`.all`
    /// filter resets, otherwise it offers a new task. Search takes priority over filter.
    static func resolveCTALabel(searchText: String, filter: TaskFilter) -> String {
        if !searchText.isEmpty { return "Clear Search" }
        if filter != .all { return "Show All" }
        return "New Task"
    }

    /// Resolves the Autovisor nav-row state, or `nil` to hide the row. The row hides
    /// ONLY when there's no real work folder (Autovisor is folder-scoped). In a
    /// folder, an unconfigured manager still surfaces a row so the user has a
    /// discoverable destination for the first-time setup pane. `isManagerActive`
    /// folds "manager exists AND enabled"; the idle-park exclusion keeps `needsInput`
    /// false while the manager is parked on `wait_for_events`.
    static func resolveManagerRowInfo(
        hasWorkFolder: Bool,
        isManagerActive: Bool,
        engineState: TeamEngineState?,
        isIdleParked: Bool
    ) -> ManagerRowInfo? {
        guard hasWorkFolder else { return nil }
        return ManagerRowInfo(
            isEnabled: isManagerActive,
            running: isManagerActive && engineState == .running,
            needsInput: isManagerActive
                && engineState == .needsSupervisorInput
                && !isIdleParked
        )
    }
}
