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

    // MARK: - Factory

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

    /// Rewrite every stored reference to an artifact NAME after a rename.
    ///
    /// An artifact's runtime identity is its **name**, not its `id`:
    /// `RoleDependencies.requiredArtifacts` / `producesArtifacts` hold names,
    /// `artifact(withName:)` / `rolesProducing` / `rolesRequiring` /
    /// `supervisorRequiredArtifacts` look up by name, `TeamGraphLayoutCalculator`
    /// builds `[artifactName: roleID]`, and step artifacts are written to
    /// `artifact_<slugify(name)>.md`. So renaming the artifact
    /// WITHOUT this cascade orphans every producer/consumer edge in the team.
    ///
    /// Scope is exactly the two per-role arrays — verified exhaustively against
    /// `Team` / `TeamSettings` / `TeamRoleDefinition` / `TeamGraphLayout`:
    /// everything else that looks name-shaped (`acceptanceCheckpoints`,
    /// `invitableRoles`, `meetingCoordinatorRoleID`, `hierarchy.reportsTo`,
    /// `graphLayout.nodePositions`, `deletedSystemArtifactIDs`) holds role,
    /// team, or artifact **ids**, which a rename deliberately leaves alone.
    ///
    /// The Supervisor is INCLUDED: `supervisorRequiredArtifacts` is derived from
    /// its `requiredArtifacts` and drives `isChatMode` /
    /// `requiresSupervisorFinalReview`, so skipping it would silently flip a
    /// pipeline team into chat mode.
    ///
    /// Rewriting is an **order-preserving dedupe**, not a plain `map`. Order is
    /// load-bearing (it feeds `StepExecution.title` and the `create_artifact`
    /// schema enum), and renaming `A` → `B` on a role that already lists `B`
    /// would otherwise manufacture a duplicate entry — the same artifact twice
    /// in that role's title and twice in its schema enum.
    ///
    /// No-op (including no `updatedAt` bump) when nothing actually changed.
    mutating func renameArtifactReferences(from oldName: String, to newName: String) {
        guard oldName != newName else { return }

        var changed = false
        for index in roles.indices {
            let dependencies = roles[index].dependencies
            let touchesRequired = dependencies.requiredArtifacts.contains(oldName)
            let touchesProduced = dependencies.producesArtifacts.contains(oldName)
            // Only lists that actually named the artifact are rewritten. This is
            // a rename, not a normalizer: deduping a list that never mentioned
            // `oldName` would silently edit an unrelated role's data and mark it
            // as modified.
            guard touchesRequired || touchesProduced else { continue }

            if touchesRequired {
                roles[index].dependencies.requiredArtifacts = Self.rewritingArtifactName(
                    in: dependencies.requiredArtifacts, from: oldName, to: newName)
            }
            if touchesProduced {
                roles[index].dependencies.producesArtifacts = Self.rewritingArtifactName(
                    in: dependencies.producesArtifacts, from: oldName, to: newName)
            }
            roles[index].updatedAt = MonotonicClock.shared.now()
            changed = true
        }

        if changed {
            updatedAt = MonotonicClock.shared.now()
        }
    }

    /// `old` → `new` inside one dependency list, dropping duplicates that the
    /// substitution creates while keeping first-occurrence order.
    private static func rewritingArtifactName(
        in names: [String], from oldName: String, to newName: String
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(names.count)
        for name in names {
            let mapped = name == oldName ? newName : name
            if seen.insert(mapped).inserted {
                result.append(mapped)
            }
        }
        return result
    }

    /// Update team name
    mutating func rename(to newName: String) {
        name = newName
        updatedAt = MonotonicClock.shared.now()
    }

    /// Create a duplicate of this team with a new ID derived from the new name.
    ///
    /// The team, its roles and its artifacts are all copied by MUTATING a copy,
    /// never by rebuilding through the memberwise init. Rebuilding enumerates
    /// fields, so every field the literal forgets silently falls back to its
    /// default — and it still compiles. That bug was live here at BOTH levels,
    /// and "New Team from template" (`TeamEditorView+Actions.handleCreateTeam`,
    /// the only caller besides `TeamManagementService.duplicateTeam`) is the
    /// path that hit it:
    ///
    /// - Team level: all three prompt templates were omitted, so every
    ///   duplicate silently ran `SystemTemplates.genericTemplate` instead of the
    ///   template's own system prompt.
    /// - Role level: `icon`, `iconColor`, `iconBackground`,
    ///   `allowedDelegationTeamIDs` and `allowDelegationToGeneratedTeams` were
    ///   omitted — so a duplicated Coding Agent lost its baked-in delegation
    ///   whitelist (`hasDelegationConfigured` false ⇒ the 4-tool delegation pack
    ///   was never auto-injected) and every role reset to the generic
    ///   `person`/blue avatar.
    ///
    /// Mutate-a-copy is the shape `TeamImportExportService.importTeam` /
    /// `importRole` already use, and it is future-proof: a field added to
    /// `Team` or `TeamRoleDefinition` later carries over with no edit here.
    /// Everything intentionally NOT carried over is reset explicitly below, so
    /// the omissions are decisions rather than oversights.
    func duplicate(withName newName: String? = nil) -> Team {
        let resolvedName = newName ?? "\(name) Copy"

        // Generate deterministic IDs for roles and artifacts from the new team name.
        // Only identity, provenance and timestamps are rewritten; everything else
        // is carried over verbatim.
        let newRoles = roles.map { role -> TeamRoleDefinition in
            var copy = role
            copy.id = NTMSID.from(name: "\(resolvedName):\(role.name)")
            copy.isSystemRole = false  // Duplicated roles are custom
            copy.createdAt = MonotonicClock.shared.now()
            copy.updatedAt = MonotonicClock.shared.now()
            return copy
        }

        let newArtifacts = artifacts.map { artifact -> TeamArtifact in
            var copy = artifact
            copy.id = NTMSID.from(name: "\(resolvedName):artifact:\(artifact.name)")
            copy.isSystemArtifact = false  // Duplicated artifacts are custom
            copy.createdAt = MonotonicClock.shared.now()
            copy.updatedAt = MonotonicClock.shared.now()
            return copy
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

        // Mutate a copy of SELF for the same reason the roles above do. The
        // previous `Team(name:description:roles:artifacts:settings:graphLayout:)`
        // literal silently accepted the memberwise defaults for everything it
        // omitted — including all three prompt templates, which fell back to
        // `SystemTemplates.genericTemplate`. Duplicating any team therefore
        // discarded the one thing that most defines it: "New Team from template"
        // → Coding Agent produced a team running the GENERIC system prompt.
        var copy = self
        let now = MonotonicClock.shared.now()
        copy.id = NTMSID.from(name: resolvedName)
        copy.name = resolvedName
        copy.createdAt = now
        copy.updatedAt = now
        copy.roles = newRoles
        copy.artifacts = newArtifacts
        copy.settings = newSettings
        copy.graphLayout = newGraphLayout
        // A duplicate is a CUSTOM team, and this is deliberate rather than
        // inherited: carrying the id over would make `NTMSRepository+Reconcile`
        // rewrite the copy's prompt templates on every version bump, clobbering
        // the user's edits, and would put two teams behind one template identity
        // in every picker that filters on it.
        copy.templateID = nil
        // Both lists track deletions of SYSTEM roles/artifacts relative to a
        // template. Every role and artifact above was just re-stamped
        // `isSystemRole = false` / `isSystemArtifact = false`, and `templateID`
        // is now nil, so the lists have nothing left to describe.
        copy.deletedSystemRoleIDs = []
        copy.deletedSystemArtifactIDs = []
        return copy
    }

    // MARK: - Bootstrap Defaults

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
