import XCTest

@testable import NanoTeams

// The remaining reachable surface of `ClipboardCaptureService`, on top of what
// `ClipboardCaptureTests` (result/parse/struct shapes), `ClipboardAndAccessibilityTests`
// (the U+200B sentinel) and `PlatformDefectFixTests` (the `lineRange` clamp regression)
// already pin.
//
// The orchestration around them — `captureSelection`, `requestAccessibilityIfNeeded`,
// `detectSourceContext`, the poll, and the snapshot/restore pair — moved to
// `ClipboardCaptureFlowCoverageTests` once `ClipboardCaptureEnvironment` made the pasteboard, the
// ⌘C, the trust check and the AX reads injectable. The list of "deliberately not exercised" paths
// that used to sit here named `restorePasteboard` among them; it was hiding two ways to destroy a
// user's clipboard, both of which that file now pins.
//
// What is left here is `enrichText` — the function that decides the PATH the model is handed —
// plus the boundary behaviour of `lineRange` and `SourceContext.parse`.

// MARK: - enrichText: the path handed to the model

/// `enrichText` produces the `// Source: <path>:<lines>` header that rides into the LLM prompt.
/// That path is copied VERBATIM by the model into `read_file` / `edit_file`, whose only accepted
/// base is the work-folder root (CLAUDE.md, path-base invariant) — so a wrong path here is not
/// cosmetic, it is a tool call that cannot resolve.
final class ClipboardEnrichTextPathTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private func header(filePath: String, root: String,
                        start: Int? = nil, end: Int? = nil) -> String {
        // `fileName` used to be a stored field this helper could override independently of
        // `filePath`; it is now derived from the path, so there is nothing left to diverge.
        let ctx = SourceContext(filePath: filePath, lineStart: start, lineEnd: end)
        let enriched = ClipboardCaptureService.enrichText(
            "BODY", with: ctx, relativeTo: URL(fileURLWithPath: root))
        return SourceContext.parse(enriched)?.source ?? "<unparseable>"
    }

    // MARK: The ordinary case — anti-vacuity for everything below

    func testNestedFileUnderRoot_isRelativeToTheRoot() {
        XCTAssertEqual(header(filePath: "/tmp/p/Sources/App.swift", root: "/tmp/p"),
                       "Sources/App.swift")
    }

    func testFileDirectlyUnderRoot_isTheBareName() {
        XCTAssertEqual(header(filePath: "/tmp/p/App.swift", root: "/tmp/p"), "App.swift")
    }

    /// `URL.path` never carries a trailing slash except for "/" itself, so the filesystem root is
    /// the one root whose relative paths must not start with a separator.
    func testFilesystemRootAsWorkFolder_yieldsASlashlessRelativePath() {
        let source = header(filePath: "/tmp/p/App.swift", root: "/")
        XCTAssertEqual(source, "tmp/p/App.swift")
        XCTAssertFalse(source.hasPrefix("/"), "a leading separator would read as absolute")
    }

    // MARK: The defect — gate and relativizer disagreed about the same path

    /// **REGRESSION.** The gate that lets `enrichText` run (`SandboxPathResolver.isWithin`, called
    /// from `detectSourceContext`) compares STANDARDIZED path components, so it accepts a path
    /// carrying `.`/`..` segments. The relativizer used a raw `hasPrefix` on the unnormalized
    /// string, which happily matched and then emitted those segments INTO the header.
    ///
    /// The result is not merely ugly: `SandboxPathResolver.resolveFileURL` throws
    /// `parentTraversalNotAllowed` for any relative path containing `..`, so the model's very
    /// first `read_file` on the path we handed it is rejected outright.
    ///
    /// `kAXDocumentAttribute` is whatever the source editor chooses to report; nothing normalizes
    /// it before it reaches here.
    func testUnnormalizedFilePath_isNormalizedInsteadOfLeakingDotDot() {
        let source = header(filePath: "/tmp/p/Sources/./sub/../App.swift", root: "/tmp/p")

        XCTAssertEqual(source, "Sources/App.swift")
        XCTAssertFalse(source.contains(".."),
                       "a relative path with `..` is rejected by SandboxPathResolver outright")
    }

    /// The same disagreement in the other operand. A root URL that standardizes (so the gate
    /// accepts the file) but whose raw `.path` differs made the string prefix miss entirely, and
    /// the miss fell back to the bare file NAME — naming `<root>/App.swift` for a file that lives
    /// at `<root>/Sources/App.swift`. Plausible, resolvable, and pointing at the wrong file or at
    /// nothing at all.
    func testUnnormalizedRoot_stillRelativizesRatherThanFallingBackToTheBareName() {
        XCTAssertEqual(header(filePath: "/tmp/p/Sources/App.swift", root: "/tmp/p/sub/.."),
                       "Sources/App.swift")
    }

    /// The two implementations must agree, not merely both be plausible: whatever the gate admits,
    /// the header must relativize. Asserted as a property over the shapes that normalization
    /// touches, so a future rewrite of either side cannot re-open the gap for a shape nobody
    /// thought to enumerate.
    func testEveryPathTheGateAdmits_relativizesRatherThanDegrading() {
        let root = URL(fileURLWithPath: "/tmp/p")
        let candidates = [
            "/tmp/p/Sources/App.swift",
            "/tmp/p/./Sources/App.swift",
            "/tmp/p/Sources/./App.swift",
            "/tmp/p/Sources/sub/../App.swift",
            "/tmp/p/x/../Sources/App.swift",
        ]

        for path in candidates {
            let file = URL(fileURLWithPath: path)
            XCTAssertTrue(SandboxPathResolver.isWithin(candidate: file, container: root),
                          "fixture must be gate-admitted: \(path)")

            let source = header(filePath: path, root: "/tmp/p")
            XCTAssertEqual(source, "Sources/App.swift", "for \(path)")
        }
    }

    /// A genuine miss must stay HONEST. CLAUDE.md's rule for any "path from a base": a
    /// non-contained path is returned ABSOLUTE, never truncated — an absolute path preserves the
    /// file's provenance and `SandboxPathResolver` accepts one inside the sandbox, whereas the
    /// bare name manufactures a plausible reference to a file that was never there.
    func testPathOutsideTheRoot_isReportedAbsolute_notAsABareFileName() {
        let source = header(filePath: "/elsewhere/deep/App.swift", root: "/tmp/p")

        XCTAssertEqual(source, "/elsewhere/deep/App.swift")
        XCTAssertNotEqual(source, "App.swift", "a truncated path fabricates <root>/App.swift")
    }

    /// `URL(string: "file://")` IS a file URL and its `.path` is "" — so `detectSourceContext` can
    /// hand an empty path down. `URL(fileURLWithPath: "")` resolves to the process's CURRENT
    /// DIRECTORY, which would relativize the clip against wherever the app happens to be running
    /// from. Degenerate in, degenerate out — but never CWD-dependent.
    func testEmptyFilePath_doesNotRelativizeAgainstTheCurrentDirectory() {
        let ctx = SourceContext(filePath: "",lineStart: nil, lineEnd: nil)
        let enriched = ClipboardCaptureService.enrichText(
            "BODY", with: ctx, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))

        XCTAssertEqual(SourceContext.parse(enriched)?.source, "")
    }

    // MARK: Path content that must survive verbatim

    func testNonASCIIPathComponents_arePreserved() {
        XCTAssertEqual(header(filePath: "/tmp/p/Исходники/Приложение.swift", root: "/tmp/p"),
                       "Исходники/Приложение.swift")
    }

    func testPathWithSpacesAndEmoji_isPreserved() {
        XCTAssertEqual(header(filePath: "/tmp/p/My Docs/🚀 notes.md", root: "/tmp/p"),
                       "My Docs/🚀 notes.md")
    }

    func testDeeplyNestedPath_keepsEverySegment() {
        XCTAssertEqual(header(filePath: "/tmp/p/a/b/c/d/e/f.swift", root: "/tmp/p"),
                       "a/b/c/d/e/f.swift")
    }
}

