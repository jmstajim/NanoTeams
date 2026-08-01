import XCTest
@testable import NanoTeams

/// Edge cases for `SearchExecutor` — degenerate inputs, encoding quirks,
/// and boundary budget behavior. Complements the happy-path coverage in
/// `SearchExecutorTests`.
final class SearchExecutorEdgeCasesTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!
    var resolver: SandboxPathResolver!
    let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
        resolver = SandboxPathResolver(workFolderRoot: tempDir, internalDir: internalDir)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        internalDir = nil
        resolver = nil
        try super.tearDownWithError()
    }

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Invalid file_glob → typed throw

    func testInvalidFileGlob_throwsTypedError() throws {
        // Drop a real file so the executor would otherwise return matches for
        // the literal query — proves the throw fires *before* the walk runs
        // and isn't just an artifact of an empty corpus.
        try write("hit.swift", content: "needle")

        XCTAssertThrowsError(
            try SearchExecutor.run(SearchExecutorInput(
                workFolderRoot: tempDir,
                resolver: resolver,
                fileManager: fm,
                queries: ["needle"],
                fileGlob: CompiledGlob._testUncompilableGlobSentinel,
                internalDir: internalDir
            ))
        ) { err in
            // Without the typed throw, the executor would silently filter every
            // candidate to false and return zero matches with no signal. The
            // human Supervisor would just see an empty result.
            guard let searchErr = err as? SearchExecutorError,
                  case .invalidFileGlob(let pattern, _) = searchErr
            else {
                XCTFail("expected SearchExecutorError.invalidFileGlob, got \(err)")
                return
            }
            XCTAssertEqual(pattern, CompiledGlob._testUncompilableGlobSentinel)
            // The thrown error's description is what reaches the envelope's
            // `search_error` field — assert the model sees corrective glob
            // vocabulary, not the raw compile detail.
            XCTAssertEqual(
                searchErr.errorDescription,
                "file_glob '\(CompiledGlob._testUncompilableGlobSentinel)' is not a valid glob (only * is a wildcard)."
            )
        }
    }

    /// The `file_glob` compile failure surfaces to the LLM via the envelope's
    /// `search_error` field (`errorDescription` is that text). It must give
    /// corrective glob vocabulary — matching `list_files`'s `name_glob` message
    /// — instead of leaking the raw NSRegularExpression detail ("did not
    /// compile: …"), which taught weaker models nothing (globs aren't regex to
    /// them) and drove self-correction loops. Playbook §1 (corrective errors).
    func testInvalidFileGlob_errorDescription_isCorrectiveGlobWording() {
        let desc = SearchExecutorError
            .invalidFileGlob(pattern: "[bad", message: "raw regex detail")
            .errorDescription
        XCTAssertEqual(desc, "file_glob '[bad' is not a valid glob (only * is a wildcard).")
        // Corner: neither the regex-leaking phrasing nor the raw compile detail
        // may reach the model.
        XCTAssertFalse(desc?.contains("did not compile") ?? true)
        XCTAssertFalse(desc?.contains("raw regex detail") ?? true)
    }

    // MARK: - Empty input

    func testEmptyFile_noMatches() throws {
        try write("empty.swift", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["anything"], internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 0)
    }

    func testEmptyWorkFolder_noMatches() throws {
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["anything"], internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 0)
        XCTAssertFalse(out.truncated)
        XCTAssertTrue(out.skipped.isEmpty)
    }

    // MARK: - Single-line files (no newlines)

    func testSingleLineNoNewline_stillMatches() throws {
        // No trailing newline.
        let url = tempDir.appendingPathComponent("oneline.swift")
        try "target found here and here".write(to: url, atomically: true, encoding: .utf8)
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"], internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].line, 1)
    }

    // MARK: - Case-insensitive substring across scripts

    func testUnicodeSubstring_substringMode_caseInsensitive() throws {
        try write("a.swift", content: "ПрокРуткА — scroll view")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["прокрутка"], internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
    }

    // MARK: - Regex: invalid pattern surfaces typed throw

    /// Behavior change (was: swallowed via `try?` → 0 matches, no signal).
    /// Now: throws `SearchExecutorError.regexCompileFailed` so the
    /// exploratory-search envelope's `search_error` carries the reason and the
    /// LLM can distinguish "no matches in corpus" from "your pattern is
    /// malformed". `try?` ate this signal silently — the LLM kept retrying
    /// with the same broken pattern.
    func testInvalidRegexPattern_throwsTypedError() throws {
        try write("a.swift", content: "literal text")
        XCTAssertThrowsError(try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["[unbalanced("],
            mode: .regex,
            internalDir: internalDir
        ))) { error in
            guard case SearchExecutorError.regexCompileFailed(let q, _) = error else {
                XCTFail("Expected regexCompileFailed, got \(error)")
                return
            }
            XCTAssertEqual(q, "[unbalanced(",
                "Error must carry the offending pattern verbatim.")
        }
    }

    // MARK: - Non-UTF8 bytes count as binary

    func testNonUTF8_countedAsBinary_notSkippedEntry() throws {
        let url = tempDir.appendingPathComponent("bytes.txt")
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)
        try write("a.swift", content: "hit\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["hit"], internalDir: internalDir
        ))
        // The source file with "hit" is the only match.
        XCTAssertEqual(out.matches.count, 1)
        // Binary counter incremented once for bytes.txt.
        XCTAssertEqual(out.skippedBinaryCount, 1)
        // Per the plan, binaries are NOT listed individually to avoid noise.
        XCTAssertTrue(out.skipped.isEmpty)
    }

    // MARK: - I9: document-extractor failure surfaces in skipped_files

    /// A corrupt document on an extension `DocumentTextExtractor.isSupported`
    /// returns true for (e.g. a fake .docx that isn't actually a zip archive)
    /// must surface via `skipped_files` — NOT silently collapse into the
    /// binary-count aggregate. The LLM needs the path + reason so it can
    /// distinguish "no textual match" from "this file was unreadable".
    func testCorruptDocxFile_surfacesInSkippedFiles() throws {
        let badDocx = tempDir.appendingPathComponent("broken.docx")
        // .docx is supposed to be a ZIP; write random bytes so the
        // extractor fails at the zip-open step.
        try Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: badDocx)
        try write("a.swift", content: "target\n")

        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"], internalDir: internalDir
        ))

        XCTAssertEqual(out.matches.count, 1,
            "The valid source file still matches.")
        XCTAssertTrue(out.skipped.contains(where: { $0.path == "broken.docx" }),
            "Corrupt document must appear in skipped_files with path + reason.")
    }

    // MARK: - .build, node_modules, Pods are all skipped

    func testMultipleSkippedDirs_allHonored() throws {
        try write(".build/x.swift", content: "target\n")
        try write("node_modules/pkg/y.swift", content: "target\n")
        try write("Pods/z.swift", content: "target\n")
        try write("DerivedData/w.swift", content: "target\n")
        try write("vendor/v.swift", content: "target\n")
        try write("third_party/t.swift", content: "target\n")
        try write(".swiftpm/a.swift", content: "target\n")
        try write("src/ok.swift", content: "target\n")

        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"], internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "src/ok.swift")
    }

    // MARK: - constrainToFiles with path outside work folder is ignored

    func testConstrainToFiles_parentTraversal_skipped() throws {
        try write("a.swift", content: "target\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            constrainToFiles: ["../../../etc/hosts", "a.swift"],
            internalDir: internalDir
        ))
        // The traversal path doesn't exist under tempDir → skipped silently.
        // Only a.swift contributes.
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift")
    }

    func testConstrainToFiles_withDirectory_skipsNonRTFD() throws {
        // A real directory in constrainToFiles should be skipped (not scanned).
        let dir = tempDir.appendingPathComponent("mydir")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("a.swift", content: "target\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            constrainToFiles: ["mydir", "a.swift"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift")
    }

    // MARK: - fileGlob edge cases

    func testFileGlob_noMatches_returnsEmpty() throws {
        try write("a.swift", content: "target\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            fileGlob: "*.rust",
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 0)
    }

    /// I10 (updated): when `file_glob` cannot be compiled into a regex, the
    /// executor must surface a typed `SearchExecutorError.invalidFileGlob`
    /// rather than silently fail-close to zero matches. The old behavior
    /// (return zero hits) was indistinguishable from "no files matched the
    /// query", so the LLM concluded the glob was correct and the search
    /// genuinely empty. The new throw lets the caller put the reason in
    /// the result envelope's `search_error` field. See also
    /// `testInvalidFileGlob_throwsTypedError` above for the dedicated assertion.
    func testFileGlob_compileFailure_throwsTypedError() throws {
        try write("a.swift", content: "target\n")
        try write("b.m", content: "target\n")
        XCTAssertThrowsError(
            try SearchExecutor.run(SearchExecutorInput(
                workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
                queries: ["target"],
                fileGlob: CompiledGlob._testUncompilableGlobSentinel,
                internalDir: internalDir
            ))
        ) { err in
            guard let searchErr = err as? SearchExecutorError,
                  case .invalidFileGlob = searchErr
            else {
                XCTFail("expected SearchExecutorError.invalidFileGlob, got \(err)")
                return
            }
        }
    }

    func testFileGlob_withMultipleStars() throws {
        try write("utils/helpers.swift", content: "target\n")
        try write("utils/consts.swift", content: "target\n")
        // "*.swift" matches anything ending in .swift (name only, not path).
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            fileGlob: "*.swift",
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 2)
    }

    // MARK: - Multi-query fairness

    func testMultiQuery_oneQueryHasZeroHits_otherFills() throws {
        try write("a.swift", content: "alpha\nbeta\ngamma\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["alpha", "zzzzz"],  // second query finds nothing
            maxResults: 10,
            internalDir: internalDir
        ))
        // The query with zero hits must not starve the other.
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].text, "alpha")
    }

    func testMultiQuery_zeroTotalHits_returnsEmpty() throws {
        try write("a.swift", content: "alpha\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["zzz", "qqq"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 0)
        XCTAssertFalse(out.truncated)
    }

    // MARK: - Context bounds at file start / end

    func testContextBefore_atFileStart_clamped() throws {
        try write("a.swift", content: "target\nafter1\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            contextBefore: 3,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.first?.context_before?.count, 0)
    }

    func testContextAfter_atFileEnd_clamped() throws {
        try write("a.swift", content: "before1\ntarget")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            contextAfter: 5,
            internalDir: internalDir
        ))
        // After the match we have no more meaningful lines (empty tail after
        // split on newlines may yield a single empty string entry).
        XCTAssertLessThanOrEqual(out.matches.first?.context_after?.count ?? 0, 1)
    }

    // MARK: - Massive line count but small matches

    func testVeryManyLinesButFewMatches_doesNotTruncate() throws {
        let junk = String(repeating: "filler\n", count: 500)
        let body = junk + "target\n" + junk
        try write("a.swift", content: body)
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            maxResults: 20,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertFalse(out.truncated)
    }

    // MARK: - Paths parameter: non-existent directory

    func testPaths_nonexistent_silentlySkipped() throws {
        try write("a.swift", content: "target\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            paths: ["doesnotexist"],
            internalDir: internalDir
        ))
        // Non-existent path → no matches, no crash.
        XCTAssertEqual(out.matches.count, 0)
    }
}
