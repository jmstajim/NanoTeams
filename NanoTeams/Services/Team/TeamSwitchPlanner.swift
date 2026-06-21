import Foundation

/// Pure decisions for `NTMSOrchestrator.switchTeam` — the guard that decides whether a
/// team switch is even allowed, and the run-state recalculation (which steps survive the
/// new roster). Extracted so these branch-free rules are unit-testable without an
/// orchestrator, snapshot, or engine; `switchTeam` keeps the @MainActor I/O
/// (`mutateWorkFolder` / `pauseRun` / `mutateTask`).
///
/// `nonisolated` (app target defaults to `@MainActor`); pure value-in/value-out.
nonisolated enum TeamSwitchPlanner {

    /// Whether the active task may be re-teamed onto `target`. Blocks two symmetric
    /// mis-teamings:
    /// 1. Re-teaming the **Autovisor manager itself** — it is permanently bound to its own
    ///    team; switching would drop its steps/role statuses and break the manager. The id
    ///    compare unwraps `activeTaskID` first: a bare `==` would be true when BOTH ids are
    ///    nil (no active task + no manager pinned) and wrongly block every switch.
    /// 2. Re-teaming a **normal task ONTO the Autovisor team** (`target.isManagedSingleton`)
    ///    — it would acquire the manager's management tools and its scratchpad writes would
    ///    overwrite the real manager's memory (`isAutovisorStep` keys on the team's
    ///    templateID, not the pinned task id).
    static func canSwitchTeam(activeTaskID: Int?, autovisorTaskID: Int?, target: Team) -> Bool {
        if let id = activeTaskID, id == autovisorTaskID { return false }
        if target.isManagedSingleton { return false }
        return true
    }

    /// Steps that survive the switch: those whose role still belongs to the new team.
    /// Steps for roles dropped from the roster are removed (the new team can't run them);
    /// `RunService.initialRoleStatuses(for:)` reinitializes the status map separately.
    static func filteredSteps(_ steps: [StepExecution], forTeamRoleIDs roleIDs: Set<String>) -> [StepExecution] {
        steps.filter { roleIDs.contains($0.effectiveRoleID) }
    }
}
