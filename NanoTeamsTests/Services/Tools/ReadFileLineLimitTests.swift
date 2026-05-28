import XCTest

@testable import NanoTeams

/// Pins the line-based hard-block behavior of `read_file`:
/// files larger than the configured limit are rejected with an error
/// pointing the LLM at `read_lines`. Default limit is `AppDefaults.readFileMaxLines`.
/// `0` is the "unlimited" sentinel — the size check is skipped entirely.
final class ReadFileLineLimitTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("ReadFileLineLimitTests_\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fm.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        runtime = run
        context = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func runReadFile(args: String, customLimit: Int? = nil) -> ToolExecutionResult {
        let activeRuntime: ToolRuntime
        if let customLimit {
            let paths = NTMSPaths(workFolderRoot: tempDir)
            let (_, run) = ToolRegistry.defaultRegistry(
                workFolderRoot: tempDir,
                toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0),
                readFileMaxLines: customLimit
            )
            activeRuntime = run
        } else {
            activeRuntime = runtime
        }
        let call = StepToolCall(name: "read_file", argumentsJSON: args)
        return activeRuntime.executeAll(context: context, toolCalls: [call])[0]
    }

    private func writeFile(name: String, contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - File within limit

    func testReadFile_smallFile_returnsAllLinesUntruncated() throws {
        let body = (1...50).map { "Line \($0)" }.joined(separator: "\n")
        _ = try writeFile(name: "small.txt", contents: body)

        let r = runReadFile(args: "{\"path\": \"small.txt\"}")

        XCTAssertFalse(r.isError)
        let json = r.outputJSON
        XCTAssertTrue(json.contains("\"end_line\":50") || json.contains("\"end_line\" : 50"))
        XCTAssertTrue(json.contains("\"total_lines\":50") || json.contains("\"total_lines\" : 50"))
        XCTAssertTrue(json.contains("Line 1\\nLine 2"))
        XCTAssertTrue(json.contains("Line 50"))
        // Successful reads must not include a `next` hint nor a truncated marker.
        XCTAssertFalse(json.contains("read_lines"),
                       "in-limit read_file must not include a `next` hint")
        XCTAssertFalse(json.contains("\"truncated\":true") || json.contains("\"truncated\" : true"))
    }

    func testReadFile_exactlyAtLimit_returnsFullContent() throws {
        let limit = AppDefaults.readFileMaxLines
        let body = (1...limit).map { "Line \($0)" }.joined(separator: "\n")
        _ = try writeFile(name: "atLimit.txt", contents: body)

        let r = runReadFile(args: "{\"path\": \"atLimit.txt\"}")

        XCTAssertFalse(r.isError, "file at exactly the limit must succeed")
        let json = r.outputJSON
        XCTAssertTrue(json.contains("\"total_lines\":\(limit)") || json.contains("\"total_lines\" : \(limit)"))
        XCTAssertTrue(json.contains("Line \(limit)"))
        XCTAssertFalse(json.contains("read_lines"))
    }

    // MARK: - File over limit

    func testReadFile_oversizeFile_returnsErrorPointingToReadLines() throws {
        let limit = AppDefaults.readFileMaxLines
        let oversizeLines = limit + 100
        let body = (1...oversizeLines).map { "Line \($0)" }.joined(separator: "\n")
        _ = try writeFile(name: "big.txt", contents: body)

        let r = runReadFile(args: "{\"path\": \"big.txt\"}")

        XCTAssertTrue(r.isError, "file over the limit must be rejected")
        let json = r.outputJSON
        XCTAssertTrue(json.contains("INVALID_ARGS"))
        XCTAssertTrue(json.contains("\(oversizeLines) lines"))
        XCTAssertTrue(json.contains("\(limit)-line read_file limit"))
        XCTAssertTrue(json.contains("read_lines"))
        XCTAssertTrue(json.contains("\"start_line\" : \"1\"") || json.contains("\"start_line\":\"1\""))
        XCTAssertTrue(json.contains("\"end_line\" : \"\(limit)\"") || json.contains("\"end_line\":\"\(limit)\""))
        // Body content must NOT leak into the error result.
        XCTAssertFalse(json.contains("Line 1\\nLine 2"))
    }

    func testReadFile_oneLineOverLimit_returnsError() throws {
        let limit = AppDefaults.readFileMaxLines
        let body = (1...(limit + 1)).map { "Line \($0)" }.joined(separator: "\n")
        _ = try writeFile(name: "overByOne.txt", contents: body)

        let r = runReadFile(args: "{\"path\": \"overByOne.txt\"}")

        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.outputJSON.contains("\(limit + 1) lines"))
    }

    // MARK: - Custom limit threading

    func testReadFile_customLimit_isHonored() throws {
        // 150-line file, registry built with limit=100 → must be rejected with
        // a message that mentions the configured 100 (proves the value flowed
        // all the way from `defaultRegistry(readFileMaxLines:)` into the handler).
        let body = (1...150).map { "Line \($0)" }.joined(separator: "\n")
        _ = try writeFile(name: "custom.txt", contents: body)

        let r = runReadFile(args: "{\"path\": \"custom.txt\"}", customLimit: 100)

        XCTAssertTrue(r.isError)
        let json = r.outputJSON
        XCTAssertTrue(json.contains("100-line read_file limit"))
        XCTAssertTrue(json.contains("150 lines"))
    }

    // MARK: - Unlimited sentinel (0)

    func testReadFile_unlimitedSentinel_readsHugeFile() throws {
        // 5000-line file with limit=0 (unlimited) must succeed and return everything.
        let body = (1...5000).map { "Line \($0)" }.joined(separator: "\n")
        _ = try writeFile(name: "huge.txt", contents: body)

        let r = runReadFile(args: "{\"path\": \"huge.txt\"}", customLimit: 0)

        XCTAssertFalse(r.isError, "limit=0 must skip the size check entirely")
        let json = r.outputJSON
        XCTAssertTrue(json.contains("\"total_lines\":5000") || json.contains("\"total_lines\" : 5000"))
        XCTAssertTrue(json.contains("Line 5000"))
        XCTAssertFalse(json.contains("read_lines"))
    }

    // MARK: - Empty file

    func testReadFile_emptyFile_returnsZeroLines() throws {
        _ = try writeFile(name: "empty.txt", contents: "")

        let r = runReadFile(args: "{\"path\": \"empty.txt\"}")

        XCTAssertFalse(r.isError)
        let json = r.outputJSON
        // Empty string `.components(separatedBy: .newlines)` returns [""] → total_lines = 1.
        XCTAssertTrue(json.contains("\"total_lines\":1") || json.contains("\"total_lines\" : 1"))
    }

    // MARK: - Single super-long line (no defensive byte cap)

    func testReadFile_singleLongLine_readsCompletely() throws {
        // Pathological file: one 50_000-char line. total_lines == 1 ≤ limit, so it
        // succeeds. No byte cap protects here — line semantics is the only contract.
        let oneLine = String(repeating: "x", count: 50_000)
        _ = try writeFile(name: "single.txt", contents: oneLine)

        let r = runReadFile(args: "{\"path\": \"single.txt\"}")

        XCTAssertFalse(r.isError)
        let json = r.outputJSON
        XCTAssertTrue(json.contains("\"total_lines\":1") || json.contains("\"total_lines\" : 1"))
    }

    // MARK: - Non-UTF-8 file rejection (silent-failure regression)

    func testReadFile_invalidUTF8_returnsErrorNotEmptyContent() throws {
        // Bytes that cannot form a valid UTF-8 sequence (continuation bytes
        // without a leading byte, plus 0xFF which never appears in UTF-8).
        // Previous behavior: `try? String(contentsOf:) ?? ""` silently swallowed
        // the failure, returning empty `content` — the LLM concluded the file
        // was empty. Must now return an error envelope so the LLM can switch to
        // a binary-aware tool or warn the user.
        let url = tempDir.appendingPathComponent("garbage.bin")
        let bytes: [UInt8] = [0xFF, 0xFE, 0x80, 0x81, 0xC0, 0xC1, 0xF5]
        try Data(bytes).write(to: url)

        let r = runReadFile(args: "{\"path\": \"garbage.bin\"}")

        XCTAssertTrue(r.isError, "non-UTF-8 file must surface an error envelope")
        let json = r.outputJSON
        XCTAssertTrue(json.lowercased().contains("utf-8") || json.lowercased().contains("not utf"),
                      "error message should mention the encoding problem; got: \(json)")
        // Body content must NOT leak as the empty string into the success channel.
        XCTAssertFalse(json.contains("\"content\":\"\"") || json.contains("\"content\" : \"\""),
                       "must not return empty content as if the file were genuinely empty")
    }

    func testReadFile_oversizeFile_nextHintTargetsCorrectPath() throws {
        // Pins the exact shape of the `next: read_lines` suggestion: path
        // echoes the rejected file, and `end_line` is the configured cap so
        // the LLM's retry stays within the limit read_lines itself enforces.
        let limit = AppDefaults.readFileMaxLines
        let body = (1...(limit + 5)).map { "Line \($0)" }.joined(separator: "\n")
        _ = try writeFile(name: "hint.txt", contents: body)

        let r = runReadFile(args: "{\"path\": \"hint.txt\"}")

        XCTAssertTrue(r.isError)
        let json = r.outputJSON
        XCTAssertTrue(json.contains("\"suggested_cmd\" : \"read_lines\"")
                      || json.contains("\"suggested_cmd\":\"read_lines\""))
        XCTAssertTrue(json.contains("\"path\" : \"hint.txt\"")
                      || json.contains("\"path\":\"hint.txt\""),
                      "next-hint args must echo the rejected path")
        XCTAssertTrue(json.contains("\"end_line\" : \"\(limit)\"")
                      || json.contains("\"end_line\":\"\(limit)\""),
                      "next-hint must bound end_line to the cap")
    }
}
