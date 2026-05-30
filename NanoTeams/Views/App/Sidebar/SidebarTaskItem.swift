import Foundation

struct SidebarTaskItem: Identifiable {
    let id: Int
    let title: String
    let status: TaskStatus
    let updatedAt: Date
    var isChatMode: Bool = false
    var hasUnreadInput: Bool = false
    var isEngineRunning: Bool = false
    /// True when the task has an enabled recurrence schedule — drives the
    /// "recurring" badge in the sidebar row.
    var isRecurring: Bool = false
}
