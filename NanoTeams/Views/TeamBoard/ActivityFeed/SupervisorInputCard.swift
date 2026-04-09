import SwiftUI

/// Interactive card body for `ActivityNotificationType.supervisorInput`.
/// Renders the question, optional thinking disclosure, auto-answer progress/result,
/// or the answer input (text field + attachments + submit button).
struct SupervisorInputCard: View {
    let question: String
    let answer: String?
    var answerAttachmentPaths: [String] = []
    var answerClippedTexts: [String] = []
    var workFolderURL: URL? = nil
    let thinking: String?
    let thinkingID: UUID
    let isSubmittingAnswer: Bool
    let isAutoAnswering: Bool
    @Binding var thinkingExpanded: Set<UUID>
    @Binding var answerText: String
    @Binding var answerAttachments: [StagedAttachment]
    var onSubmitAnswer: () -> Void
    var onStageAttachment: (URL) -> StagedAttachment?
    var onRemoveAttachment: (StagedAttachment) -> Void


    var body: some View {
        let isResolved = answer != nil

        VStack(alignment: .leading, spacing: Spacing.s) {
            if let thinking, !thinking.isEmpty {
                thinkingDisclosure(thinking: thinking)
            }

            Text(question)
                .font(.body)
                .foregroundStyle(isResolved ? .tertiary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if isResolved, let answer {
                if isAutoAnswering {
                    autoAnsweredResult(answer: answer)
                } else if !answer.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Colors.success)
                            .font(.caption)
                        Text(answer).font(.body).foregroundStyle(.secondary)
                    }
                }

                if !answerAttachmentPaths.isEmpty || !answerClippedTexts.isEmpty {
                    ReadOnlyAttachmentGrid(
                        attachmentPaths: answerAttachmentPaths,
                        clippedTexts: answerClippedTexts,
                        workFolderURL: workFolderURL
                    )
                }
            } else if isAutoAnswering {
                autoAnswerProgress
            } else {
                answerInput
            }
        }
    }

    // MARK: - Auto-answer states

    private var autoAnswerProgress: some View {
        HStack(spacing: Spacing.s) {
            NTMSLoader(.small)
            Text("Supervisor auto-answering...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                .fill(Colors.surfaceOverlay)
        )
    }

    private func autoAnsweredResult(answer: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Colors.info)
                    .font(.caption)
                Text("Auto-answered")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Colors.info)
            }
            Text(answer)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: - Answer input

    private var answerInput: some View {
        SupervisorAnswerComposer(
            text: $answerText,
            attachments: $answerAttachments,
            placeholder: "Type your answer...",
            canSubmit: !answerText.isEmpty || !answerAttachments.isEmpty,
            isSubmitting: isSubmittingAnswer,
            onSubmit: onSubmitAnswer,
            onStageAttachment: onStageAttachment,
            onRemoveAttachment: onRemoveAttachment
        )
    }

    // MARK: - Thinking disclosure

    private func thinkingDisclosure(thinking: String) -> some View {
        let isExpanded = thinkingExpanded.contains(thinkingID)

        return VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        thinkingExpanded.remove(thinkingID)
                    } else {
                        thinkingExpanded.insert(thinkingID)
                    }
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                    Text("Thinking")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    Text(thinking)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: ActivityCardTokens.thinkingMaxHeight)
                .padding(.leading, Spacing.s)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Colors.neutral)
                        .frame(width: 1.5)
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var thinkingExpanded: Set<UUID> = []
    @Previewable @State var answerText = ""
    @Previewable @State var answerAttachments: [StagedAttachment] = []

    SupervisorInputCard(
        question: "Should I prioritize build stability or the onboarding flow for the next iteration?",
        answer: nil,
        thinking: "I need a clear priority so I can sequence the remaining work without blocking the team.",
        thinkingID: UUID(),
        isSubmittingAnswer: false,
        isAutoAnswering: false,
        thinkingExpanded: $thinkingExpanded,
        answerText: $answerText,
        answerAttachments: $answerAttachments,
        onSubmitAnswer: {},
        onStageAttachment: { _ in nil },
        onRemoveAttachment: { _ in }
    )
    .padding()
    .frame(width: 300)
    .background(Colors.surfacePrimary)
    .environment(StoreConfiguration())
}

