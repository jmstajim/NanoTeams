import Foundation

/// Whether a turn that emitted tool calls counts as the model *acting*, for the
/// purposes of the no-tool-call ceiling (`LLMConstants.maxNonProductiveTurns`).
///
/// **Emitting a parseable call is not acting.** A batch that came back ENTIRELY errors —
/// `tool_not_authorized` for a name the role does not hold, `INVALID_ARGS` for an
/// argument-less envelope — advanced nothing. Zeroing the ceiling for such a turn is what
/// turns "emit one rejected call per turn" into an unbounded loop: the counter never
/// climbs, `maxToolIterations` is `0` (unlimited), and the Autovisor manager is excluded
/// from its own stuck detector, so nothing else is watching.
///
/// That shape is not hypothetical — it is exactly what the bessentinel salvage routes
/// deliberately produce for a hallucinated tool name (they promote the call so the
/// runtime can answer `tool_not_authorized` + "do not retry 'X'", which is strictly more
/// actionable than a silent parse-layer drop). This rule is therefore their
/// PRECONDITION, not an optimisation: without it the salvage trades one loop for
/// another with fewer exits.
///
/// Pure (`nonisolated`) so the rule is pinnable on its own — the production consumer is a
/// single site inside `runOneLLMToolIteration`, which no test can drive end-to-end
/// without a full client + runtime.
nonisolated enum ToolTurnProductivity: Equatable {
    /// At least one tool ran and returned a non-error result. Reset the ceiling.
    case productive

    /// Nothing advanced: every result was an error, or every call was dropped before
    /// execution (nil delegate, or the gate-merge shortfall that leaves `toolResults`
    /// shorter than the emitted calls). Count it against the ceiling.
    case nonProductive

    /// An `ask_supervisor`-only turn. Already counted BEFORE execution, because under
    /// autonomous supervisor mode it is auto-answered and the model can ping itself with
    /// it forever without doing real work. Counting it twice would halve the budget.
    case alreadyCounted

    static func classify(
        isAskSupervisorOnly: Bool,
        toolResults: [ToolExecutionResult]
    ) -> Self {
        if isAskSupervisorOnly { return .alreadyCounted }
        return toolResults.contains(where: { !$0.isError }) ? .productive : .nonProductive
    }
}
