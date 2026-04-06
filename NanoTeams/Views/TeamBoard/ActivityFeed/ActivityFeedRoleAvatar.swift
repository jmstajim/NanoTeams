import SwiftUI

/// Standalone role avatar view used across activity feed sub-views.
struct ActivityFeedRoleAvatar: View {
    let role: Role
    let roleDefinition: TeamRoleDefinition?
    var size: CGFloat = ActivityCardTokens.avatarSize
    var onTap: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .caption) private var iconScale: CGFloat = 1.0

    var body: some View {
        let bg = roleDefinition?.resolvedIconBackground ?? role.tintColor
        let fg = roleDefinition?.resolvedIconColor ?? Color.white
        let icon = roleDefinition?.icon ?? "person.fill"

        let avatar = ZStack {
            Circle()
                .fill(bg)
                .frame(width: size, height: size)
            Image(systemName: icon)
                .font(.system(size: size * 0.4 * iconScale, weight: .semibold))
                .foregroundStyle(fg)
        }

        if let onTap {
            Button(action: onTap) { avatar }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .accessibilityLabel("Select \(roleDefinition?.name ?? role.displayName)")
        } else {
            avatar
        }
    }
}

#Preview("With Role Definitions") {
    let roles: [(Role, TeamRoleDefinition)] = [
        (.softwareEngineer, TeamRoleDefinition(
            id: "swe", name: "Software Engineer", icon: "chevron.left.forwardslash.chevron.right",
            prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(),
            iconBackground: RoleColorDefaults.backgroundHex["softwareEngineer"] ?? RoleColorDefaults.defaultHex
        )),
        (.productManager, TeamRoleDefinition(
            id: "pm", name: "Product Manager", icon: "doc.text.fill",
            prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(),
            iconBackground: RoleColorDefaults.backgroundHex["productManager"] ?? RoleColorDefaults.defaultHex
        )),
        (.uxDesigner, TeamRoleDefinition(
            id: "uxd", name: "UX Designer", icon: "paintbrush.pointed.fill",
            prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(),
            iconBackground: RoleColorDefaults.backgroundHex["uxDesigner"] ?? RoleColorDefaults.defaultHex
        )),
        (.tpm, TeamRoleDefinition(
            id: "tpm", name: "TPM", icon: "calendar",
            prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(),
            iconBackground: RoleColorDefaults.backgroundHex["tpm"] ?? RoleColorDefaults.defaultHex
        )),
    ]
    HStack(spacing: 12) {
        ForEach(roles, id: \.0) { role, def in
            VStack(spacing: 6) {
                ActivityFeedRoleAvatar(role: role, roleDefinition: def)
                Text(def.name).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    .padding()
    .background(Colors.surfacePrimary)
}

#Preview("Without Role Definitions") {
    let roles: [(Role, String)] = [
        (.supervisor, "Supervisor"),
        (.softwareEngineer, "SWE"),
        (.uxDesigner, "UX Designer"),
        (.tpm, "TPM"),
    ]
    HStack(spacing: 12) {
        ForEach(roles, id: \.0) { role, label in
            VStack(spacing: 6) {
                ActivityFeedRoleAvatar(role: role, roleDefinition: nil)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    .padding()
    .background(Colors.surfacePrimary)
}