// MARK: - enrichText: the header the readers parse

/// The header's shape is a contract with every clip reader (`SourceContext.parse`,
/// `AnswerTextBuilder.clipSections`, `ClipCellPresentation`, the activity feed). Nothing pinned
/// writer↔reader agreement before: the existing round-trip test hand-writes the prefix rather than
/// calling the writer, so a writer-side change would leave it green while every reader stopped
/// recognising real clips.
final class ClipboardEnrichTextHeaderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private func enrich(_ body: String, start: Int?, end: Int?,
                        filePath: String = "/tmp/p/App.swift") -> String {
        ClipboardCaptureService.enrichText(
            body,
            with: SourceContext(filePath: filePath,lineStart: start, lineEnd: end),
            relativeTo: URL(fileURLWithPath: "/tmp/p"))
    }

    // MARK: Writer ↔ reader

    /// THE cross-surface pin: what the writer emits, the reader must accept — and hand back both
    /// halves intact.
    func testWriterOutput_parsesBackThroughSourceContextParse() {
        let enriched = enrich("let x = 1", start: 42, end: 51)
        let parsed = SourceContext.parse(enriched)

        XCTAssertEqual(parsed?.source, "App.swift:42-51")
        XCTAssertEqual(parsed?.body, "let x = 1")
    }

    /// Clips are code: the body must come back byte-for-byte through the writer as well as the
    /// reader. Indentation carries meaning and a writer-side trim would silently rewrite the
    /// snippet the model reasons about.
    func testWriterPreservesTheBodyVerbatim_indentationBlankLinesAndTrailingNewline() {
        let body = "\n    if x {\n\n        return\n    }\n"
        XCTAssertEqual(SourceContext.parse(enrich(body, start: 1, end: 5))?.body, body)
    }

    func testCRLFBody_survivesTheRoundTrip() {
        let body = "one\r\ntwo\r\n"
        XCTAssertEqual(SourceContext.parse(enrich(body, start: 1, end: 2))?.body, body)
    }

    /// The one shape the writer produces that the reader REJECTS, which is exactly why
    /// `captureSelection` guards on `!text.isEmpty` before enriching. Pinning it keeps that guard
    /// from being "cleaned up" as redundant.
    func testEmptyBody_producesAHeaderTheReaderRefuses() {
        XCTAssertNil(SourceContext.parse(enrich("", start: 1, end: 1)),
                     "an empty body is why the caller must not enrich empty text")
    }

    /// Re-clipping already-enriched text nests the headers. The OUTER one must win and the inner
    /// one must survive inside the body — losing either would silently re-attribute the snippet.
    func testAlreadyEnrichedBody_nestsRatherThanBeingRewritten() {
        let inner = enrich("let x = 1", start: 7, end: 7)
        let outer = ClipboardCaptureService.enrichText(
            inner,
            with: SourceContext(filePath: "/tmp/p/Other.swift",lineStart: 1, lineEnd: 2),
            relativeTo: URL(fileURLWithPath: "/tmp/p"))

        let parsed = SourceContext.parse(outer)
        XCTAssertEqual(parsed?.source, "Other.swift:1-2")
        XCTAssertEqual(parsed?.body, inner)
    }

    // MARK: Header shape

    /// The sentinel is what tells a real header from a user's `// Source:` comment. It has to be
    /// the very first scalar — `parse` anchors on `hasPrefix`.
    func testHeaderStartsWithTheZeroWidthSpaceSentinel() {
        let enriched = enrich("x", start: 1, end: 1)
        XCTAssertTrue(enriched.hasPrefix("\u{200B}// Source: "), "got: \(enriched.debugDescription)")
    }

    func testHeaderIsTerminatedByExactlyOneNewline() {
        let enriched = enrich("x", start: 1, end: 1)
        XCTAssertEqual(enriched, "\u{200B}// Source: App.swift:1\nx")
    }

    // MARK: Line-info formatting

    func testDistinctStartAndEnd_rendersARange() {
        XCTAssertEqual(SourceContext.parse(enrich("x", start: 10, end: 20))?.source, "App.swift:10-20")
    }

    func testEqualStartAndEnd_rendersASingleLine() {
        XCTAssertEqual(SourceContext.parse(enrich("x", start: 10, end: 10))?.source, "App.swift:10")
    }

    /// An inverted range is garbage (`lineRange` cannot produce one, but `SourceContext` does not
    /// enforce it) and must collapse to the start rather than render `:20-10`, which reads as a
    /// backwards selection to anything downstream.
    func testInvertedRange_collapsesToTheStartLine() {
        XCTAssertEqual(SourceContext.parse(enrich("x", start: 20, end: 10))?.source, "App.swift:20")
    }

    func testStartWithoutEnd_rendersASingleLine() {
        XCTAssertEqual(SourceContext.parse(enrich("x", start: 5, end: nil))?.source, "App.swift:5")
    }

    /// An end with no start has no anchor to render, so the header carries the path alone rather
    /// than a half-range.
    func testEndWithoutStart_rendersNoLineInfo() {
        XCTAssertEqual(SourceContext.parse(enrich("x", start: nil, end: 12))?.source, "App.swift")
    }

    func testNoLineInfo_rendersThePathAlone() {
        XCTAssertEqual(SourceContext.parse(enrich("x", start: nil, end: nil))?.source, "App.swift")
    }

    /// `detectLineRange` returns 1-based lines, so line 1 must render as `:1` — not be mistaken
    /// for "no information" by a truthiness check.
    func testLineOne_isRenderedNotSwallowed() {
        XCTAssertEqual(SourceContext.parse(enrich("x", start: 1, end: 1))?.source, "App.swift:1")
    }

    /// Neither endpoint is validated upstream; a zero or negative line must still round-trip as
    /// text rather than corrupt the header's shape.
    func testNonPositiveLines_stillProduceAParseableHeader() {
        XCTAssertEqual(SourceContext.parse(enrich("x", start: 0, end: 0))?.source, "App.swift:0")
        XCTAssertEqual(SourceContext.parse(enrich("x", start: -3, end: -1))?.source, "App.swift:-3--1")
    }
}

