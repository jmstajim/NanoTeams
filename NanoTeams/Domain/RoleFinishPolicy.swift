import Foundation

/// Single source of truth for "may the Supervisor finish this advisory role right now?"
///
/// This is the *view-layer* rule behind the graph node's "Finish Role" affordance:
/// an advisory role, in a non-chat team, currently `.ready` or `.working`. Before this
/// type existed the rule was duplicated inline across `TeamGraphView` (the `onFinish`
/// nil-map) and `RoleNodeRuntimeView` (the menu-item guard), composing correctly only
/// because the parent nil-mapped the closure — a drift-enabler the tests re-typed rather
/// than pinned.
///
/// It deliberately encodes `!isChatMode`: in a chat team the Supervisor ends the whole
/// conversation via task Close, not per-role finish. The Autovisor's `manage_role`
/// verbs therefore do NOT consult this policy — a chat finish is exactly what they
/// route to Close, so reusing this here would reject the case they need to allow. They
/// use their own point checks (`AcceptanceService.routeAccept` and a `completionType`
/// guard) instead.
nonisolated enum RoleFinishPolicy {
    /// True when the graph's "Finish Role" affordance should be offered for this role.
    static func canFinish(
        roleDef: TeamRoleDefinition?,
        status: RoleExecutionStatus,
        isChatMode: Bool
    ) -> Bool {
        guard let roleDef, roleDef.isAdvisory, !isChatMode else { return false }
        return status == .ready || status == .working
    }
}
