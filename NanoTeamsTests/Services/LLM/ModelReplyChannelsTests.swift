import XCTest

@testable import NanoTeams

/// The rule that decides which channel of a one-shot LLM reply carries the answer.
///
/// It is three lines, and before it had an owner it had five spellings and four
/// omissions. These tests pin the rule; `OneShotReasoningChannelCoverageTests` pins
/// that each service actually routes through it.
final class ModelReplyChannelsTests: XCTestCase {

    private let identity: (String) -> String = { $0 }

    // MARK: - Selection

    /// RED: swap the branch (`if preparedContent.isEmpty { return preparedContent }`) →
    /// content is discarded whenever both channels speak.
    func testContentWins_whenBothChannelsSpeak() {
        XCTAssertEqual(
            ModelReplyChannels.answer(content: "answer", reasoning: "hmm", prepare: identity),
            "answer")
    }

    /// RED: drop the fallback (`return prepare(content)`) → this returns "".
    func testReasoningIsUsed_whenContentIsEmpty() {
        XCTAssertEqual(
            ModelReplyChannels.answer(content: "", reasoning: "answer", prepare: identity),
            "answer")
    }

    func testBothEmpty_yieldsEmpty() {
        XCTAssertEqual(
            ModelReplyChannels.answer(content: "", reasoning: "", prepare: identity), "")
    }

    // MARK: - `prepare` runs BEFORE the emptiness test

    /// RED: apply `prepare` only to the RETURNED channel (test emptiness on the raw
    /// strings) → whitespace-only content wins and the real answer is dropped.
    ///
    /// This is the ordering that matters in production: LM Studio routinely emits a
    /// newline on the content channel before a reasoning-only reply, so "content is
    /// non-empty" is false as a raw-string test.
    func testWhitespaceOnlyContent_yieldsToReasoning() {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertEqual(
            ModelReplyChannels.answer(content: "\n  \n", reasoning: "answer", prepare: trim),
            "answer")
    }

    /// A channel holding nothing but a Harmony header is empty too — `<|channel|>final`
    /// with no body is a complete non-answer, and letting it win would deliver "" while a
    /// real reply waited in the other channel.
    ///
    /// Uses `cleanHarmonyTokens`, because only that one reduces the header to "": the bare
    /// `ModelTokenCleaner.clean` strips the `<|…|>` sentinels and leaves the glued keyword
    /// `final` behind, which is non-empty and would therefore WIN. That difference is the
    /// reason `WorkFolderContextService` and `VisionAnalysisService` both moved onto the
    /// stronger cleaner in this wave.
    func testHeaderOnlyContent_yieldsToReasoning() {
        let clean: (String) -> String = { ConversationRepairService.cleanHarmonyTokens($0) }
        let answer = ModelReplyChannels.answer(
            content: "<|channel|>final<|message|>", reasoning: "answer", prepare: clean)
        XCTAssertEqual(answer, "answer")
    }

    /// The weaker cleaner does NOT reduce that header to empty — pinned so the choice of
    /// preparer at each call site stays a deliberate one rather than a coincidence.
    func testHeaderOnlyContent_underTheWeakCleaner_isNotEmpty() {
        XCTAssertEqual(ModelTokenCleaner.clean("<|channel|>final<|message|>"), "final")
    }

    /// `prepare` is applied to the reasoning channel too — a reasoning channel is MORE
    /// likely to carry envelope debris, not less.
    func testReasoningIsPreparedAsWell() {
        let clean: (String) -> String = { ConversationRepairService.cleanHarmonyTokens($0) }
        let answer = ModelReplyChannels.answer(
            content: "", reasoning: "<|channel|>final<|message|>Use Postgres.<|end|>",
            prepare: clean)
        XCTAssertFalse(answer.contains("<|"), answer)
        XCTAssertTrue(answer.contains("Use Postgres."), answer)
    }

    /// `prepare` is called at most once per channel — it is `ModelTokenCleaner.clean` +
    /// regex work at several sites, and one of them (the meeting turn) runs it per speaker
    /// per turn.
    func testPrepareIsCalledOncePerChannel() {
        var calls = 0
        _ = ModelReplyChannels.answer(content: "", reasoning: "x", prepare: {
            calls += 1
            return $0
        })
        XCTAssertEqual(calls, 2, "expected one call per channel")

        calls = 0
        _ = ModelReplyChannels.answer(content: "x", reasoning: "y", prepare: {
            calls += 1
            return $0
        })
        XCTAssertEqual(calls, 1, "reasoning must not be prepared when content wins")
    }

    // MARK: - Parity with each site's own `prepare`

    /// Every call site passes a different `prepare`, on purpose, and the rule must be
    /// spelling-independent. If this ever fails it means the selection rule leaked an
    /// assumption about a particular cleaner.
    func testSelectionIsIndependentOfThePreparer() {
        let preparers: [(String) -> String] = [
            { $0 },
            { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            { ModelTokenCleaner.clean($0) },
            { ConversationRepairService.cleanHarmonyTokens($0) },
            { JudgeVerdictParser.whitespaceTrimmed(ModelTokenCleaner.clean($0)) },
            { ModelTokenCleaner.clean($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
        ]
        for prepare in preparers {
            XCTAssertEqual(
                ModelReplyChannels.answer(content: "A", reasoning: "B", prepare: prepare), "A")
            XCTAssertEqual(
                ModelReplyChannels.answer(content: "", reasoning: "B", prepare: prepare), "B")
        }
    }
}
