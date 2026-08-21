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
/// distinct sub-shapes this file pins — each REFUSED under the shipped per-depth
/// map, and each now landing under per-line alignment (the CHOICE recorded on the
/// original characterizations, turned by CubeCraft task 7 where the same three
/// shapes cost 10 of 24 calls):
///
/// 1. SHRINK rewrite (`new_text` shorter than the anchor): the surviving lines pair
///    with their own window lines; an unknown-depth closer keeps the model's bytes
///    instead of refusing the whole edit (run edits #7, #10).
/// 2. GROW-IN-PLACE rewrite (longer, but new content interleaved rather than
///    appended/prepended): reproduced lines pair wherever they sit, the interleaved
///    remainder is new content under the all-or-nothing rule (run edit #8).
/// 3. WINDOW-MAP CONFLICT from the sloppy side: the model wrote a closer at the
///    same depth as a content line — two file depths on one key, which per line
///    was never ambiguous at all (run edit #6).
///
/// Each test keeps its CONTROL — the same input with one depth moved onto a map
/// key — so the pin attributes the OUTCOME DIFFERENCE to the exact line that
/// carries it, not merely to the shape.
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

    private func dataField(_ result: ToolExecutionResult, _ key: String) -> Any? {
        (envelope(result)["data"] as? [String: Any])?[key]
    }

    private func warnings(_ result: ToolExecutionResult) -> [String] {
        ((envelope(result)["meta"] as? [String: Any])?["warnings"] as? [String]) ?? []
    }

    // MARK: - Shape 1: shrink rewrite (run edits #7, #10)

    /// The task-32 refusal, landed: a shrink's surviving lines pair with their own
    /// window lines, and the one unknown-depth closer keeps the model's bytes
    /// instead of refusing the whole edit. Task 32 measured the refusal's cost:
    /// edits #7 and #10 both sent 8-line replacements refused over a single closing
    /// brace (at 9 and 10 spaces); every other non-blank line was translatable.
    /// FIXTURE: a 3-line shrink of a 4-line window; closer at 9 spaces against map
    /// keys {4, 8, 12, 13}. Distilled from MeditationApp task 32 run 0, edit #7.
    ///
    /// RED: refuse when an unpaired depth is not a map key (the retired
    /// `return nil`) → both `lines` asserts see a refusal shape.
    func testShrinkRewrite_oneUnknownDepth_landsWithTheModelsBytes() {
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

        // The closer at 9 pairs with nothing (the window has no `}`) and its depth
        // is no key — it drags the whole unpaired set to the model's bytes
        // (all-or-nothing), while the paired head keeps the file's.
        let result = EditFileTool.reindentToFileConvention(
            newLines: [
                "    var body: Row {",
                "        Row(compact: true)",
                "         }",  // 9 — not a key
            ],
            anchorLines: anchor, fileLines: file, tier: .leading)
        XCTAssertEqual(
            result.lines,
            [
                "    var body: Row {",
                "        Row(compact: true)",
                "         }",
            ])
        XCTAssertEqual(result.passedThroughCount, 2)

        // CONTROL — same edit, closer moved onto the anchor's own sloppy key (13):
        // the map covers the whole unpaired set and it translates. This attributes
        // the pass-through above to the depth, not to the shrink shape.
        XCTAssertEqual(
            EditFileTool.reindentToFileConvention(
                newLines: [
                    "    var body: Row {",
                    "        Row(compact: true)",
                    "             }",  // 13 — a key, maps onto 12
                ],
                anchorLines: anchor, fileLines: file, tier: .leading).lines,
            [
                "    var body: Row {",
                "        Row(compact: true)",
                "            }",
            ])
    }

    /// The CHOICE recorded on the original characterization, delivered: the closer's
    /// depth resolves from the file line whose CONTENT it reproduces — the anchor's
    /// own closer pairs with a file line whose depth is individually known, where
    /// the per-depth map could not answer.
    /// FIXTURE: a shrink whose `}` trim-matches the anchor's closing `}`.
    /// Distilled from MeditationApp task 32 run 0, edit #10.
    ///
    /// RED: drop the greedy pairing branch (positional only) → the closer stops
    /// pairing across the deleted lines and lands at the model's 10 spaces.
    func testShrinkRewrite_contentMatchedCloser_resolvesFromItsOwnFileLine() {
        let result = EditFileTool.reindentToFileConvention(
            newLines: [
                "        Row {",
                "            content()",
                "          }",  // 10 — pairs with the window's closer at 8
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
            ],
            tier: .leading)

        XCTAssertEqual(
            result.lines,
            [
                "        Row {",
                "            content()",
                "        }",
            ],
            "the closer takes its own file line's 8 spaces")
        XCTAssertEqual(result.passedThroughCount, 0)
    }

    // MARK: - Shape 2: grow-in-place rewrite (run edit #8)

    /// The CHOICE recorded on the original characterization, delivered: lines
    /// reproducing the window pair with it wherever they sit, and the interleaved
    /// new content passes through under the existing all-or-nothing rule, as the
    /// append/prepend forms always did.
    /// FIXTURE: a 9-line rewrite of an 8-line window: one inserted member breaks
    /// prefix alignment, one new modifier sits at depth 14 outside keys
    /// {0, 4, 8, 9, 12}. Distilled from MeditationApp task 32 run 0, edit #8 —
    /// a 31 → 84-line restructure whose 32 new-code lines could not all be keys.
    ///
    /// RED: refuse when an unpaired depth is not a map key → the first `lines`
    /// assert sees a refusal shape.
    func testGrowInPlaceRewrite_unknownDepthInterleaved_lands() {
        let anchor = Self.sloppyWholeStructAnchor
        let file = Self.cardFile.components(separatedBy: "\n").dropLast().map { $0 }

        // The modifier at 14 drags the unpaired set (inserted member, rewritten
        // body line, modifier) to the model's bytes; every reproduced line still
        // pairs — the sloppy closer included, repaired to the file's 8.
        let result = EditFileTool.reindentToFileConvention(
            newLines: Self.restructuredLines(modifierIndent: 14),
            anchorLines: anchor, fileLines: file, tier: .leading)
        XCTAssertEqual(
            result.lines,
            [
                "struct Card {",
                "    let style: Style",
                "    var body: Row {",
                "        Row {",
                "            content()",
                "              .styled(style)",
                "        }",
                "    }",
                "}",
            ])
        XCTAssertEqual(result.passedThroughCount, 3)

        // CONTROL — the identical restructure with the modifier on a mapped depth
        // (12) translates whole, nothing passed through. The pass-through above is
        // about the one depth, not about growing in place.
        XCTAssertEqual(
            EditFileTool.reindentToFileConvention(
                newLines: Self.restructuredLines(modifierIndent: 12),
                anchorLines: anchor, fileLines: file, tier: .leading).lines,
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

    /// The discriminating pair the shape rule USED to fail: the SAME unknown-depth
    /// block, once appended after a full reproduction of the anchor and once with
    /// that reproduction broken by one inserted line. End-anchored free-region
    /// detection accepted the first and refused the second; alignment-based pairing
    /// accepts both identically — the reproduced lines are found wherever they sit.
    ///
    /// RED: pair only against an end-anchored reproduction (require the replacement
    /// to open or close with the whole window) → the interleaved arm loses its
    /// pairs and the second `lines` assert fails.
    func testSameUnknownDepths_landRegardlessOfWhereTheReproductionSits() {
        let anchor = Self.sloppyWholeStructAnchor
        let file = Self.cardFile.components(separatedBy: "\n").dropLast().map { $0 }
        let newBlock = [
            "",
            "    func styledRow() {",
            "              deep()",  // 14 — not a key
            "    }",
        ]

        // Appended after the reproduced anchor: block kept verbatim.
        let appended = EditFileTool.reindentToFileConvention(
            newLines: anchor + newBlock,
            anchorLines: anchor, fileLines: file, tier: .leading)
        XCTAssertEqual(appended.lines, file + newBlock)
        XCTAssertEqual(appended.passedThroughCount, 3)

        // The same lines with ONE member inserted into the reproduction: the
        // reproduced lines still pair around it — sloppy closer repaired to the
        // file's 8 — and the member joins the block in the unpaired set
        // (4 pass-throughs, straddling keys {4, 14} → verbatim, entire).
        var interleaved = anchor
        interleaved.insert("    let style: Style", at: 1)
        let result = EditFileTool.reindentToFileConvention(
            newLines: interleaved + newBlock,
            anchorLines: anchor, fileLines: file, tier: .leading)
        var expected = file
        expected.insert("    let style: Style", at: 1)
        XCTAssertEqual(result.lines, expected + newBlock,
                       "reproduced lines repair to the file's bytes, new content keeps the model's")
        XCTAssertEqual(result.passedThroughCount, 4)
    }

    /// The capability the pass-throughs above are NOT about: a grow-in-place rewrite
    /// whose every depth IS a map key translates — including the sloppy closer —
    /// with nothing passed through. Undocumented until task 32 made the distinction
    /// load-bearing.
    ///
    /// RED: skip the depth-map translation for unpaired lines (verbatim always) →
    /// `passedThroughCount` reads 2.
    func testGrowInPlaceRewrite_everyDepthMapped_isTranslated() {
        let result = EditFileTool.reindentToFileConvention(
            newLines: Self.restructuredLines(modifierIndent: 12),
            anchorLines: Self.sloppyWholeStructAnchor,
            fileLines: Self.cardFile.components(separatedBy: "\n").dropLast().map { $0 },
            tier: .leading)

        XCTAssertEqual(result.passedThroughCount, 0, "fully mapped — nothing kept the model's depths")
    }

    // MARK: - Shape 3: the sloppy-model map conflict (run edit #6)

    /// The CHOICE recorded on the original characterization, delivered: each anchor
    /// line pairs with exactly one file line, so the two depths behind the old
    /// conflict refusal were only ambiguous in the per-depth abstraction, never per
    /// line. The conflicted key is dropped (unusable for unpaired lines) instead of
    /// refusing the edit.
    /// FIXTURE: an anchor whose closing `}` sits at its CONTENT lines' depth (12),
    /// while the file closes at 8. Distilled from task 32 run 0, edit #6.
    ///
    /// RED: restore the conflicted-key `return nil` → both arms see a refusal shape.
    func testAnchorCloserAtContentDepth_conflictedKeyIsDroppedNotRefused() {
        let file = [
            "            leading()",
            "            trailing()",
            "        }",
        ]

        // Closer written at the content depth: key 12 → {12, 8} conflicts and is
        // dropped, so the replacement's one (unpaired, 12-space) line keeps the
        // model's bytes.
        let conflicted = EditFileTool.reindentToFileConvention(
            newLines: ["            done()"],
            anchorLines: [
                "            leading()",
                "            trailing()",
                "            }",  // 12 — same key as the content lines
            ],
            fileLines: file,
            tier: .leading)
        XCTAssertEqual(conflicted.lines, ["            done()"])
        XCTAssertEqual(conflicted.passedThroughCount, 1)

        // CONTROL — the closer merely off-by-one (13) is its own key, the map is a
        // function, and the unpaired line translates (the model's `}` pairs with
        // the file's closer regardless). The pass-through above is what the
        // model's specific mistake (closer at content depth) still costs.
        XCTAssertEqual(
            EditFileTool.reindentToFileConvention(
                newLines: ["            done()", "             }"],
                anchorLines: [
                    "            leading()",
                    "            trailing()",
                    "             }",  // 13 — distinct key onto 8
                ],
                fileLines: file,
                tier: .leading).lines,
            ["            done()", "        }"])
    }

    // MARK: - End-to-end: the envelope the model sees

    /// The field shape behind the retired misdiagnosis: task 32's shrink was refused
    /// over one `new_text` depth while the message spoke only about the anchor, and
    /// the model perturbed its ANCHOR's spaces across three retries (23 → 21 → 22 on
    /// the same line). The refusal route no longer exists — the shrink lands, the
    /// unknown-depth closer keeps the model's bytes, and the kept depth is disclosed
    /// so the model's next anchor can account for it.
    ///
    /// RED: refuse a unique window when an unpaired depth is not a map key → the
    /// isError assert fails and nothing below runs.
    func testShrinkWithUnknownCloserDepth_landsEndToEnd_andDisclosesTheKeptLines() throws {
        let url = try writeFile("card.swift", Self.cardFile)
        let sloppyAnchor = "    var body: Row {\n        Row {\n            leading()\n             trailing()"

        let result = runEdit(
            path: "card.swift",
            oldText: sloppyAnchor,
            newText: "    var body: Row {\n        Row(compact: true)\n         }")

        XCTAssertFalse(result.isError, result.outputJSON)
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
            
            """,
            "paired head at the file's depth; the unpaired tail keeps the model's bytes")
        // Nothing's leading whitespace changed (the paired head already matched the
        // file's depth, the unpaired tail was kept verbatim) — the envelope must not
        // claim a re-indent, only the pass-through.
        XCTAssertNil(dataField(result, "matched_ignoring_indentation"), result.outputJSON)
        XCTAssertTrue(warnings(result).contains { $0.contains("2 new lines kept your own indentation") },
                      "the kept depths are the one fact the model cannot see: \(warnings(result))")

        // CONTROL — the byte-identical anchor with new_text's closer moved onto a
        // key (13): the unpaired set translates whole into the file's convention.
        try Self.cardFile.write(to: url, atomically: true, encoding: .utf8)
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

    /// Shape 2 driven through the tool: the interleaved restructure LANDS — the
    /// task-32 model's most natural big edit, "replace this struct with a larger
    /// version of itself", which the end-anchored free region used to refuse
    /// wholesale. The sloppy closer repairs to the file's 8, the modifier keeps the
    /// model's 14 (disclosed), and the re-indent flag is honest — a paired line's
    /// leading DID change.
    ///
    /// RED: refuse a unique window when an unpaired depth is not a map key → the
    /// isError assert fails and nothing below runs.
    func testGrowInPlaceRestructure_landsEndToEnd() throws {
        let url = try writeFile("card.swift", Self.cardFile)

        let result = runEdit(
            path: "card.swift",
            oldText: Self.sloppyWholeStructAnchor.joined(separator: "\n"),
            newText: Self.restructuredLines(modifierIndent: 14).joined(separator: "\n"))

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(dataField(result, "matched_ignoring_indentation") as? Bool, true,
                       "the sloppy closer's leading was rewritten — disclose it")
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
            
            """,
            "reproduced lines at the file's depths, the unmapped modifier at the model's 14")
        XCTAssertTrue(warnings(result).contains { $0.contains("kept your own indentation") },
                      warnings(result).joined(separator: " | "))
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
