import SwiftUI

/// Renders the Supervisor's initial task as the first item in the activity feed.
struct SupervisorTaskItemView: View {
    let createdAt: Date
    let supervisorTask: String
    let clippedTexts: [String]
    let attachmentPaths: [String]
    let workFolderURL: URL?
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
            ActivityFeedRoleAvatar(role: .supervisor, roleDefinition: nil, onTap: onAvatarTap)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.s) {
                    Text("Supervisor")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Role.supervisor.tintColor)
                    Spacer()
                    Text(createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !trimmedTask.isEmpty {
                    // NSTextView-backed body for stable height + bounded layout
                    // cost on long supervisor briefs. Same rationale as
                    // `MessageBubbleView`.
                    SelectableMessageText(content: trimmedTask)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(ActivityCardTokens.cardPadding)
                        .background(
                            RoundedRectangle(cornerRadius: ActivityCardTokens.cornerRadius, style: .continuous)
                                .fill(Colors.surfaceElevated)
                        )
                }

                if hasAttachments {
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

/// See `MessageBubbleView`'s Equatable extension for full rationale.
/// `onAvatarTap` excluded (closure; captures stable orchestrator state).
extension SupervisorTaskItemView: Equatable {
    static func == (lhs: SupervisorTaskItemView, rhs: SupervisorTaskItemView) -> Bool {
        lhs.createdAt == rhs.createdAt
            && lhs.supervisorTask == rhs.supervisorTask
            && lhs.clippedTexts == rhs.clippedTexts
            && lhs.attachmentPaths == rhs.attachmentPaths
            && lhs.workFolderURL == rhs.workFolderURL
    }
}

#Preview {
    SupervisorTaskItemView(
        createdAt: Date(),
        supervisorTask: "Create a sorting algorithm that handles edge cases for empty arrays and duplicate values.",
        clippedTexts: ["Some clipped text from the clipboard"],
        attachmentPaths: [],
        workFolderURL: nil
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}
