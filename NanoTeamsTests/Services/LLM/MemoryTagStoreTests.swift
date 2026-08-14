import XCTest

@testable import NanoTeams

/// Pins the simplified tag store (2026-08-11): every supported tool result gets a
/// fresh tag and its full rendered envelope, every time. There is deliberately NO
/// unchanged-detection, no baseline comparison, and no invalidation bookkeeping —
/// the anti-dedup pins below go red if any cross-action check is reintroduced.
final class MemoryTagStoreTests: XCTestCase {

    var sut: MemoryTagStore!

    override func setUp() {
        super.setUp()
        sut = MemoryTagStore()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Tag Generation

    func testNextTagIncrementsPerType() {
        XCTAssertEqual(sut.nextTag(.read), "<§R1§>")
        XCTAssertEqual(sut.nextTag(.read), "<§R2§>")
        XCTAssertEqual(sut.nextTag(.edit), "<§E1§>")
        XCTAssertEqual(sut.nextTag(.build), "<§B1§>")
        XCTAssertEqual(sut.nextTag(.read), "<§R3§>")
    }

    // MARK: - Path Canonicalization

    /// With a work folder root set, varied spellings of the same file collapse to
    /// one repo-relative spelling in the rendered envelope, so the model sees a
    /// stable `path` regardless of how it spelled the argument.
    func testExtractPath_canonicalizesSpellings_whenWorkFolderRootSet() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // `src/x.js` / `./src/x.js` / absolute all relativize without touching disk (the
        // first component is never the root name), so no `src` dir is needed here.
        let store = MemoryTagStore(workFolderRoot: root)
        let abs = root.appendingPathComponent("src/x.js").path

        XCTAssertEqual(store.extractPath(from: "{\"path\": \"src/x.js\"}"), "src/x.js")
        XCTAssertEqual(store.extractPath(from: "{\"path\": \"./src/x.js\"}"), "src/x.js")
        XCTAssertEqual(store.extractPath(from: "{\"path\": \"\(abs)\"}"), "src/x.js")
    }

    func testExtractPath_rawPassthrough_whenNoWorkFolderRoot() {
        // Default no-arg store has nil workFolderRoot → byte-for-byte back-compat.
        XCTAssertEqual(sut.extractPath(from: "{\"path\": \"./src/x.js\"}"), "./src/x.js")
    }

    /// The canonical spelling is what lands in the rendered envelope — the
    /// model's redundant-prefix spelling never reaches the wire.
    func testCanonicalPath_isRenderedIntoTheTaggedEnvelope() throws {
        let root = makeNamedRoot("Foo")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = MemoryTagStore(workFolderRoot: root)

        guard case .tagged(let content, _) = store.processToolResult(
            makeReadResult(path: "Foo/src/x.js", content: "let x = 1")) else {
            return XCTFail("read should be tagged")
        }
        XCTAssertTrue(content.contains("\"path\":\"src/x.js\""),
                      "the envelope must carry the canonical spelling: \(content)")
    }

    func testExtractPath_escapingPath_returnsRaw_whenWorkFolderRootSet() throws {
        let root = makeNamedRoot("Foo")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = MemoryTagStore(workFolderRoot: root)
        XCTAssertEqual(store.extractPath(from: "{\"path\": \"../escape.js\"}"), "../escape.js")
        XCTAssertEqual(store.extractPath(from: "{\"path\": \"/etc/passwd\"}"), "/etc/passwd")
    }

    /// A genuine same-named subdir is NOT over-collapsed — `app/x.js` and `x.js`
    /// stay distinct paths (two different physical files).
    func testExtractPath_genuineSameNamedSubdir_keepsDistinctKey() throws {
        let root = makeNamedRoot("app")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = MemoryTagStore(workFolderRoot: root)
        XCTAssertEqual(store.extractPath(from: "{\"path\": \"app/x.js\"}"), "app/x.js")
        XCTAssertEqual(store.extractPath(from: "{\"path\": \"x.js\"}"), "x.js")
    }

