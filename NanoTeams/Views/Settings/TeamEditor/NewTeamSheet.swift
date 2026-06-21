import SwiftUI

// MARK: - New Team Sheet

struct NewTeamSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, String?) -> Void

    @State private var teamName = ""
    @State private var selectedTemplateID: String? = nil

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
                                isSelected: selectedTemplateID == template.id || (selectedTemplateID == nil && template.id == "empty")
                            ) {
                                selectedTemplateID = template.id == "empty" ? nil : template.id
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
        print("Created: \(name), template: \(templateID ?? "empty")")
    }
}

#Preview("Template Cards") {
    LazyVGrid(columns: [
        GridItem(.flexible(), spacing: Spacing.m),
        GridItem(.flexible(), spacing: Spacing.m)
    ], spacing: Spacing.m) {
        TemplateCard(
            name: "FAANG",
            icon: "building.2",
            description: "Full product dev pipeline with PM, UX, Engineering, and QA",
            isSelected: true,
            action: {}
        )
        TemplateCard(
            name: "Startup",
            icon: "bolt",
            description: "Lean team with a single Software Engineer",
            isSelected: false,
            action: {}
        )
        TemplateCard(
            name: "Quest Party",
            icon: "shield",
            description: "Adventure module creation with specialized roles",
            isSelected: false,
            action: {}
        )
        TemplateCard(
            name: "Empty",
            icon: "plus.rectangle.on.rectangle",
            description: "Start from scratch",
            isSelected: false,
            action: {}
        )
    }
    .padding(Spacing.xl)
    .frame(width: 520)
    .background(Colors.surfacePrimary)
}

// MARK: - Template Card

struct TemplateCard: View {
    let name: String
    let icon: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Image(systemName: icon)
                    .font(Typography.termXl)
                    .foregroundStyle(isSelected ? Colors.accent : Colors.textSecondary)

                Text(name)
                    .font(Typography.subheadlineMedium)
                    .foregroundStyle(Colors.textPrimary)

                Text(description)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.m)
            .background(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .strokeBorder(
                        isSelected ? Colors.accent : Colors.borderSubtle,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .trackHover($isHovered)
    }

    private var cardBackground: Color {
        if isSelected {
            return Colors.accentTint
        }
        return isHovered
            ? Colors.surfaceHover
            : Colors.surfaceCard
    }
}
