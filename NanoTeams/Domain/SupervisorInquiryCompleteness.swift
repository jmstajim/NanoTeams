import Foundation

/// Whether a questionnaire the model just sent is complete enough to park a step on.
///
/// A choice with one option is not a choice: the card renders a single radio beside the
/// "other" escape, and the human is asked to decide between one thing. It is also what a
/// TRUNCATED emission decodes into once a dropped closer has been put back — the model
/// stopped mid-array, the repair closed the object it left open, and one of the two options
/// it meant to offer was never written (MeditationApp task 65 run 0, 2026-09-11). A tolerant
/// parser is a syntax guarantee only; completeness is the validator's job (playbook R3.7.6),
/// and without this one the repair would launder truncation into a valid-looking form.
///
/// At the TOOL seam, never in `SupervisorInquiry.init(from:)` — that decoder also reads the
/// PERSISTED `StepExecution.supervisorInquiry`, and a rule that refuses a one-option choice
/// there would strand every questionnaire already parked under it. Same reason
/// `SupervisorInquiryLabelRepair` runs here rather than in the decoder.
nonisolated enum SupervisorInquiryCompleteness {

    /// The fewest options a choice can offer and still be a choice.
    static let minOptionsPerChoice = 2

    /// The first question that is not complete, rendered for the model — or nil when every
    /// question is. The FIRST only: a model that truncated one array usually truncated the
    /// tail after it, and naming every consequence of one slip spends the message on noise.
    static func fault(in inquiry: SupervisorInquiry) -> String? {
        for (offset, question) in inquiry.questions.enumerated()
            where question.kind.isChoice && question.options.count < minOptionsPerChoice {
            return tooFewOptionsNote(
                questionNumber: offset + 1, options: question.options.count)
        }
        return nil
    }

    /// runtime-prompt
    ///
    /// Names the position (1-based, as the model wrote them), the count it sent, and the
    /// repair — including the one that is not "add an option", because a question that
    /// genuinely has one answer is a `free_text` question (R1.8.1).
    static func tooFewOptionsNote(questionNumber: Int, options: Int) -> String {
        "Question \(questionNumber) is a choice with \(options) option(s); a choice needs at "
            + "least \(minOptionsPerChoice). Add the missing option(s), or send that question "
            + "with `kind` free_text."
    }
}
