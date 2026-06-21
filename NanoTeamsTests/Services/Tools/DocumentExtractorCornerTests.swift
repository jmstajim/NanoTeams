import XCTest

@testable import NanoTeams

/// Boundary / degenerate-input corner cases for the pure document-extractor
/// helpers extracted during the DocumentTextExtractor → Strategy refactor.
/// Complements `DocumentFormatExtractorsTests` (happy-path + a few corners)
/// with the boundary values: single row, ragged rows, exact maxRows, zero
/// caps, multi-byte truncation boundaries, and slide-number edge inputs.
final class DocumentExtractorCornerTests: XCTestCase {

    // MARK: - XLSXDocumentExtractor.formatMarkdownTable

    func testTable_singleRow_emitsHeaderThenSeparator() {
        let out = XLSXDocumentExtractor.formatMarkdownTable(rows: [["a", "b"]], maxRows: 200)
        XCTAssertEqual(out, "| a | b |\n| --- | --- |")
    }

    func testTable_emptyRows_returnsEmpty() {
        XCTAssertEqual(XLSXDocumentExtractor.formatMarkdownTable(rows: [], maxRows: 10), "")
    }

    func testTable_singleEmptyRow_zeroColumns_returnsEmpty() {
        XCTAssertEqual(XLSXDocumentExtractor.formatMarkdownTable(rows: [[]], maxRows: 10), "")
    }

    func testTable_maxRowsZero_returnsEmpty() {
        // prefix(0) → no columns → empty, even with real rows present.
        XCTAssertEqual(XLSXDocumentExtractor.formatMarkdownTable(rows: [["a"]], maxRows: 0), "")
    }

    func testTable_raggedRows_padToWidestRow() {
        let out = XLSXDocumentExtractor.formatMarkdownTable(
            rows: [["a", "b", "c"], ["x"]], maxRows: 200)
        XCTAssertTrue(out.contains("| --- | --- | --- |"),
                      "separator must reflect the widest row's column count: \(out)")
        // The short row is padded to 3 columns (two trailing empty cells).
        XCTAssertTrue(out.contains("| x |  |  |"), out)
    }

    func testTable_exactlyMaxRows_noTruncationNotice() {
        let out = XLSXDocumentExtractor.formatMarkdownTable(
            rows: [["a"], ["b"]], maxRows: 2)
        XCTAssertFalse(out.contains("more rows"),
                       "exactly maxRows must not append a truncation notice: \(out)")
    }

    func testTable_oneOverMaxRows_appendsNoticeCountingDropped() {
        let out = XLSXDocumentExtractor.formatMarkdownTable(
            rows: [["a"], ["b"], ["c"]], maxRows: 2)
        XCTAssertTrue(out.contains("(1 more rows)"), out)
    }

    func testTable_pipeInsideCell_isEscaped() {
        let out = XLSXDocumentExtractor.formatMarkdownTable(rows: [["a|b", "c"]], maxRows: 200)
        XCTAssertTrue(out.contains(#"a\|b"#), "pipes inside cells must be escaped: \(out)")
    }

    // MARK: - PPTXDocumentExtractor.slideNumber

    func testSlideNumber_leadingZeros_parsedAsInt() {
        XCTAssertEqual(PPTXDocumentExtractor.slideNumber("ppt/slides/slide007.xml"), 7)
    }

    func testSlideNumber_digitsInDirectoryButNotFilename_ignored() {
        // Only the last path component's digits count.
        XCTAssertEqual(PPTXDocumentExtractor.slideNumber("ppt/2024/slideX.xml"), 0)
        XCTAssertEqual(PPTXDocumentExtractor.slideNumber("ppt/2024/slide5.xml"), 5)
    }

    func testSlideNumber_multipleDigitGroups_concatenated() {
        // `filter(isNumber)` keeps every digit in the basename.
        XCTAssertEqual(PPTXDocumentExtractor.slideNumber("slide1v2.xml"), 12)
    }

    func testSlideNumber_noDigits_returnsZero() {
        XCTAssertEqual(PPTXDocumentExtractor.slideNumber("ppt/slides/notes.xml"), 0)
        XCTAssertEqual(PPTXDocumentExtractor.slideNumber("slide.xml"), 0)
    }

    func testSlideNumber_largeNumber_parsed() {
        XCTAssertEqual(PPTXDocumentExtractor.slideNumber("slide123456.xml"), 123456)
    }

    // MARK: - DocumentTextExtractor.truncateToUTF8Bytes

    func testTruncate_underAndExactCap_returnsInputUnchanged() {
        XCTAssertEqual(DocumentTextExtractor.truncateToUTF8Bytes("ab", maxBytes: 5), "ab")
        XCTAssertEqual(DocumentTextExtractor.truncateToUTF8Bytes("abc", maxBytes: 3), "abc")
    }

    func testTruncate_zeroCap_returnsEmpty() {
        XCTAssertEqual(DocumentTextExtractor.truncateToUTF8Bytes("abc", maxBytes: 0), "")
    }

    func testTruncate_asciiMidString_cutsExactly() {
        XCTAssertEqual(DocumentTextExtractor.truncateToUTF8Bytes("abcdef", maxBytes: 3), "abc")
    }

    func testTruncate_multiByteCharAtBoundary_snapsBackToCharacter() {
        // "aé": a=1 byte, é=2 bytes (3 total). Cutting at 2 bytes lands mid-é →
        // snaps back to the "a" boundary.
        XCTAssertEqual(DocumentTextExtractor.truncateToUTF8Bytes("aé", maxBytes: 2), "a")
    }

    func testTruncate_splittingTwoByteChar_snapsToEmpty() {
        // "é" is 2 bytes; a 1-byte cap can't fit any whole character.
        let out = DocumentTextExtractor.truncateToUTF8Bytes("é", maxBytes: 1)
        XCTAssertEqual(out, "")
        XCTAssertLessThanOrEqual(out.utf8.count, 1)
    }

    func testTruncate_emojiZWJSequence_neverExceedsCapAndStaysOnBoundary() {
        // ZWJ family emoji is one grapheme spanning many bytes; any sub-cap cut
        // must snap to a whole-Character boundary and never exceed the cap.
        let emoji = "👨‍👩‍👧"
        for cap in [1, 4, 8, 12] {
            let out = DocumentTextExtractor.truncateToUTF8Bytes(emoji, maxBytes: cap)
            XCTAssertLessThanOrEqual(out.utf8.count, cap, "cap=\(cap)")
            // Output must be a prefix of the original (whole graphemes only).
            XCTAssertTrue(emoji.hasPrefix(out), "cap=\(cap): output must be a grapheme prefix, got \(out)")
        }
    }
}
