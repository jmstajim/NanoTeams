import XCTest
@testable import NanoTeams

final class TaskSnapshotServiceTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var service: TaskSnapshotService!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("TaskSnapshotServiceTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = TaskSnapshotService()
    }

    override func tearDown() async throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    func testSnapshotLifecycle_startAndReview_capturesChangesAndPaginates() async throws {
        let fileA = tempDir.appendingPathComponent("fileA.txt")
        try "initial content".write(to: fileA, atomically: true, encoding: .utf8)

        // 1. Take start snapshot for task 1, round 1
        try await service.takeSnapshot(workFolder: tempDir, taskID: 1, round: 1, phase: .start)

        let snapshotsGit = tempDir.appendingPathComponent(".nanoteams/internal/snapshots.git")
        XCTAssertTrue(fileManager.fileExists(atPath: snapshotsGit.path))
        let excludeFile = snapshotsGit.appendingPathComponent("info/exclude")
        let excludeContent = try String(contentsOf: excludeFile, encoding: .utf8)
        XCTAssertTrue(excludeContent.contains(".nanoteams"))

        // Modify fileA, create fileB, delete nothing yet
        try "modified content".write(to: fileA, atomically: true, encoding: .utf8)
        let fileB = tempDir.appendingPathComponent("fileB.swift")
        try "func test() {}".write(to: fileB, atomically: true, encoding: .utf8)

        // Also create a file inside .nanoteams/ to verify exclusion
        let internalDir = tempDir.appendingPathComponent(".nanoteams/internal/test")
        try fileManager.createDirectory(at: internalDir, withIntermediateDirectories: true)
        try "internal log".write(to: internalDir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)

        // 2. Take review snapshot
        try await service.takeSnapshot(workFolder: tempDir, taskID: 1, round: 1, phase: .review)

        // 3. Diff changes
        let result = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "folder-1",
            taskID: 1,
            round: 1,
            page: 1,
            pageSize: 1,
            filePath: nil
        )

        XCTAssertEqual(result.folder_id, "folder-1")
        XCTAssertEqual(result.task_id, 1)
        XCTAssertEqual(result.round, 1)
        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(result.total_pages, 2)
        XCTAssertTrue(result.has_more)
        XCTAssertFalse(result.files.contains(where: { $0.path.contains(".nanoteams") }))

        let paths = result.files.map(\.path).sorted()
        XCTAssertEqual(paths, ["fileA.txt", "fileB.swift"])

        // Page 2
        let page2 = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "folder-1",
            taskID: 1,
            round: 1,
            page: 2,
            pageSize: 1,
            filePath: nil
        )
        XCTAssertEqual(page2.page, 2)
        XCTAssertFalse(page2.has_more)
        XCTAssertFalse(page2.diff.isEmpty)

        // 4. Single file filter
        let filtered = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "folder-1",
            taskID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: "fileA.txt"
        )
        XCTAssertEqual(filtered.files.count, 1)
        XCTAssertEqual(filtered.files.first?.path, "fileA.txt")
        XCTAssertEqual(filtered.files.first?.change_type, "modified")
        XCTAssertTrue(filtered.diff.contains("modified content"))

        // Non-existent file filter returns empty
        let nonExistent = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "folder-1",
            taskID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: "nonExistent.txt"
        )
        XCTAssertEqual(nonExistent.files.count, 0)
        XCTAssertEqual(nonExistent.diff, "")
    }

    func testDiffChanges_pathTraversal_throwsError() async throws {
        let fileA = tempDir.appendingPathComponent("fileA.txt")
        try "initial".write(to: fileA, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 1, round: 1, phase: .start)

        let maliciousPaths = [
            "../etc/passwd",
            "../../secret.txt",
            "/etc/passwd",
            "/private/var/log",
            "..\\windows\\system32",
            "\\windows\\system32",
            "sub/..\\..\\windows",
            "foo/../../bar"
        ]

        for badPath in maliciousPaths {
            do {
                _ = try await service.diffChanges(
                    workFolder: tempDir,
                    folderID: "folder-1",
                    taskID: 1,
                    round: 1,
                    page: 1,
                    pageSize: 10,
                    filePath: badPath
                )
                XCTFail("Expected path traversal for '\(badPath)' to throw")
            } catch let error as ExternalAutovisorError {
                XCTAssertEqual(error.code, .invalidArgs, "Expected INVALID_ARGS for \(badPath)")
            }
        }
    }

    func testDiffChanges_nullByteHandling_rejectedWithInvalidArgs() async throws {
        let fileA = tempDir.appendingPathComponent("fileA.txt")
        try "initial".write(to: fileA, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 1, round: 1, phase: .start)

        let nullBytePaths = [
            "file\0.txt",
            "\0/etc/passwd",
            "\0"
        ]

        for nullPath in nullBytePaths {
            do {
                _ = try await service.diffChanges(
                    workFolder: tempDir,
                    folderID: "folder-1",
                    taskID: 1,
                    round: 1,
                    page: 1,
                    pageSize: 10,
                    filePath: nullPath
                )
                XCTFail("Expected null byte path '\(nullPath)' to throw ExternalAutovisorError")
            } catch let error as ExternalAutovisorError {
                XCTAssertEqual(error.code, .invalidArgs, "Expected INVALID_ARGS for null byte path '\(nullPath)'")
            }
        }
    }

    func testPagination_mathematicalConsistency_andMultiPageScenarios() async throws {
        // Create 12 files
        for i in 1...12 {
            let f = tempDir.appendingPathComponent(String(format: "file_%02d.txt", i))
            try "start \(i)".write(to: f, atomically: true, encoding: .utf8)
        }
        try await service.takeSnapshot(workFolder: tempDir, taskID: 7, round: 1, phase: .start)

        for i in 1...12 {
            let f = tempDir.appendingPathComponent(String(format: "file_%02d.txt", i))
            try "review \(i)".write(to: f, atomically: true, encoding: .utf8)
        }
        try await service.takeSnapshot(workFolder: tempDir, taskID: 7, round: 1, phase: .review)

        let pageSize = 5
        // Total 12 files, pageSize 5 -> ceil(12/5) = 3 pages

        // Page 1
        let p1 = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 7, round: 1, page: 1, pageSize: pageSize, filePath: nil
        )
        XCTAssertEqual(p1.page, 1)
        XCTAssertEqual(p1.total_pages, 3)
        XCTAssertTrue(p1.has_more)
        XCTAssertEqual(p1.files.count, 12)
        XCTAssertTrue(p1.diff.contains("file_01.txt"))
        XCTAssertTrue(p1.diff.contains("file_05.txt"))
        XCTAssertFalse(p1.diff.contains("file_06.txt"))

        // Page 2
        let p2 = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 7, round: 1, page: 2, pageSize: pageSize, filePath: nil
        )
        XCTAssertEqual(p2.page, 2)
        XCTAssertEqual(p2.total_pages, 3)
        XCTAssertTrue(p2.has_more)
        XCTAssertTrue(p2.diff.contains("file_06.txt"))
        XCTAssertTrue(p2.diff.contains("file_10.txt"))
        XCTAssertFalse(p2.diff.contains("file_05.txt"))
        XCTAssertFalse(p2.diff.contains("file_11.txt"))

        // Page 3 (final page: 2 remaining files)
        let p3 = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 7, round: 1, page: 3, pageSize: pageSize, filePath: nil
        )
        XCTAssertEqual(p3.page, 3)
        XCTAssertEqual(p3.total_pages, 3)
        XCTAssertFalse(p3.has_more)
        XCTAssertTrue(p3.diff.contains("file_11.txt"))
        XCTAssertTrue(p3.diff.contains("file_12.txt"))
        XCTAssertFalse(p3.diff.contains("file_10.txt"))

        // Page 4 (out of bounds beyond total_pages)
        let p4 = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 7, round: 1, page: 4, pageSize: pageSize, filePath: nil
        )
        XCTAssertEqual(p4.page, 4)
        XCTAssertEqual(p4.total_pages, 3)
        XCTAssertFalse(p4.has_more)
        XCTAssertEqual(p4.diff, "")

        // Exact page boundary: 10 files with pageSize 5 -> total_pages: 2
        // Test with 0 changed files:
        let pZero = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 7, round: 1, page: 1, pageSize: pageSize, filePath: "nonexistent"
        )
        XCTAssertEqual(pZero.total_pages, 1)
        XCTAssertEqual(pZero.page, 1)
        XCTAssertFalse(pZero.has_more)
        XCTAssertEqual(pZero.files.count, 0)
        XCTAssertEqual(pZero.diff, "")

        // Verify mathematical consistency: has_more == (page < total_pages)
        XCTAssertEqual(p1.has_more, p1.page < p1.total_pages)
        XCTAssertEqual(p2.has_more, p2.page < p2.total_pages)
        XCTAssertEqual(p3.has_more, p3.page < p3.total_pages)
        XCTAssertEqual(p4.has_more, p4.page < p4.total_pages)
        XCTAssertEqual(pZero.has_more, pZero.page < pZero.total_pages)
    }

    func testNonGitFolder_fullSnapshotLifecycle() async throws {
        // Explicitly verify tempDir is NOT a git repo
        let userGitDir = tempDir.appendingPathComponent(".git")
        XCTAssertFalse(fileManager.fileExists(atPath: userGitDir.path))

        let doc = tempDir.appendingPathComponent("document.md")
        try "# Initial Doc".write(to: doc, atomically: true, encoding: .utf8)

        // Snapshot start
        try await service.takeSnapshot(workFolder: tempDir, taskID: 100, round: 1, phase: .start)

        // Verify root .git still DOES NOT exist
        XCTAssertFalse(fileManager.fileExists(atPath: userGitDir.path))
        // Verify internal snapshot repo DOES exist
        let snapshotsGit = tempDir.appendingPathComponent(".nanoteams/internal/snapshots.git")
        XCTAssertTrue(fileManager.fileExists(atPath: snapshotsGit.path))

        // Mutate doc
        try "# Updated Doc with Changes".write(to: doc, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 100, round: 1, phase: .review)

        let result = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 100, round: 1, page: 1, pageSize: 5, filePath: nil
        )
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files.first?.path, "document.md")
        XCTAssertEqual(result.files.first?.change_type, "modified")
        XCTAssertTrue(result.diff.contains("+# Updated Doc with Changes"))

        // Cleanup
        try await service.cleanupTask(workFolder: tempDir, taskID: 100)
        let refs = try await service.listTaskRefs(workFolder: tempDir, taskID: 100)
        XCTAssertTrue(refs.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: userGitDir.path))
    }

    func testInternalStateExclusion_completeIsolation() async throws {
        // Create files in root and files in .nanoteams
        let userFile = tempDir.appendingPathComponent("user_code.swift")
        try "func app() {}".write(to: userFile, atomically: true, encoding: .utf8)

        let internalDir = tempDir.appendingPathComponent(".nanoteams/internal")
        try fileManager.createDirectory(at: internalDir, withIntermediateDirectories: true)
        let internalDb = internalDir.appendingPathComponent("db.sqlite")
        try "fake-sqlite-content".write(to: internalDb, atomically: true, encoding: .utf8)

        let stateFile = tempDir.appendingPathComponent(".nanoteams/state.json")
        try "{\"phase\":\"idle\"}".write(to: stateFile, atomically: true, encoding: .utf8)

        let logDir = tempDir.appendingPathComponent(".nanoteams/logs")
        try fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
        let daemonLog = logDir.appendingPathComponent("daemon.log")
        try "log line 1\n".write(to: daemonLog, atomically: true, encoding: .utf8)

        // Snapshot start
        try await service.takeSnapshot(workFolder: tempDir, taskID: 200, round: 1, phase: .start)

        // Mutate both user and internal files
        try "func app() { print(\"modified\") }".write(to: userFile, atomically: true, encoding: .utf8)
        try "fake-sqlite-content-updated".write(to: internalDb, atomically: true, encoding: .utf8)
        try "{\"phase\":\"busy\"}".write(to: stateFile, atomically: true, encoding: .utf8)
        try "log line 1\nlog line 2\n".write(to: daemonLog, atomically: true, encoding: .utf8)
        let newInternalFile = internalDir.appendingPathComponent("temp.dat")
        try "temp data".write(to: newInternalFile, atomically: true, encoding: .utf8)

        // Snapshot review
        try await service.takeSnapshot(workFolder: tempDir, taskID: 200, round: 1, phase: .review)

        // Diff
        let res = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 200, round: 1, page: 1, pageSize: 50, filePath: nil
        )

        // Check: only user_code.swift appears!
        XCTAssertEqual(res.files.count, 1)
        XCTAssertEqual(res.files.first?.path, "user_code.swift")
        XCTAssertFalse(res.diff.contains(".nanoteams"))
        XCTAssertFalse(res.diff.contains("sqlite"))
        XCTAssertFalse(res.diff.contains("daemon.log"))
        XCTAssertFalse(res.diff.contains("phase"))

        // Try explicitly requesting an internal file
        let internalReq = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 200, round: 1, page: 1, pageSize: 10, filePath: ".nanoteams/state.json"
        )
        XCTAssertEqual(internalReq.files.count, 0)
        XCTAssertEqual(internalReq.diff, "")
    }

    /// The removal deletes the task's refs AND prunes what only they held (N10: the test asserted
    /// the refs alone, so a cleanup without `gc` passed). RED under the mutation «no gc».
    func testCleanupTask_removesRefsAndPrunesTheirObjects() async throws {
        let fileA = tempDir.appendingPathComponent("fileA.txt")
        try "initial".write(to: fileA, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 42, round: 1, phase: .start)
        try "changed".write(to: fileA, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 42, round: 1, phase: .review)
        try "other".write(to: tempDir.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 43, round: 1, phase: .start)

        let refsBefore = try await service.listTaskRefs(workFolder: tempDir, taskID: 42)
        XCTAssertEqual(refsBefore.count, 2)
        let gitDir = NTMSPaths(workFolderRoot: tempDir).snapshotsGitDir
        func git(_ args: [String]) throws -> ProcessRunner.Result {
            try ProcessRunner.run(executable: "/usr/bin/git", arguments: ["--git-dir=\(gitDir.path)"] + args,
                                  currentDirectory: tempDir)
        }
        let reviewCommit = try git(["rev-parse", "refs/nanoteams/42/0/1/review"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(try git(["cat-file", "-e", reviewCommit]).exitCode, 0)

        try await service.cleanupTask(workFolder: tempDir, taskID: 42)

        let refsAfter = try await service.listTaskRefs(workFolder: tempDir, taskID: 42)
        XCTAssertEqual(refsAfter.count, 0)
        XCTAssertNotEqual(try git(["cat-file", "-e", reviewCommit]).exitCode, 0, "gc --prune=now removed it")
        let otherRefs = try await service.listTaskRefs(workFolder: tempDir, taskID: 43)
        XCTAssertEqual(otherRefs.count, 1, "the other task's are kept")
        XCTAssertEqual(try git(["fsck", "--strict", "--no-dangling"]).exitCode, 0)
    }

    func testRoundProgression_round2IsIsolatedFromRound1() async throws {
        let fileA = tempDir.appendingPathComponent("code.swift")
        try "round 1 start".write(to: fileA, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 5, round: 1, phase: .start)

        try "round 1 review".write(to: fileA, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 5, round: 1, phase: .review)

        // Advance to round 2
        try await service.takeSnapshot(workFolder: tempDir, taskID: 5, round: 2, phase: .start)
        try "round 2 review".write(to: fileA, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 5, round: 2, phase: .review)

        let diffRound1 = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "f",
            taskID: 5,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )
        XCTAssertTrue(diffRound1.diff.contains("-round 1 start"))
        XCTAssertTrue(diffRound1.diff.contains("+round 1 review"))

        let diffRound2 = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "f",
            taskID: 5,
            round: 2,
            page: 1,
            pageSize: 10,
            filePath: nil
        )
        XCTAssertTrue(diffRound2.diff.contains("-round 1 review"))
        XCTAssertTrue(diffRound2.diff.contains("+round 2 review"))
    }

    /// The measurement `hosted-mcp.md` quotes (N20): a generated folder — 2,600 files of a few
    /// hundred bytes in 26 directories, a `.gitignore` hiding a `node_modules/` of 3,000 more and
    /// a `build/` of 400 — a cold start snapshot, an incremental end snapshot after one file
    /// changed, and a live diff of that round. The numbers ride an attachment
    /// (`xcrun xcresulttool get test-results activities --test-id …`); the assertions are the
    /// shape only — what is ignored is never stored, and the incremental snapshot is cheaper than
    /// the cold one — never a wall-clock budget.
    func testSnapshotDurations_onAGeneratedFolder() async throws {
        for d in 0..<26 {
            let dir = tempDir.appendingPathComponent("src/module\(d)", isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<100 {
                try String(repeating: "line \(d)-\(f)\n", count: 20)
                    .write(to: dir.appendingPathComponent("file\(f).swift"), atomically: false, encoding: .utf8)
            }
        }
        for (ignored, count) in [("node_modules/pkg", 3000), ("build", 400)] {
            let dir = tempDir.appendingPathComponent(ignored, isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<count {
                try "ignored \(f)".write(to: dir.appendingPathComponent("f\(f).js"), atomically: false, encoding: .utf8)
            }
        }
        try "node_modules/\nbuild/\n".write(to: tempDir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        let clock = ContinuousClock()
        let t0 = clock.now
        try await service.takeSnapshot(workFolder: tempDir, taskID: 99, runID: 0, round: 1, phase: .start)
        let cold = clock.now - t0

        try "changed\n".write(to: tempDir.appendingPathComponent("src/module3/file7.swift"), atomically: true, encoding: .utf8)
        let t1 = clock.now
        try await service.takeSnapshot(workFolder: tempDir, taskID: 99, runID: 0, round: 1, phase: .review)
        let incremental = clock.now - t1

        let t2 = clock.now
        let live = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 99, runID: 0, round: 1, roundIsOpen: true,
            page: 1, pageSize: 5, filePath: nil)
        let liveDiff = clock.now - t2

        XCTAssertEqual(live.files.map(\.path), ["src/module3/file7.swift"])
        let gitDir = NTMSPaths(workFolderRoot: tempDir).snapshotsGitDir
        let tree = try ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["--git-dir=\(gitDir.path)", "ls-tree", "-r", "--name-only", "refs/nanoteams/99/0/1/start"],
            currentDirectory: tempDir)
        let stored = tree.stdout.split(separator: "\n")
        XCTAssertEqual(stored.count, 2_601, "2,600 sources and the .gitignore; nothing ignored is stored")
        XCTAssertLessThan(incremental, cold)

        let report = "files=2600 ignored=3400 cold=\(cold) incremental=\(incremental) liveDiff=\(liveDiff)"
        let attachment = XCTAttachment(string: report)
        attachment.name = "snapshot-durations"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDiffChanges_validationEdgeCases_andLatestRoundFallback() async throws {
        let f = tempDir.appendingPathComponent("code.swift")
        try "let a = 1\n".write(to: f, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 10, round: 1, phase: .start)
        try "let a = 2\n".write(to: f, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 10, round: 1, phase: .review)

        // Invalid page
        do {
            _ = try await service.diffChanges(
                workFolder: tempDir, folderID: "f", taskID: 10, round: 1, page: 0, pageSize: 5, filePath: nil
            )
            XCTFail("Expected error for page < 1")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .invalidArgs)
        }

        // Invalid pageSize
        do {
            _ = try await service.diffChanges(
                workFolder: tempDir, folderID: "f", taskID: 10, round: 1, page: 1, pageSize: 0, filePath: nil
            )
            XCTFail("Expected error for pageSize < 1")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .invalidArgs)
        }

        // Invalid file_path (traversal / absolute)
        for badPath in ["../outside.txt", "/absolute/path.txt", "sub\\path", "null\0char"] {
            do {
                _ = try await service.diffChanges(
                    workFolder: tempDir, folderID: "f", taskID: 10, round: 1, page: 1, pageSize: 5, filePath: badPath
                )
                XCTFail("Expected error for bad filePath: \(badPath)")
            } catch let err as ExternalAutovisorError {
                XCTAssertEqual(err.code, .invalidArgs)
            }
        }

        // Non-existent round
        do {
            _ = try await service.diffChanges(
                workFolder: tempDir, folderID: "f", taskID: 10, round: 99, page: 1, pageSize: 5, filePath: nil
            )
            XCTFail("Expected error for nonexistent round")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .invalidArgs)
        }

        // Round nil: resolves latest round (round 1)
        let latestDiff = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 10, round: nil, page: 1, pageSize: 5, filePath: nil
        )
        XCTAssertEqual(latestDiff.round, 1)

        // Round 2 snapshot
        try await service.takeSnapshot(workFolder: tempDir, taskID: 10, round: 2, phase: .start)
        try "let a = 3\n".write(to: f, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 10, round: 2, phase: .review)

        let round2Diff = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 10, round: nil, page: 1, pageSize: 5, filePath: nil
        )
        XCTAssertEqual(round2Diff.round, 2)
    }

    // MARK: - Contract Extensions: Snapshot Exclusions & Deep Path Isolation (TEST_INFRA §2)

    func testSnapshotExclusions_deepInternalPathsAndSubpathExclusions() async throws {
        // Normal subpath user file
        let srcDir = tempDir.appendingPathComponent("src/components", isDirectory: true)
        try fileManager.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let appFile = srcDir.appendingPathComponent("App.swift")
        try "struct App {}".write(to: appFile, atomically: true, encoding: .utf8)

        // Multiple deeply nested .nanoteams files
        let nestedInternal = tempDir.appendingPathComponent(".nanoteams/internal/cache/v1", isDirectory: true)
        try fileManager.createDirectory(at: nestedInternal, withIntermediateDirectories: true)
        let deepCache = nestedInternal.appendingPathComponent("index.bin")
        try "binary-cache".write(to: deepCache, atomically: true, encoding: .utf8)

        let logsDir = tempDir.appendingPathComponent(".nanoteams/logs/subsystem", isDirectory: true)
        try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let subLog = logsDir.appendingPathComponent("audit.log")
        try "audit-event\n".write(to: subLog, atomically: true, encoding: .utf8)

        // Start snapshot
        try await service.takeSnapshot(workFolder: tempDir, taskID: 50, round: 1, phase: .start)

        // Mutate both user file and internal files
        try "struct App { var x = 1 }".write(to: appFile, atomically: true, encoding: .utf8)
        try "binary-cache-v2".write(to: deepCache, atomically: true, encoding: .utf8)
        try "audit-event\naudit-event-2\n".write(to: subLog, atomically: true, encoding: .utf8)

        // Review snapshot
        try await service.takeSnapshot(workFolder: tempDir, taskID: 50, round: 1, phase: .review)

        // Diff all changes
        let diff = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "folder-50",
            taskID: 50,
            round: 1,
            page: 1,
            pageSize: 50,
            filePath: nil
        )

        // Only the user file in src/components must appear
        XCTAssertEqual(diff.files.count, 1)
        XCTAssertEqual(diff.files.first?.path, "src/components/App.swift")
        XCTAssertEqual(diff.files.first?.change_type, "modified")
        XCTAssertTrue(diff.diff.contains("var x = 1"))
        XCTAssertFalse(diff.diff.contains(".nanoteams"))
        XCTAssertFalse(diff.diff.contains("audit-event"))
        XCTAssertFalse(diff.diff.contains("binary-cache"))

        // Direct query for deeply nested internal path must return 0 files and empty diff
        let directInternal = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "folder-50",
            taskID: 50,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: ".nanoteams/internal/cache/v1/index.bin"
        )
        XCTAssertEqual(directInternal.files.count, 0)
        XCTAssertEqual(directInternal.diff, "")
    }

    // MARK: - Milestone F1: Features 3–7 (Private Git & Snapshots Hardening)

    /// Feature 6: Snapshots repository directories are created with POSIX 0o700 permissions and core.sharedRepository=0600.
    func testSnapshotRepo_strictPermissions_0o700And0o600() async throws {
        let fileA = tempDir.appendingPathComponent("fileA.txt")
        try "initial content".write(to: fileA, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 1, round: 1, phase: .start)

        let internalDir = tempDir.appendingPathComponent(".nanoteams/internal")
        let snapshotsGit = internalDir.appendingPathComponent("snapshots.git")
        let internalAttrs = try fileManager.attributesOfItem(atPath: internalDir.path)
        let gitAttrs = try fileManager.attributesOfItem(atPath: snapshotsGit.path)

        let internalPerms = (internalAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let gitPerms = (gitAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0

        XCTAssertEqual(internalPerms, 0o700, ".nanoteams/internal POSIX permissions must be 0o700 (got \(String(internalPerms, radix: 8)))")
        XCTAssertEqual(gitPerms, 0o700, "snapshots.git POSIX permissions must be 0o700 (got \(String(gitPerms, radix: 8)))")

        let configFile = snapshotsGit.appendingPathComponent("config")
        let configContent = try String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(configContent.contains("sharedRepository = 0600") || configContent.contains("sharedrepository = 0600") || configContent.contains("sharedRepository = 600"), "config should have sharedRepository: \(configContent)")
    }

    /// Feature 7: Reading or cleaning a missing repository never auto-initializes snapshots.git and returns SNAPSHOTS_UNAVAILABLE.
    func testDiffChangesAndCleanup_missingRepo_neverInitializesRepository() async throws {
        let snapshotsGit = tempDir.appendingPathComponent(".nanoteams/internal/snapshots.git")
        XCTAssertFalse(fileManager.fileExists(atPath: snapshotsGit.path))

        // 1. listTaskRefs on missing repo returns []
        let refs = try await service.listTaskRefs(workFolder: tempDir, taskID: 999)
        XCTAssertEqual(refs, [])
        XCTAssertFalse(fileManager.fileExists(atPath: snapshotsGit.path), "listTaskRefs must not create snapshots.git")

        // 2. cleanupTask on missing repo is a no-op
        try await service.cleanupTask(workFolder: tempDir, taskID: 999)
        XCTAssertFalse(fileManager.fileExists(atPath: snapshotsGit.path), "cleanupTask must not create snapshots.git")

        // 3. diffChanges on missing repo throws SNAPSHOTS_UNAVAILABLE
        do {
            _ = try await service.diffChanges(
                workFolder: tempDir,
                folderID: "folder-missing",
                taskID: 999,
                round: 1,
                page: 1,
                pageSize: 50,
                filePath: nil
            )
            XCTFail("diffChanges on missing repo must throw SNAPSHOTS_UNAVAILABLE")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .snapshotsUnavailable, "Error code must be SNAPSHOTS_UNAVAILABLE")
            XCTAssertEqual(err.details?["reason"], "none_taken")
            XCTAssertEqual(err.next?.suggested_cmd, "task_log")
        }
        XCTAssertFalse(fileManager.fileExists(atPath: snapshotsGit.path), "diffChanges must not create snapshots.git")
    }

    /// S7(b), F6 2026-11-12: the LIVE path — no end snapshot, so `task_changes` stages the work
    /// tree itself — over embedded repositories whose own config names an fsmonitor hook and whose
    /// work trees are dirty: one there at the round's start, one created during it. Until then
    /// this case took a review snapshot first, and the diff ran tree to tree — a path that never
    /// looks into an embedded repository on any code. The control at the end runs `git status`
    /// in the embedded repository: it DOES run the hook, so the trap is armed.
    func testSnapshot_embeddedRepoWithMaliciousFsmonitor_liveDiff_neverExecutes() async throws {
        let markerFile = tempDir.appendingPathComponent("fsmonitor_pwned.txt")
        let scriptFile = tempDir.appendingPathComponent("evil_fsmonitor.sh")
        try "#!/bin/sh\necho PWNED > \"\(markerFile.path)\"\n".write(to: scriptFile, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)

        func makeEmbeddedRepository(_ name: String) throws -> URL {
            let dir = tempDir.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try ProcessRunner.runGit(["init", "-q"], in: dir)
            try "sub content".write(to: dir.appendingPathComponent("sub.txt"), atomically: true, encoding: .utf8)
            _ = try ProcessRunner.runGit(["add", "."], in: dir)
            _ = try ProcessRunner.runGit(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", "sub"], in: dir)
            _ = try ProcessRunner.runGit(["config", "core.fsmonitor", scriptFile.path], in: dir)
            try "dirty".write(to: dir.appendingPathComponent("sub.txt"), atomically: true, encoding: .utf8)
            return dir
        }

        let fileA = tempDir.appendingPathComponent("fileA.txt")
        try "initial content".write(to: fileA, atomically: true, encoding: .utf8)
        let atStart = try makeEmbeddedRepository("sub")
        try await service.takeSnapshot(workFolder: tempDir, taskID: 1, round: 1, phase: .start)
        _ = try makeEmbeddedRepository("later")
        try "modified".write(to: fileA, atomically: true, encoding: .utf8)
        try? fileManager.removeItem(at: markerFile)

        let live = try await service.diffChanges(
            workFolder: tempDir, folderID: "folder-1", taskID: 1, round: 1, page: 1, pageSize: 50, filePath: nil
        )
        XCTAssertFalse(fileManager.fileExists(atPath: markerFile.path), "Malicious fsmonitor in embedded repo must never execute")
        XCTAssertEqual(live.files.map(\.path), ["fileA.txt"])
        XCTAssertEqual(Set(live.not_tracked.map(\.path)), ["sub", "later"])

        // Control: the hook is live — the person's own git in that repository runs it.
        _ = try ProcessRunner.runGit(["status", "--porcelain"], in: atStart)
        XCTAssertTrue(fileManager.fileExists(atPath: markerFile.path), "control: git status must run the fsmonitor hook")
    }

    /// Feature 4: Embedded repo without a commit checked out is excluded and does not break snapshot creation.
    func testSnapshot_embeddedRepoWithoutCommit_isExcludedAndSucceeds() async throws {
        let fileA = tempDir.appendingPathComponent("fileA.txt")
        try "initial content".write(to: fileA, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 2, round: 1, phase: .start)

        let uncommittedSub = tempDir.appendingPathComponent("uncommitted_sub", isDirectory: true)
        try fileManager.createDirectory(at: uncommittedSub, withIntermediateDirectories: true)
        _ = try ProcessRunner.runGit(["init"], in: uncommittedSub)
        try "uncommitted file".write(to: uncommittedSub.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 2, round: 1, phase: .review)
        let diff = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "folder-2",
            taskID: 2,
            round: 1,
            page: 1,
            pageSize: 50,
            filePath: nil
        )
        XCTAssertFalse(diff.files.contains { $0.path.contains("uncommitted_sub") }, "Embedded repo must be excluded from snapshots")
    }

    /// Feature 5: Sensitive credentials (.ssh, tokens) in work folder are excluded from snapshots via SandboxPathResolver parity.
    func testSnapshot_workFolderWithHiddenCredentials_excludesSensitiveFiles() async throws {
        let fakeHome = tempDir.appendingPathComponent("fake_home", isDirectory: true)
        let sshDir = fakeHome.appendingPathComponent(".ssh", isDirectory: true)
        try fileManager.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let idRsa = sshDir.appendingPathComponent("id_rsa")
        try "-----BEGIN OPENSSH PRIVATE KEY-----\nMYSENSITIVEKEY\n-----END OPENSSH PRIVATE KEY-----".write(to: idRsa, atomically: true, encoding: .utf8)

        let normalFile = fakeHome.appendingPathComponent("main.swift")
        try "print(1)".write(to: normalFile, atomically: true, encoding: .utf8)

        let homeService = TaskSnapshotService(home: fakeHome)

        // 1. Snapshotting a protected work folder where hidesRoot is true must throw permissionDenied
        do {
            try await homeService.takeSnapshot(workFolder: sshDir, taskID: 99, round: 1, phase: .start)
            XCTFail("takeSnapshot on protectedWorkFolder must throw permissionDenied")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .permissionDenied)
        }

        // 2. Snapshotting the home directory must exclude hidden relative credentials
        try await homeService.takeSnapshot(workFolder: fakeHome, taskID: 3, round: 1, phase: .start)
        try "-----BEGIN OPENSSH PRIVATE KEY-----\nMODIFIEDKEY\n-----END OPENSSH PRIVATE KEY-----".write(to: idRsa, atomically: true, encoding: .utf8)
        try "print(2)".write(to: normalFile, atomically: true, encoding: .utf8)
        try await homeService.takeSnapshot(workFolder: fakeHome, taskID: 3, round: 1, phase: .review)

        let diff = try await homeService.diffChanges(
            workFolder: fakeHome,
            folderID: "folder-3",
            taskID: 3,
            round: 1,
            page: 1,
            pageSize: 50,
            filePath: nil
        )

        XCTAssertFalse(diff.diff.contains("MODIFIEDKEY"), "Sensitive keys must not appear in snapshot diff")
        XCTAssertFalse(diff.files.contains { $0.path.contains(".ssh") }, "Sensitive .ssh files must be excluded from snapshot diff")
    }

    /// Feature 3: Malicious hooks planted in snapshots.git/hooks are never executed by private git invocations.
    func testSnapshot_maliciousHookInSnapshotsGit_neverExecutes() async throws {
        let normalFile = tempDir.appendingPathComponent("main.swift")
        try "print(1)".write(to: normalFile, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 4, round: 1, phase: .start)

        let snapshotsGit = tempDir.appendingPathComponent(".nanoteams/internal/snapshots.git")
        let hooksDir = snapshotsGit.appendingPathComponent("hooks", isDirectory: true)
        try fileManager.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let markerFile = tempDir.appendingPathComponent("hook_pwned.txt")
        let evilHook = hooksDir.appendingPathComponent("reference-transaction")
        try "#!/bin/sh\necho PWNED > \"\(markerFile.path)\"\n".write(to: evilHook, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: evilHook.path)

        try "print(2)".write(to: normalFile, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 4, round: 1, phase: .review)
        _ = try await service.cleanupTask(workFolder: tempDir, taskID: 4)

        XCTAssertFalse(fileManager.fileExists(atPath: markerFile.path), "reference-transaction hook in snapshots.git must never execute")
    }

    // MARK: - Wave F2 Tests (Features 12, 16, 18, 19, 20 / §3.2, §3.4, §3.6, §3.7, §3.8, §3.9)

    func testPerFolderLock_staleLockCleanup_removesIndexLockAndSucceeds() async throws {
        let file = tempDir.appendingPathComponent("stale_test.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        // Initial snapshot to create snapshots.git
        try await service.takeSnapshot(workFolder: tempDir, taskID: 301, runID: 1, round: 1, phase: .start)

        let snapshotsGit = tempDir.appendingPathComponent(".nanoteams/internal/snapshots.git")
        let staleLock = snapshotsGit.appendingPathComponent("index.lock")
        try "fake lock pid 99999".write(to: staleLock, atomically: true, encoding: .utf8)
        XCTAssertTrue(fileManager.fileExists(atPath: staleLock.path))

        // Next snapshot should automatically detect and remove index.lock under folder lock
        try await service.takeSnapshot(workFolder: tempDir, taskID: 301, runID: 1, round: 1, phase: .review)
        XCTAssertFalse(fileManager.fileExists(atPath: staleLock.path), "stale index.lock must be cleaned up on lock acquisition")
    }

    func testRunScopedRefs_secondRunWithoutExplicitRound_resolvesRound1OfRun2() async throws {
        let file = tempDir.appendingPathComponent("scoped_test.txt")
        try "run1 content".write(to: file, atomically: true, encoding: .utf8)

        // Run 1, Round 1
        try await service.takeSnapshot(workFolder: tempDir, taskID: 401, runID: 1, round: 1, phase: .start)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 401, runID: 1, round: 1, phase: .review)

        // Run 1, Round 2
        try await service.takeSnapshot(workFolder: tempDir, taskID: 401, runID: 1, round: 2, phase: .start)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 401, runID: 1, round: 2, phase: .review)

        // Run 2, Round 1 starts
        try "run2 content".write(to: file, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 401, runID: 2, round: 1, phase: .start)

        // Query diffChanges for Run 2 without specifying round. Must resolve to Round 1 of Run 2 (not Round 2 of Run 1!)
        let diff = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-folder",
            taskID: 401,
            runID: 2,
            round: nil,
            page: 1,
            pageSize: 10,
            filePath: nil
        )

        XCTAssertEqual(diff.round, 1, "diffChanges without round for run 2 must resolve to run 2's latest round (1)")
    }

    func testDiffChanges_cyrillicPaths_handledLosslesslyWithQuotePathFalse() async throws {
        let dir = tempDir.appendingPathComponent("Планы", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let cyrillicFile = dir.appendingPathComponent("отчет.md")
        try "# Черновик".write(to: cyrillicFile, atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 501, runID: 1, round: 1, phase: .start)

        try "# Готовый отчет\nВыполнены все пункты.".write(to: cyrillicFile, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 501, runID: 1, round: 1, phase: .review)

        let diff = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-folder",
            taskID: 501,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )

        XCTAssertEqual(diff.files.count, 1)
        XCTAssertEqual(diff.files.first?.path, "Планы/отчет.md", "Cyrillic file path must be unquoted and lossless")
        XCTAssertFalse(diff.files.first?.path.contains("\\") ?? true, "Must not contain C-escape octal sequences")
        XCTAssertTrue(diff.diff.contains("Готовый отчет"))
    }

    func testDiffChanges_fileRenames_reportsRenamedWithOldPath() async throws {
        let oldFile = tempDir.appendingPathComponent("original_name.swift")
        try "struct Sample {}".write(to: oldFile, atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 601, runID: 1, round: 1, phase: .start)

        let newFile = tempDir.appendingPathComponent("renamed_name.swift")
        try fileManager.moveItem(at: oldFile, to: newFile)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 601, runID: 1, round: 1, phase: .review)

        let diff = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-folder",
            taskID: 601,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )

        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.change_type, "renamed")
        XCTAssertEqual(file.path, "renamed_name.swift")
        XCTAssertEqual(file.old_path, "original_name.swift")

        // Assert git diff -M renders rename headers due to :(literal)<old_path> in pagePaths
        XCTAssertTrue(diff.diff.contains("rename from original_name.swift"), "Diff must contain 'rename from' header")
        XCTAssertTrue(diff.diff.contains("rename to renamed_name.swift"), "Diff must contain 'rename to' header")
        XCTAssertFalse(diff.diff.contains("new file mode"), "Renamed file must not be rendered as newly created")
    }

    func testExclusionParity_respectsGitInfoExclude() async throws {
        // Initialize git in workFolder to test .git/info/exclude mirroring
        let gitInit = try ProcessRunner.runGit(["init"], in: tempDir)
        XCTAssertTrue(gitInit.success)

        let infoDir = tempDir.appendingPathComponent(".git/info", isDirectory: true)
        try fileManager.createDirectory(at: infoDir, withIntermediateDirectories: true)
        let excludeFile = infoDir.appendingPathComponent("exclude")
        try "worktrees_custom/\n*.secret\n".write(to: excludeFile, atomically: true, encoding: .utf8)

        let normalFile = tempDir.appendingPathComponent("normal.txt")
        try "hello".write(to: normalFile, atomically: true, encoding: .utf8)

        let secretFile = tempDir.appendingPathComponent("key.secret")
        try "secret123".write(to: secretFile, atomically: true, encoding: .utf8)

        let customDir = tempDir.appendingPathComponent("worktrees_custom", isDirectory: true)
        try fileManager.createDirectory(at: customDir, withIntermediateDirectories: true)
        try "ignored tree".write(to: customDir.appendingPathComponent("tree.txt"), atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 701, runID: 1, round: 1, phase: .start)

        let diff = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-folder",
            taskID: 701,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )

        let paths = diff.files.map(\.path)
        XCTAssertFalse(paths.contains("key.secret"), ".git/info/exclude *.secret must be respected")
        XCTAssertFalse(paths.contains(where: { $0.contains("worktrees_custom") }), "worktrees_custom must be excluded")
    }

    func testExclusionParity_previouslyTrackedFileNowIgnored_clearedFromIndex() async throws {
        let normal = tempDir.appendingPathComponent("config.json")
        try "{ \"env\": \"dev\" }".write(to: normal, atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 801, runID: 1, round: 1, phase: .start)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 801, runID: 1, round: 1, phase: .review)

        // Add to .gitignore before round 2
        let gitignore = tempDir.appendingPathComponent(".gitignore")
        try "config.json\n".write(to: gitignore, atomically: true, encoding: .utf8)
        try "{ \"env\": \"production\" }".write(to: normal, atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 801, runID: 1, round: 2, phase: .start)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 801, runID: 1, round: 2, phase: .review)

        let diffRound2 = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-folder",
            taskID: 801,
            runID: 1,
            round: 2,
            page: 1,
            pageSize: 10,
            filePath: nil
        )

        // config.json should not appear as modified in round 2 because it is now ignored
        XCTAssertFalse(
            diffRound2.files.contains(where: { $0.path == "config.json" && $0.change_type == "modified" }),
            "Newly ignored config.json must not appear as modified in snapshot"
        )
    }

    func testDiffChanges_fileRenames_filterByFilePath_supportsBothOldAndNewPaths() async throws {
        let oldFile = tempDir.appendingPathComponent("InitialName.swift")
        try "class InitialService {}".write(to: oldFile, atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 602, runID: 1, round: 1, phase: .start)

        let newFile = tempDir.appendingPathComponent("FinalName.swift")
        try fileManager.moveItem(at: oldFile, to: newFile)

        // 1. Query with new path
        let diffNew = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-folder",
            taskID: 602,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: "FinalName.swift"
        )
        XCTAssertEqual(diffNew.files.count, 1)
        XCTAssertEqual(diffNew.files.first?.path, "FinalName.swift")
        XCTAssertEqual(diffNew.files.first?.old_path, "InitialName.swift")
        XCTAssertTrue(diffNew.diff.contains("rename from InitialName.swift"))
        XCTAssertTrue(diffNew.diff.contains("rename to FinalName.swift"))

        // 2. Query with old path
        let diffOld = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-folder",
            taskID: 602,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: "InitialName.swift"
        )
        XCTAssertEqual(diffOld.files.count, 1)
        XCTAssertEqual(diffOld.files.first?.path, "FinalName.swift")
        XCTAssertEqual(diffOld.files.first?.old_path, "InitialName.swift")
        XCTAssertTrue(diffOld.diff.contains("rename from InitialName.swift"))
        XCTAssertTrue(diffOld.diff.contains("rename to FinalName.swift"))
    }

    func testExclusionParity_gitWorktree_respectsCommonGitInfoExclude() async throws {
        // Set up a primary git repo with an initial commit
        let mainRepo = tempDir.appendingPathComponent("main_repo", isDirectory: true)
        try fileManager.createDirectory(at: mainRepo, withIntermediateDirectories: true)

        let initRes = try ProcessRunner.runGit(["init"], in: mainRepo)
        XCTAssertTrue(initRes.success)
        _ = try ProcessRunner.runGit(["config", "user.name", "TestUser"], in: mainRepo)
        _ = try ProcessRunner.runGit(["config", "user.email", "test@example.com"], in: mainRepo)

        let initialFile = mainRepo.appendingPathComponent("initial.txt")
        try "initial content".write(to: initialFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.runGit(["add", "initial.txt"], in: mainRepo)
        let commitRes = try ProcessRunner.runGit(["commit", "-m", "init"], in: mainRepo)
        XCTAssertTrue(commitRes.success)

        // Write exclusion patterns into mainRepo's .git/info/exclude
        let infoDir = mainRepo.appendingPathComponent(".git/info", isDirectory: true)
        try fileManager.createDirectory(at: infoDir, withIntermediateDirectories: true)
        let excludeFile = infoDir.appendingPathComponent("exclude")
        try "worktree_ignored/\n*.worktree_secret\n".write(to: excludeFile, atomically: true, encoding: .utf8)

        // Create a git worktree
        let worktreeFolder = tempDir.appendingPathComponent("wt_folder", isDirectory: true)
        let wtRes = try ProcessRunner.runGit(["worktree", "add", worktreeFolder.path], in: mainRepo)
        XCTAssertTrue(wtRes.success, "git worktree add must succeed")

        // Verify .git in worktree is a file, not a directory
        var isDir: ObjCBool = false
        let dotGit = worktreeFolder.appendingPathComponent(".git")
        XCTAssertTrue(fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDir))
        XCTAssertFalse(isDir.boolValue, "worktree .git must be a regular file")

        // Take start snapshot in the worktree before round edits
        try await service.takeSnapshot(workFolder: worktreeFolder, taskID: 703, runID: 1, round: 1, phase: .start)

        // Add tracked and ignored files in the worktree
        let regularFile = worktreeFolder.appendingPathComponent("normal.txt")
        try "regular data".write(to: regularFile, atomically: true, encoding: .utf8)

        let secretFile = worktreeFolder.appendingPathComponent("access.worktree_secret")
        try "secret data".write(to: secretFile, atomically: true, encoding: .utf8)

        let ignoredDir = worktreeFolder.appendingPathComponent("worktree_ignored", isDirectory: true)
        try fileManager.createDirectory(at: ignoredDir, withIntermediateDirectories: true)
        try "nested data".write(to: ignoredDir.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)

        let diff = try await service.diffChanges(
            workFolder: worktreeFolder,
            folderID: "test-wt-folder",
            taskID: 703,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )

        let paths = diff.files.map(\.path)
        XCTAssertTrue(paths.contains("normal.txt"), "normal.txt must be tracked in snapshot")
        XCTAssertFalse(paths.contains("access.worktree_secret"), "*.worktree_secret in common info/exclude must be excluded")
        XCTAssertFalse(paths.contains(where: { $0.contains("worktree_ignored") }), "worktree_ignored/ in common info/exclude must be excluded")
    }

    func testExclusionParity_gitWorktree_relativeGitdirAndCommondir() async throws {
        let baseDir = tempDir.appendingPathComponent("relative_test", isDirectory: true)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let mainGitDir = baseDir.appendingPathComponent("main.git", isDirectory: true)
        let mainInfoDir = mainGitDir.appendingPathComponent("info", isDirectory: true)
        try fileManager.createDirectory(at: mainInfoDir, withIntermediateDirectories: true)
        try "*.rel_secret\n".write(to: mainInfoDir.appendingPathComponent("exclude"), atomically: true, encoding: .utf8)

        let wtGitDir = mainGitDir.appendingPathComponent("worktrees/wt1", isDirectory: true)
        try fileManager.createDirectory(at: wtGitDir, withIntermediateDirectories: true)
        try "../..\n".write(to: wtGitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)

        let wtWorkFolder = baseDir.appendingPathComponent("wt1_work", isDirectory: true)
        try fileManager.createDirectory(at: wtWorkFolder, withIntermediateDirectories: true)
        try "gitdir: ../main.git/worktrees/wt1\n".write(to: wtWorkFolder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: wtWorkFolder, taskID: 704, runID: 1, round: 1, phase: .start)

        let regularFile = wtWorkFolder.appendingPathComponent("file.txt")
        try "hello".write(to: regularFile, atomically: true, encoding: .utf8)

        let secretFile = wtWorkFolder.appendingPathComponent("api.rel_secret")
        try "secret".write(to: secretFile, atomically: true, encoding: .utf8)

        let diff = try await service.diffChanges(
            workFolder: wtWorkFolder,
            folderID: "test-rel-folder",
            taskID: 704,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )

        let paths = diff.files.map(\.path)
        XCTAssertTrue(paths.contains("file.txt"))
        XCTAssertFalse(paths.contains("api.rel_secret"))
    }

    // MARK: - Adversarial Challenge Tests (Rename Diffs & Worktree Exclude Stress)

    func testAdversarial_renameDiff_withContentEdits_preservesSimilarityHeaders() async throws {
        let initialLines = (1...50).map { "Line \($0): standard implementation code details for service." }.joined(separator: "\n")
        let oldFile = tempDir.appendingPathComponent("SourceService.swift")
        try initialLines.write(to: oldFile, atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 1101, runID: 1, round: 1, phase: .start)

        let newFile = tempDir.appendingPathComponent("TargetService.swift")
        try fileManager.moveItem(at: oldFile, to: newFile)

        // Modify 3 lines out of 50 (~94% similarity)
        var modifiedLines = (1...50).map { "Line \($0): standard implementation code details for service." }
        modifiedLines[10] = "Line 11: REVISED implementation details for service."
        modifiedLines[20] = "Line 21: REVISED implementation details for service."
        modifiedLines[30] = "Line 31: REVISED implementation details for service."
        try modifiedLines.joined(separator: "\n").write(to: newFile, atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 1101, runID: 1, round: 1, phase: .review)

        let diff = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-adv-rename",
            taskID: 1101,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )

        XCTAssertEqual(diff.files.count, 1)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.change_type, "renamed")
        XCTAssertEqual(file.path, "TargetService.swift")
        XCTAssertEqual(file.old_path, "SourceService.swift")

        // Git diff -M must render similarity headers and hunk, not treat as /dev/null
        XCTAssertTrue(diff.diff.contains("similarity index"), "Must contain similarity index")
        XCTAssertTrue(diff.diff.contains("rename from SourceService.swift"), "Must contain rename from")
        XCTAssertTrue(diff.diff.contains("rename to TargetService.swift"), "Must contain rename to")
        XCTAssertTrue(diff.diff.contains("+Line 11: REVISED implementation details for service."))
        XCTAssertFalse(diff.diff.contains("--- /dev/null"), "Must not treat renamed file as new file from /dev/null")
        XCTAssertFalse(diff.diff.contains("+++ /dev/null"), "Must not treat renamed file as deleted to /dev/null")
    }

    func testAdversarial_renameDiff_unicodeAndSpacesAndSymbols() async throws {
        let nestedDir = tempDir.appendingPathComponent("Документы", isDirectory: true)
        try fileManager.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let oldFile = nestedDir.appendingPathComponent("Общий План [v1].txt")
        let lines = (1...20).map { "Раздел \($0): описание архитектуры и компонентов." }.joined(separator: "\n")
        try lines.write(to: oldFile, atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 1102, runID: 1, round: 1, phase: .start)

        let targetDir = tempDir.appendingPathComponent("Архивы & Отчеты", isDirectory: true)
        try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let newFile = targetDir.appendingPathComponent("Общий План [v2 final].txt")
        try fileManager.moveItem(at: oldFile, to: newFile)

        // Slight edit (~90% similarity)
        var modLines = (1...20).map { "Раздел \($0): описание архитектуры и компонентов." }
        modLines[5] = "Раздел 6: обновленная архитектура компонентов."
        try modLines.joined(separator: "\n").write(to: newFile, atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 1102, runID: 1, round: 1, phase: .review)

        // 1. Query all
        let diffAll = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-unicode",
            taskID: 1102,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )
        XCTAssertEqual(diffAll.files.count, 1)
        let f = try XCTUnwrap(diffAll.files.first)
        XCTAssertEqual(f.change_type, "renamed")
        XCTAssertEqual(f.path, "Архивы & Отчеты/Общий План [v2 final].txt")
        XCTAssertEqual(f.old_path, "Документы/Общий План [v1].txt")
        XCTAssertTrue(diffAll.diff.contains("rename from Документы/Общий План [v1].txt"))
        XCTAssertTrue(diffAll.diff.contains("rename to Архивы & Отчеты/Общий План [v2 final].txt"))

        // 2. Query with old path filter
        let diffOld = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-unicode",
            taskID: 1102,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: "Документы/Общий План [v1].txt"
        )
        XCTAssertEqual(diffOld.files.count, 1)
        XCTAssertTrue(diffOld.diff.contains("rename from Документы/Общий План [v1].txt"))

        // 3. Query with new path filter
        let diffNew = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-unicode",
            taskID: 1102,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: "Архивы & Отчеты/Общий План [v2 final].txt"
        )
        XCTAssertEqual(diffNew.files.count, 1)
        XCTAssertTrue(diffNew.diff.contains("rename to Архивы & Отчеты/Общий План [v2 final].txt"))
    }

    func testAdversarial_renameDiff_liveDiffWithoutCommittedRef() async throws {
        let initialCode = (1...30).map { "Item \($0): config payload data." }.joined(separator: "\n")
        let oldFile = tempDir.appendingPathComponent("OldWorker.swift")
        try initialCode.write(to: oldFile, atomically: true, encoding: .utf8)

        let toDeleteFile = tempDir.appendingPathComponent("ToTrash.swift")
        try "delete me".write(to: toDeleteFile, atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 1103, runID: 1, round: 1, phase: .start)

        // Perform changes in work tree without review snapshot
        let newFile = tempDir.appendingPathComponent("NewWorker.swift")
        try fileManager.moveItem(at: oldFile, to: newFile)
        try fileManager.removeItem(at: toDeleteFile)

        let untrackedFile = tempDir.appendingPathComponent("Untracked.swift")
        try "untracked content".write(to: untrackedFile, atomically: true, encoding: .utf8)

        // Query live diff (no review snapshot taken)
        let liveDiff = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-live",
            taskID: 1103,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )

        let paths = liveDiff.files.map(\.path)
        XCTAssertTrue(paths.contains("NewWorker.swift"))
        XCTAssertTrue(paths.contains("ToTrash.swift"))
        XCTAssertTrue(paths.contains("Untracked.swift"))

        let renamedItem = try XCTUnwrap(liveDiff.files.first(where: { $0.path == "NewWorker.swift" }))
        XCTAssertEqual(renamedItem.change_type, "renamed")
        XCTAssertEqual(renamedItem.old_path, "OldWorker.swift")

        XCTAssertTrue(liveDiff.diff.contains("rename from OldWorker.swift"))
        XCTAssertTrue(liveDiff.diff.contains("rename to NewWorker.swift"))
        XCTAssertFalse(liveDiff.diff.contains("new file mode 100644\n--- /dev/null\n+++ b/NewWorker.swift"))
    }

    func testAdversarial_renameDiff_chainedAndMultipleSimultaneousRenames() async throws {
        let content1 = (1...30).map { "Chain item line \($0)" }.joined(separator: "\n")
        let content2 = (1...30).map { "Alpha file line \($0)" }.joined(separator: "\n")

        let chainStart = tempDir.appendingPathComponent("chain_start.txt")
        let alpha = tempDir.appendingPathComponent("alpha.txt")
        try content1.write(to: chainStart, atomically: true, encoding: .utf8)
        try content2.write(to: alpha, atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 1104, runID: 1, round: 1, phase: .start)

        // 1. Chained rename: chain_start -> chain_mid -> chain_final
        let chainMid = tempDir.appendingPathComponent("chain_mid.txt")
        let chainFinal = tempDir.appendingPathComponent("chain_final.txt")
        try fileManager.moveItem(at: chainStart, to: chainMid)
        try fileManager.moveItem(at: chainMid, to: chainFinal)

        // 2. Simultaneous rename: alpha -> omega
        let omega = tempDir.appendingPathComponent("omega.txt")
        try fileManager.moveItem(at: alpha, to: omega)

        try await service.takeSnapshot(workFolder: tempDir, taskID: 1104, runID: 1, round: 1, phase: .review)

        let diff = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-chained-renames",
            taskID: 1104,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )

        XCTAssertEqual(diff.files.count, 2)
        for f in diff.files {
            XCTAssertEqual(f.change_type, "renamed")
        }

        let itemChain = try XCTUnwrap(diff.files.first(where: { $0.path == "chain_final.txt" }))
        XCTAssertEqual(itemChain.old_path, "chain_start.txt")

        let itemOmega = try XCTUnwrap(diff.files.first(where: { $0.path == "omega.txt" }))
        XCTAssertEqual(itemOmega.old_path, "alpha.txt")

        XCTAssertTrue(diff.diff.contains("rename from chain_start.txt"))
        XCTAssertTrue(diff.diff.contains("rename to chain_final.txt"))
        XCTAssertTrue(diff.diff.contains("rename from alpha.txt"))
        XCTAssertTrue(diff.diff.contains("rename to omega.txt"))
    }

    func testAdversarial_renameDiff_paginationWithMultipleRenamesAndFiltering() async throws {
        // Create 4 files to test 2 pages with pageSize 2
        for i in 1...4 {
            let f = tempDir.appendingPathComponent("file_\(i).txt")
            let content = (1...20).map { "File \(i) content line \($0)" }.joined(separator: "\n")
            try content.write(to: f, atomically: true, encoding: .utf8)
        }

        try await service.takeSnapshot(workFolder: tempDir, taskID: 1105, runID: 1, round: 1, phase: .start)

        for i in 1...4 {
            let oldF = tempDir.appendingPathComponent("file_\(i).txt")
            let newF = tempDir.appendingPathComponent("renamed_\(i).txt")
            try fileManager.moveItem(at: oldF, to: newF)
        }

        try await service.takeSnapshot(workFolder: tempDir, taskID: 1105, runID: 1, round: 1, phase: .review)

        // Page 1 (pageSize 2)
        let page1 = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-pagination",
            taskID: 1105,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 2,
            filePath: nil
        )
        XCTAssertEqual(page1.total_pages, 2)
        XCTAssertEqual(page1.files.count, 4) // files list contains full matched set
        XCTAssertTrue(page1.diff.contains("rename from file_1.txt"))
        XCTAssertTrue(page1.diff.contains("rename to renamed_1.txt"))
        XCTAssertTrue(page1.diff.contains("rename from file_2.txt"))
        XCTAssertTrue(page1.diff.contains("rename to renamed_2.txt"))
        XCTAssertFalse(page1.diff.contains("rename from file_3.txt"))

        // Page 2 (pageSize 2)
        let page2 = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-pagination",
            taskID: 1105,
            runID: 1,
            round: 1,
            page: 2,
            pageSize: 2,
            filePath: nil
        )
        XCTAssertTrue(page2.diff.contains("rename from file_3.txt"))
        XCTAssertTrue(page2.diff.contains("rename to renamed_3.txt"))
        XCTAssertTrue(page2.diff.contains("rename from file_4.txt"))
        XCTAssertTrue(page2.diff.contains("rename to renamed_4.txt"))
        XCTAssertFalse(page2.diff.contains("rename from file_1.txt"))

        // Filter by old path "file_3.txt"
        let filteredOld = try await service.diffChanges(
            workFolder: tempDir,
            folderID: "test-pagination",
            taskID: 1105,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 2,
            filePath: "file_3.txt"
        )
        XCTAssertEqual(filteredOld.files.count, 1)
        XCTAssertEqual(filteredOld.files.first?.path, "renamed_3.txt")
        XCTAssertEqual(filteredOld.files.first?.old_path, "file_3.txt")
        XCTAssertTrue(filteredOld.diff.contains("rename from file_3.txt"))
        XCTAssertTrue(filteredOld.diff.contains("rename to renamed_3.txt"))
    }

    func testAdversarial_worktreeExcludes_crlfAndCommentsAndWhitespace() async throws {
        let baseDir = tempDir.appendingPathComponent("crlf_worktree", isDirectory: true)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let mainGitDir = baseDir.appendingPathComponent("main.git", isDirectory: true)
        let mainInfoDir = mainGitDir.appendingPathComponent("info", isDirectory: true)
        try fileManager.createDirectory(at: mainInfoDir, withIntermediateDirectories: true)
        try "*.crlf_secret\r\n# ignore logs\r\nlogs_dir/\r\n".write(to: mainInfoDir.appendingPathComponent("exclude"), atomically: true, encoding: .utf8)

        let wtGitDir = mainGitDir.appendingPathComponent("worktrees/wt_crlf", isDirectory: true)
        try fileManager.createDirectory(at: wtGitDir, withIntermediateDirectories: true)
        // commondir with CRLF and trailing spaces
        try "  ../..  \r\n".write(to: wtGitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)

        let wtWorkFolder = baseDir.appendingPathComponent("wt_work_crlf", isDirectory: true)
        try fileManager.createDirectory(at: wtWorkFolder, withIntermediateDirectories: true)
        // .git file with comment and CRLF
        let dotGitContent = "# git worktree reference\r\ngitdir:   ../main.git/worktrees/wt_crlf  \r\n"
        try dotGitContent.write(to: wtWorkFolder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: wtWorkFolder, taskID: 1201, runID: 1, round: 1, phase: .start)

        let regular = wtWorkFolder.appendingPathComponent("normal.txt")
        try "data".write(to: regular, atomically: true, encoding: .utf8)

        let secret = wtWorkFolder.appendingPathComponent("app.crlf_secret")
        try "sensitive".write(to: secret, atomically: true, encoding: .utf8)

        let logsDir = wtWorkFolder.appendingPathComponent("logs_dir", isDirectory: true)
        try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try "log1".write(to: logsDir.appendingPathComponent("app.log"), atomically: true, encoding: .utf8)

        let diff = try await service.diffChanges(
            workFolder: wtWorkFolder,
            folderID: "test-crlf",
            taskID: 1201,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )

        let paths = diff.files.map(\.path)
        XCTAssertTrue(paths.contains("normal.txt"))
        XCTAssertFalse(paths.contains("app.crlf_secret"))
        XCTAssertFalse(paths.contains(where: { $0.contains("logs_dir") }))
    }

    func testAdversarial_worktreeExcludes_bothCommondirAndDirectGitdirExcludes() async throws {
        let baseDir = tempDir.appendingPathComponent("dual_exclude_wt", isDirectory: true)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let mainGitDir = baseDir.appendingPathComponent("main.git", isDirectory: true)
        let mainInfoDir = mainGitDir.appendingPathComponent("info", isDirectory: true)
        try fileManager.createDirectory(at: mainInfoDir, withIntermediateDirectories: true)
        try "*.commondir_secret\n".write(to: mainInfoDir.appendingPathComponent("exclude"), atomically: true, encoding: .utf8)

        let wtGitDir = mainGitDir.appendingPathComponent("worktrees/wt_dual", isDirectory: true)
        let wtInfoDir = wtGitDir.appendingPathComponent("info", isDirectory: true)
        try fileManager.createDirectory(at: wtInfoDir, withIntermediateDirectories: true)
        try "*.wt_local_secret\n".write(to: wtInfoDir.appendingPathComponent("exclude"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: wtGitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)

        let wtWorkFolder = baseDir.appendingPathComponent("wt_work_dual", isDirectory: true)
        try fileManager.createDirectory(at: wtWorkFolder, withIntermediateDirectories: true)
        try "gitdir: ../main.git/worktrees/wt_dual\n".write(to: wtWorkFolder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: wtWorkFolder, taskID: 1202, runID: 1, round: 1, phase: .start)

        let regular = wtWorkFolder.appendingPathComponent("normal.txt")
        try "hello".write(to: regular, atomically: true, encoding: .utf8)

        let commonSecret = wtWorkFolder.appendingPathComponent("token.commondir_secret")
        try "secret-common".write(to: commonSecret, atomically: true, encoding: .utf8)

        let localSecret = wtWorkFolder.appendingPathComponent("token.wt_local_secret")
        try "secret-local".write(to: localSecret, atomically: true, encoding: .utf8)

        let diff = try await service.diffChanges(
            workFolder: wtWorkFolder,
            folderID: "test-dual-exclude",
            taskID: 1202,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )

        let paths = diff.files.map(\.path)
        XCTAssertTrue(paths.contains("normal.txt"))
        XCTAssertFalse(paths.contains("token.commondir_secret"), "commondir info/exclude must be respected")
        XCTAssertFalse(paths.contains("token.wt_local_secret"), "wt direct gitdir info/exclude must be respected")
    }

    func testAdversarial_worktreeExcludes_missingCommondirOrMissingExcludeGraceful() async throws {
        let baseDir = tempDir.appendingPathComponent("corrupted_wt", isDirectory: true)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let wtWorkFolder = baseDir.appendingPathComponent("wt_work_corrupt", isDirectory: true)
        try fileManager.createDirectory(at: wtWorkFolder, withIntermediateDirectories: true)

        // Point to a non-existent gitdir
        try "gitdir: ../does_not_exist/worktrees/wt_lost\n".write(to: wtWorkFolder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        // Must not crash or fail initialization
        try await service.takeSnapshot(workFolder: wtWorkFolder, taskID: 1203, runID: 1, round: 1, phase: .start)

        let f = wtWorkFolder.appendingPathComponent("file.txt")
        try "content".write(to: f, atomically: true, encoding: .utf8)

        let diff = try await service.diffChanges(
            workFolder: wtWorkFolder,
            folderID: "test-corrupt",
            taskID: 1203,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )
        XCTAssertEqual(diff.files.count, 1)
        XCTAssertEqual(diff.files.first?.path, "file.txt")
    }

    func testAdversarial_worktreeExcludes_submoduleGitFile() async throws {
        let baseDir = tempDir.appendingPathComponent("submodule_test", isDirectory: true)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let subGitDir = baseDir.appendingPathComponent("main.git/modules/sub1", isDirectory: true)
        let subInfoDir = subGitDir.appendingPathComponent("info", isDirectory: true)
        try fileManager.createDirectory(at: subInfoDir, withIntermediateDirectories: true)
        try "*.sub_secret\n".write(to: subInfoDir.appendingPathComponent("exclude"), atomically: true, encoding: .utf8)

        let subWorkFolder = baseDir.appendingPathComponent("sub1_work", isDirectory: true)
        try fileManager.createDirectory(at: subWorkFolder, withIntermediateDirectories: true)
        // Submodules do not have commondir, their gitdir directly holds info/exclude
        try "gitdir: ../main.git/modules/sub1\n".write(to: subWorkFolder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        try await service.takeSnapshot(workFolder: subWorkFolder, taskID: 1204, runID: 1, round: 1, phase: .start)

        let normal = subWorkFolder.appendingPathComponent("normal.txt")
        try "content".write(to: normal, atomically: true, encoding: .utf8)

        let secret = subWorkFolder.appendingPathComponent("secret.sub_secret")
        try "confidential".write(to: secret, atomically: true, encoding: .utf8)

        let diff = try await service.diffChanges(
            workFolder: subWorkFolder,
            folderID: "test-sub",
            taskID: 1204,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )

        let paths = diff.files.map(\.path)
        XCTAssertTrue(paths.contains("normal.txt"))
        XCTAssertFalse(paths.contains("secret.sub_secret"), "Submodule info/exclude directly under gitdir must be respected")
    }

    // MARK: - Wave Final Coverage Hardening: Legacy Refs & Multi-Run Resolution (M6.1)

    func testDiffChanges_multipleRuns_resolvesLatestRunID() async throws {
        let folder = tempDir.appendingPathComponent("multi-run-repo", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let testFile = folder.appendingPathComponent("doc.txt")
        try "version 1".write(to: testFile, atomically: true, encoding: .utf8)

        let snapshotService = TaskSnapshotService()
        try await snapshotService.takeSnapshot(workFolder: folder, taskID: 10, runID: 1, round: 1, phase: .start)
        try await snapshotService.takeSnapshot(workFolder: folder, taskID: 10, runID: 2, round: 1, phase: .start)

        // Calling without runID should resolve to latest run (run 2 > run 1)
        let changes = try await snapshotService.diffChanges(
            workFolder: folder,
            folderID: "multi-folder",
            taskID: 10,
            runID: nil,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )
        XCTAssertEqual(changes.task_id, 10)
    }

    func testDiffChanges_noSnapshotsTakenForTask_throwsSnapshotsUnavailable() async throws {
        let folder = tempDir.appendingPathComponent("no-snapshots-task", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshotService = TaskSnapshotService()
        _ = try await snapshotService.ensureRepositoryInitialized(in: folder)

        // Task 999 has no refs
        do {
            _ = try await snapshotService.diffChanges(
                workFolder: folder,
                folderID: "empty-folder",
                taskID: 999,
                runID: nil,
                round: nil,
                page: 1,
                pageSize: 10,
                filePath: nil
            )
            XCTFail("Expected snapshotsUnavailable")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .snapshotsUnavailable)
            XCTAssertEqual(err.details?["reason"] as? String, "none_taken")
        }
    }

    func testDiffChanges_protectedWorkFolder_throwsPermissionDenied() async throws {
        let homeDir = tempDir.appendingPathComponent("fake-home", isDirectory: true)
        let protectedDir = homeDir.appendingPathComponent(".claude", isDirectory: true)
        try fileManager.createDirectory(at: protectedDir, withIntermediateDirectories: true)

        let snapshotService = TaskSnapshotService(home: homeDir)
        do {
            _ = try await snapshotService.diffChanges(
                workFolder: protectedDir,
                folderID: "protected",
                taskID: 1,
                runID: 1,
                round: 1,
                page: 1,
                pageSize: 10,
                filePath: nil
            )
            XCTFail("Expected permissionDenied on protected root")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .permissionDenied)
        }

        do {
            _ = try await snapshotService.ensureRepositoryInitialized(in: protectedDir)
            XCTFail("Expected permissionDenied on protected root")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .permissionDenied)
        }
    }

    func testExclusionParity_worktreeAbsoluteCommonDir_andInvalidDotGit() async throws {
        let worktreeFolder = tempDir.appendingPathComponent("abs-worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeFolder, withIntermediateDirectories: true)
        let gitdirFolder = tempDir.appendingPathComponent("main-repo-gitdir", isDirectory: true)
        try fileManager.createDirectory(at: gitdirFolder, withIntermediateDirectories: true)

        let commonInfo = gitdirFolder.appendingPathComponent("info", isDirectory: true)
        try fileManager.createDirectory(at: commonInfo, withIntermediateDirectories: true)
        let commonExclude = commonInfo.appendingPathComponent("exclude")
        try "*.abs-ignored\n".write(to: commonExclude, atomically: true, encoding: .utf8)

        // Worktree gitdir commondir contains an ABSOLUTE path
        let commondirFile = gitdirFolder.appendingPathComponent("commondir")
        try (gitdirFolder.path + "\n").write(to: commondirFile, atomically: true, encoding: .utf8)

        let dotGit = worktreeFolder.appendingPathComponent(".git")
        try "gitdir: \(gitdirFolder.path)\n".write(to: dotGit, atomically: true, encoding: .utf8)

        let ignoredFile = worktreeFolder.appendingPathComponent("file.abs-ignored")
        try "should be excluded".write(to: ignoredFile, atomically: true, encoding: .utf8)

        let snapshotService = TaskSnapshotService()
        try await snapshotService.takeSnapshot(workFolder: worktreeFolder, taskID: 55, runID: 1, round: 1, phase: .start)
        let diff = try await snapshotService.diffChanges(
            workFolder: worktreeFolder,
            folderID: "f",
            taskID: 55,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )
        XCTAssertFalse(diff.files.contains { $0.path.contains("file.abs-ignored") })

        // Test invalid .git file (binary non-UTF8) returns empty exclusions without crash
        let corruptFolder = tempDir.appendingPathComponent("corrupt-git", isDirectory: true)
        try fileManager.createDirectory(at: corruptFolder, withIntermediateDirectories: true)
        let corruptDotGit = corruptFolder.appendingPathComponent(".git")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: corruptDotGit)
        try await snapshotService.takeSnapshot(workFolder: corruptFolder, taskID: 56, runID: 1, round: 1, phase: .start)
    }

    func testTakeSnapshot_readOnlyObjectsDir_throwsCommandFailed() async throws {
        let folder = tempDir.appendingPathComponent("ro-objects", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshotService = TaskSnapshotService()
        let (gitDir, _) = try await snapshotService.ensureRepositoryInitialized(in: folder)
        let objectsDir = gitDir.appendingPathComponent("objects")
        try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: objectsDir.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: objectsDir.path)
        }
        do {
            try await snapshotService.takeSnapshot(workFolder: folder, taskID: 101, runID: 1, round: 1, phase: .start)
            XCTFail("Expected write-tree to fail on read-only objects")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .commandFailed)
        }
    }

    func testDiffChanges_pageAndPageSizeValidation_throwsInvalidArgs() async throws {
        let folder = tempDir.appendingPathComponent("validation-paging", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshotService = TaskSnapshotService()
        try await snapshotService.takeSnapshot(workFolder: folder, taskID: 200, runID: 1, round: 1, phase: .start)

        // page < 1
        do {
            _ = try await snapshotService.diffChanges(
                workFolder: folder,
                folderID: "f",
                taskID: 200,
                runID: 1,
                round: 1,
                page: 0,
                pageSize: 10,
                filePath: nil
            )
            XCTFail("Expected invalidArgs for page 0")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .invalidArgs)
            XCTAssertTrue(err.message.contains("page must be positive integer"))
        }

        // pageSize < 1
        do {
            _ = try await snapshotService.diffChanges(
                workFolder: folder,
                folderID: "f",
                taskID: 200,
                runID: 1,
                round: 1,
                page: 1,
                pageSize: 0,
                filePath: nil
            )
            XCTFail("Expected invalidArgs for pageSize 0")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .invalidArgs)
            XCTAssertTrue(err.message.contains("page_size must be positive integer"))
        }
    }

    func testDiffChanges_liveDiffWithoutReviewRef_includesEmbeddedRepoExclusionPathspecs() async throws {
        let folder = tempDir.appendingPathComponent("live-diff-embedded", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let mainFile = folder.appendingPathComponent("main.txt")
        try "initial text".write(to: mainFile, atomically: true, encoding: .utf8)

        let snapshotService = TaskSnapshotService()
        try await snapshotService.takeSnapshot(workFolder: folder, taskID: 201, runID: 1, round: 1, phase: .start)

        // Create an embedded repository inside workFolder
        let subRepo = folder.appendingPathComponent("embedded_sub", isDirectory: true)
        try fileManager.createDirectory(at: subRepo, withIntermediateDirectories: true)
        _ = try await ProcessRunner.runGitAsync(["init"], in: subRepo)
        let subFile = subRepo.appendingPathComponent("sub.txt")
        try "sub file".write(to: subFile, atomically: true, encoding: .utf8)
        _ = try await ProcessRunner.runGitAsync(["add", "."], in: subRepo)
        _ = try await ProcessRunner.runGitAsync(["commit", "-m", "sub commit"], in: subRepo)

        // Modify mainFile without taking review snapshot -> exercises live diff path (lines 730-750)
        try "modified text".write(to: mainFile, atomically: true, encoding: .utf8)

        let changes = try await snapshotService.diffChanges(
            workFolder: folder,
            folderID: "f",
            taskID: 201,
            runID: 1,
            round: 1,
            page: 1,
            pageSize: 10,
            filePath: nil
        )
        XCTAssertEqual(changes.task_id, 201)
        XCTAssertTrue(changes.files.contains { $0.path == "main.txt" })
        XCTAssertTrue(changes.not_tracked.map(\.path).contains("embedded_sub"))
    }

    func testTakeSnapshot_legacyOverloadAndStopClosePhases() async throws {
        let folder = tempDir.appendingPathComponent("legacy-phases", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("doc.txt")
        try "v1".write(to: file, atomically: true, encoding: .utf8)

        let snapshotService = TaskSnapshotService()
        // Test legacy 4-param takeSnapshot overload (line 41)
        try await snapshotService.takeSnapshot(workFolder: folder, taskID: 301, round: 1, phase: .start)

        // Test .stop and .close phases
        try "v2".write(to: file, atomically: true, encoding: .utf8)
        try await snapshotService.takeSnapshot(workFolder: folder, taskID: 301, runID: 1, round: 1, phase: .stop)
        try await snapshotService.takeSnapshot(workFolder: folder, taskID: 301, runID: 1, round: 1, phase: .close)

        let refs = try await snapshotService.listTaskRefs(workFolder: folder, taskID: 301)
        XCTAssertTrue(refs.contains("refs/nanoteams/301/1/1/close"))
    }

    /// The refusal `task_changes` sends is the builder's text — the one the registry renders — and
    /// names a next call with the task (F6 T3: the registry rendered hand-written copies until
    /// 2026-11-12, which a reworded refusal never moved).
    func testDiffChanges_refusalsAreTheRegisteredBuildersText() async throws {
        let folder = tempDir.appendingPathComponent("registered-refusals", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshotService = TaskSnapshotService()
        try await snapshotService.takeSnapshot(workFolder: folder, taskID: 503, runID: 1, round: 1, phase: .start)

        func refusal(round: Int? = 1, page: Int? = 1, pageSize: Int? = 10, filePath: String? = nil) async throws -> ExternalAutovisorError {
            do {
                _ = try await snapshotService.diffChanges(
                    workFolder: folder, folderID: "f", taskID: 503, runID: 1, round: round,
                    page: page, pageSize: pageSize, filePath: filePath)
            } catch let error as ExternalAutovisorError {
                return error
            }
            struct NoRefusal: Error {}
            throw NoRefusal()
        }
        let cases: [(ExternalAutovisorError, String, String)] = [
            (try await refusal(filePath: "../x"), TaskChangesRefusal.invalidFilePath("../x"), ExternalAutovisorToolNames.taskChanges),
            (try await refusal(page: 0), TaskChangesRefusal.invalidPage, ExternalAutovisorToolNames.taskChanges),
            (try await refusal(pageSize: 0), TaskChangesRefusal.invalidPageSize, ExternalAutovisorToolNames.taskChanges),
            (try await refusal(round: 99), TaskChangesRefusal.roundDoesNotExist(round: 99, taskID: 503), ExternalAutovisorToolNames.taskChanges),
        ]
        for (error, message, command) in cases {
            XCTAssertEqual(error.code, .invalidArgs, message)
            XCTAssertEqual(error.message, message)
            XCTAssertEqual(error.next?.suggested_cmd, command, message)
            XCTAssertEqual(error.next?.suggested_args?["task_id"], "503", message)
        }
        XCTAssertEqual(cases[1].0.next?.suggested_args?["page"], "1", "a page below 1 points at the first")
    }

    func testDiffChanges_nonExistentRoundExplicitlyProvided_throwsInvalidArgs() async throws {
        let folder = tempDir.appendingPathComponent("nonexistent-round-repo", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshotService = TaskSnapshotService()
        try await snapshotService.takeSnapshot(workFolder: folder, taskID: 501, runID: 1, round: 1, phase: .start)

        do {
            _ = try await snapshotService.diffChanges(
                workFolder: folder,
                folderID: "f",
                taskID: 501,
                runID: 1,
                round: 99,
                page: 1,
                pageSize: 10,
                filePath: nil
            )
            XCTFail("Expected invalidArgs for non-existent round")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .invalidArgs)
            XCTAssertTrue(err.message.contains("Round 99 does not exist for task 501"))
        }
    }

    func testDiffChanges_invalidFilePathWithTraversalOrAbsolute_throwsInvalidArgs() async throws {
        let folder = tempDir.appendingPathComponent("invalid-filepath-repo", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshotService = TaskSnapshotService()
        try await snapshotService.takeSnapshot(workFolder: folder, taskID: 502, runID: 1, round: 1, phase: .start)

        for badPath in ["../secret.txt", "/etc/passwd", "sub\\backslash.txt", "sub\0null.txt"] {
            do {
                _ = try await snapshotService.diffChanges(
                    workFolder: folder,
                    folderID: "f",
                    taskID: 502,
                    runID: 1,
                    round: 1,
                    page: 1,
                    pageSize: 10,
                    filePath: badPath
                )
                XCTFail("Expected invalidArgs for invalid file_path \(badPath)")
            } catch let err as ExternalAutovisorError {
                XCTAssertEqual(err.code, .invalidArgs)
                XCTAssertTrue(err.message.contains("Invalid file_path"))
            }
        }
    }

    func testDiffChanges_snapshotsRepoExistsButNoSnapshotsForTask_throwsSnapshotsUnavailableNoneTaken() async throws {
        let folder = tempDir.appendingPathComponent("diff-no-snapshots-repo", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshotService = TaskSnapshotService()
        try await snapshotService.takeSnapshot(workFolder: folder, taskID: 100, runID: 1, round: 1, phase: .start)

        do {
            _ = try await snapshotService.diffChanges(
                workFolder: folder,
                folderID: "f",
                taskID: 200,
                runID: 1,
                round: nil,
                page: 1,
                pageSize: 10,
                filePath: nil
            )
            XCTFail("Expected snapshotsUnavailable for task with no snapshots taken")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .snapshotsUnavailable)
            XCTAssertEqual(err.details?["reason"], "none_taken")
            XCTAssertEqual(err.next?.suggested_cmd, ExternalAutovisorToolNames.taskLog)
        }
    }

    /// A run-less ref of the unreleased pre-F2 builds is not read (N13): it named no run, and
    /// read as run 1 it was the second run's.
    func testDiffChanges_runlessRef_isNotRead() async throws {
        let folder = tempDir.appendingPathComponent("legacy-ref-repo", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshotService = TaskSnapshotService()
        try await snapshotService.takeSnapshot(workFolder: folder, taskID: 300, runID: 0, round: 1, phase: .start)

        let gitDir = folder.appendingPathComponent(".nanoteams/internal/snapshots.git")
        _ = try await ProcessRunner.runGitAsync(
            ["--git-dir=\(gitDir.path)", "update-ref", "refs/nanoteams/300/2/start", "refs/nanoteams/300/0/1/start"],
            in: folder
        )

        let diff = try await snapshotService.diffChanges(
            workFolder: folder, folderID: "f", taskID: 300, runID: nil, round: nil,
            page: 1, pageSize: 10, filePath: nil)
        XCTAssertEqual(diff.round, 1, "run 0's round 1 — the run-less round 2 ref is not a round")
        do {
            _ = try await snapshotService.diffChanges(
                workFolder: folder, folderID: "f", taskID: 300, runID: 0, round: 2,
                page: 1, pageSize: 10, filePath: nil)
            XCTFail("round 2 has no start of its own")
        } catch let error as ExternalAutovisorError {
            XCTAssertEqual(error.code, .invalidArgs)
            XCTAssertEqual(error.missingRoundStart, 2)
        }
    }

    /// Runs are numbered from 0: a task whose only snapshots are its first run's resolves to that
    /// run. RED before N13: `latestRunID` started at 1, answered 1 for refs of run 0, and the
    /// diff found no snapshots at all.
    func testDiffChanges_firstRunIsRunZero_resolvesWithoutRunID() async throws {
        try "v1".write(to: tempDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 3, runID: 0, round: 1, phase: .start)
        try "v2".write(to: tempDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 3, runID: 0, round: 1, phase: .review)

        let diff = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 3, runID: nil, round: nil,
            page: 1, pageSize: 10, filePath: nil)
        XCTAssertEqual(diff.round, 1)
        XCTAssertEqual(diff.files.map(\.path), ["a.txt"])
    }

    /// The end of an ended round is its LAST end snapshot (N7). RED before: `review` won on a
    /// fixed priority, so the later `failure` — and what changed between them — was not read.
    func testDiffChanges_endedRound_readsTheLatestEndSnapshot() async throws {
        let file = tempDir.appendingPathComponent("a.txt")
        try "start".write(to: file, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 4, runID: 0, round: 1, phase: .start)
        try "reviewed".write(to: file, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 4, runID: 0, round: 1, phase: .review)
        try "continued".write(to: tempDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 4, runID: 0, round: 1, phase: .failure)
        try "after the end".write(to: tempDir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

        let diff = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 4, runID: 0, round: 1, roundIsOpen: false,
            page: 1, pageSize: 10, filePath: nil)
        XCTAssertEqual(diff.files.map(\.path).sorted(), ["a.txt", "b.txt"])
    }

    /// An open round is read against the work tree even when it already has an end snapshot —
    /// an intermediate acceptance, a `stop` then `resume` (N7).
    func testDiffChanges_openRound_readsTheWorkTreePastAnEarlierEnd() async throws {
        let file = tempDir.appendingPathComponent("a.txt")
        try "start".write(to: file, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 5, runID: 0, round: 1, phase: .start)
        try "reviewed".write(to: file, atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 5, runID: 0, round: 1, phase: .review)
        try "went on".write(to: tempDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let open = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 5, runID: 0, round: 1, roundIsOpen: true,
            page: 1, pageSize: 10, filePath: nil)
        XCTAssertEqual(open.files.map(\.path).sorted(), ["a.txt", "b.txt"])

        let ended = try await service.diffChanges(
            workFolder: tempDir, folderID: "f", taskID: 5, runID: 0, round: 1, roundIsOpen: false,
            page: 1, pageSize: 10, filePath: nil)
        XCTAssertEqual(ended.files.map(\.path), ["a.txt"], "ended: the review is its end")
    }

    func testTaskRefIndex_readsRunRoundPhase_andNothingElse() {
        let index = TaskSnapshotService.TaskRefIndex(refs: [
            "refs/nanoteams/9/0/1/start", "refs/nanoteams/9/0/1/review", "refs/nanoteams/9/0/2/start",
            "refs/nanoteams/9/3/1/start", "refs/nanoteams/9/1/start", "refs/nanoteams/9/0/1/bogus",
            "refs/nanoteams/9/x/1/start", "refs/nanoteams/9/0/0/start", "refs/nanoteams/19/7/1/start",
            "refs/nanoteams/9/-1/1/start",
        ], taskID: 9)
        XCTAssertEqual(index.latestRunID, 3)
        XCTAssertEqual(index.latestRound(ofRun: 0), 2)
        XCTAssertEqual(index.recordedPhases(run: 0, round: 1), [.start, .review])
        XCTAssertNil(index.latestRound(ofRun: 7))
        XCTAssertNil(TaskSnapshotService.TaskRefIndex(refs: [], taskID: 9).latestRunID)
    }

    func testSnapshot_whenGitInitFails_throwsCommandFailed() async throws {
        let folder = tempDir.appendingPathComponent("failing-init-repo", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let internalDir = folder.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try fileManager.createDirectory(at: internalDir, withIntermediateDirectories: true)
        let snapshotsGit = internalDir.appendingPathComponent("snapshots.git")
        try "file-not-dir".write(to: snapshotsGit, atomically: true, encoding: .utf8)

        let snapshotService = TaskSnapshotService()
        do {
            try await snapshotService.takeSnapshot(workFolder: folder, taskID: 1, runID: 1, round: 1, phase: .start)
            XCTFail("Expected init failure")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .commandFailed)
            XCTAssertTrue(err.message.contains("Failed to initialize snapshots repository"))
        }
    }

    func testTaskSnapshotProtocol_defaultExtensionMethods_forwardWithDefaults() async throws {
        let folder = tempDir.appendingPathComponent("proto-ext-repo", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let proto: any TaskSnapshotProtocol = service

        try await proto.takeSnapshot(workFolder: folder, taskID: 400, round: 1, phase: .start)

        let diff = try await proto.diffChanges(
            workFolder: folder,
            folderID: "f400",
            taskID: 400,
            round: 1,
            page: 1,
            pageSize: 5,
            filePath: nil
        )
        XCTAssertEqual(diff.task_id, 400)
    }

    func testDiffChanges_pageLessThanOne_throwsInvalidArgs() async throws {
        let folder = tempDir.appendingPathComponent("page-validation-repo", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            _ = try await service.diffChanges(
                workFolder: folder,
                folderID: "f",
                taskID: 10,
                runID: nil,
                round: 1,
                page: 0,
                pageSize: 5,
                filePath: nil
            )
            XCTFail("Expected invalidArgs")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .invalidArgs)
            XCTAssertTrue(err.message.contains("page must be positive integer"))
        }
    }

    func testDiffChanges_pageSizeLessThanOne_throwsInvalidArgs() async throws {
        let folder = tempDir.appendingPathComponent("pagesize-validation-repo", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            _ = try await service.diffChanges(
                workFolder: folder,
                folderID: "f",
                taskID: 10,
                runID: nil,
                round: 1,
                page: 1,
                pageSize: 0,
                filePath: nil
            )
            XCTFail("Expected invalidArgs")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .invalidArgs)
            XCTAssertTrue(err.message.contains("page_size must be positive integer"))
        }
    }

    func testWithFolderLock_cleansUpStaleLockFiles() async throws {
        let folder = tempDir.appendingPathComponent("lock-cleanup-repo", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshotsGit = folder.appendingPathComponent(".nanoteams/internal/snapshots.git", isDirectory: true)
        try fileManager.createDirectory(at: snapshotsGit, withIntermediateDirectories: true)
        let staleLock = snapshotsGit.appendingPathComponent("index.lock")
        try "stale lock content".write(to: staleLock, atomically: true, encoding: .utf8)
        XCTAssertTrue(fileManager.fileExists(atPath: staleLock.path))

        try await service.takeSnapshot(workFolder: folder, taskID: 12, runID: 1, round: 1, phase: .start)

        XCTAssertFalse(fileManager.fileExists(atPath: staleLock.path), "cleanupStaleLocks must remove .lock files")
    }

    /// The stale-lock sweep reads only where git keeps its locks — the store's own files,
    /// `refs/`, `objects/info/`, `objects/pack/` — never the loose objects (N14: it walked the
    /// whole store, every loose object included, on every acquisition of the folder lock).
    /// RED before: the planted `objects/ab/stray.lock` was removed too, i.e. the sweep walked it.
    func testStaleLockSweep_readsGitsLockLocations_notTheLooseObjects() async throws {
        try "x".write(to: tempDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 21, runID: 0, round: 1, phase: .start)
        let gitDir = NTMSPaths(workFolderRoot: tempDir).snapshotsGitDir
        let swept = [
            "index.lock", "packed-refs.lock", "HEAD.lock", "config.lock",
            "refs/nanoteams/21/0/1/start.lock", "objects/info/commit-graph.lock", "objects/pack/multi-pack-index.lock",
        ]
        let kept = ["objects/ab/stray.lock"]
        for relative in swept + kept {
            let url = gitDir.appendingPathComponent(relative)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "stale".write(to: url, atomically: true, encoding: .utf8)
        }
        // `config.lock` and `HEAD.lock` are not read by the check before the sweep removes them.

        _ = try await service.listTaskRefs(workFolder: tempDir, taskID: 21)
        try await service.takeSnapshot(workFolder: tempDir, taskID: 21, runID: 0, round: 1, phase: .review)

        for relative in swept {
            XCTAssertFalse(fileManager.fileExists(atPath: gitDir.appendingPathComponent(relative).path), relative)
        }
        for relative in kept {
            XCTAssertTrue(fileManager.fileExists(atPath: gitDir.appendingPathComponent(relative).path), relative)
        }
    }

    func testDiffChanges_snapshotsUnavailable_throwsSnapshotsUnavailable() async throws {
        let emptyFolder = tempDir.appendingPathComponent("empty-repo-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        do {
            _ = try await service.diffChanges(
                workFolder: emptyFolder,
                folderID: "empty-f",
                taskID: 10,
                runID: 1,
                round: 1,
                page: 1,
                pageSize: 5,
                filePath: nil
            )
            XCTFail("Expected snapshotsUnavailable")
        } catch let err as ExternalAutovisorError {
            XCTAssertEqual(err.code, .snapshotsUnavailable)
            XCTAssertEqual(err.details?["reason"], "none_taken")
        }
    }

    func testDiscoverEmbeddedRepositories_findsSubmoduleGitDirectories() async throws {
        let folder = tempDir.appendingPathComponent("embedded-test-folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let subRepo = folder.appendingPathComponent("submodule_a", isDirectory: true)
        let subGit = subRepo.appendingPathComponent(".git", isDirectory: true)
        try fileManager.createDirectory(at: subGit, withIntermediateDirectories: true)
        try "gitdir".write(to: subGit.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let nested = folder.appendingPathComponent("nested/deep_repo", isDirectory: true)
        let nestedGit = nested.appendingPathComponent(".git", isDirectory: true)
        try fileManager.createDirectory(at: nestedGit, withIntermediateDirectories: true)
        try "gitdir".write(to: nestedGit.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let snapshotService = TaskSnapshotService()
        let discovered = await snapshotService.discoverEmbeddedRepositories(in: folder)
        XCTAssertTrue(discovered.contains("submodule_a"))
        XCTAssertTrue(discovered.contains("nested/deep_repo"))
    }
}
