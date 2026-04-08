import SwiftUI

/// Renders a supervisor input notification or failure card.
/// Dispatches on `ActivityNotificationType` — body content lives in
/// `SupervisorInputCard` / `FailedNotificationCard`.
struct NotificationItemView: View {
    let stepID: String
    let role: Role
    let type: ActivityNotificationType
    var isChatMode: Bool = false
    var workFolderURL: URL? = nil
    @Binding var thinkingExpanded: Set<UUID>
    @Binding var answerText: String
    @Binding var answerAttachments: [StagedAttachment]
    let isSubmittingAnswer: Bool
    let isAutoAnswering: Bool
    var onSubmitAnswer: () -> Void
    var onStageAttachment: (URL) -> StagedAttachment?
    var onRemoveAttachment: (StagedAttachment) -> Void

    private var resolvedColor: Color { type.color(isChatMode: isChatMode) }

    var body: some View {
        HStack(alignment: .top, spacing: ActivityCardTokens.cardPadding) {
            ActivityFeedIconAvatar(icon: type.icon(isChatMode: isChatMode), color: resolvedColor)

            VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
                HStack(spacing: Spacing.s) {
                    Text(type.title(for: role, isChatMode: isChatMode))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(resolvedColor)
                    Spacer()
                }

                notificationContent
                    .padding(ActivityCardTokens.cardPadding)
                    .background(
                        RoundedRectangle(cornerRadius: ActivityCardTokens.cornerRadius, style: .continuous)
                            .fill(resolvedColor.opacity(ActivityCardTokens.backgroundOpacity))
                    )
            }
        }
    }

    @ViewBuilder
    private var notificationContent: some View {
        switch type {
        case .supervisorInput(let question, let answer, let answerAttachmentPaths, let toolCallID, let thinking):
            SupervisorInputCard(
                question: question,
                answer: answer,
                answerAttachmentPaths: answerAttachmentPaths,
                workFolderURL: workFolderURL,
                thinking: thinking,
                thinkingID: toolCallID,
                isSubmittingAnswer: isSubmittingAnswer,
                isAutoAnswering: isAutoAnswering,
                thinkingExpanded: $thinkingExpanded,
                answerText: $answerText,
                answerAttachments: $answerAttachments,
                onSubmitAnswer: onSubmitAnswer,
                onStageAttachment: onStageAttachment,
                onRemoveAttachment: onRemoveAttachment
            )
        case .failed(let errorMessage):
            FailedNotificationCard(errorMessage: errorMessage)
        }
    }
}

#Preview("Unanswered Question") {
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var thinking: Set<UUID> = []
    @Previewable @State var answer = ""
    NotificationItemView(
        stepID: "preview",
        role: .softwareEngineer,
        type: .supervisorInput(
            question: "Should I use async/await or completion handlers for the network layer?",
            answer: nil,
            answerAttachmentPaths: [],
            toolCallID: UUID(),
            thinking: "I need guidance on the concurrency approach."
        ),
        thinkingExpanded: $thinking,
        answerText: $answer,
        answerAttachments: .constant([]),
        isSubmittingAnswer: false,
        isAutoAnswering: false,
        onSubmitAnswer: {},
        onStageAttachment: { _ in nil },
        onRemoveAttachment: { _ in }
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
    .environment(config)
}

#Preview("Auto-Answering") {
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var thinking: Set<UUID> = []
    @Previewable @State var answer = ""
    NotificationItemView(
        stepID: "preview",
        role: .softwareEngineer,
        type: .supervisorInput(
            question: "Should I use async/await or completion handlers for the network layer?",
            answer: nil,
            answerAttachmentPaths: [],
            toolCallID: UUID(),
            thinking: "I need guidance on the concurrency approach."
        ),
        thinkingExpanded: $thinking,
        answerText: $answer,
        answerAttachments: .constant([]),
        isSubmittingAnswer: false,
        isAutoAnswering: true,
        onSubmitAnswer: {},
        onStageAttachment: { _ in nil },
        onRemoveAttachment: { _ in }
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
    .environment(config)
}

#Preview("Answered") {
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var thinking: Set<UUID> = []
    @Previewable @State var answer = ""
    NotificationItemView(
        stepID: "preview",
        role: .productManager,
        type: .supervisorInput(
            question: "What should be the priority order for the notification channels?",
            answer: "Push notifications first, then email. SMS can wait for v2.",
            answerAttachmentPaths: [],
            toolCallID: UUID(),
            thinking: nil
        ),
        thinkingExpanded: $thinking,
        answerText: $answer,
        answerAttachments: .constant([]),
        isSubmittingAnswer: false,
        isAutoAnswering: false,
        onSubmitAnswer: {},
        onStageAttachment: { _ in nil },
        onRemoveAttachment: { _ in }
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
    .environment(config)
}

#Preview("Failed") {
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var thinking: Set<UUID> = []
    @Previewable @State var answer = ""
    NotificationItemView(
        stepID: "preview",
        role: .softwareEngineer,
        type: .failed(errorMessage: "LLM connection timeout after 30 seconds"),
        thinkingExpanded: $thinking,
        answerText: $answer,
        answerAttachments: .constant([]),
        isSubmittingAnswer: false,
        isAutoAnswering: false,
        onSubmitAnswer: {},
        onStageAttachment: { _ in nil },
        onRemoveAttachment: { _ in }
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
    .environment(config)
}
