import XCTest
@testable import NanoTeams

final class TokenExtractorTests: XCTestCase {

    // MARK: - Basic splitting

    func testCamelCase_splitsIntoPieces() {
        let tokens = TokenExtractor.extractTokens(from: "makeScrollView")
        XCTAssertTrue(tokens.contains("makescrollview"))
        XCTAssertTrue(tokens.contains("make"))
        XCTAssertTrue(tokens.contains("scroll"))
        XCTAssertTrue(tokens.contains("view"))
    }

    func testSnakeCase_splitsOnUnderscores() {
        let tokens = TokenExtractor.extractTokens(from: "k_max_size")
        XCTAssertTrue(tokens.contains("max"))
        XCTAssertTrue(tokens.contains("size"))
        // 'k' is 1 char — should be discarded.
        XCTAssertFalse(tokens.contains("k"))
        // The lowercased original full form survives if ≥ 2 chars.
        XCTAssertTrue(tokens.contains("k_max_size"))
    }

    func testDashCase_splitsOnDashes() {
        let tokens = TokenExtractor.extractTokens(from: "on-file-change")
        XCTAssertTrue(tokens.contains("on"))
        XCTAssertTrue(tokens.contains("file"))
        XCTAssertTrue(tokens.contains("change"))
        XCTAssertTrue(tokens.contains("on-file-change"))
    }

    func testPascalCase_splitsIntoPieces() {
        let tokens = TokenExtractor.extractTokens(from: "XMLParser")
        XCTAssertTrue(tokens.contains("xml"))
        XCTAssertTrue(tokens.contains("parser"))
        XCTAssertTrue(tokens.contains("xmlparser"))
    }

    // MARK: - Multilingual

    func testCyrillic_pascalCase_splits() {
        let tokens = TokenExtractor.extractTokens(from: "ПрокруткаView")
        // All-lowercase full form survives.
        XCTAssertTrue(tokens.contains("прокруткаview"))
        // Both parts of the camelCase split land as lowercase.
        XCTAssertTrue(tokens.contains("прокрутка"))
        XCTAssertTrue(tokens.contains("view"))
    }

    func testCyrillic_plainText_keepsWhole() {
        let tokens = TokenExtractor.extractTokens(from: "параллелизм")
        XCTAssertTrue(tokens.contains("параллелизм"))
    }

    // MARK: - Filtering

    func testDiscardsPureDigits() {
        let tokens = TokenExtractor.extractTokens(from: "123 456")
        XCTAssertFalse(tokens.contains("123"))
        XCTAssertFalse(tokens.contains("456"))
    }

    func testKeepsAlphanumericMixedWithDigits() {
        // The regex splits digit runs out; the mixed camel form stays.
        let tokens = TokenExtractor.extractTokens(from: "HTTP2Server")
        XCTAssertTrue(tokens.contains("http2server"))
        XCTAssertTrue(tokens.contains("server"))
    }

    func testDiscardsOneCharTokens() {
        let tokens = TokenExtractor.extractTokens(from: "a b c ab cd")
        XCTAssertFalse(tokens.contains("a"))
        XCTAssertFalse(tokens.contains("b"))
        XCTAssertFalse(tokens.contains("c"))
        XCTAssertTrue(tokens.contains("ab"))
        XCTAssertTrue(tokens.contains("cd"))
    }

    // MARK: - Corner cases

    func testEmptyInput_returnsEmpty() {
        XCTAssertTrue(TokenExtractor.extractTokens(from: "").isEmpty)
    }

    func testOnlyWhitespace_returnsEmpty() {
        XCTAssertTrue(TokenExtractor.extractTokens(from: "   \n  \t  ").isEmpty)
    }

    func testPunctuationOnly_returnsEmpty() {
        XCTAssertTrue(TokenExtractor.extractTokens(from: "!!! ::: ??? ...").isEmpty)
    }

    func testMarkdownHorizontalRule_discarded() {
        // Markdown horizontal rules (`---`, `------`, …) are a major source of
        // vocabulary bloat: dashes are intentionally non-separators so
        // snake/dash identifiers survive, but a run of pure dashes has no
        // vocabulary value.
        XCTAssertTrue(TokenExtractor.extractTokens(from: "---").isEmpty)
        XCTAssertTrue(TokenExtractor.extractTokens(from: "------").isEmpty)
        XCTAssertTrue(TokenExtractor.extractTokens(from: "----------").isEmpty)
    }

