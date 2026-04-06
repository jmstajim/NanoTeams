import XCTest

@testable import NanoTeams

final class ToolsGitTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Use standardizedFileURL to resolve symlinks (/var -> /private/var on macOS)
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create .nanoteams directory
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        // Initialize git repository
        try initGitRepo()

        // Create registry with git tools
        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        runtime = run

        context = ToolExecutionContext(
            workFolderRoot: tempDir,
            taskID: Int(),
            runID: 0,
            roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
//        registry = nil
//        runtime = nil
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    private func initGitRepo() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init"]
        process.currentDirectoryURL = tempDir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        // Configure git user for commits
        configureGitUser()
    }

    private func configureGitUser() {
        let configCommands = [
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Test User"]
        ]

        for args in configCommands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = tempDir
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    private func runGitCommand(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = tempDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - git_status Tests

    func testGitStatus_emptyRepo() {
        let call = StepToolCall(name: "git_status", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("clean\":true") || results[0].outputJSON.contains("clean\": true"))
    }

    func testGitStatus_withUntrackedFile() throws {
        // Create an untracked file
        try "New content".write(to: tempDir.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let call = StepToolCall(name: "git_status", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("untracked.txt"))
        XCTAssertTrue(results[0].outputJSON.contains("clean\":false") || results[0].outputJSON.contains("clean\": false"))
    }

    func testGitStatus_showsBranchName() throws {
        // Create initial commit to have a branch
        try "Initial".write(to: tempDir.appendingPathComponent("initial.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["add", "initial.txt"])
        _ = try runGitCommand(["commit", "-m", "Initial commit"])

        let call = StepToolCall(name: "git_status", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        // Should contain branch name (main or master)
        let output = results[0].outputJSON
        XCTAssertTrue(output.contains("branch"))
    }

    // MARK: - git_add Tests

    func testGitAdd_stagesFile() throws {
        try "Content".write(to: tempDir.appendingPathComponent("to_stage.txt"), atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "git_add",
            argumentsJSON: "{\"paths\": [\"to_stage.txt\"]}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("to_stage.txt"))

        // Verify file is staged
        let statusOutput = try runGitCommand(["status", "--porcelain"])
        XCTAssertTrue(statusOutput.contains("A  to_stage.txt") || statusOutput.contains("A to_stage.txt"))
    }

    func testGitAdd_stagesMultipleFiles() throws {
        try "A".write(to: tempDir.appendingPathComponent("file_a.txt"), atomically: true, encoding: .utf8)
        try "B".write(to: tempDir.appendingPathComponent("file_b.txt"), atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "git_add",
            argumentsJSON: "{\"paths\": [\"file_a.txt\", \"file_b.txt\"]}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("file_a.txt"))
        XCTAssertTrue(results[0].outputJSON.contains("file_b.txt"))
    }

    func testGitAdd_singularPathAlias() throws {
        try "content".write(to: tempDir.appendingPathComponent("alias_test.txt"), atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "git_add",
            argumentsJSON: "{\"path\": \"alias_test.txt\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("alias_test.txt"))
    }

    func testGitAdd_missingPathsArgument() {
        let call = StepToolCall(name: "git_add", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
    }

    // MARK: - git_commit Tests

    func testGitCommit_commitsStaged() throws {
        try "Content".write(to: tempDir.appendingPathComponent("commit_me.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["add", "commit_me.txt"])

        let call = StepToolCall(
            name: "git_commit",
            argumentsJSON: "{\"message\": \"Test commit message\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)

        // Verify commit was made
        let logOutput = try runGitCommand(["log", "--oneline", "-1"])
        XCTAssertTrue(logOutput.contains("Test commit message"))
    }

    func testGitCommit_nothingToCommit() throws {
        // Create initial commit first
        try "Initial".write(to: tempDir.appendingPathComponent("initial.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["add", "initial.txt"])
        _ = try runGitCommand(["commit", "-m", "Initial"])

        // Try to commit with nothing staged
        let call = StepToolCall(
            name: "git_commit",
            argumentsJSON: "{\"message\": \"Empty commit\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(
            results[0].outputJSON.contains("CONFLICT") ||
            results[0].outputJSON.contains("nothing to commit")
        )
    }

    func testGitCommit_missingMessage() {
        let call = StepToolCall(name: "git_commit", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
    }

    // MARK: - git_diff Tests

    func testGitDiff_showsUnstagedChanges() throws {
        // Create and commit a file
        try "Original".write(to: tempDir.appendingPathComponent("diff_test.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["add", "diff_test.txt"])
        _ = try runGitCommand(["commit", "-m", "Initial"])

        // Modify the file
        try "Modified".write(to: tempDir.appendingPathComponent("diff_test.txt"), atomically: true, encoding: .utf8)

        let call = StepToolCall(name: "git_diff", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("diff_test.txt"))
    }

    func testGitDiff_stagedChanges() throws {
        try "Original".write(to: tempDir.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["add", "staged.txt"])
        _ = try runGitCommand(["commit", "-m", "Initial"])

        try "Modified".write(to: tempDir.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["add", "staged.txt"])

        let call = StepToolCall(
            name: "git_diff",
            argumentsJSON: "{\"cached\": true}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("staged.txt"))
    }

    // MARK: - git_log Tests

    func testGitLog_showsCommitHistory() throws {
        // Create some commits
        for i in 1...3 {
            try "Content \(i)".write(to: tempDir.appendingPathComponent("file\(i).txt"), atomically: true, encoding: .utf8)
            _ = try runGitCommand(["add", "file\(i).txt"])
            _ = try runGitCommand(["commit", "-m", "Commit \(i)"])
        }

        let call = StepToolCall(name: "git_log", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Commit 1"))
        XCTAssertTrue(results[0].outputJSON.contains("Commit 2"))
        XCTAssertTrue(results[0].outputJSON.contains("Commit 3"))
    }

    func testGitLog_respectsLimit() throws {
        for i in 1...5 {
            try "Content \(i)".write(to: tempDir.appendingPathComponent("file\(i).txt"), atomically: true, encoding: .utf8)
            _ = try runGitCommand(["add", "file\(i).txt"])
            _ = try runGitCommand(["commit", "-m", "Commit \(i)"])
        }

        let call = StepToolCall(
            name: "git_log",
            argumentsJSON: "{\"limit\": 2}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        // Should only show 2 commits (most recent)
        let output = results[0].outputJSON
        XCTAssertTrue(output.contains("Commit 5"))
        XCTAssertTrue(output.contains("Commit 4"))
    }

    // MARK: - git_branch_list Tests

    func testGitBranchList_showsBranches() throws {
        // Create initial commit
        try "Content".write(to: tempDir.appendingPathComponent("init.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["add", "init.txt"])
        _ = try runGitCommand(["commit", "-m", "Initial"])

        // Create a new branch
        _ = try runGitCommand(["branch", "feature-branch"])

        let call = StepToolCall(name: "git_branch_list", argumentsJSON: "{}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("feature-branch"))
    }

    // MARK: - git_checkout Tests

    func testGitCheckout_switchesBranch() throws {
        // Create initial commit
        try "Content".write(to: tempDir.appendingPathComponent("init.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["add", "init.txt"])
        _ = try runGitCommand(["commit", "-m", "Initial"])

        // Create and switch to new branch
        _ = try runGitCommand(["branch", "new-branch"])

        let call = StepToolCall(
            name: "git_checkout",
            argumentsJSON: "{\"branch\": \"new-branch\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)

        // Verify branch was switched
        let branchOutput = try runGitCommand(["branch", "--show-current"])
        XCTAssertTrue(branchOutput.contains("new-branch"))
    }

    func testGitCheckout_createNewBranch() throws {
        // Create initial commit
        try "Content".write(to: tempDir.appendingPathComponent("init.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["add", "init.txt"])
        _ = try runGitCommand(["commit", "-m", "Initial"])

        let call = StepToolCall(
            name: "git_checkout",
            argumentsJSON: "{\"branch\": \"created-branch\", \"create\": true}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)

        // Verify new branch was created and checked out
        let branchOutput = try runGitCommand(["branch", "--show-current"])
        XCTAssertTrue(branchOutput.contains("created-branch"))
    }

    // MARK: - git_stash Tests

    func testGitStash_stashesChanges() throws {
        // Create initial commit
        try "Original".write(to: tempDir.appendingPathComponent("stash.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["add", "stash.txt"])
        _ = try runGitCommand(["commit", "-m", "Initial"])

        // Make changes
        try "Modified".write(to: tempDir.appendingPathComponent("stash.txt"), atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "git_stash",
            argumentsJSON: "{\"action\": \"push\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)

        // Verify changes were stashed
        let content = try String(contentsOf: tempDir.appendingPathComponent("stash.txt"), encoding: .utf8)
        XCTAssertEqual(content, "Original")
    }

    func testGitStash_listStashes() throws {
        // Create initial commit
        try "Original".write(to: tempDir.appendingPathComponent("stash.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["add", "stash.txt"])
        _ = try runGitCommand(["commit", "-m", "Initial"])

        // Make and stash changes
        try "Modified".write(to: tempDir.appendingPathComponent("stash.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["stash", "push", "-m", "Test stash"])

        let call = StepToolCall(
            name: "git_stash",
            argumentsJSON: "{\"action\": \"list\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Test stash"))
    }

    // MARK: - git_branch Tests

    func testGitBranch_createsBranch() throws {
        // Create initial commit
        try "Content".write(to: tempDir.appendingPathComponent("init.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["add", "init.txt"])
        _ = try runGitCommand(["commit", "-m", "Initial"])

        let call = StepToolCall(
            name: "git_branch",
            argumentsJSON: "{\"name\": \"my-feature\", \"action\": \"create\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)

        // Verify branch was created
        let branchOutput = try runGitCommand(["branch"])
        XCTAssertTrue(branchOutput.contains("my-feature"))
    }

    func testGitBranch_deletesBranch() throws {
        // Create initial commit and branch
        try "Content".write(to: tempDir.appendingPathComponent("init.txt"), atomically: true, encoding: .utf8)
        _ = try runGitCommand(["add", "init.txt"])
        _ = try runGitCommand(["commit", "-m", "Initial"])
        _ = try runGitCommand(["branch", "to-delete"])

        let call = StepToolCall(
            name: "git_branch",
            argumentsJSON: "{\"name\": \"to-delete\", \"action\": \"delete\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)

        // Verify branch was deleted
        let branchOutput = try runGitCommand(["branch"])
        XCTAssertFalse(branchOutput.contains("to-delete"))
    }
}