// MARK: - lineRange: boundaries not covered by the clamp regression

/// `ClipboardLineRangeClampTests` pins the negative/overflow crash and the CRLF + non-BMP
/// counting. These are the remaining boundaries of the same seam: degenerate texts, offsets that
/// land exactly on a separator, and the line terminators it deliberately does NOT count.
final class ClipboardLineRangeBoundaryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    private func range(_ text: String, _ location: Int, _ length: Int) -> (start: Int, end: Int) {
        ClipboardCaptureService.lineRange(inUTF16Text: text, location: location, length: length)
    }

    // MARK: Degenerate texts

    /// Lines are 1-based, so even "no text at all" is line 1 — never 0, which downstream renders
    /// as `:0` and reads as a missing value.
    func testEmptyText_isLineOneAtBothEnds() {
        let r = range("", 0, 0)
        XCTAssertEqual(r.start, 1)
        XCTAssertEqual(r.end, 1)
    }

    func testEmptyTextWithGarbageOffsets_doesNotTrap() {
        XCTAssertEqual(range("", 99, 99).start, 1)
        XCTAssertEqual(range("", -99, -99).end, 1)
    }

    /// `Int.min` is the one value where negation traps and `max(_, 0)` is the only thing standing
    /// between it and the offset arithmetic.
    func testIntMinOperands_doNotTrap() {
        XCTAssertEqual(range("a\nb", Int.min, 1).start, 1)
        XCTAssertEqual(range("a\nb", 2, Int.min).start, 2, "offset 2 is on the second line")
        XCTAssertEqual(range("a\nb", Int.min, Int.min).end, 1)
    }

    func testIntMaxOperands_clampToTheEndOfTheText() {
        let r = range("a\nb\nc", Int.max, Int.max)
        XCTAssertEqual(r.start, 3)
        XCTAssertEqual(r.end, 3)
    }

    func testZeroLength_collapsesToTheStartLine() {
        let r = range("alpha\nbravo", 6, 0)
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 2)
    }

    /// Newline-only text is the densest possible input; an off-by-one in the reduce shows up here
    /// and nowhere else.
    func testNewlineOnlyText_countsEverySeparator() {
        let r = range("\n\n\n", 0, 3)
        XCTAssertEqual(r.start, 1)
        XCTAssertEqual(r.end, 4, "three separators open a fourth (empty) line")
    }

    // MARK: Offsets on and past the separator

    /// An offset AT the separator is still the line the separator terminates; only an offset PAST
    /// it moves on. This is the off-by-one the whole seam turns on.
    func testOffsetOnTheSeparator_staysOnTheLineItTerminates() {
        XCTAssertEqual(range("ab\ncd", 2, 0).start, 1, "offset 2 is the \\n itself")
        XCTAssertEqual(range("ab\ncd", 3, 0).start, 2, "offset 3 is past it")
    }

    func testOffsetExactlyAtTheTextLength_isTheLastLine() {
        XCTAssertEqual(range("ab\ncd", 5, 0).start, 2)
    }

    /// A trailing newline opens a real (empty) last line; an editor's caret can sit there.
    func testOffsetAfterATrailingNewline_isTheEmptyLastLine() {
        XCTAssertEqual(range("ab\n", 3, 0).start, 2)
    }

    // MARK: Terminators deliberately NOT counted

    /// Documented limit: a classic-Mac CR-only document reports every line as 1. Counting CR too
    /// would double-count CRLF, and no editor this feature captures from writes CR-only.
    /// Characterization, so the day it stops being acceptable is a red test rather than a surprise.
    func testCROnlyText_reportsLineOne_documentedLimit() {
        let r = range("a\rb\rc", 4, 1)
        XCTAssertEqual(r.start, 1)
        XCTAssertEqual(r.end, 1)
    }

    /// Same rule for the Unicode separators. Editors number lines by `\n`, so U+2028/U+2029 riding
    /// inside a line is the right answer — but it is a CHOICE, so it is pinned.
    func testUnicodeLineSeparators_areNotCountedAsLines() {
        XCTAssertEqual(range("a\u{2028}b", 2, 1).start, 1)
        XCTAssertEqual(range("a\u{2029}b", 2, 1).start, 1)
    }

    /// A lone CR inside an otherwise LF document must not add a line — the CR belongs to the line
    /// its following LF terminates.
    func testMixedCRAndCRLF_countsOnlyTheLineFeeds() {
        // "a\r\nb\rc\nd" — two line feeds, so three lines.
        let r = range("a\r\nb\rc\nd", 0, 8)
        XCTAssertEqual(r.start, 1)
        XCTAssertEqual(r.end, 3)
    }

    // MARK: UTF-16 vs Character counting

    /// A regional-indicator pair is ONE Character and FOUR UTF-16 code units — twice the drift of
    /// the single emoji the clamp suite uses, so an implementation that indexed the Swift String
    /// by Character would not merely misplace the line, it would run off the end.
    func testRegionalIndicatorPair_offsetsAreUTF16CodeUnits() {
        // "🇺🇸" is 4 units, so "\n" is at offset 4 and "x" at 5.
        let r = range("🇺🇸\nx", 5, 1)
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 2)
    }

    /// A combining mark is a second code unit inside one Character; the newline after it sits at
    /// offset 2, not 1.
    func testCombiningMark_shiftsTheSeparatorOffset() {
        XCTAssertEqual(range("e\u{0301}\nx", 3, 1).start, 2)
        XCTAssertEqual(range("e\u{0301}\nx", 2, 0).start, 1, "offset 2 is the \\n itself")
    }

    /// The clamp is against the UTF-16 length, not the Character count — with astral characters
    /// the two differ, and clamping to the smaller one would cut the last line off.
    func testClampUsesUTF16Length_notCharacterCount() {
        let text = "😀😀\nx"  // 5 Characters' worth of units: 2+2+1+1 = 6
        XCTAssertEqual(range(text, 6, 0).start, 2, "offset 6 is the end of the text, on line 2")
        XCTAssertEqual(range(text, 4, 0).start, 1, "offset 4 is the \\n itself")
    }
}

