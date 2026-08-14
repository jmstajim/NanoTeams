import XCTest

@testable import NanoTeams

/// The three git paths `ToolsGitTests` never reaches.
///
/// Coverage context (measured 2026-08-07): `git_pull` appears in **no** test file
/// at all — `GitPullTool.handle` was 112 executable lines at 0%. `GitMergeTool.handle`
/// was 77 at 0%. `GitErrorClassifier.classify` — the shared stderr→envelope mapper
/// behind every branching tool — was 26 at 0%, so the only tested part of the
/// classifier was its `isNotARepository` leaf.
///
/// Nothing here touches the network: `git_pull` runs against a **local bare repo**
/// used as `origin`, which exercises the same code path a real remote would.
///
/// Harness copied from `ToolsGitTests`: a real temp git repo driven through
/// `ToolRuntime`, because the tools shell out to `/usr/bin/git` and the value under
/// test is how their porcelain output is parsed. `.standardizedFileURL` is required —
/// `/var` → `/private/var` otherwise breaks `SandboxPathResolver` containment.
final class ToolsGitPullMergeTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var remoteDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        try git(["init", "-b", "main"], in: tempDir)
        try git(["config", "user.email", "test@example.com"], in: tempDir)
        try git(["config", "user.name", "Test User"], in: tempDir)
        try seedCommit(named: "base.txt", contents: "base\n", message: "base")

        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0))
        runtime = run
        context = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role")
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fileManager.removeItem(at: tempDir) }
        if let remoteDir { try? fileManager.removeItem(at: remoteDir) }
        tempDir = nil
        remoteDir = nil
        runtime = nil
        context = nil
        try super.tearDownWithError()
    }

    // MARK: - git_pull

    func testGitPull_fromLocalBareRemote_succeedsAndReportsOutput() async throws {
        try attachBareRemote()
        try git(["push", "-u", "origin", "main"], in: tempDir)
        try pushExtraCommitFromASecondClone()

        let data = try await successData(ToolNames.gitPull, ["remote": "origin", "branch": "main"])

        XCTAssertEqual(data["success"] as? Bool, true, "pull from a reachable remote must succeed")
        let output = data["output"] as? String ?? ""
        XCTAssertFalse(output.isEmpty, "the tool must surface git's output, got empty")
        XCTAssertTrue(fileManager.fileExists(atPath: tempDir.appendingPathComponent("from-remote.txt").path),
                      "the pulled commit's file must be in the working tree")
    }

    /// The `rebase: true` branch builds a different argv (`pull --rebase`). Pinning it
    /// separately because an argument dropped there fails silently — the pull still
    /// succeeds, it just merges instead of rebasing.
    func testGitPull_withRebase_succeeds() async throws {
        try attachBareRemote()
        try git(["push", "-u", "origin", "main"], in: tempDir)

        let data = try await successData(
            ToolNames.gitPull, ["remote": "origin", "branch": "main", "rebase": true])

        XCTAssertEqual(data["success"] as? Bool, true)
    }

    /// REGRESSION (found by this test, fixed 2026-08-07): a pull that fails for any
    /// non-conflict reason — no such remote, no upstream, unrelated histories — used
    /// to fall through to the SUCCESS envelope carrying `data.success == false`.
    /// The model's signal is `ok`, not `data.success`, so an unreachable remote read
    /// as a completed pull and the role moved on believing it had the remote's
    /// commits. `git_checkout` and `git_branch` had guarded this from the start via
    /// `GitErrorClassifier`; `git_pull` and `git_merge` were the two that skipped it.
    func testGitPull_withNoSuchRemote_returnsErrorEnvelope() async throws {
        let result = try await run(ToolNames.gitPull, ["remote": "definitely_not_a_remote"])

        XCTAssertTrue(result.isError,
                      "a missing remote must be an ERROR envelope, not ok:true with success:false; got \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("\"ok\":true"),
                       "the model reads `ok` — a failed pull must never report ok:true; got \(result.outputJSON)")
    }

    // MARK: - git_merge

    func testGitMerge_fastForward_reportsTheMergedBranch() async throws {
        try git(["checkout", "-b", "feature"], in: tempDir)
        try seedCommit(named: "feature.txt", contents: "feature\n", message: "feature work")
        try git(["checkout", "main"], in: tempDir)

        let data = try await successData(ToolNames.gitMerge, ["branch": "feature"])

        XCTAssertEqual(data["success"] as? Bool, true)
        XCTAssertEqual(data["merged_branch"] as? String, "feature",
                       "the envelope must name the branch that was merged")
        XCTAssertTrue(fileManager.fileExists(atPath: tempDir.appendingPathComponent("feature.txt").path))
    }

    /// `no_ff` and `squash` add flags to argv. Squash leaves the merge staged rather
    /// than committed — pinned so a future argv refactor can't silently drop it.
    func testGitMerge_squash_leavesChangesStagedNotCommitted() async throws {
        try git(["checkout", "-b", "feature"], in: tempDir)
        try seedCommit(named: "feature.txt", contents: "feature\n", message: "feature work")
        try git(["checkout", "main"], in: tempDir)

        let data = try await successData(ToolNames.gitMerge, ["branch": "feature", "squash": true])

        XCTAssertEqual(data["merged_branch"] as? String, "feature")
        let log = try capture(["log", "--oneline"], in: tempDir)
        XCTAssertFalse(log.contains("feature work"),
                       "a squashed merge must not have created the merge commit yet; got: \(log)")
    }

    func testGitMerge_conflictingBranches_returnsConflictEnvelope() async throws {
        try git(["checkout", "-b", "feature"], in: tempDir)
        try seedCommit(named: "base.txt", contents: "feature side\n", message: "feature edit")
        try git(["checkout", "main"], in: tempDir)
        try seedCommit(named: "base.txt", contents: "main side\n", message: "main edit")

        let result = try await run(ToolNames.gitMerge, ["branch": "feature"])

        XCTAssertTrue(result.isError, "a conflicting merge must be an error; got \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("Merge conflicts detected"),
                      "got: \(result.outputJSON)")
    }

    /// Sibling of the `git_pull` regression above: `git merge no_such_branch` exits 1
    /// with `merge: no_such_branch - not something we can merge`, which is neither a
    /// conflict nor a recognised classifier string — so it used to return
    /// `{"ok":true,"data":{"success":false,"merged_branch":"no_such_branch"}}` and the
    /// model believed the branch had been merged.
    func testGitMerge_unknownBranch_isRejected() async throws {
        let result = try await run(ToolNames.gitMerge, ["branch": "no_such_branch"])

        XCTAssertTrue(result.isError,
                      "merging a nonexistent branch must be an ERROR envelope; got \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("\"merged_branch\""),
                       "a failed merge must not report a merged branch; got \(result.outputJSON)")
    }

    // MARK: - GitErrorClassifier.classify

    /// The classifier is the shared stderr→envelope mapper. Each branch maps a
    /// different git message to a different `ToolErrorCode`, and the model's recovery
    /// depends on which one it gets — a `conflict` says "resolve", a `fileNotFound`
    /// says "you named something that isn't there".
    func testClassifier_mapsEachKnownStderrToItsOwnCode() {
        let args: [String: Any] = ["branch": "x"]

        let notRepo = GitErrorClassifier.classify(
            stderr: "fatal: not a git repository (or any of the parent directories): .git",
            toolName: ToolNames.gitBranch, args: args, subject: "Branch")
        XCTAssertNotNil(notRepo)
        XCTAssertTrue(notRepo?.outputJSON.contains("not a git repository") == true,
                      "got: \(notRepo?.outputJSON ?? "nil")")

        let exists = GitErrorClassifier.classify(
            stderr: "fatal: a branch named 'x' already exists",
            toolName: ToolNames.gitBranch, args: args, subject: "Branch")
        XCTAssertTrue(exists?.outputJSON.contains("Branch already exists") == true,
                      "got: \(exists?.outputJSON ?? "nil")")

        let missing = GitErrorClassifier.classify(
            stderr: "error: pathspec 'x' did not match any file(s) known to git",
            toolName: ToolNames.gitCheckout, args: args, subject: "Branch")
        XCTAssertTrue(missing?.outputJSON.contains("Branch not found") == true,
                      "got: \(missing?.outputJSON ?? "nil")")

        let conflict = GitErrorClassifier.classify(
            stderr: "CONFLICT (content): Merge conflict in base.txt",
            toolName: ToolNames.gitMerge, args: args, subject: "Branch")
        XCTAssertTrue(conflict?.outputJSON.contains("Merge conflicts detected") == true,
                      "got: \(conflict?.outputJSON ?? "nil")")
    }

    /// nil means "this stderr is not one I recognise" — the caller then falls through
    /// to its own handling. Returning an envelope here would swallow unknown failures
    /// under a wrong, confident label.
    func testClassifier_unrecognisedStderr_returnsNil() {
        XCTAssertNil(GitErrorClassifier.classify(
            stderr: "fatal: some entirely novel git failure",
            toolName: ToolNames.gitMerge, args: [:], subject: "Branch"))
        XCTAssertNil(GitErrorClassifier.classify(
            stderr: "", toolName: ToolNames.gitMerge, args: [:], subject: "Branch"))
    }

    /// `isNotARepository` is anchored on git's canonical prefix precisely because
    /// `git_commit` passes STDOUT through the classifier too — a commit message
    /// quoting the phrase must not be misread as a broken repo.
    func testClassifier_commitMessageQuotingThePhrase_isNotMisreadAsBrokenRepo() {
        XCTAssertFalse(GitErrorClassifier.isNotARepository(
            stderr: "Fix the error when this is not a git repository"))
        XCTAssertTrue(GitErrorClassifier.isNotARepository(
            stderr: "fatal: not a git repository (or any of the parent directories): .git"))
    }

    // MARK: - Helpers

    private func run(_ tool: String, _ args: [String: Any]) async throws -> ToolExecutionResult {
        let json = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let calls = [StepToolCall(name: tool, argumentsJSON: json)]
        let results = await runtime.executeAll(context: context, toolCalls: calls)
        return try XCTUnwrap(results.first)
    }

    private func successData(_ tool: String, _ args: [String: Any]) async throws -> [String: Any] {
        let result = try await run(tool, args)
        XCTAssertFalse(result.isError, "expected success, got \(result.outputJSON)")
        let object = try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))
        let envelope = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(envelope["data"] as? [String: Any],
                             "no data in envelope: \(result.outputJSON)")
    }

    /// A bare repo on disk standing in for a network remote — same git code path,
    /// zero network.
    private func attachBareRemote() throws {
        remoteDir = fileManager.temporaryDirectory
            .appendingPathComponent("remote-\(UUID().uuidString).git", isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        try git(["init", "--bare", "-b", "main"], in: remoteDir)
        try git(["remote", "add", "origin", remoteDir.path], in: tempDir)
    }

    /// Puts a commit on the remote that the work folder does not have, so `git pull`
    /// has something to fetch and actually exercises the merge half of the tool.
    private func pushExtraCommitFromASecondClone() throws {
        let clone = fileManager.temporaryDirectory
            .appendingPathComponent("clone-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? fileManager.removeItem(at: clone) }
        try git(["clone", remoteDir.path, clone.path], in: fileManager.temporaryDirectory)
        try git(["config", "user.email", "other@example.com"], in: clone)
        try git(["config", "user.name", "Other User"], in: clone)
        try Data("from remote\n".utf8).write(to: clone.appendingPathComponent("from-remote.txt"))
        try git(["add", "."], in: clone)
        try git(["commit", "-m", "remote commit"], in: clone)
        try git(["push", "origin", "main"], in: clone)
    }

    private func seedCommit(named name: String, contents: String, message: String) throws {
        try Data(contents.utf8).write(to: tempDir.appendingPathComponent(name))
        try git(["add", "."], in: tempDir)
        try git(["commit", "-m", message], in: tempDir)
    }

    @discardableResult
    private func git(_ args: [String], in directory: URL) throws -> String {
        try capture(args, in: directory)
    }

    @discardableResult
    private func capture(_ args: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
