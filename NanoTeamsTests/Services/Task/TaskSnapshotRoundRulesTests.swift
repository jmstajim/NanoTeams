import XCTest
@testable import NanoTeams

/// What `task_changes` sees of a round when ignore rules move during it (F6, 2026-11-12).
///
/// The rules of a round are the rules at its START: a `.gitignore` the reviewed role writes
/// cannot hide its own files, a file that becomes ignored mid-round is not reported deleted
/// with its old content (N18), and a rule the role removes does not expose what the person
/// ignored. Every case here writes the files AFTER the start snapshot — a diff of two
/// identical trees is empty under any rule, which is how the parity tests this file
/// replaces passed on any code (N11).
final class TaskSnapshotRoundRulesTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var service: TaskSnapshotService!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("TaskSnapshotRoundRulesTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Hermetic: the developer's own ~/.gitconfig excludes file stays out of every case.
        service = TaskSnapshotService(globalExcludesFile: nil)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        service = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func write(_ text: String, _ relative: String, in folder: URL? = nil) throws {
        let url = (folder ?? tempDir).appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func changes(
        in folder: URL? = nil, taskID: Int = 1, round: Int = 1, filePath: String? = nil
    ) async throws -> TaskSnapshotService.TaskChangesResult {
        try await service.diffChanges(
            workFolder: folder ?? tempDir, folderID: "f", taskID: taskID, runID: 1, round: round,
            page: 1, pageSize: 100, filePath: filePath
        )
    }

    private func snapshot(
        _ phase: TaskSnapshotService.SnapshotPhase, in folder: URL? = nil, taskID: Int = 1, round: Int = 1
    ) async throws {
        try await service.takeSnapshot(
            workFolder: folder ?? tempDir, taskID: taskID, runID: 1, round: round, phase: phase)
    }

    // MARK: - missed: a role's own ignore rules do not hide its files

    func testRoleWrittenGitignore_hidingItselfAndANewFile_allThreeVisible_reviewSnapshot() async throws {
        try write("seed\n", "seed.txt")
        try await snapshot(.start)

        try write("hidden.txt\n.gitignore\n", ".gitignore")
        try write("visible\n", "visible.txt")
        try write("hidden\n", "hidden.txt")
        try await snapshot(.review)

        let result = try await changes()
        XCTAssertEqual(
            Set(result.files.map(\.path)), [".gitignore", "visible.txt", "hidden.txt"],
            "rules written during the round must not hide the round's files")
        XCTAssertTrue(result.files.allSatisfy { $0.change_type == "added" })
    }

    func testRoleWrittenGitignore_liveDiffWithoutEndSnapshot_showsAllThree() async throws {
        try write("seed\n", "seed.txt")
        try await snapshot(.start)

        try write("hidden.txt\n.gitignore\n", ".gitignore")
        try write("visible\n", "visible.txt")
        try write("hidden\n", "hidden.txt")

        let result = try await changes()
        XCTAssertEqual(Set(result.files.map(\.path)), [".gitignore", "visible.txt", "hidden.txt"])
        let diff = result.diff
        XCTAssertTrue(diff.contains("+hidden"), "the hidden file's content is in the diff: \(diff)")
    }

    /// `src/` existed at the start, so the snapshot opens it and its files read as they changed;
    /// `src/deeper/` is new in the round and is one `not_tracked` entry, unread
    /// (`TaskSnapshotRoundHiddenCostTests` says why).
    func testRoleIgnoresAWholeDirectory_itsFilesStayVisible_butStartIgnoredSubtreeStaysHidden() async throws {
        try write("node_modules/\n", ".gitignore")
        try write("a\n", "src/a.txt")
        try write("dep\n", "src/node_modules/dep.js")
        try await snapshot(.start)

        try write("node_modules/\nsrc/\n", ".gitignore")
        try write("a changed\n", "src/a.txt")
        try write("b\n", "src/deeper/b.txt")
        try write("dep changed\n", "src/node_modules/dep.js")
        try await snapshot(.review)

        let result = try await changes()
        let byPath = Dictionary(uniqueKeysWithValues: result.files.map { ($0.path, $0.change_type) })
        XCTAssertEqual(byPath["src/a.txt"], "modified")
        XCTAssertNil(byPath["src/deeper/b.txt"], "a directory new in the round is not read")
        XCTAssertEqual(byPath[".gitignore"], "modified")
        XCTAssertNil(byPath["src/node_modules/dep.js"], "ignored at the start of the round, ignored now")
        XCTAssertEqual(result.not_tracked, [.init(path: "src/deeper/", reason: "hidden_by_round_rules")],
                       "src/node_modules/ was ignored at the start and is not listed")
    }

    func testRoleWrittenGitInfoExclude_inAFolderWithoutGit_doesNotHideItsFile() async throws {
        try write("seed\n", "seed.txt")
        try await snapshot(.start)

        try write("secret.txt\n", ".git/info/exclude")
        try write("secret\n", "secret.txt")
        try await snapshot(.review)

        let result = try await changes()
        XCTAssertTrue(result.files.map(\.path).contains("secret.txt"), "\(result.files)")
    }

    func testRoleRemovesARule_thePersonsIgnoredFileStaysHidden() async throws {
        try write("*.log\n", ".gitignore")
        try write("old log\n", "debug.log")
        try await snapshot(.start)

        try write("", ".gitignore")
        try write("new log\n", "debug.log")
        try write("x\n", "fresh.log")
        try await snapshot(.review)

        let result = try await changes()
        XCTAssertEqual(result.files.map(\.path), [".gitignore"], "\(result.files)")
    }

    func testNextRound_takesTheRulesTheRoundBeforeWrote() async throws {
        try write("seed\n", "seed.txt")
        try await snapshot(.start, round: 1)
        try write("hidden.txt\n", ".gitignore")
        try write("hidden 1\n", "hidden.txt")
        try await snapshot(.revision, round: 1)

        try await snapshot(.start, round: 2)
        try write("hidden 2\n", "hidden.txt")
        try write("v\n", "visible.txt")
        try await snapshot(.review, round: 2)

        let round1 = try await changes(round: 1)
        XCTAssertEqual(Set(round1.files.map(\.path)), [".gitignore", "hidden.txt"])
        let round2 = try await changes(round: 2)
        XCTAssertEqual(round2.files.map(\.path), ["visible.txt"], "round 2 starts under the new rule")
    }

    func testRulesUnchanged_ordinaryIgnoreStillApplies() async throws {
        try write("*.tmp\n", ".gitignore")
        try await snapshot(.start)
        try write("t\n", "scratch.tmp")
        try write("k\n", "kept.txt")
        try await snapshot(.review)

        let result = try await changes()
        XCTAssertEqual(result.files.map(\.path), ["kept.txt"])
    }

    // MARK: - missed: corner cases

    func testHiddenFileThatCannotBeStaged_isReportedNotTrackedWithItsReason() async throws {
        try write("seed\n", "seed.txt")
        try await snapshot(.start)
        try write("locked.txt\n", ".gitignore")
        try write("locked\n", "locked.txt")
        let locked = tempDir.appendingPathComponent("locked.txt")
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let live = try await changes()
        XCTAssertEqual(live.files.map(\.path), [".gitignore"])
        XCTAssertEqual(live.not_tracked, [.init(path: "locked.txt", reason: "hidden_by_round_rules")])

        try await snapshot(.review)
        let ended = try await changes()
        XCTAssertEqual(ended.not_tracked, [.init(path: "locked.txt", reason: "hidden_by_round_rules")],
                       "the end snapshot keeps what it could not show")
    }

    func testRoundWithoutRecordedRules_fallsBackToTheRulesOnDisk() async throws {
        try write("seed\n", "seed.txt")
        try await snapshot(.start)
        let gitDir = NTMSPaths(workFolderRoot: tempDir).snapshotsGitDir
        let ref = SnapshotIgnoreRules.refName(taskID: 1, runID: 1, round: 1)
        XCTAssertTrue(try ProcessRunner.runGit(["--git-dir=\(gitDir.path)", "update-ref", "-d", ref], in: tempDir).success)

        try write("hidden.txt\n", ".gitignore")
        try write("h\n", "hidden.txt")
        try await snapshot(.review)
        let paths = try await changes().files.map(\.path)
        XCTAssertEqual(paths, [".gitignore"], "a round recorded before rules were kept reads as it always did")
    }

    func testCleanupTask_deletesTheRoundRulesToo() async throws {
        try await snapshot(.start)
        let gitDir = NTMSPaths(workFolderRoot: tempDir).snapshotsGitDir
        let listing = { try ProcessRunner.runGit(
            ["--git-dir=\(gitDir.path)", "for-each-ref", "--format=%(refname)", "refs/nanoteams-rules/"],
            in: self.tempDir).stdout }
        XCTAssertEqual(try listing().trimmingCharacters(in: .whitespacesAndNewlines), "refs/nanoteams-rules/1/1/1")
        let refs = try await service.listTaskRefs(workFolder: tempDir, taskID: 1)
        XCTAssertEqual(refs, ["refs/nanoteams/1/1/1/start"], "the rules are not a phase")

        try await service.cleanupTask(workFolder: tempDir, taskID: 1)
        XCTAssertEqual(try listing(), "")
    }

    func testSymlinkedGitignore_isNotARule() async throws {
        try write("target.txt\n", "elsewhere/rules")
        try fileManager.createSymbolicLink(
            atPath: tempDir.appendingPathComponent(".gitignore").path, withDestinationPath: "elsewhere/rules")
        let scan = await service.scanWorkTree(in: tempDir)
        XCTAssertEqual(scan.ignoreFiles, [], "git does not follow a symlinked .gitignore")
    }

    func testUnquotedGitPath_readsGitsCQuoting() {
        func unquote(_ text: String) -> String { TaskSnapshotService.unquotedGitPath(Data(text.utf8)) }
        XCTAssertEqual(unquote("plain/path.txt"), "plain/path.txt")
        XCTAssertEqual(unquote(#""a\"b""#), #"a"b"#)
        XCTAssertEqual(unquote(#""n\nl\tt\\b""#), "n\nl\tt\\b")
        XCTAssertEqual(unquote(#""\320\226.txt""#), "Ж.txt", "octal bytes decode as UTF-8")
        XCTAssertEqual(unquote(#""\a\b\v\f\r""#), "\u{07}\u{08}\u{0B}\u{0C}\r")
        XCTAssertEqual(unquote(#"""#), #"""#, "a lone quote is not a quoted path")
    }

    /// The reader of every `-z` listing. git terminates each record with NUL and writes no empty
    /// one; the reader still keeps an empty record where two NULs meet, so positions stay aligned
    /// (`diff --name-status -z` pairs status and path by position), and does not lose a last
    /// record that arrives without its NUL.
    func testParseNullDelimitedTokens_keepsEmptyRecords_andAnUnterminatedLastOne() async {
        func parse(_ bytes: [UInt8]) async -> [String] {
            await service.parseNullDelimitedTokens(data: Data(bytes))
        }
        let nul: UInt8 = 0
        let a = Array("M".utf8), b = Array("Ж.txt".utf8)
        let both = await parse(a + [nul] + b + [nul])
        XCTAssertEqual(both, ["M", "Ж.txt"])
        let emptyInside = await parse(a + [nul, nul] + b + [nul])
        XCTAssertEqual(emptyInside, ["M", "", "Ж.txt"])
        let leadingNul = await parse([nul] + a + [nul])
        XCTAssertEqual(leadingNul, ["", "M"])
        let unterminated = await parse(a + [nul] + b)
        XCTAssertEqual(unterminated, ["M", "Ж.txt"])
        let none = await parse([])
        XCTAssertEqual(none, [])
    }

    func testArgumentBatches_cutUnderTheLimit_andKeepEveryPath() {
        let paths = (0..<10).map { "p\($0)" }
        let batches = TaskSnapshotService.argumentBatches(paths, maxBytes: 12)
        XCTAssertEqual(batches.flatMap { $0 }, paths)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 2 })
        XCTAssertEqual(TaskSnapshotService.argumentBatches([]), [])
        XCTAssertEqual(TaskSnapshotService.argumentBatches(["very-long-single"], maxBytes: 4), [["very-long-single"]])
    }

    func testNotShownTrailer_emptyListWritesNothing() {
        XCTAssertNil(TaskSnapshotService.notShownTrailerLine([]))
        XCTAssertTrue(TaskSnapshotService.notShownTrailerLine(["a"])?.hasPrefix("Not-Shown: ") == true)
    }

    // MARK: - N18: a file that becomes ignored mid-round is not "deleted"

    func testTrackedFileIgnoredMidRound_andModified_isReportedModifiedNotDeleted() async throws {
        try write("{ \"env\": \"dev\" }\n", "config.json")
        try await snapshot(.start)

        try write("config.json\n", ".gitignore")
        try write("{ \"env\": \"prod\" }\n", "config.json")
        try await snapshot(.review)

        let result = try await changes()
        let config = try XCTUnwrap(result.files.first { $0.path == "config.json" }, "\(result.files)")
        XCTAssertEqual(config.change_type, "modified")
        XCTAssertFalse(result.files.contains { $0.change_type == "deleted" })
    }

    func testTrackedFileIgnoredMidRound_unchanged_isNotReportedAtAll() async throws {
        try write("secret=1\n", ".env")
        try await snapshot(.start)

        try write(".env\n", ".gitignore")
        let live = try await changes()
        XCTAssertEqual(live.files.map(\.path), [".gitignore"], "live: \(live.files)")
        XCTAssertFalse(live.diff.contains("secret=1"), "the ignored file's content must not print")

        try await snapshot(.review)
        let ended = try await changes()
        XCTAssertEqual(ended.files.map(\.path), [".gitignore"], "review: \(ended.files)")
    }

    // MARK: - N11: exclusion parity, files written after the start

    func testExclusionParity_gitInfoExclude_filesCreatedAfterTheStart() async throws {
        XCTAssertTrue(try ProcessRunner.runGit(["init", "-q"], in: tempDir).success)
        try write("worktrees_custom/\n*.secret\n", ".git/info/exclude")
        try await snapshot(.start)

        try write("hello\n", "normal.txt")
        try write("secret123\n", "key.secret")
        try write("ignored tree\n", "worktrees_custom/tree.txt")
        try await snapshot(.review)

        let paths = try await changes().files.map(\.path)
        XCTAssertEqual(paths, ["normal.txt"], "info/exclude must hide key.secret and worktrees_custom/")
    }

    func testExclusionParity_trackedFileIgnoredBetweenRounds_isClearedFromTheIndex() async throws {
        try write("{ \"env\": \"dev\" }\n", "config.json")
        try await snapshot(.start, round: 1)
        try await snapshot(.review, round: 1)

        try write("config.json\n", ".gitignore")
        try await snapshot(.start, round: 2)
        try write("{ \"env\": \"production\" }\n", "config.json")
        try write("x\n", "other.txt")
        try await snapshot(.review, round: 2)

        let paths = try await changes(round: 2).files.map(\.path)
        XCTAssertEqual(paths, ["other.txt"], "config.json is ignored for the whole of round 2")
    }

    func testExclusionParity_globalExcludesFile_isApplied_andOnlyWhenGiven() async throws {
        let globalFile = tempDir.appendingPathComponent("global-ignore-\(UUID().uuidString)")
        try "*.envsecret\n".write(to: globalFile, atomically: true, encoding: .utf8)
        let work = tempDir.appendingPathComponent("work", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)

        service = TaskSnapshotService(globalExcludesFile: globalFile.path)
        try await snapshot(.start, in: work)
        try write("k=v\n", "app.envsecret", in: work)
        try write("n\n", "normal.txt", in: work)
        try await snapshot(.review, in: work)
        let given = try await changes(in: work).files.map(\.path)
        XCTAssertEqual(given, ["normal.txt"])

        // Anti-vacuum: the same folder without the global file shows the file.
        let bare = tempDir.appendingPathComponent("bare", isDirectory: true)
        try fileManager.createDirectory(at: bare, withIntermediateDirectories: true)
        service = TaskSnapshotService(globalExcludesFile: nil)
        try await snapshot(.start, in: bare)
        try write("k=v\n", "app.envsecret", in: bare)
        try await snapshot(.review, in: bare)
        let absent = try await changes(in: bare).files.map(\.path)
        XCTAssertEqual(absent, ["app.envsecret"])
    }

    func testUsersOwnRepository_isNotTouchedBySnapshots() async throws {
        XCTAssertTrue(try ProcessRunner.runGit(["init", "-q"], in: tempDir).success)
        try write("tracked\n", "tracked.txt")
        _ = try ProcessRunner.runGit(["add", "tracked.txt"], in: tempDir)
        _ = try ProcessRunner.runGit(
            ["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], in: tempDir)
        try write("changed\n", "tracked.txt")
        try write("u\n", "untracked.txt")

        let index = tempDir.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: index)
        let headBefore = try ProcessRunner.runGit(["rev-parse", "HEAD"], in: tempDir).stdout
        // `.nanoteams/` is the app's own folder (its `.gitignore` is written by the repository
        // layout, not by snapshots); what must not move is everything else.
        func status() throws -> String {
            try ProcessRunner.runGit(["status", "--porcelain"], in: tempDir).stdout
                .split(separator: "\n").filter { !$0.contains(".nanoteams") }.joined(separator: "\n")
        }
        let statusBefore = try status()

        try await snapshot(.start)
        try write("more\n", "more.txt")
        _ = try await changes()
        try await snapshot(.review)
        _ = try await changes()
        try? fileManager.removeItem(at: tempDir.appendingPathComponent("more.txt"))

        XCTAssertEqual(try Data(contentsOf: index), indexBefore, "the person's index must not change")
        XCTAssertEqual(try ProcessRunner.runGit(["rev-parse", "HEAD"], in: tempDir).stdout, headBefore)
        XCTAssertEqual(try status(), statusBefore)
    }

    /// A role whose new rules ignore an embedded repository does not turn that repository into
    /// an entry of the round: restoring the start's rules lists what the disk rules hide with the
    /// embedded repositories excluded, as `add -A` stages around them, so `sub` stays one
    /// `embedded_repository` entry — not a directory "new in the round" hidden by the round's rules.
    func testRoleIgnoresAnEmbeddedRepository_itStaysAnEmbeddedRepository() async throws {
        let sub = tempDir.appendingPathComponent("sub", isDirectory: true)
        try fileManager.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertTrue(try ProcessRunner.runGit(["init", "-q"], in: sub).success)
        try write("s\n", "sub/inner.txt")
        try write("a\n", "a.txt")
        try await snapshot(.start)

        try write("sub/\nnew.txt\n", ".gitignore")
        try write("a changed\n", "a.txt")
        try write("n\n", "new.txt")
        try await snapshot(.review)

        let result = try await changes()
        XCTAssertEqual(Set(result.files.map(\.path)), [".gitignore", "a.txt", "new.txt"],
                       "anti-vacuum: the round's rules were restored — new.txt is visible")
        XCTAssertEqual(result.not_tracked, [.init(path: "sub", reason: "embedded_repository")])
    }

    /// A Swift package after its first build: `.build/` is in `.gitignore`, and SwiftPM's
    /// checkouts under it are git clones. RED before 2026-11-12: the exclude of the embedded
    /// repository named an ignored path, `add -A` refused it, and no snapshot of the folder
    /// could be taken — the start failed with "Snapshot add failed".
    func testEmbeddedRepositoryInsideAnIgnoredDirectory_doesNotFailTheSnapshot() async throws {
        let checkout = tempDir.appendingPathComponent(".build/checkouts/dep", isDirectory: true)
        try fileManager.createDirectory(at: checkout, withIntermediateDirectories: true)
        XCTAssertTrue(try ProcessRunner.runGit(["init", "-q"], in: checkout).success)
        try write("d\n", ".build/checkouts/dep/Package.swift")
        try write(".build/\n", ".gitignore")
        try write("a\n", "a.txt")
        try await snapshot(.start)

        try write("a changed\n", "a.txt")
        try await snapshot(.review)

        let result = try await changes()
        XCTAssertEqual(result.files.map(\.path), ["a.txt"])
        XCTAssertFalse(result.files.contains { $0.path.hasPrefix(".build/") }, "ignored, and not staged")
    }

    func testGlobCharactersInAName_nextToAnEmbeddedRepositoryWithoutCommit_areLiteral() async throws {
        let sub = tempDir.appendingPathComponent("sub", isDirectory: true)
        try fileManager.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertTrue(try ProcessRunner.runGit(["init", "-q"], in: sub).success)
        try write("a\n", "[x].txt")
        try write("b\n", "x.txt")
        try await snapshot(.start)

        try write("a changed\n", "[x].txt")
        try write("s\n", "sub/inner.txt")
        try await snapshot(.review)

        let result = try await changes()
        XCTAssertEqual(result.files.map(\.path), ["[x].txt"], "x.txt is unchanged; sub/ is not tracked")
        XCTAssertEqual(result.not_tracked.map(\.path), ["sub"])
        XCTAssertEqual(result.not_tracked.map(\.reason), ["embedded_repository"])

        let filtered = try await changes(filePath: "[x].txt")
        XCTAssertEqual(filtered.files.map(\.path), ["[x].txt"])
        XCTAssertTrue(filtered.diff.contains("+a changed"))
        XCTAssertFalse(filtered.diff.contains("x.txt\n+b"), "a glob must not pull x.txt into the page")
    }

    func testRunWrittenBeforeRoundsExisted_decodesToRoundOne() throws {
        let json = #"{"id":0,"createdAt":"2026-01-01T00:00:00Z"}"#
        let run = try JSONCoderFactory.makeDateDecoder().decode(Run.self, from: Data(json.utf8))
        XCTAssertEqual(run.round, 1)
        XCTAssertEqual(run.roundStartedAt, run.createdAt)
        XCTAssertTrue(run.snapshotFailures.isEmpty)
    }

    // MARK: - N19: a work folder inside a repository applies that repository's rules

    func testWorkFolderInsideARepository_appliesTheEnclosingRules() async throws {
        let repo = tempDir.appendingPathComponent("repo", isDirectory: true)
        let app = repo.appendingPathComponent("app", isDirectory: true)
        try fileManager.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertTrue(try ProcessRunner.runGit(["init", "-q"], in: repo).success)
        try write("node_modules/\n.env\n/app/build/\n/other/\n", ".gitignore", in: repo)
        try write("*.tmp\n", ".git/info/exclude", in: repo)
        try await snapshot(.start, in: app)

        try write("x\n", "node_modules/x.js", in: app)
        try write("k=v\n", ".env", in: app)
        try write("o\n", "build/out.o", in: app)
        try write("t\n", "notes.tmp", in: app)
        try write("o\n", "other/kept.txt", in: app)
        try write("m\n", "src/main.swift", in: app)
        try await snapshot(.review, in: app)

        let paths = Set(try await changes(in: app).files.map(\.path))

        XCTAssertEqual(paths, ["src/main.swift", "other/kept.txt"],
                       "/other/ is anchored at the repository root, not at app/")
    }

    func testEnclosingRepositoryThatIgnoresEverything_doesNotBlankTheFolder() async throws {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let work = home.appendingPathComponent("projects/app", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        XCTAssertTrue(try ProcessRunner.runGit(["init", "-q"], in: home).success)
        try write("*\n!.zshrc\n*.log\n", ".gitignore", in: home)
        try await snapshot(.start, in: work)

        try write("m\n", "main.swift", in: work)
        try write("l\n", "debug.log", in: work)
        try await snapshot(.review, in: work)

        let paths = try await changes(in: work).files.map(\.path)
        XCTAssertEqual(paths, ["main.swift"], "`*` names the whole folder and is not applied; `*.log` is")
    }

    // MARK: - T1: relative paths are cut by components, not bytes

    func testCyrillicWorkFolder_embeddedRepository_keepsItsFullRelativePath() async throws {
        let work = tempDir.appendingPathComponent("Проекты/app", isDirectory: true)
        let vendored = work.appendingPathComponent("vendor/lib", isDirectory: true)
        try fileManager.createDirectory(at: vendored, withIntermediateDirectories: true)
        XCTAssertTrue(try ProcessRunner.runGit(["init", "-q"], in: vendored).success)
        try write("v\n", "vendor/lib/x.txt", in: work)
        try write("o\n", "lib/other.txt", in: work)

        let discovered = await service.discoverEmbeddedRepositories(in: work)
        XCTAssertEqual(discovered, ["vendor/lib"])

        try await snapshot(.start, in: work)
        try write("v changed\n", "vendor/lib/x.txt", in: work)
        try write("o changed\n", "lib/other.txt", in: work)

        let live = try await changes(in: work)
        XCTAssertEqual(live.files.map(\.path), ["lib/other.txt"], "lib/ is not the embedded repository")
        XCTAssertEqual(live.not_tracked.map(\.path), ["vendor/lib"])

        try await snapshot(.review, in: work)
        let ended = try await changes(in: work)
        XCTAssertEqual(ended.files.map(\.path), ["lib/other.txt"])
    }

    func testDiscoverEmbeddedRepositories_workFolderItselfIsNeverItsOwnEmbeddedRepository() async throws {
        let work = tempDir.appendingPathComponent("Ж", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        XCTAssertTrue(try ProcessRunner.runGit(["init", "-q"], in: work).success)
        let nested = work.appendingPathComponent("a/b", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertTrue(try ProcessRunner.runGit(["init", "-q"], in: nested).success)

        let discovered = await service.discoverEmbeddedRepositories(in: work)
        XCTAssertEqual(discovered, ["a/b"], "no empty and no single-component path")
    }
}
