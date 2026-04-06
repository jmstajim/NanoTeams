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
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Choose a starting point for your team")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.l)

            // Team name
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Team Name")
                    .font(.subheadline)
                    .fontWeight(.medium)

                TextField("Enter team name", text: $teamName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.l)

            // Template grid
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Template")
                    .font(.subheadline)
                    .fontWeight(.medium)
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

            Divider()

            // Footer buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    onSave(teamName, selectedTemplateID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
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
            icon: "building.2.fill",
            description: "Full product dev pipeline with PM, UX, Engineering, and QA",
            isSelected: true,
            action: {}
        )
        TemplateCard(
            name: "Startup",
            icon: "bolt.fill",
            description: "Lean team with a single Software Engineer",
            isSelected: false,
            action: {}
        )
        TemplateCard(
            name: "Quest Party",
            icon: "shield.fill",
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
                    .font(.title2)
                    .foregroundStyle(isSelected ? Colors.accent : .secondary)

                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
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
