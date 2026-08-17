import XCTest

@testable import NanoTeams

/// End-to-end pins for the line range `edit_file` reports, through the real `ToolRuntime`.
///
/// The decisive tests here are the ROUND TRIPS: they do not assert a number, they feed the
/// number the edit reported straight into `read_lines` and assert it lands on the edited
/// text. A number that is merely self-consistent is worthless — the requirement is that it
/// works in the tool a reader would use next, and `edit_file` and `read_lines` count lines
/// in different models (`"\n"` vs `.newlines`), which disagree on any file that is not
/// pure-LF.
final class EditFileLineRangeTests: XCTestCase {
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

    /// Writes bytes verbatim — `String.write(to:)` would be fine, but going through `Data`
    /// makes it obvious that the CRLF fixtures below are not being normalized on the way in.
    @discardableResult
    private func writeFile(_ name: String, _ content: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
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

    private func runReadLines(path: String, start: Int, end: Int) -> ToolExecutionResult {
        let args: [String: Any] = ["path": path, "start_line": start, "end_line": end]
        let data = try! JSONSerialization.data(withJSONObject: args)
        let call = StepToolCall(name: "read_lines", argumentsJSON: String(data: data, encoding: .utf8)!)
        return runtime.executeAll(context: context, toolCalls: [call])[0]
    }

    private func dataField(_ result: ToolExecutionResult, _ key: String) -> Any? {
        guard
            let json = try? JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any],
            let data = json["data"] as? [String: Any]
        else { return nil }
        return data[key]
    }

    private func span(_ result: ToolExecutionResult) -> (start: Int, end: Int)? {
        guard let s = dataField(result, "start_line") as? Int,
              let e = dataField(result, "end_line") as? Int
        else { return nil }
        return (s, e)
    }

    // MARK: - The envelope carries the span

    /// RED: pass `nil` for `start_line`/`end_line` in `EditFileData` → this fires.
    func testExactEdit_envelopeCarriesTheSpan() throws {
        try writeFile("a.swift", "one\ntwo\nthree\nfour\n")
        let result = runEdit(path: "a.swift", oldText: "three", newText: "THREE")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(span(result)?.start, 3)
        XCTAssertEqual(span(result)?.end, 3)
    }

    /// The tolerant tier rewrites the replacement's leading whitespace, so the region that
    /// CHANGED is not the window the tier matched. The span must describe the former.
    func testIndentationTolerantEdit_reportsTheChangedRegion() throws {
        try writeFile("b.swift", "class A {\n    func x() {\n        old()\n    }\n}\n")
        let result = runEdit(
            path: "b.swift",
            oldText: "  func x() {\n      old()\n  }",
            newText: "  func x() {\n      renamed()\n  }"
        )
        XCTAssertFalse(result.isError, "expected the indentation-tolerant tier to match")
        XCTAssertEqual(span(result)?.start, 3, "only the body line changed")
        XCTAssertEqual(span(result)?.end, 3)
    }

    /// RED: report the span from the PRE-edit file (`after: content`) → this fires, because
    /// `replace_all` shifts every region after the first.
    func testReplaceAll_reportsABoundingSpanAndTheCount() throws {
        try writeFile("c.txt", "x\nTARGET\ny\nTARGET\nz\nTARGET\n")
        let result = runEdit(path: "c.txt", oldText: "TARGET", newText: "HIT", replaceAll: true)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(dataField(result, "replacements_made") as? Int, 3)
        XCTAssertEqual(span(result)?.start, 2, "first region")
        XCTAssertEqual(span(result)?.end, 6, "last region — a bounding span, not a run")
    }

    /// A byte-level no-op has no line to point at, and the envelope already says so in
    /// `meta.warnings`. Both fields must be ABSENT rather than defaulted to something.
    func testNoOpEdit_omitsTheSpan() throws {
        // The interior-collapse tier's documented no-op, borrowed verbatim from
        // `EditFileInteriorWhitespaceToleranceTests.testPureSpacingEdit_disclosesTheNoOp`:
        // both sides differ only inside a run of spaces, where the FILE's spacing wins, so
        // the write is byte-identical to what was there.
        try writeFile("pad.js", "let a =  1;\nlet z = 0;\n")
        let result = runEdit(path: "pad.js", oldText: "let a = 1;", newText: "let a =      1;")

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(
            try String(contentsOf: tempDir.appendingPathComponent("pad.js"), encoding: .utf8),
            "let a =  1;\nlet z = 0;\n",
            "precondition: this fixture really is a byte-level no-op")
        XCTAssertNil(dataField(result, "start_line"), "no change, so no line to name")
        XCTAssertNil(dataField(result, "end_line"))
    }

