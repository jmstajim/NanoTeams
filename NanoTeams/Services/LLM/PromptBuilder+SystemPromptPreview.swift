import Foundation

/// System prompt preview and tool parameter parsing for Settings UI.
extension PromptBuilder {

    /// Builds a preview of the system prompt for a role without requiring full execution context.
    /// Used in Settings UI to show what prompt would be sent to the LLM.
    static func buildSystemPromptPreview(
        roleDefinition: TeamRoleDefinition,
        toolDefinitions: [ToolDefinitionRecord],
        team: Team?
    ) -> String {
        let role = Role.fromDefinition(roleDefinition)

        // Filter tools based on role definition
        let roleToolIDs = roleDefinition.toolIDs
        let availableTools = toolDefinitions.filter { roleToolIDs.contains($0.id) }

        let toolNames = availableTools.map { $0.name }.sorted()
        let toolList = toolNames.isEmpty ? "No tools are available for this step." : ""

        // Get role guidance
        var roleGuidance = roleDefinition.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if roleGuidance.isEmpty {
            roleGuidance = SystemTemplates.roles[role.baseID]?.prompt ?? ""
        }

        // Get expected artifacts from role dependencies
        let expectedArtifactNames = roleDefinition.dependencies.producesArtifacts
        var artifactInstructions: [String] = []
        for artifactName in expectedArtifactNames {
            if let match = team?.artifacts.first(where: { $0.name == artifactName }) {
                if !match.description.isEmpty {
                    artifactInstructions.append("- For \(match.name): \(match.description)")
                }
            }
        }

        let expectedArtifactsLine = expectedArtifactNames.isEmpty
            ? "(none specified)"
            : expectedArtifactNames.sorted().joined(separator: ", ")
        let artifactInstructionsBlock = artifactInstructions.isEmpty
            ? ""
            : "\nArtifact Instructions:\n" + artifactInstructions.joined(separator: "\n")

        // Build team context
        let teamContext = buildTeamContext(team: team)
        let positionContext = buildPositionContext(roleDefinition: roleDefinition, team: team)
        let teamDescriptionLine = buildTeamDescriptionLine(team: team)

        // Resolve template
        let template = team?.systemPromptTemplate ?? SystemTemplates.genericTemplate
        let hasFileReadTools = !Set(toolNames).isDisjoint(with: ToolHandlerRegistry.fileReadTools)
        let contextAwareness = buildContextAwarenessGuidance(hasFileReadTools: hasFileReadTools)

        let placeholders: [String: String] = [
            "roleName": roleDefinition.name,
            "teamName": team?.name ?? "(unknown team)",
            "teamDescription": teamDescriptionLine,
            "teamRoles": teamContext,
            "stepInfo": "You are step 1 of 1. (preview)",
            "positionContext": positionContext,
            "roleGuidance": roleGuidance,
            "contextAwareness": contextAwareness,
            "workFolderContext": "(work folder details appear here at runtime)",
            "toolList": toolList,
            "expectedArtifacts": expectedArtifactsLine,
            "artifactInstructions": artifactInstructionsBlock,
        ]

        var result = TemplateResolver.resolve(template, placeholders: placeholders)

        // Append tools summary
        let toolsSuffix: String
        if !availableTools.isEmpty {
            let toolsSummary = availableTools.map { tool in
                let params = parseToolParameters(tool: tool)
                return "- \(tool.name)(\(params))"
            }.joined(separator: "\n")
            toolsSuffix = "\n\nAvailable tools:\n\(toolsSummary)"
            result += toolsSuffix
        } else {
            toolsSuffix = ""
        }

        return result
    }

    /// Returns the raw template, placeholder values, and tools suffix for colored preview rendering.
    /// Used by `PromptPreviewSheet` to highlight resolved placeholder values.
    static func buildSystemPromptPreviewComponents(
        roleDefinition: TeamRoleDefinition,
        toolDefinitions: [ToolDefinitionRecord],
        team: Team?
    ) -> (template: String, placeholders: [String: String], toolsSuffix: String) {
        let role = Role.fromDefinition(roleDefinition)

        let roleToolIDs = roleDefinition.toolIDs
        let availableTools = toolDefinitions.filter { roleToolIDs.contains($0.id) }
        let toolNames = availableTools.map { $0.name }.sorted()
        let toolList = toolNames.isEmpty ? "No tools are available for this step." : ""

        var roleGuidance = roleDefinition.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if roleGuidance.isEmpty {
            roleGuidance = SystemTemplates.roles[role.baseID]?.prompt ?? ""
        }

        let expectedArtifactNames = roleDefinition.dependencies.producesArtifacts
        var artifactInstructions: [String] = []
        for artifactName in expectedArtifactNames {
            if let match = team?.artifacts.first(where: { $0.name == artifactName }) {
                if !match.description.isEmpty {
                    artifactInstructions.append("- For \(match.name): \(match.description)")
                }
            }
        }

        let expectedArtifactsLine = expectedArtifactNames.isEmpty
            ? "(none specified)"
            : expectedArtifactNames.sorted().joined(separator: ", ")
        let artifactInstructionsBlock = artifactInstructions.isEmpty
            ? ""
            : "\nArtifact Instructions:\n" + artifactInstructions.joined(separator: "\n")

        let teamContext = buildTeamContext(team: team)
        let positionContext = buildPositionContext(roleDefinition: roleDefinition, team: team)
        let teamDescriptionLine = buildTeamDescriptionLine(team: team)

        let template = team?.systemPromptTemplate ?? SystemTemplates.genericTemplate
        let hasFileReadTools = !Set(toolNames).isDisjoint(with: ToolHandlerRegistry.fileReadTools)
        let contextAwareness = buildContextAwarenessGuidance(hasFileReadTools: hasFileReadTools)

        let placeholders: [String: String] = [
            "roleName": roleDefinition.name,
            "teamName": team?.name ?? "(unknown team)",
            "teamDescription": teamDescriptionLine,
            "teamRoles": teamContext,
            "stepInfo": "You are step 1 of 1. (preview)",
            "positionContext": positionContext,
            "roleGuidance": roleGuidance,
            "contextAwareness": contextAwareness,
            "workFolderContext": "(work folder details appear here at runtime)",
            "toolList": toolList,
            "expectedArtifacts": expectedArtifactsLine,
            "artifactInstructions": artifactInstructionsBlock,
        ]

        var toolsSuffix = ""
        if !availableTools.isEmpty {
            let toolsSummary = availableTools.map { tool in
                let params = parseToolParameters(tool: tool)
                return "- \(tool.name)(\(params))"
            }.joined(separator: "\n")
            toolsSuffix = "\n\nAvailable tools:\n\(toolsSummary)"
        }

        return (template, placeholders, toolsSuffix)
    }

    /// Helper to parse tool parameters from a ToolDefinitionRecord.
    static func parseToolParameters(tool: ToolDefinitionRecord) -> String {
        guard let properties = tool.parameters.properties else {
            return ""
        }
        return properties.keys.sorted().joined(separator: ", ")
    }
}
