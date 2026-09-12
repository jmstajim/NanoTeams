import XCTest

@testable import NanoTeams

/// The `ask_supervisor_form` payload decoder.
///
/// The model writes this by hand into a `String` parameter — `JSONSchema` cannot express an
/// array of objects (CLAUDE.md #46) — so this decoder is the only thing between a sloppy
/// generation and a card the human cannot answer. The tests are split the way the contract
/// is: what is TOLERATED per element, what is SYNTHESIZED, and what is REFUSED loudly.
final class SupervisorInquiryDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> SupervisorInquiry {
        try JSONCoderFactory.makeWireDecoder()
            .decode(SupervisorInquiry.self, from: Data(json.utf8))
    }

    private func message(_ json: String) -> String {
        do {
            _ = try decode(json)
            return ""
        } catch {
            return "\(error)"
        }
    }

    /// Decodes ONE question, so a per-question rule can be asserted by ITS OWN message.
    ///
    /// Going through the whole inquiry instead would have every per-question rule report the
    /// same "Every question was malformed" — true, but it cannot tell the rule that fired
    /// from any of its siblings, so a mutation to one guard would be caught by five tests
    /// and located by none.
    private func questionMessage(_ json: String) -> String {
        do {
            _ = try JSONCoderFactory.makeWireDecoder()
                .decode(SupervisorInquiryQuestion.self, from: Data(json.utf8))
            return ""
        } catch {
            return "\(error)"
        }
    }

    // MARK: - Happy path

    func testDecodesAThreeQuestionForm() throws {
        let inquiry = try decode("""
        {"headline":"Three questions about M20","questions":[
          {"id":"state","prompt":"Treat M20 as implemented?","kind":"single_choice",
           "options":[{"id":"yes","label":"Yes — verify the build"},
                      {"id":"no","label":"No — implement fresh"}]},
          {"id":"access","prompt":"Which access level for Tab?","kind":"single_choice",
           "options":[{"id":"internal","label":"internal","detail":"TabRouter can see it"}]},
          {"id":"notes","prompt":"Anything else?","kind":"free_text"}
        ]}
        """)
        XCTAssertEqual(inquiry.headline, "Three questions about M20")
        XCTAssertEqual(inquiry.questions.map(\.id), ["state", "access", "notes"])
        XCTAssertEqual(inquiry.questions[0].options.count, 2)
        XCTAssertEqual(inquiry.questions[1].options.first?.detail, "TabRouter can see it")
        XCTAssertEqual(inquiry.questions[2].kind, .freeText)
        XCTAssertTrue(inquiry.questions[2].options.isEmpty)
    }

    /// Order is presentation, not a claim. A form the model wrote without saying what it
    /// recommends recommends nothing — and that is most forms.
    ///
    /// RED: resolve `recommendedOption` to `options.first` when no id was read → every choice
    /// question badges its first option, including the six of nine in the archive where the
    /// model recommended nothing at all.
    func testAQuestionThatRecommendsNothingHasNoRecommendation() throws {
        let inquiry = try decode("""
        {"headline":"H","questions":[{"prompt":"P","kind":"single_choice",
         "options":[{"label":"Preferred"},{"label":"Other"}]}]}
        """)
        XCTAssertNil(inquiry.questions[0].recommendedOption)
    }

    /// The persisted questionnaire round-trips through this decoder, so the resolution the
    /// tool seam made has to survive it — and an id naming no option of THIS question
    /// resolves to nothing rather than to a neighbour.
    func testARecommendedOptionIDIsReadAndValidatedAgainstTheOptions() throws {
        let inquiry = try decode("""
        {"headline":"H","questions":[{"prompt":"P","kind":"single_choice",
         "recommendedOptionID":"other",
         "options":[{"id":"preferred","label":"Preferred"},{"id":"other","label":"Other"}]}]}
        """)
        XCTAssertEqual(inquiry.questions[0].recommendedOption?.label, "Other")

        let orphan = try decode("""
        {"headline":"H","questions":[{"prompt":"P","kind":"single_choice",
         "recommendedOptionID":"gone",
         "options":[{"id":"preferred","label":"Preferred"},{"id":"other","label":"Other"}]}]}
        """)
        XCTAssertNil(orphan.questions[0].recommendedOption)
    }

    func testFreeTextHasNoRecommendation() throws {
        let inquiry = try decode(#"{"headline":"H","questions":[{"prompt":"P","kind":"free_text"}]}"#)
        XCTAssertNil(inquiry.questions[0].recommendedOption)
    }

    // MARK: - Loose spellings

    func testKindAcceptsCamelHyphenAndUppercase() throws {
        for spelling in ["singleChoice", "single-choice", "SINGLE_CHOICE", " single_choice "] {
            let inquiry = try decode("""
            {"headline":"H","questions":[{"prompt":"P","kind":"\(spelling)",
             "options":[{"label":"A"}]}]}
            """)
            XCTAssertEqual(inquiry.questions[0].kind, .singleChoice, "spelling: \(spelling)")
        }
    }

    // MARK: - Synthesized ids

    func testMissingIdsAreSynthesizedFromText() throws {
        let inquiry = try decode("""
        {"headline":"H","questions":[{"prompt":"Which scheme should I use?","kind":"single_choice",
         "options":[{"label":"NanoTeams (Debug)"}]}]}
        """)
        XCTAssertEqual(inquiry.questions[0].id, "which_scheme_should_i_use")
        XCTAssertEqual(inquiry.questions[0].options[0].id, "nanoteams_debug")
    }

    /// Deterministic, because a half-filled answer is keyed by id: a second decode of the
    /// same payload must match the answers already recorded against the first.
    func testSynthesizedIdsAreStableAcrossDecodes() throws {
        let json = #"{"headline":"H","questions":[{"prompt":"Ship it?","kind":"free_text"}]}"#
        XCTAssertEqual(try decode(json).questions[0].id, try decode(json).questions[0].id)
    }

    func testPunctuationOnlyPromptStillGetsAnId() throws {
        let inquiry = try decode(#"{"headline":"H","questions":[{"prompt":"?!","kind":"free_text"}]}"#)
        XCTAssertFalse(inquiry.questions[0].id.isEmpty)
    }

    func testSynthesizedIdIsCapped() {
        let long = String(repeating: "word ", count: 60)
        XCTAssertLessThanOrEqual(
            SupervisorInquiryIdentity.synthesize(from: long).count,
            SupervisorInquiryIdentity.maxSynthesizedLength)
    }

    func testSynthesizedIdHasNoTrailingSeparator() {
        XCTAssertEqual(SupervisorInquiryIdentity.synthesize(from: "Ship it?"), "ship_it")
    }

    // MARK: - Tolerated per element

    /// Nine good questions and one broken one are worth nine questions.
    ///
    /// RED: drop `Failable` from the questions array → the whole payload is rejected and the
    /// model is told nothing about which entry was wrong.
    func testOneMalformedQuestionIsDroppedNotTheWholeForm() throws {
        let inquiry = try decode("""
        {"headline":"H","questions":[
          {"prompt":"Good one","kind":"free_text"},
          {"kind":"free_text"},
          {"prompt":"Also good","kind":"free_text"}
        ]}
        """)
        XCTAssertEqual(inquiry.questions.map(\.prompt), ["Good one", "Also good"])
    }

    func testOneMalformedOptionIsDroppedNotTheQuestion() throws {
        let inquiry = try decode("""
        {"headline":"H","questions":[{"prompt":"P","kind":"single_choice",
         "options":[{"label":"Keep"},{"label":"   "},{"label":"Also keep"}]}]}
        """)
        XCTAssertEqual(inquiry.questions[0].options.map(\.label), ["Keep", "Also keep"])
    }

    // MARK: - Refused loudly

    func testEmptyHeadlineIsRefused() {
        XCTAssertTrue(message(#"{"headline":"  ","questions":[{"prompt":"P","kind":"free_text"}]}"#)
            .contains("headline"))
    }

    func testNoQuestionsIsRefused() {
        XCTAssertTrue(message(#"{"headline":"H","questions":[]}"#).contains("at least one question"))
    }

    /// Distinct from "no questions": the model DID author some and every one was wrong, so
    /// the message names the required shape rather than the empty array.
    func testEveryQuestionMalformedIsRefusedWithItsOwnMessage() {
        let text = message(#"{"headline":"H","questions":[{"kind":"free_text"},{"prompt":""}]}"#)
        XCTAssertTrue(text.contains("Every question was malformed"), text)
    }

    func testChoiceWithoutOptionsIsRefused() {
        let text = questionMessage(#"{"prompt":"P","kind":"single_choice"}"#)
        XCTAssertTrue(text.contains("at least one option"), text)
        XCTAssertTrue(text.contains("free_text"), "the message must name the way out: \(text)")
    }

    /// A contradiction the model can see and fix: keeping the options would show a choice the
    /// kind denies, dropping them would delete work it did.
    func testFreeTextCarryingOptionsIsRefused() {
        let text = questionMessage(#"{"prompt":"P","kind":"free_text","options":[{"label":"A"}]}"#)
        XCTAssertTrue(text.contains("free_text` carries"), text)
    }

    func testUnknownKindIsRefused() {
        let text = questionMessage(#"{"prompt":"P","kind":"dropdown"}"#)
        XCTAssertTrue(text.contains("Unknown kind `dropdown`"), text)
        for kind in SupervisorInquiryKind.allCases {
            XCTAssertTrue(text.contains(kind.rawValue), "the message must list \(kind.rawValue)")
        }
    }

    func testMissingPromptIsRefused() {
        XCTAssertTrue(questionMessage(#"{"kind":"free_text"}"#).contains("needs a `prompt`"))
    }

    func testOverlongPromptIsRefused() {
        let prompt = String(repeating: "x", count: SupervisorInquiryLimits.maxPromptCharacters + 1)
        XCTAssertTrue(questionMessage(#"{"prompt":"\#(prompt)","kind":"free_text"}"#)
            .contains("the limit is"))
    }

    /// Answers are keyed by question id, so a duplicate would merge two questions' answers
    /// into one — a decision recorded against a question nobody answered.
    func testDuplicateQuestionIdsAreRefused() {
        let text = message("""
        {"headline":"H","questions":[{"id":"a","prompt":"One","kind":"free_text"},
                                     {"id":"a","prompt":"Two","kind":"free_text"}]}
        """)
        XCTAssertTrue(text.contains("Duplicate question id"), text)
    }

    /// Two questions with identical prompts synthesize identical ids — the duplicate check
    /// must catch that too, not only explicit collisions.
    func testIdenticalPromptsCollideAndAreRefused() {
        let text = message("""
        {"headline":"H","questions":[{"prompt":"Same","kind":"free_text"},
                                     {"prompt":"Same","kind":"free_text"}]}
        """)
        XCTAssertTrue(text.contains("Duplicate question id"), text)
    }

    func testDuplicateOptionIdsAreRefused() {
        let text = questionMessage("""
        {"prompt":"P","kind":"single_choice",
         "options":[{"id":"x","label":"One"},{"id":"x","label":"Two"}]}
        """)
        XCTAssertTrue(text.contains("Duplicate option id `x`"), text)
    }

    func testOverlongOptionLabelIsRefused() {
        let label = String(repeating: "x", count: SupervisorInquiryLimits.maxOptionLabelCharacters + 1)
        let text = questionMessage(#"{"prompt":"P","kind":"single_choice","options":[{"label":"\#(label)"}]}"#)
        // The option is dropped per-element, so the question then fails for having none —
        // which is the right granularity: one bad option must not sink a good question.
        XCTAssertTrue(text.contains("at least one option"), text)
    }

    // MARK: - Caps refuse, never truncate

    /// The COUNT is the one dimension with no cap, and this is the pin that says so.
    ///
    /// A cap of 8 stood here until 2026-09-13. Handed a ten-question redesign form it answered
    /// «10 questions; the limit is 8», and the model resent EIGHT — dropping «с чем работать в
    /// первую очередь» and «ограничения / must-not-break», keeping the six about taste
    /// (MeditationApp task 87 run 1, 2026-09-12). 10 is that field case; 40 is here so the pin
    /// reads "no cap" rather than "a bigger number".
    ///
    /// RED: put any ceiling back in the set-level validator → the ten-question form is refused
    /// again and the role spends an emission learning to ask less.
    func testAnyNumberOfQuestionsIsAccepted() throws {
        for count in [10, 40] {
            let questions = (0..<count)
                .map { #"{"prompt":"Q\#($0)","kind":"free_text"}"# }
                .joined(separator: ",")
            let inquiry = try decode(#"{"headline":"H","questions":[\#(questions)]}"#)
            XCTAssertEqual(inquiry.questions.count, count)
        }
    }

    func testTooManyOptionsIsRefused() {
        let options = (0..<(SupervisorInquiryLimits.maxOptionsPerQuestion + 1))
            .map { #"{"label":"O\#($0)"}"# }
            .joined(separator: ",")
        let text = questionMessage(#"{"prompt":"P","kind":"single_choice","options":[\#(options)]}"#)
        XCTAssertTrue(text.contains("the limit is"), text)
    }

    /// The field that the LABEL cap's own message sends the model to — "Put the reasoning in
    /// `detail`" — and that nothing checked until 2026-09-13. It reaches the wire:
    /// `SupervisorInquiryReply.questionnaire(for:)` renders every detail, and that text is what
    /// an automated answerer and a delegated parent read.
    ///
    /// RED: drop either guard → a single option can carry a document, and with no cap on the
    /// number of questions either, nothing bounds the questionnaire at all.
    func testOverlongDetailIsRefused_onAQuestionAndOnAnOption() {
        let long = String(repeating: "x", count: SupervisorInquiryLimits.maxDetailCharacters + 1)
        let onQuestion = questionMessage(#"{"prompt":"P","kind":"free_text","detail":"\#(long)"}"#)
        XCTAssertTrue(onQuestion.contains("the limit is"), onQuestion)

        // An option is dropped per element, so the question then fails for having none — the
        // same granularity an overlong label gets, and for the same reason.
        let onOption = questionMessage(
            #"{"prompt":"P","kind":"single_choice","options":[{"label":"L","detail":"\#(long)"}]}"#)
        XCTAssertTrue(onOption.contains("at least one option"), onOption)
    }

    /// The cap is more than twice the longest detail in 200 archived field questionnaires
    /// (206 on an option, 224 on a question), so it must not reach a real one.
    func testADetailExactlyAtTheCapIsAccepted() throws {
        let atCap = String(repeating: "x", count: SupervisorInquiryLimits.maxDetailCharacters)
        let inquiry = try decode(
            #"{"headline":"H","questions":[{"prompt":"P","kind":"single_choice","detail":"\#(atCap)","options":[{"label":"L","detail":"\#(atCap)"},{"label":"M"}]}]}"#)
        XCTAssertEqual(inquiry.questions[0].detail?.count, SupervisorInquiryLimits.maxDetailCharacters)
        XCTAssertEqual(inquiry.questions[0].options[0].detail?.count, SupervisorInquiryLimits.maxDetailCharacters)
    }

    func testOverlongHeadlineIsRefused() {
        let headline = String(repeating: "x", count: SupervisorInquiryLimits.maxHeadlineCharacters + 1)
        XCTAssertTrue(message(#"{"headline":"\#(headline)","questions":[{"prompt":"P","kind":"free_text"}]}"#)
            .contains("the limit is"))
    }

    func testExactlyAtTheOptionCapIsAccepted() throws {
        let options = (0..<SupervisorInquiryLimits.maxOptionsPerQuestion)
            .map { #"{"label":"O\#($0)"}"# }
            .joined(separator: ",")
        let inquiry = try decode(
            #"{"headline":"H","questions":[{"prompt":"P","kind":"single_choice","options":[\#(options)]}]}"#)
        XCTAssertEqual(inquiry.questions[0].options.count,
                       SupervisorInquiryLimits.maxOptionsPerQuestion)
    }

    // MARK: - Round trip

    func testEncodeDecodeRoundTrips() throws {
        let original = try decode("""
        {"headline":"H","questions":[{"id":"a","prompt":"P","detail":"D","kind":"multi_choice",
         "options":[{"id":"x","label":"X","detail":"why"},{"id":"y","label":"Y"}]}]}
        """)
        let data = try JSONCoderFactory.makePersistenceEncoder().encode(original)
        let back = try JSONCoderFactory.makeWireDecoder().decode(SupervisorInquiry.self, from: data)
        XCTAssertEqual(back, original)
    }
}
