import XCTest

@testable import NanoTeams

/// Pins the trailing-whitespace-tolerant fallback in `EditFileTool`.
///
/// Production failure this guards against: a file region contained a "blank" line that
/// was actually 8 trailing spaces. The model's old_text used a clean empty line, the
/// exact match failed with ANCHOR_NOT_FOUND, and — because trailing whitespace is
/// invisible in read_lines output — the model re-sent the identical anchor in a loop.
final class EditFileWhitespaceToleranceTests: XCTestCase {
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
            workFolderRoot: tempDir,
            taskID: 0,
            runID: 0,
            roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        context = nil
        tempDir = nil
        runtime = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

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
        let call = StepToolCall(name: "edit_file", argumentsJSON: String(data: data, encoding: .utf8)!)
        return await runtime.executeAll(context: context, toolCalls: [call])[0]
    }

    private func dataField(_ result: ToolExecutionResult, _ key: String) -> Any? {
        guard
            let json = try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any],
            let data = json["data"] as? [String: Any]
        else { return nil }
        return data[key]
    }

    private func replacementsMade(in result: ToolExecutionResult) -> Int? {
        dataField(result, "replacements_made") as? Int
    }

    private func warningTexts(_ result: ToolExecutionResult) -> [String] {
        guard
            let json = try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any],
            let meta = json["meta"] as? [String: Any]
        else { return [] }
        return (meta["warnings"] as? [String]) ?? []
    }

    // MARK: - Matching

    /// Verbatim production case: blank line in the file is actually trailing spaces.
    func testTrailingWSOnBlankLine_productionCase() async throws {
        let fileContent = """
                // Initialize Spell Cooldown UI
                this.spellCooldownUI = new SpellCooldownUI(this.spellManager, this.canvas);
                \u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}
                // XP and Leveling Systems
        
        """
        let url = try writeFile("game.js", fileContent)

        let oldText = "        // Initialize Spell Cooldown UI\n        this.spellCooldownUI = new SpellCooldownUI(this.spellManager, this.canvas);\n\n        // XP and Leveling Systems"
        let newText = "        // Initialize Spell Cooldown UI\n        this.spellCooldownUI = new SpellCooldownUI(this.spellManager, this.canvas);\n\n        // Initialize Spell Selection UI\n        this.spellSelectionUI = new SpellSelectionUI(this.spellManager, this.canvas);\n\n        // XP and Leveling Systems"

        let result = await runEdit(path: "game.js", oldText: oldText, newText: newText)

        XCTAssertFalse(result.isError, "tolerant fallback should match despite trailing spaces on the blank line: \(result.outputJSON)")
        XCTAssertEqual(replacementsMade(in: result), 1)
        let newContent = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(newContent, newText + "\n")
    }

    func testTrailingSpacesOnCodeLine_multiLineWindow() async throws {
        let url = try writeFile("a.txt", "let a = 1;   \nlet b = 2;\n")

        let result = await runEdit(path: "a.txt", oldText: "let a = 1;\nlet b = 2;", newText: "let a = 9;\nlet b = 2;")

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "let a = 9;\nlet b = 2;\n")
    }

    /// Single-line window: model hallucinated trailing spaces that the file doesn't have.
    /// (The forward direction — clean old_text vs dirty file line — is always a substring
    /// match for single lines, so only the reverse direction reaches the fallback.)
    func testSingleLineOldText_modelAddedTrailingSpaces() async throws {
        let url = try writeFile("b.txt", "foo();\nbar();\n")

        let result = await runEdit(path: "b.txt", oldText: "foo();   ", newText: "baz();")

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "baz();\nbar();\n")
    }

    /// Multi-line reverse direction: old_text carries trailing whitespace the file lacks.
    func testReverseDirection_oldTextHasTrailingWS_fileClean() async throws {
        let url = try writeFile("c.txt", "one\ntwo\nthree\n")

        let result = await runEdit(path: "c.txt", oldText: "one  \ntwo\t", newText: "ONE\nTWO")

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "ONE\nTWO\nthree\n")
    }

    /// CRLF file, LF old_text: matches, and the REPLACED lines adopt the window's
    /// CRLF convention (the model can't see line endings, so the tool carries them).
    func testCRLFFile_lfOldText() async throws {
        let url = try writeFile("d.txt", "alpha\r\nbeta\r\ngamma\r\n")

        let result = await runEdit(path: "d.txt", oldText: "alpha\nbeta", newText: "ALPHA\nBETA")

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "ALPHA\r\nBETA\r\ngamma\r\n")
    }

    /// Gutter-prefixed old_text combined with a trailing-whitespace mismatch:
    /// tolerant matching must also run over the line-number-stripped candidate.
    func testGutterPrefixedOldText_plusTrailingWSMismatch() async throws {
        let url = try writeFile("e.txt", "line one  \nline two\n")

        let result = await runEdit(
            path: "e.txt",
            oldText: "1   \u{2502} line one\n2   \u{2502} line two",
            newText: "line ONE\nline TWO"
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "line ONE\nline TWO\n")
    }

    /// Non-breaking space at line end is just as invisible as a regular space.
    func testNBSPAtLineEnd_matches() async throws {
        let url = try writeFile("f.txt", "x = 1;\u{00A0}\ny = 2;\n")

        let result = await runEdit(path: "f.txt", oldText: "x = 1;\ny = 2;", newText: "x = 7;\ny = 2;")

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "x = 7;\ny = 2;\n")
    }

    // MARK: - replace_all

    func testReplaceAll_twoWindowsDifferentTrailingWS() async throws {
        let url = try writeFile("g.txt", "a  \nb\nc\na\t\nb\nd\n")

        let result = await runEdit(path: "g.txt", oldText: "a\nb", newText: "X\nY", replaceAll: true)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(replacementsMade(in: result), 2)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "X\nY\nc\nX\nY\nd\n")
    }

    /// Periodic old_text over back-to-back occurrences: greedy non-overlapping scan
    /// yields 2 matches over 4 candidate lines, never overlapping windows.
    func testReplaceAll_backToBackWindows_nonOverlappingScan() async throws {
        let url = try writeFile("h.txt", "p  \np\t\np \np\u{00A0}\nz\n")

        let result = await runEdit(path: "h.txt", oldText: "p\np", newText: "Q", replaceAll: true)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(replacementsMade(in: result), 2)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Q\nQ\nz\n")
    }

    // MARK: - Negatives / safety

    func testGenuinelyDifferentText_stillAnchorNotFound() async throws {
        _ = try writeFile("i.txt", "real content\nmore lines\n")

        let result = await runEdit(path: "i.txt", oldText: "totally different\nanchor", newText: "x")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("ANCHOR_NOT_FOUND"))
        XCTAssertFalse(result.outputJSON.contains("regions"))
        XCTAssertFalse(result.outputJSON.contains("ignoring indentation"))
    }

    /// A whitespace-only anchor would tolerantly match any blank run anywhere —
    /// refused, with a hint naming the actual problem (the generic "match exactly"
    /// steering is a treadmill instruction for an all-whitespace anchor).
    func testWhitespaceOnlyOldText_fallbackRefuses() async throws {
        _ = try writeFile("j.txt", "a\n   \n\nb\n")

        let result = await runEdit(path: "j.txt", oldText: " \n  ", newText: "x")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("ANCHOR_NOT_FOUND"))
        XCTAssertTrue(result.outputJSON.contains("whitespace-only"), result.outputJSON)
    }

    /// Fuzzy match + silent first-pick is too risky: ambiguity gets its own error
    /// code (the anchor_not_found guidance would prescribe the wrong repair).
    func testAmbiguousTolerantMatch_singleReplace_errors() async throws {
        let url = try writeFile("k.txt", "m  \nn\nz\nm\t\nn\n")

        let result = await runEdit(path: "k.txt", oldText: "m\nn", newText: "X")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("ANCHOR_AMBIGUOUS"), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("matches 2 regions"), result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "m  \nn\nz\nm\t\nn\n", "file must be untouched")
    }

    // MARK: - Ambiguity on the EXACT path

    /// The tolerant path has refused ambiguous anchors since it was written; the exact path had
    /// no such check at all, so an `old_text` occurring N times without `replace_all` silently
    /// edited the FIRST occurrence and answered `ok:true` with `replacements_made: 1`. A
    /// wrong-location write reported as a success is the worst class of failure this tool has.
    /// RED: delete the occurrence count from the exact-path loop → the first `dup()` is rewritten,
    /// the file changes, and the call reports success.
    func testExactMatchInSeveralPlaces_withoutReplaceAll_refusesAndLeavesTheFileAlone() async throws {
        let original = "dup()\nmiddle\ndup()\n"
        let url = try writeFile("dup.txt", original)

        let result = await runEdit(path: "dup.txt", oldText: "dup()", newText: "changed()")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("ANCHOR_AMBIGUOUS"), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("matches 2 places"), result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original, "file must be untouched")
    }

    /// The exact path matched byte-for-byte, so the tolerant path's "when ignoring trailing
    /// whitespace" would be a false diagnosis — it would send the model hunting a whitespace
    /// problem it does not have. Same error CODE (so `ToolErrorNotePolicy.direction` steers both), a
    /// different sentence.
    /// RED: reuse the tolerant path's message verbatim → the model is told its exact anchor has a
    /// whitespace problem, and `replace_all` is never mentioned as the other way out.
    func testExactAmbiguity_doesNotBlameTrailingWhitespace_andNamesReplaceAll() async throws {
        _ = try writeFile("dup2.txt", "dup()\nmiddle\ndup()\n")

        let result = await runEdit(path: "dup2.txt", oldText: "dup()", newText: "changed()")

        XCTAssertFalse(result.outputJSON.contains("ignoring trailing whitespace"), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("replace_all"), result.outputJSON)
    }

    /// `replace_all` is exactly what the refusal points at, so it must still work.
    /// RED: hoist the occurrence check above the `!replaceAll` guard → `replace_all: true` starts
    /// erroring on the very input it exists for.
    func testExactMatchInSeveralPlaces_withReplaceAll_stillReplacesEveryOne() async throws {
        let url = try writeFile("dup3.txt", "dup()\nmiddle\ndup()\n")

        let result = await runEdit(path: "dup3.txt", oldText: "dup()", newText: "changed()", replaceAll: true)

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("\"replacements_made\":2"), result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "changed()\nmiddle\nchanged()\n")
    }

    /// The index-0 rule's other half. The model's LITERAL anchor carries a `read_lines` gutter and
    /// matches nothing; the gutter-stripped repair then matches twice. That ambiguity belongs to a
    /// TRANSFORMED candidate, so it is recorded rather than returned — a later candidate could
    /// still be unique — and surfaces only once every candidate is exhausted.
    /// RED: return immediately instead of recording (drop the `index == 0` condition) → a
    /// transformed candidate's ambiguity becomes terminal, and any later candidate that WOULD have
    /// matched uniquely never gets its turn.
    func testTransformedCandidateAmbiguity_isDeferredThenReported() async throws {
        let original = "foo()\nbar\nfoo()\n"
        let url = try writeFile("gutter.txt", original)

        let result = await runEdit(path: "gutter.txt", oldText: "1\tfoo()", newText: "1\tchanged()")

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("ANCHOR_AMBIGUOUS"), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("matches 2 places"), result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original, "file must be untouched")
    }

    /// The common case must not regress: one occurrence still edits without ceremony.
    /// RED: treat any match as ambiguous (drop the `> 1`) → every single-occurrence edit refuses.
    func testExactMatchInOnePlace_isUnaffected() async throws {
        let url = try writeFile("once.txt", "only()\nmiddle\n")

        let result = await runEdit(path: "once.txt", oldText: "only()", newText: "changed()")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "changed()\nmiddle\n")
    }

    /// Whole-line semantics: a partial-line content difference never fallback-matches.
    func testMidLineContentDifference_noFallback() async throws {
        _ = try writeFile("l.txt", "value = compute(); // cached\nnext();\n")

        let result = await runEdit(path: "l.txt", oldText: "value = compute(); // stale\nnext();", newText: "x")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("ANCHOR_NOT_FOUND"))
    }

    /// Tabs-vs-spaces is now REPAIRED, not merely diagnosed.
    ///
    /// This test previously pinned the refusal ("diagnosed, never auto-edited"). It was
    /// flipped deliberately: the anchor→file indentation here is a well-defined map
    /// (`"    "→"\t"`, `"        "→"\t\t"`), so the replacement can be rewritten into
    /// the file's convention with no guessing. Refusing it was the behaviour that sent
    /// a real model into a spaces-perturbing loop. The case where the map is NOT
    /// well-defined still refuses — see `testIrregularFileIndentation_refusesAndQuotesTheFile`.
    ///
    /// RED: drop the tier-3 branch → ANCHOR_NOT_FOUND again.
    func testIndentationMismatch_isRepairedIntoTheFilesConvention() async throws {
        let url = try writeFile("m.swift", "// header\n\n\tif (x) {\n\t\tgo();\n\t}\n")

        let result = await runEdit(
            path: "m.swift",
            oldText: "    if (x) {\n        go();\n    }",
            newText: "    if (y) {\n        go();\n    }"
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(dataField(result, "matched_ignoring_indentation") as? Bool, true)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "// header\n\n\tif (y) {\n\t\tgo();\n\t}\n",
            "the replacement must adopt the file's tabs, not keep the model's spaces")
    }

    /// The irregular-FILE shape (the real MeditationApp one): the SAME anchor depth
    /// corresponds to two different file depths — `"    "` maps to `"    "` on the
    /// first line and to `"     "` (five) on the third. The per-depth map used to
    /// refuse here as "unknowable"; per line it never was — each reproduced line
    /// pairs with its own file line and takes ITS bytes, so the file's five-space
    /// line survives, and the one changed line (whose conflicted key is unusable)
    /// keeps the model's bytes.
    ///
    /// RED: restore the conflicted-key `return nil` in `reindentToFileConvention` →
    /// ANCHOR_NOT_FOUND and every assert below fails.
    func testIrregularFileIndentation_landsPerLine_keepingTheFilesFiveSpaces() async throws {
        let url = try writeFile(
            "irregular.swift", "// header\n\n    let a = 1\n        deeper()\n     let b = 2\n")

        let result = await runEdit(
            path: "irregular.swift",
            oldText: "    let a = 1\n        deeper()\n    let b = 2",
            newText: "    let a = 9\n        deeper()\n    let b = 2"
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "// header\n\n    let a = 9\n        deeper()\n     let b = 2\n",
            "reproduced lines keep the file's bytes — five-space `let b` included; "
                + "the changed line keeps the model's")
        XCTAssertEqual(dataField(result, "matched_ignoring_indentation") as? Bool, true,
                       "the reproduced `let b` line's leading moved 4sp → 5sp: \(result.outputJSON)")
    }

    /// A replacement line at a depth the anchor never contained pairs with nothing
    /// and has no usable key, so it keeps the model's own bytes — the same rule the
    /// append form always had — and the kept depth is disclosed. (The refusal this
    /// replaced never once produced a corrected retry across three measured runs.)
    ///
    /// RED: refuse a unique window when an unpaired depth is not a map key → the
    /// isError assert fails.
    func testReplacementAtANovelDepth_keepsTheModelsBytesForIt() async throws {
        let url = try writeFile("novel.swift", "\tif (x) {\n\t\tgo();\n\t}\n")

        let result = await runEdit(
            path: "novel.swift",
            oldText: "    if (x) {\n        go();\n    }",
            // 12 spaces is a third depth: the anchor only ever showed 4 and 8.
            newText: "    if (x) {\n        go();\n            deeper();\n    }"
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "\tif (x) {\n\t\tgo();\n            deeper();\n\t}\n",
            "reproduced lines take the file's tabs; the novel-depth line stays the model's")
        XCTAssertTrue(
            warningTexts(result).contains { $0.contains("kept your own indentation") },
            "the kept depth must be disclosed: \(warningTexts(result))")
    }

    // MARK: - File boundaries

    func testWindowAtEOF_noTrailingNewline() async throws {
        let url = try writeFile("n.txt", "first\nlast")

        let result = await runEdit(path: "n.txt", oldText: "first \nlast", newText: "X\nY")

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "X\nY")
    }

    func testTrailingNewlinePreserved() async throws {
        let url = try writeFile("o.txt", "a  \nb\n")

        let result = await runEdit(path: "o.txt", oldText: "a\nb", newText: "c\nd")

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "c\nd\n")
    }

    /// Exact byte-for-byte match must never route through the tolerant path:
    /// only the anchored occurrence is replaced even if a fuzzy duplicate exists.
    func testExactMatchTakesPriorityOverTolerant() async throws {
        let url = try writeFile("p.txt", "k  \nl\nz\nk\nl\n")

        // Exact "k\nl" exists at lines 4-5; lines 1-2 only match tolerantly.
        let result = await runEdit(path: "p.txt", oldText: "k\nl", newText: "K\nL")

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "k  \nl\nz\nK\nL\n")
    }

    /// replace_all with one exact occurrence and one fuzzy duplicate: the exact path
    /// wins and replaces ONLY exact occurrences — the fuzzy duplicate is left alone
    /// and replacements_made reports the exact count honestly.
    func testReplaceAll_exactMatchSkipsTolerantDuplicates() async throws {
        let url = try writeFile("q.txt", "k  \nl\nz\nk\nl\n")

        let result = await runEdit(path: "q.txt", oldText: "k\nl", newText: "K\nL", replaceAll: true)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(replacementsMade(in: result), 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "k  \nl\nz\nK\nL\n")
    }

    // MARK: - Trailing-newline anchors (terminator semantics)

    /// An anchor ending in "\n" — the most common LLM emission shape — treats that
    /// newline as a line terminator, not as a required blank line in the file.
    func testTerminatorAnchor_trailingNewline_matches() async throws {
        let url = try writeFile("r.txt", "first  \nsecond\nthird\n")

        let result = await runEdit(path: "r.txt", oldText: "first\nsecond\n", newText: "X\nY\n")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "X\nY\nthird\n")
    }

    /// A terminator anchor must not consume a following whitespace-only line
    /// (e.g. a Markdown paragraph separator) as its "blank line".
    func testTerminatorAnchor_preservesWhitespaceOnlySeparator() async throws {
        let url = try writeFile("s.txt", "foo \n   \nrest\n")

        let result = await runEdit(path: "s.txt", oldText: "foo\n", newText: "bar")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "bar\n   \nrest\n")
    }

    /// Terminator anchor + empty new_text deletes the matched line outright
    /// (mirrors the exact path's `replace "foo\n" with ""` semantics).
    func testTerminatorAnchor_emptyNewText_deletesLine() async throws {
        let url = try writeFile("t.txt", "foo \nrest\n")

        let result = await runEdit(path: "t.txt", oldText: "foo\n", newText: "")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "rest\n")
    }

    /// Non-terminator anchor + empty new_text leaves one blank line (the window's
    /// surrounding newlines survive, matching the exact path's behavior).
    func testEmptyNewText_nonTerminatorAnchor_leavesBlankLine() async throws {
        let url = try writeFile("u.txt", "a  \nb\nc\n")

        let result = await runEdit(path: "u.txt", oldText: "a\nb", newText: "")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\nc\n")
    }

    // MARK: - Diagnostics and disclosure

    /// A leading-whitespace mismatch is handled even when the anchor ALSO differs in
    /// trailing whitespace (trimBoth covers both ends). The zero-indent replacement
    /// needs no translation — no indentation means no indentation in either
    /// convention — and BECAUSE nothing's leading whitespace changed, the envelope
    /// must not claim a re-indent: `matched_ignoring_indentation` means "your
    /// leading whitespace is not what landed", and here it is exactly what landed.
    ///
    /// RED: drop the tier-3 branch → ANCHOR_NOT_FOUND.
    /// RED: set the flag whenever the tier fires (drop the `leadingRewritten`
    /// gate) → the nil assert fails.
    func testCombinedLeadingAndTrailingMismatch_isRepaired() async throws {
        let url = try writeFile("v.swift", "\tif (x) {  \n\t\tgo();\n\t}\n")

        let result = await runEdit(
            path: "v.swift",
            oldText: "    if (x) {\n        go();\n    }",
            newText: "x"
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertNil(dataField(result, "matched_ignoring_indentation"),
                     "the replacement's own (zero) indentation landed untouched: \(result.outputJSON)")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "x\n")
    }

    func testAnchorLongerThanFile_hintsLineCount() async throws {
        _ = try writeFile("w.txt", "a\nb\n")

        let result = await runEdit(path: "w.txt", oldText: "1\n2\n3\n4", newText: "x")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("ANCHOR_NOT_FOUND"))
        XCTAssertTrue(result.outputJSON.contains("more lines (4) than the file (2)"), result.outputJSON)
    }

    /// Ambiguity of the model's LITERAL anchor is terminal: it demonstrably exists
    /// in several places, so letting a transformed candidate (here JSON-unescaped)
    /// edit its own unique match elsewhere would be a wrong-location guess.
    func testAmbiguousRawAnchor_terminal_evenWhenTransformMatchesUniquely() async throws {
        let original = "url = \"a\\/b\"  \nnext\nurl = \"a\\/b\"\t\nnext\nurl = \"a/b\" \nnext\ntail\n"
        let url = try writeFile("x.txt", original)

        // Raw anchor (with \/) tolerantly matches regions 1 and 2; the unescaped
        // anchor (with /) would match region 3 uniquely — it must NOT win.
        let result = await runEdit(path: "x.txt", oldText: "url = \"a\\/b\"\nnext", newText: "REPLACED\nnext")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("ANCHOR_AMBIGUOUS"), result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original, "file must be untouched")
    }

    /// A TRANSFORMED candidate's ambiguity is non-terminal in the loop, but when no
    /// candidate matches uniquely it still surfaces as ANCHOR_AMBIGUOUS (the raw
    /// gutter-prefixed anchor matches nothing, the stripped one matches twice).
    func testAmbiguousStrippedCandidate_rawMatchesNothing_reportsAmbiguous() async throws {
        let original = "m  \nn\nz\nm\t\nn\n"
        let url = try writeFile("x2.txt", original)

        let result = await runEdit(path: "x2.txt", oldText: "1   \u{2502} m\n2   \u{2502} n", newText: "X")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("ANCHOR_AMBIGUOUS"), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("matches 2 regions"), result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original, "file must be untouched")
    }

    /// A fuzzy-matched edit discloses itself in the success envelope so the model
    /// knows the file's bytes differed from its anchor.
    func testTolerantSuccess_disclosesFuzzyMatch() async throws {
        _ = try writeFile("y.txt", "alpha  \nbeta\n")

        let result = await runEdit(path: "y.txt", oldText: "alpha\nbeta", newText: "ALPHA\nbeta")

        XCTAssertFalse(result.isError)
        XCTAssertEqual(dataField(result, "matched_ignoring_trailing_whitespace") as? Bool, true, result.outputJSON)
    }

    func testExactSuccess_omitsFuzzyDisclosure() async throws {
        _ = try writeFile("z.txt", "alpha\nbeta\n")

        let result = await runEdit(path: "z.txt", oldText: "alpha\nbeta", newText: "ALPHA\nbeta")

        XCTAssertFalse(result.isError)
        XCTAssertFalse(result.outputJSON.contains("matched_ignoring_trailing_whitespace"), result.outputJSON)
    }

    // MARK: - Corner cases: terminator semantics

    /// "a\n\n" drops exactly ONE trailing newline as terminator — the remaining
    /// empty component is an intentional blank-line requirement and is honored.
    func testTerminatorAnchor_keepsIntentionalBlankLineRequirement() async throws {
        let url = try writeFile("ca.txt", "a  \n\t\nx\n")

        // Anchor: line "a" + one required blank line (+ terminator).
        let result = await runEdit(path: "ca.txt", oldText: "a\n\n", newText: "b")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "b\nx\n")
    }

    /// The negative twin: the blank-line requirement left after dropping the
    /// terminator must NOT be satisfied by a non-blank line.
    func testTerminatorAnchor_blankLineRequirement_notFoundWithoutBlank() async throws {
        let url = try writeFile("cb.txt", "a\nx\n")

        let result = await runEdit(path: "cb.txt", oldText: "a\n\n", newText: "b")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("ANCHOR_NOT_FOUND"))
        XCTAssertFalse(result.outputJSON.contains("ignoring indentation"), result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\nx\n", "file must be untouched")
    }

    /// A terminator anchor matches a file whose last line has NO final newline;
    /// the file's no-final-newline shape is preserved.
    func testTerminatorAnchor_fileWithoutTrailingNewline() async throws {
        let url = try writeFile("cc.txt", "a  \nb")

        let result = await runEdit(path: "cc.txt", oldText: "a\nb\n", newText: "c\nd\n")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "c\nd")
    }

    /// LF terminator anchor against a CRLF file: the model types "\n" from read
    /// output, the file ends lines with "\r\n" — both diffs are invisible to it.
    /// The replaced line stays CRLF so the file's convention isn't eroded.
    func testLFTerminatorAnchor_onCRLFFile() async throws {
        let url = try writeFile("cd.txt", "alpha\r\nbeta\r\n")

        let result = await runEdit(path: "cd.txt", oldText: "alpha\n", newText: "ALPHA")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "ALPHA\r\nbeta\r\n")
    }

    /// Reverse line-ending direction: CRLF anchor (copied from another tool or
    /// hallucinated) against an LF file.
    func testCRLFAnchor_onLFFile() async throws {
        let url = try writeFile("ce.txt", "a\nb\nz\n")

        let result = await runEdit(path: "ce.txt", oldText: "a\r\nb", newText: "A\nB")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "A\nB\nz\n")
    }

    /// new_text's own trailing newline on a NON-terminator anchor inserts a blank
    /// line — mirroring the exact path, which honors the extra "\n" verbatim.
    func testNewTextTrailingNewline_nonTerminatorAnchor_insertsBlankLine() async throws {
        let url = try writeFile("cf.txt", "a  \nb\nz\n")

        let result = await runEdit(path: "cf.txt", oldText: "a\nb", newText: "c\n")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "c\n\nz\n")
    }

    // MARK: - Corner cases: window boundaries

    /// The window may cover every line of the file.
    func testWholeFileWindow_replacesEntireFile() async throws {
        let url = try writeFile("cg.txt", "x  \ny\t\n")

        let result = await runEdit(path: "cg.txt", oldText: "x\ny", newText: "1\n2")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "1\n2\n")
    }

    func testEmptyFile_anchorLongerThanFile_hintsZeroLines() async throws {
        let url = try writeFile("ch.txt", "")

        let result = await runEdit(path: "ch.txt", oldText: "a\nb", newText: "x")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("ANCHOR_NOT_FOUND"))
        XCTAssertTrue(result.outputJSON.contains("more lines (2) than the file (0)"), result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "", "file must be untouched")
    }

    /// A clean blank line in the anchor matches a tab-only line in the file —
    /// tabs are as invisible as trailing spaces.
    func testBlankAnchorLine_matchesTabOnlyFileLine() async throws {
        let url = try writeFile("ci.txt", "a\n\t\nb\n")

        let result = await runEdit(path: "ci.txt", oldText: "a\n\nb", newText: "a\nb")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\nb\n")
    }

    /// Triple combo: gutter-prefixed anchor + trailing newline terminator +
    /// trailing whitespace in the file — every transform layer fires at once.
    func testGutterPlusTerminatorPlusTrailingWS_combo() async throws {
        let url = try writeFile("cj.txt", "a  \nb\n")

        let result = await runEdit(path: "cj.txt", oldText: "1   \u{2502} a\n2   \u{2502} b\n", newText: "X")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "X\n")
    }

    // MARK: - Corner cases: diagnostics and Unicode

    /// Multiple indentation-only matches: plural wording, 1-based numbers, and
    /// the list capped at the first three.
    func testIndentationHint_multipleWindows_pluralAndCappedAtThree() async throws {
        _ = try writeFile("ck.txt", "\tgo()  \nx\n\tgo()\ny\n\tgo()\nz\n\tgo()\n")

        let result = await runEdit(path: "ck.txt", oldText: "    go()", newText: "stop()")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("near lines 1, 3, 5"), result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("5, 7"), "line list must cap at three entries: \(result.outputJSON)")
    }

    /// Multibyte content (accents, emoji) with trailing whitespace — the per-line
    /// trim must operate on Characters, not bytes.
    func testUnicodeContent_trailingWSMatch() async throws {
        let url = try writeFile("cl.txt", "héllo 👋  \nnext\n")

        let result = await runEdit(path: "cl.txt", oldText: "héllo 👋\nnext", newText: "done\nnext")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "done\nnext\n")
    }

    /// A combining mark (U+0301) at the visual end of a line must survive the
    /// trailing trim: the trim walks grapheme clusters and stops at the first
    /// non-whitespace Character, never splitting or eating the accent.
    func testCombiningMarkAtLineEnd_notTrimmed() async throws {
        let url = try writeFile("cm.txt", "Cafe\u{0301}  \nnext\n")

        let result = await runEdit(path: "cm.txt", oldText: "Cafe\u{0301}\nnext", newText: "X\nnext")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "X\nnext\n")
    }

    /// Multi-window deletion: replace_all + terminator anchor + empty new_text
    /// removes every matched line — the most index-shift-sensitive splice shape.
    func testReplaceAllTerminatorAnchor_emptyNewText_deletesAllWindows() async throws {
        let url = try writeFile("co.txt", "foo \nA\nfoo\t\nB\n")

        let result = await runEdit(path: "co.txt", oldText: "foo\n", newText: "", replaceAll: true)

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(replacementsMade(in: result), 2)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "A\nB\n")
    }

    /// new_text of exactly "\n" with a terminator anchor REPLACES the line with a
    /// blank one (only a fully empty new_text deletes) — pins the `isEmpty` gate
    /// against a trimmed-emptiness "cleanup".
    func testTerminatorAnchor_newlineOnlyNewText_leavesBlankLine() async throws {
        let url = try writeFile("cp.txt", "foo \nrest\n")

        let result = await runEdit(path: "cp.txt", oldText: "foo\n", newText: "\n")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\nrest\n")
    }

    /// Boundary of the longer-than-file hint: anchor exactly ONE line longer than
    /// the file's real line count (the split sentinel must not mask the diagnosis).
    func testAnchorOneLineLongerThanFile_stillHintsLineCount() async throws {
        _ = try writeFile("cq.txt", "a\nb\n")

        let result = await runEdit(path: "cq.txt", oldText: "x\ny\nz", newText: "w")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("more lines (3) than the file (2)"), result.outputJSON)
    }

    /// replace_all through the tolerant path also discloses the fuzzy match.
    func testReplaceAllTolerant_disclosesFuzzyMatch() async throws {
        let url = try writeFile("cn.txt", "a  \nb\nc\na\t\nb\n")

        let result = await runEdit(path: "cn.txt", oldText: "a\nb", newText: "Q\nb", replaceAll: true)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(replacementsMade(in: result), 2)
        XCTAssertEqual(dataField(result, "matched_ignoring_trailing_whitespace") as? Bool, true, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Q\nb\nc\nQ\nb\n")
    }

    // MARK: - Corner cases: CRLF convention preservation

    /// EOL detection is PER WINDOW: in a mixed-EOL file, a CRLF window gets CRLF
    /// replacement lines while an LF window in the same replace_all gets LF.
    func testReplaceAll_mixedEOLWindows_eachKeepsOwnConvention() async throws {
        let url = try writeFile("da.txt", "k\r\nl\r\nz\nk  \nl\n")

        let result = await runEdit(path: "da.txt", oldText: "k\nl", newText: "X\nY", replaceAll: true)

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(replacementsMade(in: result), 2)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "X\r\nY\r\nz\nX\nY\n")
    }

    /// Deletion in a CRLF file: the CR-suffixing map over an empty replacement is
    /// a no-op and untouched lines keep their CRLF endings.
    func testCRLFWindow_emptyNewText_deletesLine() async throws {
        let url = try writeFile("db.txt", "foo \r\nrest\r\n")

        let result = await runEdit(path: "db.txt", oldText: "foo\n", newText: "")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "rest\r\n")
    }

    /// Replacing with a blank line in a CRLF file produces a blank CRLF line
    /// ("\r\n"), not a bare LF one.
    func testCRLFWindow_newlineOnlyNewText_leavesBlankCRLFLine() async throws {
        let url = try writeFile("dc.txt", "foo \r\nrest\r\n")

        let result = await runEdit(path: "dc.txt", oldText: "foo\n", newText: "\n")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\r\nrest\r\n")
    }

    /// Heuristic boundary, documented: a window whose last line sits at EOF with
    /// no line terminator has no "\r" on that line, so the window does not count
    /// as CRLF and the replacement is written with LF endings.
    func testCRLFWindowAtEOF_noTerminator_fallsBackToLF() async throws {
        let url = try writeFile("dd.txt", "alpha\r\nbeta")

        let result = await runEdit(path: "dd.txt", oldText: "alpha\nbeta", newText: "X\nY")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "X\nY")
    }

    // MARK: - Corner cases: ambiguity ordering and boundaries

    /// A unique raw match wins immediately — a transform that WOULD be ambiguous
    /// is never consulted (candidate order: raw → stripped → unescaped).
    func testRawUniqueMatch_winsBeforeTransformIsConsulted() async throws {
        // Raw anchor (with \/) matches only region 1; the unescaped variant (/)
        // would match regions 2 and 3 ambiguously.
        let url = try writeFile("de.txt", "p\\/q  \nw\np/q \nw\np/q\t\nw\n")

        let result = await runEdit(path: "de.txt", oldText: "p\\/q\nw", newText: "R\nw")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "R\nw\np/q \nw\np/q\t\nw\n"
        )
    }

    /// Recorded (transform) ambiguity is returned BEFORE the indentation pass runs:
    /// the file also contains a region that trimBoth would match (indented AND
    /// trailing-dirty, so it can't exact- or trailing-trim-match), but the answer
    /// stays ANCHOR_AMBIGUOUS, not the indentation hint.
    func testTransformAmbiguity_beatsIndentationHint() async throws {
        let original = "m  \nn\nz\nm\t\nn\n\tm  \nn\t\n"
        let url = try writeFile("df.txt", original)

        let result = await runEdit(path: "df.txt", oldText: "1   \u{2502} m\n2   \u{2502} n", newText: "X")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("ANCHOR_AMBIGUOUS"), result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("ignoring indentation"), result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original, "file must be untouched")
    }

    /// Whole-file window + empty terminator new_text empties the file entirely.
    func testWholeFileWindow_emptyNewText_emptiesFile() async throws {
        let url = try writeFile("dg.txt", "a  \nb\n")

        let result = await runEdit(path: "dg.txt", oldText: "a\nb\n", newText: "")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "")
    }

    /// The longer-than-file hint also fires for files WITHOUT a trailing newline
    /// (no split sentinel to adjust for).
    func testAnchorLongerThanFile_noTrailingNewlineFile() async throws {
        _ = try writeFile("dh.txt", "a\nb")

        let result = await runEdit(path: "dh.txt", oldText: "x\ny\nz", newText: "w")

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.outputJSON.contains("more lines (3) than the file (2)"), result.outputJSON)
    }
}
