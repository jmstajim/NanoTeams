import XCTest

@testable import NanoTeams

/// A Pause that lands while an Auto judge is being asked must not be recorded as the judge
/// refusing the call.
///
/// The judges fold every way their call can end without a verdict into a fail-closed DENY —
/// a transport error, an empty reply, a throw. Cancellation is one of those ways, and it is
/// not a refusal: nobody judged anything (#152 — the same defect the human approval hold had
/// until 2026-08-30). And the denial is not transient: `cancelStepExecution` AWAITS the step's
/// task before it clears the execution entry, so everything the iteration does after the gate
/// still passes `isExecutionLive` — the envelope goes onto the tool-call card, into the
/// conversation that the resumed step replays, and into `tool_calls.jsonl` as a gate refusal.
///
/// Driven end to end: a real step, a scripted client whose first reply is the tool call and
/// whose second request — the judge's — hangs until the Pause cancels it.
@MainActor
final class JudgePauseLeavesNoDenialTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    private let stepID = "engineer"
    private let taskID = 61

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        mockDelegate = MockLLMExecutionDelegate()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("judge-pause-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mockDelegate.workFolderURL = tempDir
        mockDelegate.loggingEnabled = true
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: - The two judges

    func testPauseDuringTheBashJudge_leavesNoDenial() async throws {
        mockDelegate.bashPolicy = BashPolicy(mode: .auto, restrictionLevel: .standard)
        let call = try await pauseWhileTheJudgeIsAsked(
            toolID: ToolNames.bash, argumentsJSON: #"{"command":"rm -rf build"}"#)
        try assertNoDenial(for: call, deniedCode: ToolErrorCode.bashDenied.rawValue)
    }

    func testPauseDuringTheComputerUseJudge_leavesNoDenial() async throws {
        mockDelegate.computerUsePolicy = ComputerUsePolicy(mode: .auto, restrictionLevel: .standard)
        let call = try await pauseWhileTheJudgeIsAsked(
            toolID: ToolNames.uiKey, argumentsJSON: #"{"keys":"cmd+return"}"#)
        try assertNoDenial(for: call, deniedCode: ToolErrorCode.computerUseDenied.rawValue)
    }

    // MARK: - Driver

    /// Starts the step, waits for the judge's request (the client's second), pauses, and
    /// returns the gated call as the step recorded it.
    private func pauseWhileTheJudgeIsAsked(toolID: String, argumentsJSON: String) async throws -> StepToolCall {
        seed(toolID: toolID)
        let client = ScriptedToolCallClient(script: [
            .toolCall(name: toolID, argumentsJSON: argumentsJSON),
            .hang,
        ])
        service = LLMExecutionService(repository: NTMSRepository(), clientFactory: { client })
        service.retryDelaySeconds = 1
        service.attach(delegate: mockDelegate)

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!, runIndex: 0, stepIndex: 0)
        try await waitUntil { client.callCount >= 2 }
        XCTAssertTrue(step()?.toolCalls.contains { $0.name == toolID } ?? false,
                      "premise: the gated call is on the step before the judge is asked")
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)

        return try XCTUnwrap(step()?.toolCalls.first { $0.name == toolID })
    }

    // MARK: - What must not be anywhere

    /// The needles a fail-closed judge deny writes — the envelope's code and the runtime's
    /// sentences. Any of them after a Pause is a refusal nobody made.
    private func denialNeedles(deniedCode: String) -> [String] {
        [deniedCode, "judge call failed", "denied for safety", "Judge returned no verdict",
         JudgeFailClosedReason.actionNoVerdict, JudgeFailClosedReason.actionUnparseable]
    }

    private func assertNoDenial(
        for call: StepToolCall, deniedCode: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let needles = denialNeedles(deniedCode: deniedCode)
        func offending(_ text: String?) -> String? {
            guard let text else { return nil }
            return needles.first { text.contains($0) }
        }

        // The tool-call card in the feed. Unwrapped, not `if let`: the positive half of this
        // test is that the paused call is ANSWERED as cancelled, and a call left with no result
        // at all would otherwise pass every needle check and skip this one.
        let result = try XCTUnwrap(call.resultJSON, "the paused call is answered", file: file, line: line)
        XCTAssertNil(offending(result), "the card reads as a refusal: \(result)", file: file, line: line)
        XCTAssertTrue(result.contains(ToolErrorCode.cancelled.rawValue),
                      "a call the Pause stopped reads as cancelled: \(result)", file: file, line: line)

        let recorded = step()
        // The feed's messages and the display conversation.
        let persisted = (recorded?.messages ?? []).map(\.content) + (recorded?.llmConversation ?? []).map(\.content)
        for content in persisted {
            XCTAssertNil(offending(content), "a persisted message carries the refusal: \(content)",
                         file: file, line: line)
        }
        // The wire the resumed step replays.
        for message in recorded?.wireTranscript ?? [] {
            XCTAssertNil(offending(message.content), "the replayed wire carries the refusal: \(message.content ?? "")",
                         file: file, line: line)
        }
        // The per-run tool log.
        for (path, text) in toolCallLogs() {
            XCTAssertNil(offending(text), "\(path) logged a gate refusal for a paused call", file: file, line: line)
        }
    }

    // MARK: - Fixtures

    private func step() -> StepExecution? {
        mockDelegate.taskToMutate?.runs.last?.steps.first { $0.id == stepID }
    }

    /// Every `tool_calls.jsonl` under the temp work folder, whatever the nesting.
    private func toolCallLogs() -> [(String, String)] {
        var out: [(String, String)] = []
        let walker = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.lastPathComponent == "tool_calls.jsonl",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((url.path, text))
        }
        return out
    }

    private func seed(toolID: String) {
        let role = TeamRoleDefinition(
            id: stepID, name: "Engineer", prompt: "p",
            toolIDs: [toolID, ToolNames.createArtifact],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Supervisor Task"],
                                           producesArtifacts: ["Engineering Notes"]),
            systemRoleID: "softwareEngineer")
        let team = Team(
            name: "Pipeline", roles: [role], artifacts: [],
            settings: TeamSettings(supervisorMode: .manual), graphLayout: TeamGraphLayout())
        let step = StepExecution(
            id: stepID, role: .softwareEngineer, title: "Engineer",
            expectedArtifacts: ["Engineering Notes"], status: .running,
            llmConversation: [LLMMessage(role: .system, content: "System prompt")])
        var task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "Build it",
            runs: [Run(id: 0, steps: [step], roleStatuses: [stepID: .working])])
        task.preferredTeamID = team.id
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "T", activeTeamID: team.id),
                settings: ProjectSettings.defaults, teams: [team]),
            tasksIndex: TasksIndex(), toolDefinitions: [],
            activeTaskID: taskID, activeTask: task)
    }

    private func waitUntil(timeout: TimeInterval = 8.0, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw WaitTimeout(timeout: timeout) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct WaitTimeout: Error, LocalizedError {
        let timeout: TimeInterval
        var errorDescription: String? { "condition not met within \(timeout)s" }
    }
}
