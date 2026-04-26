import XCTest
@testable import NanoTeams

final class SearchModeTests: XCTestCase {
    func testRaw_regex_yieldsRegex() {
        XCTAssertEqual(SearchMode(raw: "regex"), .regex)
    }

    func testRaw_substring_yieldsSubstring() {
        XCTAssertEqual(SearchMode(raw: "substring"), .substring)
    }

    func testRaw_nil_yieldsSubstring() {
        XCTAssertEqual(SearchMode(raw: nil), .substring)
    }

    func testRaw_unknownString_yieldsSubstring() {
        XCTAssertEqual(SearchMode(raw: "glob"), .substring)
        XCTAssertEqual(SearchMode(raw: "REGEX"), .substring,
            "Case-sensitive — 'REGEX' is not 'regex'. Falls back safely.")
        XCTAssertEqual(SearchMode(raw: ""), .substring)
    }
}

final class SearchExecutorTests: XCTestCase {

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

    // MARK: - Single-query parity

    func testSingleQuery_findsLineAndPosition() throws {
        try write("a.swift", content: "let foo = 1\nlet bar = 2\nlet baz = 3\n")

        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["bar"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift")
        XCTAssertEqual(out.matches[0].line, 2)
        XCTAssertFalse(out.truncated)
    }

    func testSingleQuery_substringCaseInsensitive() throws {
        try write("a.swift", content: "FooBar baseline\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["foobar"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
    }

    func testRegexMode_usesPattern() throws {
        try write("a.swift", content: "hello42\nworld43\nfoo\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["^world\\d+$"],
            mode: .regex,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].text, "world43")
    }

    // MARK: - Multi-query (fan-out / dedup)

    func testMultiQuery_deduplicatesSameLine() throws {
        try write("a.swift", content: "scroll view here\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["scroll", "view"],
            internalDir: internalDir
        ))
        // Same line matches both terms; we only emit once.
        XCTAssertEqual(out.matches.count, 1)
    }

    func testMultiQuery_roundRobinFansOut() throws {
        // Each query is unique, each should land at least one hit in the
        // combined list.
        try write("a.swift", content: "scroll\nview\ncontrol\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["scroll", "view", "control"],
            maxResults: 3,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 3)
        let texts = Set(out.matches.map(\.text))
        XCTAssertEqual(texts, ["scroll", "view", "control"])
    }

    func testMultiQuery_originalQueryFirst() throws {
        try write("a.swift", content: "alpha\nbeta\ngamma\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["beta", "alpha"],
            maxResults: 2,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.first?.text, "beta",
                       "Round-robin must start with the original query.")
    }

    // MARK: - constrainToFiles

