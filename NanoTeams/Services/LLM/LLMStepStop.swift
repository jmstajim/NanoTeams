import Foundation

/// Represents the outcome of a single LLM tool iteration.
/// Used to control the flow of LLM step execution.
enum LLMStepStop {
    /// The LLM completed its work without requesting more tool calls.
    case completed

    /// The LLM requested Supervisor input via the ask_supervisor tool.
    /// The step always pauses until the Supervisor answers.
    case needsSupervisorInput(question: String)

    /// Continue the tool loop for another iteration.
    case continueLoop

    /// A tool call failed in a way that should stop the step.
    /// - Parameter message: The error message describing the failure.
    case toolFailure(message: String)

    // There is deliberately no `needsAcceptance` case. One existed and had ZERO producers in
    // production or in tests, so its arm in `+StepLifecycle` was unreachable. The behaviour it
    // described is not missing: `finishStepGraceful` calls `completeStepNeedsAcceptance` directly
    // (`+StepFlowControl`), which is the live path. A case nothing constructs is not an
    // extension point — it is a claim that a route exists, and the next reader tracing "how does a
    // step reach Supervisor review" would have followed it to a dead end.
}
