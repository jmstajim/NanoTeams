import Foundation

/// Whether the Generated Team pane should show a failure (error text + Retry) rather than
/// the "Generating team…" spinner.
///
/// Pure and split out of `GraphPanelView` because the wedge this encodes is unreachable
/// from a view test: the panel's computed properties are private, and the state that
/// produces the bug (a synthetic generation step left `.running`/`.paused` with nothing
/// in flight) only arises across an app restart or a `pauseRun`.
nonisolated enum GeneratedTeamPanelState {

    /// Failure is anything PENDING but not LIVE.
    ///
    /// The ordering matters and each term earns its place:
    ///  - not pending (a team is adopted, or the template isn't "generated") ⇒ nothing to
    ///    have failed;
    ///  - an errored `create_team` placeholder is the ordinary failure;
    ///  - a `.failed` synthetic step is the ordinary failure when the placeholder is gone;
    ///  - a task whose run hasn't started has nothing to have failed;
    ///  - otherwise LIVENESS decides.
    ///
    /// The liveness term is the fallback for EVERY remaining shape, not just "no step at
    /// all". An earlier cut returned `stepStatus == .failed` outright whenever a step
    /// survived, which meant the most common orphan never reached it: generation is in
    /// flight when the app quits, `StatusRecoveryService` parks the synthetic step
    /// `.running` → `.paused` on relaunch, and the in-memory in-flight set is empty. The
    /// step exists and isn't `.failed`, so the pane claimed to be generating forever —
    /// Retry hidden, no error text, the user's only exit being to delete the task. Same
    /// outcome after `pauseRun` cancels a generation whose step was already injected.
    ///
    /// - Parameter isGenerationInFlight: `NTMSOrchestrator.isGeneratingTeam(taskID:)`. It
    ///   is `@ObservationIgnored`, so it cannot drive a re-render on its own — it doesn't
    ///   need to. It is read here purely to SUPPRESS a false failure during the window
    ///   between `startRun` and the step's injection, never to claim liveness.
    static func failed(
        isPending: Bool,
        toolCallIsError: Bool,
        stepStatus: StepStatus?,
        hasRun: Bool,
        isGenerationInFlight: Bool
    ) -> Bool {
        guard isPending else { return false }
        if toolCallIsError { return true }
        if stepStatus == .failed { return true }
        guard hasRun else { return false }
        return !isGenerationInFlight
    }

    /// Heading for the overlay `failed` turns on.
    ///
    /// A CANCELLED generation is not a failure. `runTeamGeneration`'s `.failure` arm sets
    /// `toolCall.isError = true` for cancellations too (only the step status and the
    /// suppressed banner differ), so the pane read "Team generation failed" over the
    /// message "Team generation was cancelled" — two contradictory sentences, one of which
    /// blames the app for something the user did. A `.paused` step is also the shape
    /// `StatusRecoveryService` produces for a generation interrupted by an app quit or
    /// left behind by a destroyed record — all resumable, none a failure.
    static func failureTitle(stepStatus: StepStatus?) -> String {
        stepStatus == .paused ? "Team generation paused" : "Team generation failed"
    }

    /// Detail line under the heading. The recorded envelope message is authoritative; the
    /// fallbacks cover the shapes where there is no record left to read.
    ///
    /// Returning `nil` is what the pane used to do: `generationToolCall` resolves through
    /// `step.toolCalls`, and `StepExecution.reset()` empties that array — so a destroyed
    /// record produced a heading with no diagnosis and nothing to distinguish it from a
    /// generation that was never attempted.
    static func failureMessage(recorded: String?, stepStatus: StepStatus?) -> String {
        if let recorded, !recorded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return recorded
        }
        switch stepStatus {
        case .paused, .running:
            return "Team generation was interrupted before it finished. Retry to generate the team."
        case .pending:
            // The record was cleared by a `restartRole` reset. `StatusRecoveryService`
            // settles this shape at every load seam, so it should only be reachable
            // within the session that produced it.
            return "The team-generation record was cleared before it finished. Retry to generate the team."
        case nil:
            return "Team generation hasn't started yet. Retry to generate the team."
        default:
            return "Team generation didn't finish. Retry to generate the team."
        }
    }
}