    /// Creates `<temp>/<name>` and returns it (caller removes the parent temp dir).
    private func makeNamedRoot(_ name: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - read_file / read_lines

    func testReadFile_ReturnsTaggedContent() {
        let result = makeReadResult(path: "Sorter.swift", content: "let x = 1")
        let tagResult = sut.processToolResult(result)

        guard case .tagged(let content, let tag) = tagResult else {
            XCTFail("Expected .tagged, got \(tagResult)")
            return
        }
        XCTAssertEqual(tag, "<§R1§>")
        XCTAssertTrue(content.contains("\"tag\":\"<§R1§>\""))
        XCTAssertTrue(content.contains("\"path\":\"Sorter.swift\""))
        XCTAssertTrue(content.contains("let x = 1"))
    }

    /// The anti-dedup pin. An identical repeat read gets a FRESH tag and the FULL
    /// content again — there is no "unchanged" reference envelope any more.
    ///
    /// RED: reintroduce any unchanged-detection branch (return a compact
    /// reference for a byte-identical repeat) → this fails on both assertions.
    func testReadFile_identicalRepeat_getsFreshTagAndFullContent() {
        _ = sut.processToolResult(makeReadResult(path: "Sorter.swift", content: "let x = 1"))
        let second = sut.processToolResult(makeReadResult(path: "Sorter.swift", content: "let x = 1"))

        guard case .tagged(let content, let tag) = second else {
            return XCTFail("a repeat read must be tagged in full, got \(second)")
        }
        XCTAssertEqual(tag, "<§R2§>", "every action mints its own tag")
        XCTAssertTrue(content.contains("let x = 1"), "the full content ships every time")
    }

    func testReadLines_ReturnsTaggedWithLineRange() {
        let result = makeReadLinesResult(
            path: "Sorter.swift", content: "5 │ let x = 1",
            startLine: 5, endLine: 5)
        let tagResult = sut.processToolResult(result)

        guard case .tagged(let content, let tag) = tagResult else {
            XCTFail("Expected .tagged")
            return
        }
        XCTAssertEqual(tag, "<§R1§>")
        XCTAssertTrue(content.contains("\"lines\":\"5-5\""))
    }

    // MARK: - edit_file / write_file / delete_file

    func testEditFile_ReturnsTagged() {
        let tagResult = sut.processToolResult(makeEditResult(path: "Sorter.swift"))

        guard case .tagged(let content, let tag) = tagResult else {
            return XCTFail("Expected .tagged, got \(tagResult)")
        }
        XCTAssertEqual(tag, "<§E1§>")
        XCTAssertTrue(content.contains("\"status\":\"success\""))
        XCTAssertTrue(content.contains("\"path\":\"Sorter.swift\""))
    }

    func testEditFileError_ReturnsPassthrough() {
        let result = ToolExecutionResult(
            providerID: "call_err",
            toolName: "edit_file",
            argumentsJSON: "{\"path\":\"Sorter.swift\",\"old_text\":\"x\",\"new_text\":\"y\"}",
            outputJSON: "{\"ok\":false,\"error\":{\"code\":\"ANCHOR_NOT_FOUND\",\"message\":\"no match\"}}",
            isError: true
        )
        guard case .passthrough = sut.processToolResult(result) else {
            return XCTFail("errors must pass through untagged")
        }
    }

    func testWriteFile_ReturnsTaggedWithLineCount() {
        let tagResult = sut.processToolResult(
            makeWriteResult(path: "New.swift", content: "a\nb\nc"))

        guard case .tagged(let content, let tag) = tagResult else {
            return XCTFail("Expected .tagged, got \(tagResult)")
        }
        XCTAssertEqual(tag, "<§W1§>")
        XCTAssertTrue(content.contains("\"lines\":3"))
    }

    /// `delete_file` deliberately passes through untagged — its envelope is
    /// already minimal and nothing references a deletion afterwards.
    func testDeleteFile_isPassthrough() {
        let del = ToolExecutionResult(
            providerID: "call_del", toolName: "delete_file",
            argumentsJSON: "{\"path\":\"Old.swift\"}",
            outputJSON: "{\"ok\":true,\"data\":{\"path\":\"Old.swift\",\"deleted\":true}}",
            isError: false)
        guard case .passthrough = sut.processToolResult(del) else {
            return XCTFail("delete_file must pass through untagged")
        }
    }

    // MARK: - build / tests

    func testBuild_ReturnsTaggedSummary() {
        let result = makeBuildResult(success: true, errorCount: 0, warningCount: 2, issues: [])
        let tagResult = sut.processToolResult(result)

        guard case .tagged(let content, let tag) = tagResult else {
            return XCTFail("Expected .tagged, got \(tagResult)")
        }
        XCTAssertEqual(tag, "<§B1§>")
        XCTAssertTrue(content.contains("\"summary\""))
    }

    /// RED: reintroduce a same-summary reference or a delta-vs-previous branch →
    /// the second result stops carrying its own full summary and this fails.
    func testBuild_identicalRepeat_getsFreshTagAndFullSummary() {
        _ = sut.processToolResult(makeBuildResult(success: true, errorCount: 0, warningCount: 0, issues: []))
        let second = sut.processToolResult(
            makeBuildResult(success: true, errorCount: 0, warningCount: 0, issues: []))

        guard case .tagged(let content, let tag) = second else {
            return XCTFail("a repeat build must be tagged in full, got \(second)")
        }
        XCTAssertEqual(tag, "<§B2§>")
        XCTAssertTrue(content.contains("\"summary\""), "the full summary ships every time")
    }

    func testTests_ReturnsTaggedSummary() {
        let result = makeTestResult(passed: 10, failed: 0, skipped: 1, failures: [])
        let tagResult = sut.processToolResult(result)

        guard case .tagged(let content, let tag) = tagResult else {
            return XCTFail("Expected .tagged, got \(tagResult)")
        }
        XCTAssertEqual(tag, "<§B1§>", "tests share the B tag type")
        XCTAssertTrue(content.contains("\"summary\""))
    }

    // MARK: - git

    func testGitStatus_ReturnsTagged() {
        let tagResult = sut.processToolResult(makeGitStatusResult())

        guard case .tagged(let content, let tag) = tagResult else {
            return XCTFail("Expected .tagged, got \(tagResult)")
        }
        XCTAssertEqual(tag, "<§G1§>")
        XCTAssertTrue(content.contains("\"content\""))
    }

    func testGitDiff_identicalRepeat_getsFreshTagAndFullContent() {
        _ = sut.processToolResult(makeGitDiffResult(diff: "diff --git a b"))
        let second = sut.processToolResult(makeGitDiffResult(diff: "diff --git a b"))

        guard case .tagged(let content, let tag) = second else {
            return XCTFail("a repeat diff must be tagged in full, got \(second)")
        }
        XCTAssertEqual(tag, "<§G2§>")
        XCTAssertTrue(content.contains("diff --git a b"))
    }

    // MARK: - Unknown tools

    func testUnknownTool_ReturnsPassthrough() {
        let result = ToolExecutionResult(
            providerID: "call_x",
            toolName: "list_files",
            argumentsJSON: "{\"path\":\".\"}",
            outputJSON: "{\"ok\":true,\"data\":{\"files\":[\"a.txt\"]}}",
            isError: false
        )
        guard case .passthrough = sut.processToolResult(result) else {
            return XCTFail("unsupported tools must pass through")
        }
    }

    // MARK: - Counter seeding across step re-entry

    /// A resumed step replays `step.wireTranscript`, which carries the previous
    /// entry's tags, while the fresh store's counters start at zero. Seeding
    /// advances each per-type counter past the replayed tags so a handle is
    /// never re-minted for a different payload in the same conversation.
    ///
    /// RED: delete the `nextID[type] = max(…)` line in `seedTagCounters` → the
    /// first assertion mints `<§R1§>` again.
    func testSeedTagCounters_replayedTags_advanceEachTypeIndependently() {
        sut.seedTagCounters(replaying: [
            ChatMessage(role: .tool, content: "{\"tag\":\"<§R3§>\",\"path\":\"a\",\"content\":\"x\"}"),
            ChatMessage(role: .assistant, content: "I saw <§B2§> and <§R1§> earlier"),
        ])

        XCTAssertEqual(sut.nextTag(.read), "<§R4§>", "reads continue past the replayed maximum")
        XCTAssertEqual(sut.nextTag(.build), "<§B3§>")
        XCTAssertEqual(sut.nextTag(.edit), "<§E1§>", "types absent from the replay start fresh")
    }

    func testSeedTagCounters_freshConversation_isANoOp() {
        sut.seedTagCounters(replaying: [
            ChatMessage(role: .system, content: "prompt"),
            ChatMessage(role: .user, content: "task"),
        ])
        XCTAssertEqual(sut.nextTag(.read), "<§R1§>")
    }

    /// The seeding is only worth anything if `runStep` actually calls it on the
    /// assembled conversation before the tool loop starts. Source-scan wiring
    /// pin, same idiom as `RetryNudgeVisibilityTests`.
    func testSeedTagCounters_isWiredIntoRunStep() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LLM/
            .deletingLastPathComponent()   // Services/
            .deletingLastPathComponent()   // NanoTeamsTests/
            .deletingLastPathComponent()   // repo root
        let lifecycle = try String(
            contentsOf: root.appendingPathComponent(
                "NanoTeams/Services/LLM/LLMExecutionService+StepLifecycle.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            lifecycle.contains("seedTagCounters(replaying:" + " conversation)"),
            "runStep must seed the store from the assembled conversation — a resumed "
                + "step otherwise re-mints handles its replayed transcript already uses")
    }

    // MARK: - tagProducingTools (the legend's gate)

    /// `MemoryTagStore.tagProducingTools` is what gates and words the prompt's
    /// tag legend, so it must match what the processors actually TAG: every
    /// member yields `.tagged` for a success result, and the claimed-but-untagged
    /// tools stay out of the set.
    func testTagProducingTools_matchesActualTaggingBehavior() {
        for tool in MemoryTagStore.tagProducingTools {
            let store = MemoryTagStore()
            let result = successResult(for: tool)
            guard case .tagged = store.processToolResult(result) else {
                return XCTFail("\(tool) is in tagProducingTools but did not tag \(result.outputJSON)")
            }
        }

        for tool in [ToolNames.deleteFile, ToolNames.listFiles, ToolNames.search] {
            XCTAssertFalse(MemoryTagStore.tagProducingTools.contains(tool),
                           "\(tool) is claimed by a processor but never tagged — it must stay out of the legend gate")
        }
    }

    /// A minimal SUCCESS result of the shape each processor requires to tag.
    private func successResult(for tool: String) -> ToolExecutionResult {
        switch tool {
        case ToolNames.readFile, ToolNames.readLines:
            return ToolExecutionResult(
                toolName: tool, argumentsJSON: "{\"path\":\"A.swift\"}",
                outputJSON: "{\"ok\":true,\"data\":{\"content\":\"x\",\"start_line\":1,\"end_line\":1}}",
                isError: false)
        case ToolNames.editFile, ToolNames.writeFile:
            return ToolExecutionResult(
                toolName: tool, argumentsJSON: "{\"path\":\"A.swift\",\"content\":\"x\"}",
                outputJSON: "{\"ok\":true,\"data\":{\"path\":\"A.swift\",\"status\":\"success\"}}",
                isError: false)
        default:
            return ToolExecutionResult(
                toolName: tool, argumentsJSON: "{}",
                outputJSON: "{\"ok\":true,\"data\":{\"stdout\":\"x\"}}",
                isError: false)
        }
    }

    // MARK: - Envelope integrity (wire JSON)

    func testTaggedReadContent_keepsForwardSlashesLiteral_andEscapesBackslash() {
        let content = "let path = \"a/b\"\nlet win = \"C:\\\\x\""
        guard case .tagged(let tagged, _) = sut.processToolResult(
            makeReadResult(path: "src/deep/file.swift", content: content)) else {
            return XCTFail("expected .tagged")
        }
        XCTAssertTrue(tagged.contains("\"path\":\"src/deep/file.swift\""),
                      "forward slashes must stay literal: \(tagged)")
        XCTAssertFalse(tagged.contains("\\/"), "no escaped slashes on the wire: \(tagged)")
    }

    func testTaggedReadContent_isValidJSON_andRoundTripsVerbatim() throws {
        let content = "line1\n\"quoted\"\n\ttabbed"
        guard case .tagged(let tagged, _) = sut.processToolResult(
            makeReadResult(path: "a.swift", content: content)) else {
            return XCTFail("expected .tagged")
        }
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(tagged.utf8)) as? [String: Any])
        XCTAssertEqual(obj["content"] as? String, content, "content must round-trip verbatim")
        XCTAssertEqual(obj["path"] as? String, "a.swift")
    }

    func testTaggedReadLinesContent_keepsForwardSlashesLiteral() {
        guard case .tagged(let tagged, _) = sut.processToolResult(
            makeReadLinesResult(path: "src/x.js", content: "1 │ a/b", startLine: 1, endLine: 1)) else {
            return XCTFail("expected .tagged")
        }
        XCTAssertFalse(tagged.contains("\\/"), "slashes must stay literal: \(tagged)")
    }

    func testGitDiffTaggedContent_keepsSlashesLiteral_andRoundTrips() throws {
        let diff = "diff --git a/src/foo.swift b/src/foo.swift\n--- a/src/foo.swift\n+++ b/src/foo.swift\n@@ -1 +1 @@\n-import a/b\n+import a/c"
        guard case .tagged(let tagged, _) = sut.processToolResult(
            makeGitDiffResult(diff: diff)) else {
            return XCTFail("git diff should be tagged")
        }
        XCTAssertFalse(tagged.contains("\\/"), "git diff slashes must stay literal: \(tagged)")
        let obj = try JSONSerialization.jsonObject(with: tagged.data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(obj?["content"] as? String, diff, "diff must round-trip verbatim")
    }

    func testJsonEscape_roundTripsTrickyContent() throws {
        let tricky = "a\"b\\c\nd\te\u{1F600}"
        let escaped = sut.jsonEscape(tricky)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(escaped.utf8), options: .fragmentsAllowed) as? String)
        XCTAssertEqual(decoded, tricky)
    }

    func testJsonEscape_pureForwardSlashPath_staysLiteral() {
        XCTAssertEqual(sut.jsonEscape("a/b/c"), "\"a/b/c\"")
    }

    func testJsonEscape_literalBackslash_doublesButKeepsSlashLiteral() {
        XCTAssertEqual(sut.jsonEscape("a\\b/c"), "\"a\\\\b/c\"")
    }

    // MARK: - Helpers

    private func makeReadResult(path: String, content: String) -> ToolExecutionResult {
        // Mirrors the ReadFileTool envelope: first-N-lines slice with
        // start_line / end_line / total_lines.
        let totalLines = content.components(separatedBy: "\n").count
        let outputJSON = """
        {"ok":true,"data":{"path":"\(path)","content":\(jsonEscape(content)),"start_line":1,"end_line":\(totalLines),"total_lines":\(totalLines)}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "read_file",
            argumentsJSON: "{\"path\":\"\(path)\"}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeReadLinesResult(
        path: String, content: String, startLine: Int, endLine: Int, totalLines: Int = 100
    ) -> ToolExecutionResult {
        let outputJSON = """
        {"ok":true,"data":{"path":"\(path)","content":\(jsonEscape(content)),"start_line":\(startLine),"end_line":\(endLine),"total_lines":\(totalLines)}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "read_lines",
            argumentsJSON: "{\"path\":\"\(path)\",\"start_line\":\(startLine),\"end_line\":\(endLine)}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeEditResult(path: String) -> ToolExecutionResult {
        let outputJSON = """
        {"ok":true,"data":{"path":"\(path)","status":"success"}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "edit_file",
            argumentsJSON: "{\"path\":\"\(path)\",\"old_text\":\"x\",\"new_text\":\"y\"}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeWriteResult(path: String, content: String) -> ToolExecutionResult {
        let outputJSON = """
        {"ok":true,"data":{"path":"\(path)","status":"success"}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "write_file",
            argumentsJSON: "{\"path\":\"\(path)\",\"content\":\(jsonEscape(content))}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeBuildResult(
        success: Bool, errorCount: Int, warningCount: Int, issues: [[String: Any]]
    ) -> ToolExecutionResult {
        let issuesData = try! JSONSerialization.data(withJSONObject: issues)
        let issuesJSON = String(data: issuesData, encoding: .utf8)!
        let outputJSON = """
        {"ok":true,"data":{"success":\(success),"error_count":\(errorCount),"warning_count":\(warningCount),"issues":\(issuesJSON)}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "run_xcodebuild",
            argumentsJSON: "{}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeTestResult(
        passed: Int, failed: Int, skipped: Int, failures: [[String: Any]]
    ) -> ToolExecutionResult {
        let failuresData = try! JSONSerialization.data(withJSONObject: failures)
        let failuresJSON = String(data: failuresData, encoding: .utf8)!
        let outputJSON = """
        {"ok":true,"data":{"success":\(failed == 0),"passed":\(passed),"failed":\(failed),"skipped":\(skipped),"failures":\(failuresJSON)}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "run_xcodetests",
            argumentsJSON: "{}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeGitStatusResult() -> ToolExecutionResult {
        let outputJSON = """
        {"ok":true,"data":{"branch":"feature/foo","clean":false,"staged":["Foo.swift"],"modified":[],"untracked":[]}}
        """
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "git_status",
            argumentsJSON: "{}",
            outputJSON: outputJSON,
            isError: false
        )
    }

    private func makeGitDiffResult(diff: String) -> ToolExecutionResult {
        return ToolExecutionResult(
            providerID: "call_\(UUID().uuidString.prefix(4))",
            toolName: "git_diff",
            argumentsJSON: "{}",
            outputJSON: diff,
            isError: false
        )
    }

    private func jsonEscape(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)
        return String(data: data, encoding: .utf8)!
    }
}
