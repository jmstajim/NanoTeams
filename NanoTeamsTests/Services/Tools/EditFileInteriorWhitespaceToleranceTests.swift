import XCTest

@testable import NanoTeams

/// Pins tier 3.5 of `EditFileTool`'s anchor matching: a window located when runs of
/// spaces/tabs INSIDE the line are collapsed, with the FILE's bytes winning for every
/// replacement line the model merely reproduced.
///
/// The motivating run is CubeCraft task 5 run 0 (`qwen3.8:27b-mlx`): five `edit_file`
/// calls, all failed `ANCHOR_NOT_FOUND`/`absent`, while the anchor line WAS in the
/// file — every attempt differed only in interior alignment padding (the file pads
/// `= 1.05;  //` to a comment column that varies per line, and the model re-emits the
/// line with its own padding). Attempt 2 was ONE interior space away from the file.
/// The fixtures below are abstracted per the house rule ("реальный кейс ≠ дословный
/// дамп"): a minimal block carrying the run's significant property — aligned constants
/// with VARIABLE padding before `//` — with the target line and all five anchors kept
/// verbatim from `tool_calls.jsonl`. Each outcome has a control pair attributing it to
/// the specific property (interior drift / uniqueness / fragment), not to the shape.
final class EditFileInteriorWhitespaceToleranceTests: XCTestCase {
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

    // MARK: - Fixtures (verbatim from the run; file block minimal, not the 481-line dump)

    /// Neighbour lines carry the property that produced the failure: the padding
    /// before `//` varies per line (3, 2, 4 spaces) because it aligns a comment
    /// column across values of different widths — the one thing a model re-emitting
    /// a line from memory normalizes away.
    private static let fileLineMoveSpeed = "  const MOVE_SPEED = 4.2;   // blocks / second"
    private static let fileLinePitchLimit = "  const PITCH_LIMIT = 1.3;  // radians"
    private static let fileLineMaxView = "  const MAX_VIEW   = 16;    // max ray distance (also fog range)"
    /// Verbatim `game.js` line 18: indent 2, FOUR spaces after STEP_UP, TWO before `//`.
    private static let fileLineStepUp =
        "  const STEP_UP    = 1.05;  // max height change the player climbs automatically"

    private static var constBlock: String {
        [fileLineMoveSpeed, fileLinePitchLimit, fileLineMaxView, fileLineStepUp, ""]
            .joined(separator: "\n")
    }

    /// The five anchors, verbatim, as their whitespace signatures
    /// (indent, spaces after STEP_UP, spaces before //):
    /// 1=(2,5,3), 2=(2,4,3), 3=(0,5,3), 4=(0,6,4), 5=(0,5,fragment — no comment tail).
    private static let anchor1 =
        "  const STEP_UP     = 1.05;   // max height change the player climbs automatically"
    private static let anchor2 =
        "  const STEP_UP    = 1.05;   // max height change the player climbs automatically"
    private static let anchor3 =
        "const STEP_UP     = 1.05;   // max height change the player climbs automatically"
    private static let anchor4 =
        "const STEP_UP      = 1.05;    // max height change the player climbs automatically"
    private static let anchor5 = "const STEP_UP     = 1.05;"

    private static let new1 = anchor1 + "\n"
        + "  const GRAVITY     = 24;     // downward acceleration, blocks/s²\n"
        + "  const JUMP_VELOCITY = 8;    // initial upward velocity, blocks/s (≈1.33-block jump)"
    private static let new2 = anchor2 + "\n"
        + "  const GRAVITY     = 24;    // downward acceleration, blocks/s²\n"
        + "  const JUMP_VELOCITY = 8;   // initial upward velocity, blocks/s (~1.33-block jump)"
    private static let new3 = anchor3 + "\n"
        + "  const GRAVITY     = 24;     // downward acceleration, blocks/s^2\n"
        + "  const JUMP_VELOCITY = 8;    // initial upward velocity, blocks/s (~1.33-block jump)"
    private static let new4 = anchor4 + "\n"
        + "  const GRAVITY      = 24;     // downward acceleration, blocks/s^2\n"
        + "  const JUMP_VELOCITY = 8;     // initial upward velocity, blocks/s (~1.33-block jump)"

    // MARK: - Helpers

