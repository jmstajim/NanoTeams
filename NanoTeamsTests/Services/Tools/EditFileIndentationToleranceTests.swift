import XCTest

@testable import NanoTeams

/// Pins tier 3 of `EditFileTool`'s anchor matching: the window is located ignoring
/// LEADING whitespace, and the replacement is rewritten into the file's indentation
/// convention.
///
/// Tier 2 (trailing whitespace) is pinned by `EditFileWhitespaceToleranceTests`; the
/// field failures that motivated this tier are replayed verbatim by
/// `EditFileRealRunRegressionTests`; the REWRITE-shaped refusals distilled from
/// MeditationApp task 32 live in `EditFileRewriteReindentTests`. This file covers the
/// mechanism itself — the prefix map, its refusals, and the splice invariants tier 3
/// shares with tier 2.
final class EditFileIndentationToleranceTests: XCTestCase {
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
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role")
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
    ) -> ToolExecutionResult {
        var args: [String: Any] = ["path": path, "old_text": oldText, "new_text": newText]
        if let replaceAll { args["replace_all"] = replaceAll }
        let data = try! JSONSerialization.data(withJSONObject: args)
        let call = StepToolCall(name: "edit_file", argumentsJSON: String(data: data, encoding: .utf8)!)
        return runtime.executeAll(context: context, toolCalls: [call])[0]
    }

    private func dataField(_ result: ToolExecutionResult, _ key: String) -> Any? {
        guard
            let json = try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))
                as? [String: Any],
            let data = json["data"] as? [String: Any]
        else { return nil }
        return data[key]
    }

    private func message(_ result: ToolExecutionResult) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))
                as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String
        else { return "" }
        return message
    }

    // MARK: - The map, applied

    /// The whole block sits one level deeper in the file than in the anchor. Each
    /// depth maps consistently, so the replacement is shifted with it.
    ///
    /// RED: drop the tier-3 branch → ANCHOR_NOT_FOUND.
    func testWholeBlockShiftedOneLevel_isRepaired() throws {
        let url = try writeFile("a.swift", "class C {\n    func f() {\n        go()\n    }\n}\n")

        let result = runEdit(
            path: "a.swift",
            oldText: "func f() {\n    go()\n}",
            newText: "func f() {\n    stop()\n}"
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "class C {\n    func f() {\n        stop()\n    }\n}\n",
            "the replacement must land at the file's depth, not the anchor's")
    }

    /// A blank line inside the anchor carries no depth information and must not enter
    /// the map — the two sides disagree about blank lines constantly (the file has an
    /// empty line, the model wrote spaces, or the reverse).
    ///
    /// RED: stop skipping blank lines when building the map → `""` vs `"    "`
    /// conflicts on the blank line's key and the edit is refused.
    func testBlankLineInsideAnchor_doesNotPoisonTheMap() throws {
        let url = try writeFile("b.swift", "\tlet a = 1\n\n\tlet b = 2\n")

        let result = runEdit(
            path: "b.swift",
            oldText: "    let a = 1\n    \n    let b = 2",
            newText: "    let a = 9\n    \n    let b = 2"
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertTrue(
            try String(contentsOf: url, encoding: .utf8).contains("\tlet a = 9"),
            "the surviving lines must keep the file's tabs")
    }

    /// Zero indentation means zero indentation in either convention, so a top-level
    /// replacement line needs no entry in the map.
    ///
    /// RED: require every non-blank replacement prefix to be a map key → refused.
    func testZeroIndentReplacementLine_needsNoMapEntry() throws {
        let url = try writeFile("c.swift", "\tif (x) {\n\t\tgo();\n\t}\n")

        let result = runEdit(
            path: "c.swift",
            oldText: "    if (x) {\n        go();\n    }",
            newText: "done()"
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "done()\n")
    }

    /// Two anchor depths collapsing onto one file depth is a FUNCTION, and is exactly
    /// the commonest real repair — a model that opened a block with four spaces and
    /// closed it with five described one file depth twice.
    ///
    /// RED: additionally require the map to be injective → this is refused, and the
    /// field's most frequent recoverable case is lost.
    func testTwoAnchorDepthsOntoOneFileDepth_isStillRepaired() throws {
        let url = try writeFile("d.swift", "    init() {\n        go()\n    }\n")

        let result = runEdit(
            path: "d.swift",
            oldText: "    init() {\n        go()\n     }",
            newText: "    init() {\n        stop()\n     }"
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "    init() {\n        stop()\n    }\n",
            "the model's stray fifth space must not reach the file")
    }

    // MARK: - Splice invariants shared with tier 2

    /// A CRLF file stays CRLF after a tier-3 splice. Tier 2 already guaranteed this;
    /// extracting `spliceWindows` is what keeps the two from drifting.
    ///
    /// RED: splice tier 3 without the shared helper → the repaired lines lose `\r`.
    func testCRLFFile_survivesATierThreeSplice() throws {
        let url = try writeFile("e.swift", "\tif (x) {\r\n\t\tgo();\r\n\t}\r\n")

        let result = runEdit(
            path: "e.swift",
            oldText: "    if (x) {\n        go();\n    }",
            newText: "    if (y) {\n        go();\n    }"
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, "\tif (y) {\r\n\t\tgo();\r\n\t}\r\n")
        XCTAssertFalse(written.contains("\r\r"), "no doubled CR")
    }

    /// An anchor ending in a newline is a line TERMINATOR, and an empty replacement
    /// under it deletes the matched lines outright rather than leaving a blank one.
    /// Tier 3 mirrors tier 2 here because both go through `replacementLines`.
    ///
    /// RED: read `new_text` directly instead of through `replacementLines` → a blank
    /// line is left behind.
    func testTerminatorSemantics_holdOnTierThree() throws {
        let url = try writeFile("f.swift", "before\n\tgo();\nafter\n")

        let result = runEdit(path: "f.swift", oldText: "    go();\n", newText: "")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "before\nafter\n")
    }

    /// Several windows differ from the anchor only by indentation. Each could need a
    /// different translation, so none is chosen — the model gets the diagnosis and
    /// picks a longer anchor.
    ///
    /// RED: auto-fix on a non-unique match → one window is silently picked.
    func testMultipleIndentationWindows_areNotAutoFixed() throws {
        let original = "\tgo()\nx\n\tgo()\ny\n"
        let url = try writeFile("g.swift", original)

        let result = runEdit(path: "g.swift", oldText: "    go()", newText: "stop()")

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(message(result).contains("ignoring indentation"), message(result))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    // MARK: - The three not-found states

    /// The anchor's first line is found, then the window breaks. Both sides are named
    /// so the model can fix the transcription without re-reading blind.
    ///
    /// RED: report `.absent` for a partial match → neither line is quoted.
    func testDivergingAnchor_namesBothSidesAndTheLine() throws {
        try writeFile("h.swift", "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\n")

        let result = runEdit(
            path: "h.swift",
            oldText: "let a = 1\nlet b = 99",
            newText: "x"
        )
        let text = message(result)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(text.contains("let b = 99"), "quote what the model sent: \(text)")
        XCTAssertTrue(text.contains("let b = 2"), "quote what the file has: \(text)")
        XCTAssertTrue(text.contains("line 2"), "name the position: \(text)")
    }

    /// No line of the anchor appears anywhere. Whitespace advice cannot help, so it is
    /// not given — that misdiagnosis is what kept a real run looping.
    ///
    /// RED: fold `.absent` into the generic message → the whitespace assertion fails.
    func testAbsentAnchor_doesNotAdviseWhitespace() throws {
        try writeFile("i.swift", "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\n")

        let result = runEdit(
            path: "i.swift",
            oldText: "struct NeverExisted {\n    let x: Int\n}",
            newText: "x"
        )
        let text = message(result)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(text.contains("none of its lines appear"), text)
        XCTAssertTrue(text.contains("i.swift"), text)
        XCTAssertFalse(text.contains("whitespace and indentation"), text)
    }

    /// The two legacy diagnoses keep the old base sentence, because for a malformed
    /// (rather than mislocated) anchor the character-level advice is still true.
    ///
    /// RED: route these through the typed path → the base sentence disappears and
    /// `ToolErrorNotePolicy.direction` stops appending its steering.
    func testLegacyDiagnoses_keepTheBaseSentence() throws {
        try writeFile("j.swift", "a\nb\n")

        let longer = runEdit(path: "j.swift", oldText: "a\nb\nc\nd", newText: "z")
        XCTAssertTrue(message(longer).contains("Make sure it matches exactly"), message(longer))
        XCTAssertTrue(message(longer).contains("more lines (4) than the file (2)"), message(longer))

        let blank = runEdit(path: "j.swift", oldText: "   \n   ", newText: "z")
        XCTAssertTrue(message(blank).contains("Make sure it matches exactly"), message(blank))
        XCTAssertTrue(message(blank).contains("whitespace-only"), message(blank))
    }

    // MARK: - Unit-level: the map itself

    /// Direct pins on `reindentToFileConvention`, which is where the whole tier's
    /// safety lives. Driving it through the tool would need a fixture per row.
    func testReindentToFileConvention_truthTable() {
        // Consistent map, all replacement depths known → translated.
        XCTAssertEqual(
            EditFileTool.reindentToFileConvention(
                newLines: ["    a", "        b"],
                anchorLines: ["    x", "        y"],
                fileLines: ["\tx", "\t\ty"])?.lines,
            ["\ta", "\t\tb"])

        // Same key, two values → not a function.
        XCTAssertNil(
            EditFileTool.reindentToFileConvention(
                newLines: ["    a"],
                anchorLines: ["    x", "    y"],
                fileLines: ["    x", "     y"]))

        // A REWRITE (same line count) introducing a depth the anchor never showed is
        // still refused: every line here replaces a line of the window, so the file
        // has a convention for all of them and an unknown depth is unplaceable.
        // Only content BEYOND the window may keep the model's own indentation.
        XCTAssertNil(
            EditFileTool.reindentToFileConvention(
                newLines: ["    a", "            deep"],
                anchorLines: ["    x", "        y"],
                fileLines: ["\tx", "\t\ty"]))

        // Blank lines carry no depth and are passed through untouched.
        XCTAssertEqual(
            EditFileTool.reindentToFileConvention(
                newLines: ["    a", "", "    b"],
                anchorLines: ["    x", "", "    y"],
                fileLines: ["\tx", "", "\ty"])?.lines,
            ["\ta", "", "\tb"])

        // Mismatched window length is not a translation problem — refuse.
        XCTAssertNil(
            EditFileTool.reindentToFileConvention(
                newLines: ["a"], anchorLines: ["    x"], fileLines: ["\tx", "\ty"]))

        // An anchor of only blank lines yields no map at all.
        XCTAssertNil(
            EditFileTool.reindentToFileConvention(
                newLines: ["a"], anchorLines: ["   "], fileLines: [""]))
    }

    /// The insertion idiom: `new_text` reproduces the anchor and appends new code.
    /// The reproduced head is translated (the file has a convention for it); the
    /// appended tail keeps the model's indentation, because the anchor gave no
    /// evidence for those depths and inventing one is the extrapolation this
    /// function refuses to do.
    ///
    /// RED: return `0..<0` from `freeRegion` unconditionally → nil.
    func testReindentToFileConvention_appendAfterAnchor_translatesHeadKeepsTail() {
        let result = EditFileTool.reindentToFileConvention(
            newLines: ["    x", "        y", "", "  newTop", "      newDeep"],
            anchorLines: ["    x", "        y"],
            fileLines: ["\tx", "\t\ty"])

        XCTAssertEqual(result?.lines, ["\tx", "\t\ty", "", "  newTop", "      newDeep"])
        XCTAssertEqual(result?.passedThroughCount, 2)
    }

    /// The mirror idiom — new code inserted BEFORE the anchor.
    ///
    /// RED: drop the `suffix` arm of `freeRegion` → nil.
    func testReindentToFileConvention_insertBeforeAnchor_translatesTailKeepsHead() {
        let result = EditFileTool.reindentToFileConvention(
            newLines: ["  newTop", "", "    x", "        y"],
            anchorLines: ["    x", "        y"],
            fileLines: ["\tx", "\t\ty"])

        XCTAssertEqual(result?.lines, ["  newTop", "", "\tx", "\t\ty"])
        XCTAssertEqual(result?.passedThroughCount, 1)
    }

    /// A longer replacement that does NOT reproduce the anchor at either end is not
    /// an insertion — the model rewrote the window itself, so there is no region the
    /// file has no opinion about, and an unknown depth is still a refusal.
    ///
    /// RED: treat "longer than the anchor" as evidence of insertion on its own →
    /// writes the unmapped line.
    func testReindentToFileConvention_longerButUnaligned_refuses() {
        XCTAssertNil(
            EditFileTool.reindentToFileConvention(
                newLines: ["    a", "        b", "            deep"],
                anchorLines: ["    x", "        y"],
                fileLines: ["\tx", "\t\ty"]))
    }

    /// A free region whose every depth is a map key is translated as a WHOLE — leaving
    /// it in the model's convention would split the appended block's style from the head
    /// that was just rewritten.
    ///
    /// RED: pass every free-region line through → `["\tx", "    a"]`, count 1.
    func testReindentToFileConvention_freeRegionFullyExpressible_isTranslated() {
        let result = EditFileTool.reindentToFileConvention(
            newLines: ["    x", "    a"],
            anchorLines: ["    x"],
            fileLines: ["\tx"])

        XCTAssertEqual(result?.lines, ["\tx", "\ta"])
        XCTAssertEqual(result?.passedThroughCount, 0)
    }

    /// …but a free region that STRADDLES the key set is emitted verbatim, entire.
    ///
    /// This is the correctness core of the all-or-nothing rule. The map relabels depths
    /// without preserving their order, so translating the lines it covers and keeping the
    /// rest re-orders the appended block's own nesting — the one thing that block means.
    ///
    /// Here a 2-space model meets a 4-space file (map {2→4, 4→8}) and appends a block at
    /// 4/6/4. Per-line, the opener lands at 8, its child at 6 and the closer at 8: the
    /// child ends up SHALLOWER than the block enclosing it, written under `ok:true`.
    /// Mangled in Swift, an IndentationError in Python — and `edit_file` has no extension
    /// gating.
    ///
    /// RED: consult the map before the free-region branch (the per-line policy that
    /// shipped first) → the inversion above, with count 1.
    func testReindentToFileConvention_freeRegionStraddlingTheKeySet_isKeptVerbatim() {
        let result = EditFileTool.reindentToFileConvention(
            newLines: ["  func f() {", "    g()", "    h() {", "      deep()", "    }"],
            anchorLines: ["  func f() {", "    g()"],
            fileLines: ["    func f() {", "        g()"])

        XCTAssertEqual(
            result?.lines,
            ["    func f() {", "        g()", "    h() {", "      deep()", "    }"],
            "the window is translated; the appended block keeps its own nesting")
        XCTAssertEqual(result?.passedThroughCount, 3)

        // The property, stated independently of the exact bytes: inside the appended
        // block a line the model wrote deeper than its opener must not come out shallower.
        let written = result?.lines ?? []
        let opener = written[2].prefix { $0 == " " }.count
        let child = written[3].prefix { $0 == " " }.count
        XCTAssertGreaterThan(child, opener, "nesting inside the appended block must survive")
    }

    /// `bestPartialMatch` reports the LONGEST agreement, not the first occurrence, so
    /// the diagnosis points at the region the model actually meant.
    ///
    /// RED: return the first occurrence instead of the longest → matched == 1.
    func testBestPartialMatch_prefersTheLongestAgreement() {
        let content = ["head", "x", "tail", "head", "y", "tail"]
        let anchor = ["head", "y", "zzz"]

        let match = EditFileTool.bestPartialMatch(
            contentLines: content, oldLines: anchor, scanBound: content.count)

        XCTAssertEqual(match?.start, 3)
        XCTAssertEqual(match?.matched, 2)
    }

    /// The first anchor line appearing nowhere is the `absent` signal.
    func testBestPartialMatch_firstLineAbsent_returnsNil() {
        XCTAssertNil(
            EditFileTool.bestPartialMatch(
                contentLines: ["a", "b"], oldLines: ["nope"], scanBound: 2))
    }
}
