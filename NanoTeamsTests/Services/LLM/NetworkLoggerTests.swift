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

    // MARK: - Tool-call audit records (.toolCall)

    func testCreateToolCallRecord_setsDirectionAndFields() throws {
        let record = NetworkLogger.createToolCallRecord(
            toolName: "read_file",
            argumentsJSON: #"{"path":"a.swift"}"#,
            resultJSON: #"{"ok":true}"#,
            errorMessage: nil,
            stepID: "eng_step"
        )

        XCTAssertEqual(record.direction, .toolCall)
        XCTAssertEqual(record.stepID, "eng_step")
        XCTAssertNil(record.errorMessage)
        XCTAssertNil(record.statusCode)
        // Body is itself valid JSON carrying the tool name + result.
        let body = try XCTUnwrap(record.body)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(obj["event"] as? String, "tool_call")
        XCTAssertEqual(obj["tool"] as? String, "read_file")
        XCTAssertEqual(obj["arguments"] as? String, #"{"path":"a.swift"}"#)
        XCTAssertEqual(obj["result"] as? String, #"{"ok":true}"#)
    }

    func testCreateToolCallRecord_carriesRoleName() {
        let record = NetworkLogger.createToolCallRecord(
            toolName: "read_file", argumentsJSON: "{}", resultJSON: nil,
            errorMessage: nil, stepID: "eng", roleName: "Software Engineer")
        XCTAssertEqual(record.roleName, "Software Engineer")
        XCTAssertEqual(record.direction, .toolCall)
    }

    func testCreateToolCallRecord_carriesErrorMessage() {
        let record = NetworkLogger.createToolCallRecord(
            toolName: "malformed_tool_call",
            argumentsJSON: "{ broken",
            resultJSON: #"{"ok":false,"error":{"code":"MALFORMED_TOOL_CALL"}}"#,
            errorMessage: "Tool-call JSON could not be parsed; not dispatched.",
            stepID: "tpm_step"
        )
        XCTAssertEqual(record.errorMessage, "Tool-call JSON could not be parsed; not dispatched.")
        XCTAssertTrue(record.body?.contains("MALFORMED_TOOL_CALL") == true)
    }

    /// A malformed `argumentsJSON` payload must NOT corrupt the surrounding
    /// `[NetworkLogRecord]` array — it's embedded as an escaped string value.
    func testToolCallRecord_malformedArguments_arrayStaysDecodable() throws {
        let record = NetworkLogger.createToolCallRecord(
            toolName: "malformed_tool_call",
            argumentsJSON: #"{"name":"write_file","arguments":{"content":"<div class="x">"#,
            resultJSON: nil,
            errorMessage: "bad",
            stepID: "s"
        )
        logger.append(record)

        let data = try Data(contentsOf: logURL)
        let decoder = JSONCoderFactory.makeDateDecoder()
        let decoded = try decoder.decode([NetworkLogRecord].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].direction, .toolCall)
        XCTAssertEqual(decoded[0].errorMessage, "bad")
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

    // MARK: - Server prefill mapping

    /// The two fields the prompt-prefix cache audit reads back out of a real run. The `ns → ms`
    /// division was untested, and a zero written where the server reported nothing would poison
    /// any attempt to re-derive `minimumLoadMsForReload` from the log.

    private func responseRecord(_ prefill: ServerPrefillReport?) -> NetworkLogRecord {
        let request = NetworkLogRecord(
            id: UUID(), createdAt: Date(), direction: .request,
            httpMethod: "POST", url: "http://localhost/api", statusCode: nil, body: nil,
            durationMs: nil, errorMessage: nil, correlationID: UUID(), stepID: nil)
        return NetworkLogger.createResponseRecord(
            for: request, statusCode: 200, durationMs: 1000, error: nil,
            serverPrefill: prefill)
    }

    func testResponseRecord_mapsPrefillNanosecondsToMilliseconds() {
        // Ollama's real cold row: load_duration 2236645542 ns, prompt_eval_duration 6481316750 ns.
        let record = responseRecord(
            ServerPrefillReport(
                modelLoadMs: 2236.645542, prefillNs: 6_481_316_750, promptTokens: 12927))

        XCTAssertEqual(record.prefillMs ?? 0, 6481.31675, accuracy: 0.0001)
        XCTAssertEqual(
            record.modelLoadMs ?? 0, 2236.645542, accuracy: 0.000001,
            "the load figure is recorded verbatim — no threshold at the log layer")
    }

    func testResponseRecord_absentPrefill_writesNilNotZero() {
        let record = responseRecord(nil)
        XCTAssertNil(record.prefillMs)
        XCTAssertNil(record.modelLoadMs)
    }

    /// LM Studio's shape: a load figure, never a rate. A zero here would be indistinguishable
    /// from "the server said it prefilled instantly".
    func testResponseRecord_loadWithoutARate_leavesPrefillMsNil() {
        let record = responseRecord(
            ServerPrefillReport(modelLoadMs: 0, prefillNs: nil, promptTokens: 900))
        XCTAssertNil(record.prefillMs)
        XCTAssertEqual(record.modelLoadMs, 0)
    }
}
