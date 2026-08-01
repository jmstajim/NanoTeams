import SwiftUI

// MARK: - New Team Sheet

struct NewTeamSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// `(name, templateID)` — the templateID is always a `TeamTemplateFactory.templateMetadata`
    /// id, including the synthetic `emptyTemplateID`. It is deliberately NOT optional: `nil`
    /// used to be a magic alias for the "Empty Team" card, which let a second meaning
    /// ("this id didn't resolve") share the same branch — and that branch cloned FAANG.
    let onSave: (String, String) -> Void

    @State private var teamName = ""
    @State private var selectedTemplateID = TeamTemplateFactory.emptyTemplateID

    private let templates = TeamTemplateFactory.templateMetadata

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: Spacing.s) {
                Text("New Team")
                    .font(Typography.termXl)
                    .foregroundStyle(Colors.textPrimary)

                Text("Choose a starting point for your team")
                    .font(Typography.subheadline)
                    .foregroundStyle(Colors.textSecondary)
            }
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.l)

            // Team name
            VStack(alignment: .leading, spacing: Spacing.s) {
                MonoLabel(text: "Team Name", rule: true)

                TextField("Enter team name", text: $teamName)
                    .textFieldStyle(.plain)
                    .terminalField()
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.l)

            // Template grid
            VStack(alignment: .leading, spacing: Spacing.s) {
                MonoLabel(text: "Template", rule: true)
                    .padding(.horizontal, Spacing.xl)

                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: Spacing.m),
                        GridItem(.flexible(), spacing: Spacing.m)
                    ], spacing: Spacing.m) {
                        ForEach(templates, id: \.id) { template in
                            TemplateCard(
                                name: template.name,
                                icon: template.icon,
                                description: template.description,
                                isSelected: selectedTemplateID == template.id
                            ) {
                                selectedTemplateID = template.id
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.m)
                }
            }

            TerminalDivider()

            // Footer buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.terminalSecondary)

                Spacer()

                Button("Create") {
                    onSave(teamName, selectedTemplateID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.terminalPrimary)
                .disabled(teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(Spacing.standard)
        }
        .frame(width: 520, height: 520)
    }
}

#Preview("New Team Sheet") {
    NewTeamSheet { name, templateID in
        print("Created: \(name), template: \(templateID)")
    }
}

// `TemplateCard` lives in Views/DesignSystem/TemplateCard.swift — shared with
// the Autovisor goal preset picker.
