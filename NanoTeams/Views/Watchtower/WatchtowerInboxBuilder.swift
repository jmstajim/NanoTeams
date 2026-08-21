import Foundation

/// Builds the Watchtower inbox and decides which persisted dismissals have expired.
///
/// Extracted so the garbage collector is a pure function with a name. It used to be
/// four inline statements inside `WatchtowerView.refreshNotifications`, and every test
/// that "covered" it re-implemented those statements in the test body — so the
/// production sweep had no coverage at all, and shipped a rule that deleted dismissals
/// for every task it could not currently see.
///
/// `@MainActor` for the same reason `SidebarViewLogic` is: it operates on
/// view-adjacent types and is exercised from a `@MainActor` test.
@MainActor
enum WatchtowerInboxBuilder {

    /// One task plus the role definitions needed to name its roles.
    struct TaskInput {
        let task: NTMSTask
        let teamRoles: [TeamRoleDefinition]

        init(task: NTMSTask, teamRoles: [TeamRoleDefinition]) {
            self.task = task
            self.teamRoles = teamRoles
        }
    }

    /// Every notification the given tasks currently produce, dismissals ignored.
    static func build(
        _ inputs: [TaskInput],
        bashApprovals: [BashApprovalRequest] = []
    ) -> [WatchtowerNotification] {
        inputs.flatMap { input -> [WatchtowerNotification] in
            // Closing is the Supervisor's explicit "done" — a closed task must not
            // keep producing banners off whatever its last run still holds (a chat
            // closed mid-question would otherwise show "<Role> replied" forever;
            // the task-level predicates guard closedAt, but the per-step scan in
            // `allWatchtowerNotifications` deliberately does not know the task).
            guard input.task.closedAt == nil else { return [] }
            guard let run = input.task.runs.last else { return [] }
            return run.allWatchtowerNotifications(
                task: input.task,
                teamRoles: input.teamRoles,
                bashApprovals: bashApprovals
            ).map {
                WatchtowerNotification(
                    taskID: input.task.id,
                    taskTitle: input.task.title,
                    isChatMode: input.task.isChatMode,
                    type: $0
                )
            }
        }
    }

    static func visible(
        _ all: [WatchtowerNotification],
        dismissed: Set<WatchtowerDismissKey>
    ) -> [WatchtowerNotification] {
        all.filter { !dismissed.contains($0.dismissKey) }
    }

    /// Dismissals that have outlived the notification they suppressed.
    ///
    /// A dismissal is stale only when we can SEE its task and that task no longer
    /// produces the notification. A key whose task is not loaded says nothing at all —
    /// expiring it there is what wiped every non-resident task's dismissals on each
    /// launch, since `loadedTasks` is populated lazily and the startup sweep evicts
    /// each task right after recovering it.
    ///
    /// A key whose task is gone from the index is a different case: the task was
    /// deleted, so the dismissal can never match anything again and is reclaimed.
    ///
    /// `knownTaskIDs.isEmpty` means the snapshot is torn down or not yet bootstrapped,
    /// not that every task vanished — total no-op, the same reasoning as the empty
    /// guard in `TaskManagementState.reconcileSeenSet`.
    static func staleDismissals(
        dismissed: Set<WatchtowerDismissKey>,
        active: Set<WatchtowerDismissKey>,
        loadedTaskIDs: Set<Int>,
        knownTaskIDs: Set<Int>
    ) -> Set<WatchtowerDismissKey> {
        guard !knownTaskIDs.isEmpty else { return [] }
        return dismissed.filter { key in
            guard knownTaskIDs.contains(key.taskID) else { return true }
            guard loadedTaskIDs.contains(key.taskID) else { return false }
            return !active.contains(key)
        }
    }
}
