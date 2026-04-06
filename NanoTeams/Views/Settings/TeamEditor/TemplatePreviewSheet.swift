import SwiftUI

// MARK: - Template Preview Sheet

/// Sheet showing the resolved prompt template for a selected role.
struct TemplatePreviewSheet: View {
    let team: Team
    let templateType: TemplateType
    @State private var selectedRoleID: String?

    enum TemplateType {
        case system
        case consultation
        case meeting
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with role picker
            HStack {
                Text("Template Preview")
                    .font(.headline)
                Spacer()
                Picker("Role", selection: $selectedRoleID) {
                    ForEach(nonSupervisorRoles) { role in
                        Text(role.name).tag(Optional(role.id))
                    }
                }
                .frame(width: 200)
            }
            .padding()

            Divider()

            // Resolved prompt with highlighted placeholders
            ScrollView {
                Text(resolvedAttributedPrompt)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            selectedRoleID = nonSupervisorRoles.first?.id
        }
    }

    private var nonSupervisorRoles: [TeamRoleDefinition] {
        team.nonSupervisorRoles
    }

    private var resolvedAttributedPrompt: AttributedString {
        guard let roleID = selectedRoleID,
              let role = team.roles.first(where: { $0.id == roleID }) else {
            return AttributedString("(select a role)")
        }

        let templateStr: String
        let values: [String: String]
        let definitions: [(key: String, label: String, category: String)]

        switch templateType {
        case .system:
            templateStr = team.systemPromptTemplate
            values = systemPlaceholderValues(for: role)
            definitions = SystemTemplates.systemPromptPlaceholders
        case .consultation:
            templateStr = team.consultationPromptTemplate
            values = consultationPlaceholderValues(for: role)
            definitions = SystemTemplates.consultationPlaceholders
        case .meeting:
            templateStr = team.meetingPromptTemplate
            values = meetingPlaceholderValues(for: role)
            definitions = SystemTemplates.meetingPlaceholders
        }

        return buildHighlightedPrompt(template: templateStr, values: values, definitions: definitions)
    }

    private func systemPlaceholderValues(for role: TeamRoleDefinition) -> [String: String] {
        let teamRoles = team.nonSupervisorRoles.map(\.name).joined(separator: ", ")
        return [
            "roleName": role.name,
            "teamName": team.name,
            "teamDescription": team.description,
            "teamRoles": teamRoles,
            "stepInfo": "You are step 1 of 1. (preview)",
            "positionContext": buildPositionContext(for: role),
            "roleGuidance": role.prompt,
            "toolList": role.toolIDs.isEmpty ? "No tools available." : "(tools available at runtime)",
            "expectedArtifacts": role.dependencies.producesArtifacts.joined(separator: ", "),
            "artifactInstructions": buildArtifactInstructions(for: role),
            "contextAwareness": "(context awareness guidance available at runtime)",
        ]
    }

    private func consultationPlaceholderValues(for role: TeamRoleDefinition) -> [String: String] {
        [
            "consultedRoleName": role.name,
            "requestingRoleName": "(requesting role)",
            "roleGuidance": role.prompt,
            "teamDescription": team.description,
        ]
    }

    private func meetingPlaceholderValues(for role: TeamRoleDefinition) -> [String: String] {
        [
            "speakerName": role.name,
            "roleGuidance": role.prompt,
            "meetingTopic": "(meeting topic)",
            "turnNumber": "1",
            "coordinatorHint": "",
            "teamDescription": team.description,
        ]
    }

    // MARK: - Highlighted Prompt Builder

    private func buildHighlightedPrompt(
        template: String,
        values: [String: String],
        definitions: [(key: String, label: String, category: String)]
    ) -> AttributedString {
        TemplatePlaceholderHighlighter.resolve(
            template: template, values: values, definitions: definitions
        )
    }

    private func buildPositionContext(for role: TeamRoleDefinition) -> String {
        var parts: [String] = []
        let required = role.dependencies.requiredArtifacts
        let produces = role.dependencies.producesArtifacts

        if !required.isEmpty {
            let producers = required.compactMap { artifactName in
                team.rolesProducing(artifactName: artifactName).first?.name
            }
            if !producers.isEmpty {
                parts.append("You work after \(producers.joined(separator: ", "))")
            }
            parts.append("Receives: \(required.joined(separator: ", "))")
        }
        if !produces.isEmpty {
            parts.append("Produces: \(produces.joined(separator: ", "))")
        }
        return parts.isEmpty ? "(no dependencies)" : parts.joined(separator: ". ")
    }

    private func buildArtifactInstructions(for role: TeamRoleDefinition) -> String {
        var instructions: [String] = []
        for name in role.dependencies.producesArtifacts {
            if let artifact = team.artifacts.first(where: { $0.name == name }), !artifact.description.isEmpty {
                instructions.append("- For \(artifact.name): \(artifact.description)")
            }
        }
        return instructions.isEmpty ? "" : "\nArtifact Instructions:\n" + instructions.joined(separator: "\n")
    }
}

// MARK: - Previews

#Preview("System Template") {
    TemplatePreviewSheet(team: Team.default, templateType: .system)
        .frame(width: 700, height: 1000)
}

#Preview("Consultation Template") {
    TemplatePreviewSheet(team: Team.default, templateType: .consultation)
        .frame(width: 700, height: 1000)
}

#Preview("Meeting Template") {
    TemplatePreviewSheet(team: Team.default, templateType: .meeting)
        .frame(width: 700, height: 1000)
}
