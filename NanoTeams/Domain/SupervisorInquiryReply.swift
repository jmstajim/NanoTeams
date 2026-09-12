import Foundation

/// The text contract between a questionnaire and a TEXTUAL reply to it.
///
/// Both halves live here on purpose. An automated answerer — the `.autonomous` mode's
/// Supervisor, the Autovisor's `answer_task_question`, a delegating parent role — is an LLM
/// that receives prose and returns prose; it cannot be handed a `SupervisorInquiryAnswer` and
/// cannot produce one. So the questionnaire has to be rendered for it, and its reply has to be
/// read back. Rendering the ask and parsing the answer are one contract, and splitting them
/// across two files is how the two halves come to disagree about what a reply looks like.
///
/// The human path uses only the second half: the card produces the structure directly, and
/// `compose` renders it with the same numbering the model was asked in. One renderer for both
/// origins means the asking role cannot tell from the shape of the answer whether a person or
/// an LLM filled it in — and one silence semantics (`SupervisorInquiryAnswer.decided(in:)`,
/// reached from both branches) means it cannot tell them apart by what an omission produced
/// either. A question nobody answered reads the same whoever the answerer was.
nonisolated enum SupervisorInquiryReply {

    // MARK: - The ask

    /// runtime-prompt
    ///
    /// The questionnaire as an automated answerer sees it: the headline, one numbered block
    /// per question, and the reply contract.
    ///
    /// The contract rides INSIDE this text rather than beside it because the three answerers
    /// reach the questionnaire through three different seams — a tool result (`task_status`),
    /// a question turn (`DelegatedSupervisorAnswerService`), and a user turn
    /// (`SupervisorAutoAnswerService`) — and a contract each of them appended itself would be
    /// three copies with three fates. Here it is one string, versioned once.
    ///
    /// Options are numbered rather than named by id: a model reproduces `2` reliably and a
    /// slug like `what_ci_uses` only sometimes, and the parser accepts labels anyway, so
    /// numbering costs nothing and removes the commonest way a reply fails to land.
    static func questionnaire(for inquiry: SupervisorInquiry) -> String {
        var lines: [String] = [inquiry.headline, ""]
        for (index, question) in inquiry.questions.enumerated() {
            lines.append("Q\(index + 1). \(question.prompt)  \(hint(for: question.kind))")
            if let detail = question.detail, !detail.isEmpty {
                lines.append("  \(detail)")
            }
            for (optionIndex, option) in question.options.enumerated() {
                // `optionRow`, not `row`: the complexity scanner resolves a receiver's kind
                // by BARE NAME across the whole tree, so a `var row: String` here retro-ranks
                // every `row.count` elsewhere as a grapheme walk — it did exactly that to
                // `XLSXDocumentExtractor`, whose `row` is an `[String]` and whose count is
                // O(1). A common name in a new file is a cross-file hazard.
                var optionRow = "  \(optionIndex + 1). \(option.label)"
                if let detail = option.detail, !detail.isEmpty { optionRow += " — \(detail)" }
                // The RESOLVED recommendation, not position zero. One source of truth with the
                // card: a tag here and a badge there that could disagree would be two answers
                // to "which one does the asking role recommend", and the automated answerer is
                // told to take it when information is missing.
                if option.id == question.recommendedOptionID { optionRow += "  \(recommendedTag)" }
                lines.append(optionRow)
            }
        }
        lines.append("")
        lines.append(replyContract)
        return lines.joined(separator: "\n")
    }

    /// What the model said it recommends. A word, not a sentence: it sits at the end of an
    /// option row. It marks the option the model actually named, and no row wears it when the
    /// model named none — which is most questions.
    static let recommendedTag = "(recommended)"

    private static func hint(for kind: SupervisorInquiryKind) -> String {
        switch kind {
        case .freeText: return "(in your own words)"
        case .singleChoice: return "(pick one)"
        case .multiChoice: return "(pick one or more)"
        }
    }

    /// The one sentence that tells an answerer how to shape its reply, plus what silence
    /// costs. Both halves matter, and the second changed sign on 2026-09-12: an omission is no
    /// longer filled in from the recommendation, so an answerer that thinks it is will skip a
    /// question believing it decided one.
    ///
    /// Completeness is stated HERE and nowhere else on this path. The three automated seams
    /// render this one string, and `SupervisorAutoAnswerService`'s tail sits two lines below
    /// it in the same user turn — a second "answer every question" there is the restatement
    /// R4.3.2 refuses, adjacent enough for the model to read both.
    private static let replyContract =
        "Answer with one line for every question — `Q1: 2` to choose, `Q2: 1, 3` to choose "
            + "several, `Q3: <your words>` for the rest. A question you leave out reaches the "
            + "asking role marked not answered, and nothing is chosen in its place."

    // MARK: - The reply

    /// A parsed reply: what it decided, and what it said that no question claimed.
    ///
    /// `note` is not a leftover to discard. A model asked three questions and given a
    /// paragraph has been told something; dropping the paragraph because it did not start
    /// with `Q1:` would edit the Supervisor's answer down to what the parser happened to
    /// recognise.
    struct Parsed: Hashable, Sendable {
        var answer: SupervisorInquiryAnswer
        var note: String?
    }

    /// Reads a textual reply against the questionnaire it answers.
    ///
    /// Unmatched questions are NOT guessed at from the prose: whatever the reply said outside
    /// a `Q<n>:` line rides as `note`, verbatim and once, and the questions it did not name
    /// come back unanswered. Spreading the prose into every free-text field instead would put
    /// the same paragraph in front of the asking role three times, each labelled as an answer
    /// to a different question — a claim the reply never made.
    static func parse(_ reply: String, inquiry: SupervisorInquiry) -> Parsed {
        var byQuestionID: [String: SupervisorInquiryAnswer.QuestionAnswer] = [:]
        var unconsumed: [String] = []

        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            guard let (number, rest) = questionLine(raw),
                  inquiry.questions.indices.contains(number - 1)
            else {
                unconsumed.append(raw)
                continue
            }
            let question = inquiry.questions[number - 1]
            // Last line wins for a repeated number: a model that restates a question has
            // changed its mind, and the earlier line is the draft.
            byQuestionID[question.id] = answer(to: question, stated: rest)
        }

        let note = unconsumed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(
            answer: SupervisorInquiryAnswer(byQuestionID: byQuestionID).decided(in: inquiry),
            note: note.isEmpty ? nil : note)
    }

    /// The two things a delivered answer produces: the structure to persist and the prose the
    /// asking role reads.
    ///
    /// One function for every origin — the in-loop autonomous answerer, the two parked
    /// automated paths, and the human card — because the alternative is each seam rendering
    /// its own wire text, and a step whose persisted structure and sent prose disagree is a
    /// record nobody can audit.
    ///
    /// The branch is chosen by ORIGIN, not by emptiness. `submission` non-nil means a person
    /// filled the card in, whatever they put in it: their prose is the note, verbatim, and the
    /// questions they left alone are reported as unanswered. Reading it back with `parse`
    /// instead — the grammar written for a model's `Q2: 1, 3` reply — would turn a sentence
    /// that opens "1. I'd rather use Release" into a selection of option 1, which is the
    /// recommendation they were arguing against. `submission == nil` is an automated answerer,
    /// and for one the parse is the only way in.
    ///
    /// `reply` is what the MODEL receives and `submission.note` is what the RECORD keeps, and
    /// they are deliberately different strings on the human path: `reply` is the assembled
    /// answer (prose plus clip and attached-file sections, whole file bodies under
    /// `embedFilesInPrompt`), while the note is the words the Supervisor typed.
    ///
    /// Returns the reply unchanged when there is no questionnaire, so the plain
    /// `ask_supervisor` path is byte-for-byte what it always was.
    static func compose(
        inquiry: SupervisorInquiry?,
        reply: String,
        submission: SupervisorInquirySubmission? = nil
    ) -> (text: String, answer: SupervisorInquiryAnswer?) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let inquiry else { return (trimmed, nil) }

        let answer: SupervisorInquiryAnswer
        // Two notes, deliberately. The WIRE note is the whole reply — a human's is assembled
        // (prose plus `## Clipped Text` / `## Attached File` sections, whole file bodies under
        // `embedFilesInPrompt`), and the model must receive all of it or attaching context to a
        // questionnaire answer silently delivers nothing. The RECORDED note is the words the
        // Supervisor typed: the feed re-renders from the record, and section markers there
        // would print raw above the decisions, beside the attachment grid already showing the
        // same files.
        let wireNote: String?
        let recordedNote: String?
        if let submission {
            answer = submission.answer.decided(in: inquiry)
            wireNote = trimmed.isEmpty ? nil : trimmed
            let typed = submission.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            recordedNote = typed.isEmpty ? nil : typed
        } else {
            let parsed = parse(trimmed, inquiry: inquiry)
            answer = parsed.answer
            wireNote = parsed.note
            recordedNote = parsed.note
        }
        var recorded = answer
        recorded.note = recordedNote
        return (
            SupervisorInquiryRenderer.render(inquiry: inquiry, answer: answer, note: wireNote),
            recorded
        )
    }

    // MARK: - Line reading

    /// Markdown emphasis around an answer (`**2**`) is decoration on the reply, not part of
    /// it. Trimmed at the edges only — an asterisk inside the prose is the answerer's own
    /// word, and deleting those would edit what the Supervisor said.
    private static let emphasisAndSpace = CharacterSet(charactersIn: " *")
        .union(.whitespacesAndNewlines)

    /// What separates a selection from the sentence that qualifies it — `2 — because CI does`.
    private static let separatorAndSpace = CharacterSet(charactersIn: " -—–:,*")
        .union(.whitespacesAndNewlines)



    /// `Q2: …`, `2. …`, `- **Q2:** …` — the shapes a local model actually emits for a
    /// numbered answer. The leading bullet and the emphasis are stripped rather than refused:
    /// a reply is not a payload the model can be asked to re-send, because the step it
    /// answers has already been unblocked by the time anything reads it.
    private static func questionLine(_ line: String) -> (number: Int, rest: String)? {
        var scan = Substring(line).drop { $0 == " " || $0 == "\t" }
        while let first = scan.first, first == "-" || first == "*" || first == "•" || first == "#" {
            scan = scan.dropFirst().drop { $0 == " " || $0 == "\t" }
        }
        if scan.first == "Q" || scan.first == "q" { scan = scan.dropFirst() }
        let digits = scan.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        // Sliced past the digits by INDEX. `dropFirst(digits.count)` would walk the digits
        // once to count them and again to drop them — ranked by the complexity axis `a5`,
        // and pointless when the prefix already knows where it ends.
        scan = scan[digits.endIndex...].drop { $0 == " " || $0 == "*" }
        guard let separator = scan.first, separator == ":" || separator == "." || separator == ")" else {
            return nil
        }
        return (number, String(scan.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    /// One question's answer, read from the body of its line.
    private static func answer(
        to question: SupervisorInquiryQuestion, stated: String
    ) -> SupervisorInquiryAnswer.QuestionAnswer {
        let cleaned = stated.trimmingCharacters(in: Self.emphasisAndSpace)
        guard question.kind.isChoice else {
            return SupervisorInquiryAnswer.QuestionAnswer(freeText: cleaned.isEmpty ? nil : cleaned)
        }

        let (numbered, remainder) = leadingSelection(in: cleaned, optionCount: question.options.count)
        var selected = numbered
        var freeText = remainder
        if selected.isEmpty {
            // No numbers, so the answerer named the option instead — which is also what a
            // human pasting a label does. Matching the labels is the difference between
            // reading that answer and silently defaulting over it.
            var named: [Int] = []
            for (index, option) in question.options.enumerated()
                where matches(cleaned, option: option) {
                named.append(index)
            }
            selected = named
            if !selected.isEmpty { freeText = "" }
        }
        if question.kind == .singleChoice, selected.count > 1 {
            // A single-choice question answered with several is a contradiction the asking
            // role cannot act on. The first is the answerer's own ranking, and the rest ride
            // as prose so nothing it said is lost.
            let extra = selected.dropFirst().map { question.options[$0].label }.joined(separator: ", ")
            freeText = freeText.isEmpty ? "also: \(extra)" : "\(freeText) — also: \(extra)"
            selected = [selected[0]]
        }

        let ids = selected.map { question.options[$0].id }
        let trimmedFree = freeText.trimmingCharacters(in: Self.separatorAndSpace)
        return SupervisorInquiryAnswer.QuestionAnswer(
            selectedOptionIDs: ids,
            freeText: trimmedFree.isEmpty ? nil : trimmedFree)
    }

    /// The run of option numbers a body opens with, and whatever follows them.
    ///
    /// Leading only: a number later in the sentence is part of what the answerer is saying
    /// ("build 2 of the 3 targets"), and reading it as a selection would record a choice
    /// nobody made.
    private static func leadingSelection(
        in text: String, optionCount: Int
    ) -> (indices: [Int], remainder: String) {
        var indices: [Int] = []
        var seen = Set<Int>()
        var scan = Substring(text)
        while true {
            let head = scan.drop { $0 == " " || $0 == "," || $0 == "+" }
            let digits = head.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits), value >= 1, value <= optionCount else {
                break
            }
            if seen.insert(value - 1).inserted { indices.append(value - 1) }
            scan = head[digits.endIndex...]
            // `and` between numbers is a separator, not prose.
            let afterWord = scan.drop { $0 == " " }
            if afterWord.lowercased().hasPrefix("and ") { scan = afterWord.dropFirst(4) }
        }
        guard !indices.isEmpty else { return ([], text) }
        return (indices, String(scan))
    }

    /// Whether a body names this option — by id, or by its label as a whole word run.
    private static func matches(_ text: String, option: SupervisorInquiryOption) -> Bool {
        let haystack = text.lowercased()
        if haystack == option.id.lowercased() { return true }
        let label = option.label.lowercased()
        guard !label.isEmpty else { return false }
        return haystack == label || haystack.contains(label)
    }
}
