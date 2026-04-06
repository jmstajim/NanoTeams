import Foundation

struct TaskFilterEmptyState {
    let icon: String
    let title: String
    let subtitle: String

    static func `for`(_ filter: TaskFilter, searchText: String) -> TaskFilterEmptyState {
        if !searchText.isEmpty {
            return TaskFilterEmptyState(icon: "magnifyingglass", title: "No Results", subtitle: "Try a different search")
        }
        switch filter {
        case .done:    return TaskFilterEmptyState(icon: "checkmark.circle", title: "No Completed Tasks", subtitle: "Completed tasks will appear here")
        case .running: return TaskFilterEmptyState(icon: "circle.inset.filled", title: "No Active Tasks", subtitle: "Active tasks will appear here")
        case .all:     return TaskFilterEmptyState(icon: "tray", title: "No Tasks", subtitle: "Create a task to get started")
        }
    }
}
