import XCTest

@testable import NanoTeams

/// The headline derived from a questionnaire that arrived without one.
///
/// Field evidence the rule is built on: MeditationApp task 76, 2026-09-12, `ornith-1.5:35b` —
/// 4 of 20 runs emitted `{"form": {…}}` and nothing else, and in every one the first
/// question's prompt was the message the model meant the Supervisor to read first.
final class SupervisorInquiryHeadlineFallbackTests: XCTestCase {

    private func question(_ prompt: String) -> SupervisorInquiryQuestion {
        SupervisorInquiryQuestion(id: "q", prompt: prompt, kind: .freeText)
    }

    // MARK: - What it takes

    func testTakesTheFirstQuestionsPrompt() {
        let headline = SupervisorInquiryHeadlineFallback.headline(
            for: [question("Чем помочь сейчас?"), question("Второй вопрос")])
        XCTAssertEqual(headline, "Чем помочь сейчас?")
    }

    /// A headline is ONE line — the banner, the chip and the sidebar preview each render a
    /// single line, and a prompt carrying a paragraph would push the rest off every one.
    func testTakesOnlyTheFirstLineOfAMultiLinePrompt() {
        let headline = SupervisorInquiryHeadlineFallback.headline(
            for: [question("Всё работает.\nЧто дальше?\nЖду задачу.")])
        XCTAssertEqual(headline, "Всё работает.")
    }

    func testSkipsLeadingBlankLines() {
        let headline = SupervisorInquiryHeadlineFallback.headline(
            for: [question("\n   \nПривет! Готов продолжать.")])
        XCTAssertEqual(headline, "Привет! Готов продолжать.")
    }

    // MARK: - When there is nothing to take

    func testNoQuestionsYieldsNothing() {
        XCTAssertNil(SupervisorInquiryHeadlineFallback.headline(for: []))
    }

    /// A decoded questionnaire cannot reach here — `SupervisorInquiry`'s decoder refuses a
    /// blank prompt — so this is the fail-closed arm, pinned so it stays one.
    func testABlankPromptYieldsNothingRatherThanABlankHeadline() {
        XCTAssertNil(SupervisorInquiryHeadlineFallback.headline(for: [question("   \n\t ")]))
    }

    // MARK: - The length the domain allows

    func testAPromptAtTheLimitIsUsedVerbatim() {
        let exact = String(repeating: "a", count: SupervisorInquiryLimits.maxHeadlineCharacters)
        XCTAssertEqual(SupervisorInquiryHeadlineFallback.headline(for: [question(exact)]), exact)
    }

    /// The prompt cap is 2000 and the headline cap is 400, so this is a LIVE path, not a
    /// theoretical one: the derived headline must satisfy the same decoder that refuses an
    /// over-long authored one.
    func testALongPromptIsCutToTheHeadlineLimit() {
        let long = String(repeating: "слово ", count: 400)
        guard let headline = SupervisorInquiryHeadlineFallback.headline(for: [question(long)])
        else { return XCTFail("a long prompt must still yield a headline") }
        XCTAssertLessThanOrEqual(headline.count, SupervisorInquiryLimits.maxHeadlineCharacters)
        XCTAssertTrue(headline.hasSuffix("…"), headline)
    }

    func testALongPromptIsCutAtAWordBoundary() {
        let long = String(repeating: "слово ", count: 400)
        guard let headline = SupervisorInquiryHeadlineFallback.headline(for: [question(long)])
        else { return XCTFail("a long prompt must still yield a headline") }
        XCTAssertTrue(headline.hasSuffix("слово…"), headline)
    }

    /// No boundary to cut at — a single unbroken token — is cut hard rather than abandoned.
    func testAnUnbrokenLongPromptIsCutAnyway() {
        let long = String(repeating: "a", count: 900)
        guard let headline = SupervisorInquiryHeadlineFallback.headline(for: [question(long)])
        else { return XCTFail("an unbroken prompt must still yield a headline") }
        XCTAssertLessThanOrEqual(headline.count, SupervisorInquiryLimits.maxHeadlineCharacters)
        XCTAssertTrue(headline.hasSuffix("…"), headline)
    }

    /// Whatever it returns must satisfy the decoder that will see it — the fallback exists to
    /// avoid a refusal, and a headline of its own making that the decoder refuses would move
    /// the failure rather than remove it.
    func testTheDerivedHeadlineAlwaysDecodes() throws {
        for prompt in ["Короткий вопрос",
                       String(repeating: "слово ", count: 400),
                       String(repeating: "a", count: 900)] {
            let derived = try XCTUnwrap(
                SupervisorInquiryHeadlineFallback.headline(for: [question(prompt)]))
            let json = """
            {"headline": \(Self.jsonString(derived)), \
            "questions": [{"prompt": "P", "kind": "free_text"}]}
            """
            XCTAssertNoThrow(
                try JSONDecoder().decode(SupervisorInquiry.self, from: Data(json.utf8)),
                derived)
        }
    }

    private static func jsonString(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!
            .dropFirst().dropLast().description
    }
}
