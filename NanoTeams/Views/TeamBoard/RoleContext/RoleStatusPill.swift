import SwiftUI

/// Inline pill displaying a role's completion type label and execution status dot+text.
/// Used as the secondary line inside `RoleContextBanner.primaryRow`.
struct RoleStatusPill: View {
    let roleDefinition: TeamRoleDefinition?
    let statusName: String
    let statusColor: Color

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let def = roleDefinition, !def.isSupervisor {
                Text(def.completionTypeDisplayLabel.uppercased())
                    .font(Typography.term2xs.weight(.medium))
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(def.completionTypeDisplayColor)
            }

            StatusGlyph(
                glyph: TerminalGlyph.bullet,
                color: statusColor,
                font: Typography.term2xs
            )

            Text(statusName.uppercased())
                .font(Typography.term2xs.weight(.medium))
                .tracking(Typography.labelTracking)
                .foregroundStyle(statusColor)
        }
    }
}
