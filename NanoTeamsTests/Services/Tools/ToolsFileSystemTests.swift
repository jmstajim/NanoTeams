import XCTest

@testable import NanoTeams

final class ToolsFileSystemTests: XCTestCase {
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

        // Create registry with file system tools
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
        context = nil
        tempDir = nil
//        runtime = nil
        try super.tearDownWithError()
    }

    // MARK: - read_file Tests

    func testReadFile_readsExistingFile() throws {
        let content = "Hello, World!"
        let filePath = tempDir.appendingPathComponent("test.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"test.txt\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Hello, World!"))
    }

    func testReadFile_returnsErrorForMissingFile() {
        let call = StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"nonexistent.txt\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("FILE_NOT_FOUND"))
    }

    func testReadFile_returnsErrorForDirectory() throws {
        let dirPath = tempDir.appendingPathComponent("subdir")
        try fileManager.createDirectory(at: dirPath, withIntermediateDirectories: true)

        let call = StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"subdir\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("NOT_A_FILE"))
    }

    func testReadFile_truncatesLargeFiles() throws {
        let largeContent = String(repeating: "A", count: 300_000)
        let filePath = tempDir.appendingPathComponent("large.txt")
        try largeContent.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"large.txt\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("truncated"))
    }

    func testReadFile_respectsMaxBytes() throws {
        let content = String(repeating: "B", count: 1000)
        let filePath = tempDir.appendingPathComponent("medium.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"medium.txt\", \"max_bytes\": 100}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        // Should be truncated
        let json = results[0].outputJSON
        XCTAssertTrue(json.contains("truncated\":true") || json.contains("truncated\": true"))
    }

    // MARK: - read_lines Tests

    func testReadFileRange_readsSpecifiedLines() throws {
        let content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"
        let filePath = tempDir.appendingPathComponent("lines.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"lines.txt\", \"start_line\": 2, \"end_line\": 4}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Line 2"))
        XCTAssertTrue(results[0].outputJSON.contains("Line 3"))
        XCTAssertTrue(results[0].outputJSON.contains("Line 4"))
    }

    func testReadFileRange_invalidStartLine() throws {
        let content = "Line 1\nLine 2"
        let filePath = tempDir.appendingPathComponent("short.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"short.txt\", \"start_line\": 0, \"end_line\": 1}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
    }

    func testReadFileRange_endLineLessThanStartLine() throws {
        let content = "Line 1\nLine 2"
        let filePath = tempDir.appendingPathComponent("test.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"test.txt\", \"start_line\": 3, \"end_line\": 1}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        // Error message must teach the EOF sentinel so the model can self-correct.
        XCTAssertTrue(
            results[0].outputJSON.contains("end_line=0 or -1"),
            "Error should teach the EOF sentinel. Got: \(results[0].outputJSON)"
        )
    }

    // Regression for Run 13: qwen3.5-35b-a3b emitted `end_line: -1` intending "to EOF"
    // and got stuck retrying the same failing call. Non-positive end_line is now a
    // valid "read through end of file" sentinel.
    func testReadFileRange_endLineMinusOne_readsThroughEOF() throws {
        let content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"
        let filePath = tempDir.appendingPathComponent("eof_neg.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"eof_neg.txt\", \"start_line\": 2, \"end_line\": -1}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError, "end_line=-1 should read to EOF, not error. Got: \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("Line 2"))
        XCTAssertTrue(results[0].outputJSON.contains("Line 5"))
        // Reported end_line reflects the actual last line, not the sentinel.
        XCTAssertTrue(results[0].outputJSON.contains("\"end_line\":5") || results[0].outputJSON.contains("\"end_line\": 5"))
    }

    func testReadFileRange_endLineZero_readsThroughEOF() throws {
        let content = "A\nB\nC"
        let filePath = tempDir.appendingPathComponent("eof_zero.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"eof_zero.txt\", \"start_line\": 1, \"end_line\": 0}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("A"))
        XCTAssertTrue(results[0].outputJSON.contains("C"))
    }

    // Boundary: model passes EOF sentinel with a `start_line` that's already past
    // EOF (file shorter than expected). Must NOT crash on the slice
    // `allLines[(startLine-1)..<actualEndLine]` (which would fault if
    // startLine-1 > actualEndLine). Expected: clean rangeOutOfBounds error.
    func testReadFileRange_startLinePastEOF_withEOFSentinel_returnsRangeError() throws {
        let content = "Line 1\nLine 2\nLine 3"  // 3 lines
        let filePath = tempDir.appendingPathComponent("short_file.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"short_file.txt\", \"start_line\": 10, \"end_line\": -1}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError, "start_line past EOF must error, not return empty content")
        XCTAssertTrue(
            results[0].outputJSON.lowercased().contains("range") ||
            results[0].outputJSON.contains("exceeds file length"),
            "Error must indicate range/length issue. Got: \(results[0].outputJSON)"
        )
    }

    // MARK: - write_file Tests

    func testWriteFile_createsNewFile() {
        let call = StepToolCall(
            name: "write_file",
            argumentsJSON: "{\"path\": \"new.txt\", \"content\": \"New content\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("created\":true") || results[0].outputJSON.contains("created\": true"))

        // Verify file was created
        let filePath = tempDir.appendingPathComponent("new.txt")
        XCTAssertTrue(fileManager.fileExists(atPath: filePath.path))
    }

    func testWriteFile_overwritesExistingFile() throws {
        let filePath = tempDir.appendingPathComponent("existing.txt")
        try "Old content".write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "write_file",
            argumentsJSON: "{\"path\": \"existing.txt\", \"content\": \"New content\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        let newContent = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertEqual(newContent, "New content")
    }

    func testWriteFile_createsParentDirectories() {
        let call = StepToolCall(
            name: "write_file",
            argumentsJSON: "{\"path\": \"nested/deep/file.txt\", \"content\": \"Deep content\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)

        let filePath = tempDir.appendingPathComponent("nested/deep/file.txt")
        XCTAssertTrue(fileManager.fileExists(atPath: filePath.path))
    }

    func testWriteFile_failsWithoutCreateDirs() throws {
        let call = StepToolCall(
            name: "write_file",
            argumentsJSON: "{\"path\": \"missing_parent/file.txt\", \"content\": \"Content\", \"create_dirs\": false}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("NOT_A_DIRECTORY"))
    }

    // MARK: - delete_file Tests

    func testDeleteFile_deletesExistingFile() throws {
        let filePath = tempDir.appendingPathComponent("to_delete.txt")
        try "Content".write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "delete_file",
            argumentsJSON: "{\"path\": \"to_delete.txt\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertFalse(fileManager.fileExists(atPath: filePath.path))
    }

    func testDeleteFile_errorForMissingFile() {
        let call = StepToolCall(
            name: "delete_file",
            argumentsJSON: "{\"path\": \"nonexistent.txt\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("FILE_NOT_FOUND"))
    }

    func testDeleteFile_mustExistFalse_succeedsForMissing() {
        let call = StepToolCall(
            name: "delete_file",
            argumentsJSON: "{\"path\": \"nonexistent.txt\", \"must_exist\": false}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("deleted\":false") || results[0].outputJSON.contains("deleted\": false"))
    }

    func testDeleteFile_errorForDirectory() throws {
        let dirPath = tempDir.appendingPathComponent("mydir")
        try fileManager.createDirectory(at: dirPath, withIntermediateDirectories: true)

        let call = StepToolCall(
            name: "delete_file",
            argumentsJSON: "{\"path\": \"mydir\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("NOT_A_FILE"))
    }

    // MARK: - list_files Tests

    func testListDirectory_listsFiles() throws {
        try "A".write(to: tempDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "B".write(to: tempDir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: tempDir.appendingPathComponent("subdir"), withIntermediateDirectories: true)

        let call = StepToolCall(
            name: "list_files",
            argumentsJSON: "{\"path\": \".\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("file1.txt"))
        XCTAssertTrue(results[0].outputJSON.contains("file2.txt"))
        XCTAssertTrue(results[0].outputJSON.contains("subdir"))
    }

    func testListDirectory_respectsDepth() throws {
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent("level1/level2"),
            withIntermediateDirectories: true
        )
        try "Content".write(
            to: tempDir.appendingPathComponent("level1/level2/deep.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Depth 1 - should not see deep.txt
        let call1 = StepToolCall(
            name: "list_files",
            argumentsJSON: "{\"path\": \".\", \"depth\": 1}"
        )
        let results1 = runtime.executeAll(context: context, toolCalls: [call1])

        XCTAssertFalse(results1[0].isError)
        XCTAssertTrue(results1[0].outputJSON.contains("level1"))
        XCTAssertFalse(results1[0].outputJSON.contains("deep.txt"))

        // Depth 3 - should see deep.txt
        let call3 = StepToolCall(
            name: "list_files",
            argumentsJSON: "{\"path\": \".\", \"depth\": 3}"
        )
        let results3 = runtime.executeAll(context: context, toolCalls: [call3])

        XCTAssertFalse(results3[0].isError)
        XCTAssertTrue(results3[0].outputJSON.contains("deep.txt"))
    }

    func testListDirectory_includesHiddenFiles() throws {
        try "Hidden".write(to: tempDir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try "Visible".write(to: tempDir.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "list_files",
            argumentsJSON: "{\"path\": \".\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("visible.txt"))
        XCTAssertTrue(results[0].outputJSON.contains(".hidden"), "Hidden files should be included")
    }

    func testListDirectory_skipsNoisyDotDirs() throws {
        try "Meta".write(to: tempDir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent(".git"), withIntermediateDirectories: false
        )
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent(".build"), withIntermediateDirectories: false
        )
        try "Visible".write(to: tempDir.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "list_files",
            argumentsJSON: "{\"path\": \".\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("visible.txt"))
        XCTAssertFalse(results[0].outputJSON.contains(".DS_Store"), ".DS_Store should be skipped")
        XCTAssertFalse(results[0].outputJSON.contains(".git"), ".git should be skipped")
        XCTAssertFalse(results[0].outputJSON.contains(".build"), ".build should be skipped")
    }

    func testListDirectory_errorForNonDirectory() throws {
        try "File".write(to: tempDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "list_files",
            argumentsJSON: "{\"path\": \"file.txt\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("NOT_A_DIRECTORY"))
    }

    // MARK: - search Tests

    func testSearchProject_findsMatches() throws {
        try "Hello World".write(to: tempDir.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try "Goodbye World".write(to: tempDir.appendingPathComponent("goodbye.txt"), atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"World\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("hello.txt"))
        XCTAssertTrue(results[0].outputJSON.contains("goodbye.txt"))
    }

    func testSearchProject_caseInsensitive() throws {
        try "UPPERCASE content".write(to: tempDir.appendingPathComponent("upper.txt"), atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"uppercase\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("upper.txt"))
    }

    func testSearchProject_regexMode() throws {
        try "error: file not found".write(to: tempDir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"error:.*found\", \"mode\": \"regex\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("log.txt"))
    }

    func testSearchProject_respectsMaxResults() throws {
        for i in 0..<10 {
            try "match".write(to: tempDir.appendingPathComponent("file\(i).txt"), atomically: true, encoding: .utf8)
        }

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"match\", \"max_results\": 3}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        // Check truncated flag
        XCTAssertTrue(results[0].outputJSON.contains("truncated"))
    }

    // MARK: - read_lines Format Tests

    func testReadLines_usesBoxDrawingSeparator() throws {
        let content = "Alpha\nBeta\nGamma"
        let filePath = tempDir.appendingPathComponent("format.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"format.txt\", \"start_line\": 1, \"end_line\": 3}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        let json = results[0].outputJSON
        // Should contain box-drawing separator, not tab
        XCTAssertTrue(json.contains("\u{2502}"), "Expected box-drawing character \u{2502} in output")
        XCTAssertTrue(json.contains("Alpha"))
        XCTAssertTrue(json.contains("Beta"))
        XCTAssertTrue(json.contains("Gamma"))
    }

    // MARK: - search Glob Metacharacters (Round 4 regression)

    func testSearchProject_GlobWithMetacharacters_EscapesCorrectly() throws {
        // Create files: test.ts, test.tsx, test.py with "match" content
        try "match here".write(to: tempDir.appendingPathComponent("test.ts"), atomically: true, encoding: .utf8)
        try "match here".write(to: tempDir.appendingPathComponent("test.tsx"), atomically: true, encoding: .utf8)
        try "match here".write(to: tempDir.appendingPathComponent("test.py"), atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"match\", \"file_glob\": \"*.ts\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError, "search with glob should not error")
        let json = results[0].outputJSON
        // *.ts should match test.ts but NOT test.tsx or test.py
        XCTAssertTrue(json.contains("test.ts"), "Should find test.ts")
        XCTAssertFalse(json.contains("test.py"), "Should NOT find test.py with *.ts glob")
    }

    // MARK: - Internal Path Restriction Tests

    func testListFiles_hidesInternalDir() throws {
        // Create .nanoteams/internal/ with a file
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        try "secret".write(
            to: paths.internalDir.appendingPathComponent("project.json"),
            atomically: true, encoding: .utf8
        )

        // Also create a visible file in .nanoteams/
        try fileManager.createDirectory(at: paths.tasksDir, withIntermediateDirectories: true)

        let call = StepToolCall(
            name: "list_files",
            argumentsJSON: "{\"path\": \".nanoteams\", \"depth\": 2}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        let json = results[0].outputJSON
        // Should see tasks/ and runs/ but NOT internal/
        XCTAssertTrue(json.contains("tasks"), "Should see tasks dir")
        XCTAssertFalse(json.contains("internal"), "Should NOT see internal dir")
        XCTAssertFalse(json.contains("project.json"), "Should NOT see project.json inside internal")
    }

    func testListFiles_showsAttachments() throws {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let taskID = 0
        let attachDir = paths.taskAttachmentsDir(taskID: taskID)
        try fileManager.createDirectory(at: attachDir, withIntermediateDirectories: true)
        try "image data".write(
            to: attachDir.appendingPathComponent("photo.png"),
            atomically: true, encoding: .utf8
        )

        let call = StepToolCall(
            name: "list_files",
            argumentsJSON: "{\"path\": \".nanoteams/tasks/\(String(taskID))/attachments\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("photo.png"))
    }

    func testReadFile_blocksInternalWorkFolderJSON() throws {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        try "secret config".write(to: paths.workFolderJSON, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \".nanoteams/internal/workfolder.json\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("FILE_NOT_FOUND"))
        // Should NOT contain "permission" or "restricted" — must look like a missing file
        XCTAssertFalse(results[0].outputJSON.contains("PERMISSION"))
        XCTAssertFalse(results[0].outputJSON.contains("restricted"))
    }

    func testReadFile_blocksInternalTaskJSON() throws {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let taskID = 0
        let internalTaskDir = paths.internalTasksDir
            .appendingPathComponent(String(taskID), isDirectory: true)
        try fileManager.createDirectory(at: internalTaskDir, withIntermediateDirectories: true)
        try "task state".write(
            to: internalTaskDir.appendingPathComponent("task.json"),
            atomically: true, encoding: .utf8
        )

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \".nanoteams/internal/tasks/\(String(taskID))/task.json\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("FILE_NOT_FOUND"))
    }

    func testReadFile_allowsAttachments() throws {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let taskID = 0
        let attachDir = paths.taskAttachmentsDir(taskID: taskID)
        try fileManager.createDirectory(at: attachDir, withIntermediateDirectories: true)
        try "file content".write(
            to: attachDir.appendingPathComponent("doc.txt"),
            atomically: true, encoding: .utf8
        )

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \".nanoteams/tasks/\(String(taskID))/attachments/doc.txt\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("file content"))
    }

    func testReadFile_allowsArtifacts() throws {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let runID = 0
        let roleID = "test_role"
        let stepDir = paths.roleDir(taskID: 0, runID: runID, roleID: roleID)
        try fileManager.createDirectory(at: stepDir, withIntermediateDirectories: true)
        try "artifact content".write(
            to: stepDir.appendingPathComponent("artifact_requirements.md"),
            atomically: true, encoding: .utf8
        )

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \".nanoteams/tasks/0/runs/\(String(runID))/roles/\(roleID)/artifact_requirements.md\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("artifact content"))
    }

    func testWriteFile_blocksInternalPath() throws {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)

        let call = StepToolCall(
            name: "write_file",
            argumentsJSON: "{\"path\": \".nanoteams/internal/evil.txt\", \"content\": \"hacked\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("FILE_NOT_FOUND"))
    }

    func testSearch_skipsInternalDir() throws {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        try "secret_token=abc123".write(
            to: paths.internalDir.appendingPathComponent("config.json"),
            atomically: true, encoding: .utf8
        )
        // Also create a visible file with a match
        try "secret_token=visible".write(
            to: tempDir.appendingPathComponent("visible.txt"),
            atomically: true, encoding: .utf8
        )

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"secret_token\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        let json = results[0].outputJSON
        // Should find visible.txt but NOT config.json inside internal/
        XCTAssertTrue(json.contains("visible.txt"))
        XCTAssertFalse(json.contains("config.json"))
    }

    func testDeleteFile_blocksInternalPath() throws {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        try "important".write(
            to: paths.internalDir.appendingPathComponent("workfolder.json"),
            atomically: true, encoding: .utf8
        )

        let call = StepToolCall(
            name: "delete_file",
            argumentsJSON: "{\"path\": \".nanoteams/internal/workfolder.json\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        // File should still exist
        XCTAssertTrue(fileManager.fileExists(atPath: paths.workFolderJSON.path))
    }

    func testReadLines_blocksInternalPath() throws {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        try "line1\nline2\nline3".write(
            to: paths.internalDir.appendingPathComponent("tools.json"),
            atomically: true, encoding: .utf8
        )

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \".nanoteams/internal/tools.json\", \"start_line\": 1, \"end_line\": 3}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("FILE_NOT_FOUND"))
    }

    func testEditFile_blocksInternalPath() throws {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        try "original content".write(
            to: paths.internalDir.appendingPathComponent("tools.json"),
            atomically: true, encoding: .utf8
        )

        let call = StepToolCall(
            name: "edit_file",
            argumentsJSON: "{\"path\": \".nanoteams/internal/tools.json\", \"old_text\": \"original\", \"new_text\": \"hacked\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("FILE_NOT_FOUND"))
        // Original content should be unchanged
        let content = try String(contentsOf: paths.internalDir.appendingPathComponent("tools.json"))
        XCTAssertEqual(content, "original content")
    }

    func testSearch_blocksExplicitInternalPath() throws {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.internalDir, withIntermediateDirectories: true)
        try "secret_data".write(
            to: paths.internalDir.appendingPathComponent("config.json"),
            atomically: true, encoding: .utf8
        )

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"secret_data\", \"paths\": [\".nanoteams/internal\"]}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        // Should error because the explicit path resolves inside internalDir
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("FILE_NOT_FOUND"))
    }

    // MARK: - edit_file Fallback Tests

    func testEditFile_stripsTabLineNumberPrefixes() throws {
        let content = "## Structure\nSome content\nMore content"
        let filePath = tempDir.appendingPathComponent("strip_tab.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        // Simulate LLM copying read_lines tab-delimited output into old_text
        let call = StepToolCall(
            name: "edit_file",
            argumentsJSON: """
            {"path": "strip_tab.txt", "old_text": "6\\t## Structure\\n7\\tSome content", "new_text": "## New Structure\\nNew content"}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError, "edit_file should auto-recover by stripping line-number prefixes")
        let newContent = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertTrue(newContent.contains("## New Structure"))
    }

    func testEditFile_stripsBoxDrawingPrefixes() throws {
        let content = "func hello() {\n    print(\"hi\")\n}"
        let filePath = tempDir.appendingPathComponent("strip_box.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        // Simulate LLM copying new box-drawing format into old_text
        let call = StepToolCall(
            name: "edit_file",
            argumentsJSON: """
            {"path": "strip_box.txt", "old_text": "1   \u{2502} func hello() {\\n2   \u{2502}     print(\\"hi\\")\\n3   \u{2502} }", "new_text": "func goodbye() {\\n    print(\\"bye\\")\\n}"}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError, "edit_file should auto-recover by stripping box-drawing prefixes")
        let newContent = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertTrue(newContent.contains("func goodbye()"))
    }

    func testEditFile_unescapesJSONSlashes() throws {
        let content = "import src/utils/helper"
        let filePath = tempDir.appendingPathComponent("slash.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        // Simulate LLM copying JSON-escaped path with \/
        let call = StepToolCall(
            name: "edit_file",
            argumentsJSON: """
            {"path": "slash.txt", "old_text": "import src\\/utils\\/helper", "new_text": "import src/utils/newhelper"}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError, "edit_file should auto-recover by unescaping JSON slashes")
        let newContent = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertTrue(newContent.contains("src/utils/newhelper"))
    }

    func testEditFile_noFalsePositiveStripping() throws {
        // File content that legitimately starts with digit+tab on only some lines
        let content = "Normal line\n42\tTabbed data\nAnother normal"
        let filePath = tempDir.appendingPathComponent("no_strip.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        // old_text has mixed lines — only one has digit+tab prefix, so stripping should NOT activate
        let call = StepToolCall(
            name: "edit_file",
            argumentsJSON: """
            {"path": "no_strip.txt", "old_text": "Normal line\\n99\\tMissing data", "new_text": "Replaced"}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        // Should fail because stripping requires ALL lines to match, and "Normal line" has no prefix
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("ANCHOR_NOT_FOUND"))
    }

    func testEditFile_exactMatchStillWorks() throws {
        let content = "Hello World\nGoodbye World"
        let filePath = tempDir.appendingPathComponent("exact.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "edit_file",
            argumentsJSON: """
            {"path": "exact.txt", "old_text": "Hello World", "new_text": "Hi World"}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        let newContent = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertEqual(newContent, "Hi World\nGoodbye World")
    }

    // MARK: - search diagnostics (C5 + skipped_binary_count)

    func testSearch_rtfdBundleMissingTXTRTF_surfacesInSkippedFiles() throws {
        // An `.rtfd` directory with no internal `TXT.rtf` must produce an
        // entry in `skipped_files` — not silent omission.
        let rtfdURL = tempDir.appendingPathComponent("broken.rtfd", isDirectory: true)
        try fileManager.createDirectory(at: rtfdURL, withIntermediateDirectories: true)
        // Create a sibling with the query term so matching machinery still runs.
        try "needle here".write(
            to: tempDir.appendingPathComponent("other.txt"),
            atomically: true, encoding: .utf8
        )

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"needle\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("skipped_files"),
                      "missing TXT.rtf must surface via skipped_files: \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("broken.rtfd"),
                      "skipped_files must name the .rtfd bundle: \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("TXT.rtf"),
                      "skipped_files reason should mention TXT.rtf: \(results[0].outputJSON)")
    }

    func testSearch_binaryFiles_counted_notListed() throws {
        // A PNG-like binary (non-UTF8, unsupported extension) should contribute
        // to `skipped_binary_count` without polluting `skipped_files`.
        try "plain text with match".write(
            to: tempDir.appendingPathComponent("text.txt"),
            atomically: true, encoding: .utf8
        )
        // Bytes that can't decode as UTF-8.
        let binary = Data([0xFF, 0xFE, 0x00, 0x80, 0x81])
        try binary.write(to: tempDir.appendingPathComponent("blob.png"))

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"match\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("skipped_binary_count"),
                      "binary skip must emit aggregate counter: \(results[0].outputJSON)")
        XCTAssertFalse(results[0].outputJSON.contains("blob.png"),
                       "binary files must NOT appear in skipped_files: \(results[0].outputJSON)")
    }

    // MARK: - read_lines directory parity (B4)

    func testReadLines_onPlainDirectory_returnsNotAFileError() throws {
        let subdir = tempDir.appendingPathComponent("sub", isDirectory: true)
        try fileManager.createDirectory(at: subdir, withIntermediateDirectories: true)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"sub\", \"start_line\": 1, \"end_line\": 10}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("NOT_A_FILE"),
                      "plain dir must produce NOT_A_FILE, got: \(results[0].outputJSON)")
    }

    func testReadLines_onRTFDBundle_readsContent() throws {
        let rtfdURL = tempDir.appendingPathComponent("note.rtfd", isDirectory: true)
        try fileManager.createDirectory(at: rtfdURL, withIntermediateDirectories: true)
        let rtfContent = #"{\rtf1\ansi Line 1\line Line 2\line Line 3}"#
        try rtfContent.write(
            to: rtfdURL.appendingPathComponent("TXT.rtf"),
            atomically: true, encoding: .utf8
        )

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"note.rtfd\", \"start_line\": 1, \"end_line\": 0}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError,
                       "read_lines must accept .rtfd like read_file: \(results[0].outputJSON)")
    }

    func testReadLines_onMissingFile_stillReturnsFileNotFound() throws {
        // The new directory guard in B4 must not mask the pre-existing
        // FILE_NOT_FOUND response for truly missing paths.
        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"nonexistent.txt\", \"start_line\": 1, \"end_line\": 10}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("FILE_NOT_FOUND"),
                      "missing file must still return FILE_NOT_FOUND, not NOT_A_FILE: \(results[0].outputJSON)")
    }

    func testSearch_rtfdBundleWithValidContent_findsMatches() throws {
        // Happy-path counterpart to testSearch_rtfdBundleMissingTXTRTF: a
        // well-formed .rtfd bundle must still participate in search and NOT
        // appear in skipped_files.
        let rtfdURL = tempDir.appendingPathComponent("good.rtfd", isDirectory: true)
        try fileManager.createDirectory(at: rtfdURL, withIntermediateDirectories: true)
        let rtfContent = #"{\rtf1\ansi This contains the needle we seek}"#
        try rtfContent.write(
            to: rtfdURL.appendingPathComponent("TXT.rtf"),
            atomically: true, encoding: .utf8
        )

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"needle\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("good.rtfd"),
                      "valid .rtfd must appear as a match: \(results[0].outputJSON)")
        XCTAssertFalse(results[0].outputJSON.contains("skipped_files"),
                       "valid .rtfd must NOT appear in skipped_files: \(results[0].outputJSON)")
    }

    func testSearch_multipleBinaryFiles_aggregateCountIsExact() throws {
        // D6 edge case: the counter is an aggregate, not a "saw one" flag.
        try "needle".write(
            to: tempDir.appendingPathComponent("match.txt"),
            atomically: true, encoding: .utf8
        )
        // Three non-UTF-8 binary blobs on unsupported extensions.
        let binary = Data([0xFF, 0xFE, 0x00, 0x80])
        for name in ["a.png", "b.bin", "c.dat"] {
            try binary.write(to: tempDir.appendingPathComponent(name))
        }

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"needle\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("\"skipped_binary_count\" : 3")
                      || results[0].outputJSON.contains("\"skipped_binary_count\":3"),
                      "expected aggregate count of 3 binary files, got: \(results[0].outputJSON)")
    }

    func testSearch_noBinaryFiles_omitsSkippedBinaryCountField() throws {
        // The field is Optional<Int>? and encoded only when > 0 — guards
        // against noise on happy-path responses.
        try "needle text".write(
            to: tempDir.appendingPathComponent("only.txt"),
            atomically: true, encoding: .utf8
        )

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"needle\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertFalse(results[0].outputJSON.contains("skipped_binary_count"),
                       "no binaries → field must be absent: \(results[0].outputJSON)")
    }
}
