import SwiftUI

// MARK: - Notification Type

/// Type of watchtower notification requiring Supervisor attention
enum WatchtowerNotificationType {
    case supervisorInput(stepID: String, question: String, role: Role)
    case acceptance(stepID: String, roleID: String, roleName: String)
    case failed(stepID: String, role: Role, errorMessage: String?)
    case taskDone(taskID: Int, taskTitle: String)

    func icon(isChatMode: Bool) -> String {
        switch self {
        case .supervisorInput: return isChatMode ? "bubble.left.and.bubble.right.fill" : "questionmark.bubble.fill"
        case .acceptance: return "hand.raised.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .taskDone: return "checkmark.circle.fill"
        }
    }

    func color(isChatMode: Bool) -> Color {
        switch self {
        case .supervisorInput: return isChatMode ? Colors.info : Colors.gold
        case .acceptance: return Colors.purple
        case .failed: return Colors.error
        case .taskDone: return Colors.success
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
        }
    }

    var requiresAction: Bool {
        switch self {
        case .supervisorInput, .acceptance, .taskDone: return true
        case .failed: return false
        }
    }

    /// The string used to track dismissal state in the view.
    var dismissID: String {
        switch self {
        case .supervisorInput(let stepID, _, _): return stepID
        case .acceptance(let stepID, _, _): return stepID
        case .failed(let stepID, _, _): return stepID
        case .taskDone(let taskID, _): return String(taskID)
        }
    }
}

// MARK: - Run + Watchtower Notification (Information Expert)

// MARK: - Watchtower Notification (task-scoped wrapper)

/// Wraps a `WatchtowerNotificationType` with the originating task context,
/// enabling multi-task notification display in the Watchtower.
struct WatchtowerNotification: Identifiable {
    let taskID: Int
    let taskTitle: String
    let isChatMode: Bool
    let type: WatchtowerNotificationType

    var id: String { type.dismissID }
}

// MARK: - Run + All Watchtower Notifications

extension Run {
    /// Returns ALL Watchtower notifications for this run (not just highest-priority).
    /// Dismissal filtering is handled by the caller (view state concern).
    func allWatchtowerNotifications(task: NTMSTask, teamRoles: [TeamRoleDefinition]) -> [WatchtowerNotificationType] {
        var notifications: [WatchtowerNotificationType] = []
        var seenStepIDs: Set<String> = []
        let isChatMode = task.isChatMode

        // Supervisor input (highest priority per step — unanswered questions)
        for step in steps where step.needsSupervisorInput && step.effectiveSupervisorAnswer == nil {
            if let question = step.supervisorQuestion {
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

        return notifications
    }
}

// MARK: - Quick Action

struct QuickAction: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let icon: String
    let color: Color
    let action: () -> Void

    // MARK: - Factory

    /// Builds the list of available Watchtower quick actions based on current state.
    static func makeActions(
        activeTask: NTMSTask?,
        engineStatus: TeamEngineState?,
        requiresFinalReview: Bool,
        onNewTask: @escaping () -> Void,
        onNavigateToTask: @escaping (Int) -> Void,
        onPauseRun: @escaping (Int) -> Void,
        onShowFinalReview: @escaping () -> Void,
        onCloseTask: @escaping (Int) -> Void
    ) -> [QuickAction] {
        var actions: [QuickAction] = []

        actions.append(QuickAction(id: "newTask", title: "New Task", subtitle: "or chat", icon: "plus.circle.fill", color: Colors.accent) {
            onNewTask()
        })

        guard let activeTask else { return actions }
        let taskID = activeTask.id

        actions.append(QuickAction(id: "continueTask", title: "Continue Task", subtitle: activeTask.title, icon: "arrow.right.circle.fill", color: Colors.info) {
            onNavigateToTask(taskID)
        })

        if engineStatus == .running || engineStatus == .needsAcceptance {
            actions.append(QuickAction(id: "pauseRun", title: "Pause Run", icon: "pause.circle.fill", color: Colors.warning) {
                onPauseRun(taskID)
            })
        }

        if activeTask.isReadyForFinalAcceptance {
            actions.append(QuickAction(id: "reviewTask", title: "Review Task", subtitle: activeTask.title, icon: "eye.circle.fill", color: Colors.purple) {
                if requiresFinalReview {
                    onShowFinalReview()
                } else {
                    onNavigateToTask(taskID)
                }
            })
            actions.append(QuickAction(id: "acceptTask", title: "Accept Task", icon: "checkmark.circle.fill", color: Colors.emerald) {
                onCloseTask(taskID)
            })
        }

        return actions
    }
}
