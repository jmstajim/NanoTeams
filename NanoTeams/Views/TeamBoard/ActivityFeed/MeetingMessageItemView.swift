import SwiftUI

/// Renders a single team meeting message with thinking and tool summaries sections.
struct MeetingMessageItemView: View {
    let message: TeamMessage
    let roleDefinition: TeamRoleDefinition?
    let showHeader: Bool
    var onAvatarTap: (() -> Void)? = nil
    @Binding var meetingThinkingExpanded: Set<UUID>
    @Binding var meetingToolsExpanded: Set<UUID>

    // MARK: - Derived

    private var roleName: String { roleDefinition?.name ?? message.role.displayName }
    private var tintColor: Color { roleDefinition?.resolvedTintColor ?? message.role.tintColor }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: ActivityCardTokens.cardPadding) {
            ActivityFeedRoleAvatar(role: message.role, roleDefinition: roleDefinition, onTap: showHeader ? onAvatarTap : nil)
                .opacity(showHeader ? 1 : 0)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                if showHeader {
                    HStack(spacing: 6) {
                        Text(roleName).font(.caption.weight(.semibold)).foregroundStyle(tintColor)
                        messageTypeTag(message.messageType)
                        Spacer()
                        Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                if let thinking = message.thinking, !thinking.isEmpty {
                    thinkingSection(thinking: thinking, msgID: message.id)
                }

                if let toolSummaries = message.toolSummaries, !toolSummaries.isEmpty {
                    toolSummariesSection(summaries: toolSummaries, msgID: message.id)
                }

                contentBubble
            }
        }
    }

    // MARK: - Content Bubble

    private var contentBubble: some View {
        Text(message.content)
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ActivityCardTokens.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: ActivityCardTokens.cornerRadius, style: .continuous)
                    .fill(Colors.purpleTint)
            )
    }

    // MARK: - Thinking Section

    private func thinkingSection(thinking: String, msgID: UUID) -> some View {
        let isExpanded = meetingThinkingExpanded.contains(msgID)

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                Text("Thinking")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            if isExpanded {
                Text(thinking)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Spacing.s)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Colors.neutral)
                            .frame(width: 1.5)
                    }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    meetingThinkingExpanded.remove(msgID)
                } else {
                    meetingThinkingExpanded.insert(msgID)
                }
            }
        }
    }

    // MARK: - Tool Summaries Section

    @ViewBuilder
    private func toolSummariesSection(summaries: [MeetingToolSummary], msgID: UUID) -> some View {
        let isExpanded = meetingToolsExpanded.contains(msgID)

        if summaries.count == 1, let summary = summaries.first {
            // Single tool call — flat row matching ToolCallItemView style
            singleToolRow(summary: summary, msgID: msgID, isExpanded: isExpanded)
        } else {
            // Multiple tool calls — card with background/border
            multipleToolsCard(summaries: summaries, msgID: msgID, isExpanded: isExpanded)
        }
    }

    private func singleToolRow(summary: MeetingToolSummary, msgID: UUID, isExpanded: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    meetingToolsExpanded.remove(msgID)
                } else {
                    meetingToolsExpanded.insert(msgID)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: summary.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(summary.isError ? Colors.error : Colors.success)
                        .frame(width: 14, height: 14)
                    Text(summary.toolName)
                        .font(.caption.weight(.medium).monospaced())
                        .foregroundStyle(summary.isError ? Colors.error : Colors.success)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }

                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        if !summary.arguments.isEmpty {
                            Text(summary.arguments.prefix(200))
                                .font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2)
                        }
                        if !summary.result.isEmpty {
                            Text(summary.result.prefix(300))
                                .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func multipleToolsCard(summaries: [MeetingToolSummary], msgID: UUID, isExpanded: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    meetingToolsExpanded.remove(msgID)
                } else {
                    meetingToolsExpanded.insert(msgID)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "wrench.and.screwdriver").font(.caption).foregroundStyle(Colors.purple)
                    Text("\(summaries.count) tool calls")
                        .font(.caption.weight(.medium).monospaced())
                        .foregroundStyle(Colors.purple)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.quaternary)
                }

                if isExpanded {
                    ForEach(summaries) { summary in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Image(systemName: summary.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(summary.isError ? Colors.error : Colors.success)
                                Text(summary.toolName)
                                    .font(.caption.weight(.semibold).monospaced())
                                    .foregroundStyle(summary.isError ? Colors.error : Colors.success)
                            }
                            if !summary.arguments.isEmpty {
                                Text(summary.arguments.prefix(200))
                                    .font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2)
                            }
                            if !summary.result.isEmpty {
                                Text(summary.result.prefix(300))
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        .padding(.leading, 4)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Message Type Tag

    @ViewBuilder
    private func messageTypeTag(_ type: TeamMessageType) -> some View {
        if type != .discussion {
            Label(type.rawValue, systemImage: messageTypeIcon(type))
                .font(.caption2)
                .foregroundStyle(Colors.purple)
        }
    }

    private func messageTypeIcon(_ type: TeamMessageType) -> String {
        type.icon
    }
}

// MARK: - Preview

#Preview("Discussion") {
    @Previewable @State var thinkingExp: Set<UUID> = []
    @Previewable @State var toolsExp: Set<UUID> = []
    MeetingMessageItemView(
        message: TeamMessage(
            role: .techLead,
            content: "I think we should use a modular architecture for the notification service. Each channel (push, email, SMS) should be a separate plugin.",
            messageType: .proposal
        ),
        roleDefinition: nil,
        showHeader: true,
        meetingThinkingExpanded: $thinkingExp,
        meetingToolsExpanded: $toolsExp
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("With Thinking") {
    @Previewable @State var thinkingExp: Set<UUID> = []
    @Previewable @State var toolsExp: Set<UUID> = []
    let msgID = UUID()
    VStack(spacing: 16) {
        MeetingMessageItemView(
            message: TeamMessage(
                id: msgID,
                role: .productManager,
                content: "We need to prioritize push notifications first — 80% of our users have the mobile app installed.",
                messageType: .agreement,
                thinking: "Looking at the analytics data, mobile engagement is significantly higher than email. Push notifications would give us the best ROI for the first milestone."
            ),
            roleDefinition: nil,
            showHeader: true,
            meetingThinkingExpanded: $thinkingExp,
            meetingToolsExpanded: $toolsExp
        )
    }
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("With Tool Calls") {
    @Previewable @State var thinkingExp: Set<UUID> = []
    @Previewable @State var toolsExp: Set<UUID> = []
    MeetingMessageItemView(
        message: TeamMessage(
            role: .softwareEngineer,
            content: "I checked the existing codebase — we already have a notification model in the data layer that we can extend.",
            messageType: .discussion,
            toolSummaries: [
                MeetingToolSummary(
                    toolName: "read_file",
                    arguments: "{\"path\": \"Sources/Models/Notification.swift\"}",
                    result: "struct Notification: Codable { var id: UUID; var title: String; var body: String }"
                ),
                MeetingToolSummary(
                    toolName: "search",
                    arguments: "{\"pattern\": \"NotificationService\", \"path\": \"Sources/\"}",
                    result: "Sources/Services/NotificationService.swift:class NotificationService {",
                    isError: false
                )
            ]
        ),
        roleDefinition: nil,
        showHeader: true,
        meetingThinkingExpanded: $thinkingExp,
        meetingToolsExpanded: $toolsExp
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Objection") {
    @Previewable @State var thinkingExp: Set<UUID> = []
    @Previewable @State var toolsExp: Set<UUID> = []
    MeetingMessageItemView(
        message: TeamMessage(
            role: .codeReviewer,
            content: "I'm worried about the scalability of this approach. WebSockets are stateful — if we need to handle 100K concurrent connections, we'll need a dedicated gateway service with proper load balancing.",
            messageType: .objection
        ),
        roleDefinition: nil,
        showHeader: true,
        meetingThinkingExpanded: $thinkingExp,
        meetingToolsExpanded: $toolsExp
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}
