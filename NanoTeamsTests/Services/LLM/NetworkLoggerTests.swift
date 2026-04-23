@testable import NanoTeams
import XCTest

final class NetworkLoggerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var logURL: URL!
    private var logger: NetworkLogger!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Use standardizedFileURL to resolve symlinks (/var -> /private/var on macOS)
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        logURL = tempDir.appendingPathComponent("network_log.json")
        logger = NetworkLogger(logURL: logURL)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        tempDir = nil
        logURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Directory Permissions

    func testAppend_createsParentDirectoryWithRestrictedPermissions() throws {
        // Logger with a non-existent nested parent directory
        let nestedDir = tempDir.appendingPathComponent("run_42", isDirectory: true)
        let nestedLogURL = nestedDir.appendingPathComponent("network_log.json")
        let nestedLogger = NetworkLogger(logURL: nestedLogURL)

        let record = NetworkLogRecord(
            id: UUID(), createdAt: Date(), direction: .request,
            httpMethod: "POST", url: "http://localhost/test",
            statusCode: nil, body: nil, durationMs: nil,
            errorMessage: nil, correlationID: UUID(), stepID: nil
        )
        nestedLogger.append(record)

        XCTAssertTrue(fileManager.fileExists(atPath: nestedLogURL.path))

        let attrs = try fileManager.attributesOfItem(atPath: nestedDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700,
                        "NetworkLogger should create parent directory with owner-only permissions")
    }

    // MARK: - File Creation Tests

    func testAppendCreatesFile() {
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "http://localhost:1234/v1/chat/completions",
            statusCode: nil,
            body: "{\"test\": true}",
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        logger.append(record)

        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
    }

    // MARK: - JSON Format Tests

    func testOutputIsValidJSONArray() throws {
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "http://localhost/test",
            statusCode: nil,
            body: "test body",
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        logger.append(record)

        let data = try Data(contentsOf: logURL)
        let decoder = JSONCoderFactory.makeDateDecoder()
        let decoded = try decoder.decode([NetworkLogRecord].self, from: data)
        XCTAssertEqual(decoded.count, 1)
    }

    func testMultipleAppendsCreateArray() throws {
        let correlationID = UUID()

        let request = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "http://localhost/test",
            statusCode: nil,
            body: "request body",
            durationMs: nil,
            errorMessage: nil,
            correlationID: correlationID,
            stepID: nil
        )

        let response = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .response,
            httpMethod: "POST",
            url: "http://localhost/test",
            statusCode: 200,
            body: nil,
            durationMs: 150.5,
            errorMessage: nil,
            correlationID: correlationID,
            stepID: nil
        )

        logger.append(request)
        logger.append(response)

        let data = try Data(contentsOf: logURL)
        let decoder = JSONCoderFactory.makeDateDecoder()
        let decoded = try decoder.decode([NetworkLogRecord].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].direction, .request)
        XCTAssertEqual(decoded[1].direction, .response)
    }

    // MARK: - Request/Response Pairing Tests

    func testRequestResponseCorrelation() {
        let request = NetworkLogger.createRequestRecord(
            url: URL(string: "http://localhost:1234/v1/chat/completions")!,
            method: "POST",
            body: "{}".data(using: .utf8),
            stepID: "test_step"
        )

        let response = NetworkLogger.createResponseRecord(
            for: request,
            statusCode: 200,
            durationMs: 150.5,
            error: nil
        )

        XCTAssertEqual(request.correlationID, response.correlationID)
        XCTAssertEqual(request.direction, .request)
        XCTAssertEqual(response.direction, .response)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.durationMs, 150.5)
    }

    func testRequestRecordContainsFullBody() {
        let bodyContent = String(repeating: "x", count: 10000)
        let bodyData = bodyContent.data(using: .utf8)!

        let record = NetworkLogger.createRequestRecord(
            url: URL(string: "http://test.com")!,
            method: "POST",
            body: bodyData,
            stepID: nil
        )

        XCTAssertEqual(record.body?.count, 10000)
        XCTAssertEqual(record.body, bodyContent)
    }

    func testRequestWithNilBody() {
        let record = NetworkLogger.createRequestRecord(
            url: URL(string: "http://test.com")!,
            method: "GET",
            body: nil,
            stepID: nil
        )

        XCTAssertNil(record.body)
    }

    // MARK: - Error Handling Tests

    func testResponseRecordCapturesError() {
        let request = NetworkLogger.createRequestRecord(
            url: URL(string: "http://test.com")!,
            method: "POST",
            body: nil,
            stepID: nil
        )

        let error = NSError(domain: "TestDomain", code: 500, userInfo: [
            NSLocalizedDescriptionKey: "Internal Server Error"
        ])

        let response = NetworkLogger.createResponseRecord(
            for: request,
            statusCode: 500,
            durationMs: 100.0,
            error: error
        )

        XCTAssertEqual(response.statusCode, 500)
        XCTAssertEqual(response.errorMessage, "Internal Server Error")
    }

    // MARK: - Thread Safety Tests

    func testConcurrentAppends() throws {
        let expectation = XCTestExpectation(description: "Concurrent appends complete")
        expectation.expectedFulfillmentCount = 10

        for i in 0..<10 {
            DispatchQueue.global().async {
                let record = NetworkLogRecord(
                    id: UUID(),
                    createdAt: Date(),
                    direction: i % 2 == 0 ? .request : .response,
                    httpMethod: "POST",
                    url: "http://localhost/test/\(i)",
                    statusCode: i % 2 == 0 ? nil : 200,
                    body: "body \(i)",
                    durationMs: i % 2 == 0 ? nil : Double(i) * 10,
                    errorMessage: nil,
                    correlationID: UUID(),
                    stepID: nil
                )
                self.logger.append(record)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)

        let data = try Data(contentsOf: logURL)
        let decoder = JSONCoderFactory.makeDateDecoder()
        let decoded = try decoder.decode([NetworkLogRecord].self, from: data)
        XCTAssertEqual(decoded.count, 10)
    }

    // MARK: - StepID Context Tests

    func testRecordContainsStepID() {
        let stepID = "test_step"
        let record = NetworkLogger.createRequestRecord(
            url: URL(string: "http://test.com")!,
            method: "POST",
            body: nil,
            stepID: stepID
        )

        XCTAssertEqual(record.stepID, stepID)
    }

    func testResponseInheritsStepID() {
        let stepID = "test_step"
        let request = NetworkLogger.createRequestRecord(
            url: URL(string: "http://test.com")!,
            method: "POST",
            body: nil,
            stepID: stepID
        )

        let response = NetworkLogger.createResponseRecord(
            for: request,
            statusCode: 200,
            durationMs: 100.0,
            error: nil
        )

        XCTAssertEqual(response.stepID, stepID)
    }

    // MARK: - Markdown Generation Tests

    func testAppendCreatesConversationLogMarkdown() throws {
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "http://localhost/test",
            statusCode: nil,
            body: nil,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        logger.append(record)

        XCTAssertTrue(fileManager.fileExists(atPath: logger.conversationLogURL.path))
    }

    func testConversationLogStartsWithHeader() throws {
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "http://localhost/test",
            statusCode: nil,
            body: nil,
            durationMs: nil,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        logger.append(record)

        let markdown = try String(contentsOf: logger.conversationLogURL, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("# Conversation Log"))
    }

    func testConversationLogPreservesRecordOrder() throws {
        let correlationID = UUID()

        let request = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .request,
            httpMethod: "POST",
            url: "http://localhost/test",
            statusCode: nil,
            body: nil,
            durationMs: nil,
            errorMessage: nil,
            correlationID: correlationID,
            stepID: nil
        )

        let response = NetworkLogRecord(
            id: UUID(),
            createdAt: Date().addingTimeInterval(1),
            direction: .response,
            httpMethod: "POST",
            url: "http://localhost/test",
            statusCode: 200,
            body: "response body",
            durationMs: 150.5,
            errorMessage: nil,
            correlationID: correlationID,
            stepID: nil
        )

        logger.append(request)
        logger.append(response)

        let markdown = try String(contentsOf: logger.conversationLogURL, encoding: .utf8)

        // Check that request comes before response in markdown
        let requestPos = markdown.range(of: "<summary>1. → Request")?.lowerBound
        let responsePos = markdown.range(of: "<summary>2. ← Response")?.lowerBound

        XCTAssertNotNil(requestPos)
        XCTAssertNotNil(responsePos)
        XCTAssertTrue(requestPos! < responsePos!)
    }

    func testConversationLogContainsMetadata() throws {
        let stepID = "test_step"
        let correlationID = UUID()

        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .response,
            httpMethod: "POST",
            url: "http://localhost/test",
            statusCode: 200,
            body: nil,
            durationMs: 150.5,
            errorMessage: nil,
            correlationID: correlationID,
            stepID: stepID
        )

        logger.append(record)

        let markdown = try String(contentsOf: logger.conversationLogURL, encoding: .utf8)

        XCTAssertTrue(markdown.contains("Status: 200"))
        XCTAssertTrue(markdown.contains("Duration: 150.5ms"))
        XCTAssertTrue(markdown.contains("Step: \(stepID.prefix(8))"))
        XCTAssertTrue(markdown.contains("Correlation: \(correlationID.uuidString.prefix(8))"))
    }

    func testConversationLogRendersStructuredResponse() throws {
        let record = NetworkLogRecord(
            id: UUID(),
            createdAt: Date(),
            direction: .response,
            httpMethod: "POST",
            url: "http://localhost/test",
            statusCode: 200,
            body: "[reasoning]thinking...[/reasoning]\n\ncontent here\n\n[tool_calls][{\"name\":\"test\"}][/tool_calls]",
            durationMs: 100.0,
            errorMessage: nil,
            correlationID: UUID(),
            stepID: nil
        )

        logger.append(record)

        let markdown = try String(contentsOf: logger.conversationLogURL, encoding: .utf8)

        XCTAssertTrue(markdown.contains("**Thinking:**"))
        XCTAssertTrue(markdown.contains("thinking..."))
        XCTAssertTrue(markdown.contains("**Tool Calls:**"))
        XCTAssertTrue(markdown.contains("[{\"name\":\"test\"}]"))
    }
}
