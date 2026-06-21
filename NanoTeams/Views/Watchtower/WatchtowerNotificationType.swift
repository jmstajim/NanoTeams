import SwiftUI

// MARK: - Notification Type

/// Type of watchtower notification requiring Supervisor attention
nonisolated enum WatchtowerNotificationType {
    case supervisorInput(stepID: String, question: String, role: Role)
    case acceptance(stepID: String, roleID: String, roleName: String)
    case failed(stepID: String, role: Role, errorMessage: String?)
    case taskDone(taskID: Int, taskTitle: String)
    case timedOut(taskID: Int, taskTitle: String)

    func icon(isChatMode: Bool) -> String {
        switch self {
        case .supervisorInput: return isChatMode ? "bubble.left.and.bubble.right" : "questionmark.bubble"
        case .acceptance: return "hand.raised.circle"
        case .failed: return "exclamationmark.triangle"
        case .taskDone: return "checkmark.circle"
        case .timedOut: return "clock.badge.exclamationmark"
        }
    }

    func color(isChatMode: Bool) -> Color {
        switch self {
        case .supervisorInput: return isChatMode ? Colors.info : Colors.gold
        case .acceptance: return Colors.purple
        case .failed: return Colors.error
        case .taskDone: return Colors.success
        case .timedOut: return Colors.warning
        }
    }

    func title(isChatMode: Bool) -> String {
        switch self {
        case .supervisorInput(_, _, let role):
            return isChatMode ? "\(role.displayName) replied" : "\(role.displayName) needs your input"
        case .acceptance(_, _, let roleName):
            return "\(roleName) needs your review"
        case .failed(_, let role, _):
            return "\(role.displayName) encountered an error"
        case .taskDone(_, let taskTitle):
            return "\(taskTitle) completed"
        case .timedOut(_, let taskTitle):
            return "\(taskTitle) timed out"
        }
    }

    /// Whether this notification surfaces an action *button* (answer / accept /
    /// review). `.failed` / `.timedOut` are informational — no inline action — so
    /// they're excluded here.
    var requiresAction: Bool {
        switch self {
        case .supervisorInput, .acceptance, .taskDone: return true
        case .failed, .timedOut: return false
        }
    }

    /// Whether this notification counts toward the "{N} tasks need you" headline.
    /// Distinct from `requiresAction`: it INCLUDES `.failed` / `.timedOut`,
    /// because a failed or timed-out task is unresolved and must be counted —
    /// otherwise the masthead reads "0 tasks need you" while a failure sits in
    /// the inbox. Every current notification needs attention; the explicit
    /// predicate keeps the headline honest if a purely-informational type is
    /// added later.
    var needsAttention: Bool {
        switch self {
        case .supervisorInput, .acceptance, .taskDone, .failed, .timedOut: return true
        }
    }

    /// Dismiss-set key. For `.supervisorInput`, includes question text so a
    /// fresh question on the same step gets a fresh ID — dismissals must not
    /// bleed across rounds. `::` separator: step IDs never contain it.
    ///
    /// Known limitation: byte-identical question text across rounds (e.g.
    /// hardcoded refusal-loop nudges) collides. Acceptable today — switching
    /// to a per-call UUID would require widening the enum case.
    var dismissID: String {
        switch self {
        case .supervisorInput(let stepID, let question, _): return "\(stepID)::\(question)"
        case .acceptance(let stepID, _, _): return stepID
        case .failed(let stepID, _, _): return stepID
        case .taskDone(let taskID, _): return String(taskID)
        case .timedOut(let taskID, _): return "timeout::\(taskID)"
        }
    }
}

// MARK: - Run + Watchtower Notification (Information Expert)

// MARK: - Watchtower Notification (task-scoped wrapper)

/// Wraps a `WatchtowerNotificationType` with the originating task context,
/// enabling multi-task notification display in the Watchtower.
nonisolated struct WatchtowerNotification: Identifiable {
    let taskID: Int
    let taskTitle: String
    let isChatMode: Bool
    let type: WatchtowerNotificationType

    var id: String { type.dismissID }

    /// Count for the "{N} tasks need you" headline — notifications needing the
    /// Supervisor's attention, INCLUDING failed / timed-out (see
    /// `WatchtowerNotificationType.needsAttention`). Pure + testable.
    static func needsYouCount(_ notifications: [WatchtowerNotification]) -> Int {
        notifications.filter(\.type.needsAttention).count
    }
}

// MARK: - Run + All Watchtower Notifications

extension Run {
    /// Returns ALL Watchtower notifications for this run (not just highest-priority).
    /// Dismissal filtering is handled by the caller (view state concern).
    func allWatchtowerNotifications(task: NTMSTask, teamRoles: [TeamRoleDefinition]) -> [WatchtowerNotificationType] {
        var notifications: [WatchtowerNotificationType] = []
        var seenStepIDs: Set<String> = []
        let isChatMode = task.isChatMode

        // Shared predicate so Watchtower / activity feed / composer chip agree.
        // A bare `needsSupervisorInput && answer == nil` check misses the race
        // window where the round-N+1 question is in flight but A_N is still on
        // the step.
        //
        // `supervisorQuestion` can lag the predicate during the same race (flag
        // set, text not yet copied), so fall back to parsing the trailing ask
        // call's args — same chain `activeSupervisorQuestions` uses for the
        // composer chip. Without the fallback the banner is silently skipped.
        for step in steps where ActivityFeedBuilder.stepHasActiveSupervisorInput(step) {
            let question = step.supervisorQuestion
                ?? step.toolCalls.last(where: { $0.name == ToolNames.askSupervisor })
                    .flatMap { ActivityFeedBuilder.parseAskSupervisorQuestion(from: $0.argumentsJSON) }
            if let question {
                notifications.append(.supervisorInput(stepID: step.id, question: question, role: step.role))
                seenStepIDs.insert(step.id)
            }
        }

        // Acceptance needed (skip in chat mode; skip steps already shown above)
        if !isChatMode {
            for (roleID, status) in roleStatuses where status == .needsAcceptance {
                let roleName = teamRoles.first { $0.id == roleID }?.name ?? Role.fromID(roleID).displayName
                if let step = steps.last(where: { $0.effectiveRoleID == roleID }),
                   !seenStepIDs.contains(step.id) {
                    notifications.append(.acceptance(stepID: step.id, roleID: roleID, roleName: roleName))
                    seenStepIDs.insert(step.id)
                }
            }
        }

        // Failed steps (skip steps already shown above)
        for step in steps where step.status == .failed && !seenStepIDs.contains(step.id) {
            notifications.append(.failed(stepID: step.id, role: step.role, errorMessage: nil))
        }

        // Task completed — all roles accepted, awaiting final Supervisor acceptance (skip in chat mode)
        if !isChatMode && task.isReadyForFinalAcceptance {
            notifications.append(.taskDone(taskID: task.id, taskTitle: task.title))
        }

        // Run paused by the run-timeout watchdog. Shows only while the run is
        // actually paused-by-timeout; clears once the Supervisor resumes (the
        // task leaves `.paused`) so it doesn't linger as historical noise.
        if timedOutAt != nil && task.derivedStatusFromActiveRun() == .paused {
            notifications.append(.timedOut(taskID: task.id, taskTitle: task.title))
        }

        return notifications
    }
}

