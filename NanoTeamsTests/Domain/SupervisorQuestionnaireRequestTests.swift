import XCTest

@testable import NanoTeams

/// The directive the `[ Ask as form ]` button sends, and the policy that decides when the
/// button exists at all.
///
/// The text is model-facing and rides a tool result, so it is pinned the way every other
/// engine-authored text is: by the registry census and the runtime fingerprint. These tests
/// pin what the census cannot — that the sentence still asks for what the button promises.
final class SupervisorQuestionnaireRequestTests: XCTestCase {

    // MARK: - Availability

    func testIsAvailable_forAPlainQuestionTheRoleAsked() {
        XCTAssertTrue(
            SupervisorQuestionnaireRequest.isAvailable(inquiry: nil, askCallID: UUID()))
    }

    /// A step already parked on a questionnaire has nothing to expand — the card with the
    /// options is already on screen, and the button beside it would ask for what it shows.
    func testIsAvailable_isFalse_whenTheStepAlreadyParkedOnAForm() {
        XCTAssertFalse(
            SupervisorQuestionnaireRequest.isAvailable(
                inquiry: Self.sampleInquiry(), askCallID: UUID()))
    }

    /// A park the ROLE did not raise — a loop or drift cap, the Autovisor's idle park — has no
    /// ask call, and `PendingQuestion.askCallID` is nil on exactly that branch.
    ///
    /// RED: drop the `askCallID` half → the directive goes out on an app-raised park, where
    /// its first sentence ("The question was not answered") is a statement about a question
    /// the role never asked.
    func testIsAvailable_isFalse_whenNoAskCallRaisedThePark() {
        XCTAssertFalse(
            SupervisorQuestionnaireRequest.isAvailable(inquiry: nil, askCallID: nil))
    }

    /// The fourth corner: neither condition holds.
    func testIsAvailable_isFalse_forAFormOnAParkWithNoAskCall() {
        XCTAssertFalse(
            SupervisorQuestionnaireRequest.isAvailable(
                inquiry: Self.sampleInquiry(), askCallID: nil))
    }

    // MARK: - compose

    func testCompose_withoutANote_isTheDirectiveAlone() {
        XCTAssertEqual(
            SupervisorQuestionnaireRequest.compose(note: nil),
            SupervisorQuestionnaireRequest.directive)
    }

    /// The Supervisor's own words ride BELOW the directive, separated by a blank line: they
    /// narrow what the form should cover ("give me three design directions"), and leading with
    /// them would read as the answer the directive says was not given.
    func testCompose_withANote_putsItAfterTheDirective() {
        let composed = SupervisorQuestionnaireRequest.compose(note: "дай три варианта дизайна")

        XCTAssertTrue(composed.hasPrefix(SupervisorQuestionnaireRequest.directive))
        XCTAssertTrue(composed.hasSuffix("\n\nдай три варианта дизайна"))
    }

    func testCompose_withABlankNote_addsNoTail() {
        XCTAssertEqual(
            SupervisorQuestionnaireRequest.compose(note: "   \n  "),
            SupervisorQuestionnaireRequest.directive)
    }

    // MARK: - What the directive asks for

    /// RED: point the directive at the plain ask → the role re-sends the same shape and the
    /// `QUESTIONNAIRE_REQUIRED` gate refuses it, costing a turn for a question already asked.
    func testDirective_namesTheFormAndNotThePlainAsk() {
        let directive = SupervisorQuestionnaireRequest.directive

        XCTAssertTrue(directive.contains(ToolNames.askSupervisorForm))
        XCTAssertFalse(
            directive.replacingOccurrences(of: ToolNames.askSupervisorForm, with: "")
                .contains(ToolNames.askSupervisor),
            "the plain ask is the channel being redirected AWAY from: \(directive)")
    }

