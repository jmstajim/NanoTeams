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

    /// An open-ended role (no output artifacts) finished without tool calls.
    /// The step transitions to `.needsApproval` for Supervisor review.
    case needsAcceptance
}
