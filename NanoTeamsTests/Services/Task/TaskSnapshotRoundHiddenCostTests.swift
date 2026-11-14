import XCTest
@testable import NanoTeams

/// What a snapshot pays for files that only rules WRITTEN DURING the round hide (F6 «missed»,
/// review of 2026-11-12).
///
/// The round's start rules keep a role from hiding its own files (`TaskSnapshotRoundRulesTests`),
/// and until this change that meant `add -f` of everything the moved rules hid. The ordinary
/// «create a project» round — no `.gitignore` at the start, then one with `node_modules/` and an
/// `npm install` — forced tens of thousands of files into the private repository and onto the
/// `task_changes` pages. Now a DIRECTORY new in the round that such a rule hides is one
/// `not_tracked` entry and is never read; single FILES are still shown, up to a per-snapshot
/// limit (`TaskSnapshotService.RoundHiddenStagingLimit`); what the round's start tree held is
/// always restored, so nothing reads as deleted (N18).
final class TaskSnapshotRoundHiddenCostTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var service: TaskSnapshotService!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("TaskSnapshotRoundHiddenCostTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
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

    private func write(_ text: String, _ relative: String) throws {
        let url = tempDir.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeBytes(_ count: Int, _ relative: String) throws {
        let url = tempDir.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: count).write(to: url)
    }

    private func changes() async throws -> TaskSnapshotService.TaskChangesResult {
        try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 1, runID: 1, round: 1,
            page: 1, pageSize: 100, filePath: nil)
    }

    private func snapshot(_ phase: TaskSnapshotService.SnapshotPhase) async throws {
        try await service.takeSnapshot(workFolder: tempDir, taskID: 1, runID: 1, round: 1, phase: phase)
    }

    private var gitDir: URL { NTMSPaths(workFolderRoot: tempDir).snapshotsGitDir }

    /// Every path the private repository holds at `ref` (an end snapshot's commit).
    private func storedPaths(_ ref: String) throws -> [String] {
        let res = try ProcessRunner.runGit(
            ["--git-dir=\(gitDir.path)", "ls-tree", "-r", "--name-only", ref], in: tempDir)
        XCTAssertTrue(res.success, res.stderr)
        return res.stdout.split(separator: "\n").map(String.init)
    }

    /// Every path the private INDEX holds — what the live diff staged.
    private func indexedPaths() throws -> [String] {
        let res = try ProcessRunner.runGit(
            ["--git-dir=\(gitDir.path)", "--work-tree=\(tempDir.path)", "ls-files"], in: tempDir)
        XCTAssertTrue(res.success, res.stderr)
        return res.stdout.split(separator: "\n").map(String.init)
    }

    private func hidden(_ path: String) -> TaskSnapshotService.NotTrackedPath {
        .init(path: path, reason: TaskSnapshotService.NotTrackedPath.hiddenByRoundRules)
    }

    private func writeNodeModulesRound() throws {
        try write("node_modules/\n", ".gitignore")
        try write("b\n", "node_modules/a/b.js")
        try write("c\n", "node_modules/c.js")
        try write("v\n", "visible.txt")
    }

    // MARK: - A directory new in the round is one entry, never read

    func testNewDirectoryHiddenByARoundRule_endSnapshot_isOneNotTrackedEntry_andIsNotStored() async throws {
        try write("seed\n", "seed.txt")
        try await snapshot(.start)
        try writeNodeModulesRound()
        try await snapshot(.review)

        let result = try await changes()
        XCTAssertEqual(Set(result.files.map(\.path)), [".gitignore", "visible.txt"], "\(result.files)")
        XCTAssertEqual(result.not_tracked, [hidden("node_modules/")])
        let stored = try storedPaths("refs/nanoteams/1/1/1/review")
        XCTAssertFalse(stored.contains { $0.hasPrefix("node_modules/") }, "\(stored)")
    }

    func testNewDirectoryHiddenByARoundRule_liveDiff_isOneNotTrackedEntry_andIsNotStaged() async throws {
        try write("seed\n", "seed.txt")
        try await snapshot(.start)
        try writeNodeModulesRound()

        let result = try await changes()
        XCTAssertEqual(Set(result.files.map(\.path)), [".gitignore", "visible.txt"], "\(result.files)")
        XCTAssertEqual(result.not_tracked, [hidden("node_modules/")])
        let indexed = try indexedPaths()
        XCTAssertFalse(indexed.contains { $0.hasPrefix("node_modules/") }, "\(indexed)")
    }

    func testNewDirectoryNestedInAVisibleOne_isOneEntryAtItsOwnPath() async throws {
        try write("keep\n", "src/keep.txt")
        try await snapshot(.start)
        try write("gen/\n", ".gitignore")
        try write("x\n", "src/gen/x.swift")
        try write("z\n", "src/gen/y/z.swift")
        try write("m\n", "src/main.swift")
        try await snapshot(.review)

        let result = try await changes()
        XCTAssertEqual(Set(result.files.map(\.path)), [".gitignore", "src/main.swift"], "\(result.files)")
        XCTAssertEqual(result.not_tracked, [hidden("src/gen/")])
    }

    func testDirectoryIgnoredAtTheStart_isNotListed() async throws {
        try write("build/\n", ".gitignore")
        try write("o\n", "build/old.o")
        try await snapshot(.start)
        try write("build/\n*.log\n", ".gitignore")
        try write("n\n", "build/new.o")
        try write("l\n", "run.log")
        try await snapshot(.review)

        let result = try await changes()
        XCTAssertEqual(Set(result.files.map(\.path)), [".gitignore", "run.log"], "\(result.files)")
        XCTAssertEqual(result.not_tracked, [], "build/ was ignored before the round began")
    }

    func testEmptyNewDirectoryHiddenByARoundRule_isNotListed() async throws {
        try write("seed\n", "seed.txt")
        try await snapshot(.start)
        try write("cache/\n", ".gitignore")
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent("cache", isDirectory: true), withIntermediateDirectories: true)
        try await snapshot(.review)

        let result = try await changes()
        XCTAssertEqual(result.files.map(\.path), [".gitignore"])
        XCTAssertEqual(result.not_tracked, [], "an empty directory hides nothing")
    }

    func testDirectoryTheStartHeld_isOpened_soItsFilesDoNotReadAsDeleted_andItsStartFilesAreNotCapped() async throws {
        let limit = TaskSnapshotService.RoundHiddenStagingLimit.standard.files
        for index in 0...limit {
            try write("d\(index)\n", String(format: "data/f%04d.txt", index))
        }
        try await snapshot(.start)
        try write("data/\n", ".gitignore")
        try write("changed\n", "data/f0000.txt")
        try await snapshot(.review)

        let result = try await changes()
        XCTAssertEqual(result.files.map(\.path), [".gitignore", "data/f0000.txt"], "\(result.files.prefix(5))")
        XCTAssertEqual(result.files.last?.change_type, "modified")
        XCTAssertEqual(result.not_tracked, [], "files the start held are restored whatever their number")
    }

    // MARK: - Single files: shown, up to a limit

    func testHiddenFiles_exactlyAtTheCountLimit_areAllShown() async throws {
        let limit = TaskSnapshotService.RoundHiddenStagingLimit.standard.files
        try write("seed\n", "seed.txt")
        try await snapshot(.start)
        try write("*.log\n", ".gitignore")
        for index in 0..<limit {
            try write("l\n", String(format: "h%04d.log", index))
        }
        try await snapshot(.review)

        let result = try await changes()
        XCTAssertEqual(result.files.filter { $0.path.hasSuffix(".log") }.count, limit)
        XCTAssertEqual(result.not_tracked, [])
    }

    func testHiddenFiles_oneOverTheCountLimit_theLastIsNotTracked() async throws {
        let limit = TaskSnapshotService.RoundHiddenStagingLimit.standard.files
        try write("seed\n", "seed.txt")
        try await snapshot(.start)
        try write("*.log\n", ".gitignore")
        for index in 0...limit {
            try write("l\n", String(format: "h%04d.log", index))
        }

        let live = try await changes()
        XCTAssertEqual(live.files.filter { $0.path.hasSuffix(".log") }.count, limit)
        let last = String(format: "h%04d.log", limit)
        XCTAssertEqual(live.not_tracked, [hidden(last)])

        try await snapshot(.review)
        let ended = try await changes()
        XCTAssertEqual(ended.not_tracked, [hidden(last)], "the end snapshot keeps it in Not-Shown:")
        XCTAssertFalse(try storedPaths("refs/nanoteams/1/1/1/review").contains(last))
    }

    func testHiddenFiles_overTheByteLimit_theRestIsNotTracked_andExactlyAtItAllAreShown() async throws {
        let bytes = TaskSnapshotService.RoundHiddenStagingLimit.standard.bytes
        try write("seed\n", "seed.txt")
        try await snapshot(.start)
        try write("*.bin\n", ".gitignore")
        try writeBytes(bytes / 2, "a.bin")
        try writeBytes(bytes - bytes / 2, "b.bin")

        let atLimit = try await changes()
        XCTAssertEqual(Set(atLimit.files.map(\.path)), [".gitignore", "a.bin", "b.bin"])
        XCTAssertEqual(atLimit.not_tracked, [])

        try writeBytes(bytes - bytes / 2 + 1, "b.bin")
        let over = try await changes()
        XCTAssertEqual(Set(over.files.map(\.path)), [".gitignore", "a.bin"])
        XCTAssertEqual(over.not_tracked, [hidden("b.bin")])
    }

    func testThousandsOfSkippedFiles_collapseToTheirDirectory() async throws {
        let limit = TaskSnapshotService.RoundHiddenStagingLimit.standard.files
        let listed = TaskSnapshotService.RoundHiddenStagingLimit.standard.listedSkippedFiles
        try write("keep\n", "logs/keep.txt")
        try write("seed\n", "seed.txt")
        try await snapshot(.start)
        try write("*.log\n", ".gitignore")
        for index in 0..<(limit + listed + 1) {
            try write("l\n", String(format: "logs/h%04d.log", index))
        }
        try write("r\n", "root.log")

        let result = try await changes()
        XCTAssertEqual(result.files.filter { $0.path.hasSuffix(".log") }.count, limit)
        XCTAssertEqual(result.not_tracked, [hidden("./"), hidden("logs/")],
                       "a list past its own limit names the directories, not every file")
    }

    /// The private index outlives a snapshot, and `git rm --cached` refuses a file whose staged
    /// content matches neither the work tree nor a HEAD — the private repository has none. So a
    /// file a live diff force-staged and the role then changed stayed tracked, was updated by
    /// `add -A` whatever the rules said, and the next round started with it in its tree.
    func testFileForceStagedByALiveDiff_thenChanged_isIgnoredByTheNextRound() async throws {
        try write("seed\n", "seed.txt")
        try await snapshot(.start)
        try write("hidden.txt\n", ".gitignore")
        try write("one\n", "hidden.txt")
        _ = try await changes()
        try await snapshot(.review)

        try write("two\n", "hidden.txt")
        try await service.takeSnapshot(workFolder: tempDir, taskID: 1, runID: 1, round: 2, phase: .start)
        try write("v\n", "visible.txt")
        try await service.takeSnapshot(workFolder: tempDir, taskID: 1, runID: 1, round: 2, phase: .review)

        let round2 = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 1, runID: 1, round: 2,
            page: 1, pageSize: 100, filePath: nil)
        XCTAssertEqual(round2.files.map(\.path), ["visible.txt"], "\(round2.files)")
        let startOfRound2 = try storedPaths("refs/nanoteams/1/1/2/start")
        XCTAssertFalse(startOfRound2.contains("hidden.txt"), "round 2 starts under the rule: \(startOfRound2)")
    }

    // MARK: - The policy alone

    func testStagingPlan_ordersByPath_andStopsAtTheFirstLimitReached() {
        typealias Limit = TaskSnapshotService.RoundHiddenStagingLimit
        let plan = TaskSnapshotService.planRoundHiddenStaging(
            [("c", 1), ("a", 1), ("b", 1)], limit: Limit(files: 2, bytes: 100, listedSkippedFiles: 10))
        XCTAssertEqual(plan.stage, ["a", "b"])
        XCTAssertEqual(plan.skipped, ["c"])

        let bySize = TaskSnapshotService.planRoundHiddenStaging(
            [("a", 60), ("b", 50), ("c", 1)], limit: Limit(files: 10, bytes: 100, listedSkippedFiles: 10))
        XCTAssertEqual(bySize.stage, ["a"])
        XCTAssertEqual(bySize.skipped, ["b", "c"], "once a limit is reached the rest is not staged")

        let empty = TaskSnapshotService.planRoundHiddenStaging([], limit: Limit.standard)
        XCTAssertEqual(empty.stage, [])
        XCTAssertEqual(empty.skipped, [])
    }

    func testSkippedList_isListedUpToItsLimit_thenCollapsedByNearestDirectory() {
        typealias Limit = TaskSnapshotService.RoundHiddenStagingLimit
        let limit = Limit(files: 1, bytes: 1, listedSkippedFiles: 2)
        XCTAssertEqual(TaskSnapshotService.listedSkippedPaths(["a/x", "b"], limit: limit), ["a/x", "b"])
        XCTAssertEqual(
            TaskSnapshotService.listedSkippedPaths(["a/x", "a/y", "b", "a/c/z"], limit: limit),
            ["./", "a/", "a/c/"])
        XCTAssertEqual(TaskSnapshotService.listedSkippedPaths([], limit: limit), [])
    }
}
