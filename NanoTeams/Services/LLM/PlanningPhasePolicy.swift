import Foundation

/// Pure decisions for the role step's optional "planning phase" — the first-iteration
/// detour that swaps the system prompt to a PLANNING PHASE brief and narrows the tool
/// set to `update_scratchpad` so the model commits to a plan before acting.
///
/// Extracted from `LLMExecutionService+StepFlowControl.applyPlanningPhase` so the
/// *policy* (when to enter, what prompt, which tools, when to restore, what the marker
/// is) is separated from the @MainActor *I/O* (persisting the conversation, mutating
/// `executionStates`, re-writing the system message). The orchestration keeps the side
/// effects; this enum owns only the branch-free logic — unit-testable without a
/// delegate, a task, or a session (house pattern: `LoopRecoveryPolicy`,
/// `MessageKeyPolicy`, `DesignatedCoordinatorResolver`, `VocabExpansionScorer`).
///
/// `nonisolated` is required (app target defaults types to `@MainActor`); the policy is
/// pure value-in/value-out so it composes from any context including tests.
nonisolated enum PlanningPhasePolicy {

    /// The sentinel the swapped-in planning prompt carries. Centralized so the two sites
    /// that detect "is the live system prompt the planning one" — the restore gate in
    /// `applyPlanningPhase` and the plain-prose fallback in `handleNoToolCalls` — can
    /// never drift from the text emitted by `basePlanningPrompt`.
    static let planningPhaseMarker = "PLANNING PHASE"

    /// True on the step's genuine first working iteration: no plan recorded yet, no tool
    /// call has executed, and not a supervisor-driven revision (a revision re-enters with
    /// a saved session + feedback, never "first iteration" work — entering planning there
    /// would clobber the just-appended revision message).
    static func isFirstIteration(
        scratchpadIsNil: Bool,
        hasNoRecentCalls: Bool,
        revisionCommentIsNil: Bool
    ) -> Bool {
        scratchpadIsNil && hasNoRecentCalls && revisionCommentIsNil
    }

    /// Enter planning iff the role opts in, it is the first iteration, AND the role's
    /// tool set actually includes `update_scratchpad` (the only tool offered during
    /// planning — without it the phase has nothing to call).
    static func shouldEnterPlanning(
        isFirstIteration: Bool,
        usePlanningPhase: Bool,
        hasScratchpadTool: Bool
    ) -> Bool {
        usePlanningPhase && isFirstIteration && hasScratchpadTool
    }

    /// Whether the tool set contains `update_scratchpad`.
    static func hasScratchpadTool(in tools: [ToolSchema]) -> Bool {
        tools.contains { $0.name == ToolNames.updateScratchpad }
    }

    /// The single tool exposed during the planning phase: `update_scratchpad` only.
    /// Returns an empty array when the role has no scratchpad tool (defensive — the
    /// caller only invokes this after `shouldEnterPlanning`, which already gated on it).
    static func planningTools(from tools: [ToolSchema]) -> [ToolSchema] {
        tools.filter { $0.name == ToolNames.updateScratchpad }
    }

    /// The base PLANNING PHASE system prompt (the caller inserts `globalContext` via
    /// `TemplateResolver.insertingGlobalGuidance` — before the `## Final reminder`).
    /// Intentionally omits an inline tool-call example: `buildToolSchemaSection`
    /// already appends one `## Tool Calling` block to every system prompt, and a
    /// second example in a different syntax produces mixed-format output on
    /// smaller models.
    ///
    /// `expectedArtifacts` interpolates the role's deliverable contract — the
    /// swap replaces the base prompt's `## Deliverables`, so without it the
    /// plan was made blind to the artifact names it must target.
    static func basePlanningPrompt(roleName: String, expectedArtifacts: [String] = []) -> String {
        let deliverables = expectedArtifacts.isEmpty
            ? ""
            : "\nYour plan must end with producing: "
                + expectedArtifacts.map { "\"\($0)\"" }.joined(separator: ", ") + ".\n"
        return """
        ## Role
        \(roleName)

        ## PLANNING PHASE
        Before starting work, create your plan.

        Call `update_scratchpad` with a short numbered list of the concrete steps you will take.
        \(deliverables)
        ## Final reminder
        update_scratchpad is the only tool available now. After you record your plan, you get your full toolset.
        """
    }

    /// True when `content` is (or contains) a planning-phase system prompt — keyed on the
    /// shared `planningPhaseMarker`. A nil prompt is never a planning prompt.
    static func isPlanningSystemPrompt(_ content: String?) -> Bool {
        content?.contains(planningPhaseMarker) == true
    }

    /// Restore the saved original prompt iff one was stashed AND the live system message
    /// is still the planning one (guards against restoring over a prompt that was already
    /// swapped back, or over a fresh chain that never entered planning).
    static func shouldRestorePlanningPrompt(
        hasSavedPrompt: Bool,
        systemContainsPlanningPhase: Bool
    ) -> Bool {
        hasSavedPrompt && systemContainsPlanningPhase
    }
}
