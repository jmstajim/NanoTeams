import Foundation

struct SidebarTaskItem: Identifiable {
    let id: Int
    let title: String
    let status: TaskStatus
    let updatedAt: Date
    var isChatMode: Bool = false
    var hasUnreadInput: Bool = false
}
