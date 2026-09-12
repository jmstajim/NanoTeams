import Foundation

// MARK: - Caps

/// Structural limits on a model-authored questionnaire.
///
/// They are not defensive decoration: `JSONSchema` cannot express this shape (CLAUDE.md #46),
/// so the object arrives unvalidated and nothing but these stands between a runaway generation
/// and a card that cannot be read or answered. Every one of them is a REFUSAL, never a
/// truncation: a silently shortened questionnaire would ask the human to decide on a set the
/// model did not intend.
///
/// **The NUMBER of questions is deliberately not among them.** A cap of 8 stood here until
/// 2026-09-13, and what it did on the way out is the whole argument: handed a ten-question
/// redesign form it refused the batch, and the model resent EIGHT — dropping «с чем работать в
/// первую очередь» and «ограничения / must-not-break», the two that would have changed what it
/// did, and keeping the six about taste (MeditationApp task 87 run 1, 2026-09-12). A cap on a
/// count cannot select. It can only say "fewer", and the model then cuts what it is least sure
/// the human cares about — which is exactly the questions whose answers it lacks.
///
/// The count is also the one dimension where "too many" is the Supervisor's judgement rather
/// than a structural fault, and since a question left alone comes back `(not answered)` with
/// nothing filled in for it, an extra one costs its reader a glance. The refusal cost an
/// emission and two real questions.
///
/// So the TOTAL size of a questionnaire is deliberately unbounded, and every ELEMENT of it is
/// bounded: headline, prompt, option label and — since 2026-09-13 — every `detail`, plus
/// options per question, plus `SupervisorInquiryCompleteness` refusing the one-option choice
/// that a generation abandoned mid-question decodes into. That is the whole guard, stated
/// exactly: a runaway cannot produce an unreadable QUESTION, and nothing stops it from
/// producing many readable ones.
nonisolated enum SupervisorInquiryLimits {
    static let maxOptionsPerQuestion = 8
    static let maxHeadlineCharacters = 400
    static let maxPromptCharacters = 2000
    static let maxOptionLabelCharacters = 200
    /// The cap on a `detail`, on a question and on an option alike.
    ///
    /// It exists because the LABEL cap's own message points here — "Put the reasoning in
    /// `detail`" — and until 2026-09-13 that sent the model to the one field nothing checked,
    /// on a payload `JSONSchema` cannot validate. `detail` is not decoration on the wire
    /// either: `SupervisorInquiryReply.questionnaire(for:)` renders every one of them, and
    /// that text is what an automated answerer, a delegated parent and the Autovisor manager
    /// read.
    ///
    /// 500 is set from the field rather than from taste: across 200 archived questionnaires
    /// (824 option details, 91 question details) the median is 43 and 65 characters, the 95th
    /// percentile 87 and 147, and the longest ever written 206 and 224. The cap is more than
    /// twice the longest real one, so it bounds a runaway without reaching any questionnaire a
    /// model has actually produced.
    static let maxDetailCharacters = 500
}

// MARK: - Question kind

/// How one question is answered.
///
/// `freeText` is not "a question with no options": a choice question ALSO accepts free text
/// (the card always offers an "other" escape, because the model's options can all be wrong).
/// The kind decides what the card offers first. It decides nothing about an empty answer —
/// every kind reports an untouched question as unanswered, and nothing is filled in.
nonisolated enum SupervisorInquiryKind: String, Codable, Hashable, Sendable, CaseIterable {
    case freeText = "free_text"
    case singleChoice = "single_choice"
    case multiChoice = "multi_choice"

    /// Whether this kind is answered by picking from `options`.
    var isChoice: Bool { self != .freeText }
}

// MARK: - Option

