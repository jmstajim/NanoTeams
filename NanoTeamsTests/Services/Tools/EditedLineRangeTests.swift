import XCTest
@testable import NanoTeams

/// Corner cases for the pure span computation behind `edit_file`'s reported line numbers.
///
/// The number's whole purpose is to be usable in `read_lines`, so the decisive tests here
/// are the ones about the LINE MODEL (`.newlines`, seven separators) rather than about
/// arithmetic — see `EditFileLineRangeTests` for the round trip that proves usability
/// end-to-end.
nonisolated final class EditedLineRangeTests: XCTestCase {

    private func span(_ before: String, _ after: String) -> EditedLineRange.Span? {
        EditedLineRange.compute(before: before, after: after)
    }

    // MARK: - No span to report

    /// RED: delete the `before != after` guard → this fires (reports a span for an
    /// unchanged file).
    ///
    /// Not a defensive case: the whitespace-tolerant tiers can match a window and splice
    /// back bytes equal to what was already there, which `EditFileTool` reports with an
    /// explicit "the edit left the file unchanged" warning. Naming a line here would
    /// contradict that warning in the same envelope.
    func testIdenticalContent_hasNoSpan() {
        XCTAssertNil(span("a\nb\nc", "a\nb\nc"))
        XCTAssertNil(span("", ""))
    }

    // MARK: - The separator-terminates-its-line rule

    /// RED: drop the `endsWithSeparator` subtraction → this fires with `2-3`.
    ///
    /// Inserting a whole line is the commonest edit there is. Its changed region ends ON a
    /// separator, and counting that separator as opening another line makes the span name
    /// the untouched line that merely got pushed down.
    func testWholeLineInsertion_occupiesExactlyTheInsertedLine() {
        let s = span("a\nc\n", "a\nb\nc\n")
        XCTAssertEqual(s, .init(startLine: 2, endLine: 2))
    }

    func testBlankLineInsertion_occupiesOneLine() {
        let s = span("a\nb\n", "a\n\nb\n")
        XCTAssertEqual(s, .init(startLine: 2, endLine: 2))
    }

    func testMultiLineInsertion_spansOnlyTheInsertedLines() {
        let s = span("a\nz\n", "a\np\nq\nr\nz\n")
        XCTAssertEqual(s, .init(startLine: 2, endLine: 4))
    }

    // MARK: - Substitution, deletion, boundaries

    func testInLineSubstitution_isOneLine() {
        let s = span("alpha\nbeta\ngamma\n", "alpha\nBETA\ngamma\n")
        XCTAssertEqual(s, .init(startLine: 2, endLine: 2))
    }

    /// A deletion leaves no changed region in the new file, so the span collapses onto the
    /// line the removal happened on — honest, and deliberately lossy: removing forty lines
    /// and removing one character both report a single line. `replacements_made` and the
    /// file itself carry the magnitude.
    func testWholeLineDeletion_collapsesOntoTheLineItHappenedOn() {
        let s = span("a\nb\nc\n", "a\nc\n")
        XCTAssertEqual(s, .init(startLine: 2, endLine: 2))
    }

    func testEditOnTheFirstLine_startsAtOne() {
        let s = span("a\nb\n", "A\nb\n")
        XCTAssertEqual(s, .init(startLine: 1, endLine: 1))
    }

    func testAppendAtEOF_withTrailingNewline() {
        let s = span("a\nb\n", "a\nb\nc\n")
        XCTAssertEqual(s, .init(startLine: 3, endLine: 3))
    }

    func testAppendAtEOF_withoutTrailingNewline_extendsTheLastLine() {
        let s = span("a\nb", "a\nb-more")
        XCTAssertEqual(s, .init(startLine: 2, endLine: 2))
    }

    func testFromEmptyFile_startsAtLineOne() {
        XCTAssertEqual(span("", "hello\n")?.startLine, 1)
    }

    func testToEmptyFile_startsAtLineOne() {
        XCTAssertEqual(span("hello\n", ""), .init(startLine: 1, endLine: 1))
    }

    // MARK: - The line model — this is the point of the type

    /// RED: swap `CharacterSet.newlines` for a `scalar == "\n"` test → this fires.
    ///
    /// Measured on macOS 26: `"a\r\nb\r\nc".components(separatedBy: .newlines)` yields FIVE
    /// components (CR and LF are separate separators, so an empty line sits between each
    /// pair), while splitting on `"\n"` yields three. `read_lines` uses the former, and
    /// `FileWriteHandlers`' own internal line arrays use the latter — so counting in the
    /// handler's model would print a number that lands on the wrong line in the tool the
    /// reader would use next.
    func testCRLF_countsInTheReadLinesModel_notTheHandlersOwn() {
        let before = "a\r\nb\r\nc"
        let after = "a\r\nB\r\nc"
        // `.newlines` numbering: a=1, ""=2, b=3, ""=4, c=5 → the change is on line 3.
        XCTAssertEqual(span(before, after), .init(startLine: 3, endLine: 3))

        // Cross-check against the very expression `read_lines` evaluates, so this test
        // cannot drift from the tool it exists to agree with.
        let lines = after.components(separatedBy: .newlines)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[2], "B")
    }

    func testBareCR_isASeparator() {
        XCTAssertEqual(span("a\rb\rc", "a\rB\rc"), .init(startLine: 2, endLine: 2))
    }

    func testUnicodeLineSeparator_isASeparator() {
        XCTAssertEqual(span("a\u{2028}b", "a\u{2028}B"), .init(startLine: 2, endLine: 2))
    }

    func testNextLineU0085_isASeparator() {
        XCTAssertEqual(span("a\u{0085}b", "a\u{0085}B"), .init(startLine: 2, endLine: 2))
    }

    /// The scan and `read_lines`' own expression must agree on the start line for arbitrary
    /// content — a property, not three hand-picked examples.
    func testStartLineAgreesWithTheReadLinesExpression() {
        let fixtures = [
            ("one\ntwo\nthree\n", "one\ntwo!\nthree\n"),
            ("a\r\nb\r\nc\r\n", "a\r\nb!\r\nc\r\n"),
            ("x\u{2028}y\u{2028}z", "x\u{2028}y!\u{2028}z"),
            ("🎉\nnext\n", "🎉\nNEXT\n"),
            ("e\u{301}accent\nsecond\n", "e\u{301}accent\nSECOND\n"),
        ]
        for (before, after) in fixtures {
            guard let s = span(before, after) else {
                XCTFail("expected a span for \(before.debugDescription)")
                continue
            }
            // Independently: the 1-based index of the line holding the first difference.
            let prefix = String(zip(before, after).prefix { $0 == $1 }.map(\.0))
            let expected = prefix.components(separatedBy: .newlines).count
            XCTAssertEqual(
                s.startLine, expected,
                "disagreed with read_lines' line model on \(before.debugDescription)")
        }
    }

    // MARK: - Overlap

    /// RED: bound the suffix walk at `after.startIndex` instead of the prefix end → this
    /// fires with `startLine > endLine`.
    ///
    /// Duplicating adjacent text makes the naive prefix and suffix overlap: for
    /// `"x\ny\nz\n"` → `"x\ny\ny\nz\n"` the common prefix and common suffix together exceed
    /// the shorter string.
    func testDuplicateLineInsertion_spansStayOrdered() {
        guard let s = span("x\ny\nz\n", "x\ny\ny\nz\n") else {
            return XCTFail("expected a span")
        }
        XCTAssertLessThanOrEqual(s.startLine, s.endLine)
        XCTAssertEqual(s, .init(startLine: 3, endLine: 3))
    }

    // MARK: - Characterization

    /// CHOICE: report the DIFF-MINIMAL span, not the anchor's extent — when a replacement's
    /// trailing lines are byte-identical to what they replaced, those lines are excluded.
    /// The defensible alternative is to report the whole region the anchor matched, which
    /// is what a reader of `old_text` might expect. Rejected because the anchor's extent is
    /// only available on one of `EditFileTool`'s three replacement paths, so the number
    /// would silently depend on which tolerance tier matched — invisible to whoever reads
    /// the card, and different for two edits identical in effect.
    ///
    /// FIXTURE: a three-line anchor whose last line is reproduced verbatim in the
    /// replacement, so only the first two lines actually differ.
    func testCharacterization_spanExcludesTrailingLinesThatDidNotChange() {
        let before = "head\nA\nB\nkeep\ntail\n"
        let after = "head\nA!\nB!\nkeep\ntail\n"
        XCTAssertEqual(span(before, after), .init(startLine: 2, endLine: 3))
    }
}
