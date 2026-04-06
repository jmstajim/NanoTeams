import SwiftUI

// MARK: - Team Prompts Detail View

/// View for editing team prompt templates (system, consultation, meeting).
/// Shows one template at a time via a picker to reduce visual clutter.
/// Displayed under the "Prompts" tab in TeamEditorView.
struct TeamPromptsDetailView: View {
    @Binding var team: Team
    let onSave: () -> Void

    @State private var selectedTemplate: PromptTemplate = .system
    @State private var showPreview = false
    @State private var pendingInsertion: String?

    var body: some View {
        VStack(spacing: 0) {
            // Underline tab bar
            HStack(spacing: Spacing.standard) {
                ForEach(PromptTemplate.allCases) { template in
                    Button {
                        selectedTemplate = template
                    } label: {
                        VStack(spacing: 4) {
                            Text(template.label)
                                .font(.subheadline)
                                .fontWeight(selectedTemplate == template ? .semibold : .regular)
                                .foregroundStyle(selectedTemplate == template ? .primary : .secondary)

                            Rectangle()
                                .fill(selectedTemplate == template ? Colors.accent : .clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.top, Spacing.s)

            // Description
            Text(selectedTemplate.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.standard)
                .padding(.top, Spacing.s)

            // Editor
            PromptTemplateEditor(
                template: templateBinding,
                pendingInsertion: $pendingInsertion,
                placeholders: selectedTemplate.placeholders
            )
            .frame(maxHeight: .infinity)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .onChange(of: templateBinding.wrappedValue) { _, _ in onSave() }

            Divider()

            // Actions bar
            HStack {
                InsertVariableButton(
                    placeholders: selectedTemplate.placeholders,
                    onInsert: { placeholder in
                        pendingInsertion = placeholder
                    }
                )

                Spacer()

                Button("Preview") {
                    showPreview = true
                }

                Button("Reset to Default") {
                    resetCurrentTemplate()
                }
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.s)
        }
        .sheet(isPresented: $showPreview) {
            TemplatePreviewSheet(team: team, templateType: selectedTemplate.previewType)
        }
        .onChange(of: selectedTemplate) { _, _ in
            pendingInsertion = nil
        }
    }

    // MARK: - Helpers

    private var templateBinding: Binding<String> {
        Binding(
            get: { team[keyPath: selectedTemplate.keyPath] },
            set: { team[keyPath: selectedTemplate.keyPath] = $0 }
        )
    }

    private func resetCurrentTemplate() {
        team[keyPath: selectedTemplate.keyPath] = selectedTemplate.defaultTemplate(for: team.templateID)
        onSave()
    }

    // MARK: - Supporting Types

    private enum PromptTemplate: String, CaseIterable, Identifiable {
        case system
        case consultation
        case meeting

        var id: String { rawValue }

        private static let metadata: [PromptTemplate: (
            label: String,
            description: String,
            keyPath: WritableKeyPath<Team, String>,
            placeholders: [(key: String, label: String, category: String)],
            previewType: TemplatePreviewSheet.TemplateType,
            defaultTemplate: (String?) -> String
        )] = [
            .system: (
                "System",
                "The main prompt sent to each role during step execution. Use variables to inject role-specific context.",
                \.systemPromptTemplate,
                SystemTemplates.systemPromptPlaceholders,
                .system,
                { SystemTemplates.defaultSystemTemplate(for: $0) }
            ),
            .consultation: (
                "Consultation",
                "Prompt for teammate consultations via the ask_teammate tool.",
                \.consultationPromptTemplate,
                SystemTemplates.consultationPlaceholders,
                .consultation,
                { SystemTemplates.defaultConsultationTemplate(for: $0) }
            ),
            .meeting: (
                "Meeting",
                "Prompt for meeting participants during team meetings.",
                \.meetingPromptTemplate,
                SystemTemplates.meetingPlaceholders,
                .meeting,
                { SystemTemplates.defaultMeetingTemplate(for: $0) }
            ),
        ]

        var label: String { Self.metadata[self]!.label }
        var description: String { Self.metadata[self]!.description }
        var keyPath: WritableKeyPath<Team, String> { Self.metadata[self]!.keyPath }
        var placeholders: [(key: String, label: String, category: String)] { Self.metadata[self]!.placeholders }
        var previewType: TemplatePreviewSheet.TemplateType { Self.metadata[self]!.previewType }
        func defaultTemplate(for templateID: String?) -> String { Self.metadata[self]!.defaultTemplate(templateID) }
    }
}

// MARK: - Previews

#Preview("Prompts Editor") {
    @Previewable @State var team = Team.default
    TeamPromptsDetailView(team: $team, onSave: {})
        .frame(width: 600, height: 500)
}
