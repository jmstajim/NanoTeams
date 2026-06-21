import SwiftUI

/// Standalone role avatar view used across activity feed sub-views.
struct ActivityFeedRoleAvatar: View {
    let role: Role
    let roleDefinition: TeamRoleDefinition?
    var size: CGFloat = ActivityCardTokens.avatarSize
    var onTap: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .caption) private var iconScale: CGFloat = 1.0

    var body: some View {
        let tint = roleDefinition?.resolvedIconBackground ?? role.tintColor
        let icon = roleDefinition?.icon ?? "person"

        // Bare icon avatar — no chrome. Icon is tinted with what used to
        // be the squircle background colour so role identity remains.
        // Glyph size + frame are pinned to DS tokens
        // (`ActivityCardTokens.avatarIconSize` / `.avatarSize`) so every
        // SF Symbol renders at the same point size regardless of its
        // intrinsic metrics.
        let avatar = Image(systemName: icon)
            .font(.system(size: ActivityCardTokens.avatarIconSize * iconScale, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            // Avatar has a known fixed frame (`size × size`). Without
            // `.fixedSize()`, AppKit's constraint walk asks SwiftUI for
            // `minSize()` on every NSHostingView. `.fixedSize()` tells
            // SwiftUI the answer is constant and short-circuits the query.
            .fixedSize()

        if let onTap {
            Button(action: onTap) { avatar }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
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
            id: "pm", name: "Product Manager", icon: "doc.text",
            prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(),
            iconBackground: RoleColorDefaults.backgroundHex["productManager"] ?? RoleColorDefaults.defaultHex
        )),
        (.uxDesigner, TeamRoleDefinition(
            id: "uxd", name: "UX Designer", icon: "paintbrush.pointed",
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
                Text(def.name).font(Typography.caption2).foregroundStyle(Colors.textSecondary)
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
                Text(label).font(Typography.caption2).foregroundStyle(Colors.textSecondary)
            }
        }
    }
    .padding()
    .background(Colors.surfacePrimary)
}
