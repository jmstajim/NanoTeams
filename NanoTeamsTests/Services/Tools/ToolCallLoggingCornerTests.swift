import XCTest

@testable import NanoTeams

/// Corner cases for "every tool call lands in BOTH per-run logs" — the
/// `ToolRuntime.logNonExecutedCall` sink, `NetworkLogger.createToolCallRecord`
/// encoding, executed-call branches, and consumer compatibility of the new
/// `.toolCall` direction. All deterministic / offline (no LM Studio).
final class ToolCallLoggingCornerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var jsonlURL: URL!
    private var netURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        MonotonicClock.shared.reset()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        jsonlURL = tempDir.appendingPathComponent("tool_calls.jsonl")
        netURL = tempDir.appendingPathComponent("network_log.json")
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fileManager.removeItem(at: tempDir) }
        tempDir = nil
        jsonlURL = nil
        netURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeRuntime(
        registry: ToolRegistry = ToolRegistry(),
        jsonl: Bool,
        net: Bool
    ) -> ToolRuntime {
        ToolRuntime(
            registry: registry,
            logger: jsonl ? ToolCallLogger(logURL: jsonlURL) : nil,
            networkLogger: net ? NetworkLogger(logURL: netURL) : nil
        )
    }

    private func context() -> ToolExecutionContext {
        ToolExecutionContext(workFolderRoot: tempDir, taskID: 7, runID: 3, roleID: "eng")
    }

    private func networkToolCallRecords() throws -> [NetworkLogRecord] {
        guard fileManager.fileExists(atPath: netURL.path) else { return [] }
        let all = try JSONCoderFactory.makeDateDecoder()
            .decode([NetworkLogRecord].self, from: Data(contentsOf: netURL))
        return all.filter { $0.direction == .toolCall }
    }

    private func networkRecords() throws -> [NetworkLogRecord] {
        guard fileManager.fileExists(atPath: netURL.path) else { return [] }
        return try JSONCoderFactory.makeDateDecoder()
            .decode([NetworkLogRecord].self, from: Data(contentsOf: netURL))
    }

    private func jsonlLines() -> [String] {
        guard let text = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - logNonExecutedCall: sink combinations

    func testLogNonExecutedCall_writesBothSinks() throws {
        let rt = makeRuntime(jsonl: true, net: true)
        rt.logNonExecutedCall(
            taskID: 7, runID: 3, roleID: "eng",
            toolName: "ghost_tool", argumentsJSON: #"{"a":1}"#,
            resultJSON: #"{"ok":false}"#, errorMessage: "nope")

        let lines = jsonlLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("ghost_tool"))
        XCTAssertTrue(lines[0].contains("nope"))

        let recs = try networkToolCallRecords()
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].stepID, "eng")
        XCTAssertEqual(recs[0].errorMessage, "nope")
    }

    func testLogNonExecutedCall_jsonlLoggerOnly() throws {
        let rt = makeRuntime(jsonl: true, net: false)
        rt.logNonExecutedCall(
            taskID: 0, runID: 0, roleID: "r",
            toolName: "t", argumentsJSON: "{}", resultJSON: nil, errorMessage: nil)

        XCTAssertEqual(jsonlLines().count, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: netURL.path),
                       "No network logger → no network_log.json")
    }

    func testLogNonExecutedCall_networkLoggerOnly() throws {
        let rt = makeRuntime(jsonl: false, net: true)
        rt.logNonExecutedCall(
            taskID: 0, runID: 0, roleID: "r",
            toolName: "t", argumentsJSON: "{}", resultJSON: nil, errorMessage: nil)

        XCTAssertEqual(try networkToolCallRecords().count, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: jsonlURL.path),
                       "No jsonl logger → no tool_calls.jsonl")
    }

    func testLogNonExecutedCall_bothNil_noFilesNoCrash() {
        let rt = makeRuntime(jsonl: false, net: false)
        rt.logNonExecutedCall(
            taskID: 0, runID: 0, roleID: "r",
            toolName: "t", argumentsJSON: "{}", resultJSON: nil, errorMessage: nil)

        XCTAssertFalse(fileManager.fileExists(atPath: jsonlURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: netURL.path))
    }

    // MARK: - logNonExecutedCall: degenerate payloads

    func testLogNonExecutedCall_nilResult_networkBodyHasEmptyResult() throws {
        let rt = makeRuntime(jsonl: true, net: true)
        rt.logNonExecutedCall(
            taskID: 0, runID: 0, roleID: "r",
            toolName: "t", argumentsJSON: #"{"x":1}"#, resultJSON: nil, errorMessage: nil)

        let recs = try networkToolCallRecords()
        XCTAssertEqual(recs.count, 1)
        let body = try XCTUnwrap(recs[0].body)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(obj["result"] as? String, "", "nil resultJSON serializes as empty string")
        XCTAssertNil(recs[0].errorMessage)
    }

    func testLogNonExecutedCall_emptyToolNameAndArgs_stillRecorded() throws {
        let rt = makeRuntime(jsonl: true, net: true)
        rt.logNonExecutedCall(
            taskID: 0, runID: 0, roleID: "",
            toolName: "", argumentsJSON: "", resultJSON: "", errorMessage: "")

        XCTAssertEqual(jsonlLines().count, 1)
        XCTAssertEqual(try networkToolCallRecords().count, 1)
    }

    /// Unescaped quotes / newlines / tabs in the (possibly malformed) payload must
    /// keep BOTH the jsonl line valid JSON AND the network array decodable.
    func testLogNonExecutedCall_specialChars_bothRemainDecodable() throws {
        let nasty = "broken \" quote\nwith newline\tand tab and <div class=\"x\">"
        let rt = makeRuntime(jsonl: true, net: true)
        rt.logNonExecutedCall(
            taskID: 0, runID: 0, roleID: "r",
            toolName: "malformed_tool_call", argumentsJSON: nasty,
            resultJSON: #"{"ok":false}"#, errorMessage: "bad json")

        // jsonl: the single line must itself be valid JSON.
        let lines = jsonlLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)))

        // network: array decodes, body decodes, and the nasty payload round-trips.
        let recs = try networkToolCallRecords()
        XCTAssertEqual(recs.count, 1)
        let body = try XCTUnwrap(recs[0].body)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(obj["arguments"] as? String, nasty)
    }

    func testLogNonExecutedCall_multipleCalls_appendInOrder() throws {
        let rt = makeRuntime(jsonl: true, net: true)
        for i in 0..<3 {
            rt.logNonExecutedCall(
                taskID: 0, runID: 0, roleID: "r",
                toolName: "tool_\(i)", argumentsJSON: "{}", resultJSON: nil, errorMessage: nil)
        }
        let lines = jsonlLines()
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("tool_0"))
        XCTAssertTrue(lines[2].contains("tool_2"))
        XCTAssertEqual(try networkToolCallRecords().count, 3)
    }

    // MARK: - createToolCallRecord encoding corners

    func testCreateToolCallRecord_emptyInputs_bodyIsValidJSON() throws {
        let record = NetworkLogger.createToolCallRecord(
            toolName: "", argumentsJSON: "", resultJSON: nil, errorMessage: nil, stepID: nil)
        let body = try XCTUnwrap(record.body)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(obj["event"] as? String, "tool_call")
        XCTAssertEqual(obj["tool"] as? String, "")
        XCTAssertNil(record.stepID)
    }

    // MARK: - Consumer compatibility (FirstPromptFromLogsExtractor-style)

    /// Interleaving `.toolCall` records among `.request`/`.response` must not break
    /// decoding OR the "first request" selection consumers rely on.
    func testToolCallRecords_interleaved_doNotBreakRequestFiltering() throws {
        let logger = NetworkLogger(logURL: netURL)
        let req = NetworkLogger.createRequestRecord(
            url: URL(string: "http://localhost/api/v1/chat")!, method: "POST",
            body: Data("{\"system\":\"x\"}".utf8), stepID: "eng")
        logger.append(req)
        logger.append(NetworkLogger.createToolCallRecord(
            toolName: "read_file", argumentsJSON: "{}", resultJSON: #"{"ok":true}"#,
            errorMessage: nil, stepID: "eng"))
        logger.append(NetworkLogger.createResponseRecord(
            for: req, statusCode: 200, durationMs: 5, body: "done", error: nil))

        let all = try networkRecords()
        XCTAssertEqual(all.count, 3, "All three directions decode together")
        XCTAssertEqual(all.filter { $0.direction == .request }.count, 1)
        XCTAssertEqual(all.filter { $0.direction == .toolCall }.count, 1)
        XCTAssertEqual(all.filter { $0.direction == .response }.count, 1)
        // The 'first request' a consumer extracts is still the real request.
        let firstRequest = try XCTUnwrap(all.first { $0.direction == .request })
        XCTAssertEqual(firstRequest.body, "{\"system\":\"x\"}")
    }

    // MARK: - Executed-call branches (executeOne) parity across both sinks

    func testExecutedCall_handlerReturnedError_loggedToBothWithEnvelope() throws {
        let registry = ToolRegistry()
        registry.register(name: "boom_returns") { _, _ in
            ToolExecutionResult(
                providerID: "p", toolName: "boom_returns", argumentsJSON: "{}",
                outputJSON: #"{"error":"handler_said_no"}"#, isError: true)
        }
        let rt = makeRuntime(registry: registry, jsonl: true, net: true)

        let result = rt.executeAll(
            context: context(),
            toolCalls: [StepToolCall(name: "boom_returns", argumentsJSON: "{}")]).first!
        XCTAssertTrue(result.isError)

        let lines = jsonlLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("handler_said_no"))

        let recs = try networkToolCallRecords()
        XCTAssertEqual(recs.count, 1)
        XCTAssertTrue(recs[0].body?.contains("handler_said_no") == true)
        // Handler-RETURNED error → errorMessage stays nil (the envelope carries it).
        XCTAssertNil(recs[0].errorMessage)
    }

    /// Pins the documented invariant: cancellation envelopes (built in `executeAll`,
    /// never through `executeOne`) are NOT logged to either sink. The first call
    /// executes (and cancels the surrounding task); the remaining calls become
    /// cancellation envelopes that must leave no log record.
    func testCancelledBatch_cancellationEnvelopesNotLogged() async throws {
        let registry = ToolRegistry()
        registry.register(name: "cancel_self") { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return ToolExecutionResult(
                providerID: "p", toolName: "cancel_self", argumentsJSON: "{}",
                outputJSON: "{}", isError: false)
        }
        let rt = makeRuntime(registry: registry, jsonl: true, net: true)
        let ctx = context()
        let calls = (0..<3).map { _ in StepToolCall(name: "cancel_self", argumentsJSON: "{}") }

        let results = await Task.detached { rt.executeAll(context: ctx, toolCalls: calls) }.value
        XCTAssertEqual(results.count, 3, "1 executed + 2 cancellation envelopes")

        // Only the executed first call is logged; the 2 cancellation envelopes are not.
        XCTAssertEqual(jsonlLines().count, 1)
        XCTAssertEqual(try networkToolCallRecords().count, 1)
        let joined = jsonlLines().joined()
            + (try networkToolCallRecords().compactMap(\.body).joined())
        XCTAssertFalse(joined.contains("cancelled by user"),
                       "Cancellation envelope content must never reach either log")
    }

    func testExecutedCall_handlerThrew_loggedToBothWithErrorMessage() throws {
        let registry = ToolRegistry()
        registry.register(name: "boom_throws") { _, _ in
            throw ToolRuntimeError.argumentsNotObject
        }
        let rt = makeRuntime(registry: registry, jsonl: true, net: true)

        let result = rt.executeAll(
            context: context(),
            toolCalls: [StepToolCall(name: "boom_throws", argumentsJSON: "{}")]).first!
        XCTAssertTrue(result.isError)

        let lines = jsonlLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("execution_failed"))

        let recs = try networkToolCallRecords()
        XCTAssertEqual(recs.count, 1)
        // Thrown error (catch branch) → errorMessage IS populated.
        XCTAssertNotNil(recs[0].errorMessage)
    }
}
