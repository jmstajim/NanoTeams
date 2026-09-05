import Foundation

/// One sidebar row's render inputs, as built by `SidebarViewLogic.buildSidebarTaskItems`
/// and cached by `SidebarViewLogic.RowsMemo` across body passes.
///
/// No `updatedAt` here on purpose — `mutateTask` re-stamps its row on every write, so a
/// stamp inside a cached item would either invalidate the memo per message or freeze the
/// visible "just now". `SidebarTaskRow` takes the live value from
/// `TaskFactsProjection.updatedAtByTaskID` instead (one home, CLAUDE.md #91).
/// `Equatable` so the memo's output can be checked against a fresh build.
struct SidebarTaskItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let status: TaskStatus
    var isChatMode: Bool = false
    var hasUnreadInput: Bool = false
    var isEngineRunning: Bool = false
    /// A run start is claimed but has not reached `engine.start()` yet. Drives the same
    /// braille spinner as `isEngineRunning` — the row's own reason to say "this task is
    /// alive" — while the status LABEL deliberately stays whatever `TaskStatus` says.
    /// The word for the phase lives in `RunInitializationDisplay` and is rendered only
    /// where there is room for a caption; this column has none.
    var isInitializing: Bool = false
    /// True when the task has an enabled recurrence schedule — drives the
    /// "recurring" badge in the sidebar row.
    var isRecurring: Bool = false
    /// True when the task is holding a `bash` command awaiting Allow/Deny — drives
    /// the terminal "needs command approval" badge so a BACKGROUND task waiting on a
    /// command is discoverable without opening it.
    var hasPendingBashApproval: Bool = false
}
