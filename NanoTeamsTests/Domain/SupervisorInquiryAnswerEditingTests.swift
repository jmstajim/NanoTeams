import XCTest

@testable import NanoTeams

/// What a card does to an answer as it is filled in — and what it refuses to do.
///
/// The rules live in `Domain/` rather than in the card's body precisely so they can be checked
/// here: `NanoTeams/Views/` is outside the coverage denominator, and two surfaces render this
/// questionnaire (the docked composer and the Quick Capture panel), so a rule either of them
/// spelled itself would be a rule the other could disagree with.
final class SupervisorInquiryAnswerEditingTests: XCTestCase {

    private func option(_ id: String, _ label: String) -> SupervisorInquiryOption {
        SupervisorInquiryOption(id: id, label: label)
    }

    private var scheme: SupervisorInquiryQuestion {
        SupervisorInquiryQuestion(
            id: "scheme", prompt: "Which scheme?", kind: .singleChoice,
            options: [option("debug", "Debug"), option("release", "Release")])
    }

    private var suites: SupervisorInquiryQuestion {
        SupervisorInquiryQuestion(
            id: "suites", prompt: "Which suites?", kind: .multiChoice,
            options: [option("unit", "Unit"), option("ui", "UI"), option("perf", "Perf")])
    }

    private var notes: SupervisorInquiryQuestion {
        SupervisorInquiryQuestion(id: "notes", prompt: "Anything else?", kind: .freeText)
    }

    // MARK: - Selection

    func testSelectionRoundTrips() {
        let answer = SupervisorInquiryAnswer().settingSelection(["debug"], for: scheme)
        XCTAssertEqual(answer.selection(for: "scheme"), ["debug"])
        XCTAssertEqual(answer.byQuestionID["scheme"]?.selectedOptionIDs, ["debug"])
    }

    func testSelectionOfNothingRemovesTheEntry() {
        let answer = SupervisorInquiryAnswer()
            .settingSelection(["debug"], for: scheme)
            .settingSelection([], for: scheme)
        XCTAssertTrue(answer.byQuestionID.isEmpty,
                      "un-ticking the last option leaves nothing to persist about the question")
        XCTAssertTrue(answer.isEmpty)
    }

    /// The selection is stored as a projection of the QUESTION's own options: an id the
    /// question does not offer is dropped, and what survives is in the order the model wrote.
    ///
    /// Both halves come from the same filter, and the first is the one with teeth. A card can
    /// be handed a selection that outlived its questionnaire — the role re-asked under the same
    /// question id with different options, or the Supervisor retargeted the composer — and an
    /// id nothing in the question resolves is a choice nobody was offered.
    ///
    /// RED: store `Array(ids)` instead of filtering the question's options → the answer records
    /// an option that does not exist, and the renderer, which resolves labels by matching the
    /// question's options, reports it as no answer at all.
    func testSelectionIsStoredAsAProjectionOfTheQuestionsOptions() {
        let answer = SupervisorInquiryAnswer()
            .settingSelection(["perf", "not-an-option", "unit"], for: suites)
        XCTAssertEqual(answer.byQuestionID["suites"]?.selectedOptionIDs, ["unit", "perf"],
                       "the stray id is gone, and the survivors are in the question's order")
    }

