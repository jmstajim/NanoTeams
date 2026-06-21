import SwiftUI

// MARK: - Activity Notification Type

/// Notification type for inline activity feed items requiring Supervisor attention
nonisolated enum ActivityNotificationType: Hashable {
    /// Supervisor question notification. Each `ask_supervisor` tool call gets its own notification.
    /// - question: The question text
    /// - answer: The supervisor's answer (nil if unanswered/active)
    /// - answerAttachmentPaths: File attachment paths from the answer
    /// - answerClippedTexts: Clipped text snippets extracted from the answer (for card display)
    /// - toolCallID: The originating StepToolCall.id for unique identification
    /// - thinking: The LLM's reasoning that led to this question (nil if none)
    /// - wasAutoAnswered: Whether `answer` came from an automated path (auto-answer
    ///   service / delegating parent role / Autovisor) — from
    ///   `StepExecution.supervisorAnswerWasAuto`, NOT inferred from the team's
    ///   supervisor mode (a human answer in an autonomous team must show the
    ///   checkmark, not the "Auto-answered" badge). Step-latest flag — the builder
    ///   stamps it onto every resolved Q&A card on the step, so a step whose
    ///   history mixes auto and human answers shows the latest attribution on all
    ///   of them (per-question fidelity is not stored)
    case supervisorInput(question: String, answer: String?, answerAttachmentPaths: [String], answerClippedTexts: [String], toolCallID: UUID, thinking: String?, wasAutoAnswered: Bool)
    case failed(errorMessage: String?)

    func icon(isChatMode: Bool) -> String {
        switch self {
        case .supervisorInput: return isChatMode ? "bubble.left.and.bubble.right" : "questionmark.bubble"
        case .failed: return "exclamationmark.triangle"
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
        case .supervisorInput(_, let answer, _, _, _, _, _):
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
///
/// Every case carries `originTaskID` so the feed can interleave items from delegated
/// child tasks alongside the parent task. The originTaskID is used for:
/// - section grouping (break header on team boundary, even when role.baseID matches)
/// - per-item TeamRoleDefinition resolution (child team has its own roster)
/// - cache key namespacing (artifact/step caches partition by originTaskID)
/// - `id` derivation (prevents ForEach collisions when artifacts share names across teams)
nonisolated enum TeamActivityTimelineItem: Identifiable {
    case llmMessage(message: LLMMessage, role: Role, stepID: String, originTaskID: Int)
    case toolCall(call: StepToolCall, role: Role, stepID: String, originTaskID: Int)
    case artifact(artifact: Artifact, role: Role, stepID: String, originTaskID: Int)
    case meetingMessage(message: TeamMessage, meetingTopic: String, originTaskID: Int)
    case changeRequest(request: ChangeRequest, targetRoleName: String, originTaskID: Int)
    case notification(stepID: String, role: Role, type: ActivityNotificationType, createdAt: Date, originTaskID: Int)
    case supervisorTask(
        brief: String,
        taskCreatedAt: Date,
        supervisorTask: String,
        clippedTexts: [String],
        attachmentPaths: [String],
        workFolderURL: URL?,
        originTaskID: Int
    )

    var id: String {
        switch self {
        case .llmMessage(let msg, _, _, let taskID):
            return "msg-\(taskID)-\(msg.id)"
        case .toolCall(let call, _, _, let taskID):
            return "tool-\(taskID)-\(call.id)"
        case .artifact(let artifact, _, let stepID, let taskID):
            // Identity = `taskID + the artifact's path RELATIVE TO the task root`.
            // The persisted `relativePath` is rooted at `.nanoteams/`
            // (e.g. `tasks/9/runs/0/roles/frontend_step/artifact_index_html.md`,
            //  or `tasks/5/subtasks/6/runs/0/roles/X/artifact_Y.md` for delegated children).
            // Stripping everything up to and including `/{taskID}/` yields the
            // run/role/artifact path that uniquely identifies the artifact within
            // the task — different roles get different role-dirs, so paths can't
            // collide. Falls back to `stepID + slug` for transient artifacts not
            // yet persisted. Pinned by `TimelineArtifactIDCollisionTests`.
            let resolvedPath = TeamActivityTimelineItem.pathWithinTask(
                relativePath: artifact.relativePath, taskID: taskID
            ) ?? "\(stepID)/\(artifact.id)"
            return "art-\(taskID)-\(resolvedPath)"
        case .meetingMessage(let msg, _, let taskID):
            return "meeting-\(taskID)-\(msg.id)"
        case .changeRequest(let request, _, let taskID):
            return "cr-\(taskID)-\(request.id)"
        case .notification(let stepID, _, let type, let createdAt, let taskID):
            let typeKey: String
            switch type {
            case .supervisorInput(_, _, _, _, let tcID, _, _): typeKey = "input-\(tcID.uuidString)"
            // Fold the failure timestamp into the id so it stays stable-unique if the
            // same task ever renders multiple runs' `.failed` steps together (they
            // share `stepID` = roleID). A bare "fail" key would collide and trip
            // ForEach's stable-id rule (#22). `createdAt` here is `step.completedAt`
            // (set atomically on failure; falls back to `updatedAt` only if unset), so
            // it's stable per failed-step instance.
            case .failed: typeKey = "fail-\(createdAt.timeIntervalSinceReferenceDate)"
            }
            return "notif-\(taskID)-\(stepID)-\(typeKey)"
        case .supervisorTask(_, _, _, _, _, _, let taskID):
            return "supervisor-task-\(taskID)"
        }
    }

    /// Strips the leading `tasks/<taskID>/` (or nested `subtasks/<taskID>/`) prefix
    /// from a persisted artifact `relativePath`, yielding the path **relative to
    /// the task root** — e.g. `runs/0/roles/frontend_step/artifact_index_html.md`.
    /// Returns `nil` when `relativePath` is `nil` or doesn't contain the task ID
    /// segment (which would indicate a malformed path; caller falls back to a
    /// constructed identifier).
    static func pathWithinTask(relativePath: String?, taskID: Int) -> String? {
        guard let relativePath else { return nil }
        // Match either `tasks/<id>/` (root task) or `subtasks/<id>/` (nested child).
        // Picking the LAST occurrence so the deepest task in the chain wins.
        let needles = ["/tasks/\(taskID)/", "tasks/\(taskID)/", "/subtasks/\(taskID)/", "subtasks/\(taskID)/"]
        var bestRange: Range<String.Index>?
        for needle in needles {
            if let r = relativePath.range(of: needle, options: .backwards) {
                if bestRange == nil || r.lowerBound > bestRange!.lowerBound {
                    bestRange = r
                }
            }
        }
        guard let range = bestRange else { return nil }
        return String(relativePath[range.upperBound...])
    }

    /// Role identifier for grouping consecutive items from the same role.
    /// Returns nil for notification/changeRequest (always show header, break grouping).
    ///
    /// NOTE: this is `role.baseID` (built-in `Role` enum case), NOT the team-scoped
    /// `TeamRoleDefinition.id`. Two roles in different teams that share a `Role` enum
    /// case (both `.softwareEngineer`) produce identical `roleID`. Section-break
    /// logic in `ActivityFeedBuilder.annotate()` must therefore also break on
    /// `originTaskID` change to keep cross-team items visually separated.
    var roleID: String? {
        switch self {
        case .llmMessage(_, let role, _, _): return role.baseID
        case .toolCall(_, let role, _, _): return role.baseID
        case .artifact(_, let role, _, _): return role.baseID
        case .meetingMessage(let msg, _, _): return msg.role.baseID
        case .notification: return nil
        case .changeRequest: return nil
        case .supervisorTask: return Role.supervisor.baseID
        }
    }

    /// Origin task — `nil` is never expected in practice (every case stamps it),
    /// returned as a non-optional `Int` for convenience.
    var originTaskID: Int {
        switch self {
        case .llmMessage(_, _, _, let id): return id
        case .toolCall(_, _, _, let id): return id
        case .artifact(_, _, _, let id): return id
        case .meetingMessage(_, _, let id): return id
        case .changeRequest(_, _, let id): return id
        case .notification(_, _, _, _, let id): return id
        case .supervisorTask(_, _, _, _, _, _, let id): return id
        }
    }

    var createdAt: Date {
        switch self {
        case .llmMessage(let msg, _, _, _):
            return msg.createdAt
        case .toolCall(let call, _, _, _):
            return call.createdAt
        case .artifact(let artifact, _, _, _):
            return artifact.createdAt
        case .meetingMessage(let msg, _, _):
            return msg.createdAt
        case .changeRequest(let request, _, _):
            return request.createdAt
        case .notification(_, _, _, let date, _):
            return date
        case .supervisorTask(_, let date, _, _, _, _, _):
            return date
        }
    }

    /// Returns `true` if this item wraps a live streaming `LLMMessage`. A streaming
    /// item's `createdAt` is the moment streaming began, which is not guaranteed to
    /// be the latest timestamp in the step — later non-streaming messages can land
    /// while the preview is still alive. The caller decides whether to pin such
    /// items to the bottom of the feed.
    func isStreamingItem(isStreaming: (UUID) -> Bool) -> Bool {
        if case .llmMessage(let msg, _, _, _) = self {
            return isStreaming(msg.id)
        }
        return false
    }

}
