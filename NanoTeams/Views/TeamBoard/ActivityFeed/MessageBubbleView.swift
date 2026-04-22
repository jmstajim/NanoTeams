import SwiftUI

/// Renders a single LLM message bubble with optional thinking section.
/// Handles both streaming and committed messages — the parent resolves content before passing.
///
/// Composition:
/// - `ActivityFeedRoleAvatar` — leading avatar (or clear spacer when header is hidden).
/// - `MessageBubbleHeader` — role name, source label, timestamp.
/// - `MessageBubbleStreamingIndicator` — "Waiting"/"Processing %" status row.
/// - `MessageThinkingSection` — expandable thinking disclosure.
/// - Content bubble — the message text.
struct MessageBubbleView: View {
    let message: LLMMessage
    let role: Role
    let roleDefinition: TeamRoleDefinition?
    let content: String
    let thinking: String?
    let processingProgress: Double?
    let isStreaming: Bool
    let showHeader: Bool
    let thinkingExpandedByDefault: Bool
    var onAvatarTap: (() -> Void)? = nil
    @Binding var thinkingExpanded: Set<UUID>

    // MARK: - Derived

    private var roleName: String { roleDefinition?.name ?? role.displayName }
    private var tintColor: Color { roleDefinition?.resolvedTintColor ?? role.tintColor }

    // MARK: - Body

