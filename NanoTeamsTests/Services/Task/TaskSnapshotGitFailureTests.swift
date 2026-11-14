import XCTest
@testable import NanoTeams

/// Every git call of the snapshot store that can fail — and the snapshot or `task_changes` that
/// fails WITH it, naming the step, instead of recording what a half-run produced (F6 coverage
/// pass, 2026-11-12: these guards were the uncovered tail of the `TaskSnapshotService+*` split).
///
/// `FailingGit` is a wrapper that exits 128 with git's own `fatal:` shape when its argument list
/// contains one marker and runs `/usr/bin/git` otherwise, so each case breaks exactly one call
/// of a real store on a real work tree. What a case checks besides the error: that the ref the
/// failed call would have led to was not written — a snapshot is all or nothing.
final class TaskSnapshotGitFailureTests: XCTestCase {
    private let fileManager = FileManager.default
    private var root: URL!
    private var work: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = fileManager.temporaryDirectory
            .appendingPathComponent("TaskSnapshotGitFailureTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Helpers

    private var gitDir: URL { NTMSPaths(workFolderRoot: work).snapshotsGitDir }

    private func healthy() -> TaskSnapshotService {
        TaskSnapshotService(globalExcludesFile: nil)
    }

    private func failing(on marker: String) throws -> TaskSnapshotService {
        let git = try FailingGit.make(in: root, failingOn: marker)
        return TaskSnapshotService(
            globalExcludesFile: nil, gitInvocation: SnapshotGitInvocation(executable: git, timeLimit: 60))
    }

    private func write(_ text: String, _ relative: String) throws {
        let url = work.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func refExists(_ ref: String) throws -> Bool {
        try ProcessRunner.runGit(
            ["--git-dir=\(gitDir.path)", "rev-parse", "--verify", "-q", ref], in: root
        ).exitCode == 0
    }

    private func changes(_ service: TaskSnapshotService, roundIsOpen: Bool = false) async throws
        -> TaskSnapshotService.TaskChangesResult
    {
        try await service.diffChanges(
            workFolder: work, folderID: "f", taskID: 1, runID: 1, round: 1, roundIsOpen: roundIsOpen,
            page: 1, pageSize: 100, filePath: nil)
    }

    /// `body` throws `ExternalAutovisorError(.commandFailed)` whose message starts with `prefix`
    /// and carries what git said on stderr.
    private func assertFails(
        _ prefix: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected “\(prefix)…”", file: file, line: line)
        } catch let error as ExternalAutovisorError {
            XCTAssertEqual(error.code, .commandFailed, error.message, file: file, line: line)
            XCTAssertTrue(error.message.hasPrefix(prefix), error.message, file: file, line: line)
            XCTAssertTrue(error.message.contains(FailingGit.stderrLine), error.message, file: file, line: line)
        } catch {
            XCTFail("expected ExternalAutovisorError, got \(error)", file: file, line: line)
        }
    }

    // MARK: - A new store

    func testStoreConfigWriteFails_firstSnapshotFails_andNoStartIsRecorded() async throws {
        try write("a\n", "a.txt")
        let svc = try failing(on: " config core.sharedRepository 0600 ")

        await assertFails("Failed to configure snapshots repository") {
            try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .start)
        }
        XCTAssertFalse(try refExists("refs/nanoteams/1/1/1/start"))
    }

    /// The check of an EXISTING store builds its reference on a scratch store; when that `init`
    /// fails, the check's own error reaches the caller as it is — not re-worded as an I/O error
    /// of the store ("could not be restored") it never got to touch.
    func testReferenceStoreInitFails_onTheCheckOfAnExistingStore_reportsTheInit() async throws {
        try write("a\n", "a.txt")
        try await healthy().takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .start)
        let svc = try failing(on: " init --bare ")

