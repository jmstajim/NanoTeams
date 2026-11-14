import Foundation

/// What the External Autovisor pane's activity card shows: the rows left after the hide cutoff
/// and the task filter (newest first), the filter's options, and the line drawn when no row is
/// left. Pure, so the two controls of the card's header (`ActivityFilterBar`) are decided here
/// and tested without a view.
///
/// The cutoff is the Watchtower's own (`StoreConfiguration.timelineClearedUpToDate`, 2026-11-08,
/// «синхронизируй с главным экраном»): hiding either list hides both, and a row at or before it
/// is hidden by the same rule `WatchtowerTimelineBuilder` applies to its events. Nothing is
/// deleted — the log, and every full call, stay on disk.
struct ExternalAutovisorActivitySelection: Equatable {
    let items: [ExternalAutovisorFeedItem]
    let filterOptions: [ActivityFilterBar.Option]
    /// The filter in effect: the task chosen, while it is still one of the options. A deleted
    /// task's filter would show an empty list under a menu titled "All".
    let taskFilter: Int?
    let emptyText: String

    /// Hiding needs something shown to hide, the Watchtower's rule.
    var canHide: Bool { !items.isEmpty }

    static let noCallsYetText = "Every call the agent makes appears here as it happens."
    static let allHiddenText = "No calls since the activity was hidden."

    static func noCallsText(aboutTask taskID: Int) -> String {
        "No calls about #\(taskID) to show."
    }

    /// - Parameters:
    ///   - entries: the log's tail, oldest first (`ExternalAutovisorActivityLog.entries`).
    ///   - tasks: the agent's tasks — the filter's options, in the pane's order.
    ///   - taskFilter: the task chosen in the menu, if any.
    ///   - clearedUpTo: the shared hide cutoff; rows at or before it are not shown.
    static func make(
        entries: [ExternalAutovisorActivityRecord],
        fullCallIDs: Set<UUID>,
        tasks: [ExternalAutovisorTaskRowItem],
        taskFilter: Int?,
        clearedUpTo: Date?,
        now: Date
    ) -> ExternalAutovisorActivitySelection {
        let options = tasks.map { ActivityFilterBar.Option(id: $0.id, title: "#\($0.id) \($0.title)") }
        let offered = Set(options.map(\.id))
        let filter = taskFilter.flatMap { offered.contains($0) ? $0 : nil }

        var items: [ExternalAutovisorFeedItem] = []
        for record in entries.reversed() {
            if let clearedUpTo, record.createdAt <= clearedUpTo { continue }
            // A call ABOUT the task: its target, or a task its response named — the event that
            // carried its question, the list that carried its title — or one that reached every
            // task, the task chosen among them (a replaced Work Folder Context).
            if let filter, !record.concerns(taskID: filter), !record.reachesEveryTask { continue }
            items.append(.from(record: record, hasFullCall: fullCallIDs.contains(record.id), now: now))
        }

        let emptyText: String
        if entries.isEmpty {
            emptyText = noCallsYetText
        } else if let filter {
            emptyText = noCallsText(aboutTask: filter)
        } else {
            emptyText = allHiddenText
        }
        return ExternalAutovisorActivitySelection(
            items: items,
            filterOptions: options,
            taskFilter: filter,
            emptyText: emptyText
        )
    }
}
