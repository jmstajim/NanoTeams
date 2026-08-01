import Foundation

/// Pure mutation helpers shared by `RoleEditorSheet.saveRole`.
///
/// Why this exists: the editor sheet receives `team` through a Binding whose
/// getter (`TeamEditorView.binding(for:)`) returns a *captured snapshot* and
/// whose setter spawns an async `mutateWorkFolder` Task. Two consecutive
/// writes through that Binding race — the second write's read-modify-write
/// cycle reads the stale captured snapshot and silently overwrites the
/// first write. Symptom: unchecking a team in the Delegation tab's
/// whitelist was lost whenever `allowDelegationToGeneratedTeams = true`
/// (or any other whitelist entry remained), because that combination set
/// `shouldClearReportsTo = true` and triggered a second `removeValue` write.
///
/// Fix: callers compose every mutation on a local `var newTeam = team` and
/// ship the result via a single Binding write (`team = newTeam`). These
/// helpers own the composition so the rules don't drift between create and
/// edit paths, and they stay covered by `RoleEditorMutationsTests`.
nonisolated enum RoleEditorMutations {

    /// Apply the editor's `.edit` save to `team` in one pass.
    /// Returns `false` if no role matches `existingRoleID` (e.g. a stale UI
    /// state racing against `handleDeleteRole`). On `false`, NEITHER the
    /// role-field edit NOR the hierarchy clear runs — `team` is byte-for-byte
    /// untouched, and the caller must not assign through the Binding.
    @discardableResult
    static func applyEdit(
        to team: inout Team,
        editorState: RoleEditorState,
        existingRoleID: String
    ) -> Bool {
        guard let existing = team.roles.first(where: { $0.id == existingRoleID }) else {
            return false
        }

        var updated = existing
        let dependencies = makeDependencies(from: editorState)
        let llmOverride = makeLLMOverride(from: editorState)
        let finalToolIDs = strippedToolIDs(from: editorState.selectedTools)

        updated.name = editorState.roleName
        updated.icon = editorState.roleIcon
        updated.iconColor = editorState.roleIconColor
        updated.iconBackground = editorState.roleIconBackground

        if updated.isSupervisor {
            // Hierarchy is intentionally not touched in this branch:
            // Supervisor's outgoing `reportsTo` entry would not exist by
            // definition, and incoming entries belong to *other* roles' rows.
            updated.dependencies = RoleDependencies(
                requiredArtifacts: editorState.requiredArtifacts,
                producesArtifacts: [SystemTemplates.supervisorTaskArtifactName]
            )
            updated.prompt = ""
            updated.toolIDs = []
            updated.usePlanningPhase = false
            updated.llmOverride = nil
            updated.allowedDelegationTeamIDs = []
            updated.allowDelegationToGeneratedTeams = false
            // The Supervisor is the user, not an LLM — it has no system prompt
            // for skills to ride, so the field is cleared rather than round-tripped.
            updated.attachedSkillIDs = []
        } else {
            updated.dependencies = dependencies
            updated.prompt = editorState.rolePrompt
            updated.toolIDs = finalToolIDs
            updated.usePlanningPhase = editorState.usePlanningPhase
            updated.llmOverride = llmOverride
            // Persist delegation policy verbatim. The whitelist + generated flag
            // round-trip even when the role isn't currently top-level —
            // re-eligibility is a hierarchy change that shouldn't wipe
            // configured intent.
            updated.allowedDelegationTeamIDs = Array(editorState.selectedDelegationTeamIDs)
            updated.allowDelegationToGeneratedTeams = editorState.allowDelegationToGeneratedTeams
            // Persisted VERBATIM — never through a `Set`, unlike the whitelist
            // above. The order is the order of the `### Skill:` sections in the
            // system prompt, so re-ordering it on save would change segment-0
            // bytes and cost a full prefix re-prefill for no reason.
            updated.attachedSkillIDs = editorState.attachedSkillIDs
        }

        // Route role splice through `Team.updateRole(_:)` — it owns the
        // role + team `updatedAt` bumps internally. Without those bumps,
        // `Team.==`'s id+timestamp shortcut (CLAUDE.md #42) treats the
        // team as unchanged and SwiftUI observers up the chain skip
        // re-render, leaving row closures bound to the PRE-edit role.
        team.updateRole(updated)

        // Hierarchy mutation through `Team.detachFromHierarchy(_:)`,
        // which bumps `team.updatedAt` only when the dict actually
        // changed. When delegation is configured, the role MUST be
        // peer-level with Supervisor — no upstream `reportsTo` entry.
        // Mirrors `TeamTemplateFactory.buildSettings` /
        // `GeneratedTeamBuilder`. Supervisor is excluded by branch.
        if !updated.isSupervisor && shouldClearReportsTo(editorState: editorState) {
            team.detachFromHierarchy(roleID: existingRoleID)
        }

        return true
    }

    /// Apply the editor's `.create` save to `team` in one pass.
    /// Returns the new role's id (derived deterministically from
    /// `<teamID>:<roleName>` via `NTMSID.from(name:)`, matching the prior
    /// inline logic in `RoleEditorSheet.saveRole`).
    @discardableResult
    static func applyCreate(
        to team: inout Team,
        editorState: RoleEditorState,
        teamID: NTMSID
    ) -> NTMSID {
        let now = MonotonicClock.shared.now()
        let newRoleID = NTMSID.from(name: "\(teamID):\(editorState.roleName)")
        let dependencies = makeDependencies(from: editorState)
        let llmOverride = makeLLMOverride(from: editorState)
        let finalToolIDs = strippedToolIDs(from: editorState.selectedTools)

        let newRole = TeamRoleDefinition(
            id: newRoleID,
            name: editorState.roleName,
            icon: editorState.roleIcon,
            prompt: editorState.rolePrompt,
            toolIDs: finalToolIDs,
            usePlanningPhase: editorState.usePlanningPhase,
            dependencies: dependencies,
            llmOverride: llmOverride,
            allowedDelegationTeamIDs: Array(editorState.selectedDelegationTeamIDs),
            allowDelegationToGeneratedTeams: editorState.allowDelegationToGeneratedTeams,
            attachedSkillIDs: editorState.attachedSkillIDs,
            isSystemRole: false,
            systemRoleID: nil,
            iconColor: editorState.roleIconColor,
            iconBackground: editorState.roleIconBackground,
            createdAt: now,
            updatedAt: now
        )

        TeamManagementService.addRole(to: &team, role: newRole)

        // `Team.addRole` does not auto-insert a `reportsTo` entry today,
        // but the symmetric clear is kept as a safety net in case a future
        // factory does — and so the create path mirrors the edit path.
        // `Team.detachFromHierarchy` bumps `team.updatedAt` only when the
        // dict actually changed, so today this is a no-op-with-no-churn.
        if shouldClearReportsTo(editorState: editorState) {
            team.detachFromHierarchy(roleID: newRoleID)
        }

        return newRoleID
    }

    // MARK: - Shared derivations

    /// `SystemTemplates.supervisorTaskArtifactName` is reserved for the
    /// Supervisor role — filter it out of any non-Supervisor producer set.
    private static func makeDependencies(from state: RoleEditorState) -> RoleDependencies {
        let sanitizedProduced = state.producedArtifacts.filter {
            $0 != SystemTemplates.supervisorTaskArtifactName
        }
        return RoleDependencies(
            requiredArtifacts: state.requiredArtifacts,
            producesArtifacts: sanitizedProduced
        )
    }

    /// Empty fields collapse to "use global" (`nil`); an entirely empty
    /// struct round-trips back to nil at save time.
    private static func makeLLMOverride(from state: RoleEditorState) -> LLMOverride? {
        let candidate = LLMOverride(
            baseURLString: state.llmBaseURL.isEmpty ? nil : state.llmBaseURL,
            modelName: state.llmModelName.isEmpty ? nil : state.llmModelName,
            provider: state.llmProviderOverride
        )
        return candidate.isEmpty ? nil : candidate
    }

    private static func strippedToolIDs(from selected: Set<String>) -> [String] {
        Array(selected.subtracting(ToolHandlerRegistry.delegationToolsExcludedFromToolIDs))
    }

    private static func shouldClearReportsTo(editorState: RoleEditorState) -> Bool {
        !editorState.selectedDelegationTeamIDs.isEmpty
            || editorState.allowDelegationToGeneratedTeams
    }
}
