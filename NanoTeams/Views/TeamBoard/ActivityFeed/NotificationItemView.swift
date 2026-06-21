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
    let isAutoAnswering: Bool

    private var resolvedColor: Color { type.color(isChatMode: isChatMode) }

    var body: some View {
        HStack(alignment: .top, spacing: ActivityCardTokens.cardPadding) {
            ActivityFeedIconAvatar(icon: type.icon(isChatMode: isChatMode), color: resolvedColor)

            VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
                HStack(spacing: Spacing.s) {
                    Text(type.title(for: role, isChatMode: isChatMode))
                        .font(Typography.termXs.weight(.semibold))
                        .foregroundStyle(resolvedColor)
                    Spacer()
                }

                notificationContent
                    .padding(ActivityCardTokens.cardPadding)
                    .background(
                        RoundedRectangle.squircle(ActivityCardTokens.cornerRadius)
                            .fill(resolvedColor.opacity(ActivityCardTokens.backgroundOpacity))
                    )
            }
        }
    }

    @ViewBuilder
    private var notificationContent: some View {
        switch type {
        case .supervisorInput(let question, let answer, let answerAttachmentPaths, let answerClippedTexts, let toolCallID, let thinking, let wasAutoAnswered):
            SupervisorInputCard(
                question: question,
                answer: answer,
                answerAttachmentPaths: answerAttachmentPaths,
                answerClippedTexts: answerClippedTexts,
                workFolderURL: workFolderURL,
                thinking: thinking,
                thinkingID: toolCallID,
                roleName: role.displayName,
                isAutoAnswering: isAutoAnswering,
                wasAutoAnswered: wasAutoAnswered
            )
        case .failed(let errorMessage):
            FailedNotificationCard(errorMessage: errorMessage)
        }
    }
}

#Preview("Answered") {
    @Previewable @State var config = StoreConfiguration()
    NotificationItemView(
        stepID: "preview",
        role: .productManager,
        type: .supervisorInput(
            question: "What should be the priority order for the notification channels?",
            answer: "Push notifications first, then email. SMS can wait for v2.",
            answerAttachmentPaths: [],
            answerClippedTexts: [],
            toolCallID: UUID(),
            thinking: nil,
            wasAutoAnswered: false
        ),
        isAutoAnswering: false
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
    .environment(config)
}

#Preview("Auto-Answered") {
    @Previewable @State var config = StoreConfiguration()
    NotificationItemView(
        stepID: "preview",
        role: .softwareEngineer,
        type: .supervisorInput(
            question: "Should I use async/await or completion handlers for the network layer?",
            answer: "Use async/await throughout — matches the rest of the codebase.",
            answerAttachmentPaths: [],
            answerClippedTexts: [],
            toolCallID: UUID(),
            thinking: "I need guidance on the concurrency approach.",
            wasAutoAnswered: true
        ),
        isAutoAnswering: true
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
    .environment(config)
}

#Preview("Failed") {
    @Previewable @State var config = StoreConfiguration()
    NotificationItemView(
        stepID: "preview",
        role: .softwareEngineer,
        type: .failed(errorMessage: "LLM connection timeout after 30 seconds"),
        isAutoAnswering: false
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
    .environment(config)
}
