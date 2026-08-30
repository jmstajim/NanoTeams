import SwiftUI

/// Renders a single team meeting message. Thinking and tool summaries are
/// compact inline rows that open standalone windows on tap — no inline
/// expansion or chevrons.
struct MeetingMessageItemView: View {
    let message: TeamMessage
    let roleDefinition: TeamRoleDefinition?
    let showHeader: Bool
    var onAvatarTap: (() -> Void)? = nil
    /// Override role display name. `nil` falls back to roleDefinition.name.
    var roleLabelOverride: String? = nil
    /// Optional ` from <Team>` suffix in secondary gray for delegated
    /// child-team items.
    var roleTeamSuffix: String? = nil

    @Environment(\.openWindow) private var openWindow

    // MARK: - Derived

    private var roleName: String { roleLabelOverride ?? roleDefinition?.name ?? message.role.displayName }
    private var tintColor: Color { roleDefinition?.resolvedTintColor ?? message.role.tintColor }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: ActivityCardTokens.cardPadding) {
            ActivityFeedRoleAvatar(role: message.role, roleDefinition: roleDefinition, onTap: showHeader ? onAvatarTap : nil)
                .opacity(showHeader ? 1 : 0)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                if showHeader {
                    HStack(spacing: Spacing.s) {
                        roleNameText(roleName: roleName, teamSuffix: roleTeamSuffix, tintColor: tintColor)
                        messageTypeTag(message.messageType)
                        Spacer()
                        Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(Typography.term2xs)
                            .foregroundStyle(Colors.textTertiary)
                    }
                }

                if let thinking = message.thinking, !thinking.isEmpty {
                    thinkingRow(thinking: thinking)
                }

                if let toolSummaries = message.toolSummaries, !toolSummaries.isEmpty {
                    toolSummariesRow(summaries: toolSummaries)
                }

                contentBubble
            }
        }
    }

    // MARK: - Content Bubble

    private var contentBubble: some View {
        // NSTextView-backed body for stable height + bounded layout cost on
        // long meeting messages. Same rationale as `MessageBubbleView`.
        SelectableMessageText(content: message.content)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ActivityCardTokens.cardPadding)
            .background(
                RoundedRectangle.squircle(ActivityCardTokens.cornerRadius)
                    .fill(Colors.purpleTint)
            )
    }

    // MARK: - Thinking Row

    private func thinkingRow(thinking: String) -> some View {
        Button {
            openWindow(value: ActivityDetailWindow.meetingThinking(
                id: message.id,
                roleName: roleName,
                text: thinking
            ))
        } label: {
            HStack(spacing: Spacing.xs) {
                Text("Thinking")
                    // Same token as every other status caption in the feed —
                    // see the twin row in `SupervisorInputCard`.
                    .font(Typography.termXs.weight(.medium))
                    .foregroundStyle(Colors.textTertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tool Summaries Row

    @ViewBuilder
    private func toolSummariesRow(summaries: [MeetingToolSummary]) -> some View {
        if summaries.count == 1, let summary = summaries.first {
            singleToolRow(summary: summary)
        } else {
            multipleToolsRow(summaries: summaries)
        }
    }

    private func singleToolRow(summary: MeetingToolSummary) -> some View {
        Button {
            openWindow(value: ActivityDetailWindow.meetingTool(
                id: summary.id,
                summary: summary
            ))
        } label: {
            HStack(spacing: Spacing.s) {
                StatusGlyph(
                    glyph: summary.isError ? TerminalGlyph.failed : TerminalGlyph.done,
                    color: summary.isError ? Colors.error : Colors.success
                )
                .frame(width: 14, height: 14)
                Text(summary.toolName)
                    .font(Typography.termXs.weight(.medium))
                    .foregroundStyle(summary.isError ? Colors.error : Colors.success)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func multipleToolsRow(summaries: [MeetingToolSummary]) -> some View {
        Button {
            openWindow(value: ActivityDetailWindow.meetingTools(
                id: message.id,
                summaries: summaries
            ))
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.purple)
                Text("\(summaries.count) tool calls")
                    .font(Typography.termXs.weight(.medium))
                    .foregroundStyle(Colors.purple)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Message Type Tag

    @ViewBuilder
    private func messageTypeTag(_ type: TeamMessageType) -> some View {
        if type != .discussion {
            HStack(spacing: Spacing.xxs) {
                Text(TerminalGlyph.meeting)
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.purple)
                Text(type.rawValue.uppercased())
                    .font(Typography.term2xs.weight(.medium))
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(Colors.purple)
            }
        }
    }
}

// MARK: - Equatable

/// `TeamMessage` is `Identifiable` but not `Hashable`/`Equatable`, so we
/// hand-compare the fields the body actually reads (`id`, `content`,
/// `thinking`, `role`, `messageType`, `toolSummaries`). `MeetingToolSummary`
/// IS `Hashable`, so the array compare is structural — needed because an
/// in-place `isError` flip (red ↔ green badge) leaves `count` unchanged
/// and a count-only compare would silently drop the update. `nil` and `[]`
/// for `toolSummaries` render identically (the body gates on
/// `!isEmpty`), so we normalize both sides via `?? []` to preserve that
/// observability — pinned by `testNotEqual_whenToolSummariesNilVsEmpty`.
/// `onAvatarTap` is intentionally excluded (closures aren't Equatable;
/// the closure captures only props that ARE in `==`).
extension MeetingMessageItemView: Equatable {
    static func == (lhs: MeetingMessageItemView, rhs: MeetingMessageItemView) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.content == rhs.message.content
            && lhs.message.thinking == rhs.message.thinking
            && lhs.message.role == rhs.message.role
            && lhs.message.messageType == rhs.message.messageType
            && (lhs.message.toolSummaries ?? []) == (rhs.message.toolSummaries ?? [])
            && lhs.roleDefinition?.renderIdentity == rhs.roleDefinition?.renderIdentity
            && lhs.showHeader == rhs.showHeader
            && lhs.roleLabelOverride == rhs.roleLabelOverride
            && lhs.roleTeamSuffix == rhs.roleTeamSuffix
    }
}

// MARK: - Preview

#Preview("Discussion") {
    MeetingMessageItemView(
        message: TeamMessage(
            role: .techLead,
            content: "I think we should use a modular architecture for the notification service. Each channel (push, email, SMS) should be a separate plugin.",
            messageType: .proposal
        ),
        roleDefinition: nil,
        showHeader: true
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("With Thinking") {
    MeetingMessageItemView(
        message: TeamMessage(
            role: .productManager,
            content: "We need to prioritize push notifications first — 80% of our users have the mobile app installed.",
            messageType: .agreement,
            thinking: "Looking at the analytics data, mobile engagement is significantly higher than email."
        ),
        roleDefinition: nil,
        showHeader: true
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("With Tool Calls") {
    MeetingMessageItemView(
        message: TeamMessage(
            role: .softwareEngineer,
            content: "I checked the existing codebase — we already have a notification model in the data layer.",
            messageType: .discussion,
            toolSummaries: [
                MeetingToolSummary(
                    toolName: "read_file",
                    arguments: "{\"path\": \"Sources/Models/Notification.swift\"}",
                    result: "struct Notification: Codable { var id: UUID; var title: String }"
                ),
                MeetingToolSummary(
                    toolName: "search",
                    arguments: "{\"pattern\": \"NotificationService\"}",
                    result: "Sources/Services/NotificationService.swift",
                    isError: false
                )
            ]
        ),
        roleDefinition: nil,
        showHeader: true
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Objection") {
    MeetingMessageItemView(
        message: TeamMessage(
            role: .codeReviewer,
            content: "I'm worried about the scalability of this approach.",
            messageType: .objection
        ),
        roleDefinition: nil,
        showHeader: true
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}
