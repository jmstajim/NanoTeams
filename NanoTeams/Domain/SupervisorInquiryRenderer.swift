import Foundation

/// Renders a filled-in questionnaire as the prose the MODEL receives.
///
/// Prose, not JSON, and the choice is load-bearing in two places. The answer rides inside
/// `buildCollaborationToolResult`'s `response` field, which `CompactionPolicy` already reads
/// to carry the Supervisor's words verbatim across an epoch — a JSON blob there would be
/// preserved as a blob. And `conversation_log.md` is meant to be read by a person: an answer
/// that needs a parser to be understood is an answer nobody audits.
///
/// The structured form is not lost by rendering it: it is persisted on the step
/// (`supervisorInquiryAnswer`), which is what the feed re-renders the answered card from.
/// This function is the wire's view, not the record.
nonisolated enum SupervisorInquiryRenderer {

    /// runtime-prompt
    ///
    /// A question nobody answered — any kind. Until 2026-09-12 a CHOICE could not carry this:
    /// the submit pass filled it from `options[0]` and marked it assumed, so an untouched
    /// choice and an agreed-with recommendation differed only by a suffix, and a person who
    /// skipped a question was reported as having decided it. Nothing is filled in now, and the
    /// absence is the whole report.
    static let unansweredMarker = "(not answered)"

    /// runtime-prompt
    ///
    /// What the receiving role does about the absences. Appended ONCE, below the pairs, when
    /// any question came back without a stated answer — once and not per question, because it
    /// is addressed to the whole answer and a copy under each marker would spend the recency
    /// slot on repetition (R4.3.2).
    ///
    /// A marker alone leaves the role to invent a next action, and the cheapest one a local
    /// model invents is asking again: there is no per-step ask cap, and a reworded re-ask
    /// slips past `LoopSignal.identicalToolCallSequence`. So this names decide-and-record and
    /// deliberately offers no way to re-ask — a form the Supervisor skipped on purpose is one
    /// they will skip again.
    ///
    /// Anchored to the markers above it rather than to the reader's now, so it stays true at
    /// any distance (R3.8.4): the answer is never retired from the wire.
    static let unansweredDirection =
        "The questions marked \(unansweredMarker) have no decision behind them. Decide each "
            + "one yourself and record that decision as an assumption in what you produce."

    /// The answer body for a whole questionnaire.
    ///
    /// Numbered `Q`/`A` pairs rather than a bulleted list: the model asked N questions and is
    /// getting N answers, and a positional pairing it can count is what lets it act on the
    /// third one without re-deriving which is which.
    ///
    /// - Parameter note: whatever the Supervisor said that no single question claimed — a
    ///   human's prose beside the card, or the part of an automated answerer's reply that
    ///   named no question. It leads, once, above the pairs: it is addressed to the whole
    ///   questionnaire, and repeating it under each free-text question would attribute it to
    ///   answers it never gave.
    static func render(
        inquiry: SupervisorInquiry, answer: SupervisorInquiryAnswer, note: String? = nil
    ) -> String {
        var lines: [String] = []
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            lines.append(note)
            lines.append("")
        }
        var anyUnanswered = false
        for (index, question) in inquiry.questions.enumerated() {
            let number = index + 1
            let entry = answer.byQuestionID[question.id]
            // The SAME predicate the marker is chosen by, so the direction below and the
            // markers above can never disagree about which questions went undecided.
            if statedAnswer(to: question, answer: entry) == nil { anyUnanswered = true }
            lines.append("Q\(number). \(question.prompt)")
            lines.append("A\(number). \(renderAnswer(to: question, answer: entry))")
        }
        if anyUnanswered {
            lines.append("")
            lines.append(unansweredDirection)
        }
        return lines.joined(separator: "\n")
    }

    /// One question's answer line, without its `A<n>. ` prefix.
    static func renderAnswer(
        to question: SupervisorInquiryQuestion,
        answer: SupervisorInquiryAnswer.QuestionAnswer?
    ) -> String {
        statedAnswer(to: question, answer: answer) ?? unansweredMarker
    }

    /// What the answer SAYS — the chosen labels and the prose beside them — and nil when it
    /// says nothing.
    ///
    /// Split out because it is also the PREDICATE for "this question went undecided": the
    /// feed's transcript picks its glyph by it, and `render` gates the direction line on it.
    /// One function, so the card, the wire and the audit log cannot disagree about which
    /// questions the Supervisor answered.
    static func statedAnswer(
        to question: SupervisorInquiryQuestion,
        answer: SupervisorInquiryAnswer.QuestionAnswer?
    ) -> String? {
        guard let answer, !answer.isEmpty else { return nil }

        // Hashed membership, not a linear scan per option: both sides are capped, but the
        // shape is O(options × selections) and the complexity axis `a1` ranks it — a set is
        // the same three lines and does not have to be re-justified when a cap moves.
        let selected = Set(answer.selectedOptionIDs)
        let labels = question.options
            .filter { selected.contains($0.id) }
            .map(\.label)
        let freeText = answer.freeText?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Selections and free text are not alternatives: a choice question always offers an
        // "other" escape, and a human who picks an option AND qualifies it in prose has said
        // two things. Dropping either half would edit the answer.
        var parts: [String] = []
        if !labels.isEmpty { parts.append(labels.joined(separator: ", ")) }
        if let freeText, !freeText.isEmpty { parts.append(freeText) }
        guard !parts.isEmpty else { return nil }

        return parts.joined(separator: " — ")
    }
}