/// One predefined answer.
///
/// There is no `isRecommended` flag here, and the reason survived the 2026-09-12 change: a
/// per-option flag makes "two options are recommended" representable, and that is a state the
/// card would have to invent a rule for. The recommendation lives on the QUESTION instead, as
/// at most one option id — so "two" stays unrepresentable while "none" became representable on
/// purpose, because none is the truth for most questions a model writes.
nonisolated struct SupervisorInquiryOption: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let label: String
    let detail: String?

    init(id: String, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

// MARK: - Question

nonisolated struct SupervisorInquiryQuestion: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let prompt: String
    let detail: String?
    let kind: SupervisorInquiryKind
    /// Ordered as the model wrote them. Empty for `freeText`.
    ///
    /// The order is the model's presentation, not a claim: it lists by scope, by cost, by
    /// whatever it is reasoning about. `recommendedOptionID` carries the claim.
    let options: [SupervisorInquiryOption]

    /// The option the model said it recommends — `nil` when it said nothing, which is the
    /// ordinary case.
    ///
    /// Resolved at the TOOL seam by `SupervisorInquiryLabelRepair` from what the model
    /// actually wrote, never asked for as an argument: this wire carries no grammar, so a
    /// declared key would be one more thing to emit and to get wrong, and the models observed
    /// in the field state a recommendation in an option's `detail` instead.
    ///
    /// Until 2026-09-12 this was `options[0]`, unconditionally. That made every choice
    /// question carry a recommendation whether the model had one or not: in the one archived
    /// design questionnaire, four badges for three stated recommendations — one of them on an
    /// option the model had argued against, one invented outright. A position cannot say "I
    /// have no preference", and most of the time that is exactly what the model means.
    let recommendedOptionID: String?

    init(
        id: String,
        prompt: String,
        detail: String? = nil,
        kind: SupervisorInquiryKind,
        options: [SupervisorInquiryOption] = [],
        recommendedOptionID: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.detail = detail
        self.kind = kind
        self.options = options
        self.recommendedOptionID = recommendedOptionID
    }

    /// The option the Supervisor is SHOWN as recommended — the card badges it and the
    /// rendered questionnaire tags it `(recommended)`. Nil when the model recommended
    /// nothing, and then neither surface claims one.
    ///
    /// Resolved by ID rather than by position, so the card, the wire and the audit log cannot
    /// disagree, and an id that names no option of this question resolves to nothing rather
    /// than to a neighbour.
    ///
    /// It is shown and never taken: nothing is filled in for a question nobody answered, so
    /// this is a suggestion the answerer may act on, not a value silence resolves to.
    var recommendedOption: SupervisorInquiryOption? {
        guard let recommendedOptionID else { return nil }
        return options.first { $0.id == recommendedOptionID }
    }
}

// MARK: - Inquiry

/// A questionnaire the Supervisor is asked to fill in.
///
/// `headline` is mandatory and load-bearing, not a title: every surface that already renders
/// a supervisor question renders a `String` — the Watchtower banner, the composer chip label,
/// the sidebar preview, the dismissal key. Keeping one carries all of them across unchanged,
/// and it is what a card can show while the (much larger) body is still streaming.
nonisolated struct SupervisorInquiry: Codable, Hashable, Sendable {
    let headline: String
    let questions: [SupervisorInquiryQuestion]

    init(headline: String, questions: [SupervisorInquiryQuestion]) {
        self.headline = headline
        self.questions = questions
    }
}

// MARK: - Answer

