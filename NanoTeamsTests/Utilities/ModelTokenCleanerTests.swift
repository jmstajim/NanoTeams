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
}
