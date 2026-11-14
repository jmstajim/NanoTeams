import SwiftUI

/// Renders a supervisor input notification, a failure card, or a Supervisor event line.
/// Dispatches on `ActivityNotificationType` — card bodies live in
/// `SupervisorInputCard` / `FailedNotificationCard`, the event line in `SupervisorEventRow`.
struct NotificationItemView: View {
    let stepID: String
    let role: Role
    let type: ActivityNotificationType
    var isChatMode: Bool = false
    var workFolderURL: URL? = nil
    let isAutoAnswering: Bool

    private var resolvedColor: Color { type.color(isChatMode: isChatMode) }

    var body: some View {
        switch type {
        case .supervisorEvent(let event, let roleName):
            // An event is a log line, not a card: no avatar square, no title in the status
            // colour, nothing under it. Until 2026-11-07 the card said "<agent> closed task"
            // three times; until 2026-11-08 it still said it twice, the seal square and the title.
            SupervisorEventRow(event: event, roleName: roleName, glyphColor: resolvedColor)
        case .supervisorInput(let question, let answer, let answerAttachmentPaths, let answerClippedTexts, let toolCallID, let thinking, let wasAutoAnswered, let inquiry, let answerAuthor):
            card {
                SupervisorInputCard(
                    question: question,
                    answer: answer,
                    inquiry: inquiry,
                    answerAttachmentPaths: answerAttachmentPaths,
                    answerClippedTexts: answerClippedTexts,
                    workFolderURL: workFolderURL,
                    thinking: thinking,
                    thinkingID: toolCallID,
                    roleName: role.displayName,
                    isAutoAnswering: isAutoAnswering,
                    wasAutoAnswered: wasAutoAnswered,
                    answerAuthor: answerAuthor
                )
            }
        case .failed(let errorMessage):
            card { FailedNotificationCard(errorMessage: errorMessage) }
        }
    }

    /// The card a question and a failure share: the avatar in the gutter, the title in the
    /// status colour, the body on a tinted block. Built per case in `body`, so no case reaches
    /// it without a body of its own — an event never does.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: ActivityCardTokens.cardPadding) {
            ActivityFeedIconAvatar(icon: type.icon(isChatMode: isChatMode), color: resolvedColor)

            VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
                HStack(spacing: Spacing.s) {
                    Text(type.title(for: role, isChatMode: isChatMode))
                        .font(Typography.termXs.weight(.semibold))
                        .foregroundStyle(resolvedColor)
                    Spacer()
                }

                content()
                    .padding(ActivityCardTokens.cardPadding)
                    .background(
                        RoundedRectangle.squircle(ActivityCardTokens.cornerRadius)
                            .fill(type.tintColor(isChatMode: isChatMode))
                    )
            }
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

#Preview("Answered by an external agent") {
    @Previewable @State var config = StoreConfiguration()
    NotificationItemView(
        stepID: "preview",
        role: .softwareEngineer,
        type: .supervisorInput(
            question: "What is your preferred approach for handling file errors in linecount.py? (a) Print a stderr message and sys.exit(1); (b) Let the exception propagate naturally; (c) Catch FileNotFoundError separately.",
            answer: "(b) Let the exception propagate naturally, as your linecount.py already does. Keep blank lines uncounted.",
            answerAttachmentPaths: [],
            answerClippedTexts: [],
            toolCallID: UUID(),
            thinking: nil,
            wasAutoAnswered: false,
            answerAuthor: "Claude Code live"
        ),
        isAutoAnswering: false
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
    .environment(config)
}

#Preview("External agent closed the task") {
    @Previewable @State var config = StoreConfiguration()
    NotificationItemView(
        stepID: "preview",
        role: .supervisor,
        type: .supervisorEvent(event: SupervisorTimelineEvent(kind: .taskClosed, authorLabel: "Claude Code live")),
        isAutoAnswering: false
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