/// What the human (or an automated answerer) decided, per question.
///
/// Keyed by question id rather than positional, so a half-filled answer survives the card
/// re-rendering and cannot be silently re-attached to a different question.
nonisolated struct SupervisorInquiryAnswer: Codable, Hashable, Sendable {

    /// One question's decision.
    ///
    /// Every entry here was PUT here by whoever answered. There is no flag separating a
    /// decision from an assumption, because an assumption never becomes an entry: until
    /// 2026-09-12 an untouched choice was filled in from `options[0]` and marked
    /// `wasDefaulted`, which recorded the Supervisor as having decided the one question they
    /// had said nothing about. A question nobody answered now has no entry at all, and the
    /// renderer reports the absence.
    nonisolated struct QuestionAnswer: Codable, Hashable, Sendable {
        var selectedOptionIDs: [String]
        var freeText: String?

        init(selectedOptionIDs: [String] = [], freeText: String? = nil) {
            self.selectedOptionIDs = selectedOptionIDs
            self.freeText = freeText
        }

        /// Whether the human put anything here at all — the gate the draft store uses to
        /// decide a form is worth keeping, and the rule `decided(in:)` uses to drop an entry
        /// that says nothing.
        var isEmpty: Bool {
            selectedOptionIDs.isEmpty
                && (freeText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    var byQuestionID: [String: QuestionAnswer]

    /// What the Supervisor said that no single question claimed — their prose beside the card,
    /// or the part of an automated answerer's reply that named no question.
    ///
    /// Part of the ANSWER and not of the prose alone. The renderer's doc says the structure is
    /// the record and the rendered text is only the wire's view of it; without this field that
    /// was false for the one half a person is likeliest to have written by hand, and the feed
    /// re-rendering the record would have silently dropped their sentence.
    ///
    /// Written at composition (`SupervisorInquiryReply.compose`), never by the card: the card's
    /// prose lives in the composer's own text field until it is submitted.
    var note: String?

    init(byQuestionID: [String: QuestionAnswer] = [:], note: String? = nil) {
        self.byQuestionID = byQuestionID
        self.note = note
    }

    /// Whether any QUESTION was answered. Deliberately blind to `note`, because this is the
    /// gate that decides whether a half-filled form is worth parking as a draft, and a card
    /// never holds a note — one that counted it would be answering a different question from
    /// the one every caller asks.
    var isEmpty: Bool { byQuestionID.values.allSatisfy(\.isEmpty) }
}

// MARK: - Identity

nonisolated extension SupervisorInquiry {

    /// A stable name for THIS questionnaire, folded from everything a person answers against.
    ///
    /// Not a hash: Swift randomizes `String.hashValue` per process (CLAUDE.md #22), and this is
    /// compared across a panel re-host and read back from a parked draft. Not the question ids
    /// either — they are unique only WITHIN one questionnaire, and a local model asked the same
    /// stock question twice emits the same slug both times, so two different forms can share
    /// every id it has.
    ///
    /// What it is FOR: an answer belongs to the questionnaire it was filled against and to
    /// nothing else. The composer's fields follow whichever chip is selected and the panel's
    /// follow the conversation branch — both correct for prose, and both wrong for a set of
    /// ticks, which mean nothing beside a different set of questions. Comparing this is how a
    /// surface tells "the form on screen is the one these answers are for" from "these answers
    /// are someone else's".
    var identity: String {
        let unit = "\u{1E}"
        var parts: [String] = [headline]
        for question in questions {
            parts.append(question.id)
            parts.append(question.prompt)
            parts.append(question.detail ?? "")
            parts.append(question.kind.rawValue)
            for option in question.options {
                parts.append(option.id)
                parts.append(option.label)
                parts.append(option.detail ?? "")
            }
        }
        return parts.joined(separator: unit)
    }
}

// MARK: - Draft

/// A half-filled questionnaire, and the questionnaire it is half-filled AGAINST.
///
/// The pair is the type, because neither half is usable alone. An answer on its own is a
/// dictionary of ids that resolve against one form and silently resolve against nothing — or,
/// worse, against a DIFFERENT form that reused an id — anywhere else. Every place a live or
/// parked answer is read now has to name the questionnaire it is reading it for, which is what
/// makes "these ticks are not for this form" a state the code can be in rather than a state it
/// falls into.
nonisolated struct SupervisorInquiryDraft: Codable, Hashable, Sendable {
    /// `SupervisorInquiry.identity` of the form these answers were given to.
    let inquiryID: String
    var answer: SupervisorInquiryAnswer

    init(inquiryID: String, answer: SupervisorInquiryAnswer) {
        self.inquiryID = inquiryID
        self.answer = answer
    }

    init(inquiry: SupervisorInquiry, answer: SupervisorInquiryAnswer) {
        self.init(inquiryID: inquiry.identity, answer: answer)
    }

    var isEmpty: Bool { answer.isEmpty }

    /// The answers, but only if they were given to `inquiry`. Nil otherwise — including when
    /// `inquiry` is nil, which is the plain-`ask_supervisor` case: a step that is not asking a
    /// questionnaire has nothing these ticks could be an answer to.
    func answer(for inquiry: SupervisorInquiry?) -> SupervisorInquiryAnswer? {
        guard let inquiry, inquiry.identity == inquiryID else { return nil }
        return answer
    }
}

// MARK: - Submission

/// What a HUMAN's card produced, as it reaches the step.
///
/// Its PRESENCE is what says "a person filled this in" — not the emptiness of the answer inside
/// it. The two origins are read differently and must be told apart by origin: an automated
/// answerer replies in prose that is parsed against the questionnaire (`Q2: 1, 3`), and running
/// a person's sentence through that grammar turns "1. I'd rather use Release" into a selection
/// of option 1, which is the recommendation they were arguing against.
nonisolated struct SupervisorInquirySubmission: Hashable, Sendable {
    /// The decisions, as the card holds them. Empty is a real and ordinary value: a Supervisor
    /// who answers entirely in prose has decided nothing, and every question is then reported
    /// as unanswered, which is true.
    var answer: SupervisorInquiryAnswer
    /// The prose typed BESIDE the form — the words themselves, not the reply assembled for the
    /// model, which additionally carries clip and attached-file sections (and, with
    /// `embedFilesInPrompt`, whole file bodies).
    var note: String?

    init(answer: SupervisorInquiryAnswer = SupervisorInquiryAnswer(), note: String? = nil) {
        self.answer = answer
        self.note = note
    }
}
