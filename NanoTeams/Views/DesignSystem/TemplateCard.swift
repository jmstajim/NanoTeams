import SwiftUI

// MARK: - Template Card

/// Selectable preset/template card: SF Symbol + name + 2-line description with
/// accent border/tint when selected and hover feedback. Shared by the team
/// template grid (`NewTeamSheet`) and the Autovisor goal preset picker
/// (`AutovisorGoalPresetPicker`).
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
