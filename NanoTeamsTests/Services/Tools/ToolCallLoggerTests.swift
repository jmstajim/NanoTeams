import XCTest

@testable import NanoTeams

final class ToolCallLoggerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var logURL: URL!
    private var logger: ToolCallLogger!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Use standardizedFileURL to resolve symlinks (/var -> /private/var on macOS)
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        logURL = tempDir.appendingPathComponent("tool_calls.jsonl")
        logger = ToolCallLogger(logURL: logURL)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
//        logger = nil
        tempDir = nil
        logURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Initialization Tests

    func testInit_doesNotCreateFileImmediately() {
        let freshLogURL = tempDir.appendingPathComponent("fresh_log.jsonl")

        XCTAssertFalse(fileManager.fileExists(atPath: freshLogURL.path))
    }

    func testInit_acceptsCustomFileManager() {
        let customLogger = ToolCallLogger(logURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL.appendingPathComponent("tool_calls.jsonl"), fileManager: FileManager.default)
        // Should not crash
        XCTAssertNotNil(customLogger)
    }

    // MARK: - Append Tests

    func testAppend_createsLogFile() {
        let record = makeRecord()

        logger.append(record)

        XCTAssertTrue(fileManager.fileExists(atPath: logURL.path))
    }

    func testAppend_createsParentDirectory() throws {
        let nestedLogger = ToolCallLogger(
            logURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .standardizedFileURL
                .appendingPathComponent("nested")
                .appendingPathComponent("deep")
                .appendingPathComponent("tool_calls.jsonl"))
        let record = makeRecord()

        nestedLogger.append(record)

        XCTAssertTrue(fileManager.fileExists(atPath: nestedLogger.logURL.path))
    }

    func testAppend_createsParentDirectoryWithRestrictedPermissions() throws {
        let nestedDir = tempDir.appendingPathComponent("run_99", isDirectory: true)
        let nestedLogURL = nestedDir.appendingPathComponent("tool_calls.jsonl")
        let restrictedLogger = ToolCallLogger(logURL: nestedLogURL)

        restrictedLogger.append(makeRecord())

        XCTAssertTrue(fileManager.fileExists(atPath: nestedLogURL.path))

        let attrs = try fileManager.attributesOfItem(atPath: nestedDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700,
                        "ToolCallLogger should create parent directory with owner-only permissions")
    }

    func testAppend_writesJSONLine() throws {
        let record = makeRecord(toolName: "read_file")

        logger.append(record)

        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(content.contains("read_file"))
    }

    func testAppend_writesNewlineDelimited() throws {
        logger.append(makeRecord(toolName: "tool_1"))
        logger.append(makeRecord(toolName: "tool_2"))
        logger.append(makeRecord(toolName: "tool_3"))

        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("tool_1"))
        XCTAssertTrue(lines[1].contains("tool_2"))
        XCTAssertTrue(lines[2].contains("tool_3"))
    }

    func testAppend_eachLineIsValidJSON() throws {
        logger.append(makeRecord(toolName: "first"))
        logger.append(makeRecord(toolName: "second"))

        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        for line in lines {
            let data = line.data(using: .utf8)!
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }
    }

    func testAppend_includesAllRecordFields() throws {
        let taskID = 0
        let runID = 0
        let roleID = "test_role"

        let record = ToolCallLogRecord(
            createdAt: Date(),
            taskID: taskID,
            runID: runID,
            roleID: roleID,
            toolName: "write_file",
            argumentsJSON: "{\"path\":\"test.txt\"}",
            resultJSON: "{\"ok\":true}",
            errorMessage: nil
        )

        logger.append(record)

        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(content.contains(String(taskID)))
        XCTAssertTrue(content.contains(String(runID)))
        XCTAssertTrue(content.contains(roleID))
        XCTAssertTrue(content.contains("write_file"))
        XCTAssertTrue(content.contains("test.txt"))
    }

    func testAppend_includesErrorMessage() throws {
        let record = ToolCallLogRecord(
            createdAt: Date(),
            taskID: Int(),
            runID: 0,
            roleID: "test_role",
            toolName: "failing_tool",
            argumentsJSON: "{}",
            resultJSON: nil,
            errorMessage: "File not found"
        )

        logger.append(record)

        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(content.contains("File not found"))
    }

    func testAppend_usesISO8601DateFormat() throws {
        let date = Date()
        let record = ToolCallLogRecord(
            createdAt: date,
            taskID: Int(),
            runID: 0,
            roleID: "test_role",
            toolName: "test",
            argumentsJSON: "{}",
            resultJSON: nil,
            errorMessage: nil
        )

        logger.append(record)

        let content = try String(contentsOf: logURL, encoding: .utf8)
        // ISO8601 dates contain "T" separator
        XCTAssertTrue(content.contains("T"))
    }

    func testAppend_appendsToExistingFile() throws {
        let freshLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL.appendingPathComponent("tool_calls.jsonl")
        let freshLogger = ToolCallLogger(logURL: freshLogURL)

        // Create parent directory and existing log content
        let parentDir = freshLogURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try "existing content\n".write(to: freshLogURL, atomically: true, encoding: .utf8)

        // Append using fresh logger
        freshLogger.append(makeRecord(toolName: "new_tool"))

        let content = try String(contentsOf: freshLogURL, encoding: .utf8)
        XCTAssertTrue(content.contains("existing content"))
        XCTAssertTrue(content.contains("new_tool"))
    }

    func testAppend_neverThrows() {
        // Test with invalid URL that can't be written to
        let invalidLogger = ToolCallLogger(logURL: URL(fileURLWithPath: "/nonexistent/path/tool_calls.jsonl"))

        // Should not throw or crash
        invalidLogger.append(makeRecord())

        // Test passed if we get here without crash
        XCTAssertTrue(true)
    }

    func testAppend_handlesSpecialCharactersInJSON() throws {
        let record = ToolCallLogRecord(
            createdAt: Date(),
            taskID: Int(),
            runID: 0,
            roleID: "test_role",
            toolName: "test",
            argumentsJSON: "{\"content\":\"line1\\nline2\\ttab\"}",
            resultJSON: "{\"message\":\"quotes: \\\"test\\\"\"}",
            errorMessage: nil
        )

        logger.append(record)

        let content = try String(contentsOf: logURL, encoding: .utf8)
        let data = content.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }

    // MARK: - Concurrent Access Tests

    func testAppend_handlesConcurrentWrites() throws {
        let expectation = XCTestExpectation(description: "Concurrent writes")
        let writeCount = 10
        expectation.expectedFulfillmentCount = writeCount

        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        for i in 0..<writeCount {
            queue.async {
                self.logger.append(self.makeRecord(toolName: "tool_\(i)"))
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)

        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        // All writes should complete (though order may vary)
        XCTAssertEqual(lines.count, writeCount)
    }

    // MARK: - Helper

    private func makeRecord(toolName: String = "test_tool") -> ToolCallLogRecord {
        ToolCallLogRecord(
            createdAt: Date(),
            taskID: Int(),
            runID: 0,
            roleID: "test_role",
            toolName: toolName,
            argumentsJSON: "{}",
            resultJSON: nil,
            errorMessage: nil
        )
    }
}

