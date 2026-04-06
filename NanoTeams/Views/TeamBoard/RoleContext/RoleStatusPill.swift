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
                Text(def.completionTypeDisplayLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(def.completionTypeDisplayColor)
            }

            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)

            Text(statusName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusColor)
        }
    }
}
