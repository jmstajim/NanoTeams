import Foundation

struct SidebarTaskItem: Identifiable {
    let id: Int
    let title: String
    let status: TaskStatus
    let updatedAt: Date
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
