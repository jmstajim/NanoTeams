import XCTest
@testable import NanoTeams

/// The file tools decide on REAL paths (#375, review 2026-11-08). They run in the app's own
/// process, outside Seatbelt, and a role's sandboxed `bash` may write a symlink anywhere in the
/// work folder — so a path judged by its spelling let `ln -s ~/.ssh keys` and then
/// `read_file keys/id_ed25519` read what the sandbox denies, and `write_file` through a linked
/// folder write outside the work folder. And a work folder at `~` held the credential stores and
/// the agent token files themselves.
///
/// Every fixture lives under a temporary folder, a fake home included: nothing here touches the
/// real `~`.
final class FileToolsRealPathTests: XCTestCase {
    var base: URL!
    var home: URL!
    var work: URL!
    var outside: URL!

    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = fm.temporaryDirectory.appendingPathComponent("nt-realpath-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        work = base.appendingPathComponent("work", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        for folder in [home!, work!, outside!] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try write("secret", to: outside.appendingPathComponent("secret.txt"))
        try write("project", to: work.appendingPathComponent("README.md"))
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(at: base) }
        base = nil; home = nil; work = nil; outside = nil
        try super.tearDownWithError()
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func resolver(root: URL? = nil) -> SandboxPathResolver {
        SandboxPathResolver(workFolderRoot: root ?? work, internalDir: nil, home: home)
    }

    /// A fake home with a credential store, an agent token file and a pasted Codex config.
    private func populateHome() throws {
        try write("key", to: home.appendingPathComponent(".ssh/id_ed25519"))
        try write("ntm_a4c36525_x\n", to: home.appendingPathComponent(".config/nanoteams/a4c36525.token"))
        try write("skill", to: home.appendingPathComponent(".claude/skills/my-skill/SKILL.md"))
        try write("http_headers = { \"Authorization\" = \"Bearer ntm_a4c36525_x\" }", to: home.appendingPathComponent(".codex/config.toml"))
    }

