import XCTest
@testable import NanoTeams

final class ModelTokenCleanerTests: XCTestCase {

    // MARK: - Basic Token Removal

    func testCleanRemovesChannelTokens() {
        let input = "<|channel|>commentary to=functions.foo<|message|>{}"
        let cleaned = ModelTokenCleaner.clean(input)
        XCTAssertEqual(cleaned, "commentary to=functions.foo{}")
    }

    func testCleanRemovesConstrainTokens() {
        let input = "Some content<|constrain|>more content<|end|>"
        let cleaned = ModelTokenCleaner.clean(input)
        XCTAssertEqual(cleaned, "Some contentmore content")
    }

    func testCleanHandlesMultipleTokens() {
        let input = "Before<|constrain|>middle<|end|>after"
        let cleaned = ModelTokenCleaner.clean(input)
        XCTAssertEqual(cleaned, "Beforemiddleafter")
    }

    func testCleanRemovesNestedTokens() {
        let input = "<|call|>{\"name\": \"<|tool|>\", \"args\": {}}"
        let cleaned = ModelTokenCleaner.clean(input)
        XCTAssertEqual(cleaned, "{\"name\": \"\", \"args\": {}}")
    }

    // MARK: - Empty Content Cases

    func testCleanReturnsEmptyWhenOnlyTokens() {
        let input = "<|channel|><|constrain|><|end|>"
        let cleaned = ModelTokenCleaner.clean(input)
        XCTAssertTrue(cleaned.isEmpty)
    }

    func testCleanReturnsEmptyWhenTokensWithWhitespace() {
        let input = "  <|channel|>  <|constrain|>  <|end|>  "
        let cleaned = ModelTokenCleaner.clean(input)
        XCTAssertTrue(cleaned.isEmpty)
    }

    func testCleanTrimsWhitespaceFromRealContent() {
        let input = "  \n  <|channel|>  actual content  \n  "
        let cleaned = ModelTokenCleaner.clean(input)
        XCTAssertEqual(cleaned, "actual content")
    }

    // MARK: - Real Response Cases

    func testCleanHandlesHarmonyFormatToolCall() {
        let input = "<|channel|>scratchpad to=functions.update_scratchpad<|message|>{\"content\": \"Plan: 1) read, 2) edit, 3) commit\"}"
        let cleaned = ModelTokenCleaner.clean(input)
        XCTAssertEqual(cleaned, "scratchpad to=functions.update_scratchpad{\"content\": \"Plan: 1) read, 2) edit, 3) commit\"}")
    }

    func testCleanPreservesJsonStructure() {
        let input = "Here's a response: <|constrain|>{\"tool\": \"read_file\", \"args\": {\"path\": \"/file.txt\"}}"
        let cleaned = ModelTokenCleaner.clean(input)
        XCTAssertEqual(cleaned, "Here's a response: {\"tool\": \"read_file\", \"args\": {\"path\": \"/file.txt\"}}")
    }

    func testCleanPreservesNormalContent() {
        let input = "I will read the file at /path/to/file.swift"
        let cleaned = ModelTokenCleaner.clean(input)
        XCTAssertEqual(cleaned, "I will read the file at /path/to/file.swift")
    }

    // MARK: - Detection

    func testContainsModelTokensDetectsChannelToken() {
        XCTAssertTrue(ModelTokenCleaner.containsModelTokens("<|channel|>foo"))
    }

    func testContainsModelTokensDetectsConstrainToken() {
        XCTAssertTrue(ModelTokenCleaner.containsModelTokens("foo<|constrain|>"))
    }

    func testContainsModelTokensDetectsMultipleTokens() {
        XCTAssertTrue(ModelTokenCleaner.containsModelTokens("<|start|>content<|end|>"))
    }

    func testContainsModelTokensReturnsFalseForNormalText() {
        XCTAssertFalse(ModelTokenCleaner.containsModelTokens("This is normal text"))
    }

    func testContainsModelTokensReturnsFalseForPartialMarkers() {
        XCTAssertFalse(ModelTokenCleaner.containsModelTokens("<channel> foo |>"))
    }

    // MARK: - Edge Cases

