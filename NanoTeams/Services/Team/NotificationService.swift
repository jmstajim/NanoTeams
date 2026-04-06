import Foundation
import Observation

// MARK: - Notification Service

/// Service for managing Supervisor notifications about team activity
@Observable @MainActor
final class NotificationService {

    /// All notifications
    private(set) var notifications: [TeamNotification] = []

    /// Number of unread notifications
    var unreadCount: Int {
        notifications.filter { !$0.isRead }.count
    }

    /// Notifications requiring action
    var actionableNotifications: [TeamNotification] {
        notifications.filter { $0.requiresAction && !$0.isRead }
    }

    /// Maximum notifications kept in the queue before older items are evicted.
    private let maxNotifications = 100

    // MARK: - Factory

    private func notify(type: NotificationType, role: Role, message: String, requiresAction: Bool, contextID: String) {
        add(TeamNotification(type: type, role: role, message: message, requiresAction: requiresAction, contextID: contextID))
    }

    func notifyAcceptanceRequired(role: Role, stepID: String) {
        notify(type: .acceptanceRequired, role: role, message: "\(role.displayName) has completed their work and needs your approval.", requiresAction: true, contextID: stepID)
    }

    func notifySupervisorQuestion(role: Role, question: String, stepID: String) {
        notify(type: .supervisorQuestionAsked, role: role, message: "\(role.displayName) asks: \(question.prefix(100))...", requiresAction: true, contextID: stepID)
    }

    func notifyMeetingInvitation(initiatedBy: Role, topic: String, meetingID: UUID) {
        notify(type: .meetingInvitation, role: initiatedBy, message: "Team meeting requested: \(topic)", requiresAction: true, contextID: meetingID.uuidString)
    }

    func notifyRoleCompleted(role: Role, stepID: String) {
        notify(type: .roleCompleted, role: role, message: "\(role.displayName) has completed their work.", requiresAction: false, contextID: stepID)
    }

    func notifyRoleFailed(role: Role, error: String, stepID: String) {
        notify(type: .roleFailed, role: role, message: "\(role.displayName) failed: \(error.prefix(100))...", requiresAction: true, contextID: stepID)
    }

    func notifyRevisionCompleted(role: Role, stepID: String) {
        notify(type: .revisionCompleted, role: role, message: "\(role.displayName) has addressed your feedback and is ready for re-review.", requiresAction: true, contextID: stepID)
    }

    func notifyTaskCompleted(taskTitle: String, taskID: Int) {
        notify(type: .taskCompleted, role: .supervisor, message: "Task '\(taskTitle)' has been completed successfully.", requiresAction: false, contextID: String(taskID))
    }

    func notifyTaskFailed(taskTitle: String, error: String, taskID: Int) {
        notify(type: .taskFailed, role: .supervisor, message: "Task '\(taskTitle)' failed: \(error.prefix(100))...", requiresAction: true, contextID: String(taskID))
    }

    // MARK: - Store

    private func add(_ notification: TeamNotification) {
        notifications.insert(notification, at: 0)

        // Trim old notifications
        if notifications.count > maxNotifications {
            notifications = Array(notifications.prefix(maxNotifications))
        }
    }

    /// Mark a notification as read
    func markAsRead(_ notificationID: UUID) {
        if let index = notifications.firstIndex(where: { $0.id == notificationID }) {
            notifications[index].isRead = true
        }
    }

    /// Mark all notifications as read
    func markAllAsRead() {
        for index in notifications.indices {
            notifications[index].isRead = true
        }
    }

    /// Dismiss a notification
    func dismiss(_ notificationID: UUID) {
        notifications.removeAll { $0.id == notificationID }
    }

    /// Clear all notifications
    func clearAll() {
        notifications.removeAll()
    }

    // MARK: - Queries

    /// Get notifications sorted by priority
    func sortedByPriority() -> [TeamNotification] {
        notifications.sorted { $0.type.priority > $1.type.priority }
    }

    /// Get recent notifications (last 24 hours)
    func recentNotifications() -> [TeamNotification] {
        let cutoff = MonotonicClock.shared.now().addingTimeInterval(-24 * 60 * 60)
        return notifications.filter { $0.createdAt > cutoff }
    }
}

// MARK: - Notification Badge Data

extension NotificationService {

    /// Badge count for UI display (unread actionable notifications)
    var badgeCount: Int {
        actionableNotifications.count
    }

    /// Whether to show the badge
    var shouldShowBadge: Bool {
        badgeCount > 0
    }

    /// Badge text
    var badgeText: String {
        badgeCount > 9 ? "9+" : "\(badgeCount)"
    }
}