// MARK: - SourceContext.parse: remaining boundaries

/// `SourceContextParseTests` and `ClipboardSourceSentinelTests` cover the sentinel gate, the exact
/// header shape and body fidelity. These are the inputs neither reaches: alternative line
/// terminators in the header, and bodies that are present but blank.
final class ClipboardSourceContextParseBoundaryTests: XCTestCase {

    private static let header = "\u{200B}// Source: a/b.swift:1-2"

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    /// FIXED. This used to assert `nil` — the Swift-CRLF grapheme trap recorded as
    /// characterization rather than repaired, on the grounds that our own writer emits a bare LF
    /// so the shape was unreachable.
    ///
    /// That reasoning was about the WRITER; `parse` is the READER, and a reader is exactly the
    /// half that meets a clip arriving from somewhere else. Worse, a test asserting the broken
    /// result makes the defect the contract — the next person to fix it finds a red test telling
    /// them they were wrong. `firstIndex(where: \.isNewline)` matches the `\r\n` cluster (and all
    /// seven newline scalars), and `index(after:)` steps past both units.
    ///
    /// Fuller matrix — CR-only, body line endings preserved, no-body rejection — lives in
    /// `ClipboardSourceResolutionTests`.
    func testCRLFTerminatedHeader_splitsIntoSourceAndBody() {
        let parsed = SourceContext.parse("\(Self.header)\r\nlet x = 1")

        XCTAssertEqual(parsed?.source, "a/b.swift:1-2")
        XCTAssertEqual(parsed?.body, "let x = 1", "the \\r must not leak into the body")
    }

