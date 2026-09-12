import Foundation

/// The headline a questionnaire that arrived WITHOUT one is given, taken from its own first
/// question.
///
/// `headline` is load-bearing rather than decorative (`SupervisorInquiry`'s own doc): the
/// Watchtower banner, the composer chip, the sidebar preview and the dismissal key each
/// render that one `String`, which is why the decoder refuses a blank one. The model,
/// though, writes `form` first and stops when the questionnaire closes — 4 of 20 runs on
/// 2026-09-12 (`ornith-1.5:35b`, MeditationApp task 76) emitted `{"form": {…}}` and nothing
/// else. Each cost a refusal and a whole second emission, and each recovered on the retry:
/// the requirement was not teaching the model anything, it was charging it a round trip.
/// That is the `form (string)` lesson one argument over — a required field the model
/// reliably drops is a defect in the contract, not in the model (CLAUDE.md #311) — and the
/// text it meant is already written down. In all four the first question's prompt WAS the
/// message ("Привет! Всё работает, инструменты на месте…").
///
/// Applied at the TOOL seam like `SupervisorInquiryLabelRepair`, never inside
/// `SupervisorInquiry.init(from:)`: that decoder also reads the questionnaire persisted on
/// the step, where a missing headline is corruption to refuse rather than an omission to
/// cover.
nonisolated enum SupervisorInquiryHeadlineFallback {

    /// What the Supervisor will see first, or nil when the questionnaire offers no text to
    /// take it from.
    ///
    /// Nil cannot arrive from a DECODED questionnaire — it has at least one question and
    /// every prompt is non-blank by then — so the caller's nil arm is fail-closed rather
    /// than live. Spelled as an Optional anyway: this type is handed questions, not the
    /// decoder's guarantee about them.
    static func headline(for questions: [SupervisorInquiryQuestion]) -> String? {
        guard let prompt = questions.first?.prompt else { return nil }
        // A headline is ONE line — every surface that renders it renders a single one, and a
        // prompt carrying a paragraph would push the rest of the card off all of them.
        let firstLine = prompt
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let firstLine, !firstLine.isEmpty else { return nil }
        guard firstLine.count > SupervisorInquiryLimits.maxHeadlineCharacters else {
            return firstLine
        }
        return abbreviated(firstLine)
    }

    /// runtime-prompt
    ///
    /// Reported like every other adopted rewrite (REC.5), and it names the omission rather
    /// than only the repair: a model that reads "a headline was invented for you" and not
    /// "send one" has been given a habit, not a correction.
    static let note =
        "No `headline` was sent, so the first question's own text was used as one. Send a "
            + "headline beside the form: it is the single line the Supervisor sees before "
            + "any question renders."

    /// runtime-prompt
    ///
    /// The model wrote a headline, inside the document instead of beside it — a spelling of
    /// the right intent, so it is READ rather than refused, and reported like every other
    /// adopted rewrite. 2 of 68 field calls took this shape (2026-09-12).
    static let nestedNote =
        "The `headline` was written inside the form; it was read from there. It is a "
            + "sibling of `form`, not a field in it."

    private static let ellipsis = "…"

    /// Cut to what the decoder accepts, at a word boundary when there is one to cut at.
    ///
    /// A live path, not a theoretical one: a prompt may be 2000 characters and a headline 400.
    private static func abbreviated(_ text: String) -> String {
        let budget = SupervisorInquiryLimits.maxHeadlineCharacters - ellipsis.count
        let head = text.prefix(budget)
        // Only a boundary in the LATTER half is worth taking; cutting at an early space
        // would throw away most of the line to avoid breaking one word.
        if let space = head.lastIndex(where: \.isWhitespace),
           head.distance(from: head.startIndex, to: space) >= budget / 2
        {
            return head[..<space].trimmingCharacters(in: .whitespaces) + ellipsis
        }
        return head.trimmingCharacters(in: .whitespaces) + ellipsis
    }
}