    /// Changing one's mind REPLACES the selection rather than adding to it — a single-choice
    /// question answered twice has one answer, the second.
    ///
    /// RED: merge the sets → the asking role reads two mutually exclusive options as both
    /// chosen, and the question it asked to settle a fork is settled by neither.
    func testEditingASelectionReplacesIt() {
        let first = SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["debug"])
        ])
        let edited = first.settingSelection(["release"], for: scheme)
        XCTAssertEqual(edited.byQuestionID["scheme"]?.selectedOptionIDs, ["release"])
    }

    /// Qualifying prose is added BESIDE the tick, not over it: a human who picks an option and
    /// then explains has said two things, and `decided(in:)` keeps the entry whole.
    ///
    /// RED: let `settingFreeText` clear the selection → the explanation deletes the decision
    /// it was explaining.
    func testEditingFreeTextKeepsTheSelectionAndSurvivesNormalisation() {
        let picked = SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["debug"])
        ])
        let edited = picked.settingFreeText("but only until CI moves", for: "scheme")
        let form = SupervisorInquiry(headline: "H", questions: [scheme])
        let decided = edited.decided(in: form)
        XCTAssertEqual(decided.byQuestionID["scheme"]?.selectedOptionIDs, ["debug"])
        XCTAssertEqual(decided.byQuestionID["scheme"]?.freeText, "but only until CI moves")
    }

    // MARK: - The "other" field's openness

    /// `nil` and `""` are different states: `""` IS the reveal. The panel re-hosts its view
    /// whenever the resolved mode changes identity, so a field opened in view state would
    /// close itself under the user's cursor.
    ///
    /// RED: drop the entry when it holds only an empty string → the "other" field the human
    /// just opened is closed again on the next render pass.
    func testOpeningTheOtherFieldSurvivesAsAnEmptyString() {
        let answer = SupervisorInquiryAnswer().settingFreeText("", for: "scheme")
        XCTAssertEqual(answer.freeText(for: "scheme"), "",
                       "open-and-blank is a state, and it is spelled by an empty string")
    }

    /// …and an open-but-blank field is still NOTHING as far as the draft store is concerned.
    ///
    /// RED: count an open field as content → merely clicking "Other…" mints a parked draft and
    /// lights a draft dot for an answer nobody has written.
    func testAnOpenButBlankFieldIsStillAnEmptyAnswer() {
        let answer = SupervisorInquiryAnswer().settingFreeText("", for: "scheme")
        XCTAssertTrue(answer.isEmpty)
        XCTAssertTrue(
            AnswerDraft(inquiry: SupervisorInquiryDraft(inquiry: form, answer: answer)).isEmpty,
            "and therefore nothing the draft store should keep")
    }

    func testClosingTheOtherFieldRemovesTheEntryWhenNothingElseIsThere() {
        let answer = SupervisorInquiryAnswer()
            .settingFreeText("half a thought", for: "notes")
            .settingFreeText(nil, for: "notes")
        XCTAssertTrue(answer.byQuestionID.isEmpty)
    }

    func testClosingTheOtherFieldKeepsTheSelectionBesideIt() {
        let answer = SupervisorInquiryAnswer()
            .settingSelection(["debug"], for: scheme)
            .settingFreeText("but only sometimes", for: "scheme")
            .settingFreeText(nil, for: "scheme")
        XCTAssertEqual(answer.byQuestionID["scheme"]?.selectedOptionIDs, ["debug"])
        XCTAssertNil(answer.byQuestionID["scheme"]?.freeText)
    }

    // MARK: - Scoping

    private var form: SupervisorInquiry {
        SupervisorInquiry(headline: "H", questions: [scheme, notes])
    }

    /// One composer's fields are aimed at whichever chip is selected, and the Supervisor
    /// retargets them freely — so an answer written against one role's questionnaire can be in
    /// hand when another role's is submitted. It renders as nothing either way; the question is
    /// whether it is WRITTEN onto the second step.
    ///
    /// RED: return `self` from `scoped(to:)` → the second step is persisted holding answers to
    /// questions it never asked, under ids nothing there can resolve.
    func testScopingDropsAnswersToQuestionsThisFormNeverAsked() {
        let stray = SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["debug"]),
            "someone-elses": .init(freeText: "for another role"),
        ])
        let scoped = stray.scoped(to: form)
        XCTAssertEqual(Set(scoped.byQuestionID.keys), ["scheme"])
    }

    func testScopingKeepsEverythingWhenEveryIdBelongs() {
        let mine = SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["debug"]),
            "notes": .init(freeText: "go on"),
        ])
        XCTAssertEqual(mine.scoped(to: form), mine)
    }

    func testScopingAnEmptyAnswerIsEmpty() {
        XCTAssertTrue(SupervisorInquiryAnswer().scoped(to: form).byQuestionID.isEmpty)
    }

    // MARK: - Which questionnaire these answers belong to

    private var sameIdsDifferentForm: SupervisorInquiry {
        SupervisorInquiry(
            headline: "H",
            questions: [
                SupervisorInquiryQuestion(
                    id: "scheme", prompt: "Which scheme, really?", kind: .singleChoice,
                    options: [option("debug", "Debug"), option("profile", "Profile")]),
                SupervisorInquiryQuestion(id: "notes", prompt: "Anything else?", kind: .freeText),
            ])
    }

    func testIdentityIsStableForTheSameQuestionnaire() {
        XCTAssertEqual(form.identity, form.identity)
    }

    /// Question ids are unique only WITHIN one questionnaire — the decoder enforces it per form
    /// and never across — and a local model asked the same stock question twice emits the same
    /// slug both times.
    ///
    /// RED: fold only the question ids → two different forms share an identity, and one form's
    /// ticks render as the other's answers.
    func testTwoFormsWithTheSameQuestionIdsAreStillDifferentQuestionnaires() {
        XCTAssertNotEqual(form.identity, sameIdsDifferentForm.identity)
    }

    /// The sharpest pair: same ids, same option ids, same option labels — only the WORDS of the
    /// question differ. A person answering "which scheme?" has not answered "which scheme, and
    /// why?", and a fold that skipped the prompt would carry their tick across as if they had.
    ///
    /// RED: drop `question.prompt` from the fold → the two forms are one, the panel does not
    /// rebuild, and the card shows the previous form's decisions under the new question.
    func testTwoFormsDifferingOnlyInTheirWordingAreStillDifferent() {
        let reworded = SupervisorInquiry(
            headline: form.headline,
            questions: form.questions.map {
                SupervisorInquiryQuestion(
                    id: $0.id, prompt: $0.prompt + ", and why?", detail: $0.detail,
                    kind: $0.kind, options: $0.options)
            })
        XCTAssertNotEqual(form.identity, reworded.identity)
    }

    func testDraftHandsBackItsAnswersForTheFormTheyWereGivenTo() {
        let draft = SupervisorInquiryDraft(
            inquiry: form, answer: SupervisorInquiryAnswer().settingSelection(["debug"], for: scheme))
        XCTAssertEqual(draft.answer(for: form)?.selection(for: "scheme"), ["debug"])
    }

    /// The composer's fields follow whichever chip is selected and the panel's follow the
    /// conversation branch — right for a sentence, wrong for a set of ticks.
    ///
    /// RED: return `answer` regardless of identity → the decisions given to one role's form are
    /// read as the answers to another's, and submitted as such.
    func testDraftHandsBackNothingForAnotherQuestionnaire() {
        let draft = SupervisorInquiryDraft(
            inquiry: form, answer: SupervisorInquiryAnswer().settingSelection(["debug"], for: scheme))
        XCTAssertNil(draft.answer(for: sameIdsDifferentForm))
    }

    /// A role that re-asks PLAINLY leaves no questionnaire at all, and ticks in hand answer
    /// nothing then.
    func testDraftHandsBackNothingWhenThereIsNoQuestionnaire() {
        let draft = SupervisorInquiryDraft(
            inquiry: form, answer: SupervisorInquiryAnswer().settingSelection(["debug"], for: scheme))
        XCTAssertNil(draft.answer(for: nil))
    }

    // MARK: - The note

    /// The prose beside the form is part of the ANSWER, not only of the wire text — otherwise
    /// the feed re-rendering the record silently drops the one half a person wrote by hand.
    ///
    /// RED: return `answer` instead of the note-carrying copy from `compose` → the sentence the
    /// Supervisor typed beside the questions exists only inside the rendered prose.
    func testComposeKeepsTheSupervisorsProseOnTheRecord() {
        let composed = SupervisorInquiryReply.compose(
            inquiry: form,
            reply: "Keep the diff tight.\n\n## Attached File: notes.md\n(body)",
            submission: SupervisorInquirySubmission(
                answer: SupervisorInquiryAnswer().settingSelection(["debug"], for: scheme),
                note: "Keep the diff tight."))
        XCTAssertEqual(composed.answer?.note, "Keep the diff tight.",
                       "the RECORD keeps the words they typed")
        XCTAssertFalse(composed.answer?.note?.contains("## Attached File") ?? true,
                       "a file section is not something the Supervisor said")
        XCTAssertTrue(composed.text.contains("## Attached File: notes.md"),
                      "and the MODEL still receives the whole assembled reply — dropping the "
                          + "sections here would deliver nothing for a file they attached")
        XCTAssertTrue(composed.text.contains("Keep the diff tight."),
                      "read once, above the pairs")
    }

    func testAnEmptyReplyLeavesNoNote() {
        let composed = SupervisorInquiryReply.compose(
            inquiry: form, reply: "   ",
            submission: SupervisorInquirySubmission(
                answer: SupervisorInquiryAnswer().settingSelection(["debug"], for: scheme),
                note: "   "))
        XCTAssertNil(composed.answer?.note)
    }

    /// A note is not an answer: it must not make an untouched form look filled in, or every
    /// automated reply would leave a parked draft behind.
    func testANoteDoesNotMakeTheAnswerNonEmpty() {
        var answer = SupervisorInquiryAnswer()
        answer.note = "something I said"
        XCTAssertTrue(answer.isEmpty)
    }

    // MARK: - What the card builds from the questions

    /// A question the model said nothing about badges nothing — and that is most questions.
    ///
    /// RED: badge `options[0]` when no recommendation was read → the card tells the Supervisor
    /// the asking role recommends an option it never named, which is what every choice
    /// question showed until 2026-09-12.
    func testAQuestionThatRecommendsNothingWearsNoBadge() {
        let rows = SupervisorInquiryCard.choiceOptions(for: suites)
        XCTAssertEqual(rows.map(\.id), ["unit", "ui", "perf"])
        XCTAssertTrue(rows.allSatisfy { $0.badge == nil })
    }

    /// And when it DID name one, exactly that one wears the badge — wherever it sits.
    func testTheRecommendedOptionWearsTheBadgeWhereverItSits() {
        let marked = SupervisorInquiryQuestion(
            id: suites.id, prompt: suites.prompt, kind: suites.kind,
            options: suites.options, recommendedOptionID: "perf")
        let rows = SupervisorInquiryCard.choiceOptions(for: marked)
        XCTAssertEqual(rows.map(\.id), ["unit", "ui", "perf"], "the order is the model's")
        XCTAssertEqual(rows.last?.badge, "recommended")
        XCTAssertTrue(rows.dropLast().allSatisfy { $0.badge == nil })
    }

    func testAQuestionWithNoOptionsBuildsNoRows() {
        XCTAssertTrue(SupervisorInquiryCard.choiceOptions(for: notes).isEmpty)
    }

    func testEveryKindHasItsOwnLabel() {
        let labels = SupervisorInquiryKind.allCases.map(SupervisorInquiryCard.kindLabel)
        XCTAssertEqual(Set(labels).count, SupervisorInquiryKind.allCases.count)
        XCTAssertEqual(SupervisorInquiryCard.kindLabel(.multiChoice), "pick any")
    }
}
