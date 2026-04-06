import Foundation

// MARK: - Role Section

/// Tab sections available in the role editor.
enum RoleSection: String, CaseIterable, Identifiable {
    case general
    case prompt
    case tools
    case dependencies
    case llm

    var id: String { rawValue }

    private static let labelMap: [Self: String] = [
        .general: "General", .prompt: "Prompt", .tools: "Tools",
        .dependencies: "Dependencies", .llm: "LLM",
    ]
    var label: String { Self.labelMap[self] ?? rawValue.capitalized }
}

// MARK: - Role Editor State

/// Consolidated state for `RoleEditorSheet`. Using a single `@State` struct lets SwiftUI
/// track changes through one projected `Binding<RoleEditorState>` with key-path subscripts
/// (`$editorState.roleName`, etc.) instead of 17 separate `@State` properties.
struct RoleEditorState {
    var roleName: String = ""
    var roleIcon: String = "person.fill"
    var rolePrompt: String = ""
    var selectedTools: Set<String> = []
    var usePlanningPhase: Bool = true
    var requiredArtifacts: [String] = []
    var producedArtifacts: [String] = []
    var llmOverrideEnabled: Bool = false
    var llmBaseURL: String = ""
    var llmModelName: String = ""
    var overrideMaxTokens: Int = 0
    var overrideTemperature: Double? = nil
    var availableModels: [String] = []
    var roleIconColor: String = "#FFFFFF"
    var roleIconBackground: String = "#007AFF"
    var activeSection: RoleSection = .general
    var showingPromptPreview: Bool = false

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

        if let override = role.llmOverride, !override.isEmpty {
            llmOverrideEnabled = true
            llmBaseURL = override.baseURLString ?? ""
            llmModelName = override.modelName ?? ""
            overrideMaxTokens = override.maxTokens ?? 0
            overrideTemperature = override.temperature
        }
    }
}