        await assertFails("Failed to initialize snapshots repository") {
            try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .review)
        }
        XCTAssertFalse(try refExists("refs/nanoteams/1/1/1/review"))
    }

    // MARK: - takeSnapshot

    func testWriteTreeFails_snapshotFails() async throws {
        try write("a\n", "a.txt")
        let svc = try failing(on: " write-tree ")

        await assertFails("Snapshot write-tree failed") {
            try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .start)
        }
        XCTAssertFalse(try refExists("refs/nanoteams/1/1/1/start"))
    }

    func testCommitTreeFails_snapshotFails() async throws {
        try write("a\n", "a.txt")
        let svc = try failing(on: " commit-tree ")

        await assertFails("Snapshot commit-tree failed") {
            try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .start)
        }
        XCTAssertFalse(try refExists("refs/nanoteams/1/1/1/start"))
    }

    func testPhaseRefUpdateFails_snapshotFails() async throws {
        try write("a\n", "a.txt")
        try await healthy().takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .start)
        let svc = try failing(on: " update-ref refs/nanoteams/1/1/1/review ")

        await assertFails("Snapshot update-ref failed") {
            try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .review)
        }
        XCTAssertFalse(try refExists("refs/nanoteams/1/1/1/review"))
        XCTAssertTrue(try refExists("refs/nanoteams/1/1/1/start"), "anti-vacuum: the healthy start was taken")
    }

    // MARK: - The round's rules (recorded at the start)

    /// A start whose rules could not be recorded is no start: a round read later would fall back
    /// to the rules on disk, which a role can write.
    func testRoundRulesBlobFails_startFails_andNoStartIsRecorded() async throws {
        try write("a\n", "a.txt")
        let svc = try failing(on: " hash-object -w --no-filters ")

        await assertFails("Snapshot rules hash-object failed") {
            try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .start)
        }
        XCTAssertFalse(try refExists("refs/nanoteams/1/1/1/start"))
    }

    func testRoundRulesRefFails_startFails_andNoStartIsRecorded() async throws {
        try write("a\n", "a.txt")
        let svc = try failing(on: " update-ref refs/nanoteams-rules/1/1/1 ")

        await assertFails("Snapshot rules update-ref failed") {
            try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .start)
        }
        XCTAssertFalse(try refExists("refs/nanoteams/1/1/1/start"))
        XCTAssertFalse(try refExists("refs/nanoteams-rules/1/1/1"))
    }

    // MARK: - The round's rules (restored at its end)

    /// A round whose rules moved — the role wrote a `.gitignore` — restores the start's rules on
    /// the end snapshot: what the disk rules hide, then what the start tree held, then what the
    /// round's rules say. Each of the three git calls failing fails the snapshot.
    private func startThenMoveTheRules() async throws {
        try write("node_modules/\n", ".gitignore")
        try write("dep\n", "src/node_modules/dep.js")
        try write("a\n", "src/a.txt")
        try await healthy().takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .start)
        try write("node_modules/\nsrc/\n", ".gitignore")
        try write("a changed\n", "src/a.txt")
    }

    func testRestoringTheRoundsRules_diskIgnoredListingFails_snapshotFails() async throws {
        try await startThenMoveTheRules()
        let svc = try failing(on: " ls-files -o -i ")

        await assertFails("Snapshot ls-files failed") {
            try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .review)
        }
        XCTAssertFalse(try refExists("refs/nanoteams/1/1/1/review"))
    }

    func testRestoringTheRoundsRules_startTreeListingFails_snapshotFails() async throws {
        try await startThenMoveTheRules()
        let svc = try failing(on: " ls-tree -r -t -z ")

        await assertFails("Snapshot ls-tree failed") {
            try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .review)
        }
        XCTAssertFalse(try refExists("refs/nanoteams/1/1/1/review"))
    }

    func testRestoringTheRoundsRules_checkIgnoreFails_snapshotFails() async throws {
        try await startThenMoveTheRules()
        let svc = try failing(on: " check-ignore --no-index ")

        await assertFails("Snapshot check-ignore failed") {
            try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .review)
        }
        XCTAssertFalse(try refExists("refs/nanoteams/1/1/1/review"))
    }

    /// Anti-vacuum for the three above: the same round with a healthy git takes its end and
    /// reads the round under the start's rules — so each failure above was the named call's.
    func testRestoringTheRoundsRules_withAHealthyGit_takesTheEnd() async throws {
        try await startThenMoveTheRules()
        try await healthy().takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .review)

        XCTAssertTrue(try refExists("refs/nanoteams/1/1/1/review"))
        let result = try await changes(healthy())
        XCTAssertEqual(Set(result.files.map(\.path)), [".gitignore", "src/a.txt"])
    }

    // MARK: - task_changes

    private func takeARound() async throws {
        try write("a\n", "a.txt")
        try await healthy().takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .start)
        try write("b\n", "a.txt")
        try await healthy().takeSnapshot(workFolder: work, taskID: 1, runID: 1, round: 1, phase: .review)
    }

    func testTaskChanges_refListingFails_fails() async throws {
        try await takeARound()
        let svc = try failing(on: " for-each-ref --format=%(refname) refs/nanoteams/1/ ")

        await assertFails("Snapshot ref listing failed") { _ = try await self.changes(svc) }
    }

    func testTaskChanges_pageDiffFails_fails() async throws {
        try await takeARound()
        let svc = try failing(on: " -M -U3 ")

        await assertFails("Snapshot diff failed") { _ = try await self.changes(svc) }
        let result = try await changes(healthy())
        XCTAssertEqual(result.files.map(\.path), ["a.txt"], "anti-vacuum: the round reads with a healthy git")
    }

    func testTaskChanges_nameStatusFails_fails() async throws {
        try await takeARound()
        let svc = try failing(on: " -z --name-status ")

        await assertFails("Snapshot diff failed") { _ = try await self.changes(svc) }
    }
}

/// A git that fails — `fatal:` on stderr, exit 128 — when its arguments contain `marker`, and
/// runs `/usr/bin/git` as given otherwise. The marker is matched against the arguments joined by
/// single spaces with a space at each end, so `" commit-tree "` names that subcommand alone.
enum FailingGit {
    static let stderrLine = "fatal: injected by FailingGit"

    static func make(in directory: URL, failingOn marker: String) throws -> String {
        let bin = directory.appendingPathComponent("failing-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("git")
        let quoted = marker.replacingOccurrences(of: "'", with: "'\\''")
        let body = """
        #!/bin/sh
        case " $* " in
          *'\(quoted)'*) echo '\(stderrLine)' >&2; exit 128 ;;
        esac
        exec /usr/bin/git "$@"

        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }
}
