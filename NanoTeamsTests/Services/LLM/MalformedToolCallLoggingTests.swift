import XCTest

@testable import NanoTeams

/// A `malformed_tool_call` is a local artifact (synthesized in
/// `recordFailedToolCallAttemptIfNeeded`, never sent over the wire). These tests
/// pin that it ALSO lands in BOTH per-run audit logs — `network_log.json` (as a
/// `.toolCall` record) and `tool_calls.jsonl` — so both match the feed card.
/// Parity guard: the same cases that suppress the feed card (channel-only /
/// no-envelope) suppress both logs.
@MainActor
final class MalformedToolCallLoggingTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!
    private var runtime: ToolRuntime!
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var netURL: URL!
    private var jsonlURL: URL!

    /// Verbatim `.malformedJSON`-with-`<|call|>` payload (run 3AF0CBF5): the closing
    /// `\"` in `onclick=\"…\">` is unescaped, so the JSON can't be parsed or repaired.
    private static let malformedPayload = """
    [reasoning]
    Building the calculator.
    [/reasoning]

    <|call|>{"name":"create_artifact","arguments":{"content":"<button onclick=\\"appendOperator('-')">-</button>","name":"index.html"}}<|end|>
    """

    /// Parseable JSON missing the top-level `name` (shape-inferred as create_artifact).
    private static let missingNamePayload =
        "[reasoning]\nCreating PRD.\n[/reasoning]\n\n<|call|>{\"arguments\":{\"content\":\"PRD\",\"format\":\"markdown\",\"name\":\"Product Requirements\"}}<|end|>"

    /// Markers seen but NO `<|call|>` block → `.malformedJSON` without a call attempt
    /// → no card, no log.
    private static let channelOnlyPayload =
        "<|channel|>commentary<|message|>just thinking out loud, no tool call here"

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)

        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "Build", status: .running)
        stepID = step.id
        let run = Run(id: 0, steps: [step])
        task = NTMSTask(id: 0, title: "Test", supervisorTask: "goal", runs: [run])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        netURL = tempDir.appendingPathComponent("network_log.json")
        jsonlURL = tempDir.appendingPathComponent("tool_calls.jsonl")

        // Runtime owning BOTH per-run logger instances (the shared-instance contract).
        let (_, rt) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: jsonlURL,
            networkLogger: NetworkLogger(logURL: netURL)
        )
        runtime = rt
    }

    override func tearDown() async throws {
        if let tempDir { try? fileManager.removeItem(at: tempDir) }
        tempDir = nil
        netURL = nil
        jsonlURL = nil
        runtime = nil
        mockDelegate = nil
        service = nil
        task = nil
        stepID = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func networkToolCallRecords() -> [NetworkLogRecord] {
        guard fileManager.fileExists(atPath: netURL.path),
              let data = try? Data(contentsOf: netURL),
              let all = try? JSONCoderFactory.makeDateDecoder().decode([NetworkLogRecord].self, from: data)
        else { return [] }
        return all.filter { $0.direction == .toolCall }
    }

    private func jsonlLines() -> [String] {
        guard let text = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Both appends fire from a `Task.detached`, so poll briefly.
    ///
    /// Fails on timeout instead of returning `[]`. Every call site immediately subscripts
    /// `[0]`, so a silent empty return is not a failed assertion — it is `Index out of range`,
    /// which aborts the whole XCTest worker and gets attributed to whatever unrelated test was
    /// in flight (CLAUDE.md Грабли 2026-07-07). A timing helper that can turn a slow producer
    /// into someone else's crash report is the worst shape available.
    private func waitForNetworkRecords(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [NetworkLogRecord] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let recs = networkToolCallRecords()
            if !recs.isEmpty { return recs }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let final = networkToolCallRecords()
        if final.isEmpty {
            XCTFail("no network records after \(timeout)s — the detached append never landed",
                    file: file, line: line)
        }
        return final
    }

    // MARK: - Tests

    func testMalformed_logsToBothLogs() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: Self.malformedPayload,
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            runtime: runtime
        )

        let netRecords = await waitForNetworkRecords()
        // `guard` rather than a bare count assertion: XCTFail does not stop the test, so an
        // empty result would fall through to `[0]` and abort the worker process.
        guard netRecords.count == 1 else {
            return XCTFail("expected exactly 1 network record, got \(netRecords.count)")
        }
        XCTAssertTrue(netRecords[0].body?.contains("malformed_tool_call") == true)
        XCTAssertTrue(netRecords[0].body?.contains("MALFORMED_TOOL_CALL") == true)
        XCTAssertEqual(netRecords[0].stepID, stepID)

        let lines = jsonlLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("malformed_tool_call"))
        XCTAssertTrue(lines[0].contains("MALFORMED_TOOL_CALL"))
    }

    func testMissingToolName_logsToBothLogs() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: Self.missingNamePayload,
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            runtime: runtime
        )

        let netRecords = await waitForNetworkRecords()
        guard netRecords.count == 1 else {
            return XCTFail("expected exactly 1 network record, got \(netRecords.count)")
        }
        XCTAssertTrue(netRecords[0].body?.contains("MISSING_TOOL_NAME") == true)

        let lines = jsonlLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("MISSING_TOOL_NAME"))
    }

    func testChannelOnly_logsNothing() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: Self.channelOnlyPayload,
            sawHarmonyMarker: true,
            task: task,
            roleDefinition: nil,
            conversationMessages: &messages,
            runtime: runtime
        )

        // Give any (incorrectly-scheduled) detached append time to land, then assert none.
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(
            networkToolCallRecords().isEmpty,
            "Channel-only buffer is not a tool-call attempt → no network record (parity)")
        XCTAssertTrue(
            jsonlLines().isEmpty,
            "Channel-only buffer is not a tool-call attempt → no tool_calls.jsonl record (parity)")
    }
}