    private func assertOutside(_ path: String, _ r: SandboxPathResolver? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try (r ?? resolver()).resolveFileURL(relativePath: path), file: file, line: line) {
            guard case SandboxPathError.outsideSandbox = $0 else {
                return XCTFail("expected outsideSandbox for \(path), got \($0)", file: file, line: line)
            }
        }
    }

    private func assertProtectedRoot(
        _ path: String, _ r: SandboxPathResolver,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try r.resolveFileURL(relativePath: path), file: file, line: line) {
            guard case SandboxPathError.protectedWorkFolder = $0 else {
                return XCTFail("expected protectedWorkFolder for \(path), got \($0)", file: file, line: line)
            }
            XCTAssertTrue(
                $0.localizedDescription.contains("credential store"),
                $0.localizedDescription, file: file, line: line)
        }
    }

    private func assertHidden(_ path: String, _ r: SandboxPathResolver, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try r.resolveFileURL(relativePath: path), file: file, line: line) {
            guard case SandboxPathError.restrictedPath = $0 else {
                return XCTFail("expected restrictedPath for \(path), got \($0)", file: file, line: line)
            }
        }
    }

    // MARK: - The resolver, the one seam every file tool shares

    func testALinkOutOfTheWorkFolder_isOutside_forAFolderAFileAndAPathNotYetWritten() throws {
        try fm.createSymbolicLink(at: work.appendingPathComponent("keys"), withDestinationURL: outside)
        try fm.createSymbolicLink(
            at: work.appendingPathComponent("note.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        assertOutside("keys/secret.txt")
        assertOutside("keys")
        assertOutside("note.txt")
        assertOutside("keys/new-file.txt", nil)  // write_file into a linked folder
        XCTAssertNoThrow(try resolver().resolveFileURL(relativePath: "README.md"))
        XCTAssertNoThrow(try resolver().resolveFileURL(relativePath: "brand-new/file.txt"), "a file not written yet, in the work folder")
    }

    /// A link that dangles is followed as written: `write_file` on it would create its target.
    func testADanglingLinkPointingOut_isOutside() throws {
        try fm.createSymbolicLink(
            atPath: work.appendingPathComponent("later.txt").path, withDestinationPath: outside.appendingPathComponent("not-yet.txt").path)
        try fm.createSymbolicLink(atPath: work.appendingPathComponent("rel.txt").path, withDestinationPath: "../outside/not-yet.txt")
        assertOutside("later.txt")
        assertOutside("rel.txt")
    }

    /// Links that stay inside are as before: followed, and named by their own path.
    func testALinkInsideTheWorkFolder_resolvesAsBefore() throws {
        try write("x", to: work.appendingPathComponent("src/real.swift"))
        try fm.createSymbolicLink(at: work.appendingPathComponent("alias"), withDestinationURL: work.appendingPathComponent("src"))
        XCTAssertEqual(
            try resolver().resolveFileURL(relativePath: "alias/real.swift"),
            work.appendingPathComponent("alias/real.swift").standardizedFileURL)
    }

    /// A link cycle ends: the real path of `a -> b -> a` is computed in bounded steps.
    func testALinkCycle_terminates() throws {
        try fm.createSymbolicLink(atPath: work.appendingPathComponent("a").path, withDestinationPath: "b")
        try fm.createSymbolicLink(atPath: work.appendingPathComponent("b").path, withDestinationPath: "a")
        _ = SandboxPathResolver.canonicalPath(work.appendingPathComponent("a/x").path)
        _ = try? resolver().resolveFileURL(relativePath: "a/x")
    }

    /// The work folder IS the home folder: the credential stores and the token locations inside
    /// it answer "File not found", like the internal directory; the rest of it is a project.
    func testAWorkFolderAtHome_hidesItsStoresAndTokens() throws {
        try populateHome()
        try write("dotfile", to: home.appendingPathComponent(".zshrc"))
        let r = resolver(root: home)
        for hidden in [".ssh/id_ed25519", ".ssh", ".config/nanoteams/a4c36525.token", ".codex/config.toml",
                       ".claude/skills/my-skill/SKILL.md"] {
            assertHidden(hidden, r)
        }
        XCTAssertNoThrow(try r.resolveFileURL(relativePath: ".zshrc"))
        // Another case names the same folder on APFS — a file not written yet too.
        assertHidden(".CONFIG/NANOTEAMS/a4c36525.token", r)
        assertHidden(".Config/NanoTeams/not-yet.token", r)
        XCTAssertTrue(r.hiddenRelativePaths.contains(".ssh"), "\(r.hiddenRelativePaths)")
        XCTAssertTrue(r.hiddenRelativePaths.contains(".config/nanoteams"), "\(r.hiddenRelativePaths)")
    }

    /// The work folder inside a client folder — a Claude skill being written: the project is
    /// readable, the token folder beside it is not, through a link either.
    func testAWorkFolderInsideAClientFolder_isAProject_butItsTokenSiblingIsNot() throws {
        try populateHome()
        let skill = home.appendingPathComponent(".claude/skills/my-skill", isDirectory: true)
        let r = resolver(root: skill)
        XCTAssertNoThrow(try r.resolveFileURL(relativePath: "SKILL.md"))
        try fm.createSymbolicLink(at: skill.appendingPathComponent("t"), withDestinationURL: home.appendingPathComponent(".config/nanoteams"))
        assertOutside("t/a4c36525.json", r)
    }

    /// A token location reached through a link from an ordinary work folder: outside, and never
    /// read.
    func testATokenFileThroughALink_isNeverRead() throws {
        try populateHome()
        try fm.createSymbolicLink(at: work.appendingPathComponent("t"), withDestinationURL: home.appendingPathComponent(".config/nanoteams"))
        assertOutside("t/a4c36525.json")
        XCTAssertTrue(resolver().hides(canonicalPath: SandboxPathResolver.canonicalPath(
            home.appendingPathComponent(".config/nanoteams/a4c36525.token").path)))
    }

    /// The work folder IS a client folder (`~/.codex`, holding an API key beside the pasted
    /// token): no path in it is the tools', and the walks find nothing — the profile denies the
    /// same folder to `bash` (`workIsCredentialDir`).
    func testAWorkFolderThatIsAStore_isHiddenWhole() async throws {
        try populateHome()
        try write("API_KEY_VALUE", to: home.appendingPathComponent(".codex/auth.json"))
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        let r = resolver(root: codex)
        XCTAssertTrue(r.hidesRoot)
        assertProtectedRoot("auth.json", r)
        let output = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: codex, resolver: r, fileManager: fm,
            queries: ["API_KEY_VALUE"], maxResults: 10, offset: 0, internalDir: nil))
        XCTAssertTrue(output.matches.isEmpty, "\(output.matches.map(\.path))")
        let indexed = SearchIndexWalker(
            workFolderRoot: codex, internalDir: codex.appendingPathComponent(".nanoteams/internal"), fileManager: fm, home: home
        ).walk().candidates
        XCTAssertTrue(indexed.isEmpty, "\(indexed.map(\.relativePath))")
        let listing = await ListFilesTool(resolver: r, fileManager: fm, internalDir: nil).handle(
            context: ToolExecutionContext(workFolderRoot: codex, taskID: 0, runID: 0, roleID: "r"),
            args: ["path": ".", "depth": 3])
        XCTAssertTrue(listing.isError, "the folder itself answers \"File not found\": \(listing.outputJSON)")
        XCTAssertFalse(listing.outputJSON.contains("auth.json"), listing.outputJSON)
    }

    // MARK: - The walks

    private func listedPaths(root: URL, depth: Int = 3) async throws -> [String] {
        let tool = ListFilesTool(resolver: resolver(root: root), fileManager: fm, internalDir: nil)
        let result = await tool.handle(
            context: ToolExecutionContext(workFolderRoot: root, taskID: 0, runID: 0, roleID: "r"),
            args: ["path": ".", "depth": depth])
        XCTAssertFalse(result.isError, result.outputJSON)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let payload = (object["data"] as? [String: Any]) ?? object
        return ((payload["files"] as? [String]) ?? []) + ((payload["dirs"] as? [String]) ?? [])
    }

    func testListFiles_doesNotFollowALinkOut() async throws {
        try fm.createSymbolicLink(at: work.appendingPathComponent("keys"), withDestinationURL: outside)
        let listed = try await listedPaths(root: work)
        XCTAssertTrue(listed.contains("README.md"), "\(listed)")
        XCTAssertFalse(listed.contains { $0.hasPrefix("keys") }, "\(listed)")
    }

    func testListFiles_atHome_leavesTheStoresAndTokensOut() async throws {
        try populateHome()
        try write("dotfile", to: home.appendingPathComponent(".zshrc"))
        let listed = try await listedPaths(root: home)
        XCTAssertTrue(listed.contains(".zshrc"), "\(listed)")
        for hidden in [".ssh", ".claude", ".codex"] {
            XCTAssertFalse(listed.contains { $0 == hidden || $0.hasPrefix(hidden + "/") }, "\(hidden) listed: \(listed)")
        }
    }

    func testSearch_atHome_neverFindsAToken() async throws {
        try populateHome()
        try write("ntm_ in a note", to: home.appendingPathComponent("notes.txt"))
        let output = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: home, resolver: resolver(root: home), fileManager: fm,
            queries: ["ntm_"], maxResults: 50, offset: 0, internalDir: nil))
        XCTAssertEqual(Set(output.matches.map(\.path)), ["notes.txt"], "\(output.matches.map(\.path))")
    }

    func testSearch_throughALinkToATokenFolder_findsNothingThere() async throws {
        try populateHome()
        try fm.createSymbolicLink(at: work.appendingPathComponent("t"), withDestinationURL: home.appendingPathComponent(".config/nanoteams"))
        let output = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: work, resolver: resolver(), fileManager: fm,
            queries: ["ntm_"], maxResults: 50, offset: 0, internalDir: nil))
        XCTAssertTrue(output.matches.isEmpty, "\(output.matches.map(\.path))")
    }

    /// The vocabulary index never reads a store or a token: a "word" from one would reach any
    /// role's search.
    func testIndexWalk_atHome_leavesTheStoresAndTokensOut() throws {
        try populateHome()
        try write("dotfile", to: home.appendingPathComponent(".zshrc"))
        let internalDir = home.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        let walked = SearchIndexWalker(workFolderRoot: home, internalDir: internalDir, fileManager: fm, home: home)
            .walk().candidates.map(\.relativePath)
        XCTAssertTrue(walked.contains(".zshrc"), "\(walked)")
        XCTAssertFalse(walked.contains { $0.hasPrefix(".ssh") || $0.hasPrefix(".claude") || $0.hasPrefix(".codex") }, "\(walked)")
    }

    /// A link whose target is INSIDE the work folder but does not exist. The containment check
    /// passes — the target's path is legitimately under the root — so the entry reaches the
    /// resolve step, which cannot describe it. Skipping is right; skipping SILENTLY is not,
    /// because a walk that quietly drops entries is indistinguishable from a small tree, and the
    /// index would then look complete while missing files.
    ///
    /// RED: drop the warning (`return nil` alone) → the roster is right and nothing says why.
    func testIndexWalk_aDanglingLinkInsideTheWorkFolder_isSkippedWithAStatedReason() throws {
        try fm.createSymbolicLink(
            at: work.appendingPathComponent("ghost.md"),
            withDestinationURL: work.appendingPathComponent("never-written.md"))

        let walk = SearchIndexWalker(
            workFolderRoot: work,
            internalDir: work.appendingPathComponent(".nanoteams/internal", isDirectory: true),
            fileManager: fm, home: home).walk()
        let walked = walk.candidates.map(\.relativePath)

        XCTAssertTrue(walk.isComplete, "a dangling entry is not a cancelled walk")
        XCTAssertFalse(walked.contains("ghost.md"), "\(walked)")
        XCTAssertTrue(
            walk.warnings.contains { $0.contains("unreadable symlink target") && $0.contains("ghost.md") },
            "the skip must name itself and the entry: \(walk.warnings)")
        // The rest of the tree is untouched — one unreadable entry is not a failed walk.
        XCTAssertTrue(walked.contains("README.md"), "\(walked)")
    }

    // MARK: - End to end, through the registry the app builds

    /// `read_file` and `write_file` through a link a role planted: refused, and nothing written
    /// outside.
    func testReadAndWriteFile_throughAPlantedLink_areRefused() async throws {
        try fm.createSymbolicLink(at: work.appendingPathComponent("keys"), withDestinationURL: outside)
        let paths = NTMSPaths(workFolderRoot: work)
        try fm.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)
        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: work, toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0))
        let context = ToolExecutionContext(workFolderRoot: work, taskID: 0, runID: 0, roleID: "r")
        let read = await runtime.executeAll(
            context: context, toolCalls: [StepToolCall(name: "read_file", argumentsJSON: #"{"path":"keys/secret.txt"}"#)])[0]
        XCTAssertTrue(read.isError, read.outputJSON)
        XCTAssertFalse(read.outputJSON.contains("secret\""), read.outputJSON)
        let written = await runtime.executeAll(
            context: context,
            toolCalls: [StepToolCall(name: "write_file", argumentsJSON: #"{"path":"keys/planted.txt","content":"x"}"#)])[0]
        XCTAssertTrue(written.isError, written.outputJSON)
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("planted.txt").path))
    }

    // MARK: - The internal directory, by the route that named it

    /// `.nanoteams/internal` is skipped by its RELATIVE path (a name chain, compared against the
    /// internal directory's own) — the fast path that predates the real-path rule and still
    /// carries every ordinary walk.
    func testSearchAndIndex_skipTheInternalDirectory() async throws {
        let internalDir = work.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try write("INTERNAL_SECRET", to: internalDir.appendingPathComponent("workfolder.json"))
        try write("INTERNAL_SECRET is quoted here", to: work.appendingPathComponent("notes.txt"))
        let r = SandboxPathResolver(workFolderRoot: work, internalDir: internalDir, home: home)
        let output = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: work, resolver: r, fileManager: fm,
            queries: ["INTERNAL_SECRET"], maxResults: 50, offset: 0, internalDir: internalDir))
        XCTAssertEqual(Set(output.matches.map(\.path)), ["notes.txt"], "\(output.matches.map(\.path))")
        let walked = SearchIndexWalker(
            workFolderRoot: work, internalDir: internalDir, fileManager: fm, home: home
        ).walk().candidates.map(\.relativePath)
        XCTAssertTrue(walked.contains("notes.txt"), "\(walked)")
        XCTAssertFalse(walked.contains { $0.hasPrefix(".nanoteams/internal") }, "\(walked)")

        // ...and named explicitly as a `paths` scope, where the walk starts INSIDE `.nanoteams`
        // and the internal directory is the entry the prefix rule has to refuse.
        let scoped = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: work, resolver: r, fileManager: fm,
            queries: ["INTERNAL_SECRET"], paths: [".nanoteams"], maxResults: 50, offset: 0,
            internalDir: internalDir))
        XCTAssertTrue(scoped.matches.isEmpty, "\(scoped.matches.map { $0.path })")
    }

    // MARK: - A link to an ANCESTOR of a hidden location (#376)

    /// The route that NAMES a file says nothing about where it is. A link to a folder that is
    /// not itself hidden — `~/.config`, right above the token folder — gives everything
    /// under it a fresh name chain, and the relative-path rule the walks used matched none of
    /// them. Named so it sorts BEFORE the real ancestor, which is what let the link win the
    /// walks' cycle guard.
    private func plantAncestorLink() throws -> String {
        try write(
            "ntm_cafe1234_SECOND",
            to: home.appendingPathComponent(".config/nanoteams/cafe1234.token"))
        try fm.createSymbolicLink(
            at: home.appendingPathComponent("AAlink"),
            withDestinationURL: home.appendingPathComponent(".config"))
        return "AAlink/nanoteams/cafe1234.token"
    }

    func testSearch_throughALinkToANonHiddenAncestor_findsNoToken() async throws {
        _ = try plantAncestorLink()
        let output = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: home, resolver: resolver(root: home), fileManager: fm,
            queries: ["ntm_"], maxResults: 50, offset: 0, internalDir: nil))
        XCTAssertTrue(output.matches.isEmpty, "\(output.matches.map(\.path))")
    }

    /// The WALK itself, with no reader beneath it to catch what it enqueued. `search`'s own
    /// descriptor check refuses the bytes either way (defence in depth), which is exactly why
    /// this asserts one layer lower: the walk must not reach the token at all, or its path
    /// would ride `skipped_files`, and the index would hand the bytes to its tokenizer.
    func testGrepWalk_throughALinkToANonHiddenAncestor_neverEnqueuesTheToken() throws {
        _ = try plantAncestorLink()
        let r = resolver(root: home)
        var walker = SearchDirectoryWalker(
            fileManager: fm,
            workFolderRoot: home,
            canonicalRootReal: r.canonicalRoot,
            internalCanonicalReal: nil,
            internalRelPrefix: nil,
            hidden: SearchDirectoryWalker.Hidden(resolver: r),
            compiledGlob: nil,
            listMode: false,
            collectTarget: 10_000,
            roots: [.entry(url: home)])
        var touched: [String] = []
        while let step = walker.next() {
            switch step.event {
            case .candidate(_, let relativePath): touched.append(relativePath)
            case .skip(let skipped): touched.append(skipped.path)
            }
        }
        XCTAssertFalse(touched.contains { $0.contains("cafe1234") }, "\(touched)")
    }

    func testIndexWalk_throughALinkToANonHiddenAncestor_indexesNoToken() throws {
        _ = try plantAncestorLink()
        let walked = SearchIndexWalker(
            workFolderRoot: home, internalDir: home.appendingPathComponent(".nanoteams/internal"),
            fileManager: fm, home: home
        ).walk().candidates.map(\.relativePath)
        XCTAssertFalse(walked.contains { $0.contains("cafe1234") }, "\(walked)")
    }

    func testListFilesAndReadFile_throughALinkToANonHiddenAncestor_areRefused() async throws {
        let path = try plantAncestorLink()
        let listed = try await listedPaths(root: home, depth: 6)
        XCTAssertFalse(listed.contains { $0.contains("cafe1234") }, "\(listed)")
        assertHidden(path, resolver(root: home))
    }

    // MARK: - A store that is a symlink (dotfiles managers)

    /// `~/.ssh -> ~/dotfiles/ssh`, work folder at `~`: the store is hidden under BOTH spellings,
    /// because either may be the one a role names.
    func testASymlinkedStore_isHiddenUnderBothSpellings() async throws {
        try write("key", to: home.appendingPathComponent("dotfiles/ssh/id_ed25519"))
        try fm.createSymbolicLink(
            at: home.appendingPathComponent(".ssh"),
            withDestinationURL: home.appendingPathComponent("dotfiles/ssh"))
        let r = resolver(root: home)
        assertHidden(".ssh/id_ed25519", r)
        assertHidden("dotfiles/ssh/id_ed25519", r)
        let listed = try await listedPaths(root: home, depth: 4)
        XCTAssertFalse(listed.contains { $0.hasPrefix("dotfiles/ssh") || $0.hasPrefix(".ssh") }, "\(listed)")
        let output = try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: home, resolver: r, fileManager: fm,
            queries: ["key"], maxResults: 50, offset: 0, internalDir: nil))
        XCTAssertTrue(output.matches.isEmpty, "\(output.matches.map(\.path))")
    }

    // MARK: - A work folder that IS a client folder says so

    func testAWorkFolderThatIsAClientFolder_saysWhyRatherThanFileNotFound() throws {
        try write("# project", to: home.appendingPathComponent(".claude/CLAUDE.md"))
        let r = resolver(root: home.appendingPathComponent(".claude", isDirectory: true))
        XCTAssertTrue(r.hidesRoot)
        for path in ["CLAUDE.md", ".", "skills/x/SKILL.md"] {
            assertProtectedRoot(path, r)
        }
    }

    // MARK: - A link out of the work folder is NAMED by list_files

    func testListFiles_namesALinkItWouldNotFollow() async throws {
        try fm.createSymbolicLink(at: work.appendingPathComponent("keys"), withDestinationURL: outside)
        let tool = ListFilesTool(resolver: resolver(), fileManager: fm, internalDir: nil)
        let result = await tool.handle(
            context: ToolExecutionContext(workFolderRoot: work, taskID: 0, runID: 0, roleID: "r"),
            args: ["path": ".", "depth": 2])
        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("symlink points outside the work folder"), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("keys"), result.outputJSON)
    }

    /// A hidden location stays silent — a warning would say the token folder is there.
    func testListFiles_saysNothingAboutAHiddenLocation() async throws {
        try populateHome()
        let tool = ListFilesTool(resolver: resolver(root: home), fileManager: fm, internalDir: nil)
        let result = await tool.handle(
            context: ToolExecutionContext(workFolderRoot: home, taskID: 0, runID: 0, roleID: "r"),
            args: ["path": ".", "depth": 2])
        XCTAssertFalse(result.outputJSON.contains("symlink points outside"), result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("nanoteams"), result.outputJSON)
    }

    // MARK: - bash's working_directory is resolved as written

    /// Seatbelt governs where `bash` really goes, and a `cd` in the command reaches the same
    /// place — so the monorepo layout that addresses a sibling checkout through a link works.
    func testWorkingDirectory_throughALinkOut_resolvesWhileFileToolsRefuseIt() throws {
        try fm.createDirectory(at: outside.appendingPathComponent("kit"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: work.appendingPathComponent("Kit2"), withDestinationURL: outside.appendingPathComponent("kit"))
        let r = resolver()
        XCTAssertEqual(
            try r.resolveWorkingDirectoryURL(relativePath: "Kit2").lastPathComponent, "Kit2")
        assertOutside("Kit2/anything.txt")
    }

    /// ...but not into a hidden location: a cwd inside a token folder is refused either way.
    func testWorkingDirectory_insideAHiddenLocation_isRefused() throws {
        try populateHome()
        XCTAssertThrowsError(
            try resolver(root: home).resolveWorkingDirectoryURL(relativePath: ".config/nanoteams")
        ) {
            guard case SandboxPathError.restrictedPath = $0 else {
                return XCTFail("expected restrictedPath, got \($0)")
            }
        }
    }

    // MARK: - The work folder's own agent configurations are read-only

    func testAgentConfiguration_isReadableButNotWritable() async throws {
        try write(#"{"mcpServers":{}}"#, to: work.appendingPathComponent(".mcp.json"))
        try write("{}", to: work.appendingPathComponent(".claude/settings.json"))
        let paths = NTMSPaths(workFolderRoot: work)
        try fm.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)
        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: work, toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0))
        let context = ToolExecutionContext(workFolderRoot: work, taskID: 0, runID: 0, roleID: "r")

        let read = await runtime.executeAll(
            context: context, toolCalls: [StepToolCall(name: "read_file", argumentsJSON: #"{"path":".mcp.json"}"#)])[0]
        XCTAssertFalse(read.isError, "reading an agent configuration stays allowed: \(read.outputJSON)")

        for path in [".mcp.json", ".claude/settings.json", ".vscode/mcp.json"] {
            let written = await runtime.executeAll(
                context: context,
                toolCalls: [StepToolCall(
                    name: "write_file",
                    argumentsJSON: "{\"path\":\"\(path)\",\"content\":\"{\\\"x\\\":1}\"}")])[0]
            XCTAssertTrue(written.isError, "\(path) must not be writable: \(written.outputJSON)")
            XCTAssertTrue(written.outputJSON.contains("configures a coding agent"), written.outputJSON)
        }
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent(".mcp.json"), encoding: .utf8),
                       #"{"mcpServers":{}}"#)

        let edited = await runtime.executeAll(
            context: context,
            toolCalls: [StepToolCall(
                name: "edit_file",
                argumentsJSON: #"{"path":".mcp.json","old_text":"mcpServers","new_text":"x"}"#)])[0]
        XCTAssertTrue(edited.isError, edited.outputJSON)
        let deleted = await runtime.executeAll(
            context: context,
            toolCalls: [StepToolCall(name: "delete_file", argumentsJSON: #"{"path":".mcp.json"}"#)])[0]
        XCTAssertTrue(deleted.isError, deleted.outputJSON)
        XCTAssertTrue(fm.fileExists(atPath: work.appendingPathComponent(".mcp.json").path))
    }
}
