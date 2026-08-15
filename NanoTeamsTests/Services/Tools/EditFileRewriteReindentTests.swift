import XCTest

@testable import NanoTeams

/// The REWRITE shapes of tier-3 indentation tolerance, distilled from MeditationApp
/// task 32 run 0 — the third field family after task 24 (window replacement over an
/// irregular file, `EditFileRealRunRegressionTests`) and task 28 (insertion,
/// `EditFileInsertionReindentTests`).
///
/// Task 32's signature is the inverse of task 24: the FILE is perfectly regular
/// (4-space grid) and the MODEL is sloppy — block openers land on the grid, while
/// continuation lines and closing braces are off by one to three spaces, differently
/// on every retry. Four of eleven `edit_file` calls failed on one struct, in three
/// distinct sub-shapes this file pins:
///
/// 1. SHRINK rewrite (`new_text` shorter than the anchor): a free region is
///    impossible by construction (`freeRegion` requires `new > anchor`), so a single
///    unknown-depth line — one closing brace — refuses an edit whose every other
///    line was translatable (run edits #7, #10).
/// 2. GROW-IN-PLACE rewrite (longer, but new content interleaved rather than
///    appended/prepended): neither end reproduces the anchor, so there is no free
///    region and every line must be a map key — structurally impossible for
///    genuinely new nested code (run edit #8, a 31 → 84-line restructure).
/// 3. WINDOW-MAP CONFLICT from the sloppy side: the model wrote a closer at the
///    same depth as a content line, collapsing two file depths onto one key
///    (run edit #6).
///
/// Each refusal test carries a CONTROL — the same input with one depth moved onto a
/// map key — so the pin attributes the refusal to the exact line that caused it,
/// not merely to the shape.
final class EditFileRewriteReindentTests: XCTestCase {
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

    // MARK: - Fixture

    /// A regular 4-space file — the task-32 shape. Every fixture in this suite edits
    /// (a window of) this struct; the model-side anchors reproduce its CONTENT
    /// exactly and miss only on leading whitespace, which is what routes them past
    /// tiers 1–2 into the indentation tier.
    private static let cardFile = """
        struct Card {
            var body: Row {
                Row {
                    leading()
                    trailing()
                }
            }
        }

        """

    // MARK: - Helpers (mirrors EditFileIndentationToleranceTests)

