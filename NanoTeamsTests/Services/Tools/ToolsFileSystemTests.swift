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

    /// End-to-end guard for the slash-escaping fix: the model reads the RAW read
    /// envelope text (not JSON-decoded), so its slashes must be literal there — and
    /// an edit_file anchor copied verbatim from that text must match the file. Before
    /// the fix the envelope showed `..\/systems\/Q.js`, which the model re-typed with
    /// backslashes into an anchor that never matched → an unbreakable edit→re-read loop.
    func testReadThenEditFile_forwardSlashAnchorFromRawEnvelope_matches() throws {
        let original = "import { Q } from '../systems/Q.js';\n"
        let filePath = tempDir.appendingPathComponent("game.js")
        try original.write(to: filePath, atomically: true, encoding: .utf8)

        let read = runtime.executeAll(context: context, toolCalls: [
            StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"game.js\"}")
        ])
        XCTAssertFalse(read[0].isError)
        XCTAssertTrue(read[0].outputJSON.contains("../systems/Q.js"),
                      "raw read envelope must show literal slashes: \(read[0].outputJSON)")
        XCTAssertFalse(read[0].outputJSON.contains("..\\/systems"),
                       "raw read envelope must not escape slashes to \\/: \(read[0].outputJSON)")

        // Anchor copied verbatim from what the model saw must match on disk.
        let anchor = "import { Q } from '../systems/Q.js';"
        let edit = runtime.executeAll(context: context, toolCalls: [
            StepToolCall(
                name: "edit_file",
                argumentsJSON: "{\"path\":\"game.js\",\"old_text\":\"\(anchor)\",\"new_text\":\"import { Q } from '../systems/Quad.js';\"}"
            )
        ])
        XCTAssertFalse(edit[0].isError, "edit with forward-slash anchor must match: \(edit[0].outputJSON)")
        let updated = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertTrue(updated.contains("../systems/Quad.js"), "edit must have applied: \(updated)")
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

    /// With "/" resolving to the work-folder root, `read_file {"path": "/"}` composes with
    /// the existing directory rejection: NOT_A_FILE + a `next: list_files` hint whose
    /// suggested call now works (previously the whole path form was PERMISSION_DENIED).
    func testReadFile_slashPath_returnsNotAFileWithListFilesHint() throws {
        let call = StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"/\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("NOT_A_FILE"), results[0].outputJSON)
        XCTAssertTrue(results[0].outputJSON.contains("list_files"), "directory rejection must steer to list_files: \(results[0].outputJSON)")
    }

    func testReadFile_largeFile_returnsErrorPointingToReadLines() throws {
        // File over the configured limit → hard-block error pointing at `read_lines`.
        let limit = AppDefaults.readFileMaxLines
        let largeContent = (1...(limit + 200)).map { "Line \($0)" }.joined(separator: "\n")
        let filePath = tempDir.appendingPathComponent("large.txt")
        try largeContent.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"large.txt\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        let json = results[0].outputJSON
        XCTAssertTrue(json.contains("INVALID_ARGS"))
        XCTAssertTrue(json.contains("\(limit)-line read_file limit"))
        XCTAssertTrue(json.contains("read_lines"))
    }

    func testReadFile_inLimitFile_returnsAllLines() throws {
        let content = (1...100).map { "Line \($0)" }.joined(separator: "\n")
        let filePath = tempDir.appendingPathComponent("medium.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"medium.txt\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        let json = results[0].outputJSON
        XCTAssertTrue(json.contains("\"total_lines\":100") || json.contains("\"total_lines\" : 100"))
        XCTAssertTrue(json.contains("\"end_line\":100") || json.contains("\"end_line\" : 100"))
        XCTAssertTrue(json.contains("Line 100"))
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

    // Transposed range (start > end): per CORE_PRINCIPLES the runtime silently
    // swaps the bounds rather than erroring. `start_line: 3, end_line: 1` on a
    // 2-line file → swap to 1..3, clamp to file length, read both lines.
    func testReadFileRange_transposedRange_silentlySwaps() throws {
        let content = "Line 1\nLine 2"
        let filePath = tempDir.appendingPathComponent("test.txt")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"test.txt\", \"start_line\": 3, \"end_line\": 1}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(
            results[0].isError,
            "Transposed range must succeed (silent swap), not error. Got: \(results[0].outputJSON)"
        )
        let json = results[0].outputJSON
        XCTAssertTrue(json.contains("\"start_line\":1") || json.contains("\"start_line\" : 1"))
        XCTAssertTrue(json.contains("\"end_line\":2") || json.contains("\"end_line\" : 2"))
        XCTAssertTrue(json.contains("Line 1") && json.contains("Line 2"))
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

    /// The exact call from the reported bug: `list_files {"path": "/", "depth": 1}` —
    /// chroot-style "/" means the work-folder root and must list it, not PERMISSION_DENIED.
    func testListDirectory_slashPath_listsRootContents() throws {
        try "One".write(to: tempDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(
            at: tempDir.appendingPathComponent("subdir"), withIntermediateDirectories: false
        )

        let call = StepToolCall(
            name: "list_files",
            argumentsJSON: "{\"path\": \"/\", \"depth\": 1}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError, "\"/\" must resolve to the work-folder root: \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("file1.txt"))
        XCTAssertTrue(results[0].outputJSON.contains("subdir"))
    }

    // MARK: - list_files Result Shape

    /// `data` of a successful `list_files` result.
    private func listData(_ json: String) throws -> [String: Any] {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            "not a JSON object: \(json)"
        )
        return try XCTUnwrap(root["data"] as? [String: Any], "no data in: \(json)")
    }

    private func runListFiles(_ argumentsJSON: String) -> ToolExecutionResult {
        runtime.executeAll(
            context: context,
            toolCalls: [StepToolCall(name: "list_files", argumentsJSON: argumentsJSON)]
        )[0]
    }

    func testListFiles_splitsFilesAndDirs() throws {
        // Listed from a dedicated subdirectory, not the work-folder root: the root
        // also holds the fixture's `.nanoteams`, which would make exact-array
        // assertions couple to setUp instead of to the split behaviour.
        let proj = tempDir.appendingPathComponent("proj", isDirectory: true)
        try fileManager.createDirectory(at: proj, withIntermediateDirectories: true)
        try "A".write(to: proj.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(
            at: proj.appendingPathComponent("sub"), withIntermediateDirectories: false
        )

        let result = runListFiles("{\"path\": \"proj\"}")
        let data = try listData(result.outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["proj/a.txt"])
        XCTAssertEqual(try XCTUnwrap(data["dirs"] as? [String]), ["proj/sub"])
        // The redundant per-entry fields are gone from the whole envelope.
        XCTAssertFalse(result.outputJSON.contains("\"name\""), result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("\"type\""), result.outputJSON)
    }

    /// THE regression this change exists for: an entry taken verbatim out of a
    /// subdirectory listing must be a valid `read_file` argument. Before the fix
    /// entries were relative to the REQUESTED directory while `read_file` resolves
    /// from the work-folder root, so this round-trip silently missed.
    func testListFiles_subdirEntry_feedsDirectlyIntoReadFile() throws {
        let sources = tempDir.appendingPathComponent("Sources")
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        try "let x = 1".write(
            to: sources.appendingPathComponent("Calculator.swift"), atomically: true, encoding: .utf8
        )

        let listing = try listData(runListFiles("{\"path\": \"Sources\"}").outputJSON)
        let entry = try XCTUnwrap((listing["files"] as? [String])?.first)

        let readCall = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"\(entry)\"}"
        )
        let read = runtime.executeAll(context: context, toolCalls: [readCall])[0]

        XCTAssertFalse(read.isError, "entry '\(entry)' must feed straight into read_file: \(read.outputJSON)")
        XCTAssertTrue(read.outputJSON.contains("let x = 1"), read.outputJSON)
    }

    func testListFiles_pathsAreWorkFolderRootRelative() throws {
        let sources = tempDir.appendingPathComponent("Sources")
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        try "x".write(to: sources.appendingPathComponent("Calculator.swift"), atomically: true, encoding: .utf8)

        let data = try listData(runListFiles("{\"path\": \"Sources\"}").outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["Sources/Calculator.swift"])
    }

    /// The residual risk of the root-relative fix: a model that habitually joins
    /// `data.path` with an entry would produce `Sources/Sources/…`. The shape must
    /// make the join structurally unnecessary — entries already carry the prefix.
    func testListFiles_entryAlreadyContainsRequestedPath() throws {
        let nested = tempDir.appendingPathComponent("a/b")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try "x".write(to: nested.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)

        let data = try listData(runListFiles("{\"path\": \"a/b\"}").outputJSON)
        let echoed = try XCTUnwrap(data["path"] as? String)

        XCTAssertEqual(echoed, "a/b")
        for entry in try XCTUnwrap(data["files"] as? [String]) {
            XCTAssertTrue(entry.hasPrefix(echoed + "/"), "entry '\(entry)' should already start with '\(echoed)'")
        }
    }

    func testListFiles_countMatchesArrays() throws {
        let proj = tempDir.appendingPathComponent("proj", isDirectory: true)
        try fileManager.createDirectory(at: proj, withIntermediateDirectories: true)
        try "A".write(to: proj.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "B".write(to: proj.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(
            at: proj.appendingPathComponent("sub"), withIntermediateDirectories: false
        )

        let data = try listData(runListFiles("{\"path\": \"proj\"}").outputJSON)
        let files = try XCTUnwrap(data["files"] as? [String])
        let dirs = try XCTUnwrap(data["dirs"] as? [String])

        XCTAssertEqual(try XCTUnwrap(data["count"] as? Int), files.count + dirs.count)
        XCTAssertEqual(try XCTUnwrap(data["count"] as? Int), 3)
    }

    /// Stable shape beats a shape that varies: an empty `dirs` is the real answer
    /// "no subdirectories here", not an exception marker to be omitted.
    func testListFiles_emptyDirsArrayStillEmitted() throws {
        let proj = tempDir.appendingPathComponent("proj", isDirectory: true)
        try fileManager.createDirectory(at: proj, withIntermediateDirectories: true)
        try "A".write(to: proj.appendingPathComponent("only.txt"), atomically: true, encoding: .utf8)

        let data = try listData(runListFiles("{\"path\": \"proj\"}").outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["dirs"] as? [String]), [])
        XCTAssertNotNil(data["files"])
    }

    func testListFiles_slashPath_echoesNormalizedPath() throws {
        try "One".write(to: tempDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)

        let data = try listData(runListFiles("{\"path\": \"/\"}").outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["path"] as? String), ".")
    }

    /// `.withoutEscapingSlashes` is load-bearing: escaped `\/` in paths makes small
    /// models emit literal backslashes in edit_file anchors. Nested paths make it
    /// more load-bearing than before, so pin it here too.
    func testListFiles_forwardSlashesUnescaped() throws {
        let nested = tempDir.appendingPathComponent("a/b")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try "x".write(to: nested.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)

        let json = runListFiles("{\"path\": \".\", \"depth\": 3}").outputJSON

        XCTAssertTrue(json.contains("a/b/deep.txt"), json)
        XCTAssertFalse(json.contains("\\/"), "forward slashes must not be escaped: \(json)")
    }

    // MARK: - list_files Truncation

    private func seedFlatFiles(_ count: Int) throws {
        let dir = tempDir.appendingPathComponent("many", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<count {
            fileManager.createFile(atPath: dir.appendingPathComponent("f\(i).txt").path, contents: Data())
        }
    }

    /// Off-by-one regression: a directory holding EXACTLY the cap is a complete
    /// listing and must not claim truncation — the old `>=` provoked a needless
    /// narrowing re-call.
    func testListFiles_exactlyAtCap_notReportedTruncated() throws {
        try seedFlatFiles(ToolConstants.maxDirectoryEntries)

        let result = runListFiles("{\"path\": \"many\"}")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let data = try XCTUnwrap(root["data"] as? [String: Any])
        let meta = try XCTUnwrap(root["meta"] as? [String: Any])

        XCTAssertEqual(try XCTUnwrap(data["count"] as? Int), ToolConstants.maxDirectoryEntries)
        XCTAssertEqual(meta["truncated"] as? Bool, false)
    }

    func testListFiles_overCap_reportsTruncatedWithWarning() throws {
        try seedFlatFiles(ToolConstants.maxDirectoryEntries + 5)

        let result = runListFiles("{\"path\": \"many\"}")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let data = try XCTUnwrap(root["data"] as? [String: Any])
        let meta = try XCTUnwrap(root["meta"] as? [String: Any])

        XCTAssertEqual(try XCTUnwrap(data["count"] as? Int), ToolConstants.maxDirectoryEntries)
        XCTAssertEqual(meta["truncated"] as? Bool, true)
        // No-silent-caps: the cut must come with a way out, not just a flag.
        let warnings = try XCTUnwrap(meta["warnings"] as? [String])
        XCTAssertTrue(warnings.contains { $0.contains("name_glob") }, "\(warnings)")
    }

    // MARK: - list_files Corners: path base resolution

    /// Builds the args JSON through JSONSerialization so non-ASCII and quoted
    /// names can't be broken by hand-escaping.
    private func runList(_ args: [String: Any]) throws -> ToolExecutionResult {
        let data = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        return runtime.executeAll(
            context: context, toolCalls: [StepToolCall(name: "list_files", argumentsJSON: json)]
        )[0]
    }

    private func seed(_ relativePaths: [String]) throws {
        for rel in relativePaths {
            let url = tempDir.appendingPathComponent(rel)
            if rel.hasSuffix("/") {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try "x".write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    func testListFiles_pathOmitted_listsRootWithNoPrefix() throws {
        try seed(["top.txt"])

        let data = try listData(try runList([:]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["path"] as? String), ".")
        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["top.txt"])
    }

    func testListFiles_emptyStringPath_listsRoot() throws {
        try seed(["top.txt"])

        let data = try listData(try runList(["path": ""]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["path"] as? String), ".")
        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["top.txt"])
    }

    func testListFiles_trailingSlashPath_normalizesPrefix() throws {
        try seed(["Sources/a.swift"])

        let data = try listData(try runList(["path": "Sources/"]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["path"] as? String), "Sources")
        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["Sources/a.swift"])
    }

    func testListFiles_dotSlashPath_normalizesPrefix() throws {
        try seed(["Sources/a.swift"])

        let data = try listData(try runList(["path": "./Sources"]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["path"] as? String), "Sources")
        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["Sources/a.swift"])
    }

    /// The prefix is derived from the RESOLVED url, so an absolute in-sandbox path
    /// (models paste these) comes back relativized rather than absolute.
    func testListFiles_absoluteInSandboxPath_prefixIsRelativized() throws {
        try seed(["Sources/a.swift"])

        let data = try listData(
            try runList(["path": tempDir.appendingPathComponent("Sources").path]).outputJSON
        )

        XCTAssertEqual(try XCTUnwrap(data["path"] as? String), "Sources")
        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["Sources/a.swift"])
    }

    /// Deriving the prefix from the resolved url (not the raw arg) means a
    /// redundant work-folder-name component is echoed back in canonical form —
    /// the model sees the spelling that its next call should use.
    func testListFiles_redundantWorkFolderNamePrefix_echoesCanonicalPath() throws {
        try seed(["Sources/a.swift"])
        let folderName = tempDir.lastPathComponent

        let data = try listData(try runList(["path": "\(folderName)/Sources"]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["path"] as? String), "Sources")
        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["Sources/a.swift"])
    }

    func testListFiles_deeplyNestedRequest_prefixesEveryComponent() throws {
        try seed(["a/b/c/leaf.txt"])

        let data = try listData(try runList(["path": "a/b/c"]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["path"] as? String), "a/b/c")
        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["a/b/c/leaf.txt"])
    }

    // MARK: - list_files Corners: shape and ordering

    func testListFiles_emptyDirectory_zeroCountBothArraysPresent() throws {
        try seed(["empty/"])

        let data = try listData(try runList(["path": "empty"]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["count"] as? Int), 0)
        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), [])
        XCTAssertEqual(try XCTUnwrap(data["dirs"] as? [String]), [])
    }

    func testListFiles_onlyDirectories_filesArrayEmptyButPresent() throws {
        try seed(["only/one/", "only/two/"])

        let data = try listData(try runList(["path": "only"]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), [])
        XCTAssertEqual(try XCTUnwrap(data["dirs"] as? [String]), ["only/one", "only/two"])
    }

    /// Ordering is by PATH, so each subtree stays contiguous. Under the old
    /// basename key this returned ["b/apple.txt", "a/zebra.txt"], which reads as
    /// unsorted once the per-entry `name` is gone.
    func testListFiles_ordering_isByPathNotBasename() throws {
        try seed(["a/zebra.txt", "b/apple.txt"])

        let data = try listData(try runList(["path": ".", "depth": 2]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["a/zebra.txt", "b/apple.txt"])
    }

    /// `localizedStandardCompare` survives the switch to the path key, so numbered
    /// files stay in natural order rather than lexicographic.
    func testListFiles_ordering_isNaturalNotLexicographic() throws {
        try seed(["n/f2.txt", "n/f10.txt"])

        let data = try listData(try runList(["path": "n"]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["n/f2.txt", "n/f10.txt"])
    }

    /// A file and a directory sharing a name are distinguishable by ARRAY, with no
    /// in-band marker to misread — the property that ruled out the trailing-slash
    /// encoding.
    func testListFiles_sameNameAsFileAndDirectory_noAmbiguity() throws {
        try seed(["x/report/", "y/report"])

        let data = try listData(try runList(["path": ".", "depth": 2]).outputJSON)

        XCTAssertTrue(try XCTUnwrap(data["dirs"] as? [String]).contains("x/report"))
        XCTAssertTrue(try XCTUnwrap(data["files"] as? [String]).contains("y/report"))
    }

    func testListFiles_nonASCIIAndSpacedNames_roundTripIntact() throws {
        try seed(["Ресурсы/файл тест.txt"])

        let data = try listData(try runList(["path": "Ресурсы"]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["Ресурсы/файл тест.txt"])
    }

    /// The constant `meta` block was deliberately KEPT (its presence is the
    /// mechanically checkable half of the no-silent-caps rule).
    func testListFiles_untruncated_stillEmitsMetaBlock() throws {
        try seed(["a.txt"])

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try runList(["path": "."]).outputJSON.utf8))
                as? [String: Any]
        )
        let meta = try XCTUnwrap(root["meta"] as? [String: Any])

        XCTAssertEqual(meta["truncated"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(meta["warnings"] as? [String]), [])
    }

    // MARK: - list_files Corners: glob, depth, skips

    func testListFiles_globMatchingOnlyDirs_leavesFilesEmpty() throws {
        try seed(["g/keep.d/", "g/drop.txt"])

        let data = try listData(try runList(["path": "g", "name_glob": "*.d"]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["dirs"] as? [String]), ["g/keep.d"])
        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), [])
    }

    func testListFiles_globMatchingNothing_succeedsWithZeroCount() throws {
        try seed(["g/a.txt"])

        let result = try runList(["path": "g", "name_glob": "*.never"])
        let data = try listData(result.outputJSON)

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try XCTUnwrap(data["count"] as? Int), 0)
    }

    /// The glob matches the BASENAME while the emitted path is full — removing the
    /// `name` field must not have moved the filter onto the path.
    func testListFiles_globMatchesBasename_whilePathStaysFull() throws {
        try seed(["deep/nested/target.gd", "deep/nested/other.txt"])

        let data = try listData(
            try runList(["path": ".", "depth": 3, "name_glob": "*.gd"]).outputJSON
        )

        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["deep/nested/target.gd"])
    }

    /// THE field shape: models orient themselves by calling `list_files` with
    /// `depth: 0` on the work-folder root — recursion depth is habitually counted
    /// from zero. Before the floor this answered with a successful EMPTY listing,
    /// i.e. "your project is empty", at the very first exploration step.
    func testListFiles_depthZeroOnRoot_listsImmediateChildren() throws {
        try seed(["top.txt", "sub/"])

        let result = try runList(["depth": 0])
        let data = try listData(result.outputJSON)

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["top.txt"])
        XCTAssertTrue(try XCTUnwrap(data["dirs"] as? [String]).contains("sub"))
    }

    /// The scale is 0-indexed RECURSION depth: 0 is this folder's direct contents,
    /// 1 already reaches into its subfolders. Pinning both tiers against the same
    /// tree is what makes the indexing falsifiable — an off-by-one either way
    /// breaks exactly one of these two assertions.
    func testListFiles_depthScale_isZeroIndexedRecursion() throws {
        try seed(["d/a.txt", "d/nested/deep.txt"])

        let zero = try listData(try runList(["path": "d", "depth": 0]).outputJSON)
        let one = try listData(try runList(["path": "d", "depth": 1]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(zero["files"] as? [String]), ["d/a.txt"],
                       "depth 0 = direct contents only, no recursion")
        XCTAssertEqual(try XCTUnwrap(one["files"] as? [String]), ["d/a.txt", "d/nested/deep.txt"],
                       "depth 1 = one level deeper, so the subfolder's contents appear")
    }

    /// Omitting `depth` must behave as `depth: 0` — the default is the base of the
    /// scale, so the overwhelmingly common no-arg call is unaffected by the indexing.
    func testListFiles_depthOmitted_equivalentToDepthZero() throws {
        try seed(["d/a.txt", "d/nested/deep.txt"])

        let omitted = try listData(try runList(["path": "d"]).outputJSON)
        let zero = try listData(try runList(["path": "d", "depth": 0]).outputJSON)

        XCTAssertEqual(omitted["files"] as? [String], zero["files"] as? [String])
        XCTAssertEqual(omitted["dirs"] as? [String], zero["dirs"] as? [String])
    }

    /// A wild depth must not overflow the internal `depth + 1`.
    func testListFiles_intMaxDepth_doesNotOverflow() throws {
        try seed(["d/a.txt"])

        let result = try runList(["path": "d", "depth": Int.max])

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try XCTUnwrap(try listData(result.outputJSON)["files"] as? [String]), ["d/a.txt"])
    }

    /// Negative depth is the same class of nonsense as zero and takes the same floor
    /// rather than silently reporting an empty directory.
    func testListFiles_negativeDepth_listsImmediateChildren() throws {
        try seed(["d/a.txt"])

        let data = try listData(try runList(["path": "d", "depth": -3]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["d/a.txt"])
    }

    /// The string-encoded path takes the floor too — coercion happens before it.
    func testListFiles_depthZeroAsString_listsImmediateChildren() throws {
        try seed(["d/a.txt"])

        let data = try listData(try runList(["path": "d", "depth": "0"]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["d/a.txt"])
    }

    func testListFiles_depthBeyondTree_listsEverythingWithoutError() throws {
        try seed(["d/a/b.txt"])

        let result = try runList(["path": "d", "depth": 99])
        let data = try listData(result.outputJSON)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["d/a/b.txt"])
        XCTAssertEqual(try XCTUnwrap(data["dirs"] as? [String]), ["d/a"])
    }

    /// WalkSkipRules must keep applying below the first level, not just at the root.
    func testListFiles_skipRules_applyAtNestedDepth() throws {
        try seed(["proj/src/main.swift", "proj/node_modules/pkg.js"])

        let data = try listData(try runList(["path": "proj", "depth": 3]).outputJSON)
        let all = try XCTUnwrap(data["files"] as? [String]) + (try XCTUnwrap(data["dirs"] as? [String]))

        XCTAssertTrue(all.contains("proj/src/main.swift"), "\(all)")
        XCTAssertFalse(all.contains { $0.contains("node_modules") }, "\(all)")
    }

    /// A dangling symlink fails the `fileExists` probe and is skipped rather than
    /// listed as a file the model would then fail to read.
    func testListFiles_danglingSymlink_isSkipped() throws {
        try seed(["s/real.txt"])
        try fileManager.createSymbolicLink(
            atPath: tempDir.appendingPathComponent("s/broken.txt").path,
            withDestinationPath: tempDir.appendingPathComponent("s/does_not_exist.txt").path
        )

        let data = try listData(try runList(["path": "s"]).outputJSON)

        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["s/real.txt"])
    }

    // MARK: - list_files Corners: truncation boundary

    /// One past the cap is the smallest input that must report truncation, and the
    /// probe entry must not leak into the payload.
    func testListFiles_exactlyOneOverCap_truncatesAndDropsProbe() throws {
        try seedFlatFiles(ToolConstants.maxDirectoryEntries + 1)

        let result = runListFiles("{\"path\": \"many\"}")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let data = try XCTUnwrap(root["data"] as? [String: Any])
        let files = try XCTUnwrap(data["files"] as? [String])

        XCTAssertEqual(files.count, ToolConstants.maxDirectoryEntries)
        XCTAssertEqual(try XCTUnwrap(data["count"] as? Int), files.count)
        XCTAssertEqual((root["meta"] as? [String: Any])?["truncated"] as? Bool, true)
    }

    /// The cap counts entries actually LISTED, so a glob that filters most of the
    /// directory away must not trip truncation.
    func testListFiles_capCountsMatchingEntriesOnly_notScannedOnes() throws {
        try seedFlatFiles(ToolConstants.maxDirectoryEntries + 5)
        try "x".write(
            to: tempDir.appendingPathComponent("many/unique.gd"), atomically: true, encoding: .utf8
        )

        let result = runListFiles("{\"path\": \"many\", \"name_glob\": \"*.gd\"}")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let data = try XCTUnwrap(root["data"] as? [String: Any])

        XCTAssertEqual(try XCTUnwrap(data["files"] as? [String]), ["many/unique.gd"])
        XCTAssertEqual((root["meta"] as? [String: Any])?["truncated"] as? Bool, false)
    }

    // MARK: - Slash-Path Write-Side Safety

    /// SAFETY: now that "/" resolves to the real work-folder root, a model that fat-fingers
    /// `delete_file {"path": "/"}` must NOT delete the work folder — the directory guard
    /// rejects it with NOT_A_FILE and everything survives.
    func testDeleteFile_slashPath_rejectedAndWorkFolderPreserved() throws {
        let call = StepToolCall(name: "delete_file", argumentsJSON: "{\"path\": \"/\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("NOT_A_FILE"), results[0].outputJSON)
        var isDir: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: tempDir.path, isDirectory: &isDir) && isDir.boolValue,
                      "work folder must survive a delete_file on \"/\"")
        XCTAssertTrue(fileManager.fileExists(atPath: NTMSPaths(workFolderRoot: tempDir).nanoteamsDir.path),
                      ".nanoteams must survive")
    }

    /// SAFETY: `write_file {"path": "/"}` cannot clobber the work-folder root — writing a
    /// file over an existing directory fails, so the call errors and the folder survives.
    func testWriteFile_slashPath_rejectedAndWorkFolderPreserved() throws {
        let call = StepToolCall(
            name: "write_file",
            argumentsJSON: "{\"path\": \"/\", \"content\": \"nope\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError, "write_file on \"/\" must fail: \(results[0].outputJSON)")
        var isDir: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: tempDir.path, isDirectory: &isDir) && isDir.boolValue,
                      "work folder must survive a write_file on \"/\"")
        XCTAssertTrue(fileManager.fileExists(atPath: NTMSPaths(workFolderRoot: tempDir).nanoteamsDir.path),
                      ".nanoteams must survive")
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

        // Asserted on the PARSED path arrays, not on substrings of the whole
        // envelope: a bare `json.contains("internal")` passes for the wrong
        // reason and would false-fail on any future envelope field that merely
        // spells the word.
        let data = try listData(results[0].outputJSON)
        let entries = try XCTUnwrap(data["files"] as? [String]) + (try XCTUnwrap(data["dirs"] as? [String]))

        XCTAssertTrue(entries.contains(".nanoteams/tasks"), "Should see tasks dir: \(entries)")
        XCTAssertFalse(
            entries.contains { $0.split(separator: "/").contains("internal") },
            "Should NOT see the internal dir: \(entries)"
        )
        XCTAssertFalse(
            entries.contains { ($0 as NSString).lastPathComponent == "project.json" },
            "Should NOT see project.json inside internal: \(entries)"
        )
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
        let content = try String(contentsOf: paths.internalDir.appendingPathComponent("tools.json"), encoding: .utf8)
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

    // MARK: - search: empty-query "list files" mode

    func testSearch_emptyQueryWithGlob_listsFilenameMatches() throws {
        try fileManager.createDirectory(at: tempDir.appendingPathComponent("scenes"), withIntermediateDirectories: true)
        try "extends Node".write(to: tempDir.appendingPathComponent("scenes/Player.gd"), atomically: true, encoding: .utf8)
        try "extends Body".write(to: tempDir.appendingPathComponent("Slime.gd"), atomically: true, encoding: .utf8)
        try "# docs".write(to: tempDir.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)

        let call = StepToolCall(name: "search", argumentsJSON: "{\"query\": \"\", \"file_glob\": \"*.gd\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError, results[0].outputJSON)
        XCTAssertTrue(results[0].outputJSON.contains("filename_matches"))
        XCTAssertTrue(results[0].outputJSON.contains("Player.gd"))
        XCTAssertTrue(results[0].outputJSON.contains("Slime.gd"))
        XCTAssertFalse(results[0].outputJSON.contains("readme.md"),
                       "The *.gd glob must exclude the .md file.")
    }

    func testSearch_emptyQueryNoConstraint_returnsError() throws {
        let call = StepToolCall(name: "search", argumentsJSON: "{\"query\": \"\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError, "Empty query with no file_glob/paths must be an error, not a silent zero.")
        XCTAssertTrue(results[0].outputJSON.contains("empty query requires file_glob or paths"),
                      results[0].outputJSON)
    }

    func testSearch_emptyQuery_blankPathsEntry_returnsError() throws {
        // paths:[""] resolves to the work-folder root — a present-but-empty
        // constraint must NOT slip an empty query into a whole-tree walk.
        try "x".write(to: tempDir.appendingPathComponent("some.gd"), atomically: true, encoding: .utf8)
        let argsData = try JSONSerialization.data(withJSONObject: ["query": "", "paths": [""]])
        let call = StepToolCall(name: "search", argumentsJSON: String(data: argsData, encoding: .utf8)!)
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError, "paths:[\"\"] is not a real constraint: \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("empty query requires file_glob or paths"))
    }

    func testSearch_emptyQuery_paddedFileGlob_stillLists() throws {
        // A whitespace-padded glob (common LLM emission artifact) must be
        // trimmed, not silently match nothing.
        try "x".write(to: tempDir.appendingPathComponent("Player.gd"), atomically: true, encoding: .utf8)
        let call = StepToolCall(name: "search", argumentsJSON: "{\"query\": \"\", \"file_glob\": \"*.gd \"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError, results[0].outputJSON)
        XCTAssertTrue(results[0].outputJSON.contains("Player.gd"),
                      "A padded glob must be trimmed, not silently match nothing: \(results[0].outputJSON)")
    }

    func testSearch_emptyQuery_emptyFileGlob_returnsError() throws {
        // file_glob:"" compiles to ^$ (matches nothing) — treat as no constraint
        // (typed error), not a silent zero.
        try "x".write(to: tempDir.appendingPathComponent("some.gd"), atomically: true, encoding: .utf8)
        let call = StepToolCall(name: "search", argumentsJSON: "{\"query\": \"\", \"file_glob\": \"\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError, "file_glob:\"\" is not a real constraint: \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("empty query requires file_glob or paths"))
    }

    func testSearch_emptyQueryWithGlob_exploratoryDefaultOn_stillListsViaPlainPath() throws {
        // With exploratory default ON, a non-empty query would route to the
        // vector pass. An empty query has nothing to expand, so it must fall
        // through to the plain list path BEFORE the exploratory branch — not
        // hit the exploratory `emptyQuery` throw.
        try "extends Node".write(to: tempDir.appendingPathComponent("Player.gd"), atomically: true, encoding: .utf8)
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let (_, exploratoryRuntime) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 1),
            searchExploratoryByDefault: true
        )

        let call = StepToolCall(name: "search", argumentsJSON: "{\"query\": \"\", \"file_glob\": \"*.gd\"}")
        let results = exploratoryRuntime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError, results[0].outputJSON)
        XCTAssertTrue(results[0].outputJSON.contains("Player.gd"))
        XCTAssertFalse(results[0].outputJSON.contains("exploring"),
                       "Empty query must NOT enter the exploratory pass.")
    }

    // MARK: - list_files: name_glob filter

    func testListFiles_nameGlob_filtersToMatchingFiles() throws {
        try "a".write(to: tempDir.appendingPathComponent("a.gd"), atomically: true, encoding: .utf8)
        try "b".write(to: tempDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let call = StepToolCall(name: "list_files", argumentsJSON: "{\"path\": \".\", \"name_glob\": \"*.gd\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("a.gd"))
        XCTAssertFalse(results[0].outputJSON.contains("b.txt"),
                       "name_glob *.gd must exclude b.txt.")
    }

    func testListFiles_nameGlob_recursesButFiltersEntries() throws {
        // A non-matching subdirectory is still traversed so nested matches are
        // reachable; the subdirectory itself is filtered out of the listing.
        try fileManager.createDirectory(at: tempDir.appendingPathComponent("scenes"), withIntermediateDirectories: true)
        try "deep".write(to: tempDir.appendingPathComponent("scenes/Enemy.gd"), atomically: true, encoding: .utf8)
        try "top".write(to: tempDir.appendingPathComponent("Main.gd"), atomically: true, encoding: .utf8)

        let call = StepToolCall(name: "list_files", argumentsJSON: "{\"path\": \".\", \"depth\": 3, \"name_glob\": \"*.gd\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Main.gd"))
        XCTAssertTrue(results[0].outputJSON.contains("Enemy.gd"),
                      "Nested match must be reachable even though its parent dir doesn't match the glob.")
    }

    func testListFiles_invalidNameGlob_returnsError() throws {
        // The uncompilable-glob sentinel must surface as a typed error, not a
        // fail-closed empty listing.
        let argsData = try JSONSerialization.data(
            withJSONObject: ["path": ".", "name_glob": CompiledGlob._testUncompilableGlobSentinel])
        let argsJSON = String(data: argsData, encoding: .utf8)!
        let call = StepToolCall(name: "list_files", argumentsJSON: argsJSON)
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].isError, "An uncompilable name_glob must error, not fail-close silently.")
        XCTAssertTrue(results[0].outputJSON.contains("name_glob"),
                      "Error must name the actual parameter: \(results[0].outputJSON)")
        XCTAssertFalse(results[0].outputJSON.contains("file_glob"),
                       "Error must NOT name file_glob — list_files has no such parameter: \(results[0].outputJSON)")
    }

    func testListFiles_paddedNameGlob_stillFilters() throws {
        // A whitespace-padded name_glob must be trimmed, not silently exclude
        // every entry.
        try "x".write(to: tempDir.appendingPathComponent("a.gd"), atomically: true, encoding: .utf8)
        try "x".write(to: tempDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let call = StepToolCall(name: "list_files", argumentsJSON: "{\"path\": \".\", \"name_glob\": \"*.gd \"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError, results[0].outputJSON)
        XCTAssertTrue(results[0].outputJSON.contains("a.gd"),
                      "Padded name_glob must be trimmed: \(results[0].outputJSON)")
        XCTAssertFalse(results[0].outputJSON.contains("b.txt"))
    }

    func testListFiles_emptyNameGlob_listsAll() throws {
        // name_glob:"" must mean "no filter", not "match nothing" (^$).
        try "x".write(to: tempDir.appendingPathComponent("a.gd"), atomically: true, encoding: .utf8)
        try "x".write(to: tempDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let call = StepToolCall(name: "list_files", argumentsJSON: "{\"path\": \".\", \"name_glob\": \"\"}")
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError, results[0].outputJSON)
        XCTAssertTrue(results[0].outputJSON.contains("a.gd"),
                      "Empty name_glob must not silently exclude everything: \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("b.txt"))
    }
}
