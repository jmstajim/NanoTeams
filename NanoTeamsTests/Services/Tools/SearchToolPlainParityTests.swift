import XCTest
@testable import NanoTeams

/// Parity tests for the post-refactor `SearchTool.handle` plain path —
/// confirms the envelope shape, key ordering, and behavior match what the
/// LLM saw before `SearchExecutor` was extracted. Any field rename,
/// dropped key, or change in match ordering would shift the LLM's parsing
/// in ways that are hard to detect from a CI run alone.
final class SearchToolPlainParityTests: XCTestCase {

    private let fm = FileManager.default
    private var tempDir: URL!
    private var resolver: SandboxPathResolver!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
        resolver = SandboxPathResolver(workFolderRoot: tempDir, internalDir: internalDir)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        resolver = nil
        try super.tearDownWithError()
    }

    private func makeTool() -> SearchTool {
        SearchTool(
            resolver: resolver,
            fileManager: fm,
            workFolderRoot: tempDir,
            internalDir: tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true),
            exploratoryByDefault: false,
            defaultMaxResults: AppDefaults.searchMaxResults,
            defaultContextBefore: AppDefaults.searchContextBefore,
            defaultContextAfter: AppDefaults.searchContextAfter
        )
    }

    private func ctx() -> ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "tester")
    }

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func parse(_ json: String) throws -> [String: Any] {
        let data = json.data(using: .utf8) ?? Data()
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ParityTests", code: 0)
        }
        return dict
    }

    // MARK: - Paging cursor

    /// The description tells the model to repeat the call with `offset: next_offset`. That is
    /// only sound if the field is actually there whenever another page is promised — and if it
    /// really is where the next page starts.
    private func searchData(_ args: [String: Any]) async throws -> [String: Any] {
        let result = await makeTool().handle(context: ctx(), args: args)
        XCTAssertFalse(result.isError, result.outputJSON)
        let dict = try parse(result.outputJSON)
        return try XCTUnwrap(dict["data"] as? [String: Any])
    }

    func testPaging_nextOffsetAccompaniesHasMore() async throws {
        for i in 0..<9 { try write("f\(i).swift", content: "NEEDLE\n") }

        let page = try await searchData(["query": "NEEDLE", "max_results": 4])
        XCTAssertEqual(page["has_more"] as? Bool, true)
        XCTAssertEqual(page["count"] as? Int, 4)
        XCTAssertEqual(page["next_offset"] as? Int, 4, "0 + 4")
    }

    /// No further page, no cursor — a cursor there would invite one more empty round trip.
    func testPaging_nextOffsetAbsentOnTheLastPage() async throws {
        for i in 0..<3 { try write("f\(i).swift", content: "NEEDLE\n") }

        let page = try await searchData(["query": "NEEDLE", "max_results": 50])
        XCTAssertNil(page["has_more"])
        XCTAssertNil(page["next_offset"])
    }

    /// Following the cursor verbatim must partition the result set — no repeats, no gaps.
    func testPaging_followingTheCursorVisitsEveryMatchOnce() async throws {
        for i in 0..<9 { try write("f\(i).swift", content: "NEEDLE\n") }

        var seen: [String] = []
        var args: [String: Any] = ["query": "NEEDLE", "max_results": 4]
        for _ in 0..<10 {
            let page = try await searchData(args)
            let matches = try XCTUnwrap(page["matches"] as? [[String: Any]])
            seen += matches.compactMap { $0["path"] as? String }
            guard page["has_more"] as? Bool == true else { break }
            args["offset"] = try XCTUnwrap(page["next_offset"] as? Int)
        }
        XCTAssertEqual(seen.count, 9)
        XCTAssertEqual(Set(seen).count, 9, "no duplicates across pages: \(seen)")
    }

    // MARK: - Envelope shape

    func testPlain_envelopeHasOkDataMetaKeys() async throws {
        try write("a.swift", content: "target line\n")
        let result = await makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        XCTAssertEqual(env["ok"] as? Bool, true)
        XCTAssertNotNil(env["data"])
        XCTAssertNotNil(env["meta"])
    }

    func testPlain_dataHasQueryMatchesCount() async throws {
        try write("a.swift", content: "target\nbeta\n")
        let result = await makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        let data = env["data"] as? [String: Any]
        XCTAssertEqual(data?["query"] as? String, "target")
        XCTAssertEqual(data?["count"] as? Int, 1)
        let matches = data?["matches"] as? [[String: Any]]
        XCTAssertEqual(matches?.count, 1)
        XCTAssertEqual(matches?.first?["path"] as? String, "a.swift")
        XCTAssertEqual(matches?.first?["line"] as? Int, 1)
        XCTAssertEqual(matches?.first?["text"] as? String, "target")
    }

    func testPlain_metaHasTruncatedFalseWhenWithinLimits() async throws {
        try write("a.swift", content: "target\n")
        let result = await makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        let meta = env["meta"] as? [String: Any]
        XCTAssertEqual(meta?["truncated"] as? Bool, false)
    }

    func testPlain_metaHasTruncatedTrueAtLimit() async throws {
        let lines = (0..<30).map { "target \($0)" }.joined(separator: "\n")
        try write("a.swift", content: lines)
        let result = await makeTool().handle(
            context: ctx(),
            args: ["query": "target", "max_results": 5]
        )
        let env = try parse(result.outputJSON)
        let meta = env["meta"] as? [String: Any]
        XCTAssertEqual(meta?["truncated"] as? Bool, true)
    }

    // MARK: - Optional skipped fields

    func testPlain_skippedKeys_omittedWhenEmpty() async throws {
        try write("a.swift", content: "target\n")
        let result = await makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        let data = env["data"] as? [String: Any]
        XCTAssertNil(data?["skipped_files"],
                     "skipped_files must be omitted when no files were skipped.")
        XCTAssertNil(data?["skipped_binary_count"],
                     "skipped_binary_count must be omitted when zero.")
    }

    /// Many files, one cause, one entry. Every `.doc` in a tree produces the SAME sentence,
    /// so listing them per file spends the model's context restating one fact — the flood
    /// that made binaries an aggregate count one field over.
    func testPlain_skippedFiles_foldedByReasonWithACount() async throws {
        try write("a.swift", content: "target\n")
        for name in ["one.doc", "two.doc", "three.doc"] {
            try write(name, content: "legacy binary content")
        }

        let result = await makeTool().handle(context: ctx(), args: ["query": "target"])
        let env = try parse(result.outputJSON)
        let data = env["data"] as? [String: Any]
        let groups = try XCTUnwrap(data?["skipped_files"] as? [[String: Any]])

        XCTAssertEqual(groups.count, 1, "one cause must yield one entry: \(groups)")
        XCTAssertEqual(groups[0]["count"] as? Int, 3)
        XCTAssertEqual(
            Set((groups[0]["paths"] as? [String]) ?? []),
            ["one.doc", "two.doc", "three.doc"],
            "the sample must name the files so the reader can act on them"
        )
        XCTAssertEqual((groups[0]["reason"] as? String)?.contains("save as .docx"), true)
    }

    /// The sample is capped but the count is not, so "how many" survives a flood even
    /// though "which ones" is abridged. No separate warning is needed: a `count` larger
    /// than `paths` says it.
    func testPlain_skippedFiles_pathsAreSampledWhileCountStaysTrue() async throws {
        try write("a.swift", content: "target\n")
        let total = SkippedFileGroup.pathSampleLimit + 4
        for i in 0..<total {
            try write("legacy\(i).doc", content: "legacy binary content")
        }

        let result = await makeTool().handle(context: ctx(), args: ["query": "target"])
        let env = try parse(result.outputJSON)
        let groups = try XCTUnwrap((env["data"] as? [String: Any])?["skipped_files"] as? [[String: Any]])

        XCTAssertEqual(groups[0]["count"] as? Int, total)
        XCTAssertEqual((groups[0]["paths"] as? [String])?.count, SkippedFileGroup.pathSampleLimit)
    }

    /// Folding only works if the reason names the RULE. An oversize file's reason used to
    /// embed its own byte count, so two large files were two distinct reasons and a folder
    /// of logs flooded exactly as it did unfolded — the fold silently doing nothing.
    func testPlain_oversizeFiles_shareOneReasonDespiteDifferentSizes() async throws {
        try write("a.swift", content: "target\n")
        let over = SearchExecutor.maxSearchableFileBytes + 1
        for (i, name) in ["big1.txt", "big2.txt"].enumerated() {
            try Data(count: over + i).write(to: tempDir.appendingPathComponent(name))
        }

        let result = await makeTool().handle(context: ctx(), args: ["query": "target"])
        let env = try parse(result.outputJSON)
        let groups = try XCTUnwrap((env["data"] as? [String: Any])?["skipped_files"] as? [[String: Any]])

        XCTAssertEqual(groups.count, 1,
                       "differently-sized oversize files must share one reason: \(groups)")
        XCTAssertEqual(groups[0]["count"] as? Int, 2)
    }

    /// A document that WAS searched can still carry a caveat — text salvaged from a
    /// mid-document parse abort, a worksheet that would not unzip, a body cut at the
    /// extraction byte cap. Those reach `meta.warnings`, because a match list that silently
    /// covers part of a file is the same lie as an unreported skip.
    ///
    /// They are deduplicated for the same reason `skipped_files` is folded: the caveat is a
    /// property of the FORMAT, so a folder of them would otherwise repeat one sentence per
    /// file. Two damaged documents here, one warning expected.
    func testPlain_documentWarnings_reachMetaAndAreDeduplicated() async throws {
        // XML that stops mid-`<w:t>`: the collector salvages "target" and reports the abort.
        for name in ["one.docx", "two.docx"] {
            try writeTruncatedDOCX(name)
        }

        let result = await makeTool().handle(context: ctx(), args: ["query": "target"])
        let env = try parse(result.outputJSON)
        let meta = env["meta"] as? [String: Any]
        let warnings = try XCTUnwrap(meta?["warnings"] as? [String])
        let aborts = warnings.filter { $0.contains("XML parse stopped early") }

        XCTAssertEqual(aborts.count, 1,
                       "one caveat per FORMAT, not per file: \(warnings)")
        XCTAssertEqual((env["data"] as? [String: Any])?["count"] as? Int, 2,
                       "both documents were still searched: \(result.outputJSON)")
    }

    /// A DOCX whose `word/document.xml` ends mid-element, so the parse aborts after
    /// collecting real text.
    private func writeTruncatedDOCX(_ name: String) throws {
        let truncatedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>target
        """
        try ZIPArchiveWriter.write(to: tempDir.appendingPathComponent(name), entries: [
            .init(name: "word/document.xml", data: Data(truncatedXML.utf8), method: .deflate)
        ])
    }

    func testPlain_skippedBinaryCount_presentWhenBinary() async throws {
        try write("a.swift", content: "target\n")
        // Add a binary file to trigger the binary counter.
        try Data([0xFF, 0xFE]).write(to: tempDir.appendingPathComponent("blob.bin"))
        let result = await makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        let data = env["data"] as? [String: Any]
        XCTAssertEqual(data?["skipped_binary_count"] as? Int, 1)
    }

    // MARK: - Context fields

    func testPlain_contextFields_omitted_whenZero() async throws {
        try write("a.swift", content: "target\n")
        // Explicit 0/0 — `makeTool()` propagates non-zero AppDefaults so the
        // test must override them to exercise the "context omitted" branch.
        let result = await makeTool().handle(
            context: ctx(),
            args: ["query": "target", "context_before": 0, "context_after": 0]
        )
        let env = try parse(result.outputJSON)
        let matches = env["data"] as? [String: Any]
        let m = (matches?["matches"] as? [[String: Any]])?.first
        XCTAssertNil(m?["context_before"])
        XCTAssertNil(m?["context_after"])
    }

    func testPlain_contextFields_present_whenRequested() async throws {
        try write("a.swift", content: "before\ntarget\nafter\n")
        let result = await makeTool().handle(
            context: ctx(),
            args: ["query": "target", "context_before": 1, "context_after": 1]
        )
        let env = try parse(result.outputJSON)
        let matches = env["data"] as? [String: Any]
        let m = (matches?["matches"] as? [[String: Any]])?.first
        let before = m?["context_before"] as? [[String: Any]]
        let after = m?["context_after"] as? [[String: Any]]
        XCTAssertEqual(before?.count, 1)
        XCTAssertEqual(after?.count, 1)
        XCTAssertEqual(before?.first?["text"] as? String, "before")
        XCTAssertEqual(after?.first?["text"] as? String, "after")
    }

    // MARK: - Multi-file ordering

    func testPlain_multipleFiles_returnedInDirectoryOrder() async throws {
        // Both files match — the walk sorts directory entries, so we get a
        // stable order regardless of FS enumeration quirks.
        try write("aa.swift", content: "target\n")
        try write("bb.swift", content: "target\n")
        try write("cc.swift", content: "target\n")
        let result = await makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        let matches = (env["data"] as? [String: Any])?["matches"] as? [[String: Any]]
        let paths = matches?.compactMap { $0["path"] as? String }
        XCTAssertEqual(paths, ["aa.swift", "bb.swift", "cc.swift"],
                       "Directory walk must remain alphabetically stable.")
    }

    // MARK: - Error behavior

    func testPlain_missingQuery_errorEnvelopeShape() async throws {
        let result = await makeTool().handle(
            context: ctx(), args: [:]
        )
        XCTAssertTrue(result.isError)
        let env = try parse(result.outputJSON)
        XCTAssertEqual(env["ok"] as? Bool, false)
        let err = env["error"] as? [String: Any]
        XCTAssertNotNil(err)
        XCTAssertNotNil(err?["code"])
        XCTAssertNotNil(err?["message"])
    }

    // MARK: - Filename matches envelope shape

    /// Pin the omit-when-empty contract so the LLM-visible envelope stays
    /// compact when there are no name hits — a `"filename_matches": []`
    /// would burn tokens on every plain search that has only content hits.
    func testPlain_filenameMatches_omittedWhenEmpty() async throws {
        try write("a.swift", content: "target line\n")
        let result = await makeTool().handle(
            context: ctx(), args: ["query": "target"]
        )
        let env = try parse(result.outputJSON)
        let data = env["data"] as? [String: Any]
        XCTAssertNil(data?["filename_matches"],
                     "filename_matches must be omitted when no files matched by name.")
    }

    func testPlain_filenameMatches_presentWhenBasenameHits() async throws {
        try write("Sources/SearchExecutor.swift", content: "// no content match\n")
        let result = await makeTool().handle(
            context: ctx(), args: ["query": "SearchExecutor"]
        )
        let env = try parse(result.outputJSON)
        let data = env["data"] as? [String: Any]
        XCTAssertEqual(data?["count"] as? Int, 0,
                       "Query has no content hits — only a filename hit.")
        let names = data?["filename_matches"] as? [[String: Any]]
        XCTAssertEqual(names?.count, 1)
        XCTAssertEqual(names?.first?["path"] as? String, "Sources/SearchExecutor.swift")
        XCTAssertEqual(names?.first?["matched_on"] as? String, "basename")
    }

    func testPlain_filenameMatches_basenameSortsBeforePath() async throws {
        try write("Services/Search/Foo.swift", content: "")
        try write("Domain/Search.swift", content: "")
        let result = await makeTool().handle(
            context: ctx(), args: ["query": "Search"]
        )
        let env = try parse(result.outputJSON)
        let names = (env["data"] as? [String: Any])?["filename_matches"] as? [[String: Any]]
        XCTAssertEqual(names?.first?["path"] as? String, "Domain/Search.swift")
        XCTAssertEqual(names?.first?["matched_on"] as? String, "basename")
    }

    /// Pin the `MatchedOn` enum's wire encoding. The enum is `String`-raw,
    /// but the contract is that it serializes as exactly `"basename"` /
    /// `"path"` — never `"basename"` capitalized, never an int, never a
    /// nested object. A drift here would silently break any LLM-side parser.
    func testPlain_filenameMatches_matchedOn_serializesAsRawLowercaseString() async throws {
        try write("Domain/Search.swift", content: "")
        try write("Services/Search/Foo.swift", content: "")
        let result = await makeTool().handle(
            context: ctx(), args: ["query": "Search"]
        )
        let env = try parse(result.outputJSON)
        let names = (env["data"] as? [String: Any])?["filename_matches"] as? [[String: Any]]
        let onValues = names?.compactMap { $0["matched_on"] as? String } ?? []
        XCTAssertTrue(onValues.contains("basename"))
        XCTAssertTrue(onValues.contains("path"))
        for v in onValues {
            XCTAssertTrue(v == "basename" || v == "path",
                          "matched_on raw value drifted: \(v)")
        }
    }

    /// Pin that filename matches survive content-mode `regex` — filename
    /// matching is scoped to substring/glob semantics independent of
    /// content's regex compile. Useful regression guard against accidental
    /// coupling of the two paths.
    func testPlain_filenameMatches_unaffectedByContentRegexMode() async throws {
        try write("FooBar.swift", content: "no regex match here\n")
        let result = await makeTool().handle(
            context: ctx(),
            args: ["query": "FooBar", "mode": "regex"]
        )
        let env = try parse(result.outputJSON)
        let data = env["data"] as? [String: Any]
        XCTAssertEqual(data?["count"] as? Int, 0)
        let names = data?["filename_matches"] as? [[String: Any]]
        XCTAssertEqual(names?.count, 1)
        XCTAssertEqual(names?.first?["path"] as? String, "FooBar.swift")
    }

    /// Both `matches` and `filename_matches` populated for a query that
    /// hits content AND name — the envelope's two arrays are independent.
    func testPlain_filenameMatches_alongsideContentMatches() async throws {
        try write("Search.swift", content: "// Search\n")
        let result = await makeTool().handle(
            context: ctx(), args: ["query": "Search"]
        )
        let env = try parse(result.outputJSON)
        let data = env["data"] as? [String: Any]
        XCTAssertEqual(data?["count"] as? Int, 1)
        let matches = data?["matches"] as? [[String: Any]]
        XCTAssertEqual(matches?.first?["path"] as? String, "Search.swift")
        let names = data?["filename_matches"] as? [[String: Any]]
        XCTAssertEqual(names?.first?["path"] as? String, "Search.swift",
                       "Same file legitimately appears in both arrays — no dedup between them.")
    }

    /// `file_glob` should narrow filename match candidates the same way it
    /// narrows content scan candidates. Verify via the envelope.
    func testPlain_filenameMatches_respectFileGlob() async throws {
        try write("a.swift", content: "")
        try write("a.md", content: "")
        let result = await makeTool().handle(
            context: ctx(),
            args: ["query": "a.", "file_glob": "*.swift"]
        )
        let env = try parse(result.outputJSON)
        let names = (env["data"] as? [String: Any])?["filename_matches"] as? [[String: Any]]
        let paths = names?.compactMap { $0["path"] as? String } ?? []
        XCTAssertEqual(paths, ["a.swift"],
                       "Filename matches must reflect the same glob-narrowed scope as content matches.")
    }

    /// Pin nil-when-empty semantics under both `count == 0` AND
    /// `filename_matches.isEmpty` — neither field should appear when both
    /// are zero, keeping the envelope minimal.
    func testPlain_emptyEnvelope_omitsBothMatchArrays() async throws {
        try write("README.md", content: "no relevant content\n")
        let result = await makeTool().handle(
            context: ctx(), args: ["query": "nonexistent-token"]
        )
        let env = try parse(result.outputJSON)
        let data = env["data"] as? [String: Any]
        XCTAssertEqual(data?["count"] as? Int, 0)
        XCTAssertNil(data?["filename_matches"],
                     "Empty filename_matches must be omitted to keep envelope compact.")
    }

    /// Internal-dir entries must NEVER reach `filename_matches`. Pin via
    /// envelope — defense-in-depth even though the executor walk filters.
    func testPlain_filenameMatches_internalDirNeverSurfaces() async throws {
        try write(".nanoteams/internal/SecretsHelper.swift", content: "")
        try write("Sources/Helper.swift", content: "")
        let result = await makeTool().handle(
            context: ctx(), args: ["query": "Helper"]
        )
        let env = try parse(result.outputJSON)
        let names = (env["data"] as? [String: Any])?["filename_matches"] as? [[String: Any]]
        let paths = names?.compactMap { $0["path"] as? String } ?? []
        XCTAssertFalse(paths.contains(where: { $0.contains("internal") }),
                       "Internal-dir entries must never appear in filename_matches.")
        XCTAssertTrue(paths.contains("Sources/Helper.swift"))
    }
}