    @discardableResult
    private func writeFile(_ name: String, _ content: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func readFile(_ name: String) throws -> String {
        try String(contentsOf: tempDir.appendingPathComponent(name), encoding: .utf8)
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

    private func envelope(_ result: ToolExecutionResult) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
            ?? [:]
    }

    private func dataField(_ result: ToolExecutionResult, _ key: String) -> Any? {
        (envelope(result)["data"] as? [String: Any])?[key]
    }

    private func message(_ result: ToolExecutionResult) -> String {
        ((envelope(result)["error"] as? [String: Any])?["message"] as? String) ?? ""
    }

    private func diagnosis(_ result: ToolExecutionResult) -> String? {
        (((envelope(result)["error"] as? [String: Any])?["details"] as? [String: Any])?["diagnosis"])
            as? String
    }

    private func warnings(_ result: ToolExecutionResult) -> [String] {
        ((envelope(result)["meta"] as? [String: Any])?["warnings"] as? [String]) ?? []
    }

    /// Line-anchored equality: the whole point of this suite is leading/interior
    /// bytes, and a bare `contains(line)` passes when the needle is a SUFFIX of a
    /// differently-indented line (recorded assert-trap, Грабли 2026-08-15/16).
    private func assertLine(
        _ content: String, at index: Int, equals expected: String,
        _ note: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let lines = content.components(separatedBy: "\n")
        guard index < lines.count else {
            return XCTFail("no line \(index) in:\n\(content)", file: file, line: line)
        }
        XCTAssertEqual(lines[index], expected, note, file: file, line: line)
    }

    // MARK: - The run's failing attempts, repaired

    /// Attempt 1 (signature 2,5,3 vs file 2,4,2): interior drift only. The repair must
    /// land, and the target line must keep the FILE's alignment bytes — tier 2 splices
    /// trailing dirt away and tier 3 rewrites leading whitespace into the file's
    /// convention, so the interior tier writing the MODEL's padding over the file
    /// would invert the ladder's own invariant and un-align the const block.
    ///
    /// RED: remove the tier-3.5 collapsed scan → the call returns ANCHOR_NOT_FOUND
    /// and every assertion below the first fails.
    func testRealAttempt1_interiorDriftOnly_isRepairedWithTheFilesBytes() async throws {
        try writeFile("game.js", Self.constBlock)

        let result = await runEdit(path: "game.js", oldText: Self.anchor1, newText: Self.new1)

        XCTAssertFalse(result.isError, result.outputJSON)
        let disk = try readFile("game.js")
        assertLine(disk, at: 3, equals: Self.fileLineStepUp,
                   "the reproduced line must keep the FILE's 4/2 spacing, not the model's 5/3")
        assertLine(disk, at: 4,
                   equals: "  const GRAVITY     = 24;     // downward acceleration, blocks/s²",
                   "genuinely new lines carry the model's own bytes")
        assertLine(disk, at: 5,
                   equals: "  const JUMP_VELOCITY = 8;    // initial upward velocity, blocks/s (≈1.33-block jump)",
                   "genuinely new lines carry the model's own bytes")
        XCTAssertEqual(dataField(result, "matched_ignoring_interior_whitespace") as? Bool, true,
                       "the model must learn the file's spacing differed from its anchor")
        XCTAssertNil(dataField(result, "matched_ignoring_indentation"),
                     "identity indent map — claiming a re-indent would be a false disclosure")
        XCTAssertNil(dataField(result, "matched_ignoring_trailing_whitespace"), result.outputJSON)
    }

    /// Attempt 2 was ONE interior space away from the file (3 vs 2 before `//`), with
    /// the indent and the code both correct — the sharpest form of the class.
    ///
    /// RED: same mutation as `testRealAttempt1_interiorDriftOnly_isRepairedWithTheFilesBytes`.
    func testRealAttempt2_oneInteriorSpaceAway_isRepaired() async throws {
        try writeFile("game.js", Self.constBlock)

        let result = await runEdit(path: "game.js", oldText: Self.anchor2, newText: Self.new2)

        XCTAssertFalse(result.isError, result.outputJSON)
        assertLine(try readFile("game.js"), at: 3, equals: Self.fileLineStepUp,
                   "the file's alignment survives the repair")
        XCTAssertEqual(dataField(result, "matched_ignoring_interior_whitespace") as? Bool, true,
                       result.outputJSON)
    }

    /// Control pair for attempts 1–2: the SAME anchor with the file's interior
    /// spacing matches on the exact tier with no disclosure at all — which attributes
    /// the run's failures to the interior bytes and to nothing else.
    func testControl_anchorWithTheFilesInteriorSpacing_matchesExactly() async throws {
        try writeFile("game.js", Self.constBlock)

        let result = await runEdit(
            path: "game.js", oldText: Self.fileLineStepUp,
            newText: Self.fileLineStepUp + "\n  const GRAVITY     = 24;     // downward acceleration")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertNil(dataField(result, "matched_ignoring_interior_whitespace"), result.outputJSON)
        XCTAssertNil(dataField(result, "matched_ignoring_indentation"), result.outputJSON)
        XCTAssertNil(dataField(result, "matched_ignoring_trailing_whitespace"), result.outputJSON)
    }

    /// Attempt 3 (signature 0,5,3): interior drift PLUS a dropped leading indent —
    /// the shape the model fell into after the misdiagnosis told it whitespace was
    /// not the problem. The repair composes with `reindentToFileConvention`
    /// (map "" → "  "), so BOTH disclosures must ride the envelope, and the
    /// appended-lines warning must survive.
    ///
    /// RED: hardcode `alsoReindented: false` in the tier-3.5 kind → the
    /// `matched_ignoring_indentation` assertion fails.
    func testRealAttempt3_interiorPlusLeadingDrift_repairsAndDisclosesBoth() async throws {
        try writeFile("game.js", Self.constBlock)

        let result = await runEdit(path: "game.js", oldText: Self.anchor3, newText: Self.new3)

        XCTAssertFalse(result.isError, result.outputJSON)
        let disk = try readFile("game.js")
        assertLine(disk, at: 3, equals: Self.fileLineStepUp,
                   "reproduced line: file bytes, including the restored 2-space indent")
        assertLine(disk, at: 4,
                   equals: "  const GRAVITY     = 24;     // downward acceleration, blocks/s^2",
                   "new lines keep the model's own bytes")
        XCTAssertEqual(dataField(result, "matched_ignoring_interior_whitespace") as? Bool, true,
                       result.outputJSON)
        XCTAssertEqual(dataField(result, "matched_ignoring_indentation") as? Bool, true,
                       "the anchor's indent 0 was translated to the file's 2 — disclose it")
        XCTAssertTrue(warnings(result).contains { $0.contains("2 new lines") },
                      "the pass-through count must survive the interior tier: \(warnings(result))")
    }

    /// Attempt 4 (signature 0,6,4) — the widest drift of the run.
    ///
    /// RED: remove the tier-3.5 collapsed scan → ANCHOR_NOT_FOUND again and the byte
    /// assertion never runs.
    func testRealAttempt4_widestDrift_stillRepairs() async throws {
        try writeFile("game.js", Self.constBlock)

        let result = await runEdit(path: "game.js", oldText: Self.anchor4, newText: Self.new4)

        XCTAssertFalse(result.isError, result.outputJSON)
        assertLine(try readFile("game.js"), at: 3, equals: Self.fileLineStepUp,
                   "the file's alignment survives the repair")
    }

    // MARK: - Class 6: the sub-line fragment (attempt 5)

    /// CHOICE: a substring-collapse tier could rescue fragment anchors too, and was
    /// rejected: a fragment's splice boundary inside a whitespace-normalized line is
    /// undefined, and replaying attempt 5 shows what the "repair" would do — its
    /// new_text equals its old_text, so the whole-line splice would have overwritten
    /// the file's line and silently DELETED the trailing comment under ok:true.
    /// Refusal keeps the failure visible; the control test below proves the fragment
    /// shape itself still works when its bytes are right.
    /// FIXTURE: attempt 5's verbatim fragment anchor — indent 0, five spaces after
    /// STEP_UP, comment tail dropped — against the aligned-const block.
    func testCharacterization_fragmentAnchorWithInteriorDrift_staysAbsent() async throws {
        try writeFile("game.js", Self.constBlock)

        let result = await runEdit(path: "game.js", oldText: Self.anchor5, newText: Self.anchor5)

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(message(result).contains("none of its lines appear"),
                      "whole-line collapse cannot see a fragment — it stays absent: \(message(result))")
        XCTAssertEqual(try readFile("game.js"), Self.constBlock, "a refusal must not write")
    }

    /// Control pair for class 6: the same fragment with the FILE's interior spacing
    /// is an exact substring and edits via tier 1 — the class is the drift inside
    /// the fragment, not the fragment shape.
    func testControl_fragmentWithTheFilesInteriorSpacing_editsViaTheExactTier() async throws {
        try writeFile("game.js", Self.constBlock)

        let result = await runEdit(
            path: "game.js",
            oldText: "const STEP_UP    = 1.05;",
            newText: "const STEP_UP    = 1.15;")

        XCTAssertFalse(result.isError, result.outputJSON)
        assertLine(try readFile("game.js"), at: 3,
                   equals: "  const STEP_UP    = 1.15;  // max height change the player climbs automatically",
                   "an exact fragment splices in place")
        XCTAssertNil(dataField(result, "matched_ignoring_interior_whitespace"), result.outputJSON)
    }

    // MARK: - Refusals: ambiguity and untranslatable indentation

    /// Distilled from the motivating file itself: game.js lines 288/368 are distinct
    /// under trimBoth and EQUAL once interior runs collapse. An anchor drifting onto
    /// that pair must be refused with the file's bytes — picking either window would
    /// be a wrong-location guess.
    ///
    /// RED: take `matches[0]` when `matches.count > 1` → this becomes a silent
    /// wrong-location write and the isError assertion fails.
    func testCollapseAmbiguousWindow_isRefusedWithTheFilesBytes_notAbsent() async throws {
        let lineA = "    let sideY = (dirY > 0 ? (eyeY - y)     : (y + 1 - eyeY))     * ddy;"
        let lineB = "      let sideY = (dirY > 0 ? (eyeY - y)   : (y + 1 - eyeY))     * ddy;"
        try writeFile("ray.js", lineA + "\n" + lineB + "\n")

        let result = await runEdit(
            path: "ray.js",
            oldText: "let sideY = (dirY > 0 ? (eyeY - y)  : (y + 1 - eyeY))  * ddy;",
            newText: "let sideY = 0;")

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertEqual(diagnosis(result), "interior_whitespace_mismatch", result.outputJSON)
        XCTAssertFalse(message(result).contains("none of its lines appear"),
                       "a located window must not be reported as absent: \(message(result))")
        XCTAssertTrue(message(result).contains("\n" + lineA),
                      "hand back the file's exact bytes, line-anchored: \(message(result))")
        XCTAssertEqual(try readFile("ray.js"), lineA + "\n" + lineB + "\n",
                       "a refusal must not write")
    }

    /// Control pair: the same two lines with DISTINCT content collapse to distinct
    /// strings, the window is unique, and the same anchor repairs.
    func testControl_sameShapeWithDistinctContent_isRepairedUniquely() async throws {
        let lineA = "    let sideY = (dirY > 0 ? (eyeY - y)     : (y + 1 - eyeY))     * ddy;"
        let lineB = "      let sideZ = (dirZ > 0 ? (eyeZ - z)   : (z + 1 - eyeZ))     * ddz;"
        try writeFile("ray.js", lineA + "\n" + lineB + "\n")

        let result = await runEdit(
            path: "ray.js",
            oldText: "let sideY = (dirY > 0 ? (eyeY - y)  : (y + 1 - eyeY))  * ddy;",
            newText: "let sideY = (dirY > 0 ? (eyeY - y)  : (y + 1 - eyeY))  * ddy; // hit")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(dataField(result, "matched_ignoring_interior_whitespace") as? Bool, true,
                       result.outputJSON)
    }

    /// Route (б), landed: a UNIQUE collapsed window over IRREGULAR indentation (the
    /// anchor's one depth corresponds to two file depths — 4sp and 5sp). The
    /// per-depth map used to refuse here; per line the conflicted key is simply
    /// unusable, so both (changed, unpaired) replacement lines keep the model's
    /// bytes, disclosed.
    ///
    /// RED: restore the conflicted-key `return nil` in `reindentToFileConvention` →
    /// the isError assert fails and nothing below runs.
    func testUniqueWindowOverIrregularIndentation_landsWithTheModelsBytes() async throws {
        let fileA = "    let a = 1;  // x"
        let fileB = "     let b = 2;  // y"
        try writeFile("odd.js", fileA + "\n" + fileB + "\n")

        let result = await runEdit(
            path: "odd.js",
            oldText: "    let a = 1;   // x\n    let b = 2;   // y",
            newText: "    let a = 9;\n    let b = 9;")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try readFile("odd.js"), "    let a = 9;\n    let b = 9;\n",
                       "the conflicted key routes both changed lines to the model's own bytes")
        XCTAssertEqual(dataField(result, "matched_ignoring_interior_whitespace") as? Bool, true,
                       result.outputJSON)
        XCTAssertNil(dataField(result, "matched_ignoring_indentation"),
                     "no line's leading whitespace changed — the envelope must not claim a re-indent")
        XCTAssertTrue(warnings(result).contains { $0.contains("kept your own indentation") },
                      "the kept depths are disclosed: \(warnings(result))")
    }

