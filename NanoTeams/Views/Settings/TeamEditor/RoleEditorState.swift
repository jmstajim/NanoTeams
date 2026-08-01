import Foundation

// MARK: - Role Section

/// Tab sections available in the role editor.
nonisolated enum RoleSection: String, CaseIterable, Identifiable {
    case general
    case prompt
    case tools
    case dependencies
    case skills
    case llm
    case delegation

    var id: String { rawValue }

    private static let labelMap: [Self: String] = [
        .general: "General", .prompt: "Prompt", .tools: "Tools",
        .dependencies: "Dependencies", .skills: "Skills",
        .llm: "LLM", .delegation: "Delegation",
    ]
    var label: String { Self.labelMap[self] ?? rawValue.capitalized }
}

// MARK: - Role Editor State

/// Consolidated state for `RoleEditorSheet`. Using a single `@State` struct lets SwiftUI
/// track changes through one projected `Binding<RoleEditorState>` with key-path subscripts
/// (`$editorState.roleName`, etc.) instead of 17 separate `@State` properties.
nonisolated struct RoleEditorState {
    var roleName: String = ""
    var roleIcon: String = "person"
    var rolePrompt: String = ""
    var selectedTools: Set<String> = []
    /// Off for a NEW role. The phase is a multi-turn read-and-plan stretch now,
    /// not the single `update_scratchpad` call it used to be, so it is opt-in
    /// everywhere except the Software Engineer template.
    var usePlanningPhase: Bool = false
    var requiredArtifacts: [String] = []
    var producedArtifacts: [String] = []
    var llmBaseURL: String = ""
    var llmModelName: String = ""
    /// `nil` = inherit the global provider. Set when the override URL points
    /// at a different provider's server (mirrors `LLMOverride.provider`).
    var llmProviderOverride: LLMProvider? = nil
    var availableModels: [String] = []
    /// Populated when the override-model fetch fails. Cleared on every fetch
    /// attempt; rendered in the LLM tab so the user knows why the picker is
    /// stale instead of seeing nothing change.
    var llmModelFetchError: String?
    var roleIconColor: String = "#FFFFFF"
    var roleIconBackground: String = "#007AFF"
    var activeSection: RoleSection = .general
    var showingPromptPreview: Bool = false
    /// Whitelist of project teams this role may delegate to.
    var selectedDelegationTeamIDs: Set<NTMSID> = []
    /// When `true`, the role can pass `team_id == "generated"` to spin up new teams.
    var allowDelegationToGeneratedTeams: Bool = false
    /// Agent skills attached to this role, as scanner ids.
    ///
    /// An ORDERED array, deliberately not a `Set` like the delegation whitelist
    /// beside it: this order is the order of the `### Skill:` sections in the
    /// system prompt, i.e. segment-0 bytes. `Array(Set<String>)` yields a
    /// different order per process (Swift seeds string hashing per launch), so a
    /// no-op re-save would reshuffle the prompt and cost a full re-prefill.
    var attachedSkillIDs: [String] = []

    /// Pure value constructor for the `.edit` mode of `RoleEditorSheet`.
    /// Used by the sheet's `init` to seed `@State` synchronously, so the
    /// very first body evaluation already reflects the role's persisted
    /// fields. Replaces the previous `.onAppear { load(from: role) }`
    /// pattern, which left a window between first render and onAppear
    /// during which the view rendered with the default-empty state and
    /// any user input landing in that window raced against the load.
    static func loaded(from role: TeamRoleDefinition) -> RoleEditorState {
        var state = RoleEditorState()
        state.load(from: role)
        return state
    }

    mutating func load(from role: TeamRoleDefinition) {
        roleName = role.name
        roleIcon = role.icon
        roleIconColor = role.iconColor
        roleIconBackground = role.iconBackground
        rolePrompt = role.prompt
        selectedTools = Set(role.toolIDs)
        usePlanningPhase = role.usePlanningPhase
        requiredArtifacts = role.dependencies.requiredArtifacts
        producedArtifacts = role.dependencies.producesArtifacts

        // Override fields seed from the persisted struct directly. With no
        // master toggle, the runtime treats empty fields as "use global"
        // and a fully-empty struct round-trips back to `nil` at save time.
        if let override = role.llmOverride {
            llmBaseURL = override.baseURLString ?? ""
            llmModelName = override.modelName ?? ""
            llmProviderOverride = override.provider
        }

        // Delegation: whitelist + generated flag round-trip directly from the
        // role definition. Auto-injection of the 4-tool delegation pack derives
        // from these two fields alone (see `LLMExecutionService+ToolResolution`).
        selectedDelegationTeamIDs = Set(role.allowedDelegationTeamIDs)
        allowDelegationToGeneratedTeams = role.allowDelegationToGeneratedTeams
        // Verbatim — order is meaningful (see `attachedSkillIDs`).
        attachedSkillIDs = role.attachedSkillIDs
    }

    /// The role as it would be saved RIGHT NOW, from the in-flight draft.
    ///
    /// Lets tabs run the real resolvers (tool schemas, prompt preview) against the
    /// unsaved edit instead of re-deriving each rule from `RoleEditorState` fields —
    /// the duplication that let the editor's "Auto-injected" list drift from what
    /// the runtime actually injects. Lives on the state because the state owns the
    /// draft (Information Expert); every consumer must build it the same way, since
    /// a dropped field here is a silently wrong preview.
    func provisionalDefinition(mode: EditorMode<TeamRoleDefinition>) -> TeamRoleDefinition {
        var role: TeamRoleDefinition
        if case .edit(let existing) = mode {
            role = existing
        } else {
            role = TeamRoleDefinition(
                id: UUID().uuidString,
                name: "",
                prompt: "",
                toolIDs: [],
                usePlanningPhase: false,
                dependencies: RoleDependencies(),
                isSystemRole: false,
                systemRoleID: nil)
        }

        role.name = roleName
        role.icon = roleIcon
        role.iconColor = roleIconColor
        role.iconBackground = roleIconBackground
        role.prompt = rolePrompt
        role.toolIDs = Array(selectedTools)
        role.usePlanningPhase = usePlanningPhase
        role.dependencies = RoleDependencies(
            requiredArtifacts: requiredArtifacts,
            producesArtifacts: producedArtifacts
        )
        let override = LLMOverride(
            baseURLString: llmBaseURL.isEmpty ? nil : llmBaseURL,
            modelName: llmModelName.isEmpty ? nil : llmModelName,
            provider: llmProviderOverride
        )
        role.llmOverride = override.isEmpty ? nil : override
        role.allowedDelegationTeamIDs = Array(selectedDelegationTeamIDs)
        role.allowDelegationToGeneratedTeams = allowDelegationToGeneratedTeams
        role.attachedSkillIDs = attachedSkillIDs
        return role
    }
}
