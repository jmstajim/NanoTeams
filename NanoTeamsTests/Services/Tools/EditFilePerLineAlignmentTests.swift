import XCTest

@testable import NanoTeams

/// Per-line alignment for tiers 3 / 3.5, distilled from CubeCraft task 7 run 0 —
/// the fourth field family after task 24 (irregular file, `EditFileRealRunRegressionTests`),
/// task 28 (insertion, `EditFileInsertionReindentTests`) and task 32 (rewrite,
/// `EditFileRewriteReindentTests`).
///
/// Task 7's signature: 10 of 24 `edit_file` calls refused (41.7%), all
/// `ANCHOR_NOT_FOUND` from located-but-refused arms, in three classes:
///
/// 1. MID-INSERTION "sandwich" (6 of 10): the model keeps the anchor's head AND
///    tail and inserts new lines between. `freeRegion` recognised only the two
///    end-anchored shapes, so a split anchor had no free region and the new
///    block's own depths (5-space array rows, 6/9/12-space function bodies)
///    refused the whole edit.
/// 2. ONE ANCHOR DEPTH ↔ TWO FILE DEPTHS (3 of 10): the depth map hit a
///    conflicted key and refused — while each anchor line pairs with exactly ONE
///    file line, so per line the answer was always known. The irregularity was
///    SELF-INFLICTED: a successful append 40 seconds earlier wrote the model's
///    own 3/4/6-space block verbatim into a 2-space file, and every later anchor
///    over that region straddled the two conventions.
/// 3. GROW-IN-PLACE rewrite (1 of 10): rewritten window plus new content,
///    neither end aligned, new depths outside the map.
///
/// The fix dissolves the per-depth abstraction where it was refusing: replacement
/// lines PAIR with window lines (positionally when counts match, greedy in-order
/// otherwise), a paired line takes its OWN file line's whitespace, and only the
/// unpaired remainder consults the depth map — all-or-nothing, exactly as the
/// free region did. Refusal remains only for ambiguity (several windows).
final class EditFilePerLineAlignmentTests: XCTestCase {
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

    // MARK: - Helpers (mirrors EditFileRewriteReindentTests)

