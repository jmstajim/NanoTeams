import XCTest
@testable import NanoTeams

/// Characterization tests written BEFORE the byte-scanner rewrite.
///
/// These pin behavior that is real, load-bearing, and was previously unpinned. They are the
/// contract the new `LineScanner` must satisfy — not aspirational assertions. Every expectation
/// here was derived by running the CURRENT implementation, not by reasoning about what it
/// "should" do.
///
/// The two that matter most:
///
/// 1. **Line numbering.** `components(separatedBy: .newlines)` splits on SEVEN scalars
///    (`U+000A U+000B U+000C U+000D U+0085 U+2028 U+2029`), and CRLF is TWO separators, so
///    `"a\r\nX"` puts `X` on line **3**, not 2. A `\n`-only byte scanner silently renumbers every
///    CRLF file — and `SearchMatch.line` is what the model feeds straight into `read_lines`.
///
/// 2. **Case-insensitive matching.** A naive ASCII byte fold disagrees with
///    `localizedCaseInsensitiveContains` in BOTH directions on non-ASCII input. These cases are
///    why the rewrite's rule is "any line containing a byte >= 0x80 goes to ICU regardless of what
///    the byte scan said".
final class SearchExecutorCharacterizationTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!
    var resolver: SandboxPathResolver!
    let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
        resolver = SandboxPathResolver(workFolderRoot: tempDir, internalDir: internalDir)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        internalDir = nil
        resolver = nil
        try super.tearDownWithError()
    }

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func run(
        _ queries: [String],
        contextBefore: Int = 0,
        contextAfter: Int = 0,
        maxResults: Int = 20,
        offset: Int = 0
    ) throws -> SearchExecutorOutput {
        try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: queries,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            maxResults: maxResults,
            offset: offset,
            internalDir: internalDir
        ))
    }

    // MARK: - Line numbering: the seven separators

    /// `CharacterSet.newlines` = U+000A, U+000B, U+000C, U+000D, U+0085, U+2028, U+2029.
    /// Each of the six single-separator cases puts the needle on line 2.
    func testCharacterization_lineNumbering_eachSeparatorSplitsOnce() throws {
        let separators: [(name: String, scalar: String)] = [
            ("LF", "\u{000A}"),
            ("VT", "\u{000B}"),
            ("FF", "\u{000C}"),
            ("CR", "\u{000D}"),
            ("NEL", "\u{0085}"),
            ("LS", "\u{2028}"),
            ("PS", "\u{2029}"),
        ]
        for (name, sep) in separators {
            let file = "sep_\(name).txt"
            try write(file, content: "alpha\(sep)NEEDLE\(sep)omega\n")
            let out = try run(["NEEDLE"])
            let match = try XCTUnwrap(
                out.matches.first { $0.path == file },
                "\(name) (U+\(String(format: "%04X", sep.unicodeScalars.first!.value))) must split lines"
            )
            XCTAssertEqual(match.line, 2, "\(name) is a line separator, so NEEDLE is on line 2")
            XCTAssertEqual(match.text, "NEEDLE", "\(name) must not survive into the line text")
            try fm.removeItem(at: tempDir.appendingPathComponent(file))
        }
    }

    /// CRLF is the odd one out: `\r` and `\n` are each separators in their own right, so a CRLF
    /// pair yields an EMPTY line between them and the needle lands on line 3.
    ///
    /// This is the single most dangerous case for the rewrite — a `\n`-only scanner reports 2.
    func testCharacterization_lineNumbering_crlfIsTwoSeparators() throws {
        try write("crlf.txt", content: "alpha\r\nNEEDLE\r\nomega\r\n")

        let out = try run(["NEEDLE"], contextBefore: 2)
        let match = try XCTUnwrap(out.matches.first)
        XCTAssertEqual(match.line, 3, "CR and LF each split, so line 2 is the empty string between them")

        let before = try XCTUnwrap(match.context_before)
        XCTAssertEqual(before.map(\.line), [1, 2])
        XCTAssertEqual(before.map(\.text), ["alpha", ""], "line 2 is the empty part CRLF produces")
    }

    /// A trailing separator produces a final EMPTY line. `testContextAfter_atFileEnd_clamped`
    /// depends on this, and a byte scanner that stops at the last terminator would drop it.
    func testCharacterization_trailingSeparator_producesEmptyFinalLine() throws {
        try write("trail.txt", content: "NEEDLE\n")

        let out = try run(["NEEDLE"], contextAfter: 3)
        let match = try XCTUnwrap(out.matches.first)
        XCTAssertEqual(match.line, 1)

        let after = try XCTUnwrap(match.context_after, "a trailing \\n yields one empty line after")
        XCTAssertEqual(after.map(\.line), [2])
        XCTAssertEqual(after.map(\.text), [""])
    }

    /// No trailing separator: the last line is real content and there is no phantom empty line.
    func testCharacterization_noTrailingSeparator_lastLineIsContent() throws {
        try write("notrail.txt", content: "alpha\nNEEDLE")

        let out = try run(["NEEDLE"], contextAfter: 3)
        let match = try XCTUnwrap(out.matches.first)
        XCTAssertEqual(match.line, 2)
        // Non-nil but EMPTY: `contextAfter > 0` always installs an array, even when the window
        // clamps to nothing at EOF. The envelope's nil-omission happens a layer up.
        let after = try XCTUnwrap(match.context_after)
        XCTAssertTrue(after.isEmpty, "nothing follows the final line")
    }

    // MARK: - Directory order

    /// `searchDirectory` uses `contents.sorted()`, i.e. Swift's `String <` (Unicode scalar order),
    /// NOT `localizedStandardCompare`. The two genuinely disagree — localized ordering would give
    /// `["_", "a", "Ä", "B", "Z", "б"]`. `list_files` uses the localized variant; the executor
    /// must not drift into it when the walk is rewritten to prefetch resource values.
    func testCharacterization_directoryOrder_isUnicodeScalarNotLocalized() throws {
        for name in ["Z.swift", "a.swift", "Ä.swift", "_.swift", "B.swift", "б.swift"] {
            try write(name, content: "NEEDLE\n")
        }

        let out = try run(["NEEDLE"])
        XCTAssertEqual(
            out.matches.map(\.path),
            ["B.swift", "Z.swift", "_.swift", "a.swift", "Ä.swift", "б.swift"],
            "Swift String < orders by scalar: B(0x42) Z(0x5A) _(0x5F) a(0x61) Ä(0xC4) б(0x431)"
        )
    }

    // MARK: - Binary classification

    /// A zero-byte file decodes to the empty string, so it is TEXT with one empty line — not a
    /// binary. The rewrite's size gate must special-case 0 rather than treating it as unreadable.
    func testCharacterization_emptyFile_isTextNotBinary() throws {
        try write("empty.txt", content: "")
        try write("other.txt", content: "NEEDLE\n")

        let out = try run(["NEEDLE"])
        XCTAssertEqual(out.skippedBinaryCount, 0, "an empty file is not a binary")
        XCTAssertTrue(out.skipped.isEmpty, "nor is it a skipped file")
        XCTAssertEqual(out.matches.count, 1)
    }

    /// Invalid UTF-8 WITHOUT a NUL byte. Today it is classified binary only after a full read +
    /// failed decode. After the rewrite an 8 KB NUL sniff runs first — this file has no NUL, so it
    /// must still fall through to the decode and land in the same bucket.
    func testCharacterization_invalidUTF8WithoutNUL_isBinaryNotSkipped() throws {
        let url = tempDir.appendingPathComponent("bytes.txt")
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)

        let out = try run(["anything"])
        XCTAssertEqual(out.skippedBinaryCount, 1)
        XCTAssertTrue(out.skipped.isEmpty, "binaries are counted in aggregate, never listed individually")
    }

    // MARK: - Case-insensitive matching semantics

    /// The four cases where a naive ASCII byte fold disagrees with ICU. All four involve a line
    /// containing non-ASCII, which is precisely why the rewrite routes such lines to ICU
    /// unconditionally instead of trusting the byte result.
    func testCharacterization_nonASCIILines_followICUNotByteFolding() throws {
        // Byte scan would say YES (the literal bytes "cafe" are present), ICU says NO because the
        // grapheme is "é", not "e".
        try write("combining.txt", content: "cafe\u{0301}\n")
        XCTAssertTrue(try run(["cafe"]).matches.isEmpty,
            "'cafe' + combining acute is not a match for 'cafe' under ICU")

        // Byte scan would say NO, ICU says YES because full case folding maps ß to ss.
        try write("eszett.txt", content: "stra\u{00DF}e\n")
        XCTAssertEqual(try run(["strasse"]).matches.count, 1,
            "ICU full case folding expands ß to ss")

        // Byte scan would say NO, ICU says YES: U+212A KELVIN SIGN folds to 'k'.
        try write("kelvin.txt", content: "\u{212A}elvin\n")
        XCTAssertEqual(try run(["kelvin"]).matches.count, 1,
            "U+212A folds to 'k' under ICU")

        // A non-ASCII needle legitimately matches ASCII content, so a non-ASCII query can never
        // take the byte fast path.
        try write("plain.txt", content: "kelvin\n")
        XCTAssertEqual(try run(["\u{212A}elvin"]).matches.count, 2,
            "matches both the ASCII file and the U+212A one")
    }

    /// The ASCII fold must be `A-Z -> a-z` only. A naive `| 0x20` also maps `[`->`{`, `@`->backtick,
    /// `^`->`~` and NUL->space, which in a code search means `foo{` would match `foo[`.
    func testCharacterization_asciiPunctuation_isNotCaseFolded() throws {
        try write("brackets.swift", content: "let a = arr[0]\n")

        XCTAssertTrue(try run(["arr{0}"]).matches.isEmpty,
            "'[' and '{' differ by 0x20 but are distinct characters")
        XCTAssertTrue(try run(["@"]).matches.isEmpty)
        XCTAssertTrue(try run(["^"]).matches.isEmpty)
        XCTAssertEqual(try run(["ARR[0]"]).matches.count, 1,
            "letters DO fold, so the query matches case-insensitively")
    }

    /// An empty needle matches nothing — `NSString` returns `NSNotFound` for an empty search
    /// string. A byte scanner returns "found at offset 0" unless it guards this explicitly.
    /// Reached via a MIXED query array, which is not list mode.
    func testCharacterization_emptyNeedleInMixedArray_matchesNothing() throws {
        try write("a.swift", content: "alpha\nbeta\n")

        let out = try run(["beta", ""])
        XCTAssertEqual(out.matches.count, 1, "only the non-empty query matches")
        XCTAssertEqual(out.matches[0].text, "beta")
    }

    // MARK: - Result budget

    /// `max_results` is now the ONLY limit on how many matches come back.
    ///
    /// Before the rewrite a hardcoded 40-line budget (`maxMatchLines`) stopped the walk first: at
    /// context 2+3 each match cost ~6 lines, so this same call returned **8** matches and reported
    /// `truncated`, leaving 12 of the 20 requested slots unused.
    func testMaxResults_isTheOnlyLimitOnCount() throws {
        let lines = (1...40).map { "NEEDLE \($0)" }.joined(separator: "\n")
        try write("many.swift", content: lines + "\n")

        let out = try run(["NEEDLE"], contextBefore: 2, contextAfter: 3, maxResults: 20)
        XCTAssertEqual(out.matches.count, 20, "the page size governs, not a line budget")
        XCTAssertTrue(out.truncated, "40 matches exist, so more pages remain")
    }

    /// Context width no longer changes the number of matches. Previously the same corpus and the
    /// same `maxResults` returned 20 matches at context 0 and only 4 at context 8+8 — raising a
    /// display setting silently shrank the result set.
    func testContextWidth_doesNotChangeResultCount() throws {
        let lines = (1...40).map { "NEEDLE \($0)" }.joined(separator: "\n")
        try write("many.swift", content: lines + "\n")

        let noContext = try run(["NEEDLE"], maxResults: 20)
        let wideContext = try run(["NEEDLE"], contextBefore: 8, contextAfter: 8, maxResults: 20)

        XCTAssertEqual(noContext.matches.count, 20)
        XCTAssertEqual(wideContext.matches.count, 20, "context is presentation, not budget")
        XCTAssertEqual(noContext.matches.map(\.line), wideContext.matches.map(\.line),
                       "and it selects the same matches")
    }

    // MARK: - Pagination

    /// Consecutive pages partition the result set: no overlap, no gap.
    func testPagination_pagesPartitionTheResultSet() throws {
        let lines = (1...40).map { "NEEDLE \($0)" }.joined(separator: "\n")
        try write("many.swift", content: lines + "\n")

        let whole = try run(["NEEDLE"], maxResults: 20)
        let firstHalf = try run(["NEEDLE"], maxResults: 10)
        let secondHalf = try run(["NEEDLE"], maxResults: 10, offset: 10)

        XCTAssertEqual(firstHalf.matches.map(\.line) + secondHalf.matches.map(\.line),
                       whole.matches.map(\.line),
                       "offset 0..10 plus offset 10..20 reconstructs offset 0..20 exactly")
    }

    /// `total_matches` is reported only when it is actually known — the walk ran out of corpus
    /// before it ran out of page. Otherwise the number would be "how many we bothered to
    /// collect", which is not a total.
    func testPagination_totalIsExactOnlyWhenTheWalkCompleted() throws {
        let lines = (1...7).map { "NEEDLE \($0)" }.joined(separator: "\n")
        try write("few.swift", content: lines + "\n")

        let complete = try run(["NEEDLE"], maxResults: 50)
        XCTAssertEqual(complete.totalMatches, 7)
        XCTAssertFalse(complete.truncated)

        let partial = try run(["NEEDLE"], maxResults: 3)
        XCTAssertNil(partial.totalMatches, "more matches exist beyond the page")
        XCTAssertTrue(partial.truncated)
    }

    /// Paging past the end is an empty page, not an error.
    func testPagination_offsetBeyondEnd_returnsEmptyPage() throws {
        try write("a.swift", content: "NEEDLE\n")

        let out = try run(["NEEDLE"], maxResults: 10, offset: 500)
        XCTAssertTrue(out.matches.isEmpty)
        XCTAssertFalse(out.truncated)
    }

    // MARK: - Argument hygiene

    /// `max_results: Int.max` used to CRASH the process: `perQueryCap` computed
    /// `Int(Double(Int.max).rounded(.up))`, and `Double(Int.max)` rounds to exactly 2^63 — one
    /// past `Int.max` — which traps. A trap is not catchable by `ToolErrorHandler`, so a single
    /// malformed tool call took the app down.
    func testArgumentHygiene_intMaxResults_isClampedNotCrashing() throws {
        try write("a.swift", content: "NEEDLE\n")

        let out = try run(["NEEDLE"], maxResults: Int.max)
        XCTAssertEqual(out.matches.count, 1)
    }

    /// `max_results: 0` used to return an empty result with `truncated: false` — a silent zero
    /// indistinguishable from "nothing matched". Negative values did the same and additionally
    /// reported `truncated: true` on the empty result.
    func testArgumentHygiene_zeroAndNegativeMaxResults_areClampedToOne() throws {
        try write("a.swift", content: "NEEDLE one\nNEEDLE two\n")

        for value in [0, -5] {
            let out = try run(["NEEDLE"], maxResults: value)
            XCTAssertEqual(out.matches.count, 1, "clamped to a one-result page (max_results: \(value))")
            XCTAssertTrue(out.truncated, "and the second match is honestly reported as more")
        }
    }

    /// Negative offsets clamp to 0 rather than shifting the page backwards.
    func testArgumentHygiene_negativeOffset_isClampedToZero() throws {
        try write("a.swift", content: "NEEDLE one\nNEEDLE two\n")

        let out = try run(["NEEDLE"], maxResults: 10, offset: -3)
        XCTAssertEqual(out.matches.count, 2)
    }

    /// The page COUNT is unbounded — only the page SIZE is capped — so `offset` accepts
    /// arbitrarily large values. That makes `offset + maxResults` an overflow site: at
    /// `offset: Int.max` the addition TRAPS, and a trap is not catchable by `ToolErrorHandler`,
    /// so one malformed tool call takes the app down. Same class as the `max_results: Int.max`
    /// crash, reachable through the other argument.
    func testArgumentHygiene_intMaxOffset_doesNotCrash() throws {
        try write("a.swift", content: "NEEDLE one\nNEEDLE two\n")

        let out = try run(["NEEDLE"], maxResults: 10, offset: Int.max)
        XCTAssertTrue(out.matches.isEmpty, "paging past the end is an empty page, not a crash")
        XCTAssertFalse(out.truncated)
    }

    /// A large-but-sane offset still pages correctly rather than being clamped to something small
    /// — "infinitely many pages" has to actually hold.
    func testPagination_veryLargeOffset_isHonouredNotClamped() throws {
        let lines = (1...50).map { "NEEDLE \($0)" }.joined(separator: "\n")
        try write("many.swift", content: lines + "\n")

        let out = try run(["NEEDLE"], maxResults: 10, offset: 45)
        XCTAssertEqual(out.matches.count, 5, "matches 46...50")
        XCTAssertEqual(out.matches.first?.line, 46)
    }

    /// The page-size ceiling the tool DESCRIPTION advertises must be the ceiling the runtime
    /// ENFORCES, and the Settings stepper must not offer a value outside it.
    ///
    /// These had already drifted: Settings capped at 500, the schema said "max 500", and the
    /// executor clamped at 1000 — so a model asking for 800 got 800 while being told it could
    /// not. A number stated to the LLM is a contract; three copies of it is three chances to lie.
    func testArgumentHygiene_advertisedPageCeiling_matchesTheEnforcedOne() throws {
        XCTAssertEqual(ExploratorySearchPayload.maxAllowedResults, AppDefaults.searchMaxResultsMax,
                       "runtime clamp and Settings range must be one number")

        let description = try XCTUnwrap(
            SearchTool.schema.parameters.properties?["max_results"]?.description)
        XCTAssertTrue(
            description.contains(String(AppDefaults.searchMaxResultsMax)),
            "the schema tells the model the ceiling; it must be the real one — got: \(description)"
        )

        // And it is actually enforced end-to-end.
        try write("many.swift", content: String(repeating: "NEEDLE\n", count: 600))
        let out = try run(["NEEDLE"], maxResults: 900)
        XCTAssertEqual(out.matches.count, AppDefaults.searchMaxResultsMax)
    }

    // MARK: - Binary gate

    /// Deliberate divergence introduced with the 8 KB NUL sniff: a file that is valid UTF-8 but
    /// carries a literal NUL early on now classifies as binary. Same heuristic git and ripgrep
    /// use — it trades a freak case for not reading every `.mp4` in the tree in full.
    func testBinaryGate_utf8FileWithEmbeddedNUL_classifiedAsBinary() throws {
        try write("weird.txt", content: "NEEDLE\u{0000}more text\n")

        let out = try run(["NEEDLE"])
        XCTAssertTrue(out.matches.isEmpty)
        XCTAssertEqual(out.skippedBinaryCount, 1)
    }

    /// An oversize file is REPORTED, not silently dropped and not miscounted as a binary blob.
    func testBinaryGate_oversizeFile_surfacesAsSkippedNotBinary() throws {
        let url = tempDir.appendingPathComponent("huge.txt")
        // One byte past the cap, all printable so nothing else could classify it as binary.
        let data = Data(repeating: UInt8(ascii: "a"), count: SearchExecutor.maxSearchableFileBytes + 1)
        try data.write(to: url)

        let out = try run(["NEEDLE"])
        XCTAssertEqual(out.skippedBinaryCount, 0, "an oversize text file is not a binary")
        XCTAssertEqual(out.skipped.count, 1)
        XCTAssertEqual(out.skipped[0].path, "huge.txt")
        XCTAssertTrue(out.skipped[0].reason.contains("over the"), out.skipped[0].reason)
    }

    /// A text file with an unfamiliar extension stays searchable. This is why the gate sniffs
    /// content instead of copying the indexer's extension allowlist.
    func testBinaryGate_unknownExtensionWithTextContent_isStillSearched() throws {
        try write("script.zig", content: "const NEEDLE = 1;\n")
        try write("Makefile", content: "NEEDLE: ; echo hi\n")

        let out = try run(["NEEDLE"])
        XCTAssertEqual(Set(out.matches.map(\.path)), ["script.zig", "Makefile"])
    }
}
