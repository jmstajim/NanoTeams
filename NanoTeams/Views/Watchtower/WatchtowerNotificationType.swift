import SwiftUI

// MARK: - Notification Type

/// Type of watchtower notification requiring Supervisor attention
nonisolated enum WatchtowerNotificationType {
    /// `toolCallID` is the identity of the `ask_supervisor` call that asked, taken
    /// from `StepToolCall.id` — a persisted `UUID`, so it survives a relaunch. It is
    /// what makes a dismissal target ONE question instead of "whatever this step is
    /// currently asking", which matters most in chat mode, where every assistant turn
    /// is another `ask_supervisor` call. Nil only on the escalation path, where the
    /// engine flips the waiting flag without appending a call.
    case supervisorInput(stepID: String, question: String, role: Role, toolCallID: UUID?)
    case acceptance(stepID: String, roleID: String, roleName: String)
    case failed(stepID: String, role: Role, errorMessage: String?)
    case taskDone(taskID: Int, taskTitle: String)
    case timedOut(taskID: Int, taskTitle: String)
    /// A `bash` command is HELD awaiting Allow/Deny. The in-loop hold keeps the step
    /// `.running` (no `.needsSupervisorInput`), so for a BACKGROUND task this banner
    /// is the only Watchtower signal it's waiting. Informational pointer — the
    /// Allow/Deny/Always/Ask-AI card lives in the task's activity feed; the banner's
    /// open affordance navigates there.
    case bashApprovalNeeded(stepID: String, taskID: Int, command: String, role: Role, createdAt: Date)

    func icon(isChatMode: Bool) -> String {
        switch self {
        case .supervisorInput: return isChatMode ? "bubble.left.and.bubble.right" : "questionmark.bubble"
        case .acceptance: return "hand.raised.circle"
        case .failed: return "exclamationmark.triangle"
        case .taskDone: return "checkmark.circle"
        case .timedOut: return "clock.badge.exclamationmark"
        case .bashApprovalNeeded: return "terminal"
        }
    }

    func color(isChatMode: Bool) -> Color {
        switch self {
        case .supervisorInput: return isChatMode ? Colors.info : Colors.gold
        case .acceptance: return Colors.purple
        case .failed: return Colors.error
        case .taskDone: return Colors.success
        case .timedOut: return Colors.warning
        case .bashApprovalNeeded: return Colors.warning
        }
    }

    func title(isChatMode: Bool) -> String {
        switch self {
        case .supervisorInput(_, _, let role, _):
            return isChatMode ? "\(role.displayName) replied" : "\(role.displayName) needs your input"
        case .acceptance(_, _, let roleName):
            return "\(roleName) needs your review"
        case .failed(_, let role, _):
            return "\(role.displayName) encountered an error"
        case .taskDone(_, let taskTitle):
            return "\(taskTitle) completed"
        case .timedOut(_, let taskTitle):
            return "\(taskTitle) timed out"
        case .bashApprovalNeeded(_, _, _, let role, _):
            return "\(role.displayName) wants to run a command"
        }
    }

    /// Whether this notification surfaces an action *button* (answer / accept /
    /// review). `.failed` / `.timedOut` are informational — no inline action — so
    /// they're excluded here. `.bashApprovalNeeded` is a pointer: the rich Allow/Deny
    /// card lives in the task feed, so the banner only navigates (no inline action).
    var requiresAction: Bool {
        switch self {
        case .supervisorInput, .acceptance, .taskDone: return true
        case .failed, .timedOut, .bashApprovalNeeded: return false
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
        case .supervisorInput, .acceptance, .taskDone, .failed, .timedOut, .bashApprovalNeeded: return true
        }
    }

    /// Dismiss-set key WITHIN a task. `WatchtowerDismissKey` adds the task scope —
    /// this string alone is not a dismissal identity, because `stepID == roleID` and
    /// is therefore shared by every task on the same team.
    ///
    /// For `.supervisorInput` the discriminator is the asking call's `UUID`, so a
    /// fresh question on the same step always gets a fresh key even when its text
    /// repeats byte-for-byte (hardcoded refusal-loop nudges used to collide here).
    /// The escalation path has no call to name, so it falls back to the question
    /// text and keeps the old, collision-prone behaviour for that one case.
    /// `::` separator: step IDs never contain it.
    var dismissID: String {
        switch self {
        case .supervisorInput(let stepID, let question, _, let toolCallID):
            return "\(stepID)::\(toolCallID?.uuidString ?? question)"
        case .acceptance(let stepID, _, _):
            return WatchtowerDismissKey.acceptanceTypeID(stepID: stepID)
        case .failed(let stepID, _, _):
            return WatchtowerDismissKey.failedTypeID(stepID: stepID)
        case .taskDone(let taskID, _): return String(taskID)
        case .timedOut(let taskID, _): return "timeout::\(taskID)"
        // `createdAt` discriminates hold instances: a re-held command (new createdAt)
        // gets a fresh ID so a prior dismissal doesn't suppress it — same per-instance
        // identity the in-loop gate keys on.
        case .bashApprovalNeeded(let stepID, let taskID, _, _, let createdAt):
            return "bash::\(taskID)::\(stepID)::\(createdAt.timeIntervalSince1970)"
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

    /// Task-scoped dismissal identity. `type.dismissID` alone is NOT an identity —
    /// see `WatchtowerDismissKey`.
    var dismissKey: WatchtowerDismissKey {
        WatchtowerDismissKey(taskID: taskID, typeID: type.dismissID)
    }

    var id: String { dismissKey.storageKey }

    /// Count for the "{N} tasks need you" headline — notifications needing the
    /// Supervisor's attention, INCLUDING failed / timed-out (see
    /// `WatchtowerNotificationType.needsAttention`). Pure + testable.
    static func needsYouCount(_ notifications: [WatchtowerNotification]) -> Int {
        notifications.filter(\.type.needsAttention).count
    }
}

// MARK: - Run + All Watchtower Notifications

nonisolated extension Run {
    /// Returns ALL Watchtower notifications for this run (not just highest-priority).
    /// Dismissal filtering is handled by the caller (view state concern).
    func allWatchtowerNotifications(
        task: NTMSTask,
        teamRoles: [TeamRoleDefinition],
        bashApprovals: [BashApprovalRequest] = []
    ) -> [WatchtowerNotificationType] {
        var notifications: [WatchtowerNotificationType] = []
        var seenStepIDs: Set<String> = []
        let isChatMode = task.isChatMode

        // Held `bash` commands (cross-task discoverable). The step is `.running` while
        // the gate awaits, so this never collides with the input/acceptance/failed
        // loops below (those need other statuses) — append directly. Role resolved
        // from the holding step so the title can name it.
        for req in bashApprovals where req.taskID == task.id {
            let role = steps.first(where: { $0.id == req.stepID })?.role ?? Role.fromID(req.stepID)
            notifications.append(.bashApprovalNeeded(
                stepID: req.stepID, taskID: req.taskID, command: req.command,
                role: role, createdAt: req.createdAt))
        }

        // Shared predicate so Watchtower / activity feed / composer chip agree.
        // A bare `needsSupervisorInput && answer == nil` check misses the race
        // window where the round-N+1 question is in flight but A_N is still on
        // the step.
        //
        // `supervisorQuestion` can lag the predicate during the same race (flag
        // set, text not yet copied), so fall back to parsing the trailing ask
        // call's args — same chain `activeSupervisorQuestions` uses for the
        // composer chip. Without the fallback the banner is silently skipped.
        for step in steps where step.hasActiveSupervisorInput {
            let question = step.supervisorQuestion
                ?? step.toolCalls.last(where: { $0.name == ToolNames.askSupervisor })
                .flatMap { $0.parsedSupervisorQuestion }
            if let question {
                notifications.append(.supervisorInput(
                    stepID: step.id, question: question, role: step.role,
                    toolCallID: step.activeSupervisorQuestionID))
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

