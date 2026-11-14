import XCTest
@testable import NanoTeams

/// N1 of the F6 acceptance (2026-11-12): a snapshot command whose cost grows with the work tree
/// or the store — the cold `add -A`, `write-tree`, the `gc` after a task's removal — runs to its
/// end. Until then every call carried the app's 60 s limit, so on a large folder without ignore
/// rules the first `add -A` was SIGTERMed (then SIGKILLed) every time, git removed `index.lock`,
/// and the folder never got a start snapshot; `gc --prune=now` on a large store never finished.
///
/// The commands are made slow, not the folder large: `StallingGit` is a wrapper that sleeps
/// before running the named subcommands, and the service is given a per-command limit well
/// under that sleep.
final class TaskSnapshotTimeLimitTests: XCTestCase {
    private let fileManager = FileManager.default
    private var root: URL!
    private var work: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = fileManager.temporaryDirectory
            .appendingPathComponent("TaskSnapshotTimeLimitTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        work = root.appendingPathComponent("work", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? fileManager.removeItem(at: root) }
        root = nil
        work = nil
        try await super.tearDown()
    }

    /// The per-command limit the tests give: far above what a FAST snapshot command takes under a
    /// full parallel run (0.5 s was not — on 2026-11-12 a `rev-parse` / `config` of the start
    /// snapshot crossed it with 20 test processes running, and `…runsToItsEnd` failed on a command
    /// it never stalled), and well under each stall below, so a stalled command still crosses it.
    private static let limit: TimeInterval = 4

    private func service(stalling subcommands: [String], seconds: Double, limit: TimeInterval) throws -> TaskSnapshotService {
        let git = try StallingGit.make(in: root, stalling: subcommands, seconds: seconds)
        return TaskSnapshotService(
            globalExcludesFile: nil,
            gitInvocation: SnapshotGitInvocation(executable: git, timeLimit: limit))
    }

    /// RED before the fix: the stalled `add -A` was stopped at the limit and the snapshot
    /// threw `ProcessRunnerError.timeout`.
    func testAddSlowerThanTheCommandLimit_runsToItsEnd() async throws {
        try "content".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let svc = try service(stalling: ["add"], seconds: 6, limit: Self.limit)

        try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 0, round: 1, phase: .start)

        let refs = try await svc.listTaskRefs(workFolder: work, taskID: 1)
        XCTAssertEqual(refs, ["refs/nanoteams/1/0/1/start"])
    }

    /// RED before the fix: the stalled `gc` was stopped at the limit (and the error swallowed),
    /// so the unreachable objects of the removed task stayed in the store.
    func testGCSlowerThanTheCommandLimit_prunesTheRemovedTasksObjects() async throws {
        try "one".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let svc = try service(stalling: ["gc"], seconds: 6, limit: Self.limit)
        try await svc.takeSnapshot(workFolder: work, taskID: 7, runID: 0, round: 1, phase: .start)
        try "two".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await svc.takeSnapshot(workFolder: work, taskID: 7, runID: 0, round: 1, phase: .review)
        let gitDir = NTMSPaths(workFolderRoot: work).snapshotsGitDir
        XCTAssertGreaterThan(try looseObjectCount(gitDir), 0, "the fixture must leave loose objects")

        try await svc.cleanupTask(workFolder: work, taskID: 7)

        let refs = try await svc.listTaskRefs(workFolder: work, taskID: 7)
        XCTAssertTrue(refs.isEmpty)
        XCTAssertEqual(try looseObjectCount(gitDir), 0, "gc --prune=now must have run to its end")
    }

    /// The limit still holds where the cost does not grow with the folder: a `commit-tree` that
    /// hangs is stopped, and the snapshot fails instead of holding the folder lock for ever.
    func testCommandWhoseCostDoesNotGrow_isStillStoppedAtTheLimit() async throws {
        try "content".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let svc = try service(stalling: ["commit-tree"], seconds: 8, limit: Self.limit)

        do {
            try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 0, round: 1, phase: .start)
            XCTFail("a commit-tree past the limit must fail the snapshot")
        } catch let error as ProcessRunnerError {
            guard case .timeout = error else { return XCTFail("expected timeout, got \(error)") }
        }
    }

    func testSubcommandPolicy_namesTheCommandsThatScaleWithTheFolder() {
        let unbounded: [[String]] = [
            ["--git-dir=/s", "--work-tree=/w", "add", "-A"],
            ["--git-dir=/s", "--work-tree=/w", "--literal-pathspecs", "add", "-f", "--pathspec-from-file=/l"],
            ["--git-dir=/s", "--work-tree=/w", "write-tree"],
            ["--git-dir=/s", "--work-tree=/w", "-c", "core.quotePath=false", "ls-files", "-i"],
            ["--git-dir=/s", "--work-tree=/w", "rm", "--cached"],
            ["--git-dir=/s", "-c", "gc.autoDetach=false", "gc", "--prune=now"],
            ["--git-dir=/s", "--work-tree=/w", "diff-index", "--cached"],
            ["--git-dir=/s", "--work-tree=/t", "-c", "core.quotePath=false", "check-ignore", "--no-index"],
        ]
        for args in unbounded {
            XCTAssertNil(TaskSnapshotService.timeLimit(forSnapshotGit: args, perCommand: 60), "\(args)")
        }
        let bounded: [[String]] = [
            ["--git-dir=/s", "commit-tree", "abc", "-m", "add"],
            ["--git-dir=/s", "update-ref", "refs/x", "abc"],
            ["--git-dir=/s", "rev-parse", "--verify", "refs/x"],
            ["--git-dir=/s", "for-each-ref", "--format=%(refname)", "refs/nanoteams/1/"],
            ["--git-dir=/s", "-c", "core.quotePath=false", "diff", "-M", "a", "b"],
            ["init", "--bare", "/s"],
            ["config", "--file", "/h/.gitconfig", "--get", "core.excludesfile"],
        ]
        for args in bounded {
            XCTAssertEqual(TaskSnapshotService.timeLimit(forSnapshotGit: args, perCommand: 60), 60, "\(args)")
        }
    }

    // MARK: - Helpers

    private func looseObjectCount(_ gitDir: URL) throws -> Int {
        let res = try ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["--git-dir=\(gitDir.path)", "count-objects", "-v"],
            currentDirectory: root)
        for line in res.stdout.split(separator: "\n") where line.hasPrefix("count: ") {
            return Int(line.dropFirst("count: ".count)) ?? -1
        }
        return -1
    }
}

/// A git that sleeps before running the named subcommands, then runs `/usr/bin/git` as given.
enum StallingGit {
    static func make(in directory: URL, stalling subcommands: [String], seconds: Double) throws -> String {
        let bin = directory.appendingPathComponent("bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("git")
        let cases = subcommands.joined(separator: "|")
        let body = """
        #!/bin/sh
        skip=0
        for a in "$@"; do
          if [ "$skip" = 1 ]; then skip=0; continue; fi
          case "$a" in
            -c) skip=1 ;;
            -*) ;;
            \(cases)) /bin/sleep \(seconds); break ;;
            *) break ;;
          esac
        done
        exec /usr/bin/git "$@"

        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }
}
