import XCTest

@testable import NanoTeams

/// Meeting turns run a separate `ToolRuntime` (built in `handleTeamMeeting` via its
/// own `defaultRegistry` call). These tests pin that the meeting runtime, when given
/// the shared `NetworkLogger`, records BOTH executed and rejected meeting tool calls
/// in `tool_calls.jsonl` AND `network_log.json` — same audit guarantee as the step
/// path — plus the degenerate edges. Regression target: someone dropping
/// `networkLogger:` from the meeting registry build, or the rejection mirror in
/// `MeetingToolExecutor`.
@MainActor
final class MeetingToolCallLoggingTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var jsonlURL: URL!
    private var netURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        jsonlURL = tempDir.appendingPathComponent("tool_calls.jsonl")
        netURL = tempDir.appendingPathComponent("network_log.json")
    }

    override func tearDown() async throws {
        if let tempDir { try? fileManager.removeItem(at: tempDir) }
        tempDir = nil
        jsonlURL = nil
        netURL = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func networkToolCallRecords() throws -> [NetworkLogRecord] {
        guard fileManager.fileExists(atPath: netURL.path) else { return [] }
        let all = try NetworkLogTestReading.strictRecords(at: netURL)
        return all.filter { $0.direction == .toolCall }
    }

    private func jsonlLines() -> [String] {
        guard let text = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Runs one meeting tool-execution turn with the given emitted calls and allowed
    /// tool names. Uses ONE shared `NetworkLogger` for both the runtime and the
    /// streaming logger — mirroring production (`handleTeamMeeting`), so there's never
    /// two instances on one file. The StubLLMClient returns an empty stream, so the
    /// loop exits after this single tool-execution iteration.
    private func runTurn(emitted: [StepToolCall], allowed: [String]) async throws {
        let sharedNetworkLogger = NetworkLogger(logURL: netURL)
        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: jsonlURL,
            networkLogger: sharedNetworkLogger
        )
        let tools = allowed.map {
            ToolSchema(name: $0, description: "t",
                       parameters: JSONSchema(type: "object", properties: [:], required: []))
        }
        let initial = TeamMeetingService.MeetingStreamResult(
            content: "", thinking: "", resolvedToolCalls: emitted)
        _ = NTMSTask(id: 7, title: "T", supervisorTask: "g", runs: [Run(id: 0, steps: [])])
        let context = TeamMeetingService.MeetingContext( initiatedBy: .softwareEngineer,
                                                         participants: [.softwareEngineer, .productManager], availableArtifacts: [],
                                                         artifactReader: { _ in nil }, team: nil,
                                                         coordinatorRole: .softwareEngineer, limits: TeamLimits())
        let toolContext = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 7, runID: 0, roleID: "team_software_engineer")

        _ = try await MeetingToolExecutor.executeTurnToolLoop(
            initialResult: initial,
            conversationSoFar: [ChatMessage(role: .system, content: "meeting system prompt")],
            meetingContext: context,
            client: StubLLMClient(),
            config: LLMConfig(),
            tools: tools,
            runtime: runtime,
            toolContext: toolContext,
            stepID: "team_software_engineer",
            networkLogger: sharedNetworkLogger)
    }

    // MARK: - Tests

    func testMeetingTurn_executedAndRejectedCalls_logToBothSinks() async throws {
        try await runTurn(
            emitted: [
                StepToolCall(name: "list_files", argumentsJSON: #"{"path":"."}"#),  // executes
                StepToolCall(name: "write_file", argumentsJSON: #"{"path":"x","content":"y"}"#),  // rejected
            ],
            allowed: ["list_files"])

        let netRecords = try networkToolCallRecords()
        XCTAssertEqual(netRecords.count, 2, "Executed + rejected meeting calls both in network_log.json")
        let netBodies = netRecords.compactMap(\.body).joined()
        XCTAssertTrue(netBodies.contains("list_files"))
        XCTAssertTrue(netBodies.contains("write_file"))

        let lines = jsonlLines()
        XCTAssertEqual(lines.count, 2, "Executed + rejected meeting calls both in tool_calls.jsonl")
        let joined = lines.joined()
        XCTAssertTrue(joined.contains("list_files"))
        XCTAssertTrue(joined.contains("write_file"))
    }

    /// Edge: a turn where EVERY emitted tool is disallowed (the original meeting-stall
    /// scenario). `validCalls` is empty, `executeAll([])` runs, and all rejections
    /// must still be logged to both sinks — nothing executed.
    func testMeetingTurn_allCallsRejected_loggedToBoth() async throws {
        try await runTurn(
            emitted: [
                StepToolCall(name: "write_file", argumentsJSON: #"{"path":"a","content":"1"}"#),
                StepToolCall(name: "delete_file", argumentsJSON: #"{"path":"b"}"#),
            ],
            allowed: ["list_files"])  // neither emitted tool is allowed

        let netRecords = try networkToolCallRecords()
        XCTAssertEqual(netRecords.count, 2)
        let netBodies = netRecords.compactMap(\.body).joined()
        XCTAssertTrue(netBodies.contains("write_file"))
        XCTAssertTrue(netBodies.contains("delete_file"))
        XCTAssertFalse(netBodies.contains("list_files"), "Nothing was executed")

        XCTAssertEqual(jsonlLines().count, 2)
    }

    /// Edge: a turn with NO tool calls emitted — the loop body never runs, so neither
    /// log gets a record and nothing crashes.
    func testMeetingTurn_noToolCalls_logsNothing() async throws {
        try await runTurn(emitted: [], allowed: ["list_files"])

        XCTAssertTrue(try networkToolCallRecords().isEmpty)
        XCTAssertTrue(jsonlLines().isEmpty)
    }
}

private final class StubLLMClient: LLMClient, @unchecked Sendable {
    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
    func loadModel(provider _: LLMProvider, modelName _: String, baseURLString _: String) async throws -> String { "" }
    func unloadModel(provider _: LLMProvider, instanceID _: String, baseURLString _: String) async throws {}
    func listLoadedInstances(provider _: LLMProvider, baseURLString _: String) async throws -> LoadedInstanceListing { .listed([]) }
}
