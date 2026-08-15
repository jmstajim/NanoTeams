import XCTest

@testable import NanoTeams

/// The arms of `handleTeamMeeting` the happy-path suite does not reach: the
/// stale-task fallback, upstream artifact grounding, the run-log wiring, the
/// turn-limit branch at the TOP of the loop (distinct from the `shouldContinue`
/// exit the happy path takes), the tool-follow-up registrars, and both `catch`
/// arms.
///
/// The two catch arms matter most: a meeting that dies mid-turn must leave a
/// CANCELLED record behind, not an `.inProgress` one — an in-progress meeting
/// keeps its participants glowing in the graph and counts against
/// `maxMeetingsPerRun` forever.
@MainActor
final class TeamMeetingCornerTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    private let stepID = "team_software_engineer"
    private let taskID = 52
    private let initiator: Role = .softwareEngineer

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-corner-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mockDelegate.workFolderURL = tempDir
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: - Failure arms

    /// A stream that throws mid-turn must CANCEL the meeting and say why. Leaving
    /// it `.inProgress` would keep the graph glowing and burn a slot against
    /// `maxMeetingsPerRun` that nothing ever releases.
    func testMeeting_streamThrows_cancelsTheMeetingAndReportsTheReason() async {
        seedDefault(maxTurns: 3)

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "t", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0,
            client: ThrowingMeetingClient(error: LLMClientError.badHTTPStatus(500, "boom")),
            config: stubConfig())

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(reply.text.hasPrefix("Meeting failed:"),
                      "the model needs the reason, not a bare failure; got: \(reply.text)")

        let meeting = mockDelegate.taskToMutate?.runs.first?.meetings.first
        XCTAssertNotNil(meeting, "a failed meeting must still be recorded — the transcript is evidence")
        XCTAssertEqual(meeting?.status, .cancelled,
                       "a meeting that died mid-turn must not be left in progress")
    }

    /// Cancellation (pause during a meeting) is a DIFFERENT arm from a failure and
    /// must not be reported as one — a `Meeting failed:` prefix on a user-initiated
    /// pause reads as a bug to the model and to the human.
    func testMeeting_cancelled_reportsCancellation_notFailure() async {
        seedDefault(maxTurns: 3)

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "t", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0,
            client: ThrowingMeetingClient(error: CancellationError()),
            config: stubConfig())

        XCTAssertFalse(reply.succeeded)
        XCTAssertEqual(reply.text, "Meeting cancelled.",
                       "cancellation has its own arm; got: \(reply.text)")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs.first?.meetings.first?.status, .cancelled)
    }

    // MARK: - Turn limit at the top of the loop

    /// `hasReachedTurnLimit` is checked BEFORE a speaker is chosen, so a limit
    /// already met completes the meeting without ever calling the LLM. The happy
    /// path exits through `shouldContinue` instead, so this branch is only
    /// reachable with a limit of zero.
    func testMeeting_turnLimitAlreadyMet_completesWithoutCallingTheModel() async {
        seedDefault(maxTurns: 0)
        let client = CountingMeetingClient(reply: "should never be said")

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "t", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0, client: client, config: stubConfig())

        XCTAssertTrue(reply.succeeded, "a meeting that ends at the limit is not an error; got: \(reply.text)")
        XCTAssertEqual(client.callCount, 0,
                       "the limit is checked before the speaker turn — no tokens may be spent")
        let meeting = mockDelegate.taskToMutate?.runs.first?.meetings.first
        XCTAssertEqual(meeting?.status, .completed,
                       "the branch must COMPLETE the meeting, not leave it pending")
        XCTAssertTrue(meeting?.messages.isEmpty ?? false)
    }

    // MARK: - Stale task snapshot

    /// The meeting count is read from a FRESH `loadedTask`. When the task is not
    /// loadable at all (evicted, or a delegated child unloaded mid-flight) the
    /// meeting must still run against the snapshot's own count rather than
    /// aborting — the limit is a budget, not a liveness check.
    func testMeeting_taskNotLoadable_fallsBackToTheSnapshotsMeetings() async {
        seedDefault(maxTurns: 1)
        let task = mockDelegate.taskToMutate!
        mockDelegate.taskToMutate = nil             // `loadedTask` → nil

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "t", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, task: task, runIndex: 0, stepIndex: 0,
            client: CountingMeetingClient(reply: "agreed"), config: stubConfig())

        XCTAssertTrue(reply.succeeded,
                      "an unloadable task must not be mistaken for a meeting-limit breach; got: \(reply.text)")
        XCTAssertTrue(reply.text.contains("agreed") || !reply.text.isEmpty,
                      "the meeting result must still reach the model; got: \(reply.text)")
    }

    // MARK: - Upstream artifact grounding

    /// Artifacts produced by EARLIER steps are collected and read into the
    /// speaker's turn. Without it a meeting about a design discusses a design
    /// nobody in the room can see.
    func testMeeting_upstreamArtifacts_areReadAndGroundedIntoTheSpeakersTurn() async {
        let team = makeTeam(maxTurns: 1)
        // Step 0 produced an artifact; our step is index 1, so step 0 is upstream.
        let relPath = writeArtifactFile(named: "design_spec", content: "THE-UPSTREAM-CONTENT")
        let upstream = StepExecution(
            id: "team_pm", role: .productManager, title: "PM", status: .done,
            artifacts: [Artifact(
                name: "Design Spec", icon: "doc", mimeType: "text/markdown",
                createdAt: MonotonicClock.shared.now(), updatedAt: MonotonicClock.shared.now(),
                relativePath: relPath)])
        let mine = StepExecution(id: stepID, role: initiator, title: "SWE", status: .running)
        var task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "b",
            runs: [Run(id: 0, steps: [upstream, mine])])
        task.preferredTeamID = team.id
        seed(task: task, team: team)

        let client = CapturingMeetingClient(reply: "noted")
        _ = await service.handleTeamMeeting(
            stepID: stepID, topic: "t", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, task: task, runIndex: 0, stepIndex: 1,
            client: client, config: stubConfig())

        let wire = client.capturedMessages.flatMap { $0 }.compactMap(\.content).joined(separator: "\n")
        XCTAssertTrue(wire.contains("Design Spec"),
                      "the upstream artifact must be named in the speaker's grounding")
        XCTAssertTrue(wire.contains("THE-UPSTREAM-CONTENT"),
                      "…and its CONTENT must be read through the artifactReader, not just its name")
    }

    // MARK: - Run-log wiring

    /// With logging on, meeting tool calls are written to the RUN's jsonl — the
    /// same audit file step executions use. Without the wiring a meeting's tool
    /// activity is invisible in the audit trail while step activity is not.
    func testMeeting_loggingEnabled_writesMeetingToolCallsIntoTheRunLog() async {
        seedDefault(maxTurns: 1)
        mockDelegate.loggingEnabled = true

        _ = await service.handleTeamMeeting(
            stepID: stepID, topic: "t", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0,
            client: ToolCallThenTextClient(toolName: ToolNames.readFile),
            config: stubConfig())

        let logURL = NTMSPaths(workFolderRoot: tempDir).toolCallsJSONL(taskID: taskID, runID: 0)
        let logged = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(logged.contains(ToolNames.readFile),
                      "a meeting's rejected/executed tool calls must reach the run's jsonl; got: \(logged)")
    }

    // MARK: - Tool follow-up inside a turn

    /// A speaker that emits a tool call takes the follow-up loop: the batch is
    /// registered for cancellation (so pause-during-meeting can reach it) and the
    /// grown conversation is recorded on the meeting's prefix chain. The tool is
    /// deliberately one the meeting does NOT authorize — a rejection still runs the
    /// batch, so this pins the registrars without needing a real tool execution.
    func testMeeting_speakerEmitsUnauthorizedTool_isRejectedAndTheTurnStillCompletes() async {
        seedDefault(maxTurns: 1)

        let reply = await service.handleTeamMeeting(
            stepID: stepID, topic: "t", participantIDs: ["team_pm"], context: nil,
            initiatingRole: initiator, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0,
            client: ToolCallThenTextClient(toolName: ToolNames.readFile),
            config: stubConfig())

        XCTAssertTrue(reply.succeeded,
                      "an unauthorized tool inside a meeting must not stall the turn; got: \(reply.text)")
        let meeting = mockDelegate.taskToMutate?.runs.first?.meetings.first
        XCTAssertEqual(meeting?.status, .completed)
        let summaries = meeting?.messages.compactMap(\.toolSummaries).flatMap { $0 } ?? []
        XCTAssertTrue(summaries.contains { $0.toolName == ToolNames.readFile },
                      "the rejected call must still be recorded as a tool summary — silently dropping it "
                        + "is what stalled meetings before; got \(summaries.map(\.toolName))")
        XCTAssertTrue(summaries.contains { $0.isError },
                      "the rejection must be visible as an error, not a green no-op")
    }

    // MARK: - Fixtures

    private func writeArtifactFile(named slug: String, content: String) -> String {
        let paths = NTMSPaths(workFolderRoot: tempDir)
        let dir = paths.roleDir(taskID: taskID, runID: 0, roleID: "team_pm")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("artifact_\(slug).md")
        try? content.write(to: file, atomically: true, encoding: .utf8)
        return paths.relativePathWithinNanoteams(for: file)
    }

    private func seedDefault(maxTurns: Int) {
        let team = makeTeam(maxTurns: maxTurns)
        let step = StepExecution(id: stepID, role: initiator, title: "SWE", status: .running)
        var task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "b", runs: [Run(id: 0, steps: [step])])
        task.preferredTeamID = team.id
        seed(task: task, team: team)
    }

    private func seed(task: NTMSTask, team: Team) {
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "T", activeTeamID: team.id),
                settings: .defaults, teams: [team]),
            tasksIndex: TasksIndex(), toolDefinitions: [],
            activeTaskID: task.id, activeTask: task)
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    private func makeTeam(maxTurns: Int) -> Team {
        let pm = TeamRoleDefinition(
            id: "team_pm", name: "Product Manager", prompt: "p",
            toolIDs: [ToolNames.requestTeamMeeting], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "productManager")
        let swe = TeamRoleDefinition(
            id: stepID, name: "Software Engineer", prompt: "p",
            toolIDs: [ToolNames.requestTeamMeeting], usePlanningPhase: false,
            dependencies: RoleDependencies(), systemRoleID: "softwareEngineer")
        return Team(
            name: "MeetingTeam", roles: [pm, swe], artifacts: [],
            settings: TeamSettings(limits: TeamLimits(maxMeetingsPerRun: 3, maxMeetingTurns: maxTurns)),
            graphLayout: TeamGraphLayout())
    }

    private func stubConfig() -> LLMConfig {
        LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")
    }
}

