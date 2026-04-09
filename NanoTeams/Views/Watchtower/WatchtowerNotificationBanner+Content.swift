import SwiftUI

// MARK: - Content Views

extension WatchtowerNotificationBanner {

    @ViewBuilder
    var notificationContent: some View {
        switch notification {
        case .supervisorInput(let stepID, let question, _):
            supervisorInputContent(stepID: stepID, question: question)

        case .acceptance(_, let roleID, _):
            acceptanceContent(roleID: roleID)

        case .failed(_, _, let errorMessage):
            failedContent(errorMessage: errorMessage)

        case .taskDone:
            taskDoneContent
        }
    }

    private var canSubmitAnswer: Bool {
        !answerText.isEmpty || !answerAttachments.isEmpty
    }

    func supervisorInputContent(stepID: String, question: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(question)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            SupervisorAnswerComposer(
                text: $answerText,
                attachments: $answerAttachments,
                placeholder: "Type your answer...",
                canSubmit: canSubmitAnswer,
                isSubmitting: isSubmitting,
                onSubmit: { submitAnswer(stepID: stepID) },
                onStageAttachment: { url in onStageAttachment(stepID, url) },
                onRemoveAttachment: { attachment in onRemoveAttachment(attachment) }
            )
        }
    }

    func acceptanceContent(roleID: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Completed — awaiting your review")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: Spacing.s) {
                Button {
                    onViewDetails()
                } label: {
                    Label("View", systemImage: "arrow.right.circle")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
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
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    func failedContent(errorMessage: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Button {
                onViewDetails()
            } label: {
                Label("View Details", systemImage: "arrow.right.circle")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    var taskDoneContent: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("All team roles have completed their work. Review the deliverables and accept the task.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: Spacing.s) {
                if case .taskDone(let taskID, _) = notification {
                    Button {
                        onViewDetails()
                    } label: {
                        Label("Review Task", systemImage: "eye.circle.fill")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Colors.purple)
                    .controlSize(.small)

                    Button {
                        Task {
                            let success = await onAcceptTask(taskID)
                            if success {
                                onDismiss()
                            }
                        }
                    } label: {
                        Label("Accept Task", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(Colors.emerald)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Helpers

    func submitAnswer(stepID: String) {
        guard canSubmitAnswer else { return }

        isSubmitting = true
        Task {
            let success = await onSubmitAnswer(stepID, answerText, answerAttachments)
            await MainActor.run {
                isSubmitting = false
                if success {
                    answerText = ""
                    answerAttachments = []
                    onDismiss()
                }
            }
        }
    }
}
