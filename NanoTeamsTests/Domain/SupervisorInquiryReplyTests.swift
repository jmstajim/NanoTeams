import XCTest
@testable import NanoTeams

/// The text contract between a questionnaire and a textual reply — the half of the form
/// feature that every AUTOMATED answerer depends on.
///
/// It carries more weight than its size suggests: `HeadlessRunner` cannot answer a parked
/// step (it prints progress and keeps polling), so a questionnaire is only reachable
/// end-to-end without a human through these three seams, and all three are prose in, prose
/// out. If the ask does not render or the reply does not parse, the failure is silent — every
/// choice defaults to its recommendation and the asking role is told the Supervisor had no
/// opinion, which is exactly what an unanswered form looks like.
final class SupervisorInquiryReplyTests: XCTestCase {

    // MARK: - Fixtures

    private func inquiry(
        _ questions: [SupervisorInquiryQuestion], headline: String = "Build settings"
    ) -> SupervisorInquiry {
        SupervisorInquiry(headline: headline, questions: questions)
    }

    private func choice(
        _ id: String, _ prompt: String, _ labels: [String], multi: Bool = false
    ) -> SupervisorInquiryQuestion {
        SupervisorInquiryQuestion(
            id: id, prompt: prompt, kind: multi ? .multiChoice : .singleChoice,
            options: labels.map { SupervisorInquiryOption(id: $0.lowercased(), label: $0) })
    }

    private func free(_ id: String, _ prompt: String) -> SupervisorInquiryQuestion {
        SupervisorInquiryQuestion(id: id, prompt: prompt, kind: .freeText)
    }

    private var scheme: SupervisorInquiryQuestion { choice("scheme", "Which scheme?", ["Debug", "Release"]) }
    private var targets: SupervisorInquiryQuestion {
        choice("targets", "Which targets?", ["Unit", "UI", "Perf"], multi: true)
    }
    private var notes: SupervisorInquiryQuestion { free("notes", "Anything else?") }

    // MARK: - The ask

    func testQuestionnaireNumbersQuestionsAndOptions() {
        let text = SupervisorInquiryReply.questionnaire(for: inquiry([scheme, notes]))
        XCTAssertTrue(text.hasPrefix("Build settings"), text)
        XCTAssertTrue(text.contains("Q1. Which scheme?"), text)
        XCTAssertTrue(text.contains("  1. Debug"), text)
        XCTAssertTrue(text.contains("  2. Release"), text)
        XCTAssertTrue(text.contains("Q2. Anything else?"), text)
    }

    /// The tag names the option the asking role ACTUALLY recommended, and the card badges the
    /// same one — one source of truth, because `questionnaireTail` tells an automated answerer
    /// to take it when information is missing.
    ///
    /// RED: tag `optionIndex == 0` again → the wire and the card disagree on every form whose
    /// recommendation is not first, and the automated answerer is steered to the option the
    /// asking role argued against.
    func testTheTagFollowsTheRecommendationNotThePosition() {
        let marked = SupervisorInquiryQuestion(
            id: "scheme", prompt: "Which scheme?", kind: .singleChoice,
            options: scheme.options, recommendedOptionID: scheme.options[1].id)
        let text = SupervisorInquiryReply.questionnaire(for: inquiry([marked]))
        let tagged = text.split(separator: "\n").filter { $0.contains(SupervisorInquiryReply.recommendedTag) }
        XCTAssertEqual(tagged.count, 1, text)
        XCTAssertTrue(tagged[0].contains("Release"), text)
    }

    /// A questionnaire that recommends nothing tags nothing — the ordinary case.
    func testAQuestionnaireThatRecommendsNothingTagsNoRow() {
        let text = SupervisorInquiryReply.questionnaire(for: inquiry([scheme]))
        XCTAssertFalse(text.contains(SupervisorInquiryReply.recommendedTag), text)
    }

    func testQuestionnaireNamesEachKind() {
        let text = SupervisorInquiryReply.questionnaire(for: inquiry([scheme, targets, notes]))
        XCTAssertTrue(text.contains("(pick one)"), text)
        XCTAssertTrue(text.contains("(pick one or more)"), text)
        XCTAssertTrue(text.contains("(in your own words)"), text)
    }