    func testFailedEdit_hasNoSpan() throws {
        try writeFile("e.txt", "one\ntwo\n")
        let result = runEdit(path: "e.txt", oldText: "nowhere", newText: "x")
        XCTAssertTrue(result.isError)
        XCTAssertNil(dataField(result, "start_line"))
    }

    // MARK: - Round trips: the number has to WORK in read_lines

    /// RED: count separators as `scalar == "\n"` instead of `CharacterSet.newlines` → this
    /// fires, because on CRLF the two models disagree by roughly a factor of two and
    /// `read_lines` returns a different region than the one that was edited.
    ///
    /// The edit deliberately CHANGES the line count, so a span computed against the
    /// pre-edit file would also miss.
    func testCRLFRoundTrip_readLinesReturnsTheEditedText() throws {
        try writeFile("crlf.txt", "alpha\r\nbeta\r\ngamma\r\n")
        let edit = runEdit(path: "crlf.txt", oldText: "beta", newText: "BETA\r\nEXTRA")
        XCTAssertFalse(edit.isError)
        guard let s = span(edit) else { return XCTFail("expected a span") }

        let read = runReadLines(path: "crlf.txt", start: s.start, end: s.end)
        XCTAssertFalse(read.isError)
        let content = dataField(read, "content") as? String ?? ""
        XCTAssertTrue(
            content.contains("BETA"),
            "read_lines(\(s.start)…\(s.end)) returned \(content.debugDescription), which does not hold the edit")
        XCTAssertTrue(content.contains("EXTRA"), "the whole inserted region must be inside the span")
    }

    /// The pure-LF control, so the CRLF test above cannot pass for a trivial reason.
    func testLFRoundTrip_readLinesReturnsTheEditedText() throws {
        try writeFile("lf.txt", "alpha\nbeta\ngamma\n")
        let edit = runEdit(path: "lf.txt", oldText: "beta", newText: "BETA\nEXTRA")
        XCTAssertFalse(edit.isError)
        guard let s = span(edit) else { return XCTFail("expected a span") }

        let read = runReadLines(path: "lf.txt", start: s.start, end: s.end)
        let content = dataField(read, "content") as? String ?? ""
        XCTAssertTrue(content.contains("BETA"))
        XCTAssertTrue(content.contains("EXTRA"))
        XCTAssertFalse(content.contains("alpha"), "the span must not overreach")
        XCTAssertFalse(content.contains("gamma"))
    }

    // MARK: - The span stays off the wire

    /// RED: add a `start_line` forwarding branch to `MemoryTagStore.processEdit` → this
    /// fires.
    ///
    /// The line numbers are a DISPLAY fact, added for the activity-feed card and the
    /// exported conversation log. `edit_file` is anchored by text, not by position, so the
    /// model cannot act on a line number, and forwarding it would cost context on every
    /// edit forever. `processEdit` BUILDS its envelope from an enumerated field list, so
    /// the omission is the default — this pin exists because that file's doc comment
    /// carries a standing instruction to forward every new disclosure, and a reader
    /// following it would silently re-introduce the cost.
    func testTheSpanDoesNotReachTheWire() throws {
        try writeFile("f.swift", "one\ntwo\nthree\n")
        let result = runEdit(path: "f.swift", oldText: "two", newText: "TWO")
        XCTAssertNotNil(span(result), "precondition: the handler produced a span")

        guard case .tagged(let wire, _) = MemoryTagStore().processToolResult(result) else {
            return XCTFail("a successful edit must be tagged")
        }
        XCTAssertFalse(wire.contains("start_line"), "line numbers must not reach the model: \(wire)")
        XCTAssertFalse(wire.contains("end_line"), wire)
        // Anti-vacuum: the tagged envelope really is this edit's, not an empty passthrough.
        XCTAssertTrue(wire.contains("f.swift"), wire)
    }
}
