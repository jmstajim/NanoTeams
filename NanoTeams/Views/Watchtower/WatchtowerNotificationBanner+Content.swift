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
        let area = SupervisorAnswerAttachmentArea(
            attachments: $answerAttachments,
            isShowingFilePicker: $isShowingFilePicker,
            isDropTargeted: $isAnswerDropTargeted,
            onStage: { url in onStageAttachment(stepID, url) },
            onRemove: { attachment in onRemoveAttachment(attachment) }
        )

        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text(question)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Type your answer...", text: $answerText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...10)
                .accessibilityLabel("Answer to supervisor question")
                .padding(Spacing.s)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                        .fill(Colors.surfacePrimary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                        .strokeBorder(Colors.borderSubtle, lineWidth: 0.5)
                )
                .focused($isAnswerFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if config.enterSendsMessage {
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.command) {
                            NSApp.sendAction(#selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                        } else if canSubmitAnswer && !isSubmitting {
                            submitAnswer(stepID: stepID)
                        }
                    } else {
                        if press.modifiers.contains(.command) {
                            if canSubmitAnswer && !isSubmitting { submitAnswer(stepID: stepID) }
                        } else {
                            NSApp.sendAction(#selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                        }
                    }
                    return .handled
                }

            HStack {
                Button {
                    isShowingFilePicker = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title2)
                        .foregroundStyle(Colors.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach files")

                if !answerAttachments.isEmpty {
                    Text("\(answerAttachments.count) file\(answerAttachments.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    submitAnswer(stepID: stepID)
                } label: {
                    if isSubmitting {
                        NTMSLoader(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(!canSubmitAnswer ? Colors.textTertiary : Colors.accent)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitAnswer || isSubmitting)
            }

            area
        }
        .modifier(area.dropZone())
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
