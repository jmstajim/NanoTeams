import SwiftUI

/// Read-only history card for a resolved (or auto-answered) `ask_supervisor`
/// notification. Renders the question, optional "Thinking" row that opens a
/// window, and either the auto-answer progress/result or the Supervisor's
/// committed reply with attachments.
///
/// Active / in-flight questions are owned by the docked `TeamActivityComposer`
/// — `ActivityFeedBuilder.emitItems` skips emitting a card for them so the
/// answering surface is never duplicated.
///
/// Two distinct flags: `wasAutoAnswered` (from `StepExecution.supervisorAnswerWasAuto`)
/// decides how a RESOLVED answer is attributed — "Auto-answered" badge vs the
/// human checkmark. `isAutoAnswering` (team is autonomous) only drives the
/// in-progress loader for an unresolved question. Keying the resolved badge on
/// the team mode mislabeled human answers in autonomous teams (e.g. a reply to
/// the Autovisor's idle park).
struct SupervisorInputCard: View {
    let question: String
    let answer: String?
    var answerAttachmentPaths: [String] = []
    var answerClippedTexts: [String] = []
    var workFolderURL: URL? = nil
    let thinking: String?
    let thinkingID: UUID
    let roleName: String
    let isAutoAnswering: Bool
    var wasAutoAnswered: Bool = false

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let isResolved = answer != nil

        VStack(alignment: .leading, spacing: Spacing.s) {
            if let thinking, !thinking.isEmpty {
                thinkingRow(thinking: thinking)
            }

            Text(question)
                .font(.body)
                .foregroundStyle(isResolved ? .tertiary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if isResolved, let answer {
                if wasAutoAnswered {
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

    // MARK: - Thinking row

    private func thinkingRow(thinking: String) -> some View {
        Button {
            openWindow(value: ActivityDetailWindow.supervisorThinking(
                id: thinkingID,
                roleName: roleName,
                text: thinking
            ))
        } label: {
            HStack(spacing: Spacing.xs) {
                Text("Thinking")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SupervisorInputCard(
        question: "What should be the priority order for the notification channels?",
        answer: "Push notifications first, then email. SMS can wait for v2.",
        thinking: "I need direction on the rollout sequence so I can sequence the work.",
        thinkingID: UUID(),
        roleName: "Software Engineer",
        isAutoAnswering: false
    )
    .padding()
    .frame(width: 300)
    .background(Colors.surfacePrimary)
    .environment(StoreConfiguration())
}