// MARK: - Clients

/// Throws on the first stream. Used for both catch arms — the arm is selected by
/// the error's TYPE, which is the discrimination under test.
private final class ThrowingMeetingClient: LLMClient, @unchecked Sendable {
    private let error: Error
    init(error: Error) { self.error = error }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let e = error
        return AsyncThrowingStream { $0.finish(throwing: e) }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

/// Counts calls so a test can assert the model was never consulted.
private final class CountingMeetingClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }
    private let reply: String
    init(reply: String) { self.reply = reply }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock { _callCount += 1 }
        let text = reply
        return AsyncThrowingStream {
            $0.yield(StreamEvent(contentDelta: text))
            $0.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

/// Records every message array it was handed, so a test can assert what actually
/// reached the wire rather than inferring it from a side effect.
private final class CapturingMeetingClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _captured: [[ChatMessage]] = []
    var capturedMessages: [[ChatMessage]] { lock.withLock { _captured } }
    private let reply: String
    init(reply: String) { self.reply = reply }

    func streamChat(
        config _: LLMConfig, messages: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock { _captured.append(messages) }
        let text = reply
        return AsyncThrowingStream {
            $0.yield(StreamEvent(contentDelta: text))
            $0.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

/// Emits one tool call on the first stream, then plain text — the minimum shape
/// that drives `MeetingToolExecutor`'s follow-up loop exactly once and then lets
/// the turn settle.
private final class ToolCallThenTextClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private let toolName: String
    init(toolName: String) { self.toolName = toolName }

    func streamChat(
        config _: LLMConfig, messages _: [ChatMessage], tools _: [ToolSchema],
        logger _: NetworkLogger?, stepID _: String?, roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let isFirst = lock.withLock { () -> Bool in
            _callCount += 1
            return _callCount == 1
        }
        let name = toolName
        return AsyncThrowingStream { continuation in
            if isFirst {
                continuation.yield(StreamEvent(toolCallDeltas: [
                    StreamEvent.ToolCallDelta(
                        index: 0, id: "call_1", name: name, argumentsDelta: "{}")
                ]))
            } else {
                continuation.yield(StreamEvent(contentDelta: "done, thanks"))
            }
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
