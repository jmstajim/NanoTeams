import SwiftUI

// MARK: - Watchtower Notification Banner

/// Banner showing notifications that require Supervisor attention.
/// Supports inline response for Supervisor questions.
/// Content views are in WatchtowerNotificationBanner+Content.swift.
struct WatchtowerNotificationBanner: View {
    let notification: WatchtowerNotificationType
    var taskTitle: String? = nil
    var isChatMode: Bool = false
    let onDismiss: () -> Void
    let onViewDetails: () -> Void
    let onAcceptRole: (String) async -> Bool
    let onAcceptTask: (Int) async -> Bool
    let onSubmitAnswer: (String, String, [StagedAttachment]) async -> Bool
    let onStageAttachment: (String, URL) -> StagedAttachment?
    let onRemoveAttachment: (StagedAttachment) -> Void

    @Environment(StoreConfiguration.self) var config
    @State var answerText = ""
    @State var answerAttachments: [StagedAttachment] = []
    @State var isSubmitting = false
    @State var isAnswerDropTargeted = false
    @State var isShowingFilePicker = false
    @FocusState var isAnswerFocused: Bool

    private var resolvedColor: Color { notification.color(isChatMode: isChatMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            // Header: icon + title + dismiss
            HStack(spacing: Spacing.s) {
                Image(systemName: notification.icon(isChatMode: isChatMode))
                    .font(.subheadline)
                    .foregroundStyle(resolvedColor)

                Text(notification.title(isChatMode: isChatMode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if let taskTitle {
                    Text("· \(taskTitle)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if case .supervisorInput = notification {
                    Button {
                        onViewDetails()
                    } label: {
                        Image(systemName: "arrow.right.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Colors.textTertiary)
                    .help(isChatMode ? "Open Chat" : "Open Task")
                }

                Spacer()

                DismissButton(onDismiss: onDismiss)
            }

            // Content (full width)
            notificationContent
        }
        .padding(Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(resolvedColor.opacity(ActivityCardTokens.backgroundOpacity))
        )
    }
}

// MARK: - Dismiss Button

private struct DismissButton: View {
    let onDismiss: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isHovered || isFocused ? .primary : .secondary)
                .padding(6)
                .background(Circle().fill(isHovered || isFocused ? Colors.surfaceCard : Colors.surfaceHover))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss notification")
        .focusable()
        .focused($isFocused)
        .trackHover($isHovered)
    }
}

// MARK: - Preview

#Preview("Notification Types") {
    @Previewable @State var config = StoreConfiguration()
    VStack(spacing: Spacing.m) {
        WatchtowerNotificationBanner(
            notification: .supervisorInput(
                stepID: "preview",
                question: "What should be the priority for this feature? Should we focus on performance or user experience first?",
                role: .tpm
            ),
            onDismiss: {},
            onViewDetails: {},
            onAcceptRole: { _ in true },
            onAcceptTask: { _ in true },
            onSubmitAnswer: { _, _, _ in true },
            onStageAttachment: { _, _ in nil },
            onRemoveAttachment: { _ in }
        )

        WatchtowerNotificationBanner(
            notification: .acceptance(
                stepID: "preview",
                roleID: "softwareEngineer",
                roleName: "Software Engineer"
            ),
            onDismiss: {},
            onViewDetails: {},
            onAcceptRole: { _ in true },
            onAcceptTask: { _ in true },
            onSubmitAnswer: { _, _, _ in true },
            onStageAttachment: { _, _ in nil },
            onRemoveAttachment: { _ in }
        )

        WatchtowerNotificationBanner(
            notification: .failed(
                stepID: "preview",
                role: .softwareEngineer,
                errorMessage: "Build failed with 3 errors in AuthenticationService.swift"
            ),
            onDismiss: {},
            onViewDetails: {},
            onAcceptRole: { _ in true },
            onAcceptTask: { _ in true },
            onSubmitAnswer: { _, _, _ in true },
            onStageAttachment: { _, _ in nil },
            onRemoveAttachment: { _ in }
        )

        WatchtowerNotificationBanner(
            notification: .taskDone(
                taskID: Int(),
                taskTitle: "Implement user authentication"
            ),
            onDismiss: {},
            onViewDetails: {},
            onAcceptRole: { _ in true },
            onAcceptTask: { _ in true },
            onSubmitAnswer: { _, _, _ in true },
            onStageAttachment: { _, _ in nil },
            onRemoveAttachment: { _ in }
        )
    }
    .padding()
    .frame(width: 500)
    .background(NTMSBackground())
    .environment(config)
}