    func testCleanEmptyString() {
        let cleaned = ModelTokenCleaner.clean("")
        XCTAssertTrue(cleaned.isEmpty)
    }

    func testCleanOnlyWhitespace() {
        let cleaned = ModelTokenCleaner.clean("   \n\t  ")
        XCTAssertTrue(cleaned.isEmpty)
    }

    func testCleanUnmatchedTokenMarker() {
        let input = "<|channel|>content without closing"
        let cleaned = ModelTokenCleaner.clean(input)
        // Unmatched opener stays (can't close), content remains
        XCTAssertEqual(cleaned, "content without closing")
    }

    func testCleanTokensWithoutClosing() {
        let input = "<|start|>content<|end|>more<|final"
        let cleaned = ModelTokenCleaner.clean(input)
        // <|start|> and <|end|> are removed, but <|final is kept (no closing)
        XCTAssertEqual(cleaned, "contentmore<|final")
    }

    // MARK: - Bounded span (gemma-4-e4b mangled sentinels)

    /// The regression this bound exists for. `<|tool_call>` has no `|>` of its own, so
    /// the greedy pairing matched the one at the end of `<|end|>` and deleted the entire
    /// `create_artifact` payload between them — the model was then told it had submitted
    /// nothing, for an attempt the harness had swallowed.
    /// (MeditationApp run, record `[39]` @2026-08-07T13:52:24.821Z.)
    func testClean_mangledOpenerDoesNotSwallowPayload() {
        let input = #"<|tool_call>call_multiple{"contributions":[{"toolName":"create_artifact"}]}<|end|>"#
        XCTAssertEqual(
            ModelTokenCleaner.clean(input),
            #"<|tool_call>call_multiple{"contributions":[{"toolName":"create_artifact"}]}"#,
            "the unmatched opener stays verbatim so the normalizer can still see it; only the real <|end|> goes")
    }

    /// A span carrying a line break is prose, not one token.
    func testClean_spanWithNewline_isNotRemoved() {
        let input = "<|oops\nstill here|>tail"
        XCTAssertEqual(ModelTokenCleaner.clean(input), input)
    }

    /// Over the 32-char cap: no real sentinel is this long (the longest shipped is
    /// `<|channel|>` at 11).
    func testClean_spanOverCap_isNotRemoved() {
        let input = "<|" + String(repeating: "x", count: 40) + "|>tail"
        XCTAssertEqual(ModelTokenCleaner.clean(input), input)
    }

    /// Skipping a non-token `<|` must not suppress cleaning of the rest — the loop
    /// resumes after it rather than bailing out.
    func testClean_rejectedSpanDoesNotBlockLaterTokens() {
        let input = #"<|tool_call>call_multiple{"a":1}<|end|> then <|channel|>done"#
        XCTAssertEqual(
            ModelTokenCleaner.clean(input),
            #"<|tool_call>call_multiple{"a":1} then done"#)
    }

    /// The `[33]` shape: the alien opener DOES have a `|>` here and the span is short and
    /// brace-free, so it is removed exactly as before — this record is the normalizer's
    /// job, not the cleaner's.
    func testClean_shortMangledSpanWithOwnCloser_stillRemoved() {
        let input = #"<|tool_call>call|>{"name":"list_files"}|<|<end|>"#
        XCTAssertEqual(ModelTokenCleaner.clean(input), #"{"name":"list_files"}|"#)
    }

    /// The cap is a length in CHARACTERS and is decided within the first 33 of them —
    /// `Substring.count` walked the whole span, which is unbounded when an opening `<|`
    /// has no closer until the far end of a large payload. Boundary pinned on both sides
    /// so a `<`/`<=` slip is caught.
    func testClean_spanExactlyAtCap_isRemoved_oneOverIsNot() {
        // `<|` + body + `|>` = 32 characters ⇒ body of 28.
        let atCap = "<|" + String(repeating: "x", count: 28) + "|>tail"
        XCTAssertEqual(ModelTokenCleaner.clean(atCap), "tail")

        let overCap = "<|" + String(repeating: "x", count: 29) + "|>tail"
        XCTAssertEqual(ModelTokenCleaner.clean(overCap), overCap)
    }
}
