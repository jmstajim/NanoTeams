import SwiftUI

// MARK: - Supervisor Inquiry Transcript

/// A questionnaire and what was decided, read-only, for the feed's answered card.
///
/// The wire already carries the same content as prose — `SupervisorInquiryRenderer.render`
/// numbers the `Q`/`A` pairs so the model can count them — and the feed showed exactly that
/// blob. It is readable and it is undifferentiated: the question, the answer and the note that
/// belonged to none of them arrive as one paragraph, and the assumption marker rides at the end
/// of a line as more of the same grey.
///
/// This is the same content with the structure kept: one row per question, and the decision
/// beside it — or, for a question the Supervisor left alone, the absence of one. Two states and
/// no third: until 2026-09-12 an untouched CHOICE was filled in from `options[0]` and wore an
/// `assumed` tag here, which drew a green tick on the one question its reader had said nothing
/// about. Nothing is filled in now, so the row that says nothing looks like one.
///
/// The words themselves come from the renderer (`statedAnswer`), never spelled again here: a
/// card that described the decision differently from the wire would be a record of an answer
/// nobody sent.
struct SupervisorInquiryTranscript: View {
    let inquiry: SupervisorInquiry
    let answer: SupervisorInquiryAnswer
    /// Prose the Supervisor wrote beside the form, addressed to the whole questionnaire.
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                Text(note)
                    .font(Typography.termBase)
                    .foregroundStyle(Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(Array(inquiry.questions.enumerated()), id: \.element.id) { index, question in
                row(number: index + 1, question: question)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What an unanswered row says to a HUMAN.
    ///
    /// Spelled here rather than borrowed from `SupervisorInquiryRenderer.unansweredMarker`,
    /// which reads identically today: that one is wire text, registered as an input of
    /// `RuntimePromptRegistry`'s fingerprint, and sharing it would make a label on screen part
    /// of what a prompt-version change is measured over — the same reason `kindLabel` refuses to
    /// reuse the renderer's `(pick one)` hint.
    private static let unansweredText = "(not answered)"

    private func row(number: Int, question: SupervisorInquiryQuestion) -> some View {
        let entry = answer.byQuestionID[question.id]
        let stated = SupervisorInquiryRenderer.statedAnswer(to: question, answer: entry)

        return VStack(alignment: .leading, spacing: Spacing.xxs) {
            // Byte-for-byte the pair the SAME card gives a resolved plain `ask_supervisor`
            // question one row above (`SupervisorInputCard`): body size, tertiary ink. A
            // question that has been answered recedes by COLOUR; shrinking it to the tag scale
            // as well made the questionnaire's questions unreadable next to the plain one's.
            Text("\(number). \(question.prompt)")
                .font(Typography.termBase)
                .foregroundStyle(Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                StatusGlyph(
                    glyph: stated == nil ? TerminalGlyph.bullet : TerminalGlyph.done,
                    color: stated == nil ? Colors.textTertiary : Colors.success)
                Text(stated ?? Self.unansweredText)
                    .font(Typography.termBase)
                    .foregroundStyle(stated == nil ? Colors.textTertiary : Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }
    }
}

#if DEBUG
#Preview("Inquiry Transcript") {
    SupervisorInquiryTranscript(
        inquiry: SupervisorInquiry(
            headline: "A few decisions before I start.",
            questions: [
                SupervisorInquiryQuestion(
                    id: "scheme", prompt: "Which scheme should I build against?",
                    kind: .singleChoice,
                    options: [
                        SupervisorInquiryOption(id: "debug", label: "NanoTeams (Debug)"),
                        SupervisorInquiryOption(id: "release", label: "NanoTeams (Release)"),
                    ]),
                SupervisorInquiryQuestion(
                    id: "suites", prompt: "Which suites should I run?",
                    kind: .multiChoice,
                    options: [
                        SupervisorInquiryOption(id: "unit", label: "Unit tests"),
                        SupervisorInquiryOption(id: "ui", label: "UI tests"),
                    ]),
                SupervisorInquiryQuestion(
                    id: "notes", prompt: "Anything else?", kind: .freeText),
            ]),
        answer: SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["debug"]),
            "suites": .init(selectedOptionIDs: ["unit"]),
        ]),
        note: "Keep the diff tight, please.")
        .padding(Spacing.l)
        .frame(width: 460)
        .background(Colors.surfaceCard)
}
#endif
