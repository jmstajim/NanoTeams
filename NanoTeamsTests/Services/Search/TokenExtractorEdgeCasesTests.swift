import XCTest
@testable import NanoTeams

final class TokenExtractorEdgeCasesTests: XCTestCase {

    // MARK: - Unicode: emoji + symbols

    func testEmoji_treatedAsSeparator() {
        let tokens = TokenExtractor.extractTokens(from: "scroll 🎯 view")
        // Emoji are symbols → separator — scroll and view extracted, emoji is not a token.
        XCTAssertTrue(tokens.contains("scroll"))
        XCTAssertTrue(tokens.contains("view"))
        XCTAssertFalse(tokens.contains("🎯"))
    }

    func testSymbolsBetweenWords_actAsSeparators() {
        let tokens = TokenExtractor.extractTokens(from: "scroll==view")
        XCTAssertTrue(tokens.contains("scroll"))
        XCTAssertTrue(tokens.contains("view"))
    }

    // MARK: - Ambiguous camelCase runs

    func testSingleCapitalAtEnd_splitCorrectly() {
        let tokens = TokenExtractor.extractTokens(from: "scrollX")
        XCTAssertTrue(tokens.contains("scrollx"))
        XCTAssertTrue(tokens.contains("scroll"))
        // 'X' alone is < minTokenLength → dropped.
        XCTAssertFalse(tokens.contains("x"))
    }

    func testAllCapsAcronym() {
        let tokens = TokenExtractor.extractTokens(from: "HTTP")
        XCTAssertTrue(tokens.contains("http"))
    }

    func testAcronymThenWord() {
        let tokens = TokenExtractor.extractTokens(from: "JSONParser")
        XCTAssertTrue(tokens.contains("json"))
        XCTAssertTrue(tokens.contains("parser"))
        XCTAssertTrue(tokens.contains("jsonparser"))
    }

    func testWordThenAcronym() {
        let tokens = TokenExtractor.extractTokens(from: "parseJSON")
        XCTAssertTrue(tokens.contains("parse"))
        XCTAssertTrue(tokens.contains("json"))
    }

    // MARK: - Digits embedded

    func testDigitBetweenLetters() {
        // camel-split regex splits the digit run; both letter runs survive.
        let tokens = TokenExtractor.extractTokens(from: "http2Server")
        XCTAssertTrue(tokens.contains("http2server"))
        XCTAssertTrue(tokens.contains("server"))
    }

    func testVersionString() {
        let tokens = TokenExtractor.extractTokens(from: "version1_2_3")
        XCTAssertTrue(tokens.contains("version"))
        // Pure-digit tokens are discarded.
        XCTAssertFalse(tokens.contains("1"))
        XCTAssertFalse(tokens.contains("2"))
        XCTAssertFalse(tokens.contains("3"))
    }

    // MARK: - Long words

    func testVeryLongSingleToken_kept() {
        let long = String(repeating: "a", count: 100)
        let tokens = TokenExtractor.extractTokens(from: long)
        XCTAssertTrue(tokens.contains(long))
    }

    // MARK: - Mixed casing dedup

    func testMixedCaseDuplicates_normalizedToOneLowercase() {
        let tokens = TokenExtractor.extractTokens(from: "Scroll SCROLL scroll scrolL")
        let scrolls = tokens.filter { $0 == "scroll" }
        XCTAssertEqual(scrolls.count, 1)
    }

    // MARK: - Zero-width joiners / non-printables

    func testTab_actsAsSeparator() {
        let tokens = TokenExtractor.extractTokens(from: "scroll\tview")
        XCTAssertTrue(tokens.contains("scroll"))
        XCTAssertTrue(tokens.contains("view"))
    }

    func testNewlineSeparator() {
        let tokens = TokenExtractor.extractTokens(from: "alpha\nbeta\r\ngamma")
        XCTAssertTrue(tokens.contains("alpha"))
        XCTAssertTrue(tokens.contains("beta"))
        XCTAssertTrue(tokens.contains("gamma"))
    }

    // MARK: - Cyrillic edge cases

    func testCyrillicCamel_multipleWords() {
        let tokens = TokenExtractor.extractTokens(from: "ПрокруткаВидаView")
        XCTAssertTrue(tokens.contains("прокрутка"))
        XCTAssertTrue(tokens.contains("вида"))
        XCTAssertTrue(tokens.contains("view"))
    }

    func testCyrillicSnakeCase() {
        let tokens = TokenExtractor.extractTokens(from: "прокрутка_вида")
        XCTAssertTrue(tokens.contains("прокрутка"))
        XCTAssertTrue(tokens.contains("вида"))
        XCTAssertTrue(tokens.contains("прокрутка_вида"))
    }

    // MARK: - Filename edge cases

    func testFilenameWithDotsInMiddle() {
        // "my.config.yml" → `deletingPathExtension().lastPathComponent` = "my.config"
        let url = URL(fileURLWithPath: "/tmp/my.config.yml")
        let tokens = TokenExtractor.extractFilenameTokens(from: url)
        XCTAssertTrue(tokens.contains("config"))
        // "my" is 2 chars, should be kept.
        XCTAssertTrue(tokens.contains("my"))
    }

    func testFilenameWithoutExtension() {
        let url = URL(fileURLWithPath: "/tmp/Makefile")
        let tokens = TokenExtractor.extractFilenameTokens(from: url)
        XCTAssertTrue(tokens.contains("makefile"))
        XCTAssertTrue(tokens.contains("make"))
        XCTAssertTrue(tokens.contains("file"))
    }
}