    /// The point of the button is an EXPANDED question — the decision broken into its sides,
    /// each with options — not the same one question repackaged.
    ///
    /// RED: trim the directive to "Ask it again as a form." → this fails on every count.
    func testDirective_asksForTheDecisionBrokenIntoSides() {
        let directive = SupervisorQuestionnaireRequest.directive

        XCTAssertGreaterThanOrEqual(
            SupervisorQuestionnaireRequest.axes.count, 3,
            "fewer than three named sides is a repackaging, not an expansion")
        for axis in SupervisorQuestionnaireRequest.axes {
            XCTAssertTrue(directive.contains(axis), "the directive drops the side `\(axis)`")
        }
        XCTAssertTrue(directive.contains("one `questions` entry per side"))
    }

    /// Every `kind` the directive teaches has to be one the decoder accepts. Spelled from the
    /// enum rather than typed as prose, so a renamed case moves the directive with it.
    func testDirective_teachesOnlyKindsTheDecoderAccepts() {
        let directive = SupervisorQuestionnaireRequest.directive

        XCTAssertTrue(directive.contains(SupervisorInquiryKind.singleChoice.rawValue))
        XCTAssertTrue(directive.contains(SupervisorInquiryKind.freeText.rawValue))

        for token in directive.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            let word = token.trimmingCharacters(in: CharacterSet(charactersIn: "`.:—"))
            guard word.contains("_"), word != "ask_supervisor_form" else { continue }
            XCTAssertNotNil(
                SupervisorInquiryKind(rawValue: word),
                "`\(word)` looks like a kind the decoder does not have")
        }
    }

    /// No surface claims the order is a recommendation any more. The directive asks for the
    /// options and says nothing about their order, because since 2026-09-12 the app reads the
    /// recommendation out of what the model WRITES and badges nothing when it wrote none.
    ///
    /// RED: put "the one you recommend first" back in any of the four sites that carried it →
    /// the model is told position is a claim while the card, the wire tag and the audit log
    /// all read the resolved id, and a deliberately ordered form badges nothing.
    func testDirective_makesNoClaimAboutTheOrderOfOptions() {
        for spelling in ["recommend first", "one you recommend", "FIRST entry"] {
            XCTAssertFalse(
                SupervisorQuestionnaireRequest.directive.contains(spelling),
                "\(spelling): \(SupervisorQuestionnaireRequest.directive)")
        }
        XCTAssertTrue(
            SupervisorQuestionnaireRequest.directive.contains(
                "\(SupervisorInquiryKind.singleChoice.rawValue) with its options"))
    }

    // MARK: - Format conventions (R4.3.1, R1.2.2)

    func testDirective_carriesNoEmphasisNoPolitenessNoUIPaths() {
        let directive = SupervisorQuestionnaireRequest.directive

        XCTAssertFalse(directive.contains("**"))
        XCTAssertFalse(directive.contains("Settings →"))
        for word in ["please", "kindly", "thank you"] {
            XCTAssertFalse(
                directive.lowercased().contains(word), "politeness token `\(word)` (R4.3.1)")
        }
        XCTAssertFalse(
            directive.contains("\n"),
            "one run of prose: it rides a tool result, where a blank line separates it from the "
                + "Supervisor's own note (`compose`)")
    }

    // MARK: - Registry

    /// The marker alone is not enough — `RuntimePromptCensusPinTests` requires the row, and the
    /// row is what puts the text in `RuntimePromptFingerprint`.
    @MainActor
    func testTheDirectiveIsInTheRuntimePromptRegistry() {
        let rendered = RuntimePromptRegistry.entries
            .first { $0.name == "SupervisorQuestionnaireRequest.directive" }?
            .render()

        XCTAssertEqual(rendered, SupervisorQuestionnaireRequest.directive)
    }

    // MARK: - Fixture

    private static func sampleInquiry() -> SupervisorInquiry {
        SupervisorInquiry(
            headline: "Which way should the screen go?",
            questions: [
                SupervisorInquiryQuestion(
                    id: "q1", prompt: "Which layout?", kind: .singleChoice,
                    options: [
                        SupervisorInquiryOption(id: "a", label: "List"),
                        SupervisorInquiryOption(id: "b", label: "Grid"),
                    ])
            ])
    }
}