    var body: some View {
        // Treat whitespace-only reasoning as "no thinking" so a disclosure
        // doesn't render with nothing inside (older persisted messages and
        // mid-stream previews can hold a lone `\n` if the model emitted an
        // empty [reasoning] block).
        let hasThinkingContent = thinking.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        let hasMessageContent = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        HStack(alignment: .top, spacing: ActivityCardTokens.cardPadding) {
            if showHeader {
                ActivityFeedRoleAvatar(role: role, roleDefinition: roleDefinition, onTap: onAvatarTap)
            } else {
                // Preserve horizontal alignment without inflating row height
                Color.clear
                    .frame(width: ActivityCardTokens.avatarSize, height: 0)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                if showHeader {
                    MessageBubbleHeader(
                        roleName: roleName,
                        tintColor: tintColor,
                        sourceLabel: message.sourceContextDisplayLabel,
                        timestamp: message.createdAt,
                        isStreaming: isStreaming
                    )
                }

                MessageBubbleStreamingIndicator(
                    isStreaming: isStreaming,
                    hasMessageContent: hasMessageContent,
                    hasThinkingContent: hasThinkingContent,
                    processingProgress: processingProgress
                )

                if hasThinkingContent, let thinking {
                    let isThinkingStreaming = isStreaming && !hasMessageContent
                    MessageThinkingSection(
                        thinking: thinking,
                        messageID: message.id,
                        isStreaming: isThinkingStreaming,
                        expandedByDefault: thinkingExpandedByDefault,
                        thinkingExpanded: $thinkingExpanded
                    )
                }

                if hasMessageContent {
                    // Supervisor-injected messages (queued chat delivery) render
                    // with the same bubble style as the initial-task brief
                    // (`SupervisorTaskItemView`) — visually consistent with the
                    // Supervisor's other utterances in the feed.
                    let contentText = Text(content)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if message.sourceContext == .supervisorMessage {
                        contentText
                            .padding(ActivityCardTokens.cardPadding)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: ActivityCardTokens.cornerRadius,
                                    style: .continuous
                                )
                                .fill(Colors.surfaceElevated)
                            )
                    } else {
                        contentText
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("All States") {
    @Previewable @State var expanded: Set<UUID> = []
    let thinkingMsgID = UUID()

    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            messageBubblePreviewSectionLabel("1. Completed message")
            MessageBubbleView(
                message: LLMMessage(role: .assistant, content: "I'll implement the sorting algorithms now."),
                role: .softwareEngineer,
                roleDefinition: nil,
                content: "I'll implement the sorting algorithms now.",
                thinking: nil,
                processingProgress: nil,
                isStreaming: false,
                showHeader: true,
                thinkingExpandedByDefault: false,
                thinkingExpanded: $expanded
            )

            Divider()

            messageBubblePreviewSectionLabel("2. Completed with thinking (expanded)")
            MessageBubbleView(
                message: LLMMessage(id: thinkingMsgID, role: .assistant, content: "Let me read the existing file first.", thinking: "I should check what's already there before writing."),
                role: .techLead,
                roleDefinition: nil,
                content: "Let me read the existing file first.",
                thinking: "I should check what's already there before writing.",
                processingProgress: nil,
                isStreaming: false,
                showHeader: true,
                thinkingExpandedByDefault: true,
                thinkingExpanded: $expanded
            )

            Divider()

            messageBubblePreviewSectionLabel("3. Streaming — waiting")
            MessageBubbleView(
                message: LLMMessage(role: .assistant, content: ""),
                role: .productManager,
                roleDefinition: nil,
                content: "",
                thinking: nil,
                processingProgress: nil,
                isStreaming: true,
                showHeader: true,
                thinkingExpandedByDefault: false,
                thinkingExpanded: $expanded
            )

            Divider()

            messageBubblePreviewSectionLabel("4. Streaming — processing 42%")
            MessageBubbleView(
                message: LLMMessage(role: .assistant, content: ""),
                role: .productManager,
                roleDefinition: nil,
                content: "",
                thinking: nil,
                processingProgress: 0.42,
                isStreaming: true,
                showHeader: true,
                thinkingExpandedByDefault: false,
                thinkingExpanded: $expanded
            )

            Divider()

            messageBubblePreviewSectionLabel("5. Streaming — thinking")
            MessageBubbleView(
                message: LLMMessage(role: .assistant, content: ""),
                role: .softwareEngineer,
                roleDefinition: nil,
                content: "",
                thinking: "The user wants bubble sort and merge sort. I should check if there's an existing file first.",
                processingProgress: nil,
                isStreaming: true,
                showHeader: true,
                thinkingExpandedByDefault: true,
                thinkingExpanded: $expanded
            )

            Divider()

            messageBubblePreviewSectionLabel("6. Streaming — writing")
            MessageBubbleView(
                message: LLMMessage(role: .assistant, content: "I'll start by creating the Sorting.swift file with"),
                role: .softwareEngineer,
                roleDefinition: nil,
                content: "I'll start by creating the Sorting.swift file with",
                thinking: "Need to implement both algorithms.",
                processingProgress: nil,
                isStreaming: true,
                showHeader: true,
                thinkingExpandedByDefault: false,
                thinkingExpanded: $expanded
            )

            Divider()

            messageBubblePreviewSectionLabel("7. Consultation source label")
            MessageBubbleView(
                message: LLMMessage(role: .user, content: "The API should use REST endpoints.", sourceRole: .techLead, sourceContext: .consultation),
                role: .techLead,
                roleDefinition: nil,
                content: "The API should use REST endpoints.",
                thinking: nil,
                processingProgress: nil,
                isStreaming: false,
                showHeader: true,
                thinkingExpandedByDefault: false,
                thinkingExpanded: $expanded
            )

            Divider()

            messageBubblePreviewSectionLabel("8. No header (continuation)")
            MessageBubbleView(
                message: LLMMessage(role: .assistant, content: "Here is the second part of my response."),
                role: .softwareEngineer,
                roleDefinition: nil,
                content: "Here is the second part of my response.",
                thinking: nil,
                processingProgress: nil,
                isStreaming: false,
                showHeader: false,
                thinkingExpandedByDefault: false,
                thinkingExpanded: $expanded
            )
        }
        .padding()
    }
    .frame(width: 520, height: 1100)
    .background(Colors.surfacePrimary)
    .onAppear { expanded.insert(thinkingMsgID) }
}

// periphery:ignore - used in #Preview macros
@ViewBuilder
private func messageBubblePreviewSectionLabel(_ text: String) -> some View {
    Text(text)
        .font(.caption2.weight(.bold))
        .foregroundStyle(.tertiary)
        .padding(.leading, 4)
}
