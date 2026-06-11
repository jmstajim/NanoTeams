//
//  Team.swift
//  NanoTeams
//
//  Represents a team configuration with roles, artifacts, settings, and graph layout.
//

import Foundation

// MARK: - Team

/// Represents a team configuration with per-team roles, artifacts, settings, and graph layout
nonisolated struct Team: Codable, Identifiable {
    var id: NTMSID
    var createdAt: Date
    var updatedAt: Date

    /// Name of the team
    var name: String

    /// Description of the team's purpose and workflow
    var description: String

    /// Template ID this team was created from (e.g., "faang", "questParty"). Nil for custom teams.
    var templateID: String?

    /// Template for the main system prompt sent to roles during step execution.
    /// Uses `{placeholder}` syntax resolved by PromptBuilder.
    var systemPromptTemplate: String

    /// Template for the system prompt sent to teammates during consultations.
    var consultationPromptTemplate: String

    /// Template for the system prompt sent to meeting participants.
    var meetingPromptTemplate: String

    /// Team-specific role definitions
    var roles: [TeamRoleDefinition]

    /// Team-specific artifacts
    var artifacts: [TeamArtifact]

    /// Settings for this team
    var settings: TeamSettings

    /// Visual layout of the team graph
    var graphLayout: TeamGraphLayout

    /// System role IDs (`TeamRoleDefinition.systemRoleID`) that the user has
    /// explicitly deleted from this team. Prevents version-bump reconcile from
    /// resurrecting them. Cleared by "Restore Default Teams".
    var deletedSystemRoleIDs: [String]

    /// System artifact IDs (`TeamArtifact.id`) that the user has explicitly deleted
    /// from this team. Prevents version-bump reconcile from resurrecting them.
    /// Cleared by "Restore Default Teams".
    var deletedSystemArtifactIDs: [String]

    // MARK: - Initialization

    init(
        id: NTMSID? = nil,
        createdAt: Date = MonotonicClock.shared.now(),
        updatedAt: Date = MonotonicClock.shared.now(),
        name: String,
        description: String = "",
        templateID: String? = nil,
        systemPromptTemplate: String = SystemTemplates.genericTemplate,
        consultationPromptTemplate: String = SystemTemplates.genericConsultationTemplate,
        meetingPromptTemplate: String = SystemTemplates.genericMeetingTemplate,
        roles: [TeamRoleDefinition],
        artifacts: [TeamArtifact],
        settings: TeamSettings,
        graphLayout: TeamGraphLayout,
        deletedSystemRoleIDs: [String] = [],
        deletedSystemArtifactIDs: [String] = []
    ) {
        self.id = id ?? NTMSID.from(name: name)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.name = name
        self.description = description
        self.templateID = templateID
        self.systemPromptTemplate = systemPromptTemplate
        self.consultationPromptTemplate = consultationPromptTemplate
        self.meetingPromptTemplate = meetingPromptTemplate
        self.roles = roles
        self.artifacts = artifacts
        self.settings = settings
        self.graphLayout = graphLayout
        self.deletedSystemRoleIDs = deletedSystemRoleIDs
        self.deletedSystemArtifactIDs = deletedSystemArtifactIDs
    }

    /// Convenience initializer for tests: creates minimal team with empty roles/artifacts and default settings
    init(name: String) {
        self.init(
            name: name,
            roles: [],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )
    }

    // MARK: - Prompt Template Mutation

    /// Identifies one of the three prompt-template fields. Used as the typed
    /// surface for `assignPromptTemplate(_:value:clock:)` — narrower than
    /// `WritableKeyPath<Team, String>` (which would also accept `\.name`,
    /// `\.description`, etc., bypassing the prompt-template contract).
    enum PromptField {
        case system
        case consultation
        case meeting

        fileprivate var keyPath: WritableKeyPath<Team, String> {
            switch self {
            case .system: return \.systemPromptTemplate
            case .consultation: return \.consultationPromptTemplate
            case .meeting: return \.meetingPromptTemplate
            }
        }
    }

    /// Writes `value` to the selected prompt-template field and bumps
    /// `updatedAt` on every real change. Idempotent on no-op writes (skip
    /// equal-value assignment so binding round-trips don't burn timestamps).
    ///
    /// **Why this exists.** `Team.==` is `(id, updatedAt)`-only — a perf
    /// shortcut documented at the bottom of this file. Without bumping
    /// `updatedAt`, SwiftUI's view diff treats a Team whose template body
    /// changed as identical to the pre-write one and skips re-evaluating
    /// downstream views (visible regression: "Reset to Default" in the
    /// Prompts tab silently did nothing until the user navigated away and
    /// back, because `PromptTemplateEditor.updateNSView` never received the
    /// new value). Routing every prompt-template write through this method
    /// keeps the `(id, updatedAt)` contract honest.
    mutating func assignPromptTemplate(
        _ field: PromptField,
        value: String,
        clock: MonotonicClock = .shared
    ) {
        let keyPath = field.keyPath
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
        self.updatedAt = clock.now()
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case updatedAt
        case name
        case description
        case templateID
        case systemPromptTemplate
        case consultationPromptTemplate
        case meetingPromptTemplate
        case roles
        case artifacts
        case settings
        case graphLayout
        case deletedSystemRoleIDs
        case deletedSystemArtifactIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(NTMSID.self, forKey: .id)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? MonotonicClock.shared.now()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? MonotonicClock.shared.now()
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.templateID = try c.decodeIfPresent(String.self, forKey: .templateID)
        self.systemPromptTemplate = try c.decodeIfPresent(String.self, forKey: .systemPromptTemplate)
            ?? SystemTemplates.genericTemplate
        self.consultationPromptTemplate = try c.decodeIfPresent(String.self, forKey: .consultationPromptTemplate)
            ?? SystemTemplates.genericConsultationTemplate
        self.meetingPromptTemplate = try c.decodeIfPresent(String.self, forKey: .meetingPromptTemplate)
            ?? SystemTemplates.genericMeetingTemplate
        self.roles = try c.decode([TeamRoleDefinition].self, forKey: .roles)
        self.artifacts = try c.decode([TeamArtifact].self, forKey: .artifacts)
        self.settings = try c.decodeIfPresent(TeamSettings.self, forKey: .settings) ?? .default
        self.graphLayout = try c.decodeIfPresent(TeamGraphLayout.self, forKey: .graphLayout) ?? .default
        self.deletedSystemRoleIDs = try c.decodeIfPresent([String].self, forKey: .deletedSystemRoleIDs) ?? []
        self.deletedSystemArtifactIDs = try c.decodeIfPresent([String].self, forKey: .deletedSystemArtifactIDs) ?? []
    }

    // MARK: - Computed Properties

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

    /// True when this team can be a *target* of `delegate_to_team`. Chat-mode
    /// teams never produce supervisor deliverables (they never auto-complete),
    /// so they're never valid delegation targets. Single source of truth shared
    /// by the runtime catalog (`DelegateToTeamTool.buildSchema`) and the
    /// role-editor delegation picker (`RoleEditorDelegationPolicy`). Named for
    /// the target side, mirroring `roleIsTopLevelDelegator` on the source side.
    var isValidDelegationTarget: Bool {
        !isChatMode
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

    /// Creates a new pending `StepExecution` for the given role ID.
    /// Returns `nil` if no role with that ID exists in this team.
    func makeStep(forRoleID roleID: String) -> StepExecution? {
        guard let roleDef = roles.first(where: { $0.id == roleID }) else { return nil }
        return StepExecution.make(for: roleDef)
    }

    // MARK: - Mutations

    /// Add a role to the team
    mutating func addRole(_ role: TeamRoleDefinition) {
        roles.append(role)

        // Add node position if missing
        if !graphLayout.nodePositions.contains(where: { $0.roleID == role.id }) {
            let pos = graphLayout.nextNodePosition()
            graphLayout.nodePositions.append(TeamNodePosition(roleID: role.id, x: pos.x, y: pos.y))
        }

        updatedAt = MonotonicClock.shared.now()
    }

    /// Remove a role from the team, cleaning up all references.
    ///
    /// If the removed role is a system role (`isSystemRole == true` with a non-nil
    /// `systemRoleID`), its `systemRoleID` is appended to `deletedSystemRoleIDs`
    /// so subsequent version-bump reconciles won't resurrect it.
    mutating func removeRole(_ roleID: String) {
        if let removed = roles.first(where: { $0.id == roleID }),
           removed.isSystemRole,
           let sid = removed.systemRoleID,
           !deletedSystemRoleIDs.contains(sid)
        {
            deletedSystemRoleIDs.append(sid)
        }
        roles.removeAll(where: { $0.id == roleID })
        graphLayout.hiddenRoleIDs.remove(roleID)
        graphLayout.nodePositions.removeAll(where: { $0.roleID == roleID })
        // Clean hierarchy: remove as subordinate and re-parent any of its subordinates
        settings.hierarchy.reportsTo.removeValue(forKey: roleID)
        for (sub, sup) in settings.hierarchy.reportsTo where sup == roleID {
            settings.hierarchy.reportsTo.removeValue(forKey: sub)
        }
        if settings.meetingCoordinatorRoleID == roleID {
            settings.meetingCoordinatorRoleID = nil
        }
        settings.invitableRoles.remove(roleID)
        settings.acceptanceCheckpoints.remove(roleID)
        updatedAt = MonotonicClock.shared.now()
    }

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

    /// Update a role in the team. Bumps both the role's `updatedAt`
    /// (via `withUpdatedTimestamp`) and the team's `updatedAt` so SwiftUI
    /// observers re-evaluate through `Team.==`'s id+timestamp shortcut
    /// (see CLAUDE.md #42). Silently no-ops if no role matches
    /// `updatedRole.id` — callers that need failure-on-missing must
    /// pre-validate via `roles.contains(where:)`.
    mutating func updateRole(_ updatedRole: TeamRoleDefinition) {
        if let index = roles.firstIndex(where: { $0.id == updatedRole.id }) {
            roles[index] = updatedRole.withUpdatedTimestamp()
            updatedAt = MonotonicClock.shared.now()
        }
    }

    /// Remove a role's upstream `reportsTo` entry, making it peer-level
    /// with Supervisor. Bumps `team.updatedAt` iff the dictionary
    /// actually changed — no-op for already-peer roles so non-delegating
    /// edits don't churn SwiftUI observers.
    mutating func detachFromHierarchy(roleID: String) {
        if settings.hierarchy.reportsTo.removeValue(forKey: roleID) != nil {
            updatedAt = MonotonicClock.shared.now()
        }
    }

    /// Add an artifact to the team
    mutating func addArtifact(_ artifact: TeamArtifact) {
        artifacts.append(artifact)
        updatedAt = MonotonicClock.shared.now()
    }

    /// Remove an artifact from the team.
    ///
    /// If the removed artifact is a system artifact (`isSystemArtifact == true`),
    /// its `id` is appended to `deletedSystemArtifactIDs` so subsequent
    /// version-bump reconciles won't resurrect it.
    mutating func removeArtifact(_ artifactID: String) {
        if let removed = artifacts.first(where: { $0.id == artifactID }),
           removed.isSystemArtifact,
           !deletedSystemArtifactIDs.contains(removed.id)
        {
            deletedSystemArtifactIDs.append(removed.id)
        }
        artifacts.removeAll(where: { $0.id == artifactID })
        updatedAt = MonotonicClock.shared.now()
    }

    /// Update an artifact in the team
    mutating func updateArtifact(_ updatedArtifact: TeamArtifact) {
        if let index = artifacts.firstIndex(where: { $0.id == updatedArtifact.id }) {
            artifacts[index] = updatedArtifact.withUpdatedTimestamp()
            updatedAt = MonotonicClock.shared.now()
        }
    }

    /// Update team name
    mutating func rename(to newName: String) {
        name = newName
        updatedAt = MonotonicClock.shared.now()
    }

    /// Create a duplicate of this team with a new ID derived from the new name.
    func duplicate(withName newName: String? = nil) -> Team {
        let resolvedName = newName ?? "\(name) Copy"

        // Generate deterministic IDs for roles and artifacts from the new team name
        let newRoles = roles.map { role in
            TeamRoleDefinition(
                id: NTMSID.from(name: "\(resolvedName):\(role.name)"),
                name: role.name,
                prompt: role.prompt,
                toolIDs: role.toolIDs,
                usePlanningPhase: role.usePlanningPhase,
                dependencies: role.dependencies,
                llmOverride: role.llmOverride,
                isSystemRole: false,  // Duplicated roles are custom
                systemRoleID: role.systemRoleID
            )
        }

        let newArtifacts = artifacts.map { artifact in
            TeamArtifact(
                id: NTMSID.from(name: "\(resolvedName):artifact:\(artifact.name)"),
                name: artifact.name,
                icon: artifact.icon,
                mimeType: artifact.mimeType,
                description: artifact.description,
                isSystemArtifact: false,  // Duplicated artifacts are custom
                systemArtifactName: artifact.systemArtifactName
            )
        }

        // Build old → new role ID mapping
        var roleIDMapping: [String: String] = [:]
        for (index, originalRole) in roles.enumerated() {
            if index < newRoles.count {
                roleIDMapping[originalRole.id] = newRoles[index].id
            }
        }

        // Update graph layout with new role IDs
        var newGraphLayout = graphLayout
        for i in 0..<newGraphLayout.nodePositions.count {
            let oldRoleID = newGraphLayout.nodePositions[i].roleID
            if let newID = roleIDMapping[oldRoleID] {
                newGraphLayout.nodePositions[i].roleID = newID
            }
        }
        newGraphLayout.hiddenRoleIDs = Set(
            graphLayout.hiddenRoleIDs.compactMap { roleIDMapping[$0] }
        )

        let newSettings = settings.remappingRoleIDs(roleIDMapping)

        return Team(
            name: resolvedName,
            description: description,
            roles: newRoles,
            artifacts: newArtifacts,
            settings: newSettings,
            graphLayout: newGraphLayout
        )
    }

    // MARK: - Bootstrap Defaults

    /// Roles excluding Supervisor (the user-controlled role).
    var nonSupervisorRoles: [TeamRoleDefinition] {
        roles.filter { !$0.isSupervisor }
    }

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

    /// All built-in team templates.
    static var defaultTeams: [Team] { TeamTemplateFactory.allTemplates }

    /// Default team (FAANG configuration).
    static var `default`: Team { TeamTemplateFactory.faang() }
}

// MARK: - Hashable

nonisolated extension Team: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(updatedAt)
    }

    static func == (lhs: Team, rhs: Team) -> Bool {
        lhs.id == rhs.id &&
        lhs.updatedAt == rhs.updatedAt
    }
}