    /// The reachable neighbour, and the reason the trap above stays theoretical: the writer's own
    /// LF is never absorbed into a following `\r`, because only CR-then-LF clusters. So a body
    /// captured from a CRLF document — a selection begun at a line end — still splits correctly.
    func testWriterLFFollowedByACRLFBody_stillSplitsAtTheWriterNewline() {
        let parsed = SourceContext.parse("\(Self.header)\n\r\ntwo")

        XCTAssertEqual(parsed?.source, "a/b.swift:1-2")
        XCTAssertEqual(parsed?.body, "\r\ntwo")
    }

    /// A blank body is still a body — only a truly EMPTY one is rejected. A whitespace-only clip is
    /// a legitimate capture (an indented blank line) and dropping the attribution for it would be
    /// an unexplained hole.
    func testWhitespaceOnlyBody_parses() {
        XCTAssertEqual(SourceContext.parse("\(Self.header)\n   ")?.body, "   ")
        XCTAssertEqual(SourceContext.parse("\(Self.header)\n\n")?.body, "\n")
    }

    /// The sentinel alone is not a header: no newline means no split point.
    func testSentinelWithoutTheRestOfTheHeader_returnsNil() {
        XCTAssertNil(SourceContext.parse("\u{200B}"))
        XCTAssertNil(SourceContext.parse("\u{200B}// Source: "))
    }

    /// An empty label is degenerate but structurally valid — the split happens at the newline
    /// regardless of what precedes it, and swallowing the body would be the worse failure.
    func testEmptyLabelWithABody_parsesWithAnEmptySource() {
        let parsed = SourceContext.parse("\u{200B}// Source: \nlet x = 1")

        XCTAssertEqual(parsed?.source, "")
        XCTAssertEqual(parsed?.body, "let x = 1")
    }

    /// The label is delimited by the FIRST newline only; a body carrying further headers, colons
    /// or sentinels must not influence where the split lands.
    func testOnlyTheFirstNewlineSplits() {
        let body = "\u{200B}// Source: decoy.swift:9\nreal body\nmore"
        let parsed = SourceContext.parse("\(Self.header)\n\(body)")

        XCTAssertEqual(parsed?.source, "a/b.swift:1-2")
        XCTAssertEqual(parsed?.body, body)
    }
}