    /// The reply contract rides inside the ask because three seams deliver it and none of
    /// them would otherwise carry one. An ask without it is a form the answerer replies to in
    /// prose — which parses as nothing.
    func testQuestionnaireCarriesTheReplyContract() {
        let text = SupervisorInquiryReply.questionnaire(for: inquiry([scheme]))
        XCTAssertTrue(text.contains("one line for every question"), text)
        XCTAssertTrue(
            text.contains("marked not answered"),
            "an answerer that thinks an omission is filled in will skip a question believing "
                + "it decided one: \(text)")
    }

    func testOptionDetailRidesWithItsOption() {
        let question = SupervisorInquiryQuestion(
            id: "scheme", prompt: "Which scheme?", detail: "CI builds Debug.", kind: .singleChoice,
            options: [
                SupervisorInquiryOption(id: "debug", label: "Debug", detail: "what CI uses"),
                SupervisorInquiryOption(id: "release", label: "Release"),
            ])
        let text = SupervisorInquiryReply.questionnaire(for: inquiry([question]))
        XCTAssertTrue(text.contains("what CI uses"), text)
        XCTAssertTrue(text.contains("CI builds Debug."), text)
    }

    // MARK: - The reply — numbered

    func testNumberedReplySelectsByPosition() {
        let form = inquiry([scheme, targets])
        let parsed = SupervisorInquiryReply.parse("Q1: 2\nQ2: 1, 3", inquiry: form)
        XCTAssertEqual(parsed.answer.byQuestionID["scheme"]?.selectedOptionIDs, ["release"])
        XCTAssertEqual(parsed.answer.byQuestionID["targets"]?.selectedOptionIDs, ["unit", "perf"])
        XCTAssertNil(parsed.note)
    }

    /// `2. …`, `- **Q2:** …` — what local models actually emit. A reply cannot be sent back
    /// for repair: by the time anything reads it the step it answers is already unblocked.
    func testSloppyLineShapesStillParse() {
        let form = inquiry([scheme, targets])
        for reply in ["Q1. 2", "1: 2", "1) 2", "- Q1: 2", "**Q1:** 2", "  * q1 : 2"] {
            let parsed = SupervisorInquiryReply.parse(reply, inquiry: form)
            XCTAssertEqual(
                parsed.answer.byQuestionID["scheme"]?.selectedOptionIDs, ["release"], reply)
        }
    }

    func testTrailingProseOnAChoiceLineRidesAsThatQuestionsFreeText() {
        let parsed = SupervisorInquiryReply.parse("Q1: 2 — CI is on Release now", inquiry: inquiry([scheme]))
        let answer = parsed.answer.byQuestionID["scheme"]
        XCTAssertEqual(answer?.selectedOptionIDs, ["release"])
        XCTAssertEqual(answer?.freeText, "CI is on Release now")
    }

    func testLabelNamedInsteadOfNumberedIsStillAChoice() {
        let parsed = SupervisorInquiryReply.parse("Q1: Release", inquiry: inquiry([scheme]))
        XCTAssertEqual(parsed.answer.byQuestionID["scheme"]?.selectedOptionIDs, ["release"])
        XCTAssertNil(parsed.answer.byQuestionID["scheme"]?.freeText)
    }

    /// A number inside the sentence is what the answerer is SAYING, not what it picked.
    /// Reading it as a selection would record a choice nobody made — so the line stays prose,
    /// which a choice question accepts (its card always offers an escape from the options).
    func testANumberLaterInTheSentenceIsNotASelection() {
        let parsed = SupervisorInquiryReply.parse(
            "Q1: build 2 of the 3 configurations", inquiry: inquiry([scheme]))
        let answer = parsed.answer.byQuestionID["scheme"]
        XCTAssertEqual(answer?.selectedOptionIDs, [])
        XCTAssertEqual(answer?.freeText, "build 2 of the 3 configurations",
                       "the Supervisor did answer — just not by picking")
    }

