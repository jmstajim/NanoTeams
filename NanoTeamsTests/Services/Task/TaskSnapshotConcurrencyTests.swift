import XCTest
@testable import NanoTeams

/// The snapshot store under concurrent use (N10 of the F6 acceptance, 2026-11-12). The tests
/// this file replaces asserted only that both operations finished, which they did with a global
/// lock, with no lock at all, and on the synchronous actor before F2. These MEASURE: git is
/// slowed with `StallingGit`, so serialization and overlap show in the elapsed time; and a race
/// of a live diff, an end snapshot and a neighbouring task's removal ends with `git fsck` clean.
final class TaskSnapshotConcurrencyTests: XCTestCase {
    private let fileManager = FileManager.default
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = fileManager.temporaryDirectory
            .appendingPathComponent("TaskSnapshotConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? fileManager.removeItem(at: root) }
        root = nil
        try await super.tearDown()
    }

    private func folder(_ name: String, files: [String: String] = ["a.txt": "a"]) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        for (path, content) in files {
            try content.write(to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        return url
    }

    private func stalledService(seconds: Double) throws -> TaskSnapshotService {
        let git = try StallingGit.make(in: root, stalling: ["add"], seconds: seconds)
        return TaskSnapshotService(
            globalExcludesFile: nil, gitInvocation: SnapshotGitInvocation(executable: git, timeLimit: 60))
    }

    /// Two folders never wait for each other: two snapshots whose `add` each takes 1 s finish
    /// together. RED under the mutation «one lock for every folder» (≥ 2 s).
    func testDifferentFolders_overlap() async throws {
        let a = try folder("A")
        let b = try folder("B")
        let svc = try stalledService(seconds: 1.0)
        let clock = ContinuousClock()
        let started = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await svc.takeSnapshot(workFolder: a, taskID: 1, runID: 0, round: 1, phase: .start) }
            group.addTask { try await svc.takeSnapshot(workFolder: b, taskID: 1, runID: 0, round: 1, phase: .start) }
            try await group.waitForAll()
        }
        let elapsed = clock.now - started
        XCTAssertLessThan(elapsed, .milliseconds(1800), "two folders took \(elapsed)")
        let refsA = try await svc.listTaskRefs(workFolder: a, taskID: 1)
        let refsB = try await svc.listTaskRefs(workFolder: b, taskID: 1)
        XCTAssertEqual(refsA, ["refs/nanoteams/1/0/1/start"])
        XCTAssertEqual(refsB, ["refs/nanoteams/1/0/1/start"])
    }

    /// One folder's operations take turns: two snapshots whose `add` each takes 0.6 s take at
    /// least 1.2 s together, and both land. RED under the mutation «no folder lock» (≈ 0.6 s, or
    /// `index.lock: File exists`).
    func testOneFolder_takesTurns() async throws {
        let a = try folder("A")
        let svc = try stalledService(seconds: 0.6)
        let clock = ContinuousClock()
        let started = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await svc.takeSnapshot(workFolder: a, taskID: 1, runID: 0, round: 1, phase: .start) }
            group.addTask { try await svc.takeSnapshot(workFolder: a, taskID: 2, runID: 0, round: 1, phase: .start) }
            try await group.waitForAll()
        }
        let elapsed = clock.now - started
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(1200), "one folder took \(elapsed)")
        let refs1 = try await svc.listTaskRefs(workFolder: a, taskID: 1)
        let refs2 = try await svc.listTaskRefs(workFolder: a, taskID: 2)
        XCTAssertEqual(refs1.count, 1)
        XCTAssertEqual(refs2.count, 1)
    }

    /// §3.2 test 5 and §3.12: a live `task_changes`, an end snapshot of the same task and the
    /// removal of a NEIGHBOURING task (`gc --prune=now`) at once, five times over: every ref of
    /// the kept task still resolves and `git fsck --strict` finds nothing. RED under the mutation
    /// «no folder lock» (a prune between an `add` and its `commit-tree` loses objects, or two
    /// writers meet at `index.lock`).
    func testLiveDiff_endSnapshot_andANeighboursRemoval_leaveTheStoreWhole() async throws {
        let work = try folder("work", files: ["a.txt": "start", "b.txt": "b"])
        let svc = TaskSnapshotService(globalExcludesFile: nil)
        try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 0, round: 1, phase: .start)

        for iteration in 0..<5 {
            try "neighbour \(iteration)".write(to: work.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
            try await svc.takeSnapshot(workFolder: work, taskID: 2, runID: 0, round: 1, phase: .start)
            try "edit \(iteration)".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await svc.diffChanges(
                        workFolder: work, folderID: "f", taskID: 1, runID: 0, round: 1, roundIsOpen: true,
                        page: 1, pageSize: 5, filePath: nil)
                }
                group.addTask {
                    try await svc.takeSnapshot(workFolder: work, taskID: 1, runID: 0, round: 1, phase: .review)
                }
                group.addTask { try await svc.cleanupTask(workFolder: work, taskID: 2) }
                try await group.waitForAll()
            }
        }

        let gitDir = NTMSPaths(workFolderRoot: work).snapshotsGitDir
        let refs = try await svc.listTaskRefs(workFolder: work, taskID: 1)
        XCTAssertEqual(Set(refs), ["refs/nanoteams/1/0/1/start", "refs/nanoteams/1/0/1/review"])
        for ref in refs {
            let verify = try ProcessRunner.run(
                executable: "/usr/bin/git", arguments: ["--git-dir=\(gitDir.path)", "rev-parse", "--verify", "\(ref)^{tree}"],
                currentDirectory: root)
            XCTAssertEqual(verify.exitCode, 0, "\(ref): \(verify.stderr)")
        }
        let neighbour = try await svc.listTaskRefs(workFolder: work, taskID: 2)
        XCTAssertTrue(neighbour.isEmpty)
        let fsck = try ProcessRunner.run(
            executable: "/usr/bin/git", arguments: ["--git-dir=\(gitDir.path)", "fsck", "--strict", "--no-dangling"],
            currentDirectory: root)
        XCTAssertEqual(fsck.exitCode, 0, fsck.stdout + fsck.stderr)
        let diff = try await svc.diffChanges(
            workFolder: work, folderID: "f", taskID: 1, runID: 0, round: 1, roundIsOpen: false,
            page: 1, pageSize: 5, filePath: nil)
        XCTAssertTrue(diff.diff.contains("+edit 4"), "the last end snapshot holds the last edit")
    }
}
