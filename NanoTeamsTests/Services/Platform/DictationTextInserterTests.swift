import XCTest
@testable import NanoTeams

/// Exercises the pure anchor/replace logic extracted from `DictationMicButton`.
/// These cases are regression pins — previously the logic lived inline in a
/// SwiftUI view and was unreachable to unit tests.
final class DictationTextInserterTests: XCTestCase {

    // MARK: - Basic append flow

    func testApply_emptyText_insertsPartialAtAnchorZero() {
        let outcome = DictationTextInserter.apply(partial: "hello", to: "", anchor: 0, lastLength: 0)
        XCTAssertEqual(outcome.newText, "hello")
        XCTAssertEqual(outcome.newLength, 5)
        XCTAssertFalse(outcome.drifted)
    }

    func testApply_preservesTextBeforeAnchor() {
        // User typed "prefix " then started dictating: anchor = 7.
        let outcome = DictationTextInserter.apply(partial: "world", to: "prefix ", anchor: 7, lastLength: 0)
        XCTAssertEqual(outcome.newText, "prefix world")
        XCTAssertFalse(outcome.drifted)
    }

    func testApply_replacesPreviousPartial_notAppends() {
        // Previous partial "hello" at offset 0 of "hello"; new partial "hello world".
        let outcome = DictationTextInserter.apply(partial: "hello world", to: "hello", anchor: 0, lastLength: 5)
        XCTAssertEqual(outcome.newText, "hello world")
        XCTAssertEqual(outcome.newLength, 11)
    }

    func testApply_shrinkingPartial_trimsToShorter() {
        // Recognizer revised the transcription down — happens mid-sentence.
        let outcome = DictationTextInserter.apply(partial: "hi", to: "hello world", anchor: 0, lastLength: 11)
        XCTAssertEqual(outcome.newText, "hi")
        XCTAssertEqual(outcome.newLength, 2)
    }

    // MARK: - Unicode safety (grapheme clusters)

    func testApply_emojiGraphemeClusters_treatedAsSingleCharacter() {
        // 👨‍👩‍👧 is one grapheme cluster but multiple code points.
        // Our API operates on Character offsets, so partial.count == 1.
        let partial = "👨‍👩‍👧"
        let outcome = DictationTextInserter.apply(partial: partial, to: "", anchor: 0, lastLength: 0)
        XCTAssertEqual(outcome.newText, partial)
        XCTAssertEqual(outcome.newLength, 1)
    }

    func testApply_replaceRespectsGraphemeBoundaries() {
        // Buffer has an emoji in position 6. Anchor past it (offset 7) — replace
        // "end" with "END". Emoji must stay intact.
        let outcome = DictationTextInserter.apply(partial: "END", to: "start 👋 end", anchor: 8, lastLength: 3)
        XCTAssertEqual(outcome.newText, "start 👋 END")
    }

    // MARK: - Drift clamping (user-edit-during-dictation)

    func testApply_anchorPastEndOfText_clampsAndFlagsDrift() {
        // User started dictating, then deleted everything after the anchor.
        let outcome = DictationTextInserter.apply(partial: "new", to: "abc", anchor: 10, lastLength: 0)
        XCTAssertEqual(outcome.newText, "abcnew")
        XCTAssertTrue(outcome.drifted, "Should report drift so caller can reset anchor")
    }

    func testApply_oldEndPastTextEnd_clampsToEndAndFlagsDrift() {
        // Previous partial was "hello world" (11 chars), but user then deleted
        // " world" so text is now "hello" (5 chars). Next partial still thinks
        // lastLength = 11. Clamp prevents crash.
        let outcome = DictationTextInserter.apply(partial: "goodbye", to: "hello", anchor: 0, lastLength: 11)
        XCTAssertEqual(outcome.newText, "goodbye")
        XCTAssertTrue(outcome.drifted)
    }

    func testApply_negativeAnchor_clampsToZeroAndFlagsDrift() {
        // Defensive — shouldn't happen from the normal flow but guards against
        // off-by-one bugs in callers.
        let outcome = DictationTextInserter.apply(partial: "x", to: "abc", anchor: -5, lastLength: 0)
        XCTAssertEqual(outcome.newText, "xabc")
        XCTAssertTrue(outcome.drifted)
    }

    func testApply_negativeLastLength_treatedAsZero() {
        let outcome = DictationTextInserter.apply(partial: "x", to: "abc", anchor: 3, lastLength: -10)
        XCTAssertEqual(outcome.newText, "abcx")
        XCTAssertFalse(outcome.drifted, "Anchor was valid; only lastLength was defensive")
    }

    // MARK: - Empty partial

    func testApply_emptyPartial_removesPreviouslyInsertedText() {
        let outcome = DictationTextInserter.apply(partial: "", to: "abc hello", anchor: 4, lastLength: 5)
        XCTAssertEqual(outcome.newText, "abc ")
        XCTAssertEqual(outcome.newLength, 0)
    }
}
