import Foundation

/// The tool result a `delegate_to_team` call gets when the process died while it was awaiting
/// its child — written at RECOVERY time, because the handler that would have written it is gone.
///
/// ## Why the call has to be closed at all
///
/// `delegate_to_team` suspends inside the handler on `TaskCompletionAwaiter.register`, and that
/// continuation cannot survive a process restart. The assistant turn carrying the call IS
/// committed (incrementally, by `commitStreaming`); the tool result is written only by the
/// handler's terminal arms, so after a crash the step's conversation ends on a call with no
/// answer. `pauseRun`'s own comment already names what that costs: an unresolved
/// `delegate_to_team` tool_call has "no clean restart path on resume".
///
/// The wire is NOT OpenAI-shaped — both request builders render tool calls as Harmony text
/// appended to `content`, so there is no `tool_call_id` to pair and no HTTP 400 to hit. The
/// damage is semantic, and for a small local model it is worse than a protocol error would be:
/// replayed, the model sees its own `delegate_to_team` call with nothing after it, and its
/// honest readings are "still in flight" (wait forever), "re-issue" (spawn a second child), or
/// "call `cancel_delegation`" — which, after recovery clears the marker, rejects with
/// INVALID_ARGS. So the closure must be self-describing rather than merely present.
///
/// `nonisolated` because `StatusRecoveryService` is, and `makeErrorEnvelope` is a top-level
/// `nonisolated func` — no isolation gymnastics needed. House pattern: `ConversationReplay`,
/// `RoleStepReconciler`, `LoopRecoveryPolicy`.
nonisolated enum DelegationInterruptionEnvelope {

    /// The LLM-facing error envelope.
    ///
    /// The code stays `DELEGATION_INTERRUPTED` rather than collapsing into `COMMAND_FAILED`:
    /// the awaiter already emits `COMMAND_FAILED` for "the child ran and failed", and merging
    /// them would make "your child failed, read its output" indistinguishable from "your child
    /// never ran" — the two states need different next moves.
    static func envelope(childTaskID: Int) -> String {
        makeErrorEnvelope(
            code: .delegationInterrupted,
            message: "The app restarted while this delegation was in flight, so it did not "
                + "complete. Team \(childTaskID)'s work is NOT available to you, and nothing is "
                + "waiting on it any more. Decide fresh: delegate again if the work still needs "
                + "doing, or continue without it.",
            details: ["child_task_id": String(childTaskID)]
        )
    }

    /// The persisted tool message: the envelope wrapped in the same `[CALL]…[RESULT]` composite
    /// every other tool message carries.
    ///
    /// It restates the tool name and the child id because the transcript being replayed may not
    /// contain the call — `persistWireTranscript` has no arm on the delegation await, so
    /// `wireTranscript` on disk is typically from the PREVIOUS suspend or empty. Same rule
    /// `ConversationRepairService` follows when it truncates a poisoned tail: restate the
    /// critical context you removed, or the reference points at nothing the model can see.
    static func toolMessage(childTaskID: Int) -> String {
        TaskMutationService.toolResultComposite(
            toolName: ToolNames.delegateToTeam,
            argumentsJSON: "{\"child_task_id\":\(childTaskID)}",
            resultJSON: envelope(childTaskID: childTaskID)
        )
    }
}
