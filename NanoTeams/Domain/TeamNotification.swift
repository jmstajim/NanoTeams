import Foundation

// MARK: - Team Notification

/// Represents a notification for the Supervisor (user) about team activity
struct TeamNotification: Codable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date

    /// Type of notification
    var type: NotificationType

    /// Role that triggered the notification
    var role: Role

    /// Human-readable message
    var message: String

    /// Whether this notification has been read
    var isRead: Bool

    /// Whether this notification requires user action
    var requiresAction: Bool

    /// Additional context (e.g., step ID, meeting ID)
    var contextID: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = MonotonicClock.shared.now(),
        type: NotificationType,
        role: Role,
        message: String,
        isRead: Bool = false,
        requiresAction: Bool = false,
        contextID: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.type = type
        self.role = role
        self.message = message
        self.isRead = isRead
        self.requiresAction = requiresAction
        self.contextID = contextID
    }
}

// MARK: - Notification Type

enum NotificationType: String, Codable, Hashable {
    /// Role completed work and needs acceptance
    case acceptanceRequired

    /// Role asked a question via ask_supervisor
    case supervisorQuestionAsked

    /// Invitation to a team meeting
    case meetingInvitation

    /// Role completed their work (info only)
    case roleCompleted

    /// Role failed
    case roleFailed

    /// Revision completed and ready for re-review
    case revisionCompleted

    /// Task completed
    case taskCompleted

    /// Task failed
    case taskFailed

    private static let metadata: [NotificationType: (name: String, icon: String, priority: Int)] = [
        .acceptanceRequired:    ("Acceptance Required",  "checkmark.circle.badge.questionmark", 100),
        .supervisorQuestionAsked: ("Question Asked",    "questionmark.bubble",                  90),
        .roleFailed:            ("Role Failed",          "xmark.circle",                         85),
        .taskFailed:            ("Task Failed",          "exclamationmark.triangle",             80),
        .meetingInvitation:     ("Meeting Invitation",   "person.3",                             70),
        .revisionCompleted:     ("Revision Ready",       "arrow.clockwise.circle",               60),
        .roleCompleted:         ("Role Completed",       "checkmark.circle",                     30),
        .taskCompleted:         ("Task Completed",       "flag.checkered",                       20),
    ]

    var displayName: String { Self.metadata[self]?.name ?? rawValue }
    var icon: String { Self.metadata[self]?.icon ?? "bell" }
    var priority: Int { Self.metadata[self]?.priority ?? 0 }
}
