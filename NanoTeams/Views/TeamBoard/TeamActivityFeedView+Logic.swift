import SwiftUI

// Pure, unit-testable view-logic seams extracted from TeamActivityFeedView:
// the run-data change-detection hash and the composer-visibility policies.
extension TeamActivityFeedView {

    /// Pure implementation of `runDataVersion` — extracted so it's testable
    /// without instantiating the view. Pinned by
    /// `TeamActivityFeedLogicTests.testComputeRunDataVersion_*`:
    /// must respond to `step.needsSupervisorInput` flipping. The engine's
    /// escalation path (`setNeedsSupervisorInput` from drift/refusal/parse-
    /// failure caps in `LLMExecutionService+StepFlowControl.swift`) flips the
    /// flag without appending a tool call or LLM message — so a hash that only
    /// walked counts left `recomputeAndRebuild` un-triggered and the user had
    /// to switch tasks to force a fresh view rebuild.
    static func computeRunDataVersion(
        run: Run?,
        descendants: [ActivityFeedBuilder.DescendantTask]
    ) -> Int {
        var hasher = Hasher()
        if let run {
            hasher.combine(run.steps.count)
            for step in run.steps {
                hasher.combine(step.llmConversation.count)
                // Catches in-place updates to the last message (e.g. a collapsing
                // retry note) that leave `count` unchanged — same reason
                // `needsSupervisorInput` is folded into this hash.
                hasher.combine(step.llmConversation.last?.createdAt)
                hasher.combine(step.toolCalls.count)
                hasher.combine(step.artifacts.count)
                hasher.combine(step.needsSupervisorInput)
                hasher.combine(step.status)
            }
            for meeting in run.meetings { hasher.combine(meeting.messages.count) }
            hasher.combine(run.changeRequests.count)
        }
        // Fold in descendant runs so child progress triggers rebuilds.
        for descendant in descendants {
            hasher.combine(descendant.task.id)
            hasher.combine(descendant.run.steps.count)
            for step in descendant.run.steps {
                hasher.combine(step.llmConversation.count)
                // Catches in-place updates to the last message (e.g. a collapsing
                // retry note) that leave `count` unchanged — same reason
                // `needsSupervisorInput` is folded into this hash.
                hasher.combine(step.llmConversation.last?.createdAt)
                hasher.combine(step.toolCalls.count)
                hasher.combine(step.artifacts.count)
                hasher.combine(step.needsSupervisorInput)
                hasher.combine(step.status)
            }
            for meeting in descendant.run.meetings { hasher.combine(meeting.messages.count) }
            hasher.combine(descendant.run.changeRequests.count)
        }
        return hasher.finalize()
    }

    /// Whether the composer may auto-resolve to a candidate role when nothing is working
    /// and nothing is asking. True for chat mode (always messageable) and for
    /// resumable-by-send engine states (`.paused`/`.pending`/`.failed`, where a queued
    /// message wakes `resumeRun`). False for `.needsAcceptance` (done, awaiting review) and
    /// the transient `.running` no-working-role gap — there the composer goes inert instead
    /// of naming an arbitrary role. Static seam so the engine-state mapping (the heart of
    /// the inert-on-review / retry-on-failed fix) is unit-testable without mounting the view.
    static func allowsRoleFallback(isChatMode: Bool, engineState: TeamEngineState?) -> Bool {
        if isChatMode { return true }
        switch engineState {
        case .paused, .pending, .failed: return true
        default: return false
        }
    }

    /// Composer visibility policy. The composer stays available on any live task
    /// (not read-only, not closed) so the Supervisor can always send a message —
    /// **including a `.failed` task**, where sending resumes/retries the run (see
    /// `QuickCaptureController.tryFlushQueuedMessages` → `resumeRun`). Chat-mode
    /// tasks keep it alive across every engine state (advisory roles never
    /// self-terminate; state may transiently sit at `.done` after restart while
    /// the task still accepts input). Non-chat tasks hide it only on `.done`/`nil`
    /// (no live run to message).
    static func shouldShowComposer(
        isReadOnly: Bool,
        activeTaskID: Int?,
        closedAt: Date?,
        isChatMode: Bool,
        engineState: TeamEngineState?
    ) -> Bool {
        if isReadOnly { return false }
        guard activeTaskID != nil else { return false }
        guard closedAt == nil else { return false }
        if isChatMode { return true }
        switch engineState {
        case .done, nil: return false
        default:         return true   // .failed falls through → sending resumes the run
        }
    }
}
