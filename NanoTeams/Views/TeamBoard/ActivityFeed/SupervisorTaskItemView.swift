import SwiftUI

/// Renders the Supervisor's initial task as the first item in the activity feed.
struct SupervisorTaskItemView: View {
    let createdAt: Date
    let supervisorTask: String
    let clippedTexts: [String]
    let attachmentPaths: [String]
    let workFolderURL: URL?
    /// The team roster's Supervisor definition — drives the avatar icon,
    /// name, and tint so this card matches the Supervisor's message
    /// bubbles (`MessageBubbleView`) instead of the generic
    /// `ActivityFeedRoleAvatar` "person" fallback. `nil` (roster lookup
    /// missed) keeps the fallback.
    let roleDefinition: TeamRoleDefinition?
    var authorLabel: String? = nil
    var onAvatarTap: (() -> Void)? = nil

    private var hasAttachments: Bool {
        let hasClips = clippedTexts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let hasResolvableFiles = workFolderURL != nil && !attachmentPaths.isEmpty
        return hasResolvableFiles || hasClips
    }

    private var trimmedTask: String {
        supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .top, spacing: ActivityCardTokens.cardPadding) {
            ActivityFeedRoleAvatar(role: .supervisor, roleDefinition: roleDefinition, onTap: onAvatarTap)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                // The same header a Supervisor message bubble wears, so the task card and the
                // turns after it name their author one way (the agent mark).
                MessageBubbleHeader(
                    roleName: roleDefinition?.name ?? Role.supervisor.displayName,
                    tintColor: roleDefinition?.resolvedTintColor ?? Role.supervisor.tintColor,
                    authorLabel: authorLabel,
                    timestamp: createdAt,
                    isStreaming: false,
                    showsPromptMarker: true
                )

                if !trimmedTask.isEmpty {
                    // NSTextView-backed body for stable height + bounded layout
                    // cost on long supervisor briefs. Same rationale as
                    // `MessageBubbleView`.
                    SelectableMessageText(content: trimmedTask)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(ActivityCardTokens.cardPadding)
                        .background(
                            RoundedRectangle.squircle(ActivityCardTokens.cornerRadius)
                                .fill(Colors.surfaceElevated)
                        )
                }

                if hasAttachments {
                    ReadOnlyAttachmentGrid(
                        attachmentPaths: attachmentPaths,
                        clippedTexts: clippedTexts,
                        clipSeed: "supervisor-task-\(createdAt.timeIntervalSince1970)",
                        workFolderURL: workFolderURL
                    )
                }
            }
        }
    }
}

// MARK: - Equatable

/// See `MessageBubbleView`'s Equatable extension for full rationale.
/// `onAvatarTap` excluded (closure; captures stable orchestrator state).
/// `roleDefinition` compared by `renderIdentity` — its presentation fields —
/// the same choice as `MessageBubbleView.==`, whose extension carries the
/// reasoning. It compared `id` alone until 2026-08-25, on the claim that
/// "content edits to the role regenerate the view via parent state updates";
/// that regeneration is precisely when `==` runs, so the claim named the path
/// that produced the staleness rather than one that cured it.
extension SupervisorTaskItemView: Equatable {
    static func == (lhs: SupervisorTaskItemView, rhs: SupervisorTaskItemView) -> Bool {
        lhs.createdAt == rhs.createdAt
            && lhs.supervisorTask == rhs.supervisorTask
            && lhs.clippedTexts == rhs.clippedTexts
            && lhs.attachmentPaths == rhs.attachmentPaths
            && lhs.workFolderURL == rhs.workFolderURL
            && lhs.roleDefinition?.renderIdentity == rhs.roleDefinition?.renderIdentity
            && lhs.authorLabel == rhs.authorLabel
    }
}

#Preview {
    SupervisorTaskItemView(
        createdAt: Date(),
        supervisorTask: "Create a sorting algorithm that handles edge cases for empty arrays and duplicate values.",
        clippedTexts: ["Some clipped text from the clipboard"],
        attachmentPaths: [],
        workFolderURL: nil,
        roleDefinition: nil
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Created by an external agent") {
    SupervisorTaskItemView(
        createdAt: Date(),
        supervisorTask: "Write linecount.py: count non-blank lines of the file given as the first argument.",
        clippedTexts: [],
        attachmentPaths: [],
        workFolderURL: nil,
        roleDefinition: nil,
        authorLabel: "Claude Code live"
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}
