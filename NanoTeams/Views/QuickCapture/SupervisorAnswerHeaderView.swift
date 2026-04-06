import SwiftUI

// MARK: - Supervisor Answer Header View

/// Header row rendered above the Quick Capture form when the panel is in
/// supervisor-answer mode — shows the originating role avatar and a short status
/// line ("<Role> replied" in chat mode, "<Role> needs your input" otherwise).
struct SupervisorAnswerHeaderView: View {
    let payload: SupervisorAnswerPayload

    var body: some View {
        HStack(spacing: Spacing.s) {
            ActivityFeedRoleAvatar(
                role: payload.role,
                roleDefinition: payload.roleDefinition,
                size: 20
            )

            Text(statusLine)
                .font(.headline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var statusLine: String {
        let name = payload.roleDefinition?.name ?? payload.role.displayName
        return payload.isChatMode ? "\(name) replied" : "\(name) needs your input"
    }
}
