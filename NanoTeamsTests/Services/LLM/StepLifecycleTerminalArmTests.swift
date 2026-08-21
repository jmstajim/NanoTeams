import XCTest

@testable import NanoTeams

/// The terminal arms of `startStepExecution`'s tool loop, driven end-to-end
/// through the REAL pipeline (stub client → real streaming → real `ToolRuntime`
/// → real completion), with no network and a temp work folder.
///
/// Every arm follows the same three-beat contract — persist the wire transcript,
/// persist the token usage, then complete — and the ORDER is load-bearing: the
/// transcript is what `ConversationReplay` replays on re-entry, so a completion
/// that lands before the persist leaves the next run rebuilding from the lossy
/// display record. The `.toolFailure` arm and the outer catch arms are already
/// covered elsewhere; `.completed` and `.needsSupervisorInput` were not.
@MainActor
final class StepLifecycleTerminalArmTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!

    private let stepID = "swe"
    private let taskID = 33

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        service.retryDelaySeconds = 1
        mockDelegate = MockLLMExecutionDelegate()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: - .completed

    /// A producing role that submits its expected artifact auto-completes.
    /// `checkArtifactCompleteness` is the only producer of `.completed`, so this
    /// is the arm every pipeline step exits through on success.
    func testCompleted_expectedArtifactSubmitted_persistsTranscriptThenCompletes() async throws {
        seed(producesArtifacts: ["Design Spec"])
        let client = ScriptedToolCallClient(script: [
            .toolCall(name: ToolNames.createArtifact,
                      argumentsJSON: #"{"name":"Design Spec","content":"the spec"}"#),
        ])
        attach(client)

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0)
        try await waitUntil { self.step()?.status == .done }

        let s = step()
        XCTAssertEqual(s?.artifacts.map(\.name), ["Design Spec"],
                       "the deliverable must be on the step, not just on disk")
        XCTAssertFalse(s?.wireTranscript.isEmpty ?? true,
                       "the wire transcript must be persisted BEFORE completing — it is what a "
                           + "later revision replays instead of rebuilding from the display record")
        XCTAssertNil(s?.supervisorQuestion,
                     "a completed step must not also be parked for input")
    }

    /// Completion is gated on the FULL expected set. A role that submits one of
    /// two artifacts must keep going — auto-completing there would strand every
    /// downstream role waiting on the artifact that never arrived.
    func testCompleted_partialArtifactSet_doesNotComplete() async throws {
        seed(producesArtifacts: ["Design Spec", "Research Report"])
        let client = ScriptedToolCallClient(script: [
            .toolCall(name: ToolNames.createArtifact,
                      argumentsJSON: #"{"name":"Design Spec","content":"partial"}"#),
            .hang,
        ])
        attach(client)

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0)
        try await waitUntil { self.step()?.artifacts.count == 1 }

        XCTAssertNotEqual(step()?.status, .done,
                          "one of two expected artifacts must not complete the step")
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)
    }

    // MARK: - .needsSupervisorInput

    /// `ask_supervisor` in a manual-mode team parks the step with the question
    /// recorded. The question is the ONLY thing the composer and the Quick
    /// Capture overlay can render, so losing it wedges the run with no visible
    /// prompt to answer.
    func testNeedsSupervisorInput_askSupervisor_parksWithTheQuestionRecorded() async throws {
        seed(producesArtifacts: [], extraTools: [ToolNames.askSupervisor])
        let client = ScriptedToolCallClient(script: [
            .toolCall(name: ToolNames.askSupervisor,
                      argumentsJSON: #"{"question":"Which database should I use?"}"#),
        ])
        attach(client)

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0)
        try await waitUntil { self.step()?.status == .needsSupervisorInput }

        let s = step()
        XCTAssertEqual(s?.supervisorQuestion, "Which database should I use?")
        XCTAssertEqual(s?.needsSupervisorInput, true)
        XCTAssertFalse(s?.supervisorAnswerPendingDelivery ?? true,
                       "a fresh park must not claim an undelivered answer — that flag is what "
                           + "makes the re-entry append an ask_supervisor envelope")
        XCTAssertFalse(s?.wireTranscript.isEmpty ?? true,
                       "the transcript must be persisted so answering continues the SAME conversation")
        XCTAssertNotEqual(s?.status, .failed,
                          "a successful park must not fall through to the persist-failure arm")
    }

    /// The park must NOT auto-answer in manual mode — that is the whole
    /// distinction between `.manual` and `.autonomous`.
    func testNeedsSupervisorInput_manualMode_recordsNoAnswer() async throws {
        seed(producesArtifacts: [], extraTools: [ToolNames.askSupervisor])
        attach(ScriptedToolCallClient(script: [
            .toolCall(name: ToolNames.askSupervisor, argumentsJSON: #"{"question":"q?"}"#),
        ]))

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0)
        try await waitUntil { self.step()?.status == .needsSupervisorInput }

        XCTAssertNil(step()?.supervisorAnswer,
                     "manual mode must wait for the human, not synthesize an answer")
    }

    /// Defense-in-depth arm: if the question fails to PERSIST, the step must be
    /// failed rather than returned from silently. A silent return leaves the
    /// engine pinned at `.needsSupervisorInput` with no question on the step —
    /// nothing to answer, nothing to resume, and no error anywhere.
    ///
    /// The failure is engineered the way it happens in production: the step's run
    /// is no longer the latest one (a recurrence fire or a restart appended a new
    /// run while this step's loop was still unwinding), so
    /// `setNeedsSupervisorInput`'s `runs.last`-scoped closure finds nothing to
    /// write and reports `false` even though `mutateTask` itself persisted.
    func testNeedsSupervisorInput_persistFails_failsTheStepInsteadOfParkingSilently() async throws {
        seedStepBehindANewerRun(extraTools: [ToolNames.askSupervisor])
        attach(ScriptedToolCallClient(script: [
            .toolCall(name: ToolNames.askSupervisor, argumentsJSON: #"{"question":"q?"}"#),
        ]))

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0)
        try await waitUntil {
            self.mockDelegate.clearStreamingPreviewCalls.contains(self.stepID)
        }

        XCTAssertTrue(mockDelegate.notifyQueuedMessageBackstopCalls.isEmpty,
                      "the backstop fires only on a SUCCESSFUL park — premise: this park failed")
        XCTAssertTrue(mockDelegate.clearStreamingPreviewCalls.contains(stepID),
                      "the failure arm must run step completion, not return silently")
        let parked = mockDelegate.taskToMutate?.runs[0].steps[0]
        XCTAssertNotEqual(parked?.status, .needsSupervisorInput,
                          "a step whose question never persisted must not be left claiming to wait for one")
    }

    // MARK: - Poisoned-tail repair arms the prefix-reset exemption

    /// The retry path repairs a poisoned tail by TRUNCATING it — a deliberate
    /// prefix reset. It must arm the one-shot exemption, or the prompt-prefix
    /// detector reports the app's own repair as a cache defect on the next
    /// request. The flag is armed only when the repair actually fired: arming it
    /// on a no-op would swallow a genuine miss instead.
    func testRetryAfterPoisonedTail_armsTheExpectedPrefixReset() async throws {
        seed(producesArtifacts: [], extraTools: [ToolNames.askSupervisor])
        // Turn 1 emits a tool call the role does NOT hold → rejected → error
        // guidance appended as a `.user` turn. That leaves exactly the shape the
        // repair recognises: assistant(toolCalls), tool, user. Turn 2 then throws
        // a retryable 503, which is where the repair runs.
        attach(ScriptedToolCallClient(script: [
            .toolCall(name: ToolNames.gitCommit, argumentsJSON: #"{"message":"x"}"#),
            .error(LLMClientError.badHTTPStatus(503, "loading")),
        ]))

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0)
        try await waitUntil(timeout: 8) {
            self.service._testExpectedPrefixResetPending(stepID: self.stepID, taskID: self.taskID) == true
        }

        XCTAssertEqual(
            service._testExpectedPrefixResetPending(stepID: stepID, taskID: taskID), true,
            "a repair that truncated the tail must arm the prefix-reset exemption")
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)
    }

    /// The negative half: a retry with NO poisoned tail must leave the exemption
    /// disarmed, so the very next real cache miss is still reported.
    func testRetryWithoutPoisonedTail_leavesTheExemptionDisarmed() async throws {
        seed(producesArtifacts: [], extraTools: [ToolNames.askSupervisor])
        attach(ScriptedToolCallClient(script: [.error(LLMClientError.badHTTPStatus(503, "loading"))]))

        service.startStepExecution(
            stepID: stepID, taskID: taskID, task: mockDelegate.taskToMutate!,
            runIndex: 0, stepIndex: 0)
        // Wait for the retry note — proof the retry path ran at all.
        try await waitUntil(timeout: 8) {
            self.step()?.llmConversation.contains {
                $0.content.hasPrefix(LLMConstants.llmServerErrorRetryNotePrefix)
            } ?? false
        }

        XCTAssertEqual(
            service._testExpectedPrefixResetPending(stepID: stepID, taskID: taskID), false,
            "no repair fired, so nothing may be exempted")
        await service.cancelStepExecution(stepID: stepID, taskID: taskID)
    }

    // MARK: - Fixtures

    private func step() -> StepExecution? {
        mockDelegate.taskToMutate?.runs.last?.steps.first { $0.id == stepID }
    }

    private func attach(_ client: ScriptedToolCallClient) {
        service = LLMExecutionService(repository: NTMSRepository(), clientFactory: { client })
        service.retryDelaySeconds = 1
        service.attach(delegate: mockDelegate)
    }

    private func seed(producesArtifacts: [String], extraTools: [String] = []) {
        let role = TeamRoleDefinition(
            id: stepID, name: "Software Engineer", prompt: "p",
            toolIDs: [ToolNames.readFile] + extraTools, usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: producesArtifacts),
            systemRoleID: "softwareEngineer")
        let team = Team(
            name: "Pipeline", roles: [role], artifacts: [],
            settings: TeamSettings(supervisorMode: .manual), graphLayout: TeamGraphLayout())
        let step = StepExecution(
            id: stepID, role: .softwareEngineer, title: "SWE",
            expectedArtifacts: producesArtifacts, status: .running,
            llmConversation: [LLMMessage(role: .system, content: "System prompt")])
        var task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "Build it",
            runs: [Run(id: 0, steps: [step])])
        task.preferredTeamID = team.id
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "T", activeTeamID: team.id),
                settings: .defaults, teams: [team]),
            tasksIndex: TasksIndex(), toolDefinitions: [],
            activeTaskID: taskID, activeTask: task)
    }

    /// Same team/step as `seed`, but the task carries a SECOND, newer run that
    /// does not contain this step — so every `runs.last`-scoped write no-ops.
    private func seedStepBehindANewerRun(extraTools: [String]) {
        seed(producesArtifacts: [], extraTools: extraTools)
        var task = mockDelegate.taskToMutate!
        task.runs.append(Run(
            id: 1,
            steps: [StepExecution(id: "another_role", role: .productManager,
                                  title: "newer run", status: .pending)]))
        mockDelegate.taskToMutate = task
    }

    private func waitUntil(
        timeout: TimeInterval = 6.0,
        _ condition: @MainActor () -> Bool
    ) async throws {
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

// MARK: - Scripted tool-call client

/// Drives the step's tool loop one scripted turn at a time. Clamps to the LAST
/// entry once the script is exhausted, so a test that expects the loop to settle
/// ends its script with the settling turn.
private final class ScriptedToolCallClient: LLMClient, @unchecked Sendable {
    enum Turn {
        case toolCall(name: String, argumentsJSON: String)
        case text(String)
        /// Yields nothing and holds the connection until cancelled — for tests
        /// that assert the loop did NOT terminate.
        case hang
        case error(Error)
    }

    private let lock = NSLock()
    private var _callCount = 0
    private let script: [Turn]

    init(script: [Turn]) {
        precondition(!script.isEmpty)
        self.script = script
    }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let turn: Turn = lock.withLock {
            let i = min(_callCount, script.count - 1)
            _callCount += 1
            return script[i]
        }
        return AsyncThrowingStream { continuation in
            switch turn {
            case .toolCall(let name, let args):
                continuation.yield(StreamEvent(toolCallDeltas: [
                    StreamEvent.ToolCallDelta(
                        index: 0, id: "call_\(UUID().uuidString.prefix(6))",
                        name: name, argumentsDelta: args)
                ]))
                continuation.finish()
            case .text(let t):
                continuation.yield(StreamEvent(contentDelta: t))
                continuation.finish()
            case .error(let e):
                continuation.finish(throwing: e)
            case .hang:
                let producer = Task.detached {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in producer.cancel() }
            }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}
