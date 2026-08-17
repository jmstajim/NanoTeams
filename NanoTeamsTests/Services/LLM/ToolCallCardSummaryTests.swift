import XCTest
@testable import NanoTeams

/// `ToolCallSummarizer.cardSummary` — the one line a tool card shows next to the tool name.
///
/// It is `summarizeArguments` for 49 of the 50 tools. `edit_file` is the exception because
/// the useful fact about a SUCCESSFUL edit is not in its arguments: the tool is anchored by
/// text, so the arguments can only answer "what did you search for", which the match itself
/// already settled. Where it landed is known only after the splice.
nonisolated final class ToolCallCardSummaryTests: XCTestCase {

    private typealias TN = ToolNames

    private static let editArgs = #"{"path":"Foo.swift","old_text":"func loadUser()","new_text":"func loadUser(id:)"}"#

    private func editResult(
        start: Int?, end: Int?, replacements: Int = 1, path: String = "Foo.swift"
    ) -> String {
        var data: [String: Any] = ["path": path, "replacements_made": replacements]
        if let start { data["start_line"] = start }
        if let end { data["end_line"] = end }
        let envelope: [String: Any] = ["ok": true, "tool": TN.editFile, "data": data]
        let bytes = try! JSONSerialization.data(withJSONObject: envelope)
        return String(data: bytes, encoding: .utf8)!
    }

    private func card(
        _ tool: String, args: String, result: String?, isError: Bool = false
    ) -> String {
        ToolCallSummarizer.cardSummary(
            toolName: tool, argumentsJSON: args, resultJSON: result, isError: isError)
    }

    // MARK: - A successful edit says where it landed

    /// RED: return the argument summary unconditionally from `cardSummary` → this fires.
    func testSuccessfulEdit_showsTheLineRange() {
        XCTAssertEqual(
            card(TN.editFile, args: Self.editArgs, result: editResult(start: 118, end: 126)),
            "Foo.swift 118-126")
    }

    /// A one-line change reads as one number, not `118-118`.
    func testSuccessfulEdit_singleLine_showsOneNumber() {
        XCTAssertEqual(
            card(TN.editFile, args: Self.editArgs, result: editResult(start: 118, end: 118)),
            "Foo.swift 118")
    }

    /// RED: drop the `×N` clause → this fires.
    ///
    /// Under `replace_all` the pair is a bounding span over N scattered regions. Without the
    /// count, `12-412` reads as four hundred contiguous changed lines.
    func testReplaceAll_marksTheSpanAsBounding() {
        XCTAssertEqual(
            card(TN.editFile,
                 args: Self.editArgs,
                 result: editResult(start: 12, end: 412, replacements: 3)),
            "Foo.swift 12-412 ×3")
    }

    // MARK: - Everything else falls back to the anchor

    /// RED: drop the `isError` guard → this fires.
    ///
    /// A failed edit has no line range by definition, and the anchor is exactly what did
    /// NOT match — the only useful thing that can go on that row.
    ///
    /// The fixture deliberately carries a span ALONGSIDE `isError`, which `makeErrorResult`
    /// never produces today. That is the point: with a realistic error envelope (no `data`)
    /// the span lookup returns nil on its own, so the guard is never consulted and a test
    /// using one would pass with the guard deleted — it would pin nothing. Feeding an
    /// impossible-today pair is what makes the guard's contract, "an errored call shows the
    /// anchor whatever its envelope holds", observable.
    func testFailedEdit_keepsTheAnchorPreview() {
        let expected = ToolCallSummarizer.summarizeArguments(
            toolName: TN.editFile, json: Self.editArgs)
        XCTAssertTrue(expected.contains("‹"), "precondition: the fallback really is the anchor")
        XCTAssertEqual(
            card(TN.editFile,
                 args: Self.editArgs,
                 result: editResult(start: 118, end: 126),
                 isError: true),
            expected)
    }

    /// The realistic failure shape — `makeErrorResult` emits no `data` at all — which must
    /// reach the same place by the other route.
    func testFailedEdit_withARealisticErrorEnvelope_keepsTheAnchorPreview() {
        XCTAssertEqual(
            card(TN.editFile,
                 args: Self.editArgs,
                 result: #"{"ok":false,"error":{"code":"ANCHOR_NOT_FOUND","message":"…"}}"#,
                 isError: true),
            ToolCallSummarizer.summarizeArguments(toolName: TN.editFile, json: Self.editArgs))
    }

    /// While the call is in flight there is no result yet.
    func testEditWithNoResultYet_keepsTheAnchorPreview() {
        XCTAssertEqual(
            card(TN.editFile, args: Self.editArgs, result: nil),
            ToolCallSummarizer.summarizeArguments(toolName: TN.editFile, json: Self.editArgs))
    }

    /// The case most easily forgotten: a `task.json` persisted BEFORE line numbers existed
    /// re-renders in the feed, and its `edit_file` results carry no `start_line`. It must
    /// degrade to today's behaviour with no migration.
    func testEditFromBeforeThisFeature_keepsTheAnchorPreview() {
        XCTAssertEqual(
            card(TN.editFile, args: Self.editArgs, result: editResult(start: nil, end: nil)),
            ToolCallSummarizer.summarizeArguments(toolName: TN.editFile, json: Self.editArgs))
    }

    /// A byte-level no-op reports no span, and the envelope's own warning already says the
    /// file is unchanged — so the row falls back rather than naming a line that did not move.
    func testNoOpEdit_keepsTheAnchorPreview() {
        XCTAssertEqual(
            card(TN.editFile, args: Self.editArgs, result: editResult(start: nil, end: nil)),
            ToolCallSummarizer.summarizeArguments(toolName: TN.editFile, json: Self.editArgs))
    }

    // MARK: - No disturbance

    /// RED: make the refinement unconditional on the tool name → this fires for 49 tools.
    ///
    /// Mechanical rather than a hand-picked sample: every tool on the roster except
    /// `edit_file` must produce byte-identical output through `cardSummary` and
    /// `summarizeArguments`, for a success, a failure and an in-flight call alike.
    func testEveryOtherToolIsUnchangedByTheCardLayer() {
        let args = #"{"path":"a.swift","task_id":7,"query":"x","branch":"main","action":"pause"}"#
        let result = #"{"ok":true,"data":{"start_line":5,"end_line":9,"path":"a.swift"}}"#
        for tool in ToolNames.allNames where tool != TN.editFile {
            let base = ToolCallSummarizer.summarizeArguments(toolName: tool, json: args)
            XCTAssertEqual(card(tool, args: args, result: result), base, "\(tool) success")
            XCTAssertEqual(card(tool, args: args, result: nil), base, "\(tool) in flight")
            XCTAssertEqual(
                card(tool, args: args, result: result, isError: true), base, "\(tool) failed")
        }
    }

    /// Anti-vacuum for the sweep above: the fixture must actually exercise tools that SAY
    /// something, or "unchanged" would be a comparison of empty strings.
    func testTheNoDisturbanceSweepIsNotComparingEmptyStrings() {
        let args = #"{"path":"a.swift","task_id":7,"query":"x","branch":"main","action":"pause"}"#
        let speaking = ToolNames.allNames.filter { tool in
            !ToolCallSummarizer.summarizeArguments(toolName: tool, json: args).isEmpty
        }
        XCTAssertGreaterThan(speaking.count, 15, "sweep fixture exercises too few tools")
    }

    // MARK: - Degenerate input

    func testUnparseableResult_keepsTheAnchorPreview() {
        XCTAssertEqual(
            card(TN.editFile, args: Self.editArgs, result: "not json"),
            ToolCallSummarizer.summarizeArguments(toolName: TN.editFile, json: Self.editArgs))
    }

    /// The path comes from the result envelope, which is what the handler resolved. When the
    /// result somehow lacks it, the arguments still carry it.
    func testPathFallsBackToTheArgumentsWhenTheResultOmitsIt() {
        let envelope = #"{"ok":true,"data":{"replacements_made":1,"start_line":4,"end_line":4}}"#
        XCTAssertEqual(card(TN.editFile, args: Self.editArgs, result: envelope), "Foo.swift 4")
    }
}