    func testNegativeNumber_discarded() {
        // `-100000`, `-04-21`, `-1_209_600` have no letters and should be
        // dropped. The old `isAllDigits` filter missed them because `-` isn't
        // a digit.
        XCTAssertTrue(TokenExtractor.extractTokens(from: "-100000").isEmpty)
        XCTAssertTrue(TokenExtractor.extractTokens(from: "-04-21").isEmpty)
        XCTAssertTrue(TokenExtractor.extractTokens(from: "-1_209_600").isEmpty)
    }

    func testCLIFlagWithLetters_kept() {
        // `--amend` is real vocabulary (git CLI flag) — the dash prefix must
        // not cause it to be dropped.
        let tokens = TokenExtractor.extractTokens(from: "--amend")
        XCTAssertTrue(tokens.contains("amend"))
    }

    func testVeryLongInput_doesntExplode() {
        // Sanity check on larger input.
        let body = String(repeating: "makeScrollView ", count: 500)
        let tokens = TokenExtractor.extractTokens(from: body)
        XCTAssertTrue(tokens.contains("makescrollview"))
        XCTAssertTrue(tokens.contains("make"))
        XCTAssertTrue(tokens.contains("scroll"))
        XCTAssertTrue(tokens.contains("view"))
    }

    func testMixedScriptsInSameString() {
        let tokens = TokenExtractor.extractTokens(from: "scrollView прокрутка makeScrollView")
        XCTAssertTrue(tokens.contains("scroll"))
        XCTAssertTrue(tokens.contains("view"))
        XCTAssertTrue(tokens.contains("прокрутка"))
        XCTAssertTrue(tokens.contains("makescrollview"))
    }

    // MARK: - Filename tokens

    func testFilenameStem_dropsExtension() {
        let url = URL(fileURLWithPath: "/tmp/MyViewController.swift")
        let tokens = TokenExtractor.extractFilenameTokens(from: url)
        XCTAssertTrue(tokens.contains("myviewcontroller"))
        XCTAssertTrue(tokens.contains("view"))
        XCTAssertTrue(tokens.contains("controller"))
        // Extension should NOT appear.
        XCTAssertFalse(tokens.contains("swift"))
    }

    func testFilenameStem_compoundName() {
        // user_profile.py → stem "user_profile" → {user_profile, user, profile}
        let url = URL(fileURLWithPath: "/tmp/user_profile.py")
        let tokens = TokenExtractor.extractFilenameTokens(from: url)
        XCTAssertTrue(tokens.contains("user_profile"))
        XCTAssertTrue(tokens.contains("user"))
        XCTAssertTrue(tokens.contains("profile"))
        XCTAssertFalse(tokens.contains("py"))
    }

    // MARK: - Compound filename splitting

    func testFilenameStem_unknownCompound_staysWhole() {
        // "scrollview" has no split markers and none of its substrings are
        // in `knownFilenameStems` — must land as a single token, not get
        // over-split by the compound heuristic.
        let url = URL(fileURLWithPath: "/tmp/scrollview.swift")
        let tokens = TokenExtractor.extractFilenameTokens(from: url)
        XCTAssertTrue(tokens.contains("scrollview"))
        // Nothing in knownFilenameStems overlaps with scrollview's internals.
        XCTAssertFalse(tokens.contains("scroll"))
        XCTAssertFalse(tokens.contains("view"))
    }

    func testFilenameStem_shortRemainder_suppressesSplit() {
        // "filer" starts with "file" (known) but the remainder "r" is 1 char
        // — below `minTokenLength=2`. The length guard treats this as "not a
        // compound" and suppresses the WHOLE split (neither the stem nor the
        // remainder is inserted) — splitting precision wins over recall when
        // the remainder is implausibly short.
        let url = URL(fileURLWithPath: "/tmp/filer.txt")
        let tokens = TokenExtractor.extractFilenameTokens(from: url)
        XCTAssertTrue(tokens.contains("filer"))
        XCTAssertFalse(tokens.contains("r"))
        XCTAssertFalse(tokens.contains("file"),
                       "Guard must suppress stem insertion when remainder < minTokenLength.")
    }

    func testFilenameStem_suffixMatch_splits() {
        // "dockerfile" — "file" is a known suffix, remainder "docker" is
        // ≥ minTokenLength. Expect full form + both halves.
        let url = URL(fileURLWithPath: "/tmp/Dockerfile")
        let tokens = TokenExtractor.extractFilenameTokens(from: url)
        XCTAssertTrue(tokens.contains("dockerfile"))
        XCTAssertTrue(tokens.contains("docker"))
        XCTAssertTrue(tokens.contains("file"))
    }
}
