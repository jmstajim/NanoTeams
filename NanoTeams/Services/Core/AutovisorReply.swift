import Foundation

/// The texts the app writes to the Autovisor's manager about its own actions and about the folder
/// it watches: the reply to every action call — `NTMSOrchestrator.performAutovisorAction`, its
/// verb dispatchers, and the team-generation retry that `control_task resume` and `manage_role
/// restart` route to — and the event notice injected into a pass that is still reviewing
/// (`NTMSOrchestrator.composeAutovisorEventNotice`).
///
/// One builder, so that `RuntimePromptRegistry` versions all of them: each one becomes a tool
/// result or a user turn the manager reads, and several carry direction ("call list_tasks",
/// "call control_task start on #N", "use manage_role restart"). The registry renders every case
/// with a fixed sample (`RuntimePromptRegistry.autovisorReplySamples`).
///
/// Not here, by owner: the reply to an action a folder transition overtook is the deferred-call
/// family's (`DeferredCallReplies.folderChanged`), shared with the delegation handler; a team
/// refusal is `AutovisorTeamPolicy.failureMessage`'s, the policy that decides it; an accept
/// refusal's fact and remedy are `AcceptanceService.validateAcceptance`'s and
/// `AutovisorStatus.acceptRejectionAdvice`'s, joined here. Each of those is a marked builder
/// with registry rows of its own. A
/// banner the action itself surfaced (`surfacingError(_:)`) reaches the manager verbatim as
/// the reason — the person's text, not this builder's.
nonisolated enum AutovisorReply {

    // MARK: Every action of the built-in manager

    /// The folder's Autovisor driver is the external agent, so the built-in manager is dormant and
    /// refuses every action before it reads anything (`performAutovisorAction`).
    case drivenByExternalAgent

    // MARK: Every task-targeted action

    case ownTask(taskID: Int)
    case taskNotFound(taskID: Int)

    // MARK: create_managed_task

    case tooManyRunning(count: Int)
    case creationLimitReached(limit: Int)
    /// The external agent's two creation caps, each with its own remedy — and that is why they
    /// are two cases. Both used to render `creationLimitReached`, which is the built-in manager's
    /// per-REVIEW cap: its wording («this pass», «review or finish existing tasks») names a
    /// concept an agent has no referent for, and its remedy is actively wrong for a sliding
    /// window — closing a task frees an OPEN slot and never refills a window, so an agent that
    /// obeyed it retried into the identical refusal until it gave up. The ledger computes
    /// `windowMinutes` and the old mapping discarded it with a `_`.
    case openTaskLimitReached(count: Int, limit: Int)
    case creationWindowLimitReached(limit: Int, windowMinutes: Int)
    case creationFailed
    /// `reason` is the banner the start surfaced, or `nil` when it surfaced none.
    case createdNotStarted(taskID: Int, title: String, reason: String?)
    case createdAndStarted(taskID: Int, title: String)
    case createdScheduled(taskID: Int, title: String, runAt: Date?)

    // MARK: answer_task_question, message_task, schedule_task, set_work_folder_context

    case notWaitingForInput(taskID: Int)
    /// The same fact for an external agent, which has a second reader of the task: the person.
    /// The feed has no `answered` and no `accepted` kind, so a question the person answers in the
    /// app is never retracted — the agent finishes drafting, calls in, and the bare "not waiting"
    /// reads as a stale id or a bug rather than "the human got there first". Names `task_log`,
    /// whose `from` is the only place that says who spoke (D-M15).
    case notWaitingForInputExternal(taskID: Int)
    case roleNotWaiting(taskID: Int, roleID: String, waitingRoleIDs: [String])
    case answered(taskID: Int)
    /// The answer landed in a task paused in the app, which stays paused
    /// (`NTMSOrchestrator.isPausedInTheApp`).
    case answeredWhilePausedInTheApp(taskID: Int)
    case answerNotDelivered(taskID: Int)
    case messageNotQueued(taskID: Int)
    case messageDiscardedTaskFinished(taskID: Int)
    case messageQueued(taskID: Int)
    case messageQueuedAndResumed(taskID: Int)
    /// The message waits in a task paused in the app, which stays paused.
    case messageQueuedWhilePausedInTheApp(taskID: Int)
    /// Said after a role decision's own reply: it landed in a task the person paused in the app,
    /// which stays paused until they resume it.
    case decisionWaitsForThePersonsResume(taskID: Int)
    case scheduleNotCleared(taskID: Int)
    case scheduleCleared(taskID: Int)
    case scheduleNotStored(taskID: Int)
    case scheduled(taskID: Int, minutes: Int)
    case workFolderContextUpdated
    /// An external agent's `set_work_folder_context` carried the revision it read and the stored
    /// text has another one: the text was replaced after the agent read it, and its write was
    /// refused so as not to discard that (2026-11-13). It names no current revision on purpose —
    /// one copied from a refusal would let the next call replace a text nobody read; the agent
    /// reads it again, beside the text it names.
    case workFolderContextChangedSinceRead

    // MARK: control_task

    /// Durable-state reasons for why `control_task pause` cannot pause a task.
    nonisolated enum PauseFailureReason: String, CaseIterable, Sendable {
        case alreadyClosed = "it is already closed"
        case noActiveRun = "it has no active run"
        case alreadyPaused = "it is already paused"
        case notRunning = "it is not running"
    }

    case alreadyRunning(taskID: Int)
    case started(taskID: Int)
    case couldNotStart(taskID: Int)
    case paused(taskID: Int)
    case couldNotPause(taskID: Int, reason: String)
    case closedNotResumable(taskID: Int)
    case noRunToResume(taskID: Int)
    /// `control_task resume` or `start`, or `manage_role correct`, on a task the person paused in
    /// the app: only they lift that pause, and nothing was changed (D-M18, 2026-11-12). Shared —
    /// the built-in manager is held to the same rule for the person's Pause, not for its own.
    case pausedByThePerson(taskID: Int)
    case resumed(taskID: Int)
    case stopped(taskID: Int)
    case closed(taskID: Int)
    case closeFailed(taskID: Int)
    case deleted(taskID: Int)
    case renamed(taskID: Int, title: String)
    case timeoutCleared(taskID: Int)
    case timeoutSet(taskID: Int)

    // MARK: manage_role

    case noSuchRole(taskID: Int, roleID: String)
    /// `verb` is the action's own name (`RoleVerb.autovisorVerbName`).
    case generationIsNotARole(roleID: String, verb: String)
    case restartWouldDiscard(taskID: Int, roleID: String, toolCalls: Int)
    /// A role parked on `delegate_to_team` emits nothing while the child task works, so it looks
    /// exactly like a role that has stalled — and `AutovisorStuckEvaluator` deliberately returns
    /// `.notStuck` for it, which removes the one signal that would have explained the silence.
    /// `restartRole` cascades to downstream ROLES only, never to child TASKS, so restarting the
    /// parent leaves the child running with nobody to receive its result. The evaluator's own
    /// comment names that harm; until now nothing stopped a caller from doing it.
    case restartWouldOrphanChild(taskID: Int, roleID: String, childTaskID: Int)
    case restarted(taskID: Int, roleID: String)
    case changesRequested(taskID: Int, roleID: String)
    case correctNeedsPause(taskID: Int)
    case corrected(taskID: Int, roleID: String)
    case alreadyClosed(taskID: Int)
    case finishAdvisoryOnProducingRole(taskID: Int, roleID: String)
    case noActiveRun(taskID: Int)
    case accepted(taskID: Int, roleID: String)
    case acceptFailed(roleID: String)
    /// `reason` is `AcceptanceService.routeAccept`'s fact, `remedy` the way out
    /// (`AutovisorStatus.acceptRejectionAdvice`), when there is one.
    case acceptRejected(reason: String, remedy: String?)
    case finishFailed(taskID: Int, roleID: String)
    case advisoryFinished(taskID: Int, roleID: String)
    case chatRoleFinished(taskID: Int, roleID: String, stillActive: [String])
    case chatRoleFinishedAndClosed(taskID: Int, roleID: String)
    /// `reason` is the banner the close surfaced, or `nil` when it surfaced none.
    case chatRoleFinishedCloseFailed(taskID: Int, roleID: String, reason: String?)

    // MARK: The team-generation retry

    case noPendingGeneration(taskID: Int)
    case noLongerLoaded(taskID: Int)
    case generationRerun(taskID: Int)
    case generationInProgress(taskID: Int)
    /// `reason` is the failed `create_team` call's own error, when it recorded one.
    case generationFailedAgain(taskID: Int, reason: String?)
    case generationDidNotRestart(taskID: Int)

    // MARK: The mid-review event notice

    case eventNotice([NTMSOrchestrator.AutovisorAttentionItem])

    /// The outcome a success reports beside its text, for the replies a caller should branch on
    /// rather than read: an answer or a message that left a person's pause standing. `nil` for
    /// every other reply, which is a plain `ok`.
    var outcome: AutovisorActionOutcome? {
        switch self {
        case .answeredWhilePausedInTheApp: .answeredPausedByPerson
        case .messageQueuedWhilePausedInTheApp: .queuedPausedByPerson
        default: nil
        }
    }

    /// Which refusal a failure reply is, for the replies an external agent branches on by code.
    var failureKind: AutovisorActionFailure? {
        switch self {
        case .taskNotFound: .taskNotFound
        case .noSuchRole: .roleNotFound
        case .notWaitingForInput, .notWaitingForInputExternal, .roleNotWaiting: .notWaiting
        case .tooManyRunning, .creationLimitReached, .openTaskLimitReached, .creationWindowLimitReached: .limitReached
        case .pausedByThePerson: .pausedByPerson
        case .workFolderContextChangedSinceRead: .contextChanged
        default: nil
        }
    }

    /// runtime-prompt
    var text: String {
        switch self {
        case .drivenByExternalAgent:
            return "Refused: this work folder's Autovisor is now driven by an external agent, so the manager "
                + "can no longer act here and nothing was changed. End the pass with wait_for_events."
        case .ownTask(let taskID):
            return "Refused: the manager cannot act on its own task (#\(taskID))."
        case .taskNotFound(let taskID):
            return "Task #\(taskID) not found — call list_tasks for current task ids."
        case .tooManyRunning(let count):
            return "Too many tasks already running (\(count)). Wait for some to finish before creating more."
        case .creationLimitReached(let limit):
            return "Per-review task-creation limit (\(limit)) reached this pass — review or finish existing tasks before creating more."
        case .openTaskLimitReached(let count, let limit):
            return "Too many of your tasks are open (\(count) of \(limit)). Close or finish one before creating another; "
                + "folder_status.limits counts them."
        case .creationWindowLimitReached(let limit, let windowMinutes):
            return "Task-creation rate limit reached: \(limit) in the last \(windowMinutes) min. Closing a task does NOT "
                + "refill this window — wait for it to pass. folder_status.limits shows created_in_window and window_minutes."
        case .creationFailed:
            return "Failed to create task."
        case .createdNotStarted(let taskID, let title, let reason):
            return "Created task #\(taskID): \(title). It did NOT start (\(reason ?? "no run was created")) — call "
                + "control_task start on #\(taskID)."
        case .createdAndStarted(let taskID, let title):
            return "Created and started task #\(taskID): \(title)"
        case .createdScheduled(let taskID, let title, let runAt):
            return Self.createdScheduled(for: taskID, title: title, runAt: runAt)
        case .notWaitingForInput(let taskID):
            return "Task #\(taskID) is not waiting for supervisor input."
        case .notWaitingForInputExternal(let taskID):
            return "Task #\(taskID) is not waiting for supervisor input — if it was, it has been answered already, "
                + "possibly by the person in the app. No event reports that; task_log shows every turn with from naming who spoke."
        case .roleNotWaiting(let taskID, let roleID, let waitingRoleIDs):
            if waitingRoleIDs.isEmpty {
                return "Role '\(roleID)' on task #\(taskID) is not waiting for supervisor input (no roles are currently waiting)."
            }
            return "Role '\(roleID)' on task #\(taskID) is not waiting for supervisor input. Waiting roles: \(waitingRoleIDs.joined(separator: ", "))."
        case .answered(let taskID):
            return "Answered task #\(taskID)."
        case .answeredWhilePausedInTheApp(let taskID):
            return "Answered task #\(taskID). The person paused this task in NanoTeams, so it stays paused: the role continues with your answer once they resume it."
        case .answerNotDelivered(let taskID):
            return "Failed to deliver answer to task #\(taskID)."
        case .messageNotQueued(let taskID):
            return "Could not queue message for task #\(taskID)."
        case .messageDiscardedTaskFinished(let taskID):
            return "Message to task #\(taskID) was not queued — the task has already finished. Use manage_role request_changes to reopen a role in Review, or manage_role restart on a closed task."
        case .messageQueued(let taskID):
            return "Queued message for task #\(taskID)."
        case .messageQueuedAndResumed(let taskID):
            return "Queued message for paused task #\(taskID) and resumed the current run to deliver it."
        case .messageQueuedWhilePausedInTheApp(let taskID):
            return "Queued message for task #\(taskID). The person paused this task in NanoTeams, so it stays paused: the role reads your message once they resume it."
        case .decisionWaitsForThePersonsResume(let taskID):
            return "The person paused task #\(taskID) in NanoTeams, so it stays paused: the team acts on this once they resume it."
        case .scheduleNotCleared(let taskID):
            return "Could not clear the schedule for task #\(taskID) — it still has one. Re-read it with task_status."
        case .scheduleCleared(let taskID):
            return "Cleared schedule for task #\(taskID)."
        case .scheduleNotStored(let taskID):
            return "Could not schedule task #\(taskID) — no recurrence was stored."
        case .scheduled(let taskID, let minutes):
            return "Task #\(taskID) will now run every \(minutes) min."
        case .workFolderContextUpdated:
            return "Updated the Work Folder Context."
        case .workFolderContextChangedSinceRead:
            return "The work folder context was replaced after you read it; nothing was written. "
                + "Read it again and start from the text as it stands."
        case .alreadyRunning(let taskID):
            return "Task #\(taskID) is already running."
        case .started(let taskID):
            return "Started task #\(taskID)."
        case .couldNotStart(let taskID):
            return "Task #\(taskID) could not start."
        case .paused(let taskID):
            return "Paused task #\(taskID)."
        case .couldNotPause(let taskID, let reason):
            return "Could not pause task #\(taskID) — \(reason)."
        case .closedNotResumable(let taskID):
            return "Task #\(taskID) is already closed — use manage_role restart to reopen it, or control_task delete to drop it."
        case .noRunToResume(let taskID):
            return "Task #\(taskID) has no run to resume — use control_task start."
        case .pausedByThePerson(let taskID):
            return "Refused: the person paused task #\(taskID) in NanoTeams, and only they can resume it. "
                + "Nothing was changed and the task stays paused; a message_task waits in its queue until they resume it."
        case .resumed(let taskID):
            return "Resumed task #\(taskID)."
        case .stopped(let taskID):
            return "Stopped task #\(taskID)."
        case .closed(let taskID):
            return "Closed task #\(taskID)."
        case .closeFailed(let taskID):
            return "Failed to close task #\(taskID)."
        case .deleted(let taskID):
            return "Deleted task #\(taskID)."
        case .renamed(let taskID, let title):
            return "Renamed task #\(taskID) to \"\(title)\"."
        case .timeoutCleared(let taskID):
            return "Cleared run timeout for task #\(taskID)."
        case .timeoutSet(let taskID):
            return "Set run timeout for task #\(taskID)."
        case .noSuchRole(let taskID, let roleID):
            return "Task #\(taskID) has no role '\(roleID)' — call task_status for valid role_ids."
        case .generationIsNotARole(let roleID, let verb):
            return "'\(roleID)' is team generation, not a role — \(verb) does not apply. "
                + "Use manage_role restart to re-run generation, or control_task delete to drop the task."
        case .restartWouldDiscard(let taskID, let roleID, let toolCalls):
            return "restart would discard \(toolCalls) tool call(s) and the conversation of "
                + "role \(roleID) on paused task #\(taskID). Use manage_role correct to steer it, "
                + "control_task resume to continue it, or control_task stop first to discard deliberately."
        case .restartWouldOrphanChild(let taskID, let roleID, let childTaskID):
            return "Role \(roleID) on task #\(taskID) is not stalled — it is waiting on a delegated task (#\(childTaskID)) "
                + "running on another team, which is why it has emitted nothing. Restarting it would leave that task "
                + "running with nobody to receive its result. Wait for it, or control_task stop the whole task."
        case .restarted(let taskID, let roleID):
            return "Restarted role \(roleID) on task #\(taskID)."
        case .changesRequested(let taskID, let roleID):
            return "Requested changes from role \(roleID) on task #\(taskID)."
        case .correctNeedsPause(let taskID):
            return "correct requires task #\(taskID) to be paused first (use control_task pause)."
        case .corrected(let taskID, let roleID):
            return "Sent correction to role \(roleID) on task #\(taskID)."
        case .alreadyClosed(let taskID):
            return "Task #\(taskID) is already closed."
        case .finishAdvisoryOnProducingRole(let taskID, let roleID):
            return "finish_advisory only applies to chat/advisory roles; \(roleID) on task #\(taskID) is a producing role — accept it when task_status lists it in roles_needing_acceptance, or restart it with guidance."
        case .noActiveRun(let taskID):
            return "Task #\(taskID) has no active run."
        case .accepted(let taskID, let roleID):
            return "Accepted role \(roleID) on task #\(taskID)."
        case .acceptFailed(let roleID):
            return "Could not accept role \(roleID)."
        case .acceptRejected(let reason, let remedy):
            return remedy.map { reason + " — " + $0 } ?? reason
        case .finishFailed(let taskID, let roleID):
            return "Could not finish role \(roleID) on task #\(taskID)."
        case .advisoryFinished(let taskID, let roleID):
            return "Finished advisory role \(roleID) on task #\(taskID)."
        case .chatRoleFinished(let taskID, let roleID, let stillActive):
            return "Finished role \(roleID) on chat task #\(taskID). Still active: \(stillActive.joined(separator: ", ")). A chat task never finishes on its own — use control_task close when you want to end it."
        case .chatRoleFinishedAndClosed(let taskID, let roleID):
            return "Finished role \(roleID) and closed chat task #\(taskID) — no other roles were active."
        case .chatRoleFinishedCloseFailed(let taskID, let roleID, let reason):
            return "Finished role \(roleID) on chat task #\(taskID), but closing it failed: \(reason ?? "unknown"). Retry with control_task close."
        case .noPendingGeneration(let taskID):
            return "Task #\(taskID) has no pending team generation — its team is already in place. "
                + "Use manage_role on a role_id from task_status, or control_task delete "
                + "to drop the task."
        case .noLongerLoaded(let taskID):
            return "Task #\(taskID) is no longer loaded."
        case .generationRerun(let taskID):
            return "Re-ran team generation for task #\(taskID)."
        case .generationInProgress(let taskID):
            return "Team generation for task #\(taskID) is already in progress — "
                + "wait and re-check task_status."
        case .generationFailedAgain(let taskID, let reason):
            return reason.map { "Team generation for task #\(taskID) failed again: \($0)" }
                ?? "Team generation for task #\(taskID) failed again."
        case .generationDidNotRestart(let taskID):
            return "Team generation for task #\(taskID) did not restart."
        case .eventNotice(let items):
            return ([MessageSourceContext.autovisorEventNoticeHeader] + items.map(Self.eventBullet))
                .joined(separator: "\n")
        }
    }

    /// Who receives this reply. `roleNotWaiting` is shared since 2026-11-09: the built-in
    /// manager's `answer_task_question` declares `role_id` too, so it can name a role that is
    /// not waiting exactly as an external agent can.
    var audience: RuntimePromptRegistry.Audience {
        switch self {
        // `restartWouldOrphanChild` is deliberately NOT here: the built-in manager can restart a
        // delegating role too, and the harm is identical, so it is a shared reply like its
        // sibling `restartWouldDiscard`.
        case .openTaskLimitReached,
             .creationWindowLimitReached,
             .notWaitingForInputExternal,
             .createdScheduled,
             .workFolderContextChangedSinceRead:
            return .externalAgent
        default:
            return .localModel
        }
    }

    /// runtime-prompt
    static func createdScheduled(for taskID: Int, title: String, runAt: Date?) -> String {
        if let runAt {
            return "Created task #\(taskID): \(title). Scheduled to run at \(ISO8601DateFormatter().string(from: runAt))."
        } else {
            return "Created task #\(taskID): \(title). Scheduled for one-shot execution."
        }
    }

    /// One bullet of the event notice: the condition and the call that acts on it.
    private static func eventBullet(_ item: NTMSOrchestrator.AutovisorAttentionItem) -> String {
        let task = "Task #\(item.taskID) \"\(item.title)\""
        switch item.trigger {
        case .needsSupervisor:
            return "- \(task) is waiting for a supervisor answer (answer_task_question)."
        case .failed:
            return "- \(task) failed (task_status to triage)."
        case .completed:
            return "- \(task) finished and awaits review (review it, then control_task close)."
        case .acceptanceGate:
            return "- \(task) has a role waiting for acceptance and its pipeline is "
                + "stalled until you decide (task_status, then manage_role accept)."
        case .created:
            return "- New task: \(task) was created."
        case .stuck:
            return "- \(task) looks stuck or looping (task_status / manage_role)."
        }
    }
}

/// The action result carrying a reply of the builder above — the spelling every action uses, so
/// no reply is composed beside it.
extension AutovisorActionResult {
    static func success(_ reply: AutovisorReply, createdTaskID: Int? = nil) -> AutovisorActionResult {
        var result = AutovisorActionResult.success(reply.text, createdTaskID: createdTaskID)
        result.outcome = reply.outcome
        return result
    }

    static func failure(_ reply: AutovisorReply, next: NextHint? = nil) -> AutovisorActionResult {
        var result = AutovisorActionResult.failure(reply.text, next: next)
        result.failure = reply.failureKind
        return result
    }
}