    @discardableResult
    private func writeFile(_ name: String, _ lines: [String]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func onDisk(_ name: String) throws -> [String] {
        try String(contentsOf: tempDir.appendingPathComponent(name), encoding: .utf8)
            .components(separatedBy: "\n")
    }

    private func runEdit(path: String, oldText: String, newText: String) async -> ToolExecutionResult {
        let args: [String: Any] = ["path": path, "old_text": oldText, "new_text": newText]
        let data = try! JSONSerialization.data(withJSONObject: args)
        let call = StepToolCall(name: "edit_file", argumentsJSON: String(data: data, encoding: .utf8)!)
        return await runtime.executeAll(context: context, toolCalls: [call])[0]
    }

    private func envelope(_ result: ToolExecutionResult) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any]) ?? [:]
    }

    private func message(_ result: ToolExecutionResult) -> String {
        (envelope(result)["error"] as? [String: Any])?["message"] as? String ?? ""
    }

    private func dataField(_ result: ToolExecutionResult, _ key: String) -> Any? {
        (envelope(result)["data"] as? [String: Any])?[key]
    }

    private func warnings(_ result: ToolExecutionResult) -> [String] {
        ((envelope(result)["meta"] as? [String: Any])?["warnings"] as? [String]) ?? []
    }

    // MARK: - Class 1: mid-insertion sandwich, interior tier (run idx 12)

    /// Run idx 12 (16:52:10): the anchor reproduced an aligned-constant line with
    /// the model's own interior padding (tier 3.5 territory), kept the anchor's
    /// last two lines as the tail, and inserted a constants block between — whose
    /// 5-space rows were no map key, so the whole edit was refused with
    /// `interior_whitespace_mismatch` even though the window was unique.
    ///
    /// Depth vocabulary preserved from the run: 2-space file, 3-space model
    /// reproductions, 5-space new rows, a whitespace-only "blank" in the anchor.
    ///
    /// RED: refuse when an unpaired depth is not a map key (the shipped
    /// `return nil`) → `isError` flips and every assert below fails.
    func testSandwichInsertion_interiorTier_landsWithFileBytesForTheReproducedLines() async throws {
        try writeFile("game.js", [
            "  const JUMP  = 8;      // px",
            "",
            "  // save key",
            "  const KEY = \"v1\";",
        ])

        let result = await runEdit(
            path: "game.js",
            oldText: [
                "   const JUMP   = 8;       // px",  // 3sp + interior drift
                "  ",                                 // model wrote spaces on the blank
                "   // save key",                     // 3sp
                "   const KEY = \"v1\";",             // 3sp
            ].joined(separator: "\n"),
            newText: [
                "   const JUMP   = 8;       // px",
                "  ",
                "   const DAY   = 150;     // s",     // 3sp — new
                "   const KEYS = [",                  // 3sp — new
                "     [0.00, 10],",                   // 5sp — new, no map key
                "   ];",                              // 3sp — new
                "  ",
                "   // save key",
                "   const KEY = \"v1\";",
            ].joined(separator: "\n"))

        XCTAssertFalse(result.isError, result.outputJSON)
        let written = try onDisk("game.js")
        // Reproduced lines carry the FILE's bytes — its interior alignment and
        // 2-space convention survive.
        XCTAssertEqual(written[0], "  const JUMP  = 8;      // px")
        XCTAssertEqual(written[1], "")
        XCTAssertEqual(written[7], "  // save key")
        XCTAssertEqual(written[8], "  const KEY = \"v1\";")
        // The inserted block straddles the map (5sp is no key), so it lands
        // verbatim, entire — the model's bytes, nesting intact.
        XCTAssertEqual(written[2], "   const DAY   = 150;     // s")
        XCTAssertEqual(written[4], "     [0.00, 10],")
        XCTAssertEqual(dataField(result, "matched_ignoring_interior_whitespace") as? Bool, true)
        XCTAssertTrue(warnings(result).contains { $0.contains("kept your own indentation") },
                      "the pass-through must be disclosed: \(warnings(result))")
    }

    // MARK: - Class 1: mid-insertion sandwich, indentation tier (run idx 19/26/55)

    /// Run idx 19 (16:55:13): head + blank + tail anchor around an inserted
    /// function whose body depths (6/9sp) no 3-line anchor could have shown.
    /// The refusal told the model to "check leading whitespace (tabs vs spaces)"
    /// about an anchor that was never the problem.
    ///
    /// RED: refuse when an unpaired depth is not a map key → `isError` flips.
    func testSandwichInsertion_indentationTier_lands() async throws {
        try writeFile("game.js", [
            "   let t = 0.30; // morning",   // 3sp — the file is irregular here
            "",
            "  // ids",                       // 2sp
        ])

        let result = await runEdit(
            path: "game.js",
            oldText: [
                "   let t = 0.30; // morning",
                "",
                "    // ids",                 // 4sp — model's guess at the tail
            ].joined(separator: "\n"),
            newText: [
                "   let t = 0.30; // morning",
                "",
                "   function sky(t) {",       // 3sp — new
                "      let a = KEYS[0];",     // 6sp — new, no map key
                "   }",                       // 3sp — new
                "",
                "    // ids",
            ].joined(separator: "\n"))

        XCTAssertFalse(result.isError, result.outputJSON)
        let written = try onDisk("game.js")
        XCTAssertEqual(written[0], "   let t = 0.30; // morning")
        XCTAssertEqual(written[6], "  // ids", "the reproduced tail takes its own file line's indentation")
        XCTAssertEqual(written[3], "      let a = KEYS[0];", "the new body keeps the model's bytes")
    }

    /// Run idx 43 (16:58:34): the sandwich whose new block ends in its own `}` —
    /// under the shipped code the suffix arm FALSE-aligned on that brace
    /// (trim-equal to the anchor's closer), pulled the real closer inside the
    /// "window", and refused on its depth. Per-line pairing is order-preserving,
    /// so the head `}` pairs first and the block's own `}` is honestly new.
    ///
    /// RED: refuse when an unpaired depth is not a map key → `isError` flips.
    func testSandwichWhoseNewBlockEndsInABrace_pairsInOrder() async throws {
        try writeFile("style.html", [
            "     }",          // 5sp
            "  </style>",      // 2sp
        ])

        let result = await runEdit(
            path: "style.html",
            oldText: [
                "      }",         // 6sp
                "   </style>",     // 3sp
            ].joined(separator: "\n"),
            newText: [
                "      }",
                "     #clock {",   // 5sp — new
                "      left: 0;",  // 6sp — new
                "       }",        // 7sp — new: the block's own closer
                "   </style>",
            ].joined(separator: "\n"))

        XCTAssertFalse(result.isError, result.outputJSON)
        let written = try onDisk("style.html")
        XCTAssertEqual(written[0], "     }", "the anchor's closer takes the file's 5sp, in order")
        XCTAssertEqual(written[3], "       }", "the new block's own closer stays the model's")
        XCTAssertEqual(written[4], "  </style>")
    }

    // MARK: - Class 2: one anchor depth ↔ two file depths (run idx 21/40/61)

    /// Run idx 61 (17:00:35): a pure same-count rewrite of `saveWorld()` whose
    /// window closes at 3sp beside a 4sp body — the anchor's `"    "` mapped to
    /// two file depths and the map refused, though ten of thirteen lines were
    /// byte-reproductions each pairing with exactly one file line.
    ///
    /// RED: restore the conflicted-key `return nil` in the map builder → the
    /// refusal returns and `isError` flips.
    func testPureRewriteOverAnIrregularWindow_mapConflictDissolvesPerLine() async throws {
        try writeFile("game.js", [
            "  function save() {",
            "    body();",
            "   }",              // 3sp — irregular beside the 4sp body
        ])

        let result = await runEdit(
            path: "game.js",
            oldText: [
                "  function save() {",
                "    body();",
                "    }",         // 4sp — same key as the body line → the old conflict
            ].joined(separator: "\n"),
            newText: [
                "  function save(silent) {",   // changed
                "    body(silent);",           // changed
                "    }",                       // reproduced
            ].joined(separator: "\n"))

        XCTAssertFalse(result.isError, result.outputJSON)
        let written = try onDisk("game.js")
        XCTAssertEqual(written[0], "  function save(silent) {")
        XCTAssertEqual(written[1], "    body(silent);")
        XCTAssertEqual(written[2], "   }",
                       "the reproduced closer takes ITS file line's 3sp — the conflict never existed per line")
    }

    /// Run idx 21 (16:55:30): the sandwich variant of the same conflict — the
    /// anchor's head and tail sit at ONE model depth while the file has them at
    /// two (3sp and 2sp, the head written by the run itself 40 seconds earlier).
    ///
    /// RED: restore the conflicted-key `return nil` → `isError` flips.
    func testSandwichOverSelfPoisonedIndentation_lands() async throws {
        try writeFile("game.js", [
            "   let t = 0.30;",   // 3sp — the model's own earlier insert
            "",
            "  // ids",           // 2sp — the file's original convention
        ])

        let result = await runEdit(
            path: "game.js",
            oldText: [
                "   let t = 0.30;",
                "",
                "   // ids",       // 3sp — same key as the head, file says 2sp
            ].joined(separator: "\n"),
            newText: [
                "   let t = 0.30;",
                "",
                "   function sky(t) { return t; }",  // 3sp — new; its key is conflicted
                "",
                "   // ids",
            ].joined(separator: "\n"))

        XCTAssertFalse(result.isError, result.outputJSON)
        let written = try onDisk("game.js")
        XCTAssertEqual(written[0], "   let t = 0.30;")
        XCTAssertEqual(written[4], "  // ids", "the tail pairs with its own 2sp file line")
        XCTAssertEqual(written[2], "   function sky(t) { return t; }",
                       "the conflicted key is unusable, so the new line keeps the model's bytes")
    }

    // MARK: - Class 3: grow-in-place rewrite (run idx 31)

    /// Run idx 31 (16:57:03): the window rewritten (first line's comment changed)
    /// AND grown — neither end reproduces the anchor, and the new sun-disc block
    /// carried depths (7sp) the anchor never showed.
    ///
    /// RED: refuse when an unpaired depth is not a map key → `isError` flips.
    func testGrowInPlaceRewrite_unmappedNewDepths_lands() async throws {
        try writeFile("game.js", [
            "    // Sky backgrounds.",
            "    const h = clamp(H);",
            "    fill(sky);",
        ])

        let result = await runEdit(
            path: "game.js",
            oldText: [
                "      // Sky backgrounds.",   // 6sp
                "     const h = clamp(H);",    // 5sp
                "     fill(sky);",             // 5sp
            ].joined(separator: "\n"),
            newText: [
                "      // Sky with day/night colours.",  // changed — unpaired
                "     const info = interp(t);",          // new
                "     const h = clamp(H);",              // reproduced
                "     fill(sky);",                       // reproduced
                "     if (y > -0.1) {",                  // new, 5sp
                "       arc(x, y);",                     // new, 7sp — no map key
                "     }",                                // new, 5sp
            ].joined(separator: "\n"))

        XCTAssertFalse(result.isError, result.outputJSON)
        let written = try onDisk("game.js")
        XCTAssertEqual(written[2], "    const h = clamp(H);", "reproduced lines take the file's 4sp")
        XCTAssertEqual(written[3], "    fill(sky);")
        XCTAssertEqual(written[5], "       arc(x, y);", "the new block keeps the model's bytes, entire")
    }

    // MARK: - The properties that keep the rescue as safe as the refusal was

    /// The all-or-nothing rule survives the move from `freeRegion` to pairing: an
    /// unpaired set that STRADDLES the key set is emitted verbatim, entire. Here a
    /// 2-space model meets a 4-space file (map {2→4}) and inserts a block at
    /// 4/6/4 mid-window: translating the mapped 4s and keeping the 6 would land
    /// the child SHALLOWER than its own opener.
    ///
    /// RED: translate unpaired lines per-line through the map (drop the
    /// all-or-nothing gate) → the opener lands at 8sp, the child at 6sp, and the
    /// nesting assert fails.
    func testUnpairedSetStraddlingTheKeys_isKeptVerbatimEntire() async throws {
        try writeFile("f.py", [
            "    def f():",
            "        g()",
        ])

        let result = await runEdit(
            path: "f.py",
            oldText: [
                "  def f():",     // 2sp model vs 4sp file → map {2→4}
                "    g()",        // 4sp → 8sp
            ].joined(separator: "\n"),
            newText: [
                "  def f():",
                "    if x:",      // 4sp — a key
                "      h()",      // 6sp — NOT a key
                "    g()",
            ].joined(separator: "\n"))

        XCTAssertFalse(result.isError, result.outputJSON)
        let written = try onDisk("f.py")
        XCTAssertEqual(written[0], "    def f():")
        XCTAssertEqual(written[3], "        g()")
        // The block keeps its own nesting: child deeper than opener.
        let opener = written[1].prefix { $0 == " " }.count
        let child = written[2].prefix { $0 == " " }.count
        XCTAssertGreaterThan(child, opener, "nesting inside the inserted block must survive: \(written)")
        XCTAssertEqual(written[1], "    if x:")
        XCTAssertEqual(written[2], "      h()")
    }

    /// Pairing is positional when the counts match: a line the model MOVED must
    /// not steal a later window line's bytes — reordering is not "merely
    /// reproduced". The interior tier makes the theft observable: the stolen file
    /// line would carry the FILE's padding, the honest translation carries the
    /// model's. (Same rule `fileBytesForReproducedLines` carried; this pins it on
    /// the reindent decision.)
    ///
    /// RED: pair greedily for equal counts too → position 0 steals the file's
    /// `b()   // y` padding and the first equality fails.
    func testEqualCountReorder_staysTheModelsBytes() async throws {
        try writeFile("f.swift", [
            "    a()  // x",
            "    b()   // y",
        ])

        let result = await runEdit(
            path: "f.swift",
            oldText: [
                "   a() // x",    // 3sp, collapsed interior — tier 3.5 territory
                "   b() // y",
            ].joined(separator: "\n"),
            newText: [
                "   b() // y",    // swapped
                "   a() // x",
            ].joined(separator: "\n"))

        XCTAssertFalse(result.isError, result.outputJSON)
        let written = try onDisk("f.swift")
        // Both positions are unpaired (position 0 is not `a()`, position 1 is not
        // `b()`), the map {3→4} covers them, so the swap is translated as new
        // content — with the MODEL's interior bytes, never the other line's file
        // bytes.
        XCTAssertEqual(written[0], "    b() // y")
        XCTAssertEqual(written[1], "    a() // x")
    }

    /// Ambiguity is the one refusal the rescue keeps: several windows match
    /// ignoring indentation, and editing one would be a wrong-location guess.
    ///
    /// RED: edit the first of several trimBoth windows → `isError` flips and the
    /// wrong region is written.
    func testSeveralWindows_stillRefuse() async throws {
        try writeFile("dup.swift", [
            "    row()",
            "separator()",
            "  row()",
        ])

        let result = await runEdit(
            path: "dup.swift",
            oldText: "     row()",   // 5sp — deeper than both, so the exact tier misses
            newText: "     column()")

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(message(result).contains("ignoring indentation"), message(result))
        XCTAssertEqual(try onDisk("dup.swift")[0], "    row()", "a refusal must not write")
    }

    /// A tier-3 edit whose only difference is leading whitespace collapses into a
    /// byte no-op (the file's indentation wins on both sides) and must say so —
    /// `replacements_made: 1` alone would present a formatting change that never
    /// landed as a clean success, and a formatting-intent model would retry
    /// forever. Mirrors the interior tier's existing no-op disclosure.
    ///
    /// RED: gate the no-op warning on the interior flag only → no warning here
    /// and the contains assert fails.
    func testLeadingOnlyFormattingIntent_disclosesTheNoOp() async throws {
        try writeFile("f.swift", [
            "   body()",   // 3sp — the "wrong" indentation the model wants to fix
        ])

        let result = await runEdit(
            path: "f.swift",
            oldText: "    body()",   // 4sp — misses exactly, matches trimBoth
            newText: "  body()")     // 2sp — pure formatting intent

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try onDisk("f.swift")[0], "   body()", "the file's indentation wins")
        XCTAssertTrue(
            warnings(result).contains { $0.contains("left the file unchanged") },
            "a formatting edit that landed nothing must disclose it: \(warnings(result))")
    }

    // MARK: - Direct unit pins on the reworked reindent

    /// The conflicted key is DROPPED from the map (unusable for unpaired lines),
    /// never a refusal — and paired lines never consult it at all.
    ///
    /// RED: restore `if let existing = map[key], existing != value { return nil }`
    /// → the function refuses and every assert here fails.
    func testReindent_conflictedKey_pairedLinesTakeTheirOwnFileLines() {
        let result = EditFileTool.reindentToFileConvention(
            newLines: [
                "    leading()",
                "    done()",     // changed line at the conflicted depth
                "    }",          // reproduced closer
            ],
            anchorLines: [
                "    leading()",
                "    trailing()",
                "    }",          // 4sp — same key as the content lines
            ],
            fileLines: [
                "    leading()",
                "    trailing()",
                "   }",           // 3sp — the conflict under the per-depth map
            ],
            tier: .leading)

        XCTAssertEqual(result.lines[0], "    leading()", "paired — its own file line")
        XCTAssertEqual(result.lines[2], "   }", "paired — its own file line, conflict or not")
        XCTAssertEqual(result.lines[1], "    done()",
                       "the changed line's depth key is conflicted → unusable → model bytes")
        XCTAssertEqual(result.passedThroughCount, 1)
        XCTAssertTrue(result.leadingRewritten, "the paired closer moved 4sp → 3sp")
    }

    /// Blank lines pair too, and a paired blank takes the file's spelling — the
    /// model's phantom spaces on a blank line must not land.
    ///
    /// RED: skip blank lines in the pairing (treat them as unpaired) → the model's
    /// `"  "` lands and the equality fails.
    func testReindent_pairedBlankLine_takesTheFilesSpelling() {
        let result = EditFileTool.reindentToFileConvention(
            newLines: ["  a()", "  ", "  b()"],
            anchorLines: ["  a()", "  ", "  b()"],
            fileLines: ["  a()", "", "  b()"],
            tier: .interior)

        XCTAssertEqual(result.lines, ["  a()", "", "  b()"])
        XCTAssertFalse(result.leadingRewritten,
                       "a blank line's whitespace is not indentation — no re-indent to disclose")
    }
}