    func testConstrainToFiles_iteratesExactSet() throws {
        try write("a.swift", content: "target here\n")
        try write("b.swift", content: "target here\n")
        try write("c.swift", content: "target here\n")

        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            constrainToFiles: ["a.swift", "c.swift"],
            internalDir: internalDir
        ))
        let paths = Set(out.matches.map(\.path))
        XCTAssertEqual(paths, ["a.swift", "c.swift"])
    }

    func testConstrainToFiles_empty_shortCircuits() throws {
        try write("a.swift", content: "target\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            constrainToFiles: [],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 0)
    }

    func testConstrainToFiles_missingFileSkipped() throws {
        try write("a.swift", content: "target\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            constrainToFiles: ["a.swift", "nonexistent.swift"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift")
    }

    // MARK: - Skip internal

    func testInternalDir_neverScanned() throws {
        try write(".nanoteams/internal/search_index.json", content: "target here\n")
        try write("a.swift", content: "target here\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift")
    }

    // MARK: - Skip rules

    func testNodeModulesSkipped() throws {
        try write("node_modules/pkg/x.js", content: "target\n")
        try write("a.swift", content: "target\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift")
    }

    // MARK: - Limits

    func testMaxResults_stopsAtLimit() throws {
        let lines = (0..<50).map { "target line \($0)" }.joined(separator: "\n")
        try write("a.swift", content: lines)
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            maxResults: 5,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 5)
        XCTAssertTrue(out.truncated)
    }

    // MARK: - Skipped/binary tracking

    func testBinaryFileCounted_butNotSurfaced() throws {
        // Write a non-UTF8 binary file with an unknown extension.
        let bytes: [UInt8] = [0xFF, 0xFE, 0xFD, 0x00, 0xAB, 0xCD]
        let url = tempDir.appendingPathComponent("blob.bin")
        try Data(bytes).write(to: url)
        try write("a.swift", content: "target\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertTrue(out.skipped.isEmpty)
        XCTAssertEqual(out.skippedBinaryCount, 1)
    }

    // MARK: - fileGlob

    func testFileGlob_restrictsByExtension() throws {
        try write("a.swift", content: "target\n")
        try write("a.md", content: "target\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            fileGlob: "*.swift",
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift")
    }

    // MARK: - Context

    func testContextBeforeAfter_capturesNeighbors() throws {
        try write("a.swift", content: "before1\nbefore2\ntarget here\nafter1\nafter2\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            contextBefore: 2,
            contextAfter: 2,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].context_before?.count, 2)
        XCTAssertEqual(out.matches[0].context_after?.count, 2)
    }

    // MARK: - Regex compile failure

    /// A malformed regex pattern must throw `SearchExecutorError.regexCompileFailed`
    /// — not silently produce zero matches. Without the typed throw, the LLM
    /// can't tell the difference between "no matches" (corpus answer) and
    /// "your pattern is invalid" (query bug).
    func testRegexMode_unbalancedBracket_throwsRegexCompileFailed() throws {
        try write("a.swift", content: "anything\n")

        XCTAssertThrowsError(try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["[unclosed"],
            mode: .regex,
            internalDir: internalDir
        ))) { error in
            guard case SearchExecutorError.regexCompileFailed(let q, _) = error else {
                XCTFail("Expected regexCompileFailed, got \(error)")
                return
            }
            XCTAssertEqual(q, "[unclosed",
                "Error must carry the offending pattern so the envelope can echo it.")
        }
    }

    func testRegexMode_compileFailure_errorDescriptionReadable() throws {
        try write("a.swift", content: "anything\n")
        do {
            _ = try SearchExecutor.run(SearchExecutorInput(
                workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
                queries: ["[unclosed"],
                mode: .regex,
                internalDir: internalDir
            ))
            XCTFail("Expected throw")
        } catch {
            // Without `LocalizedError` conformance, `localizedDescription`
            // produces "The operation couldn't be completed. (… error 0.)" —
            // unhelpful in the LLM-facing envelope. Pin readability so a
            // future enum-only refactor doesn't regress the surfaced message.
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("[unclosed"),
                "localizedDescription should reference the bad pattern; got: \(desc)")
            XCTAssertTrue(desc.contains("regex"),
                "localizedDescription should classify the failure mode; got: \(desc)")
        }
    }

    // MARK: - Substring mode bypasses regex compilation

    /// Substring mode must NOT compile patterns as regex — `[` is a perfectly
    /// valid substring, and the prior `try?` swallow would have masked any
    /// crossover bug. Pins that the typed throw is gated on `.regex` only.
    func testSubstringMode_bracketCharInQuery_doesNotThrow() throws {
        try write("a.swift", content: "[unclosed bracket\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["[unclosed"],
            mode: .substring,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1, "Substring mode treats brackets as literal chars.")
    }

    // MARK: - Sandbox: explicit internal path rejected

    /// The sandbox enforcement is a security boundary. Calling `search` with
    /// an explicit `paths: [".nanoteams/internal/..."]` argument must NOT
    /// surface internal artifacts — `SandboxPathResolver` rejects internal
    /// paths at resolution time. Regression test for the sandbox bypass
    /// surface.
    func testSandbox_explicitInternalPath_isRejected() throws {
        try write(".nanoteams/internal/secret.txt", content: "target sentinel inside internal\n")
        try write("a.swift", content: "target at root\n")

        // Resolver throws on internal paths; the throw propagates from
        // `SearchExecutor.run`. Whatever error type, the call must fail.
        XCTAssertThrowsError(try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            paths: [".nanoteams/internal"],
            internalDir: internalDir
        ))) { _ in
            // Any error is acceptable — the contract is "does not return
            // matches from internal/", not a specific error type.
        }
    }

    /// Even when no `paths` argument is supplied, a recursive walk must
    /// skip the internal dir. Existing `testInternalDir_neverScanned` covers
    /// this; this test pins the descendant case via a deeper path.
    func testSandbox_internalDir_descendantFilesSkipped() throws {
        try write(".nanoteams/internal/deep/nested/secret.txt", content: "target sentinel\n")
        try write("a.swift", content: "target at root\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift",
            "Internal subtree must not contribute matches at any depth.")
    }

    // MARK: - Filename matches (walk-collected)

    func testFilenameMatches_returnedAlongsideContentMatches() throws {
        try write("Sources/SearchExecutor.swift", content: "let x = 1\n")
        try write("Domain/Role.swift", content: "let y = 2\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["SearchExecutor"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 0,
            "Query doesn't appear in any file's content.")
        XCTAssertEqual(out.filenameMatches.count, 1)
        XCTAssertEqual(out.filenameMatches[0].path, "Sources/SearchExecutor.swift")
        XCTAssertEqual(out.filenameMatches[0].matched_on, .basename)
    }

    func testFilenameMatches_basenameSortsBeforePath() throws {
        try write("Services/Search/Foo.swift", content: "")
        try write("Domain/Search.swift", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["Search"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.first?.path, "Domain/Search.swift",
            "Basename hits must come before path-only hits.")
        XCTAssertEqual(out.filenameMatches.first?.matched_on, .basename)
    }

    func testFilenameMatches_respectInternalDirSkip() throws {
        try write(".nanoteams/internal/SearchSecrets.swift", content: "")
        try write("a.swift", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["Search"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 0,
            "Internal-dir files must not contribute filename matches even when they'd otherwise match.")
    }

    func testFilenameMatches_respectFileGlob() throws {
        // file_glob filters which files we walk for content; the same filter
        // should narrow filename match candidates so the LLM gets one
        // consistent scope.
        try write("a.swift", content: "")
        try write("a.md", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["a."],
            fileGlob: "*.swift",
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.map(\.path), ["a.swift"])
    }

    func testFilenameMatches_emptyWhenNoCandidates() throws {
        try write("foo.swift", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["nothing-will-match-this"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 0)
    }

    func testFilenameMatches_constrainToFiles_iteratesExactSet() throws {
        try write("a.swift", content: "")
        try write("b.swift", content: "")
        try write("c.swift", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [".swift"],
            constrainToFiles: ["a.swift", "c.swift"],
            internalDir: internalDir
        ))
        XCTAssertEqual(Set(out.filenameMatches.map(\.path)), ["a.swift", "c.swift"],
            "Constrained walk only visits the listed files for filename matching too.")
    }

    // MARK: - Filename matches: walk-integration corner cases

    func testFilenameMatches_skipDirectories_neverContributeFiles() throws {
        // `.git` is in `WalkSkipRules.skipped`. Files inside it must not
        // appear in filename matches even if their basename matches.
        try write(".git/objects/SearchExecutor.swift", content: "")
        try write("Sources/SearchExecutor.swift", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["SearchExecutor"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 1)
        XCTAssertEqual(out.filenameMatches[0].path, "Sources/SearchExecutor.swift",
            "WalkSkipRules-blocked subtree must not contribute filename matches.")
    }

    func testFilenameMatches_deeplyNested_pathBranchAttribution() throws {
        // A file deep in the tree where only a parent dir matches the
        // query — ensures `matched_on: .path` fires for nested paths.
        try write("a/b/c/d/Foo.swift", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["b/c"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 1)
        XCTAssertEqual(out.filenameMatches[0].matched_on, .path)
    }

    func testFilenameMatches_pathsParameter_narrowsCandidateSet() throws {
        // The `paths` filter restricts the walk to a subdirectory; filename
        // matches must respect the same scope.
        try write("inside/foo.swift", content: "")
        try write("outside/foo.swift", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["foo"],
            paths: ["inside"],
            internalDir: internalDir
        ))
        let paths = Set(out.filenameMatches.map(\.path))
        XCTAssertTrue(paths.contains(where: { $0.contains("inside/foo.swift") }))
        XCTAssertFalse(paths.contains(where: { $0.contains("outside/foo.swift") }),
            "Files outside the `paths` scope must not contribute filename matches.")
    }

    func testFilenameMatches_multipleQueries_allTermsContribute() throws {
        // Round-robin/dedup at the matcher level: each query term feeds
        // into the same `visitedPaths`, so any file whose name matches
        // ANY query surfaces.
        try write("AuthService.swift", content: "")
        try write("UserManager.swift", content: "")
        try write("Other.swift", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["Auth", "User"],
            internalDir: internalDir
        ))
        XCTAssertEqual(Set(out.filenameMatches.map(\.path)),
                       ["AuthService.swift", "UserManager.swift"])
    }

    func testFilenameMatches_globQueryMatchesByExtension() throws {
        // The query parameter (not file_glob) carries a glob — filename
        // match path detects `*` and switches to glob mode.
        try write("a.swift", content: "")
        try write("b.md", content: "")
        try write("c.swift", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["*.swift"],
            internalDir: internalDir
        ))
        XCTAssertEqual(Set(out.filenameMatches.map(\.path)), ["a.swift", "c.swift"])
    }

    func testFilenameMatches_caseInsensitiveAcrossBasenameCase() throws {
        // The walk preserves filesystem casing. Queries must match
        // regardless of case difference between query and file.
        try write("README.MD", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["readme"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 1)
        XCTAssertEqual(out.filenameMatches[0].matched_on, .basename)
    }

    func testFilenameMatches_dotfileIncluded_notTreatedAsHidden() throws {
        // `.gitignore` is intentionally NOT in `WalkSkipRules.skipped` —
        // the project allows useful dotfiles. Filename match must surface
        // it when queried.
        try write(".gitignore", content: "build/\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["gitignore"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 1)
        XCTAssertEqual(out.filenameMatches[0].path, ".gitignore")
    }

    func testFilenameMatches_constrainToFiles_emptyList_emptyOutput() throws {
        // The `constrainToFiles: []` early-return path returns an empty
        // output. No files were "visited", so no filename matches.
        try write("a.swift", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["a"],
            constrainToFiles: [],
            internalDir: internalDir
        ))
        XCTAssertTrue(out.filenameMatches.isEmpty)
    }

    func testFilenameMatches_regexContentMode_doesNotAffectFilenameMatch() throws {
        // `mode: .regex` controls CONTENT search; filename matching is
        // independent (always substring/glob). Verify a regex-mode query
        // that is also a valid substring still surfaces the file by name.
        try write("FooBar.swift", content: "no content match here\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["FooBar"],
            mode: .regex,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 0,
            "No content matches the regex `FooBar` in this file.")
        XCTAssertEqual(out.filenameMatches.count, 1,
            "Filename match runs in substring mode regardless of content `mode`.")
    }

    func testFilenameMatches_combinedWithContentMatches_bothPresent() throws {
        // A file can legitimately match BOTH on content and on name.
        // The two outputs are independent — no dedup between them.
        try write("Search.swift", content: "Search\n")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["Search"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.filenameMatches.count, 1)
        XCTAssertEqual(out.filenameMatches[0].path, "Search.swift",
            "Same file appearing in both `matches` and `filename_matches` is by design.")
    }

    func testFilenameMatches_pathsTargetingSingleFile_onlyThatFile() throws {
        // When `paths` resolves to a single file (not a dir), the walk
        // searches only that file. Filename matching reflects the same
        // scope — exactly one candidate considered.
        try write("only.swift", content: "")
        try write("other.swift", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [".swift"],
            paths: ["only.swift"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.map(\.path), ["only.swift"],
            "Single-file `paths` argument feeds the file into the filename-match scan, mirroring the dir-walk branch.")
    }

    func testFilenameMatches_emptyQueriesArray_emptyOutput() throws {
        // Empty queries (somehow reached the executor) must produce no
        // filename matches and no content matches, but not crash.
        try write("a.swift", content: "")
        let out = try SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 0)
        XCTAssertEqual(out.matches.count, 0)
    }
}
