import SwiftUI

/// Renders a single LLM message bubble with optional thinking section.
/// Handles both streaming and committed messages — the parent resolves content before passing.
///
/// Composition:
/// - `ActivityFeedRoleAvatar` — leading avatar (or clear spacer when header is hidden).
/// - `MessageBubbleHeader` — role name, source label, timestamp.
/// - `MessageBubbleStreamingIndicator` — status row: Processing X% / Generating /
///   Waiting (or hidden once content / thinking arrives).
/// - `MessageThinkingSection` — compact "Thinking" row that opens a window.
/// - Content bubble — the message text.
struct MessageBubbleView: View {
    let message: LLMMessage
    let role: Role
    let roleDefinition: TeamRoleDefinition?
    let content: String
    let thinking: String?
    let processingProgress: Double?
    /// True when the streaming pipeline has observed at least one delta of
    /// any kind for this step (thinking, content, tool-call, harmony).
    /// Drives the "Waiting" → "Generating" status flip in
    /// `MessageBubbleStreamingIndicator` for the case where tokens are
    /// flowing into invisible buffers (e.g. tool-call argument JSON).
    var hasStreamActivity: Bool = false
    let isStreaming: Bool
    var isImplicitStreamTarget: Bool = false
    let showHeader: Bool
    var onAvatarTap: (() -> Void)? = nil
    /// Override role display name (e.g. role.name from a child team's roster
    /// when the active team's roles don't match). `nil` falls back to the
    /// resolved role definition name.
    var roleLabelOverride: String? = nil
    /// Optional team suffix rendered as ` from <Team>` after the role name in
    /// secondary gray. Set for delegated child-team items so the user sees
    /// which team the item came from. `nil` for active-team items.
    var roleTeamSuffix: String? = nil
    /// Non-embedded attachment file paths (relative to `workFolderURL`) to
    /// render as thumbnail cards via `ReadOnlyAttachmentGrid` below the bubble.
    /// Populated by the caller for `.supervisorMessage` turns after running
    /// `ActivityFeedBuilder.stripAttachedFiles` on `displayContent`. Empty for
    /// every other surface — same component as `SupervisorTaskItemView` and
    /// `SupervisorInputCard` so all three supervisor-input bubbles share one
    /// rendering path.
    var attachmentPaths: [String] = []
    /// Clipped-text snippets extracted alongside `attachmentPaths`.
    var clippedTexts: [String] = []
    /// Resolution base for `attachmentPaths` (typically `store.workFolderURL`).
    var workFolderURL: URL? = nil

    // MARK: - Derived

    private var roleName: String { roleLabelOverride ?? roleDefinition?.name ?? role.displayName }
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
                        teamSuffix: roleTeamSuffix,
                        tintColor: tintColor,
                        sourceLabel: message.sourceContextDisplayLabel,
                        timestamp: message.createdAt,
                        isStreaming: isStreaming
                    )
                }

                MessageBubbleStreamingIndicator(
                    isStreaming: isStreaming,
                    isImplicitStreamTarget: isImplicitStreamTarget,
                    hasMessageContent: hasMessageContent,
                    hasThinkingContent: hasThinkingContent,
                    processingProgress: processingProgress,
                    hasStreamActivity: hasStreamActivity
                )
                // Load-bearing: skips this subtree on streaming ticks when
                // the 5 inputs are unchanged (Waiting/Generating/Processing
                // steady state). Drift-guarded by
                // `MessageBubbleStreamingIndicatorEquatableTests`.
                .equatable()

                if hasThinkingContent, let thinking {
                    let isThinkingStreaming = isStreaming && !hasMessageContent
                    MessageThinkingSection(
                        thinking: thinking,
                        messageID: message.id,
                        roleName: roleName,
                        isStreaming: isThinkingStreaming
                    )
                }

                if hasMessageContent {
                    // `.supervisorMessage` matches the Supervisor's other
                    // feed utterances (initial-task-brief styling). See
                    // `SelectableMessageText` for streaming/append-only
                    // and `LazyVStack` height-stability rationale.
                    let contentText = SelectableMessageText(content: content)
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

                if !attachmentPaths.isEmpty || !clippedTexts.isEmpty {
                    ReadOnlyAttachmentGrid(
                        attachmentPaths: attachmentPaths,
                        clippedTexts: clippedTexts,
                        workFolderURL: workFolderURL
                    )
                }
            }
        }
    }
}

