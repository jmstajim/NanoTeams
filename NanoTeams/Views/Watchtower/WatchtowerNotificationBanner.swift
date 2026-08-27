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
    let onSubmitAnswer: (String, String, [StagedAttachment], [String]) async -> Bool
    let onStageAttachment: (String, URL) -> StagedAttachment?
    let onRemoveAttachment: (StagedAttachment) -> Void

    /// Work-folder root for the composer's "/" skills picker (nil → global only).
    var skillsProjectRoot: URL? = nil

    @State var answerText = ""
    @State var answerAttachments: [StagedAttachment] = []
    @State var answerClippedTexts: [Clip] = []
    @State var isSubmitting = false

    /// Inbox-card styling, 1:1 with the design's `INBOX_CFG`: a terminal glyph +
    /// uppercase label cut into the top border, in the type color.
    private var inboxStyle: (glyph: String, label: String, color: Color) {
        // Color is sourced from the canonical per-case mapping so each state keeps
        // its semantic hue (gold/purple/success/error/warning); the glyph + short
        // label are the terminal cut-in treatment.
        let color = notification.color(isChatMode: isChatMode)
        switch notification {
        case .supervisorInput: return (TerminalGlyph.prompt, "needs input", color)
        case .acceptance:      return (TerminalGlyph.review, "review", color)
        case .failed:          return (TerminalGlyph.failed, "failed", color)
        case .taskDone:        return (TerminalGlyph.done, "done", color)
        case .timedOut:        return (TerminalGlyph.paused, "timed out", color)
        case .bashApprovalNeeded: return (TerminalGlyph.prompt, "command", color)
        }
    }

    /// VoiceOver summary — the state word + task. The visible state label lives in
    /// an accessibility-hidden border cut-in, so expose it on the card root instead.
    private var accessibilitySummary: String {
        if let taskTitle { return "\(inboxStyle.label): \(taskTitle)" }
        return inboxStyle.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            // Meta row — the title is cut into the border; here we carry the
            // task path + open/dismiss affordances.
            HStack(spacing: Spacing.xs) {
                StatusGlyph(glyph: inboxStyle.glyph, color: inboxStyle.color, font: Typography.term2xs)

                if let taskTitle {
                    (
                        Text("task/").foregroundStyle(Colors.textQuaternary)
                            + Text(taskTitle).foregroundStyle(Colors.textTertiary)
                    )
                    .font(Typography.term2xs)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }

                Spacer(minLength: Spacing.xs)

                switch notification {
                case .supervisorInput:
                    Button(action: onViewDetails) {
                        Image(systemName: "arrow.right.circle").font(Typography.termBase)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Colors.textTertiary)
                    .help(isChatMode ? "Open Chat" : "Open Task")
                case .bashApprovalNeeded:
                    Button(action: onViewDetails) {
                        Image(systemName: "arrow.right.circle").font(Typography.termBase)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Colors.textTertiary)
                    .help("Open Task")
                default:
                    EmptyView()
                }

                DismissButton(onDismiss: onDismiss)
            }

            // Content (full width) — answer field / accept buttons / error.
            notificationContent
        }
        .padding(Spacing.m)
        .padding(.top, Spacing.xs)
        .background(Colors.surfaceCard, in: RoundedRectangle.squircle(CornerRadius.medium))
        .overlay(
            RoundedRectangle.squircle(CornerRadius.medium)
                .strokeBorder(inboxStyle.color, lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            Text("┤ \(inboxStyle.glyph) \(inboxStyle.label.uppercased()) ├")
                .font(Typography.term2xs)
                .fontWeight(.medium)
                .tracking(Typography.labelTracking)
                .foregroundStyle(inboxStyle.color)
                .padding(.horizontal, 6)
                .background(Colors.surfacePrimary) // masks the border line behind the label
                .padding(.leading, Spacing.m)
                .offset(y: -7)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }
}

// MARK: - Dismiss Button

private struct DismissButton: View {
    let onDismiss: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(Typography.captionSemibold)
                .foregroundStyle(isHovered ? Colors.textPrimary : Colors.textSecondary)
                .padding(6)
                .background(RoundedRectangle.squircle(CornerRadius.small).fill(isHovered ? Colors.surfaceCard : Colors.surfaceHover))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("Dismiss notification")
        .trackHover($isHovered)
    }
}

// MARK: - Preview

#Preview("Notification Types") {
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var dictation = DictationService()
    VStack(spacing: Spacing.m) {
        WatchtowerNotificationBanner(
            notification: .supervisorInput(
                stepID: "preview",
                question: "What should be the priority for this feature? Should we focus on performance or user experience first?",
                role: .tpm,
                toolCallID: nil
            ),
            onDismiss: {},
            onViewDetails: {},
            onAcceptRole: { _ in true },
            onAcceptTask: { _ in true },
            onSubmitAnswer: { _, _, _, _ in true },
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
            onSubmitAnswer: { _, _, _, _ in true },
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
            onSubmitAnswer: { _, _, _, _ in true },
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
            onSubmitAnswer: { _, _, _, _ in true },
            onStageAttachment: { _, _ in nil },
            onRemoveAttachment: { _ in }
        )
    }
    .padding()
    .frame(width: 500)
    .background(NTMSBackground())
    .environment(config)
    .environment(dictation)
}
