import Foundation

/// Whether a plain `ask_supervisor` question has the shape `ask_supervisor_form` exists for.
///
/// The plain ask carries ONE question or a chat reply; the questionnaire carries several
/// questions, each with the answers the role thinks likely. The prompt said so (`choiceFragment`,
/// deleted in 1.9.20 — the `## Final reminder` names the form now), and measured on 2026-09-11 the sentence did not hold: across two Personal
/// Assistant runs (`ornith-1.5:35b`, Ollama 0.34.0) 30 of 51 plain asks carried a question,
/// most of them a numbered list of questions — the structure the form exists to carry,
/// hand-rolled in prose, for a human to answer as free text. A constraint the prompt cannot
/// hold moves into the instrument (playbook R1.2.2, R4.3.4): `AskSupervisorTool` refuses this
/// shape when the batch holds the form, and the refusal names the form. Never when it does not:
/// a numbered list is the only shape a role with the plain ask alone can send,
/// and a refusal pointing at a tool the role lacks is the
/// 2026-07-25 defect — `ToolExecutionContext.questionnaireAvailable` is the switch.
///
/// Two shapes, both read off the text with code spans and strong-emphasis markers removed (a
/// Swift optional is a `?` before a newline; `**1. … (recommended)**` is the item it wraps):
/// - two or more question sentences — a `?` (or `？`) that closes a sentence, i.e. is followed
///   by whitespace, a closing quote or bracket, or the end of the text; a run of `?`/`!` counts
///   once, and a `?` inside a URL or a word closes nothing;
/// - one question sentence followed by two or more enumerated items — `1.`, `1)`, `(1)`, `a)`
///   anywhere after it, or a `-` / `•` / `*` bullet opening a line — a choice with its options
///   spelled out.
///
/// Options BEFORE the question — "pick one: 1. … 2. … 3. … Which would you like?", the
/// shape the first after-gate run sent past a rule that read only the tail — are told apart
/// from a plan before a confirmation ("1. … 2. … 3. … Shall I proceed?") by the question
/// itself OPENING with a choice word (which / choose / pick / prefer / option, and the Russian
/// equivalents, within its first four words) or by an item wearing the `(recommended)` mark the
/// prose fallback prescribed until 1.9.20 and models keep writing. A plan is not a menu; a menu says so.
///
/// A reply quoting two of the Supervisor's questions back IS refused; the price is one turn.
nonisolated enum SupervisorQuestionShape {

    /// The one verdict the GATE and the NUDGE both read: this text belongs in the form, and
    /// the form is there to receive it.
    ///
    /// Two readers, one predicate, because they answered the same question differently and
    /// the disagreement cost a turn per occurrence. `AskSupervisorTool` refused a plain ask
    /// carrying the questionnaire's shape while `noToolCallNudge` — which knows only the
    /// SCHEMA, never the text — had just told the model to put that text through
    /// `ask_supervisor`: nudge, refusal, form (MeditationApp task 52 run 10, 2026-09-11).
    ///
    /// - Parameter formAvailable: whether `ask_supervisor_form` is in the batch's authorized
    ///   set — `ToolExecutionContext.questionnaireAvailable` for the handler,
    ///   `allowedToolNames.contains(_:)` for the nudge, which is the same set. False gives the
    ///   permissive reading everywhere: the numbered list parks, and no text names a tool the
    ///   role does not hold (the 2026-07-25 defect).
    static func requiresForm(_ text: String, formAvailable: Bool) -> Bool {
        formAvailable && isQuestionnaire(text)
    }

    static func isQuestionnaire(_ text: String) -> Bool {
        let prose = strippingMarkup(text)
        let ends = questionSentenceEnds(in: prose)
        if ends.count >= 2 { return true }
        guard let only = ends.first else { return false }
        if enumeratedItemCount(in: String(prose[only...])) >= 2 { return true }
        guard enumeratedItemCount(in: prose) >= 2 else { return false }
        return asksForAChoice(questionSentence(endingAt: only, in: prose))
            || anItemIsMarkedRecommended(in: prose)
    }

    /// The sentence the only `?` closes: back over the `?`/`!` run first (it is itself a
    /// terminator — read from `end` without that step, the sentence is always empty), then
    /// to the previous terminator or line break.
    static func questionSentence(endingAt end: String.Index, in text: String) -> String {
        var start = end
        while start > text.startIndex {
            let previous = text[text.index(before: start)]
            guard questionMarks.contains(previous) || previous == "!" else { break }
            start = text.index(before: start)
        }
        while start > text.startIndex {
            let previous = text.index(before: start)
            if terminators.contains(text[previous]) { break }
            start = previous
        }
        return String(text[start..<end])
    }

    /// The choice word must open the question — within its first four words: "Which would
    /// you like?", "Do you prefer…?", "Какой предпочитаете?". Anywhere in the sentence was the
    /// measured rule's one false positive (2026-09-11, task 7): a summary list and then "Can
    /// you point me to which component renders the badge?" — one information question, refused
    /// for the "which" six words in.
    static func asksForAChoice(_ sentence: String) -> Bool {
        let opening = sentence.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        return choiceWord.firstMatch(in: opening, range: NSRange(opening.startIndex..., in: opening)) != nil
    }

    static func anItemIsMarkedRecommended(in text: String) -> Bool {
        recommendedItem.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The index just past every run of `?` (and `!`) that closes a sentence.
    static func questionSentenceEnds(in text: String) -> [String.Index] {
        var ends: [String.Index] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard questionMarks.contains(text[i]) else {
                i = text.index(after: i)
                continue
            }
            var j = i
            while j < text.endIndex, questionMarks.contains(text[j]) || text[j] == "!" {
                j = text.index(after: j)
            }
            if j == text.endIndex || text[j].isWhitespace || closers.contains(text[j]) {
                ends.append(j)
            }
            i = j
        }
        return ends
    }

    /// Enumerated items: `1.` / `1)` / `(1)` / `a)` after whitespace or a line start, plus
    /// `-` / `•` / `*` bullets at a line start only — a spaced hyphen in prose is a dash.
    static func enumeratedItemCount(in text: String) -> Int {
        let whole = NSRange(text.startIndex..., in: text)
        return enumeration.numberOfMatches(in: text, range: whole)
            + bulletLine.numberOfMatches(in: text, range: whole)
    }

    /// Fenced blocks first (an unterminated fence runs to the end), then inline spans.
    static func strippingCodeSpans(_ text: String) -> String {
        var stripped = text
        for pattern in [fencedBlock, inlineCode] {
            stripped = pattern.stringByReplacingMatches(
                in: stripped, range: NSRange(stripped.startIndex..., in: stripped), withTemplate: " ")
        }
        return stripped
    }

    /// Code spans first, then the strong-emphasis markers: `**1. Тёмная тема (recommended)**`
    /// is the numbered item it wraps and the mark it wears — MeditationApp task 60 (2026-09-11)
    /// put its whole menu in bold headings, and read raw the line-anchored item stems missed
    /// every one, so the rule saw a plan. Two-character markers only: a single `*` opening a
    /// line is a bullet, a single `_` is part of a word. Classification only — the text the
    /// gate refuses and the nudge quotes is the model's own, markers included.
    static func strippingMarkup(_ text: String) -> String {
        let prose = strippingCodeSpans(text)
        return strongEmphasis.stringByReplacingMatches(
            in: prose, range: NSRange(prose.startIndex..., in: prose), withTemplate: "")
    }

    private static let questionMarks: Set<Character> = ["?", "？"]
    private static let closers: Set<Character> = [")", "]", "\"", "'", "»", "”", "’", "*", "_"]
    private static let fencedBlock = try! NSRegularExpression(
        pattern: "```.*?(?:```|\\z)", options: [.dotMatchesLineSeparators])
    private static let inlineCode = try! NSRegularExpression(pattern: "`[^`\\n]*`")
    private static let strongEmphasis = try! NSRegularExpression(pattern: #"\*\*|__"#)
    // The item stems are shared with `SupervisorInquiryLabelRepair`, which strips the same
    // enumeration and the same marker off option LABELS: one spelling of "an item", so the
    // shape detector and the label repair cannot drift apart.
    private static let enumeration = try! NSRegularExpression(
        pattern: #"(?:^|\s)"# + SupervisorInquiryLabelRepair.enumerationItemStem + #"\s+\S"#,
        options: [.anchorsMatchLines])
    private static let bulletLine = try! NSRegularExpression(
        pattern: #"^[ \t]*[-•*]\s+\S"#, options: [.anchorsMatchLines])
    private static let terminators: Set<Character> = [".", "!", "?", "？", "\n", "\r"]
    private static let choiceWord = try! NSRegularExpression(
        pattern: #"\b(?:which|whichever|choose|pick|prefer|preferred|options?|alternatives?|какой|какую|какое|какие|который|которую|которые|выбер\w*|предпоч\w*)\b"#,
        options: [.caseInsensitive])
    private static let recommendedItem = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:"# + SupervisorInquiryLabelRepair.enumerationItemStem + #"|[-•*])\s+[^\n]*\b"#
            + SupervisorInquiryLabelRepair.recommendedWordStem + #"\b"#,
        options: [.anchorsMatchLines, .caseInsensitive])
}
