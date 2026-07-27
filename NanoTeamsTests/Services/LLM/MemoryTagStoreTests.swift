import XCTest

@testable import NanoTeams

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

    // MARK: - Path Key Canonicalization

    /// With a work folder root set, varied spellings of the same file collapse to one key
    /// so dedup / edit-invalidation / MEMORIES rows don't fragment.
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

    /// Reading the same file via a redundant-prefix spelling then the plain spelling must
    /// dedup to a reference — the actual cross-spelling payoff, not just `extractPath`.
    func testCanonicalKey_collapsesRedundantPrefix_acrossReads() throws {
        let root = makeNamedRoot("Foo")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = MemoryTagStore(workFolderRoot: root)

        guard case .tagged = store.processToolResult(
            makeReadResult(path: "Foo/src/x.js", content: "let x = 1"), iteration: 1) else {
            return XCTFail("first read should be tagged")
        }
        guard case .reference(let content) = store.processToolResult(
            makeReadResult(path: "src/x.js", content: "let x = 1"), iteration: 2) else {
            return XCTFail("same file via different spelling should dedup to a reference")
        }
        XCTAssertTrue(content.contains("<§R1§>"))
    }

    /// Editing via one spelling must invalidate a read cached under another spelling.
    func testCanonicalKey_editInvalidatesAcrossSpellings() throws {
        let root = makeNamedRoot("Foo")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = MemoryTagStore(workFolderRoot: root)

        _ = store.processToolResult(makeReadResult(path: "src/x.js", content: "let x = 1"), iteration: 1)
        _ = store.processToolResult(makeEditResult(path: "Foo/src/x.js"), iteration: 2)  // edit via redundant prefix
        guard case .tagged(let content, let tag) = store.processToolResult(
            makeReadResult(path: "src/x.js", content: "let x = 2"), iteration: 3) else {
            return XCTFail("post-edit read should be a fresh baseline, not a stale reference")
        }
        XCTAssertEqual(tag, "<§R2§>")
        XCTAssertTrue(content.contains("let x = 2"))
    }

    /// Deleting via one spelling must outdate a read tag cached under another spelling.
    func testCanonicalKey_deleteInvalidatesAcrossSpellings() throws {
        let root = makeNamedRoot("Foo")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = MemoryTagStore(workFolderRoot: root)

        _ = store.processToolResult(makeReadResult(path: "src/x.js", content: "let x = 1"), iteration: 1)  // R1
        let del = ToolExecutionResult(
            providerID: "call_del", toolName: "delete_file",
            argumentsJSON: "{\"path\":\"Foo/src/x.js\"}",
            outputJSON: "{\"ok\":true,\"data\":{\"path\":\"Foo/src/x.js\",\"deleted\":true}}",
            isError: false)
        _ = store.processToolResult(del, iteration: 2)

        guard case .outdated(let reason)? = store.entries["<§R1§>"]?.status else {
            return XCTFail("delete via a redundant-prefix spelling should outdate the read tag")
        }
        XCTAssertEqual(reason, "deleted")
    }

    func testExtractPath_escapingPath_returnsRaw_whenWorkFolderRootSet() throws {
        let root = makeNamedRoot("Foo")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = MemoryTagStore(workFolderRoot: root)
        XCTAssertEqual(store.extractPath(from: "{\"path\": \"../escape.js\"}"), "../escape.js")
        XCTAssertEqual(store.extractPath(from: "{\"path\": \"/etc/passwd\"}"), "/etc/passwd")
    }

    /// A genuine same-named subdir is NOT over-collapsed — `app/x.js` and `x.js` stay
    /// distinct keys (two different physical files keep two cache entries).
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

    // MARK: - read_file Processing

    func testReadFileFirstRead_ReturnsTaggedContent() {
        let result = makeReadResult(path: "Sorter.swift", content: "let x = 1")
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .tagged(let content, let tag) = tagResult else {
            XCTFail("Expected .tagged, got \(tagResult)")
            return
        }
        XCTAssertEqual(tag, "<§R1§>")
        XCTAssertTrue(content.contains("\"tag\":\"<§R1§>\""))
        XCTAssertTrue(content.contains("\"path\":\"Sorter.swift\""))
        XCTAssertTrue(content.contains("let x = 1"))
    }

    func testReadFileRepeatUnchanged_ReturnsReference() {
        let result = makeReadResult(path: "Sorter.swift", content: "let x = 1")
        _ = sut.processToolResult(result, iteration: 1)

        let result2 = makeReadResult(path: "Sorter.swift", content: "let x = 1")
        let tagResult2 = sut.processToolResult(result2, iteration: 2)

        guard case .reference(let content) = tagResult2 else {
            XCTFail("Expected .reference, got \(tagResult2)")
            return
        }
        XCTAssertTrue(content.contains("\"status\":\"unchanged\""))
        XCTAssertTrue(content.contains("\"ref\":\"<§R1§>\""))
    }

    func testReadFileAfterEdit_ReturnsNewBaseline() {
        let result1 = makeReadResult(path: "Sorter.swift", content: "let x = 1")
        _ = sut.processToolResult(result1, iteration: 1)

        // Edit the file
        let editResult = makeEditResult(path: "Sorter.swift")
        _ = sut.processToolResult(editResult, iteration: 2)

        // Read again — should get new baseline even with same content
        let result3 = makeReadResult(path: "Sorter.swift", content: "let x = 2")
        let tagResult3 = sut.processToolResult(result3, iteration: 3)

        guard case .tagged(let content, let tag) = tagResult3 else {
            XCTFail("Expected .tagged, got \(tagResult3)")
            return
        }
        XCTAssertEqual(tag, "<§R2§>")
        XCTAssertTrue(content.contains("let x = 2"))

        // Old tag should be replaced
        if case .replaced(let by) = sut.entries["<§R1§>"]?.status {
            XCTAssertEqual(by, "<§R2§>")
        } else {
            XCTFail("Expected R1 to be replaced")
        }
    }

    func testReadFileExternalChange_ReturnsNewBaseline() {
        let result1 = makeReadResult(path: "Sorter.swift", content: "let x = 1")
        _ = sut.processToolResult(result1, iteration: 1)

        // Read again with DIFFERENT content (external change, no edit)
        let result2 = makeReadResult(path: "Sorter.swift", content: "let x = 99")
        let tagResult2 = sut.processToolResult(result2, iteration: 2)

        guard case .tagged(_, let tag) = tagResult2 else {
            XCTFail("Expected .tagged for external change")
            return
        }
        XCTAssertEqual(tag, "<§R2§>")
    }

    // MARK: - read_lines Processing

    func testReadLinesFirstRead_ReturnsTagged() {
        let result = makeReadLinesResult(
            path: "Sorter.swift", content: "5 │ let x = 1",
            startLine: 5, endLine: 5)
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .tagged(let content, let tag) = tagResult else {
            XCTFail("Expected .tagged")
            return
        }
        XCTAssertEqual(tag, "<§R1§>")
        XCTAssertTrue(content.contains("\"lines\":\"5-5\""))
    }

    func testReadLinesRepeatUnchanged_ReturnsReference() {
        let result = makeReadLinesResult(
            path: "Sorter.swift", content: "5 │ let x = 1",
            startLine: 5, endLine: 5)
        _ = sut.processToolResult(result, iteration: 1)

        let result2 = makeReadLinesResult(
            path: "Sorter.swift", content: "5 │ let x = 1",
            startLine: 5, endLine: 5)
        let tagResult2 = sut.processToolResult(result2, iteration: 2)

        guard case .reference(let content) = tagResult2 else {
            XCTFail("Expected .reference")
            return
        }
        XCTAssertTrue(content.contains("\"status\":\"unchanged\""))
    }

    func testReadLinesInvalidatedByEdit() {
        let result = makeReadLinesResult(
            path: "Sorter.swift", content: "5 │ let x = 1",
            startLine: 5, endLine: 5)
        _ = sut.processToolResult(result, iteration: 1)

        // Edit the file
        let editResult = makeEditResult(path: "Sorter.swift")
        _ = sut.processToolResult(editResult, iteration: 2)

        // Read same lines — should get new baseline
        let result2 = makeReadLinesResult(
            path: "Sorter.swift", content: "5 │ let x = 2",
            startLine: 5, endLine: 5)
        let tagResult2 = sut.processToolResult(result2, iteration: 3)

        guard case .tagged(_, let tag) = tagResult2 else {
            XCTFail("Expected .tagged after edit")
            return
        }
        XCTAssertEqual(tag, "<§R2§>")
    }

    /// Regression: a partial re-read after `edit_file` was clearing the
    /// per-path "edited since last read" flag, which made a subsequent read
    /// of a *different* range incorrectly short-circuit to the pre-edit tag
    /// reference (stale content). The flag must only clear when the FULL
    /// file is re-read so all stale ranges have been observably refreshed.
    func testReadLinesAfterEdit_doesNotClearStalenessForOtherRanges() {
        // 1. Read range 1-50 — establishes baseline R1 for that range.
        let r1 = makeReadLinesResult(
            path: "Foo.swift", content: "lines 1..50 original",
            startLine: 1, endLine: 50)
        _ = sut.processToolResult(r1, iteration: 1)

        // 2. Edit the file — staleness flag set for path.
        _ = sut.processToolResult(makeEditResult(path: "Foo.swift"), iteration: 2)

        // 3. Read range 60-100. This is a NEW range, so it gets a fresh tag —
        //    but the per-path staleness flag must NOT be cleared because the
        //    1-50 range is still stale (the edit's effect on that range was
        //    never observed).
        let r2 = makeReadLinesResult(
            path: "Foo.swift", content: "lines 60..100 post-edit",
            startLine: 60, endLine: 100)
        _ = sut.processToolResult(r2, iteration: 3)

        // 4. Re-read range 1-50 with the *original* (now stale) content. This
        //    can happen when the LLM repeats a read to get cached content.
        //    Must return a NEW tagged baseline, NOT a reference to R1 — the
        //    edit at step 2 invalidated the original 1-50 baseline.
        let r3 = makeReadLinesResult(
            path: "Foo.swift", content: "lines 1..50 original",
            startLine: 1, endLine: 50)
        let result = sut.processToolResult(r3, iteration: 4)

        if case .reference = result {
            XCTFail("Re-read of stale range after edit must NOT return a reference; got reference to pre-edit tag")
        }
    }

    /// The per-call line cap on `read_lines` means a single call may not
    /// satisfy the legacy `endLine == totalLines` shortcut on large files.
    /// Paginated reads that collectively cover [1, totalLines] must clear
    /// the staleness flag — otherwise post-edit identical re-reads bypass
    /// the cache forever, re-injecting full content into LLM context.
    func testReadLines_paginatedCoverageAfterEdit_clearsStaleness() {
        // Establish per-page baselines so the post-edit re-read has a tag
        // to potentially reference.
        let total = 100
        _ = sut.processToolResult(makeReadLinesResult(
            path: "Foo.swift", content: "page 1", startLine: 1, endLine: 50, totalLines: total
        ), iteration: 1)
        _ = sut.processToolResult(makeReadLinesResult(
            path: "Foo.swift", content: "page 2", startLine: 51, endLine: 100, totalLines: total
        ), iteration: 2)

        _ = sut.processToolResult(makeEditResult(path: "Foo.swift"), iteration: 3)

        // Paginated re-read covers [1, 100] across two calls.
        _ = sut.processToolResult(makeReadLinesResult(
            path: "Foo.swift", content: "page 1 v2", startLine: 1, endLine: 50, totalLines: total
        ), iteration: 4)
        _ = sut.processToolResult(makeReadLinesResult(
            path: "Foo.swift", content: "page 2 v2", startLine: 51, endLine: 100, totalLines: total
        ), iteration: 5)

        // Identical-content re-read of the just-covered range must now
        // short-circuit to a reference — staleness has been resolved.
        let probe = sut.processToolResult(makeReadLinesResult(
            path: "Foo.swift", content: "page 1 v2", startLine: 1, endLine: 50, totalLines: total
        ), iteration: 6)

        guard case .reference = probe else {
            XCTFail("Paginated coverage of [1, total] should clear staleness; expected .reference, got \(probe)")
            return
        }
    }

    func testReadLines_outOfOrderPaginatedCoverage_clearsStaleness() {
        // Same scenario as above, but pages re-read in reverse order.
        // IndexSet-backed coverage must accumulate regardless of read order.
        let total = 100
        _ = sut.processToolResult(makeReadLinesResult(
            path: "Bar.swift", content: "p1", startLine: 1, endLine: 50, totalLines: total
        ), iteration: 1)
        _ = sut.processToolResult(makeReadLinesResult(
            path: "Bar.swift", content: "p2", startLine: 51, endLine: 100, totalLines: total
        ), iteration: 2)

        _ = sut.processToolResult(makeEditResult(path: "Bar.swift"), iteration: 3)

        // Reverse order: read page 2 first, then page 1.
        _ = sut.processToolResult(makeReadLinesResult(
            path: "Bar.swift", content: "p2 v2", startLine: 51, endLine: 100, totalLines: total
        ), iteration: 4)
        _ = sut.processToolResult(makeReadLinesResult(
            path: "Bar.swift", content: "p1 v2", startLine: 1, endLine: 50, totalLines: total
        ), iteration: 5)

        let probe = sut.processToolResult(makeReadLinesResult(
            path: "Bar.swift", content: "p2 v2", startLine: 51, endLine: 100, totalLines: total
        ), iteration: 6)

        guard case .reference = probe else {
            XCTFail("Out-of-order paginated coverage should still clear staleness; got \(probe)")
            return
        }
    }

    func testReadLines_partialPaginatedCoverageAfterEdit_staysStaleAcrossRanges() {
        // Only page 1 is re-read after the edit. Coverage [1, 50] does not
        // satisfy [1, 100]; the staleness flag must remain set so a re-read
        // of page 2 can't short-circuit to its pre-edit baseline.
        let total = 100
        _ = sut.processToolResult(makeReadLinesResult(
            path: "Baz.swift", content: "p1 orig", startLine: 1, endLine: 50, totalLines: total
        ), iteration: 1)
        _ = sut.processToolResult(makeReadLinesResult(
            path: "Baz.swift", content: "p2 orig", startLine: 51, endLine: 100, totalLines: total
        ), iteration: 2)

        _ = sut.processToolResult(makeEditResult(path: "Baz.swift"), iteration: 3)

        // Partial: only page 1 re-read after edit.
        _ = sut.processToolResult(makeReadLinesResult(
            path: "Baz.swift", content: "p1 v2", startLine: 1, endLine: 50, totalLines: total
        ), iteration: 4)

        // Re-read page 2 with the *original* content. Must NOT return a
        // reference — coverage is incomplete, so the page-2 baseline is
        // still considered stale relative to the edit.
        let probe = sut.processToolResult(makeReadLinesResult(
            path: "Baz.swift", content: "p2 orig", startLine: 51, endLine: 100, totalLines: total
        ), iteration: 5)

        if case .reference = probe {
            XCTFail("Partial coverage must NOT clear staleness for unread ranges; got reference to stale page-2 baseline")
        }
    }

    // MARK: - edit_file Processing

    func testEditFile_ReturnsTaggedAndInvalidatesRead() {
        // First read the file
        let readResult = makeReadResult(path: "Foo.swift", content: "original")
        _ = sut.processToolResult(readResult, iteration: 1)

        // Edit it
        let editResult = makeEditResult(path: "Foo.swift")
        let tagResult = sut.processToolResult(editResult, iteration: 2)

        guard case .tagged(let content, let tag) = tagResult else {
            XCTFail("Expected .tagged for edit")
            return
        }
        XCTAssertEqual(tag, "<§E1§>")
        XCTAssertTrue(content.contains("\"status\":\"success\""))

        // Read tag should be outdated
        if case .outdated(let reason) = sut.entries["<§R1§>"]?.status {
            XCTAssertEqual(reason, "<§E1§>")
        } else {
            XCTFail("Expected R1 to be outdated")
        }
    }

    func testEditFileError_ReturnsPassthrough() {
        let result = ToolExecutionResult(
            providerID: "call_1",
            toolName: "edit_file",
            argumentsJSON: "{\"path\":\"Foo.swift\",\"old_text\":\"x\",\"new_text\":\"y\"}",
            outputJSON: "{\"error\":\"old_text not found\"}",
            isError: true
        )
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .passthrough = tagResult else {
            XCTFail("Expected .passthrough for failed edit")
            return
        }
    }

    // MARK: - write_file Processing

    func testWriteFile_CreatesNewBaseline() {
        // First read the file
        let readResult = makeReadResult(path: "Foo.swift", content: "original")
        _ = sut.processToolResult(readResult, iteration: 1)

        // Write new content
        let writeResult = makeWriteResult(path: "Foo.swift", content: "new content")
        let tagResult = sut.processToolResult(writeResult, iteration: 2)

        guard case .tagged(let content, let tag) = tagResult else {
            XCTFail("Expected .tagged for write")
            return
        }
        XCTAssertEqual(tag, "<§W1§>")
        XCTAssertTrue(content.contains("\"status\":\"success\""))

        // `read_file` now keys reads by range (`path:start-end`); `processWrite` invalidates
        // every range for the path via `invalidateReadRanges` → `.outdated(reason: W1)`,
        // not `.replaced(by: W1)` (the latter is reserved for collisions on the same key).
        if case .outdated(let reason) = sut.entries["<§R1§>"]?.status {
            XCTAssertEqual(reason, "<§W1§>")
        } else {
            XCTFail("Expected R1 to be outdated by W1, got: \(String(describing: sut.entries["<§R1§>"]?.status))")
        }
    }

    // MARK: - delete_file Processing

    func testDeleteFile_OutdatesAllTagsForPath() {
        let readResult = makeReadResult(path: "Foo.swift", content: "content")
        _ = sut.processToolResult(readResult, iteration: 1)

        let deleteResult = ToolExecutionResult(
            providerID: "call_1",
            toolName: "delete_file",
            argumentsJSON: "{\"path\":\"Foo.swift\"}",
            outputJSON: "{\"ok\":true}",
            isError: false
        )
        let tagResult = sut.processToolResult(deleteResult, iteration: 2)

        guard case .passthrough = tagResult else {
            XCTFail("Expected .passthrough for delete")
            return
        }

        // Read tag should be outdated
        if case .outdated(let reason) = sut.entries["<§R1§>"]?.status {
            XCTAssertEqual(reason, "deleted")
        } else {
            XCTFail("Expected R1 to be outdated [deleted]")
        }
    }

    // MARK: - Build Processing

    func testBuildFirstRun_ReturnsTagged() {
        let result = makeBuildResult(success: false, errorCount: 2, warningCount: 1, issues: [
            ["severity": "error", "message": "Cannot find type", "file": "Foo.swift", "line": 5],
            ["severity": "error", "message": "Expected '}'", "file": "Foo.swift", "line": 10],
            ["severity": "warning", "message": "Unused var", "file": "Foo.swift", "line": 3],
        ])
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .tagged(let content, let tag) = tagResult else {
            XCTFail("Expected .tagged for build")
            return
        }
        XCTAssertEqual(tag, "<§B1§>")
        XCTAssertTrue(content.contains("<§B1§>"))
    }

    func testBuildRepeatSameResult_ReturnsReference() {
        let result = makeBuildResult(success: true, errorCount: 0, warningCount: 0, issues: [])
        _ = sut.processToolResult(result, iteration: 1)

        let result2 = makeBuildResult(success: true, errorCount: 0, warningCount: 0, issues: [])
        let tagResult2 = sut.processToolResult(result2, iteration: 2)

        guard case .reference(let content) = tagResult2 else {
            XCTFail("Expected .reference for unchanged build")
            return
        }
        XCTAssertTrue(content.contains("\"status\":\"unchanged\""))
    }

    func testBuildInvalidatedByEdit() {
        let result = makeBuildResult(success: true, errorCount: 0, warningCount: 0, issues: [])
        _ = sut.processToolResult(result, iteration: 1)

        // Edit a file
        let editResult = makeEditResult(path: "Foo.swift")
        _ = sut.processToolResult(editResult, iteration: 2)

        // Build tag should be outdated
        if case .outdated = sut.entries["<§B1§>"]?.status {
            // Expected
        } else {
            XCTFail("Expected B1 to be outdated after edit")
        }
    }

    // MARK: - Test Processing

    func testTestsFirstRun_ReturnsTagged() {
        let result = makeTestResult(passed: 10, failed: 1, skipped: 0, failures: [
            ["scheme": "NanoTeams", "file": "FooTests.swift", "line": 15, "message": "XCTAssertEqual failed"],
        ])
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .tagged(_, let tag) = tagResult else {
            XCTFail("Expected .tagged for tests")
            return
        }
        XCTAssertEqual(tag, "<§B1§>")
    }

    // MARK: - Git Processing

    func testGitStatusFirstCall_ReturnsTagged() {
        let result = makeGitStatusResult()
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .tagged(_, let tag) = tagResult else {
            XCTFail("Expected .tagged for git_status")
            return
        }
        XCTAssertEqual(tag, "<§G1§>")
    }

    func testGitDiffFirstCall_ReturnsTagged() {
        let result = makeGitDiffResult(diff: "diff --git a/Foo.swift")
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .tagged(_, let tag) = tagResult else {
            XCTFail("Expected .tagged for git_diff")
            return
        }
        XCTAssertEqual(tag, "<§G1§>")
    }

    func testGitDiffRepeatUnchanged_ReturnsReference() {
        let diff = "diff --git a/Foo.swift b/Foo.swift"
        let result1 = makeGitDiffResult(diff: diff)
        _ = sut.processToolResult(result1, iteration: 1)

        let result2 = makeGitDiffResult(diff: diff)
        let tagResult2 = sut.processToolResult(result2, iteration: 2)

        guard case .reference(let content) = tagResult2 else {
            XCTFail("Expected .reference for unchanged diff")
            return
        }
        XCTAssertTrue(content.contains("\"status\":\"unchanged\""))
    }

    func testGitInvalidatedByEdit() {
        let result = makeGitStatusResult()
        _ = sut.processToolResult(result, iteration: 1)

        let editResult = makeEditResult(path: "Foo.swift")
        _ = sut.processToolResult(editResult, iteration: 2)

        if case .outdated = sut.entries["<§G1§>"]?.status {
            // Expected
        } else {
            XCTFail("Expected G1 to be outdated after edit")
        }
    }

    // MARK: - Passthrough

    func testUnknownTool_ReturnsPassthrough() {
        let result = ToolExecutionResult(
            providerID: "call_1",
            toolName: "list_files",
            argumentsJSON: "{\"path\":\".\"}", outputJSON: "{\"files\":[\"a.txt\"]}",
            isError: false
        )
        let tagResult = sut.processToolResult(result, iteration: 1)

        guard case .passthrough = tagResult else {
            XCTFail("Expected .passthrough for unknown tool")
            return
        }
    }

    // MARK: - Memories Generation

    func testGenerateMemories_ContainsAllTags() {
        let read = makeReadResult(path: "Foo.swift", content: "content")
        _ = sut.processToolResult(read, iteration: 1)

        let edit = makeEditResult(path: "Foo.swift")
        _ = sut.processToolResult(edit, iteration: 2)

        let memories = sut.generateMemories(version: 1)

        XCTAssertNotNil(memories)
        XCTAssertTrue(memories?.contains("## Memories v1") == true)
        XCTAssertTrue(memories?.contains("<§R1§>") == true)
        XCTAssertTrue(memories?.contains("<§E1§>") == true)
    }

    func testGenerateMemories_WithPlanTag() {
        sut.registerPlanUpdate(content: "1. Step 1\n2. Step 2", iteration: 1)
        let memories = sut.generateMemories(version: 1)
        XCTAssertTrue(memories?.contains("<§P1§>") == true)
        XCTAssertTrue(memories?.contains("CURRENT") == true)
        XCTAssertTrue(memories?.contains("plan") == true)
    }

    func testGenerateMemories_ShowsCorrectStatuses() {
        // Read -> Edit -> Read (new baseline)
        let read1 = makeReadResult(path: "A.swift", content: "v1")
        _ = sut.processToolResult(read1, iteration: 1)

        let edit = makeEditResult(path: "A.swift")
        _ = sut.processToolResult(edit, iteration: 2)

        let read2 = makeReadResult(path: "A.swift", content: "v2")
        _ = sut.processToolResult(read2, iteration: 3)

        let memories = sut.generateMemories(version: 3)

        // R1 should be OUTDATED or REPLACED, E1 should be CURRENT, R2 should be CURRENT
        XCTAssertTrue(memories?.contains("OUTDATED") == true || memories?.contains("REPLACED") == true)
        XCTAssertTrue(memories?.contains("CURRENT") == true)
    }

    /// `generateMemories` returns nil when nothing has been tracked yet — the
    /// caller uses this to short-circuit the MEMORIES injection so an empty
    /// header/footer doesn't appear in every iteration of a no-file-reads role.
    func testGenerateMemories_emptyStore_returnsNil() {
        XCTAssertNil(sut.generateMemories(version: 1))
    }

    // MARK: - Cross-tool Interactions

    func testWriteInvalidatesBuildsAndGit() {
        let build = makeBuildResult(success: true, errorCount: 0, warningCount: 0, issues: [])
        _ = sut.processToolResult(build, iteration: 1)

        let git = makeGitStatusResult()
        _ = sut.processToolResult(git, iteration: 1)

        let write = makeWriteResult(path: "Foo.swift", content: "new")
        _ = sut.processToolResult(write, iteration: 2)

        // Both build and git should be outdated
        if case .outdated = sut.entries["<§B1§>"]?.status {
            // Expected
        } else {
            XCTFail("Expected build tag to be outdated after write")
        }

        if case .outdated = sut.entries["<§G1§>"]?.status {
            // Expected
        } else {
            XCTFail("Expected git tag to be outdated after write")
        }
    }

    func testDeleteInvalidatesAllRangesForPath() {
        // Read first N lines (whole file, since it's only 3 lines) and a sub-range.
        // Distinct ranges so they get distinct range keys (`path:1-3` vs `path:1-1`).
        let readFull = makeReadResult(path: "Foo.swift", content: "line1\nline2\nline3")
        _ = sut.processToolResult(readFull, iteration: 1)

        let readRange = makeReadLinesResult(
            path: "Foo.swift", content: "1 │ line1", startLine: 1, endLine: 1)
        _ = sut.processToolResult(readRange, iteration: 1)

        // Delete file
        let deleteResult = ToolExecutionResult(
            providerID: "call_1",
            toolName: "delete_file",
            argumentsJSON: "{\"path\":\"Foo.swift\"}",
            outputJSON: "{\"ok\":true}",
            isError: false
        )
        _ = sut.processToolResult(deleteResult, iteration: 2)

        // Both full read and range read should be outdated
        if case .outdated(let reason) = sut.entries["<§R1§>"]?.status {
            XCTAssertEqual(reason, "deleted")
        } else {
            XCTFail("Expected R1 (full read) to be outdated")
        }

        if case .outdated(let reason) = sut.entries["<§R2§>"]?.status {
            XCTAssertEqual(reason, "deleted")
        } else {
            XCTFail("Expected R2 (range read) to be outdated")
        }
    }

    // MARK: - Slash escaping in tagged read content

    /// The tagged read envelope the model reads back must keep forward slashes
    /// literal (`/`, never `\/`). The `\/` form is what drove qwen3.5 to
    /// mis-transcribe paths into backslashes in edit_file anchors → an unbreakable
    /// edit→re-read loop. A literal backslash in the file must still round-trip
    /// (escaped as `\\`), proving we didn't naively strip `\/` → `/`.
    func testTaggedReadContent_keepsForwardSlashesLiteral_andEscapesBackslash() {
        let content = "import { Q } from '../systems/Q.js';\nimport { U } from '../systems\\U.js';"
        guard case .tagged(let tagged, _) = sut.processToolResult(
            makeReadResult(path: "src/engine/Game.js", content: content), iteration: 1) else {
            return XCTFail("read should be tagged")
        }
        XCTAssertFalse(tagged.contains("\\/"),
                       "tagged read content must not escape forward slashes: \(tagged)")
        XCTAssertTrue(tagged.contains("\"path\":\"src/engine/Game.js\""),
                      "path slashes must be literal: \(tagged)")
        XCTAssertTrue(tagged.contains("../systems/Q.js"),
                      "content slashes must be literal: \(tagged)")
        XCTAssertTrue(tagged.contains("../systems\\\\U.js"),
                      "literal backslash must round-trip as \\\\: \(tagged)")
    }

    /// `jsonEscape` must produce a valid JSON string token that parses back to the
    /// exact input — empty strings, quotes, control chars, unicode, and any mix of
    /// `/` and literal `\`. This is the invariant that lets us drop slash escaping
    /// without ever emitting malformed JSON to the model.
    func testJsonEscape_roundTripsTrickyContent() throws {
        let cases = [
            "",
            "////",                                 // content that is only slashes
            "src/dir/",                             // trailing slash
            "line1\r\nline2",                       // CRLF — anchor must preserve \r
            "../systems/Foo.js",
            "../systems\\Foo.js",                 // literal backslash
            "a\"b\"c",                              // double quotes
            "line1\nline2\ttabbed",                 // newline + tab
            "..\\/leadingBackslashThenSlash",       // backslash immediately before slash
            "Юникод / путь \\ back",                // unicode + both slash kinds
            "{\"nested\":\"json/like\\value\"}",    // json-like content
        ]
        for original in cases {
            let escaped = sut.jsonEscape(original)
            let decoded = try JSONSerialization.jsonObject(
                with: escaped.data(using: .utf8)!, options: [.fragmentsAllowed]) as? String
            XCTAssertEqual(decoded, original, "round-trip failed; escaped=\(escaped)")
        }
    }

    func testJsonEscape_pureForwardSlashPath_staysLiteral() {
        XCTAssertEqual(sut.jsonEscape("../systems/Foo.js"), "\"../systems/Foo.js\"")
    }

    func testJsonEscape_literalBackslash_doublesButKeepsSlashLiteral() {
        // `../a\b/c` → forward slashes literal, the single backslash doubled.
        XCTAssertEqual(sut.jsonEscape("../a\\b/c"), "\"../a\\\\b/c\"")
    }

    /// The tagged read envelope must always be parseable JSON and the content must
    /// survive verbatim — even when the file mixes quotes, newlines, slashes, and a
    /// literal backslash on the same line.
    func testTaggedReadContent_isValidJSON_andRoundTripsVerbatim() throws {
        let content = "const s = \"a/b\";\nimport x from '../sys\\Helper.js'; // path/with/slashes"
        guard case .tagged(let tagged, _) = sut.processToolResult(
            makeReadResult(path: "src/a/b.js", content: content), iteration: 1) else {
            return XCTFail("read should be tagged")
        }
        let obj = try JSONSerialization.jsonObject(with: tagged.data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(obj?["content"] as? String, content, "content must round-trip exactly")
        XCTAssertEqual(obj?["path"] as? String, "src/a/b.js")
    }

    /// The dedup "unchanged" reference (re-read of the same range) must also keep
    /// path slashes literal and remain valid JSON — it's the response the model
    /// receives when the edit error told it to re-read.
    func testUnchangedReference_keepsPathSlashesLiteral_andIsValidJSON() throws {
        _ = sut.processToolResult(makeReadResult(path: "src/engine/Game.js", content: "x"), iteration: 1)
        guard case .reference(let ref) = sut.processToolResult(
            makeReadResult(path: "src/engine/Game.js", content: "x"), iteration: 2) else {
            return XCTFail("repeat read of the same range should dedup to a reference")
        }
        XCTAssertFalse(ref.contains("\\/"), "reference path must keep slashes literal: \(ref)")
        let obj = try JSONSerialization.jsonObject(with: ref.data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(obj?["path"] as? String, "src/engine/Game.js")
        XCTAssertEqual(obj?["status"] as? String, "unchanged")
    }

    /// `read_lines` shares `processRangedRead` with `read_file` today, but it's the
    /// path the model actually used in the bug report — pin its slashes explicitly
    /// so a future divergence can't silently re-escape them.
    func testTaggedReadLinesContent_keepsForwardSlashesLiteral() {
        guard case .tagged(let tagged, _) = sut.processToolResult(
            makeReadLinesResult(path: "src/a/b.js", content: "import x from '../sys/H.js';",
                                startLine: 1, endLine: 1), iteration: 1) else {
            return XCTFail("read_lines should be tagged")
        }
        XCTAssertFalse(tagged.contains("\\/"), "read_lines content slashes must stay literal: \(tagged)")
        XCTAssertTrue(tagged.contains("\"path\":\"src/a/b.js\""), "path slashes must be literal: \(tagged)")
        XCTAssertTrue(tagged.contains("../sys/H.js"), "content slashes must be literal: \(tagged)")
    }

    /// A git diff is the densest forward-slash payload the model reads back, and it
    /// directly feeds edit_file anchor decisions — the exact blast radius of the bug.
    /// The other git tests discard the tagged content, so pin slashes here.
    func testGitDiffTaggedContent_keepsSlashesLiteral_andRoundTrips() throws {
        let diff = "diff --git a/src/foo.swift b/src/foo.swift\n--- a/src/foo.swift\n+++ b/src/foo.swift\n@@ -1 +1 @@\n-import a/b\n+import a/c"
        guard case .tagged(let tagged, _) = sut.processToolResult(
            makeGitDiffResult(diff: diff), iteration: 1) else {
            return XCTFail("git diff should be tagged")
        }
        XCTAssertFalse(tagged.contains("\\/"), "git diff slashes must stay literal: \(tagged)")
        let obj = try JSONSerialization.jsonObject(with: tagged.data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(obj?["content"] as? String, diff, "diff must round-trip verbatim")
    }

    // MARK: - Helpers

    private func makeReadResult(path: String, content: String) -> ToolExecutionResult {
        // Mirrors the new ReadFileTool envelope: first-N-lines slice with
        // start_line / end_line / total_lines so MemoryTagStore can build a range key.
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

    // MARK: - resetForFreshConversation (the planning→implementation boundary)

    /// The wedge this exists to prevent: the boundary discards the exploration
    /// transcript, so a repeat read that short-circuits to
    /// `{"status":"unchanged","ref":"<§R1§>","_hint":"Do NOT re-read"}` hands the
    /// model a pointer to content it can no longer see, together with an
    /// instruction not to fetch it. There is then no route to the file at all.
    func testResetForFreshConversation_repeatReadReturnsFullContentAgain() {
        guard case .tagged = sut.processToolResult(
            makeReadResult(path: "src/x.js", content: "let x = 1"), iteration: 1) else {
            return XCTFail("first read should be tagged")
        }
        guard case .reference = sut.processToolResult(
            makeReadResult(path: "src/x.js", content: "let x = 1"), iteration: 2) else {
            return XCTFail("precondition: an unchanged repeat read dedups to a reference")
        }

        sut.resetForFreshConversation()

        guard case .tagged(let content, _) = sut.processToolResult(
            makeReadResult(path: "src/x.js", content: "let x = 1"), iteration: 3) else {
            return XCTFail("after the boundary the model has NOT seen this file — send it")
        }
        XCTAssertTrue(content.contains("let x = 1"))
    }

    /// Tags stay monotonic across the reset. A phase-2 read reusing `<§R1§>`
    /// would collide with the phase-1 tag still visible in `llmConversation`,
    /// `tool_calls.jsonl` and the activity feed.
    func testResetForFreshConversation_keepsTagCountersMonotonic() {
        _ = sut.processToolResult(makeReadResult(path: "a.js", content: "1"), iteration: 1)
        sut.resetForFreshConversation()

        guard case .tagged(_, let tag) = sut.processToolResult(
            makeReadResult(path: "b.js", content: "2"), iteration: 2) else {
            return XCTFail("expected a fresh baseline")
        }
        XCTAssertEqual(tag, "<§R2§>", "counters must not rewind")
        XCTAssertNil(sut.entries["<§R1§>"], "the discarded conversation's entries are gone")
    }

    /// An edit recorded before the boundary must not keep invalidating reads
    /// afterwards — the whole per-path bookkeeping describes a conversation that
    /// no longer exists.
    func testResetForFreshConversation_clearsEditInvalidationState() {
        _ = sut.processToolResult(makeReadResult(path: "x.js", content: "1"), iteration: 1)
        _ = sut.processToolResult(makeEditResult(path: "x.js"), iteration: 2)

        sut.resetForFreshConversation()

        guard case .tagged = sut.processToolResult(
            makeReadResult(path: "x.js", content: "2"), iteration: 3) else {
            return XCTFail("expected a clean baseline read")
        }
        guard case .reference = sut.processToolResult(
            makeReadResult(path: "x.js", content: "2"), iteration: 4) else {
            return XCTFail("dedup must work normally again after the reset")
        }
    }

    func testResetForFreshConversation_isIdempotentAndSafeWhenEmpty() {
        sut.resetForFreshConversation()
        sut.resetForFreshConversation()
        XCTAssertTrue(sut.entries.isEmpty)
    }
}