    @discardableResult
    private func writeFile(_ name: String, _ content: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func runEdit(path: String, oldText: String, newText: String) -> ToolExecutionResult {
        let args: [String: Any] = ["path": path, "old_text": oldText, "new_text": newText]
        let data = try! JSONSerialization.data(withJSONObject: args)
        let call = StepToolCall(name: "edit_file", argumentsJSON: String(data: data, encoding: .utf8)!)
        return runtime.executeAll(context: context, toolCalls: [call])[0]
    }

    private func envelope(_ result: ToolExecutionResult) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any]) ?? [:]
    }

    private func message(_ result: ToolExecutionResult) -> String {
        (envelope(result)["error"] as? [String: Any])?["message"] as? String ?? ""
    }

    private func diagnosis(_ result: ToolExecutionResult) -> String? {
        ((envelope(result)["error"] as? [String: Any])?["details"] as? [String: String])?["diagnosis"]
    }

    private func dataField(_ result: ToolExecutionResult, _ key: String) -> Any? {
        (envelope(result)["data"] as? [String: Any])?[key]
    }

    private func warnings(_ result: ToolExecutionResult) -> [String] {
        ((envelope(result)["meta"] as? [String: Any])?["warnings"] as? [String]) ?? []
    }

    // MARK: - Shape 1: shrink rewrite (run edits #7, #10)

    /// CHOICE: refuse the whole edit, or translate the lines the map covers and let
    /// the one unknown-depth line through verbatim (per-line evidence). Refusal is
    /// the shipped design — an in-window unknown depth is "unplaceable" because a
    /// shrink has no free region by construction — and task 32 measured its cost:
    /// edits #7 and #10 both sent 8-line replacements refused over a single closing
    /// brace (at 9 and 10 spaces); every other non-blank line was map-translatable.
    /// FIXTURE: a 3-line shrink of a 4-line window; closer at 9 spaces against map
    /// keys {4, 8, 12, 13}. Distilled from MeditationApp task 32 run 0, edit #7.
    ///
    /// RED: pass an unmapped in-window depth through (`return nil` →
    /// `out.append(line)`) → the first assert sees a non-nil translation.
    func testCharacterization_shrinkRewrite_oneUnknownDepth_refusesTheWholeEdit() {
        let anchor = [
            "    var body: Row {",
            "        Row {",
            "            leading()",
            "             trailing()",  // 13 — the model's off-by-one; maps onto 12
        ]
        let file = [
            "    var body: Row {",
            "        Row {",
            "            leading()",
            "            trailing()",
        ]

        // The closer at 9 is the only line whose depth the anchor never showed.
        XCTAssertNil(
            EditFileTool.reindentToFileConvention(
                newLines: [
                    "    var body: Row {",
                    "        Row(compact: true)",
                    "         }",  // 9 — not a key
                ],
                anchorLines: anchor, fileLines: file))

        // CONTROL — same edit, closer moved onto the anchor's own sloppy key (13):
        // the map covers it and the whole edit translates. This attributes the
        // refusal above to the depth, not to the shrink shape.
        XCTAssertEqual(
            EditFileTool.reindentToFileConvention(
                newLines: [
                    "    var body: Row {",
                    "        Row(compact: true)",
                    "             }",  // 13 — a key, maps onto 12
                ],
                anchorLines: anchor, fileLines: file)?.lines,
            [
                "    var body: Row {",
                "        Row(compact: true)",
                "            }",
            ])
    }

    /// CHOICE: refuse, or resolve the closer's depth from the file line whose
    /// CONTENT it reproduces — the anchor's own closer pairs with a file line whose
    /// depth is individually known, so per-line alignment would answer where the
    /// per-depth map cannot. The shipped mechanism consults only the map, so the
    /// content match buys nothing.
    /// FIXTURE: a shrink whose refused `}` trim-matches the anchor's closing `}`.
    /// Distilled from MeditationApp task 32 run 0, edit #10.
    ///
    /// RED: fall back to the aligned file line's whitespace for a content-matched
    /// line → this returns non-nil and the assert fails.
    func testCharacterization_shrinkRewrite_contentMatchedCloser_stillRefused() {
        XCTAssertNil(
            EditFileTool.reindentToFileConvention(
                newLines: [
                    "        Row {",
                    "            content()",
                    "          }",  // 10 — unknown, though `}` matches the anchor's closer
                ],
                anchorLines: [
                    "        Row {",
                    "            leading()",
                    "            trailing()",
                    "         }",  // 9 → maps onto the file's 8
                ],
                fileLines: [
                    "        Row {",
                    "            leading()",
                    "            trailing()",
                    "        }",
                ]))
    }

    // MARK: - Shape 2: grow-in-place rewrite (run edit #8)

    /// CHOICE: refuse, or classify per line — lines reproducing the window translate,
    /// interleaved new content passes through under the existing all-or-nothing rule,
    /// as the append/prepend forms already do. The shipped `freeRegion` recognises
    /// only those two end-anchored forms, so a restructure that grows in the middle
    /// has no free region and every line must be a map key.
    /// FIXTURE: a 9-line rewrite of an 8-line window: one inserted member breaks
    /// prefix alignment, one new modifier sits at depth 14 outside keys
    /// {0, 4, 8, 9, 12}. Distilled from MeditationApp task 32 run 0, edit #8 —
    /// a 31 → 84-line restructure whose 32 new-code lines could not all be keys.
    ///
    /// RED: pass an unmapped in-window depth through instead of refusing → the
    /// refusal assert sees a translation.
    func testCharacterization_growInPlaceRewrite_unknownDepthInterleaved_isRefused() {
        let anchor = Self.sloppyWholeStructAnchor
        let file = Self.cardFile.components(separatedBy: "\n").dropLast().map { $0 }

        XCTAssertNil(
            EditFileTool.reindentToFileConvention(
                newLines: Self.restructuredLines(modifierIndent: 14),
                anchorLines: anchor, fileLines: file))

        // CONTROL — the identical restructure with the modifier on a mapped depth
        // (12) translates whole, closer 9 → 8 included. The refusal above is about
        // the one depth, not about growing in place.
        XCTAssertEqual(
            EditFileTool.reindentToFileConvention(
                newLines: Self.restructuredLines(modifierIndent: 12),
                anchorLines: anchor, fileLines: file)?.lines,
            [
                "struct Card {",
                "    let style: Style",
                "    var body: Row {",
                "        Row {",
                "            content()",
                "            .styled(style)",
                "        }",
                "    }",
                "}",
            ])
    }

    /// The discriminating pair for the shape rule: the SAME unknown-depth block is
    /// accepted verbatim when appended after a full reproduction of the anchor (the
    /// task-28 free region) and refused when the reproduction is broken by one
    /// inserted line.
    ///
    /// CHOICE: end-anchored free-region detection, or alignment-based detection that
    /// finds the reproduced lines wherever they sit. End-anchored is the shipped
    /// task-28 design; task 32 edit #8 measured what it misses — the model's most
    /// natural big edit, "replace this struct with a larger version of itself".
    /// FIXTURE: one block at depth 14 (not a key), once appended, once interleaved.
    ///
    /// RED: derive the free region from length alone (`newCount > anchorCount` ⇒
    /// everything past the window is free) → the interleaved arm stops refusing.
    func testCharacterization_sameUnknownDepths_acceptedAsAppend_refusedWhenInterleaved() {
        let anchor = Self.sloppyWholeStructAnchor
        let file = Self.cardFile.components(separatedBy: "\n").dropLast().map { $0 }
        let newBlock = [
            "",
            "    func styledRow() {",
            "              deep()",  // 14 — not a key
            "    }",
        ]

        // Appended after the reproduced anchor: free region, block kept verbatim.
        let appended = EditFileTool.reindentToFileConvention(
            newLines: anchor + newBlock,
            anchorLines: anchor, fileLines: file)
        XCTAssertEqual(appended?.lines, file + newBlock)
        XCTAssertEqual(appended?.passedThroughCount, 3)

        // The same lines with ONE member inserted into the reproduction: no free
        // region, and the depth-14 line refuses the whole edit.
        var interleaved = anchor
        interleaved.insert("    let style: Style", at: 1)
        XCTAssertNil(
            EditFileTool.reindentToFileConvention(
                newLines: interleaved + newBlock,
                anchorLines: anchor, fileLines: file))
    }

    /// The capability the refusals above are NOT about: a grow-in-place rewrite whose
    /// every depth IS a map key translates — including the sloppy closer — with
    /// nothing passed through. Undocumented until task 32 made the distinction
    /// load-bearing.
    ///
    /// RED: refuse any longer-than-anchor rewrite that fails both `freeRegion` arms
    /// (treat no-free-region as terminal) → this returns nil.
    func testGrowInPlaceRewrite_everyDepthMapped_isTranslated() {
        let result = EditFileTool.reindentToFileConvention(
            newLines: Self.restructuredLines(modifierIndent: 12),
            anchorLines: Self.sloppyWholeStructAnchor,
            fileLines: Self.cardFile.components(separatedBy: "\n").dropLast().map { $0 })

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.passedThroughCount, 0, "fully mapped — nothing kept the model's depths")
    }

    // MARK: - Shape 3: the sloppy-model map conflict (run edit #6)

    /// CHOICE: refuse on the conflicting key, or resolve per line — each anchor line
    /// pairs with exactly one file line, so the two depths are only ambiguous in the
    /// per-depth map abstraction, never per line. Refusal is the shipped rule ("one
    /// key → two values ⇒ the right answer is unknown"), recorded for the irregular-
    /// FILE direction in task 24; this pins the mirror direction that actually fired
    /// in task 32 — a sloppy MODEL against a perfectly regular file.
    /// FIXTURE: an anchor whose closing `}` sits at its CONTENT lines' depth (12),
    /// while the file closes at 8. Distilled from task 32 run 0, edit #6.
    ///
    /// RED: keep only the last value for a duplicated key instead of refusing → the
    /// conflict arm returns a translation and the nil assert fails.
    func testCharacterization_anchorCloserAtContentDepth_conflictsTheMap() {
        let file = [
            "            leading()",
            "            trailing()",
            "        }",
        ]

        // Closer written at the content depth: key 12 → {12, 8} is not a function.
        XCTAssertNil(
            EditFileTool.reindentToFileConvention(
                newLines: ["            done()"],
                anchorLines: [
                    "            leading()",
                    "            trailing()",
                    "            }",  // 12 — same key as the content lines
                ],
                fileLines: file))

        // CONTROL — the closer merely off-by-one (13) is its own key, the map is a
        // function, and the edit repairs. The conflict above is what the model's
        // specific mistake (closer at content depth) costs.
        XCTAssertEqual(
            EditFileTool.reindentToFileConvention(
                newLines: ["            done()", "             }"],
                anchorLines: [
                    "            leading()",
                    "            trailing()",
                    "             }",  // 13 — distinct key onto 8
                ],
                fileLines: file)?.lines,
            ["            done()", "        }"])
    }

    // MARK: - End-to-end: the envelope the model saw

    /// The misdiagnosis measured in the field: the refusal was CAUSED by a `new_text`
    /// line, but the message speaks only about the anchor and the file's window —
    /// "check leading whitespace", the window's bytes, a column-0 anchor hint. The
    /// task-32 model obeyed and perturbed its ANCHOR's spaces across three retries
    /// (23 → 21 → 22 on the same line) while the anchor was never the problem.
    ///
    /// CHOICE: one state-neutral message for every `indentationMismatch` route (the
    /// shipped design, argued at the arm: three states share it and the column-0
    /// advice is right for all), or a split message that names the `new_text` line
    /// when the window itself was located and translatable.
    /// FIXTURE: the shape-1 shrink driven through the tool; the control proves the
    /// byte-identical anchor succeeds once `new_text`'s one depth is corrected.
    ///
    /// RED: name the offending `new_text` line in the refusal → the
    /// does-not-mention assert fails (and this characterization is retired).
    func testCharacterization_shrinkRefusalMessage_speaksOnlyOfTheAnchor_whileNewTextCausedIt() throws {
        let url = try writeFile("card.swift", Self.cardFile)
        let sloppyAnchor = "    var body: Row {\n        Row {\n            leading()\n             trailing()"

        let refused = runEdit(
            path: "card.swift",
            oldText: sloppyAnchor,
            newText: "    var body: Row {\n        Row(compact: true)\n         }")

        XCTAssertTrue(refused.isError, refused.outputJSON)
        XCTAssertEqual(diagnosis(refused), "indentation_mismatch")
        let text = message(refused)
        XCTAssertTrue(text.contains("ignoring indentation"), text)
        // Line-anchored on purpose: the sloppy anchor spells this line with 13 spaces,
        // and a bare 12-space needle is a SUFFIX of it — a message quoting the ANCHOR's
        // bytes instead of the file's would keep an unanchored contains() green.
        XCTAssertTrue(
            text.contains("\n            trailing()"),
            "the file window's exact bytes are the evidence handed over: \(text)")
        XCTAssertTrue(text.contains("column 0"), text)
        XCTAssertFalse(
            text.contains("new_text"),
            "characterized misdirection — the cause is never named: \(text)")
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8), Self.cardFile,
            "a refusal must leave the file untouched")

        // CONTROL — the byte-identical anchor with new_text's closer moved onto a
        // key (13): success, translated into the file's convention. The anchor the
        // message steered the model to rewrite was fine all along.
        let repaired = runEdit(
            path: "card.swift",
            oldText: sloppyAnchor,
            newText: "    var body: Row {\n        Row(compact: true)\n             }")

        XCTAssertFalse(repaired.isError, repaired.outputJSON)
        XCTAssertEqual(dataField(repaired, "matched_ignoring_indentation") as? Bool, true)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            """
            struct Card {
                var body: Row {
                    Row(compact: true)
                        }
                    }
                }
            }

            """)
    }

    /// The restructure task 32 was trying to land, distilled: a whole-struct rewrite
    /// with a new member and a new modifier, every depth on a map key. It translates
    /// end to end — sloppy closer repaired, disclosure set, no pass-through warning.
    /// This is the reference for what the field model SHOULD have emitted; edits #6
    /// and #8 failed only in how their depths strayed from this shape.
    ///
    /// RED: drop the tier-3 branch from `whitespaceTolerantEdit` → ANCHOR_NOT_FOUND.
    func testFullStructRestructure_allDepthsMapped_landsTranslated() throws {
        let url = try writeFile("card.swift", Self.cardFile)

        let result = runEdit(
            path: "card.swift",
            oldText: Self.sloppyWholeStructAnchor.joined(separator: "\n"),
            newText: Self.restructuredLines(modifierIndent: 12).joined(separator: "\n"))

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(dataField(result, "matched_ignoring_indentation") as? Bool, true)
        // Structural, not phrase-keyed: nothing pins the warning's wording positively,
        // so a contains() on its text would go silently vacuous the day it is reworded.
        // An empty warnings list survives any rewording and still reds a mutation that
        // fabricates a pass-through count on a fully-mapped edit.
        XCTAssertEqual(
            warnings(result), [],
            "fully mapped — no pass-through disclosure to make")
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            """
            struct Card {
                let style: Style
                var body: Row {
                    Row {
                        content()
                        .styled(style)
                    }
                }
            }

            """)
    }

    /// Shape 2 driven through the tool: the interleaved restructure is refused with
    /// the indentation diagnosis and the file is left byte-identical.
    ///
    /// CHOICE: same alternatives as the unit-level shape-2 pin — refuse, or classify
    /// reproduced lines per alignment and pass the interleaved remainder through as
    /// the append form already does; refusal is what shipped and what the field run
    /// paid for.
    /// FIXTURE: the shape-2 grow-in-place rewrite (modifier at 14) via `runEdit`.
    ///
    /// RED: pass unmapped in-window depths through → this splices and the
    /// unchanged-file assert fails.
    func testCharacterization_growInPlaceRestructure_isRefusedEndToEnd() throws {
        let url = try writeFile("card.swift", Self.cardFile)

        let result = runEdit(
            path: "card.swift",
            oldText: Self.sloppyWholeStructAnchor.joined(separator: "\n"),
            newText: Self.restructuredLines(modifierIndent: 14).joined(separator: "\n"))

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertEqual(diagnosis(result), "indentation_mismatch")
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8), Self.cardFile,
            "a refusal must leave the file untouched")
    }

    // MARK: - Shared model-side fixtures

    /// The whole `cardFile` struct as the model reproduces it: content exact, the
    /// `Row` closer off by one (9 instead of 8). Keys: {0, 4, 8, 9, 12}.
    private static let sloppyWholeStructAnchor = [
        "struct Card {",
        "    var body: Row {",
        "        Row {",
        "            leading()",
        "            trailing()",
        "         }",  // 9 — the one sloppy line; routes past tiers 1–2
        "    }",
        "}",
    ]

    /// The restructured struct: a member inserted at index 1 (which breaks the
    /// prefix-alignment of `freeRegion`), a rewritten `Row` body, and one modifier
    /// whose indent the caller chooses — 14 sits outside the map's keys, 12 on them.
    private static func restructuredLines(modifierIndent: Int) -> [String] {
        [
            "struct Card {",
            "    let style: Style",
            "    var body: Row {",
            "        Row {",
            "            content()",
            String(repeating: " ", count: modifierIndent) + ".styled(style)",
            "         }",  // 9 — mapped onto the file's 8
            "    }",
            "}",
        ]
    }
}
