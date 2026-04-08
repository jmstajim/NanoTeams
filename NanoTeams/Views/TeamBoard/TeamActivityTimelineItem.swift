import SwiftUI

// MARK: - Activity Notification Type

/// Notification type for inline activity feed items requiring Supervisor attention
enum ActivityNotificationType: Hashable {
    /// Supervisor question notification. Each `ask_supervisor` tool call gets its own notification.
    /// - question: The question text
    /// - answer: The supervisor's answer (nil if unanswered/active)
    /// - toolCallID: The originating StepToolCall.id for unique identification
    /// - thinking: The LLM's reasoning that led to this question (nil if none)
    case supervisorInput(question: String, answer: String?, answerAttachmentPaths: [String], toolCallID: UUID, thinking: String?)
    case failed(errorMessage: String?)

    func icon(isChatMode: Bool) -> String {
        switch self {
        case .supervisorInput: return isChatMode ? "bubble.left.and.bubble.right.fill" : "questionmark.bubble.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    func color(isChatMode: Bool) -> Color {
        switch self {
        case .supervisorInput: return isChatMode ? Colors.textTertiary : Colors.warning
        case .failed: return Colors.error
        }
    }

    func title(for role: Role, isChatMode: Bool = false) -> String {
        switch self {
        case .supervisorInput(_, let answer, _, _, _):
            if answer != nil {
                return "\(role.displayName) asked"
            }
            return isChatMode ? "\(role.displayName) replied" : "\(role.displayName) needs your input"
        case .failed:
            return "\(role.displayName) encountered an error"
        }
    }
}

// MARK: - Timeline Item

/// A unified item for the team activity timeline, combining all activity types across roles.
enum TeamActivityTimelineItem: Identifiable {
    case llmMessage(message: LLMMessage, role: Role, stepID: String)
    case toolCall(call: StepToolCall, role: Role, stepID: String)
    case artifact(artifact: Artifact, role: Role, stepID: String)
    case meetingMessage(message: TeamMessage, meetingTopic: String)
    case changeRequest(request: ChangeRequest, targetRoleName: String)
    case notification(stepID: String, role: Role, type: ActivityNotificationType, createdAt: Date)
    case supervisorTask(
        brief: String,
        taskCreatedAt: Date,
        supervisorTask: String,
        clippedTexts: [String],
        attachmentPaths: [String],
        workFolderURL: URL?
    )

    var id: String {
        switch self {
        case .llmMessage(let msg, _, _):
            return "msg-\(msg.id))"
        case .toolCall(let call, _, _):
            return "tool-\(call.id))"
        case .artifact(let artifact, _, _):
            return "art-\(artifact.id)"  // artifact.id is already String (computed from name)
        case .meetingMessage(let msg, _):
            return "meeting-\(msg.id))"
        case .changeRequest(let request, _):
            return "cr-\(request.id))"
        case .notification(let stepID, _, let type, _):
            let typeKey: String
            switch type {
            case .supervisorInput(_, _, _, let tcID, _): typeKey = "input-\(tcID.uuidString)"
            case .failed: typeKey = "fail"
            }
            return "notif-\(stepID)-\(typeKey)"
        case .supervisorTask:
            return "supervisor-task"
        }
    }

    /// Role identifier for grouping consecutive items from the same role.
    /// Returns nil for notification/changeRequest (always show header, break grouping).
    var roleID: String? {
        switch self {
        case .llmMessage(_, let role, _): return role.baseID
        case .toolCall(_, let role, _): return role.baseID
        case .artifact(_, let role, _): return role.baseID
        case .meetingMessage(let msg, _): return msg.role.baseID
        case .notification: return nil
        case .changeRequest: return nil
        case .supervisorTask: return Role.supervisor.baseID
        }
    }

    var createdAt: Date {
        switch self {
        case .llmMessage(let msg, _, _):
            return msg.createdAt
        case .toolCall(let call, _, _):
            return call.createdAt
        case .artifact(let artifact, _, _):
            return artifact.createdAt
        case .meetingMessage(let msg, _):
            return msg.createdAt
        case .changeRequest(let request, _):
            return request.createdAt
        case .notification(_, _, _, let date):
            return date
        case .supervisorTask(_, let date, _, _, _, _):
            return date
        }
    }

}