    /// An option number the form does not have selects nothing, and the line is reported as
    /// written. Substituting the recommendation would tell the asking role the Supervisor
    /// chose it, which is the one thing that did not happen.
    func testOutOfRangeOptionNumberSelectsNothingAndKeepsWhatWasSaid() {
        let parsed = SupervisorInquiryReply.parse("Q1: 9", inquiry: inquiry([scheme]))
        let answer = parsed.answer.byQuestionID["scheme"]
        XCTAssertEqual(answer?.selectedOptionIDs, [])
        XCTAssertEqual(answer?.freeText, "9")
    }

    /// A question number past the end of the form is not a question — the line is prose that
    /// happens to start with a digit ("2026: shipped"), and dropping it would edit the answer.
    func testOutOfRangeQuestionNumberStaysProse() {
        let parsed = SupervisorInquiryReply.parse("Q7: whatever", inquiry: inquiry([scheme]))
        XCTAssertEqual(parsed.note, "Q7: whatever")
    }

    /// Single-choice answered with several is a contradiction the asking role cannot act on.
    /// The first is the answerer's own ranking; the rest must not vanish.
    func testSingleChoiceKeepsTheFirstAndSaysTheRest() {
        let parsed = SupervisorInquiryReply.parse("Q1: 1, 2", inquiry: inquiry([scheme]))
        let answer = parsed.answer.byQuestionID["scheme"]
        XCTAssertEqual(answer?.selectedOptionIDs, ["debug"])
        XCTAssertEqual(answer?.freeText, "also: Release")
    }

    func testDuplicateNumbersSelectOnce() {
        let parsed = SupervisorInquiryReply.parse("Q1: 1, 1, 2", inquiry: inquiry([targets]))
        XCTAssertEqual(parsed.answer.byQuestionID["targets"]?.selectedOptionIDs, ["unit", "ui"])
    }

    func testAndBetweenNumbersIsASeparator() {
        let parsed = SupervisorInquiryReply.parse("Q1: 1 and 3", inquiry: inquiry([targets]))
        XCTAssertEqual(parsed.answer.byQuestionID["targets"]?.selectedOptionIDs, ["unit", "perf"])
    }

    /// A restated question is a changed mind, not two answers.
    func testARepeatedQuestionNumberTakesTheLastLine() {
        let parsed = SupervisorInquiryReply.parse("Q1: 1\nQ1: 2", inquiry: inquiry([scheme]))
        XCTAssertEqual(parsed.answer.byQuestionID["scheme"]?.selectedOptionIDs, ["release"])
    }

    // MARK: - The reply — prose

    func testFreeTextQuestionTakesItsLineWhole() {
        let parsed = SupervisorInquiryReply.parse("Q1: keep the diff tight", inquiry: inquiry([notes]))
        XCTAssertEqual(parsed.answer.byQuestionID["notes"]?.freeText, "keep the diff tight")
    }

    /// Prose naming no question rides ONCE, as a note. Spreading it into every free-text
    /// field would put the same paragraph in front of the role three times, each labelled as
    /// an answer to a different question — a claim the reply never made.
    func testUnattributedProseRidesAsANoteAndNotAsAnAnswer() {
        let form = inquiry([scheme, notes])
        let parsed = SupervisorInquiryReply.parse("Use whatever CI uses, and keep it tight.", inquiry: form)
        XCTAssertEqual(parsed.note, "Use whatever CI uses, and keep it tight.")
        XCTAssertNil(parsed.answer.byQuestionID["scheme"],
                     "prose that named no question decided none of them")
        XCTAssertNil(parsed.answer.byQuestionID["notes"])
    }

    func testProseAroundNumberedLinesIsKeptAsANote() {
        let parsed = SupervisorInquiryReply.parse(
            "Thinking it through.\nQ1: 2\nThat is my call.", inquiry: inquiry([scheme]))
        XCTAssertEqual(parsed.answer.byQuestionID["scheme"]?.selectedOptionIDs, ["release"])
        XCTAssertEqual(parsed.note, "Thinking it through.\nThat is my call.")
    }

    /// An answerer that said nothing decided nothing — of any kind. Until 2026-09-12 every
    /// CHOICE here came back as `options[0]`, so an LLM that failed to reply at all was
    /// reported to the asking role as a Supervisor who had endorsed every recommendation.
    func testAnEmptyReplyDecidesNothingAndCarriesNoNote() {
        let parsed = SupervisorInquiryReply.parse("", inquiry: inquiry([scheme, targets, notes]))
        XCTAssertTrue(parsed.answer.byQuestionID.isEmpty)
        XCTAssertNil(parsed.note)
    }

