import SwiftUI

// MARK: - Prompt Preview Sheet

/// Read-only preview of the full system prompt that will be sent to the LLM.
/// Resolved placeholder values are highlighted with category-matching colors (same as editor chips).
struct PromptPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let roleDefinition: TeamRoleDefinition
    let toolDefinitions: [ToolDefinitionRecord]
    let team: Team?

    /// Plain text for clipboard copy.
    private var previewText: String {
        PromptBuilder.buildSystemPromptPreview(
            roleDefinition: roleDefinition,
            toolDefinitions: toolDefinitions,
            team: team
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Full Prompt Preview")
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(previewText, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.m)

            Divider()

            // Prompt content with colored placeholder values
            ScrollView {
                Text(highlightedPrompt)
                    .textSelection(.enabled)
                    .padding(Spacing.standard)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    // MARK: - Highlighted Prompt

    private var highlightedPrompt: AttributedString {
        let components = PromptBuilder.buildSystemPromptPreviewComponents(
            roleDefinition: roleDefinition,
            toolDefinitions: toolDefinitions,
            team: team
        )

        var result = TemplatePlaceholderHighlighter.resolve(
            template: components.template,
            values: components.placeholders,
            definitions: SystemTemplates.systemPromptPlaceholders
        )

        // Append tools suffix as plain text
        if !components.toolsSuffix.isEmpty {
            let monoFont = Font.system(.body, design: .monospaced)
            var suffix = AttributedString(components.toolsSuffix)
            suffix.font = monoFont
            result.append(suffix)
        }

        return result
    }
}

// MARK: - Previews

#Preview("Prompt Preview") {
    let team = Team.default
    let role = team.nonSupervisorRoles.first!
    PromptPreviewSheet(
        roleDefinition: role,
        toolDefinitions: ToolDefinitionRecord.defaultDefinitions(),
        team: team
    )
    .frame(width: 700, height: 1100)
}
