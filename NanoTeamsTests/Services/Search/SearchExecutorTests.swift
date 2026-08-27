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

    func testSingleQuery_findsLineAndPosition() async throws {
        try write("a.swift", content: "let foo = 1\nlet bar = 2\nlet baz = 3\n")

        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["bar"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift")
        XCTAssertEqual(out.matches[0].line, 2)
        XCTAssertFalse(out.truncated)
    }

    func testSingleQuery_substringCaseInsensitive() async throws {
        try write("a.swift", content: "FooBar baseline\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["foobar"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
    }

    func testRegexMode_usesPattern() async throws {
        try write("a.swift", content: "hello42\nworld43\nfoo\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["^world\\d+$"],
            mode: .regex,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].text, "world43")
    }

    // MARK: - Multi-query (fan-out / dedup)

    func testMultiQuery_deduplicatesSameLine() async throws {
        try write("a.swift", content: "scroll view here\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["scroll", "view"],
            internalDir: internalDir
        ))
        // Same line matches both terms; we only emit once.
        XCTAssertEqual(out.matches.count, 1)
    }

    func testMultiQuery_roundRobinFansOut() async throws {
        // Each query is unique, each should land at least one hit in the
        // combined list.
        try write("a.swift", content: "scroll\nview\ncontrol\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["scroll", "view", "control"],
            maxResults: 3,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 3)
        let texts = Set(out.matches.map(\.text))
        XCTAssertEqual(texts, ["scroll", "view", "control"])
    }

    func testMultiQuery_originalQueryFirst() async throws {
        try write("a.swift", content: "alpha\nbeta\ngamma\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["beta", "alpha"],
            maxResults: 2,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.first?.text, "beta",
                       "Round-robin must start with the original query.")
    }

    // MARK: - constrainToFiles

    func testConstrainToFiles_iteratesExactSet() async throws {
        try write("a.swift", content: "target here\n")
        try write("b.swift", content: "target here\n")
        try write("c.swift", content: "target here\n")

        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            constrainToFiles: ["a.swift", "c.swift"],
            internalDir: internalDir
        ))
        let paths = Set(out.matches.map(\.path))
        XCTAssertEqual(paths, ["a.swift", "c.swift"])
    }

    func testConstrainToFiles_empty_shortCircuits() async throws {
        try write("a.swift", content: "target\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            constrainToFiles: [],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 0)
    }

    func testConstrainToFiles_missingFileSkipped() async throws {
        try write("a.swift", content: "target\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            constrainToFiles: ["a.swift", "nonexistent.swift"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift")
    }

    // MARK: - Skip internal

    func testInternalDir_neverScanned() async throws {
        try write(".nanoteams/internal/search_index.json", content: "target here\n")
        try write("a.swift", content: "target here\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift")
    }

    // MARK: - Skip rules

    func testNodeModulesSkipped() async throws {
        try write("node_modules/pkg/x.js", content: "target\n")
        try write("a.swift", content: "target\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift")
    }

    // MARK: - Limits

    func testMaxResults_stopsAtLimit() async throws {
        let lines = (0..<50).map { "target line \($0)" }.joined(separator: "\n")
        try write("a.swift", content: lines)
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            maxResults: 5,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 5)
        XCTAssertTrue(out.truncated)
    }

    // MARK: - Skipped/binary tracking

    func testBinaryFileCounted_butNotSurfaced() async throws {
        // Write a non-UTF8 binary file with an unknown extension.
        let bytes: [UInt8] = [0xFF, 0xFE, 0xFD, 0x00, 0xAB, 0xCD]
        let url = tempDir.appendingPathComponent("blob.bin")
        try Data(bytes).write(to: url)
        try write("a.swift", content: "target\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertTrue(out.skipped.isEmpty)
        XCTAssertEqual(out.skippedBinaryCount, 1)
    }

    // MARK: - fileGlob

    func testFileGlob_restrictsByExtension() async throws {
        try write("a.swift", content: "target\n")
        try write("a.md", content: "target\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            fileGlob: "*.swift",
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift")
    }

    // MARK: - Context

    func testContextBeforeAfter_capturesNeighbors() async throws {
        try write("a.swift", content: "before1\nbefore2\ntarget here\nafter1\nafter2\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
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
    func testRegexMode_unbalancedBracket_throwsRegexCompileFailed() async throws {
        try write("a.swift", content: "anything\n")

        await XCTAssertThrowsErrorAsync(try await SearchExecutor.run(SearchExecutorInput(
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

    func testRegexMode_compileFailure_errorDescriptionReadable() async throws {
        try write("a.swift", content: "anything\n")
        do {
            _ = try await SearchExecutor.run(SearchExecutorInput(
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
    func testSubstringMode_bracketCharInQuery_doesNotThrow() async throws {
        try write("a.swift", content: "[unclosed bracket\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
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
    func testSandbox_explicitInternalPath_isRejected() async throws {
        try write(".nanoteams/internal/secret.txt", content: "target sentinel inside internal\n")
        try write("a.swift", content: "target at root\n")

        // Resolver throws on internal paths; the throw propagates from
        // `SearchExecutor.run`. Whatever error type, the call must fail.
        await XCTAssertThrowsErrorAsync(try await SearchExecutor.run(SearchExecutorInput(
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
    func testSandbox_internalDir_descendantFilesSkipped() async throws {
        try write(".nanoteams/internal/deep/nested/secret.txt", content: "target sentinel\n")
        try write("a.swift", content: "target at root\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["target"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches[0].path, "a.swift",
                       "Internal subtree must not contribute matches at any depth.")
    }

    // MARK: - Filename matches (walk-collected)

    func testFilenameMatches_returnedAlongsideContentMatches() async throws {
        try write("Sources/SearchExecutor.swift", content: "let x = 1\n")
        try write("Domain/Role.swift", content: "let y = 2\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
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

    func testFilenameMatches_basenameSortsBeforePath() async throws {
        try write("Services/Search/Foo.swift", content: "")
        try write("Domain/Search.swift", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["Search"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.first?.path, "Domain/Search.swift",
                       "Basename hits must come before path-only hits.")
        XCTAssertEqual(out.filenameMatches.first?.matched_on, .basename)
    }

    func testFilenameMatches_respectInternalDirSkip() async throws {
        try write(".nanoteams/internal/SearchSecrets.swift", content: "")
        try write("a.swift", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["Search"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 0,
                       "Internal-dir files must not contribute filename matches even when they'd otherwise match.")
    }

    func testFilenameMatches_respectFileGlob() async throws {
        // file_glob filters which files we walk for content; the same filter
        // should narrow filename match candidates so the LLM gets one
        // consistent scope.
        try write("a.swift", content: "")
        try write("a.md", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["a."],
            fileGlob: "*.swift",
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.map(\.path), ["a.swift"])
    }

    func testFilenameMatches_emptyWhenNoCandidates() async throws {
        try write("foo.swift", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["nothing-will-match-this"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 0)
    }

    func testFilenameMatches_constrainToFiles_iteratesExactSet() async throws {
        try write("a.swift", content: "")
        try write("b.swift", content: "")
        try write("c.swift", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [".swift"],
            constrainToFiles: ["a.swift", "c.swift"],
            internalDir: internalDir
        ))
        XCTAssertEqual(Set(out.filenameMatches.map(\.path)), ["a.swift", "c.swift"],
                       "Constrained walk only visits the listed files for filename matching too.")
    }

    // MARK: - Filename matches: walk-integration corner cases

    func testFilenameMatches_skipDirectories_neverContributeFiles() async throws {
        // `.git` is in `WalkSkipRules.skipped`. Files inside it must not
        // appear in filename matches even if their basename matches.
        try write(".git/objects/SearchExecutor.swift", content: "")
        try write("Sources/SearchExecutor.swift", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["SearchExecutor"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 1)
        XCTAssertEqual(out.filenameMatches[0].path, "Sources/SearchExecutor.swift",
                       "WalkSkipRules-blocked subtree must not contribute filename matches.")
    }

    func testFilenameMatches_deeplyNested_pathBranchAttribution() async throws {
        // A file deep in the tree where only a parent dir matches the
        // query — ensures `matched_on: .path` fires for nested paths.
        try write("a/b/c/d/Foo.swift", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["b/c"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 1)
        XCTAssertEqual(out.filenameMatches[0].matched_on, .path)
    }

    func testFilenameMatches_pathsParameter_narrowsCandidateSet() async throws {
        // The `paths` filter restricts the walk to a subdirectory; filename
        // matches must respect the same scope.
        try write("inside/foo.swift", content: "")
        try write("outside/foo.swift", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
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

    func testFilenameMatches_multipleQueries_allTermsContribute() async throws {
        // Round-robin/dedup at the matcher level: each query term feeds
        // into the same `visitedPaths`, so any file whose name matches
        // ANY query surfaces.
        try write("AuthService.swift", content: "")
        try write("UserManager.swift", content: "")
        try write("Other.swift", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["Auth", "User"],
            internalDir: internalDir
        ))
        XCTAssertEqual(Set(out.filenameMatches.map(\.path)),
                       ["AuthService.swift", "UserManager.swift"])
    }

    func testFilenameMatches_globQueryMatchesByExtension() async throws {
        // The query parameter (not file_glob) carries a glob — filename
        // match path detects `*` and switches to glob mode.
        try write("a.swift", content: "")
        try write("b.md", content: "")
        try write("c.swift", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["*.swift"],
            internalDir: internalDir
        ))
        XCTAssertEqual(Set(out.filenameMatches.map(\.path)), ["a.swift", "c.swift"])
    }

    func testFilenameMatches_caseInsensitiveAcrossBasenameCase() async throws {
        // The walk preserves filesystem casing. Queries must match
        // regardless of case difference between query and file.
        try write("README.MD", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["readme"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 1)
        XCTAssertEqual(out.filenameMatches[0].matched_on, .basename)
    }

    func testFilenameMatches_dotfileIncluded_notTreatedAsHidden() async throws {
        // `.gitignore` is intentionally NOT in `WalkSkipRules.skipped` —
        // the project allows useful dotfiles. Filename match must surface
        // it when queried.
        try write(".gitignore", content: "build/\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["gitignore"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 1)
        XCTAssertEqual(out.filenameMatches[0].path, ".gitignore")
    }

    func testFilenameMatches_constrainToFiles_emptyList_emptyOutput() async throws {
        // The `constrainToFiles: []` early-return path returns an empty
        // output. No files were "visited", so no filename matches.
        try write("a.swift", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["a"],
            constrainToFiles: [],
            internalDir: internalDir
        ))
        XCTAssertTrue(out.filenameMatches.isEmpty)
    }

    func testFilenameMatches_regexContentMode_doesNotAffectFilenameMatch() async throws {
        // `mode: .regex` controls CONTENT search; filename matching is
        // independent (always substring/glob). Verify a regex-mode query
        // that is also a valid substring still surfaces the file by name.
        try write("FooBar.swift", content: "no content match here\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
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

    func testFilenameMatches_combinedWithContentMatches_bothPresent() async throws {
        // A file can legitimately match BOTH on content and on name.
        // The two outputs are independent — no dedup between them.
        try write("Search.swift", content: "Search\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["Search"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.filenameMatches.count, 1)
        XCTAssertEqual(out.filenameMatches[0].path, "Search.swift",
                       "Same file appearing in both `matches` and `filename_matches` is by design.")
    }

    func testFilenameMatches_pathsTargetingSingleFile_onlyThatFile() async throws {
        // When `paths` resolves to a single file (not a dir), the walk
        // searches only that file. Filename matching reflects the same
        // scope — exactly one candidate considered.
        try write("only.swift", content: "")
        try write("other.swift", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [".swift"],
            paths: ["only.swift"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.map(\.path), ["only.swift"],
                       "Single-file `paths` argument feeds the file into the filename-match scan, mirroring the dir-walk branch.")
    }

    func testFilenameMatches_emptyQueriesArray_emptyOutput() async throws {
        // Empty queries (somehow reached the executor) must produce no
        // filename matches and no content matches, but not crash.
        try write("a.swift", content: "")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 0)
        XCTAssertEqual(out.matches.count, 0)
    }

    // MARK: - Chunked UTF-8 reader invariants

    /// Single line longer than the 1-MiB chunk threshold. A buggy chunked
    /// accumulator could lose the suffix or produce a "split" line.
    func testStreaming_singleLineLongerThanChunkSize_stillFindsMatchAtEnd() async throws {
        // 1.5 MiB > the 1 MiB chunk size. Pad the start with ASCII so a
        // greedy implementation would emit a "match" inside the pad, not on
        // the terminal query — we want to prove the suffix actually reaches
        // the scanner.
        let padCount = (3 * 1024 * 1024) / 2  // 1.5 MiB of 'a'
        let padding = String(repeating: "a", count: padCount)
        let query = "NEEDLE_MARKER_AT_END"
        try write("huge.txt", content: padding + query + "\n")

        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [query],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1, "Streaming reader must surface a query at the end of a >1MB single line")
        XCTAssertEqual(out.matches.first?.path, "huge.txt")
        XCTAssertTrue(out.matches.first?.text.contains(query) == true)
    }

    /// Forces a multi-byte UTF-8 character (4 bytes: 𝄞 U+1D11E) to straddle
    /// the 1-MB chunk boundary. A per-chunk decode would corrupt this; the
    /// accumulate-then-decode design avoids the issue. This test pins the
    /// guarantee so a future "optimize" to per-chunk decode would fail loudly.
    func testStreaming_multibyteUTF8AtChunkBoundary_decodesCorrectly() async throws {
        // Aim to land the 4-byte char so its FIRST byte is at offset
        // (1_048_576 - 2) and the last byte is at offset (1_048_576 + 1) —
        // straddling the 1-MiB boundary. Three pad-bytes (each ASCII, 1-byte)
        // bring us up to offset (1_048_576 - 2); then the 4-byte char.
        let oneMiB = 1 << 20
        let padCount = oneMiB - 2
        let padding = String(repeating: "x", count: padCount)
        let musicalSymbolGClef = "\u{1D11E}"  // 4 bytes in UTF-8
        let trailer = "AFTER_MULTIBYTE_BOUNDARY"
        try write("utf8.txt", content: padding + musicalSymbolGClef + trailer + "\n")

        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [trailer],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertTrue(out.matches.first?.text.contains(musicalSymbolGClef) == true,
                      "Multi-byte UTF-8 char straddling the chunk boundary must survive intact")
        XCTAssertTrue(out.matches.first?.text.contains(trailer) == true)
    }

    /// Non-UTF-8 input still surfaces as a "binary file" via `skippedBinaryCount`
    /// — the streaming-reader rewrite preserves the prior classification, so a
    /// `.bin` blob mixed in with text files doesn't pollute `skipped_files`.
    func testStreaming_nonUTF8Input_classifiedAsBinaryNotSkipped() async throws {
        // Build a file whose first byte is 0xFF — invalid UTF-8 start byte —
        // and whose extension is NOT in the document-extractor set, so the
        // text-streaming path handles it.
        let binURL = tempDir.appendingPathComponent("blob.bin")
        var bytes = Data([0xFF, 0xFE, 0xFD, 0xFC])
        bytes.append(contentsOf: Array(repeating: UInt8(0x00), count: 64))
        try bytes.write(to: binURL)

        // Also write a normal text file so the walk finds a candidate.
        try write("a.txt", content: "NEEDLE in text file\n")

        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["NEEDLE"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1, "The text file's match must still be found")
        XCTAssertEqual(out.matches.first?.path, "a.txt")
        XCTAssertGreaterThanOrEqual(out.skippedBinaryCount, 1,
                                    "The non-UTF-8 file must be counted as binary, not surfaced in skipped_files")
        XCTAssertFalse(
            out.skipped.contains(where: { $0.path == "blob.bin" }),
            "Binary files go into the aggregate count, NOT skipped_files — preserving the prior contract."
        )
    }

    /// Mid-walk cancellation: a pre-cancelled `Task` running
    /// `SearchExecutor.run` over a corpus must bail without burning the rest
    /// of the tree. Pins the `Task.isCancelled` checks at the top of
    /// `searchFile` and inside `searchDirectory`'s loop — a regression that
    /// drops either would silently let a paused search grep the whole project.
    func testStreaming_cancelledTask_shortCircuitsWalk() async throws {
        for i in 0..<32 {
            try write("file_\(i).txt", content: "NEEDLE in file \(i)\n")
        }
        // Per CLAUDE.md Swift 6 notes: tests must NOT pass `self.fm` (or any
        // non-Sendable XCTestCase property) into a `sending` parameter — use
        // `FileManager.default` directly. The tempDir / resolver / internalDir
        // get pulled into locals before the detached closure to satisfy the
        // region-based isolation checker.
        let tempDirRef = tempDir!
        let resolverRef = resolver!
        let internalDirRef = internalDir!
        let task = Task.detached { () throws -> SearchExecutorOutput in
            try await SearchExecutor.run(SearchExecutorInput(
                workFolderRoot: tempDirRef, resolver: resolverRef, fileManager: .default,
                queries: ["NEEDLE"],
                maxResults: 1000,
                internalDir: internalDirRef
            ))
        }
        task.cancel()
        let out = try await task.value
        // The first file may match before the cancel check fires; everything
        // after the first cancel-check tick must short-circuit. 32 files of
        // NEEDLE on an uncancelled run would produce 32 matches.
        XCTAssertLessThan(out.matches.count, 32,
                          "Cancelled walk must short-circuit; got all \(out.matches.count) matches as if not cancelled.")
    }

    /// Unterminated last line must remain matchable. Defends against a
    /// future "yield per line during read" optimization that might drop the
    /// tail.
    func testStreaming_fileWithoutTrailingNewline_matchesLastLine() async throws {
        try write("notail.txt", content: "first line\nNEEDLE in last line without newline")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["NEEDLE"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 1)
        XCTAssertEqual(out.matches.first?.line, 2,
                       "The unterminated last line must be reachable as line 2.")
    }

    // MARK: - List mode (empty query enumerates files)

    func testListMode_emptyQueryWithGlob_listsAllMatchingFiles() async throws {
        try write("scenes/Player.gd", content: "extends Node\n")
        try write("enemies/Slime.gd", content: "extends KinematicBody2D\n")
        try write("readme.md", content: "docs\n")

        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [""],
            fileGlob: "*.gd",
            internalDir: internalDir
        ))
        // No content matches on an empty query...
        XCTAssertTrue(out.matches.isEmpty)
        // ...but every .gd file is listed, and the .md is excluded.
        XCTAssertEqual(out.filenameMatches.map(\.path), ["enemies/Slime.gd", "scenes/Player.gd"])
        XCTAssertTrue(out.filenameMatches.allSatisfy { $0.matched_on == .basename })
    }

    func testListMode_whitespaceOnlyQuery_alsoListsMode() async throws {
        try write("a.gd", content: "x\n")
        try write("b.gd", content: "y\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["  \n"],
            fileGlob: "*.gd",
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.map(\.path), ["a.gd", "b.gd"])
    }

    func testListMode_emptyQueryWithPaths_listsFilesInScope() async throws {
        try write("src/a.txt", content: "x\n")
        try write("src/b.txt", content: "y\n")
        try write("other/c.txt", content: "z\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [""],
            paths: ["src"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.map(\.path), ["src/a.txt", "src/b.txt"])
    }

    func testListMode_doesNotReadFileContent() async throws {
        // A binary file matching the glob would be counted in `skippedBinaryCount`
        // if content were read. In list mode we never open it — so the counter
        // stays 0, proving `searchFile` was skipped.
        let bytes: [UInt8] = [0xFF, 0xFE, 0xFD, 0x00, 0xAB, 0xCD]
        try Data(bytes).write(to: tempDir.appendingPathComponent("blob.gd"))
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [""],
            fileGlob: "*.gd",
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.map(\.path), ["blob.gd"])
        XCTAssertEqual(out.skippedBinaryCount, 0,
                       "List mode must not open file content — the binary is listed, never read.")
        XCTAssertTrue(out.skipped.isEmpty)
    }

    func testListMode_rosterCappedAtMaxResults_marksTruncated() async throws {
        for i in 0..<5 { try write("f\(i).gd", content: "x\n") }
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [""],
            fileGlob: "*.gd",
            maxResults: 3,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 3)
        XCTAssertTrue(out.truncated, "Hitting the roster cap must mark the result truncated.")
    }

    func testListMode_overlappingPaths_dedupeRoster_noPrematureStop() async throws {
        // Overlapping paths must not double-count files against the roster cap.
        // `src/utils` has a,b,c; `src` also directly has zzz1,zzz2. With
        // maxResults=5 the deduped roster must be 5 DISTINCT files — not stop
        // early after re-counting a,b,c when `src` re-walks into `utils`.
        try write("src/utils/a.txt", content: "x\n")
        try write("src/utils/b.txt", content: "x\n")
        try write("src/utils/c.txt", content: "x\n")
        try write("src/zzz1.txt", content: "x\n")
        try write("src/zzz2.txt", content: "x\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [""],
            paths: ["src/utils", "src"],
            maxResults: 5,
            internalDir: internalDir
        ))
        let paths = Set(out.filenameMatches.map(\.path))
        XCTAssertEqual(out.filenameMatches.count, 5,
                       "Roster must hold 5 DISTINCT files, not stop early on duplicate appends.")
        XCTAssertEqual(out.filenameMatches.count, paths.count, "No duplicate entries in the roster.")
        XCTAssertTrue(paths.isSuperset(of: ["src/zzz1.txt", "src/zzz2.txt"]),
                      "Files reachable only via the second path must not be dropped by duplicate inflation.")
    }

    func testListMode_singleFilePathEntry_respectsFileGlob() async throws {
        // A single-file `paths` entry must be filtered by file_glob, just like
        // files found in a directory walk — a non-matching named file must not
        // slip into the roster past the filter.
        try write("notes.txt", content: "x\n")
        try write("scene.gd", content: "x\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [""],
            paths: ["notes.txt", "scene.gd"],
            fileGlob: "*.gd",
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.map(\.path), ["scene.gd"],
                       "file_glob must exclude the non-matching single-file path entry.")
    }

    func testContentSearch_singleFilePathEntry_filenameMatchSurvivesBudgetExhaustion() async throws {
        // A directory path that exhausts the content-match budget must not drop
        // the filename match of a co-listed single-file `paths` entry (explicit
        // files stay visible for name matching even once the budget is full).
        try write("bigdir/hits.txt", content: "needle\nneedle\nneedle\n")
        try write("target_needle.txt", content: "unrelated\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: ["needle"],
            paths: ["bigdir", "target_needle.txt"],
            maxResults: 3,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.matches.count, 3, "bigdir should fill the content-match budget")
        XCTAssertTrue(out.filenameMatches.contains { $0.path == "target_needle.txt" },
                      "An explicitly-named file's filename match must survive a budget-exhausting sibling path.")
    }

    func testListMode_duplicatePathEntries_countedOnce() async throws {
        try write("a.txt", content: "x\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [""],
            paths: ["a.txt", "a.txt", "a.txt"],
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.map(\.path), ["a.txt"],
                       "A repeated single-file path entry must appear once, not thrice.")
    }

    func testListMode_emptyQueriesArray_isNotListMode_evenWithGlob() async throws {
        // Distinct from `queries: [""]`: an EMPTY ARRAY (no terms) must not
        // enumerate — `[].allSatisfy` is vacuously true, so without the
        // `!isEmpty` guard this would wrongly list every .gd file.
        try write("a.gd", content: "x\n")
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [],
            fileGlob: "*.gd",
            internalDir: internalDir
        ))
        XCTAssertTrue(out.matches.isEmpty)
        XCTAssertTrue(out.filenameMatches.isEmpty,
                      "An empty queries ARRAY is a no-op search, not list mode.")
    }

    func testListMode_exactlyMaxResults_notTruncated() async throws {
        // Exactly maxResults matching files and no more → `truncated` MUST be
        // false (nothing was dropped). A naive `count >= maxResults` check
        // reports a false positive here and tells the LLM to keep narrowing a
        // search that already returned everything.
        for i in 0..<3 { try write("f\(i).gd", content: "x\n") }
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [""],
            fileGlob: "*.gd",
            maxResults: 3,
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.count, 3)
        XCTAssertFalse(out.truncated,
                       "Exactly maxResults files with none dropped must not be marked truncated.")
    }

    func testListMode_respectsInternalDirSkip() async throws {
        try write("a.gd", content: "x\n")
        // A .gd inside the internal dir must never be listed.
        let internalGd = internalDir.appendingPathComponent("secret.gd")
        try "hidden\n".write(to: internalGd, atomically: true, encoding: .utf8)
        let out = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir, resolver: resolver, fileManager: fm,
            queries: [""],
            fileGlob: "*.gd",
            internalDir: internalDir
        ))
        XCTAssertEqual(out.filenameMatches.map(\.path), ["a.gd"])
    }
}