    /// The arm no prompt edit can reach: the auto-answerer's server was down, its generation
    /// was empty, or the step index was bad, so `fallbackAnswer` is returned with no model
    /// having run. It names no `Q<n>:`, so it decides nothing and rides as the note — and the
    /// asking role reads the absences plus the sentence, instead of a full set of decisions
    /// attributed to a Supervisor that never answered.
    func testTheAutoAnswerFallbackDecidesNothingAndRidesAsTheNote() {
        let form = inquiry([scheme, targets])
        let composed = SupervisorInquiryReply.compose(
            inquiry: form, reply: SupervisorAutoAnswerService.fallbackAnswer)
        XCTAssertEqual(composed.answer?.byQuestionID, [:])
        XCTAssertEqual(composed.answer?.note, SupervisorAutoAnswerService.fallbackAnswer)
        XCTAssertTrue(
            composed.text.contains(SupervisorInquiryRenderer.unansweredDirection), composed.text)
    }

    func testAnEmptyAnswerLineIsNotAnAnswer() {
        let parsed = SupervisorInquiryReply.parse("Q1:", inquiry: inquiry([notes]))
        XCTAssertNil(parsed.answer.byQuestionID["notes"])
    }

    // MARK: - compose

    /// The plain `ask_supervisor` path is the common one — chat-mode teams take it on every
    /// turn — and must be byte-for-byte what it was.
    func testComposeWithoutAnInquiryReturnsTheReplyUnchanged() {
        let composed = SupervisorInquiryReply.compose(inquiry: nil, reply: "  Ship it.  ")
        XCTAssertEqual(composed.text, "Ship it.")
        XCTAssertNil(composed.answer)
    }

    func testComposeRendersNumberedPairsAndMarksAbsences() {
        let form = inquiry([scheme, notes])
        let composed = SupervisorInquiryReply.compose(inquiry: form, reply: "Q2: keep it tight")
        XCTAssertTrue(composed.text.contains("Q1. Which scheme?"), composed.text)
        XCTAssertTrue(
            composed.text.contains("A1. \(SupervisorInquiryRenderer.unansweredMarker)"),
            composed.text)
        XCTAssertTrue(composed.text.contains("A2. keep it tight"), composed.text)
        XCTAssertNil(composed.answer?.byQuestionID["scheme"])
    }

    /// The note LEADS: it is addressed to the whole questionnaire, and the pairs below it
    /// stay a block the role can count through.
    func testComposePutsTheNoteAboveThePairs() {
        let composed = SupervisorInquiryReply.compose(
            inquiry: inquiry([scheme]), reply: "Whatever CI uses.")
        XCTAssertTrue(composed.text.hasPrefix("Whatever CI uses.\n\nQ1."), composed.text)
    }

    /// A person who decides nothing and answers in prose has still answered as a PERSON. The
    /// branch is chosen by origin — a submission is present — not by whether the card holds
    /// anything, because a card left alone yields an empty answer and an empty one is legal.
    ///
    /// RED: choose the branch on `submission.answer.isEmpty` (or drop the submission and pass a
    /// bare structure again) → their sentence runs through `parse`, whose grammar reads a
    /// leading `1.` as a selection of option 1 — the recommendation they were arguing against.
    func testAHumansProseIsNeverReadWithTheModelsReplyGrammar() {
        let form = inquiry([scheme, targets])
        let composed = SupervisorInquiryReply.compose(
            inquiry: form,
            reply: "1. I'd rather you used Release, actually.",
            submission: SupervisorInquirySubmission(
                answer: SupervisorInquiryAnswer(),
                note: "1. I'd rather you used Release, actually."))

        XCTAssertNil(composed.answer?.byQuestionID["scheme"],
                     "they ticked nothing, so nothing was decided — and `debug` in particular "
                         + "is the recommendation they were arguing against")
        XCTAssertEqual(composed.answer?.note, "1. I'd rather you used Release, actually.",
                       "and their sentence reaches the role verbatim, as a note")
    }