    /// Control pair: the same anchor against a REGULAR file (both lines at one
    /// depth) — the map is a function, and the edit repairs.
    func testControl_sameAnchorAgainstRegularIndentation_repairs() async throws {
        let fileA = "    let a = 1;  // x"
        let fileB = "    let b = 2;  // y"
        try writeFile("even.js", fileA + "\n" + fileB + "\n")

        let result = await runEdit(
            path: "even.js",
            oldText: "    let a = 1;   // x\n    let b = 2;   // y",
            newText: "    let a = 9;\n    let b = 9;")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try readFile("even.js"), "    let a = 9;\n    let b = 9;\n", "the rewrite lands")
    }

    // MARK: - Pure rewrite: per-line file-bytes-win

    /// A rewrite window (newCount == anchorCount) has positional correspondence, so
    /// the file-bytes rule applies per line: a line the model REPRODUCED (collapse-
    /// equal) keeps the file's bytes, a line it CHANGED takes the model's.
    ///
    /// RED: drop the file-bytes pass → line 0 lands with the model's 3-space padding
    /// and the first byte-equality fails.
    func testPureRewrite_reproducedLineKeepsFileBytes_changedLineTakesModels() async throws {
        try writeFile("game.js", Self.constBlock)

        let result = await runEdit(
            path: "game.js",
            oldText: "  const MAX_VIEW   = 16;   // max ray distance (also fog range)\n"
                + "  const STEP_UP    = 1.05;   // max height change the player climbs automatically",
            newText: "  const MAX_VIEW   = 16;   // max ray distance (also fog range)\n"
                + "  const STEP_UP    = 2.05;   // raised step")

        XCTAssertFalse(result.isError, result.outputJSON)
        let disk = try readFile("game.js")
        assertLine(disk, at: 2, equals: Self.fileLineMaxView,
                   "the reproduced line keeps the FILE's 4-space comment padding")
        assertLine(disk, at: 3, equals: "  const STEP_UP    = 2.05;   // raised step",
                   "the changed line is the model's content — written as sent")
    }

    /// A DELETE-lines edit (new_text shorter than the anchor): the surviving line is
    /// still a reproduction, so it must keep the file's bytes — and the disclosure
    /// ("the model's interior padding is NOT what landed") must not be false for the
    /// one shape where the positional correspondence cannot see it.
    ///
    /// RED: drop the greedy branch of the pairing in `reindentToFileConvention`
    /// (positional only) → the surviving line pairs with nothing and lands with
    /// the model's padding.
    func testDeleteLineEdit_survivingLineKeepsFileBytes() async throws {
        try writeFile("game.js", Self.constBlock)
        let driftedMaxView = "  const MAX_VIEW    = 16;   // max ray distance (also fog range)"

        let result = await runEdit(
            path: "game.js",
            oldText: driftedMaxView + "\n" + Self.anchor2,
            newText: Self.anchor2)

        XCTAssertFalse(result.isError, result.outputJSON)
        let disk = try readFile("game.js")
        assertLine(disk, at: 2, equals: Self.fileLineStepUp,
                   "the surviving reproduced line keeps the FILE's 4/2 spacing")
        XCTAssertFalse(disk.contains("MAX_VIEW"), "the deleted line is gone")
        XCTAssertEqual(dataField(result, "matched_ignoring_interior_whitespace") as? Bool, true,
                       result.outputJSON)
    }

    /// A MID-insertion grow (new line between two reproduced ones) has no aligned
    /// prefix or suffix, so the old positional correspondence bailed — and both
    /// reproduced lines landed with the model's padding under a disclosure claiming
    /// the opposite. The greedy in-order pairing must see through the insertion.
    ///
    /// RED: same mutation as `testDeleteLineEdit_survivingLineKeepsFileBytes`.
    func testMidInsertionGrow_reproducedLinesKeepFileBytes() async throws {
        try writeFile("game.js", Self.constBlock)
        let driftedMaxView = "  const MAX_VIEW    = 16;   // max ray distance (also fog range)"
        let inserted = "  const NEW_CONST  = 7;    // inserted between"

        let result = await runEdit(
            path: "game.js",
            oldText: driftedMaxView + "\n" + Self.anchor2,
            newText: driftedMaxView + "\n" + inserted + "\n" + Self.anchor2)

        XCTAssertFalse(result.isError, result.outputJSON)
        let disk = try readFile("game.js")
        assertLine(disk, at: 2, equals: Self.fileLineMaxView,
                   "reproduced line before the insertion keeps file bytes")
        assertLine(disk, at: 3, equals: inserted, "the inserted line is the model's content")
        assertLine(disk, at: 4, equals: Self.fileLineStepUp,
                   "reproduced line after the insertion keeps file bytes")
    }

    /// Identity indent map + pass-through appended lines: the warning must not open
    /// with "Anchor indentation was rewritten to match the file" — nothing was
    /// rewritten, and the same envelope (correctly) omits
    /// `matched_ignoring_indentation`. A warning contradicting its own envelope is
    /// the misdiagnosis class this whole change exists to remove.
    ///
    /// RED: make the rewrite clause unconditional again → the NotContains assertion
    /// fails.
    func testIdentityMapWithPassthrough_warningDoesNotClaimARewrite() async throws {
        try writeFile("game.js", Self.constBlock)

        let result = await runEdit(
            path: "game.js",
            oldText: Self.anchor2,
            newText: Self.anchor2 + "\n  function step() {\n    return 1;\n  }")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertNil(dataField(result, "matched_ignoring_indentation"), result.outputJSON)
        let warning = warnings(result).joined(separator: " | ")
        XCTAssertTrue(warning.contains("kept your own indentation"), warning)
        XCTAssertFalse(warning.contains("was rewritten"),
                       "identity map — claiming a rewrite contradicts the omitted flag: \(warning)")
    }

    /// An edit whose only difference IS interior spacing collapses into a byte-level
    /// no-op (the file's spacing wins on both sides). It must not masquerade as a
    /// clean success: the envelope says `replacements_made: 1`, so without a warning
    /// a formatting-intent model retries forever with no error to react to.
    ///
    /// RED: drop the unchanged-content warning → the warning assertion fails.
    func testPureSpacingEdit_disclosesTheNoOp() async throws {
        try writeFile("pad.js", "let a =  1;\nlet z = 0;\n")

        let result = await runEdit(path: "pad.js", oldText: "let a = 1;", newText: "let a =      1;")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try readFile("pad.js"), "let a =  1;\nlet z = 0;\n",
                       "the file's spacing wins on both sides — bytes unchanged")
        XCTAssertTrue(warnings(result).contains { $0.contains("left the file unchanged") },
                      "a byte-level no-op must be disclosed: \(warnings(result))")
    }

    /// `replace_all` over collapse-equal-but-drifted occurrences: the refusal must
    /// not prescribe uniqueness — the caller explicitly asked for every occurrence,
    /// and the real blocker is that the occurrences differ in their spacing.
    ///
    /// RED: advise uniqueness on every ambiguous route → the NotContains fails.
    func testReplaceAllOverDriftedDuplicates_refusalNamesTheRealCure() async throws {
        try writeFile("dup.js", "let s = a  + b;\nlet s = a   + b;\n")

        let result = await runEdit(
            path: "dup.js", oldText: "let s = a + b;", newText: "let s = a - b;",
            replaceAll: true)

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertEqual(diagnosis(result), "interior_whitespace_mismatch", result.outputJSON)
        XCTAssertFalse(message(result).contains("make the target unique"),
                       "the caller asked for every occurrence — uniqueness is not the cure: \(message(result))")
        XCTAssertTrue(message(result).contains("each occurrence separately"), message(result))
    }

    // MARK: - Ladder ordering and splice fidelity

    /// Trailing-only drift must still take tier 2 (which discloses trailing, not
    /// interior) — the collapsed tier sits BELOW the existing ones, never before.
    ///
    /// RED: run the collapsed scan before the trailing-trim scan → the trailing flag
    /// disappears and the interior flag appears.
    func testTrailingOnlyDrift_stillTakesTier2() async throws {
        try writeFile("game.js", Self.constBlock)

        let result = await runEdit(
            path: "game.js", oldText: Self.fileLineStepUp + "   ",
            newText: Self.fileLineStepUp)

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(dataField(result, "matched_ignoring_trailing_whitespace") as? Bool, true,
                       result.outputJSON)
        XCTAssertNil(dataField(result, "matched_ignoring_interior_whitespace"), result.outputJSON)
    }

    /// CRLF files: the interior repair must ride the shared splice plumbing, so the
    /// repaired line keeps CRLF and never gains a doubled CR.
    ///
    /// RED: splice the file bytes WITH their trailing CR kept → the repaired line
    /// ends "\r\r\n" and both assertions fail.
    func testCRLFFile_interiorRepair_preservesLineEndings() async throws {
        let crlf = Self.constBlock.replacingOccurrences(of: "\n", with: "\r\n")
        try writeFile("game.js", crlf)

        let result = await runEdit(path: "game.js", oldText: Self.anchor2, newText: Self.anchor2)

        XCTAssertFalse(result.isError, result.outputJSON)
        let disk = try readFile("game.js")
        XCTAssertFalse(disk.contains("\r\r"), "no doubled CR: \(disk.debugDescription)")
        XCTAssertTrue(disk.contains(Self.fileLineStepUp + "\r\n"),
                      "the repaired line keeps the file's bytes AND its CRLF ending")
    }

    // MARK: - The wire

    /// The envelope is rebuilt by `MemoryTagStore.processEdit`, and a disclosure not
    /// forwarded there is dead on the wire — recorded happening twice before this
    /// suite existed (Грабли 2026-08-15).
    ///
    /// RED: drop the transfer line in `processEdit` → the envelope still carries the
    /// key while the wire content loses it.
    func testInteriorDisclosure_survivesTheMemoryTagStore() async throws {
        try writeFile("game.js", Self.constBlock)
        let result = await runEdit(path: "game.js", oldText: Self.anchor1, newText: Self.new1)
        XCTAssertFalse(result.isError, result.outputJSON)

        guard case .tagged(let wire, _) = MemoryTagStore().processToolResult(result) else {
            return XCTFail("a successful edit must be tagged")
        }
        XCTAssertTrue(wire.contains("\"matched_ignoring_interior_whitespace\":true"),
                      "the model must learn the file's spacing won: \(wire)")
    }

    /// Anti-noise: a clean exact edit adds no interior disclosure anywhere —
    /// envelope or wire.
    ///
    /// RED: forward the key unconditionally → the wire assertion fails.
    func testCleanExactEdit_carriesNoInteriorDisclosure() async throws {
        try writeFile("game.js", Self.constBlock)
        let result = await runEdit(
            path: "game.js", oldText: Self.fileLineStepUp, newText: Self.fileLineStepUp)
        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertNil(dataField(result, "matched_ignoring_interior_whitespace"), result.outputJSON)

        guard case .tagged(let wire, _) = MemoryTagStore().processToolResult(result) else {
            return XCTFail("a successful edit must be tagged")
        }
        XCTAssertFalse(wire.contains("matched_ignoring_interior_whitespace"), wire)
    }

    // MARK: - Honesty of `.absent` after the tier lands

    /// An anchor naming code that never existed still reports `.absent` with its
    /// message untouched — the collapsed tier must not have widened what counts as
    /// "found", and the message's whitespace denial is now true for every whole-line
    /// anchor that reaches it. A control, not a mutation target: no single-line
    /// mutation of the tier can make THIS anchor match (its words exist nowhere in
    /// the fixture), so the pin's job is to hold the message steady.
    func testGenuinelyAbsentAnchor_staysAbsent_messageUntouched() async throws {
        try writeFile("game.js", Self.constBlock)

        let result = await runEdit(
            path: "game.js",
            oldText: "struct NeverExisted {\n    let x: Int\n}",
            newText: "x")

        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(message(result).contains("none of its lines appear"), message(result))
        XCTAssertTrue(message(result).contains("this is not a whitespace problem"), message(result))
    }
}
