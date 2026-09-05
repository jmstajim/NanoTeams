import SwiftUI

// MARK: - Content Views

extension WatchtowerNotificationBanner {

    @ViewBuilder
    var notificationContent: some View {
        switch notification {
        case .supervisorInput(let stepID, let question, _, _):
            supervisorInputContent(stepID: stepID, question: question)

        case .acceptance(_, let roleID, _):
            acceptanceContent(roleID: roleID)

        case .failed(_, _, let errorMessage):
            failedContent(errorMessage: errorMessage)

        case .taskDone:
            taskDoneContent

        case .timedOut:
            timedOutContent

        case .bashApprovalNeeded(_, _, let command, _, _):
            bashApprovalContent(command: command)
        }
    }

    private var canSubmitAnswer: Bool {
        !answerText.isEmpty || !answerAttachments.isEmpty || !answerClippedTexts.isEmpty
    }

    func supervisorInputContent(stepID: String, question: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .top, spacing: Spacing.xs) {
                PromptMarker()
                Text(question)
                    .font(Typography.termBase)
                    .foregroundStyle(Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MessageComposer(
                text: $answerText,
                attachments: $answerAttachments,
                clips: $answerClippedTexts,
                placeholder: "Type your answer...",
                canSubmit: canSubmitAnswer,
                isSubmitting: isSubmitting,
                onSubmit: { submitAnswer(stepID: stepID) },
                onStageAttachment: { url in onStageAttachment(stepID, url) },
                onRemoveAttachment: { attachment in onRemoveAttachment(attachment) },
                skillsProjectRoot: skillsProjectRoot
            )
        }
    }

    func acceptanceContent(roleID: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Completed — awaiting your review")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
            HStack(spacing: Spacing.s) {
                Button {
                    onViewDetails()
                } label: {
                    Label("View", systemImage: "arrow.right.circle")
                        .font(Typography.subheadlineMedium)
                }
                .buttonStyle(.terminalSecondary)
                .controlSize(.small)

                Button {
                    Task {
                        let success = await onAcceptRole(roleID)
                        if success {
                            onDismiss()
                        }
                    }
                } label: {
                    Label("Accept", systemImage: "checkmark")
                        .font(Typography.subheadlineMedium)
                }
                .buttonStyle(.terminalPrimary)
                .controlSize(.small)
            }
        }
    }

    func failedContent(errorMessage: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let error = errorMessage {
                Text(error)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .lineLimit(2)
            }

            Button {
                onViewDetails()
            } label: {
                Label("View Details", systemImage: "arrow.right.circle")
                    .font(Typography.subheadlineMedium)
            }
            .buttonStyle(.terminalSecondary)
            .controlSize(.small)
        }
    }

    var taskDoneContent: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("All team roles have completed their work. Review the deliverables and accept the task.")
                .font(Typography.termBase)
                .foregroundStyle(Colors.textSecondary)

            HStack(spacing: Spacing.s) {
                if case .taskDone(let taskID, _) = notification {
                    Button {
                        onViewDetails()
                    } label: {
                        Label("Review Task", systemImage: "eye.circle")
                            .font(Typography.subheadlineMedium)
                    }
                    .buttonStyle(.terminalPrimary)
                    .controlSize(.small)

                    Button {
                        Task {
                            let success = await onAcceptTask(taskID)
                            if success {
                                onDismiss()
                            }
                        }
                    } label: {
                        Label("Accept Task", systemImage: "checkmark.circle")
                            .font(Typography.subheadlineMedium)
                    }
                    .buttonStyle(.terminalSecondary)
                    .controlSize(.small)
                }
            }
        }
    }

    /// Informational pointer: shows the held command and navigates to the task,
    /// where the Allow/Deny/Always + "Ask AI" card (the single source of truth) lives.
    func bashApprovalContent(command: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(command)
                .font(Typography.monoCaption)
                .foregroundStyle(Colors.textPrimary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle.squircle(CornerRadius.micro).fill(Colors.surfaceOverlay))

            Button {
                onViewDetails()
            } label: {
                Label("Open Task to Approve", systemImage: "arrow.right.circle")
                    .font(Typography.subheadlineMedium)
            }
            .buttonStyle(.terminalSecondary)
            .controlSize(.small)
        }
    }

    var timedOutContent: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("This run exceeded its time limit and was paused. Review it and resume from the task.")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onViewDetails()
            } label: {
                Label("View Task", systemImage: "arrow.right.circle")
                    .font(Typography.subheadlineMedium)
            }
            .buttonStyle(.terminalSecondary)
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    /// On success the draft is cleared and NOTHING is dismissed: the orchestrator's
    /// `answerSupervisorQuestion` already retired this banner's dismissal and un-marked
    /// the task "seen", and `WatchtowerView`'s `onSubmitAnswer` refreshed the inbox
    /// synchronously after it — so the answered banner is gone before this closure runs.
    /// Calling `onDismiss()` here re-inserted the key the orchestrator had just retired
    /// (`WatchtowerView.dismissNotification`) and re-marked the task read, which left a
    /// text-keyed escalation dismissal standing for the NEXT same-text question.
    func submitAnswer(stepID: String) {
        guard canSubmitAnswer else { return }

        isSubmitting = true
        Task {
            let success = await onSubmitAnswer(stepID, answerText, answerAttachments, answerClippedTexts.texts)
            await MainActor.run {
                isSubmitting = false
                if success {
                    answerText = ""
                    answerAttachments = []
                    answerClippedTexts = []
                }
            }
        }
    }
}
