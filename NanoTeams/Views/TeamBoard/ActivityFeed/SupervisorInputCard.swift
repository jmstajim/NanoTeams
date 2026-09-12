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
    /// The questionnaire this call asked and what was decided, when it asked one. Present, the
    /// card renders the DECISIONS — one row per question, the assumption as a badge — instead
    /// of the `Q1./A1.` paragraph that carries the same content to the model. Absent, the card
    /// is byte-for-byte the plain `ask_supervisor` card it always was.
    var inquiry: AnsweredInquiry? = nil
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
                .font(Typography.termBase)
                .foregroundStyle(isResolved ? Colors.textTertiary : Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let inquiry {
                // Asked as a form, so it is shown as one whether or not it was answered: a
                // questionnaire left open on a closed run used to render as its headline and
                // nothing else, which reads as a question with no content.
                if isResolved, wasAutoAnswered { autoAnsweredLabel }
                SupervisorInquiryTranscript(
                    inquiry: inquiry.inquiry,
                    answer: inquiry.answer ?? SupervisorInquiryAnswer(),
                    note: inquiry.answer?.note)
            } else if isResolved, let answer {
                if wasAutoAnswered {
                    autoAnsweredResult(answer: answer)
                } else if !answer.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        StatusGlyph(glyph: TerminalGlyph.done, color: Colors.success)
                        Text(answer).font(Typography.termBase).foregroundStyle(Colors.textSecondary)
                    }
                }
            }

            if isResolved {
                if !answerAttachmentPaths.isEmpty || !answerClippedTexts.isEmpty {
                    ReadOnlyAttachmentGrid(
                        attachmentPaths: answerAttachmentPaths,
                        clippedTexts: answerClippedTexts,
                        clipSeed: "supervisor-answer-\(thinkingID.uuidString)",
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
        // Same inline loader+caption DS pattern as `MessageLoaderLabel`
        // and `MessageThinkingSection`: NTMSLoader at the caption's
        // line-height (termXs) + accent for "alive", muted caption
        // (termXs.medium + textTertiary), Unicode ellipsis `…` for "in
        // progress". The surrounding card padding/background is
        // unchanged — only the inline pair is unified.
        HStack(spacing: Spacing.xs) {
            NTMSLoader(font: Typography.termXs, color: Colors.accent)
            Text("Supervisor auto-answering…")
                .font(Typography.termXs.weight(.medium))
                .foregroundStyle(Colors.textTertiary)
        }
        .padding(Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceOverlay)
        )
    }

    /// The "Auto-answered" attribution, on its own so the questionnaire transcript can wear it
    /// without the prose body underneath that `autoAnsweredResult` pairs it with.
    /// The design system's badge, not a hand-built SF-symbol row: this label stands directly
    /// above the questionnaire transcript's own rows, and two attributions about the same
    /// answer were drawn in two different chromes. (Until 2026-09-12 the rows it sat above
    /// carried ASSUMED tags of their own, which is what made the clash visible.)
    private var autoAnsweredLabel: some View {
        TerminalStatusBadge(
            glyph: TerminalGlyph.working, label: "auto-answered",
            color: Colors.info, bordered: false)
    }

    private func autoAnsweredResult(answer: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            autoAnsweredLabel
            Text(answer)
                .font(Typography.termBase)
                .foregroundStyle(Colors.textSecondary)
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
                    // Same token as every other status caption in the feed
                    // (`MessageLoaderLabel`, `MessageThinkingSection`) — this
                    // row used `captionSemibold`, the same 11pt at a fourth
                    // weight, for no reason anyone recorded.
                    .font(Typography.termXs.weight(.medium))
                    .foregroundStyle(Colors.textTertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Plain ask — answered") {
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

/// The questionnaire's answered card, auto-answered — the state where the "auto-answered"
/// attribution stands directly above the transcript's own rows, an answered one and an
/// untouched one reading `(not answered)`. Two attributions about the same answer were drawn
/// in two different chromes until 2026-09-11, and only this pairing shows the seam.
#Preview("Questionnaire — auto-answered") {
    SupervisorInputCard(
        question: "A few decisions before I start on the exporter.",
        answer: "",
        inquiry: AnsweredInquiry(
            inquiry: SupervisorInquiry(
                headline: "A few decisions before I start on the exporter.",
                questions: [
                    SupervisorInquiryQuestion(
                        id: "scheme", prompt: "Which scheme should I build against?",
                        kind: .singleChoice,
                        options: [
                            SupervisorInquiryOption(id: "debug", label: "NanoTeams (Debug)"),
                            SupervisorInquiryOption(id: "release", label: "NanoTeams (Release)"),
                        ]),
                    SupervisorInquiryQuestion(
                        id: "notes", prompt: "Anything else I should know?", kind: .freeText),
                ]),
            answer: SupervisorInquiryAnswer(byQuestionID: [
                "scheme": .init(selectedOptionIDs: ["debug"]),
            ])),
        thinking: nil,
        thinkingID: UUID(),
        roleName: "Software Engineer",
        isAutoAnswering: false,
        wasAutoAnswered: true
    )
    .padding()
    .frame(width: 360)
    .background(Colors.surfaceCard)
    .environment(StoreConfiguration())
}