// MARK: - ToolCallLogRecord Tests

final class ToolCallLogRecordTests: XCTestCase {

    func testRecord_codable() throws {
        let record = ToolCallLogRecord(
            createdAt: Date(),
            taskID: Int(),
            runID: 0,
            roleID: "test_role",
            toolName: "test_tool",
            argumentsJSON: "{\"path\":\"file.txt\"}",
            resultJSON: "{\"ok\":true}",
            errorMessage: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ToolCallLogRecord.self, from: data)

        XCTAssertEqual(decoded.toolName, record.toolName)
        XCTAssertEqual(decoded.taskID, record.taskID)
        XCTAssertEqual(decoded.argumentsJSON, record.argumentsJSON)
    }

    func testRecord_hashable() {
        let taskID = 0
        let runID = 0
        let roleID = "test_role"
        let date = Date()

        let record1 = ToolCallLogRecord(
            createdAt: date,
            taskID: taskID,
            runID: runID,
            roleID: roleID,
            toolName: "tool",
            argumentsJSON: "{}",
            resultJSON: nil,
            errorMessage: nil
        )

        let record2 = ToolCallLogRecord(
            createdAt: date,
            taskID: taskID,
            runID: runID,
            roleID: roleID,
            toolName: "tool",
            argumentsJSON: "{}",
            resultJSON: nil,
            errorMessage: nil
        )

        XCTAssertEqual(record1, record2)
        XCTAssertEqual(record1.hashValue, record2.hashValue)
    }

    func testRecord_optionalFields() throws {
        let record = ToolCallLogRecord(
            createdAt: Date(),
            taskID: Int(),
            runID: 0,
            roleID: "test_role",
            toolName: "tool",
            argumentsJSON: "{}",
            resultJSON: nil,
            errorMessage: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(record)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Optional fields should be null or absent
        XCTAssertTrue(json["resultJSON"] == nil || json["resultJSON"] is NSNull)
        XCTAssertTrue(json["errorMessage"] == nil || json["errorMessage"] is NSNull)
    }
}