// MARK: - Equatable

/// `Equatable` lets `TeamActivityFeedView`'s dispatcher wrap this view in
/// `.equatable()` for committed bubbles — SwiftUI's diff fast-path skips
/// the entire subtree when nothing in the inputs has changed. This is the
/// load-bearing optimization for steady-state `DisplayList.append`
/// pressure described in the plan file's Phase 2 follow-up.
///
/// **Hand-rolled (not synthesized) for two reasons:**
/// 1. Excludes `onAvatarTap` (closure — closures are never `Equatable`).
///    The closure is treated as identity-stable per parent body — as long
///    as every value it captures is also in `==`, the captured copy stays
///    correct across cache hits. The captured values here are `role` and
///    `originTaskID`; both feed `roleDefinition?.id` / `roleTeamSuffix`,
///    which ARE in `==`.
/// 2. Compares `roleDefinition` by `id` rather than the full struct.
///    `TeamRoleDefinition` is `Identifiable` but not `Hashable`; structural
///    equality would require field-by-field comparison and we only care
///    about identity here. If the role's content (name, icon, color) ever
///    changes mid-conversation, parent state updates regenerate the view.
///
/// **DRIFT GUARD.** Any new prop added to `MessageBubbleView` must be
/// added to `==` here, otherwise updates to that prop are silently
/// dropped under `.equatable()`. The companion test
/// `MessageBubbleEquatableTests` pins each prop's contribution.
extension MessageBubbleView: Equatable {
    static func == (lhs: MessageBubbleView, rhs: MessageBubbleView) -> Bool {
        lhs.message == rhs.message
            && lhs.role == rhs.role
            && lhs.roleDefinition?.id == rhs.roleDefinition?.id
            && lhs.content == rhs.content
            && lhs.thinking == rhs.thinking
            && lhs.processingProgress == rhs.processingProgress
            && lhs.hasStreamActivity == rhs.hasStreamActivity
            && lhs.isStreaming == rhs.isStreaming
            && lhs.isImplicitStreamTarget == rhs.isImplicitStreamTarget
            && lhs.showHeader == rhs.showHeader
            && lhs.roleLabelOverride == rhs.roleLabelOverride
            && lhs.roleTeamSuffix == rhs.roleTeamSuffix
            && lhs.attachmentPaths == rhs.attachmentPaths
            && lhs.clippedTexts == rhs.clippedTexts
            && lhs.workFolderURL == rhs.workFolderURL
    }
}

// MARK: - Preview

#Preview("All States") {
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
                showHeader: true
            )

            Divider()

            messageBubblePreviewSectionLabel("2. Completed with thinking")
            MessageBubbleView(
                message: LLMMessage(role: .assistant, content: "Let me read the existing file first.", thinking: "I should check what's already there before writing."),
                role: .techLead,
                roleDefinition: nil,
                content: "Let me read the existing file first.",
                thinking: "I should check what's already there before writing.",
                processingProgress: nil,
                isStreaming: false,
                showHeader: true
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
                showHeader: true
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
                showHeader: true
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
                showHeader: true
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
                showHeader: true
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
                showHeader: true
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
                showHeader: false
            )
        }
        .padding()
    }
    .frame(width: 520, height: 1100)
    .background(Colors.surfacePrimary)
}

// periphery:ignore - used in #Preview macros
@ViewBuilder
private func messageBubblePreviewSectionLabel(_ text: String) -> some View {
    Text(text)
        .font(.caption2.weight(.bold))
        .foregroundStyle(.tertiary)
        .padding(.leading, 4)
}
