import Foundation

/// Decides, from two observations of one task, whether the Supervisor has now SEEN
/// the questions it is being asked — and which Watchtower banners that retires.
///
/// Pure and total so it can be unit-tested; `MainLayoutView` only applies the result.
/// The rules it replaces lived inline in an `onChange(of: TaskStatus?)` closure and
/// got two things wrong that no test could reach:
///
/// 1. The observed value was derived from `store.activeTaskID`, so a COLD LAUNCH
///    (`nil → something`) and an active-task SWITCH (A's state → B's state) both
///    looked like "this task's state changed", and the not-viewing branch cleared a
///    seen flag that had just been loaded from disk.
/// 2. It carried a `Bool`. In chat mode every assistant turn is another
///    `ask_supervisor` call, so "waiting → waiting" is the common case and a boolean
///    can't tell a second question from the first one still standing.
///
/// Hence: identity sets, and `.none` for anything that is not a genuine same-task
/// transition.
nonisolated enum SupervisorSeenPolicy {

    /// One task's active questions at one moment. `questionIDs` are
    /// `StepToolCall.id`s — persisted, so they are stable across a relaunch.
    ///
    /// `isWaiting` (`NTMSTask.hasPendingSupervisorInput`) rides alongside because a
    /// flag-only escalation (drift / refusal-loop cap flips `needsSupervisorInput`
    /// without appending an ask call) is a question with NO identity: the ID set
    /// alone reads it as "quiet", and the policy would clear a flag the user just
    /// earned by reading the escalation, or miss its arrival entirely.
    struct Observation: Equatable {
        let taskID: Int
        let questionIDs: Set<UUID>
        let isWaiting: Bool

        init(taskID: Int, questionIDs: Set<UUID>, isWaiting: Bool) {
            self.taskID = taskID
            self.questionIDs = questionIDs
            self.isWaiting = isWaiting
        }
    }

    enum SeenAction: Equatable {
        case none
        case mark(taskID: Int)
        case clear(taskID: Int)
    }

    struct Decision: Equatable {
        let seen: SeenAction
        /// Questions to retire from the Watchtower inbox because the Supervisor is
        /// looking at them right now. Only ever a subset of what just appeared.
        let dismissQuestionIDs: Set<UUID>

        static let none = Decision(seen: .none, dismissQuestionIDs: [])
    }

    /// The Supervisor navigated to a task and is now looking at it.
    ///
    /// Returns only a `SeenAction`: the navigation path already retires EVERY banner
    /// of the opened task (not just supervisor questions), so a per-question dismiss
    /// set here would be an unwired half — computed, tested, and discarded.
    ///
    /// Clearing when nothing is pending is not a no-op dressed up: it keeps the
    /// invariant "seen ⟹ there was something to see". Marking a quiet task seen
    /// freezes its flag, and the sweep — which only clears tasks that are NOT
    /// waiting — then refuses to touch it once it finally asks something, so that
    /// question would never light the sidebar. `isWaiting` covers the identity-less
    /// escalation question: the task IS asking, so opening it is seeing it.
    static func onOpen(taskID: Int, questionIDs: Set<UUID>, isWaiting: Bool) -> SeenAction {
        (questionIDs.isEmpty && !isWaiting) ? .clear(taskID: taskID) : .mark(taskID: taskID)
    }

    /// The active task's questions were re-observed.
    ///
    /// Acts only on a genuine same-task transition. A nil `previous` (cold launch, or
    /// the first observation after a work-folder switch) and a change of `taskID`
    /// both carry no transition information — reading them as one is what destroyed
    /// the persisted "seen" flag on every launch.
    static func onChange(
        previous: Observation?,
        current: Observation?,
        isViewing: Bool
    ) -> Decision {
        guard let current else { return .none }
        guard let previous, previous.taskID == current.taskID else { return .none }

        let appeared = current.questionIDs.subtracting(previous.questionIDs)
        if !appeared.isEmpty {
            return isViewing
                ? Decision(seen: .mark(taskID: current.taskID), dismissQuestionIDs: appeared)
                : Decision(seen: .clear(taskID: current.taskID), dismissQuestionIDs: [])
        }
        // Answered: either the identified questions emptied, or the waiting fact
        // dropped. Clear in both readings so the NEXT question relights the dot —
        // and if an identity-less escalation still stands while q1 was answered,
        // clearing is again right: the user has not read the escalation.
        if (current.questionIDs.isEmpty && !previous.questionIDs.isEmpty)
            || (!current.isWaiting && previous.isWaiting) {
            return Decision(seen: .clear(taskID: current.taskID), dismissQuestionIDs: [])
        }
        // Flag-only escalation arrived: waiting rose with no new question ID. There
        // is no identity to retire from the inbox (its banner keys on question
        // text), so the dismiss set stays empty either way.
        if current.isWaiting, !previous.isWaiting {
            return Decision(
                seen: isViewing
                    ? .mark(taskID: current.taskID)
                    : .clear(taskID: current.taskID),
                dismissQuestionIDs: [])
        }
        return .none
    }
}
