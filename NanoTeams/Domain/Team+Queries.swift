//
//  Team+Queries.swift
//  NanoTeams
//
//  Read-only query / predicate layer for `Team`, split out of the core model
//  (init + Codable + mutations + Hashable) per SRP / GRASP Low-Coupling. Every
//  member here is a pure function of the team's stored fields — no mutation, no
//  I/O — so the query surface is a discoverable, separately-testable unit
//  (`Team+QueriesTests`). The core `Team.swift` keeps the things that change for
//  a *different* reason: schema/Codable, the prompt-template write contract, the
//  CRUD mutators, `duplicate`, and the `(id, updatedAt)` Hashable shortcut.
//
//  `nonisolated` is required: the app target defaults every type to `@MainActor`
//  and a type's `nonisolated` does NOT propagate to its extensions in other
//  files (Грабли from 21fc086). Domain purity = `import Foundation` only.
//

import Foundation

nonisolated extension Team {

    // MARK: - Roster Queries

    /// Number of roles in the team
    var memberCount: Int {
        roles.count
    }

    /// Check if a role exists in this team by ID
    func hasRole(_ roleID: String) -> Bool {
        roles.contains(where: { $0.id == roleID })
    }

    /// Find a role by ID
    func role(withID roleID: String) -> TeamRoleDefinition? {
        roles.first(where: { $0.id == roleID })
    }

    /// Find an artifact by name
    func artifact(withName name: String) -> TeamArtifact? {
        artifacts.first(where: { $0.name == name })
    }

    /// All artifact display names in this team.
    var artifactNames: [String] {
        artifacts.map(\.name)
    }

    /// Roles that produce the given artifact (have it in `producesArtifacts`).
    func rolesProducing(artifactName: String) -> [TeamRoleDefinition] {
        roles.filter { $0.dependencies.producesArtifacts.contains(artifactName) }
    }

    /// Roles that require the given artifact (have it in `requiredArtifacts`).
    func rolesRequiring(artifactName: String) -> [TeamRoleDefinition] {
        roles.filter { $0.dependencies.requiredArtifacts.contains(artifactName) }
    }

    /// Roles excluding Supervisor (the user-controlled role).
    var nonSupervisorRoles: [TeamRoleDefinition] {
        roles.filter { !$0.isSupervisor }
    }

    // MARK: - Tolerant Role Resolution

    /// Find a role by any identifier: TeamRoleDefinition.id (UUID), systemRoleID
    /// (built-in ID), or display name. Exact id/systemRoleID (case-sensitive) and
    /// case-insensitive name matches win first; otherwise a normalized fallback
    /// (lowercase + strip non-alphanumerics) resolves the LLM's snake_case / spaced /
    /// hyphenated guesses — e.g. `software_engineer` → the `softwareEngineer`
    /// (systemRoleID) / "Software Engineer" (name) role. The normalized fallback
    /// resolves only when exactly one role matches; an ambiguous collision returns nil
    /// so the caller surfaces its own error rather than silently binding the wrong role.
    func findRole(byIdentifier identifier: String) -> TeamRoleDefinition? {
        if let role = roles.first(where: { $0.id == identifier }) { return role }
        if let role = roles.first(where: { $0.systemRoleID == identifier }) { return role }
        if let role = roles.first(where: { $0.name.caseInsensitiveCompare(identifier) == .orderedSame }) { return role }

        let target = Self.normalizedRoleIdentifier(identifier)
        guard !target.isEmpty else { return nil }
        let matches = roles.filter { role in
            Self.normalizedRoleIdentifier(role.id) == target
                || role.systemRoleID.map(Self.normalizedRoleIdentifier) == target
                || Self.normalizedRoleIdentifier(role.name) == target
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Lowercased, alphanumerics-only form used for tolerant identifier matching
    /// (`"software_engineer"`, `"Software Engineer"`, `"softwareEngineer"` all → `"softwareengineer"`).
    static func normalizedRoleIdentifier(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Supervisor / Acceptance Derivations

    /// Artifacts that the Supervisor requires before the task can be accepted.
    /// Derived from the Supervisor role's `requiredArtifacts` dependency list.
    var supervisorRequiredArtifacts: [String] {
        let deps = roles.first(where: \.isSupervisor)?.dependencies ?? RoleDependencies()
        let cleaned = deps.requiredArtifacts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(cleaned))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// True when the Supervisor must review specific artifacts before accepting the task.
    var requiresSupervisorFinalReview: Bool {
        !supervisorRequiredArtifacts.isEmpty
    }

    /// True when this team operates in open-ended chat mode (no supervisor deliverables).
    /// Chat-mode tasks have no acceptance flow, no Finish button, and run until paused or closed.
    var isChatMode: Bool {
        supervisorRequiredArtifacts.isEmpty
    }

    // MARK: - Visibility / Authorization Predicates

    /// True when this team can be a *target* of `delegate_to_team`. Chat-mode
    /// teams never produce supervisor deliverables (they never auto-complete),
    /// so they're never valid delegation targets. Single source of truth shared
    /// by the runtime catalog (`DelegateToTeamTool.buildSchema`) and the
    /// role-editor delegation picker (`RoleEditorDelegationPolicy`). Named for
    /// the target side, mirroring `roleIsTopLevelDelegator` on the source side.
    var isValidDelegationTarget: Bool {
        !isChatMode
    }

    /// The completion kind of one role by id, or nil when this team has no such role.
    /// Single source of truth for "which verb ends this role" — the Autovisor's
    /// `manage_role` guards and `task_status`'s `role_kind`. Role ids are safe to key
    /// on: `StepExecution.effectiveRoleID == step.id` and `Team.makeStep` builds the
    /// step from the `TeamRoleDefinition`, so step ids, `roleStatuses` keys and role
    /// ids share one namespace.
    func completionType(forRoleID roleID: String) -> RoleCompletionType? {
        roles.first(where: { $0.id == roleID })?.completionType
    }

    /// True for infrastructure teams that must be hidden from every *task-assignment*
    /// team picker (the Generated Team placeholder and the Autovisor team). They are
    /// never chosen as a regular task's team, a delegation target, or a manager-spawned
    /// task's team. Single source of truth for task-assignment picker / tool-catalog
    /// filtering. NOTE: the Settings → Teams *config editor* is an exception — it uses
    /// `isHiddenFromTeamEditor` instead, so Autovisor shows there as a protected entry.
    var isHiddenFromPickers: Bool {
        templateID == DelegationConstants.generatedTeamSentinel
            || templateID == AutovisorConstants.teamTemplateID
    }

    /// True for teams hidden from the Settings → Teams configuration list. Only the
    /// Generated Team placeholder qualifies (no roles, transient delegation sentinel).
    /// The Autovisor team IS shown in the editor (as a protected, non-deletable,
    /// non-duplicable entry) so it can be inspected/configured like any other team.
    var isHiddenFromTeamEditor: Bool {
        templateID == DelegationConstants.generatedTeamSentinel
    }

    /// True for the managed singleton (the Autovisor team) — a permanent fixture the
    /// user must not delete or duplicate from the editor. Single source of truth for
    /// delete/duplicate protection.
    var isManagedSingleton: Bool {
        templateID == AutovisorConstants.teamTemplateID
    }

    // MARK: - Delegation Predicates

    /// True iff `role` is **peer-level with the human Supervisor** — i.e. has no
    /// upstream entry in `settings.hierarchy.reportsTo` (or the entry points back
    /// to itself). Peer roles act autonomously and don't depend on Supervisor for
    /// completion; they are the eligibility set for `delegate_to_team`.
    ///
    /// Takes `TeamRoleDefinition` (not a string) so the call site resolves
    /// identity once via `findRole(byIdentifier:)` and the predicate operates on
    /// a single canonical id (`role.id`). Supervisor itself is always rejected.
    func roleIsTopLevelDelegator(_ role: TeamRoleDefinition) -> Bool {
        guard !role.isSupervisor else { return false }
        let parent = settings.hierarchy.reportsTo[role.id]
        return parent == nil || parent == role.id
    }

    /// True iff `role` can produce any successful `delegate_to_team` call —
    /// peer-level with Supervisor AND has at least one configured target
    /// (whitelisted team OR generated permission). The 4-tool delegation pack
    /// auto-injects into the LLM schema only when this returns true.
    /// Combines the two structural/configuration halves into one canonical
    /// predicate so callers don't have to chain them manually.
    func delegationEnabled(for role: TeamRoleDefinition) -> Bool {
        roleIsTopLevelDelegator(role) && role.hasDelegationConfigured
    }
}