    /// The same words from an AUTOMATED answerer are still parsed — that is the only way in for
    /// a model, and the reason the two origins must be told apart rather than guessed at.
    func testAnAutomatedReplyIsStillParsedAgainstTheQuestionnaire() {
        let form = inquiry([scheme, targets])
        let composed = SupervisorInquiryReply.compose(inquiry: form, reply: "Q1: 2")
        XCTAssertEqual(composed.answer?.byQuestionID["scheme"]?.selectedOptionIDs, ["release"])
    }

    /// A number with no separator after it is PROSE, not an answer line. "2 of the three
    /// options look wrong" opens with a digit and answers nothing; reading it as question 2's
    /// answer would record a decision the Supervisor never made.
    ///
    /// RED: accept a line whose digits are followed by anything (drop the separator guard) →
    /// the sentence lands on question 2 as its answer, and the role is told a decision was
    /// made where a sentence was written.
    func testANumberWithoutASeparatorIsProseAndDecidesNothing() {
        let form = inquiry([scheme, targets])

        let composed = SupervisorInquiryReply.compose(
            inquiry: form, reply: "2 of these options look wrong to me")

        XCTAssertNil(composed.answer?.byQuestionID["targets"],
                     "no line addressed question 2, so it has no answer")
        XCTAssertEqual(composed.answer?.note, "2 of these options look wrong to me")
    }

    /// The human card's path, and the shape the user reported: one question ticked, one left
    /// alone, prose beside the card. The tick is kept, the untouched question is reported as
    /// unanswered, and the typed words ride as the note.
    ///
    /// RED: fill the untouched question from `options[0]` → the asking role reads a decision
    /// on the one question the Supervisor passed over.
    func testComposeKeepsWhatWasTickedAndReportsTheRestUnanswered() {
        let form = inquiry([scheme, targets])
        let structured = SupervisorInquiryAnswer(byQuestionID: [
            "scheme": .init(selectedOptionIDs: ["release"]),
        ])
        let composed = SupervisorInquiryReply.compose(
            inquiry: form, reply: "Bumping the version too.",
            submission: SupervisorInquirySubmission(
                answer: structured, note: "Bumping the version too."))
        XCTAssertEqual(composed.answer?.byQuestionID["scheme"]?.selectedOptionIDs, ["release"])
        XCTAssertNil(composed.answer?.byQuestionID["targets"])
        XCTAssertTrue(composed.text.hasPrefix("Bumping the version too."), composed.text)
        XCTAssertTrue(
            composed.text.contains("A2. \(SupervisorInquiryRenderer.unansweredMarker)"),
            composed.text)
        XCTAssertTrue(
            composed.text.hasSuffix(SupervisorInquiryRenderer.unansweredDirection), composed.text)
    }

    /// An empty submit is a legal submit — the whole reason a partial answer is allowed. It
    /// must still deliver something, or the asking role waits forever for an answer that was
    /// given.
    func testComposeOfAnEmptyReplyStillProducesAnAnswerBody() {
        let composed = SupervisorInquiryReply.compose(inquiry: inquiry([scheme]), reply: "")
        XCTAssertFalse(composed.text.isEmpty)
        XCTAssertTrue(
            composed.text.contains(SupervisorInquiryRenderer.unansweredMarker), composed.text)
        XCTAssertTrue(
            composed.text.contains(SupervisorInquiryRenderer.unansweredDirection), composed.text)
    }

    /// Round trip: what the answerer is shown is what the parser reads back. A drift between
    /// the two halves is invisible — the reply simply stops landing and every question comes
    /// back unanswered.
    func testTheAskAndTheParserAgreeOnNumbering() {
        let form = inquiry([scheme, targets, notes])
        let asked = SupervisorInquiryReply.questionnaire(for: form)
        XCTAssertTrue(asked.contains("Q2. Which targets?"), asked)
        XCTAssertTrue(asked.contains("  3. Perf"), asked)
        let parsed = SupervisorInquiryReply.parse("Q2: 3", inquiry: form)
        XCTAssertEqual(parsed.answer.byQuestionID["targets"]?.selectedOptionIDs, ["perf"])
    }
}
