import SwiftUI

// MARK: - Supervisor Answer Header View

/// Header row rendered above the Quick Capture form when the panel is in
/// supervisor-answer mode — shows the originating role avatar and a short status
/// line ("<Role> replied" in chat mode, "<Role> needs your input" otherwise).
///
/// One of four variants that render into `QuickCaptureFormView.overlayHeaderRow`
/// — beside `overlayHeader`, `overlayTeamMenu` and `workingHeader`, in the same
/// row and next to the same `CloseButton`. The status line therefore carries the
/// SLOT's typography (`Typography.termMd`), not its own: this view spelled it
/// `termLg` until 2026-08-24, two points and one weight step above the three it
/// sits beside, which read as oversized against the 10pt close glyph and the
/// 13pt question text below it. Pinned by `QuickCaptureHeaderTypographyPinTests`
/// (CLAUDE.md #51 — the rule held at three of four sites, and nothing was red).
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
                .font(Typography.termMd)
                .foregroundStyle(Colors.textSecondary)
                .lineLimit(1)
        }
    }

    private var statusLine: String {
        let name = payload.roleDefinition?.name ?? payload.role.displayName
        return payload.isChatMode ? "\(name) replied" : "\(name) needs your input"
    }
}
