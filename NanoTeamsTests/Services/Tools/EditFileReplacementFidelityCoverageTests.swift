import XCTest

@testable import NanoTeams

/// Pins what `edit_file` WRITES, as distinct from what it MATCHES.
///
/// `EditFileWhitespaceToleranceTests` next door covers the anchor side — which `old_text`
/// spellings still find their region. Every one of its cases passes a clean `new_text`, so the
/// replacement side was never exercised, and three defects lived there: the tool repaired the
/// anchor and then spliced the model's raw `new_text` verbatim, doubled a CR the model had
/// carried, and let an anchor's phantom trailing blank line consume the file's final newline.
/// All three write a corrupted file and report `ok:true` — the worst shape a tool result can
/// take, because the model has no reason to look again.
///
/// The reachability argument is the same in each case and is not incidental: the repair firing
/// is itself evidence of the model's habit. A model that stripped the `read_lines` gutter out of
/// `new_text` would have stripped it out of `old_text` too, and the gutter repair would never
/// have been needed. The repair predicts the corruption.
final class EditFileReplacementFidelityCoverageTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        runtime = run

        context = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fileManager.removeItem(at: tempDir) }
        context = nil
        tempDir = nil
        runtime = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func writeFile(_ name: String, _ content: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func runEdit(
        path: String, oldText: String, newText: String, replaceAll: Bool? = nil
    ) async -> ToolExecutionResult {
        var args: [String: Any] = ["path": path, "old_text": oldText, "new_text": newText]
        if let replaceAll { args["replace_all"] = replaceAll }
        let data = try! JSONSerialization.data(withJSONObject: args)
        let call = StepToolCall(name: ToolNames.editFile, argumentsJSON: String(data: data, encoding: .utf8)!)
        return await runtime.executeAll(context: context, toolCalls: [call])[0]
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: tempDir.appendingPathComponent(name), encoding: .utf8)
    }

    /// Renders control characters so a failure message distinguishes `\r\r\n` from `\r\n`.
    private func visible(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "<CR>")
            .replacingOccurrences(of: "\n", with: "<LF>\n")
    }

    // MARK: - The anchor repair must reach the replacement

    /// The `read_lines` gutter is the single most common thing a model copies into an edit, and
    /// `include_line_numbers` defaults to true, so this is the ordinary path rather than an edge.
    ///
    /// RED: build `candidates` from `oldText` alone and splice raw `newText` (the pre-fix code) →
    /// the file becomes `1   │ func foo() {\n2   │     baz()\n}\n` — line-number gutters written
    /// into a Swift source file under `ok:true`.
    func testGutterInBothAnchorAndReplacement_doesNotWriteTheGutterIntoTheFile() async throws {
        try writeFile("g.swift", "func foo() {\n    bar()\n}\n")

        let result = await runEdit(
            path: "g.swift",
            oldText: "1   \u{2502} func foo() {\n2   \u{2502}     bar()",
            newText: "1   \u{2502} func foo() {\n2   \u{2502}     baz()"
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        let got = try read("g.swift")
        XCTAssertEqual(got, "func foo() {\n    baz()\n}\n", visible(got))
    }

    /// The same class through the other repair: a model that JSON-escaped its forward slashes
    /// escaped them on both sides of the call.
    ///
    /// RED: apply `unescapeJSONSequences` to the anchor only → the file gets a literal backslash,
    /// `const u = "a\/c";`.
    func testEscapedSlashInBothAnchorAndReplacement_doesNotWriteABackslash() async throws {
        try writeFile("h.js", "const u = \"a/b\";\n")

        let result = await runEdit(
            path: "h.js",
            oldText: "const u = \"a\\/b\";",
            newText: "const u = \"a\\/c\";"
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try read("h.js"), "const u = \"a/c\";\n")
    }

    /// The repair must be conditional on which candidate won, not unconditional: a replacement
    /// that legitimately contains `│` or `\/` and needed no repair has to survive byte-for-byte.
    ///
    /// RED: unconditionally run `stripLineNumberPrefixes` / `unescapeJSONSequences` over
    /// `new_text` → the box-drawing table row loses its `2 │ ` prefix and the regex loses its
    /// backslash, silently rewriting content the model meant literally.
    func testCleanAnchor_leavesAGutterLookalikeReplacementUntouched() async throws {
        try writeFile("i.txt", "row\n")

        let result = await runEdit(path: "i.txt", oldText: "row", newText: "2 \u{2502} cell\npath = \"a\\/b\"")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try read("i.txt"), "2 \u{2502} cell\npath = \"a\\/b\"\n")
    }

    /// Same pairing rule on the whitespace-tolerant path, which selects its candidate by index
    /// inside `whitespaceTolerantEdit` rather than in the caller. The file's trailing spaces force
    /// the exact path to miss, so the fallback is what performs this edit.
    ///
    /// RED: pass a bare `[String]` of anchors plus one `newText` into `whitespaceTolerantEdit`
    /// (the pre-fix signature) → the gutter reaches the file through the fallback instead.
    func testGutterRepair_pairsWithTheReplacementOnTheTolerantPathToo() async throws {
        try writeFile("j.txt", "line one  \nline two\n")

        let result = await runEdit(
            path: "j.txt",
            oldText: "1   \u{2502} line one\n2   \u{2502} line two",
            newText: "1   \u{2502} line ONE\n2   \u{2502} line TWO"
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try read("j.txt"), "line ONE\nline TWO\n")
    }

    // MARK: - Line endings are the tool's business, not the model's

    /// `read_file` returns content verbatim including every `\r`, so a model working on a CRLF
    /// file has every reason to echo CRLF back — which falsifies the premise stated in the
    /// production comment ("the model can't see line endings, so it can't be asked to carry the
    /// `\r` itself"). The tool owns the convention; it must therefore normalise what it is given.
    ///
    /// RED: drop the CR-stripping normalisation before the `windowIsCRLF` reattach map → the file
    /// becomes `ALPHA\r\r\nBETA\r\ngamma\r\n`, and `\r\r\n` is not a valid line ending.
    func testCRLFReplacementIntoACRLFWindow_doesNotDoubleTheCR() async throws {
        try writeFile("k.txt", "alpha\r\nbeta\r\ngamma\r\n")

        let result = await runEdit(path: "k.txt", oldText: "alpha\nbeta", newText: "ALPHA\r\nBETA")

        XCTAssertFalse(result.isError, result.outputJSON)
        let got = try read("k.txt")
        XCTAssertEqual(got, "ALPHA\r\nBETA\r\ngamma\r\n", visible(got))
    }

    /// The terminator branch doubles EVERY line rather than just the first, so it is pinned
    /// separately — the two branches build `newLines` by different routes.
    ///
    /// RED: same mutation → `ONE\r\r\nTWO\r\r\nbeta\r\n`.
    func testCRLFReplacementWithATerminatorAnchor_doesNotDoubleAnyCR() async throws {
        try writeFile("l.txt", "alpha\r\nbeta\r\n")

        let result = await runEdit(path: "l.txt", oldText: "alpha\n", newText: "ONE\r\nTWO\r\n")

        XCTAssertFalse(result.isError, result.outputJSON)
        let got = try read("l.txt")
        XCTAssertEqual(got, "ONE\r\nTWO\r\nbeta\r\n", visible(got))
    }

    /// The normalisation must not push CRLF into a file that does not use it: an LF window keeps
    /// LF even when the model volunteered `\r\n`. The file's trailing spaces are what send this
    /// through the tolerant path — the path that has taken ownership of line endings.
    ///
    /// RED: strip the CR only when `windowIsCRLF` is true → an LF file acquires CRLF lines from
    /// whatever convention the model happened to emit.
    func testCRLFReplacementIntoAnLFWindow_staysLF() async throws {
        try writeFile("m.txt", "alpha  \nbeta\n")

        let result = await runEdit(path: "m.txt", oldText: "alpha\nbeta", newText: "ONE\r\nTWO")

        XCTAssertFalse(result.isError, result.outputJSON)
        let got = try read("m.txt")
        XCTAssertEqual(got, "ONE\nTWO\n", visible(got))
    }

    /// The exact path deliberately does NOT normalise: it is a literal substring replace with no
    /// line context at all, so the model's bytes go in as written.
    ///
    /// CHOICE: the alternative is to strip the CR here too, on the grounds that an LF file should
    /// not silently acquire mixed line endings. It is rejected because this path has no window and
    /// no line-ending convention to preserve — it replaces the span the model named. A model
    /// editing a fixture that genuinely contains `\r`, or a file that really is CRLF, is entitled
    /// to write one, and stripping it would be the mirror image of the gutter defect above:
    /// rewriting content the model meant literally. The tolerant path is different precisely
    /// because it already reattaches `\r` per window, i.e. it has taken ownership.
    /// FIXTURE: LF file `alpha\nbeta\n`, anchor `alpha` (an exact substring hit), replacement
    /// `ONE\r\nTWO`.
    ///
    /// RED: hoist the CR normalisation out of `whitespaceTolerantEdit` into the exact-match branch
    /// → the model's literal bytes are rewritten on a path that has no line-ending convention to
    /// preserve, which is the mirror image of the gutter defect above.
    func testCharacterization_exactPathSplicesTheModelsBytesVerbatim() async throws {
        try writeFile("m2.txt", "alpha\nbeta\n")

        let result = await runEdit(path: "m2.txt", oldText: "alpha", newText: "ONE\r\nTWO")

        XCTAssertFalse(result.isError, result.outputJSON)
        let got = try read("m2.txt")
        XCTAssertEqual(got, "ONE\r\nTWO\nbeta\n", visible(got))
    }

    // MARK: - The split sentinel is not a line

    /// `"a\nb\n".components(separatedBy: "\n")` is `["a", "b", ""]`; that final `""` marks the
    /// terminating newline, it is not a blank line. `whitespaceTolerantEdit` already knows this —
    /// it excludes the sentinel when counting `fileLineCount` for the longer-than-file
    /// diagnostic — but `windowMatches` counted it as matchable, so the same phantom line was
    /// "not a line" for counting and "a line" for matching.
    ///
    /// This branch can only fire when the blank line does NOT exist: a file that genuinely ends
    /// with one is matched by the exact path instead (pinned below).
    ///
    /// RED: scan to `contentLines.count` instead of excluding the sentinel → the file becomes
    /// `X` with no trailing newline, silently un-terminating a text file under `ok:true`.
    func testAnchorWithAPhantomTrailingBlankLine_isRefusedRatherThanEatingTheFinalNewline() async throws {
        try writeFile("n.txt", "a\nb\n")

        let result = await runEdit(path: "n.txt", oldText: "a\nb\n\n", newText: "X")

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertEqual(try read("n.txt"), "a\nb\n")
    }

    /// The control: a file that really does end in a blank line still matches the same anchor,
    /// through the exact path, and the edit lands.
    ///
    /// RED: write the sentinel exclusion so it also refuses a REAL trailing blank line (e.g. a
    /// scan bound of `count - 2`) → this reds while the phantom-line test above still passes, so
    /// the pair fixes the boundary from both sides.
    func testAnchorWithARealTrailingBlankLine_stillMatches() async throws {
        try writeFile("o.txt", "a\nb\n\n")

        let result = await runEdit(path: "o.txt", oldText: "a\nb\n\n", newText: "X")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try read("o.txt"), "X")
    }

    /// An anchor ending on the file's LAST REAL line must keep working — the sentinel exclusion
    /// narrows the scan bound, and an off-by-one there would refuse every end-of-file edit.
    ///
    /// RED: exclude the sentinel by scanning to `count - oldLines.count` or otherwise
    /// over-narrowing → this ordinary end-of-file edit starts returning ANCHOR_NOT_FOUND.
    func testAnchorEndingOnTheFinalRealLine_stillMatches() async throws {
        try writeFile("p.txt", "a  \nb\n")

        let result = await runEdit(path: "p.txt", oldText: "a\nb", newText: "X\nY")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try read("p.txt"), "X\nY\n")
    }

    // MARK: - Selection and splice share one primitive

    /// CHOICE: candidate selection and the single-replacement splice both go through
    /// `range(of:)`, so an NFC anchor over NFD content matches on the exact path and the
    /// model's NFC bytes are spliced verbatim; the defensible alternative — a byte-literal
    /// selector that refuses the normalization mismatch to the tolerant path — would reject
    /// the ordinary pairing of JSON-NFC anchors with filesystem-NFD sources.
    /// FIXTURE: file content spells `é` DECOMPOSED (`e` + U+0301); the anchor spells it
    /// PRECOMPOSED (U+00E9) — how JSON from an LLM typically arrives.
    ///
    /// Measured 2026-08-11 (macOS 26): `contains`, `range(of:)` and `replacingOccurrences`
    /// all agree on this pair — which is what licensed removing the defensive "located but
    /// could not be replaced" arm. If a future Foundation ever splits the primitives, the
    /// range-based selection falls through to the tolerant path's honest ANCHOR_NOT_FOUND,
    /// so this test's failure mode is a changed error message, never a corrupted file.
    ///
    /// RED: select the winner with a byte-literal search (e.g. over `utf8`) instead of
    /// `range(of:)` → the NFC anchor misses the NFD content and this edit is refused.
    func testCharacterization_precomposedAnchorOverDecomposedContent_matchesOnTheExactPath() async throws {
        let decomposed = "let cafe\u{0301} = 1\nprint(cafe\u{0301})\n"
        try writeFile("nfd.swift", decomposed)

        let result = await runEdit(path: "nfd.swift", oldText: "caf\u{00E9} = 1", newText: "tea = 2")

        XCTAssertFalse(result.isError, result.outputJSON)
        let got = try read("nfd.swift")
        XCTAssertEqual(got, "let tea = 2\nprint(cafe\u{0301})\n",
                       "Splice replaces exactly the matched range; the untouched é keeps its NFD bytes")
    }

    /// The all-or-nothing rule for gutter stripping, pinned from the side that hurts: a MIXED
    /// anchor (some lines carry the gutter, some don't) must not produce a partially-stripped
    /// candidate — even when that partially-stripped spelling EXISTS in the file. The sibling
    /// pin in `ToolsFileSystemTests.testEditFile_noFalsePositiveStripping` uses a fixture whose
    /// partial strip matches nothing, so it stays green under a strip-what-matches regression;
    /// this fixture is the one that would land the edit on text the model never named.
    ///
    /// RED: strip per matching line instead of bailing on the first non-matching one → the
    /// partially-stripped candidate matches and the file is edited under `ok:true`.
    func testMixedGutterAnchor_doesNotMatchViaAPartialStrip() async throws {
        try writeFile("mx.txt", "Normal line\nTabbed data\n")

        let result = await runEdit(path: "mx.txt", oldText: "Normal line\n42\tTabbed data", newText: "X")

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("ANCHOR_NOT_FOUND"), result.outputJSON)
        XCTAssertEqual(try read("mx.txt"), "Normal line\nTabbed data\n", "File must be untouched")
    }

    /// replace_all through a REPAIRED candidate: selection is range-based, and the replaceAll
    /// arm re-searches with `winner.old` — this pins that both use the SAME candidate, so the
    /// gutter repair reaches every occurrence, not just the selecting one.
    ///
    /// RED: make the replaceAll arm search with the raw `oldText` instead of the winner → zero
    /// occurrences of the gutter-carrying spelling exist in the file, `replacements_made`
    /// reads 0 and the file is written unchanged under `ok:true`.
    func testReplaceAll_throughARepairedGutterAnchor_replacesEveryOccurrence() async throws {
        try writeFile("ra.swift", "foo()\nbar()\nfoo()\n")

        let result = await runEdit(
            path: "ra.swift", oldText: "1\tfoo()", newText: "1\tqux()", replaceAll: true
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try read("ra.swift"), "qux()\nbar()\nqux()\n")
        XCTAssertTrue(result.outputJSON.contains("\"replacements_made\":2"), result.outputJSON)
    }
}
