import XCTest

@testable import NanoTeams

// MARK: - Shared private doubles
//
// Every file-scope helper here is `private` on purpose: the test target is one module
// and generic names like `StubClient` collide across files.

/// Yields a scripted answer on the content channel and records how many times it was
/// asked, so a test can prove the auto-answer really went through
/// `SupervisorAutoAnswerService` rather than a hard-coded fallback.
private final class ScriptedAnswerClient: LLMClient, @unchecked Sendable {
    private let answer: String
    private(set) var callCount = 0

    init(answer: String) { self.answer = answer }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        callCount += 1
        let text = answer
        return AsyncThrowingStream { continuation in
            if !text.isEmpty { continuation.yield(StreamEvent(contentDelta: text)) }
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

/// Never yields anything — exercises the "no content" fallback in
/// `SupervisorAutoAnswerService.generateAnswer` and keeps `startStepExecution`'s
/// spawned tool loop from ever reaching the network.
private final class SilentStreamClient: LLMClient, @unchecked Sendable {
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

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

/// Thread-safe latch used to observe that a `Task` handed to production code was
/// actually cancelled. `Task` exposes no external `isCancelled`, so the task body
/// sets this on its way out.
private final class CancellationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Builds a team whose Supervisor requires a deliverable → `isChatMode == false`.
/// Attached via `adoptGeneratedTeam` because `resolveTeam` prefers the task-owned
/// team, which is the lightest way to drive team-shaped branches.
private func makeNonChatTeamFixtureForLoopStateSuite(worker: TeamRoleDefinition) -> Team {
    var settings = TeamSettings()
    settings.supervisorMode = .autonomous
    let supervisor = TeamRoleDefinition(
        id: "sup", name: "Supervisor", prompt: "",
        toolIDs: [], usePlanningPhase: false,
        dependencies: RoleDependencies(
            requiredArtifacts: ["Final Deliverable"],
            producesArtifacts: ["Supervisor Task"]
        ),
        isSystemRole: true,
        systemRoleID: "supervisor"
    )
    return Team(
        id: "t", name: "T", roles: [supervisor, worker], artifacts: [],
        settings: settings, graphLayout: TeamGraphLayout()
    )
}

private func makeAdvisoryRoleFixtureForLoopStateSuite(id: String) -> TeamRoleDefinition {
    TeamRoleDefinition(
        id: id, name: "Advisor", prompt: "",
        toolIDs: [], usePlanningPhase: false,
        dependencies: RoleDependencies(requiredArtifacts: ["Supervisor Task"], producesArtifacts: [])
    )
}

// MARK: - handleSupervisorAutoAnswer (the positive, in-loop path)

/// `+ToolLoopState.handleSupervisorAutoAnswer`. The three early-return arms (manual
/// mode, no question, Autovisor-supervised) are pinned in `ToolExecutionTests`; the
/// path that actually generates and threads an answer was not, and neither were the
/// gate's corner cases (a delegation child, the manager's own task, the trigger off).
@MainActor
final class ToolLoopStateSupervisorAutoAnswerCoverageTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!
    private var task: NTMSTask!
    private let stepID = "swe"

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)

        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "Work", status: .running)
        task = NTMSTask(id: 0, title: "T", supervisorTask: "build it", runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        service = nil
        mockDelegate = nil
        task = nil
        try await super.tearDown()
    }

    private func outcome(providerID: String?) -> LLMExecutionService.ToolResultsOutcome {
        LLMExecutionService.ToolResultsOutcome(
            shouldStopForSupervisor: true,
            supervisorQuestion: "Which UI framework?",
            supervisorToolCallProviderIDs: providerID.map { [$0] } ?? []
        )
    }

    private var persistedStep: StepExecution? {
        mockDelegate.taskToMutate?.runs.last?.steps.first(where: { $0.id == stepID })
    }

    // MARK: - Wire threading

    /// The pending `ask_supervisor` tool result is REPLACED in place. Appending a
    /// second `.tool` message instead would leave the original placeholder answering
    /// the same `tool_call_id` twice.
    func testAutoAnswer_replacesPendingToolResultInPlace_withoutAppending() async {
        let client = ScriptedAnswerClient(answer: "Use SwiftUI.")
        var conversation: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "task"),
            ChatMessage(role: .assistant, content: "asking"),
            ChatMessage(role: .tool, content: #"{"ok":true,"status":"pending"}"#, toolCallID: "tc-1"),
        ]

        let stop = await service.handleSupervisorAutoAnswer(
            outcome: outcome(providerID: "tc-1"),
            stepID: stepID,
            supervisorMode: .autonomous,
            task: mockDelegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: LLMConfig(),
            conversationMessages: &conversation
        )

        guard case .continueLoop = stop else {
            return XCTFail("An auto-answered question must continue the loop, got \(String(describing: stop))")
        }
        XCTAssertEqual(conversation.count, 4, "Replacement, never an append")
        XCTAssertEqual(conversation[3].role, .tool)
        XCTAssertEqual(conversation[3].toolCallID, "tc-1",
                       "The replacement must keep answering the same tool_call_id")
        let payload = conversation[3].content ?? ""
        XCTAssertTrue(payload.contains("Use SwiftUI."), "Answer must reach the wire, got: \(payload)")
        XCTAssertTrue(payload.contains("\"ok\":true"), "Envelope shape, got: \(payload)")
        XCTAssertTrue(payload.contains(ToolNames.askSupervisor),
                      "Envelope must name the tool it resolves, got: \(payload)")
        XCTAssertEqual(client.callCount, 1, "Exactly one generation call")
    }

    /// No provider id recorded (a Harmony envelope the accumulator never gave an id):
    /// the answer still has to reach the model, as a prefixed user turn.
    func testAutoAnswer_nilProviderID_appendsPrefixedUserTurn() async {
        let client = ScriptedAnswerClient(answer: "Ship the simplest thing.")
        var conversation: [ChatMessage] = [ChatMessage(role: .assistant, content: "asking")]

        let stop = await service.handleSupervisorAutoAnswer(
            outcome: outcome(providerID: nil),
            stepID: stepID,
            supervisorMode: .autonomous,
            task: mockDelegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: LLMConfig(),
            conversationMessages: &conversation
        )

        guard case .continueLoop = stop else { return XCTFail("expected .continueLoop") }
        XCTAssertEqual(conversation.count, 2)
        XCTAssertEqual(conversation.last?.role, .user)
        XCTAssertEqual(
            conversation.last?.content,
            "\(MessageSourceContext.supervisorAnswerPrefix)Ship the simplest thing.")
    }

    /// A provider id that matches nothing in the conversation takes the same fallback —
    /// silently dropping the answer would leave the model waiting on a tool result forever.
    func testAutoAnswer_providerIDAbsentFromConversation_fallsBackToUserTurn() async {
        let client = ScriptedAnswerClient(answer: "Proceed.")
        var conversation: [ChatMessage] = [
            ChatMessage(role: .tool, content: "{}", toolCallID: "some-other-id")
        ]

        _ = await service.handleSupervisorAutoAnswer(
            outcome: outcome(providerID: "tc-missing"),
            stepID: stepID,
            supervisorMode: .autonomous,
            task: mockDelegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: LLMConfig(),
            conversationMessages: &conversation
        )

        XCTAssertEqual(conversation.count, 2, "Fallback appends rather than dropping the answer")
        XCTAssertEqual(conversation.last?.role, .user)
        XCTAssertEqual(conversation.first?.content, "{}", "The unrelated tool result is untouched")
    }

    // MARK: - Persistence

    /// The in-loop answer must NOT arm `supervisorAnswerPendingDelivery`. This path
    /// injects the answer into the live conversation itself and never suspends, so a
    /// later pause/resume of the same step would re-append the identical
    /// `ask_supervisor` envelope and the model would execute the instruction twice.
    func testAutoAnswer_persistsAnswerAsAuto_andNeverArmsPendingDelivery() async {
        let client = ScriptedAnswerClient(answer: "Use SwiftUI.")
        var conversation: [ChatMessage] = []

        _ = await service.handleSupervisorAutoAnswer(
            outcome: outcome(providerID: nil),
            stepID: stepID,
            supervisorMode: .autonomous,
            task: mockDelegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: LLMConfig(),
            conversationMessages: &conversation
        )

        let step = persistedStep
        XCTAssertEqual(step?.supervisorAnswer, "Use SwiftUI.")
        XCTAssertEqual(step?.supervisorQuestion, "Which UI framework?")
        XCTAssertEqual(step?.supervisorAnswerWasAuto, true,
                       "An LLM-authored answer must be badged 'Auto-answered'")
        XCTAssertEqual(step?.needsSupervisorInput, false)
        XCTAssertEqual(step?.supervisorAnswerPendingDelivery, false,
                       "The in-loop path delivers the answer itself — arming this re-delivers it on re-entry")
    }

    /// The answer also has to be visible in the feed, attributed to the Supervisor.
    func testAutoAnswer_recordsAttributedSupervisorTurn() async {
        let client = ScriptedAnswerClient(answer: "Use SwiftUI.")
        var conversation: [ChatMessage] = []

        _ = await service.handleSupervisorAutoAnswer(
            outcome: outcome(providerID: nil),
            stepID: stepID,
            supervisorMode: .autonomous,
            task: mockDelegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: LLMConfig(),
            conversationMessages: &conversation
        )

        let recorded = persistedStep?.llmConversation.last
        XCTAssertEqual(recorded?.role, .user)
        XCTAssertEqual(recorded?.sourceRole, .supervisor)
        XCTAssertEqual(recorded?.sourceContext, .supervisorAnswer)
        XCTAssertTrue(recorded?.content.contains("Use SwiftUI.") == true)
    }

    /// An empty generation must not ship an empty decision — the service's documented
    /// fallback is what keeps the blocked role moving.
    func testAutoAnswer_emptyGeneration_usesServiceFallbackAnswer() async {
        var conversation: [ChatMessage] = []

        _ = await service.handleSupervisorAutoAnswer(
            outcome: outcome(providerID: nil),
            stepID: stepID,
            supervisorMode: .autonomous,
            task: mockDelegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: SilentStreamClient(),
            config: LLMConfig(),
            conversationMessages: &conversation
        )

        XCTAssertEqual(persistedStep?.supervisorAnswer, SupervisorAutoAnswerService.fallbackAnswer)
        XCTAssertEqual(
            conversation.last?.content,
            "\(MessageSourceContext.supervisorAnswerPrefix)\(SupervisorAutoAnswerService.fallbackAnswer)")
    }

    // MARK: - Autovisor suppression gate — the corners the truth table turns on

    private func installAutovisorSnapshot(
        enabled: Bool = true,
        managerTaskID: Int? = 99,
        needsSupervisorTrigger: Bool = true
    ) {
        var activation = AutovisorActivation.default
        activation.onTaskNeedsSupervisor = needsSupervisorTrigger
        mockDelegate.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "Test", autovisorTaskID: managerTaskID),
                settings: ProjectSettings(
                    autovisorEnabled: enabled, autovisorActivation: activation),
                teams: []
            ),
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: nil,
            activeTask: nil
        )
    }

    /// `AutovisorPolicy.supervisesTask` requires `parentTaskID == nil`. A delegation
    /// child routes its questions back to the delegating role, so the generic
    /// auto-answer must still run for it.
    func testAutoAnswer_delegationChild_isNotSuppressed() async {
        installAutovisorSnapshot()
        let child = NTMSTask(
            id: 7, title: "child", supervisorTask: "sub work",
            runs: [Run(id: 0, steps: [StepExecution(id: stepID, role: .softwareEngineer, title: "W", status: .running)])],
            parentTaskID: 1, parentRoleID: "coding_agent", delegationDepth: 1)
        mockDelegate.taskToMutate = child
        service._testRegisterStepTask(stepID: stepID, taskID: child.id)

        let client = ScriptedAnswerClient(answer: "Keep going.")
        var conversation: [ChatMessage] = []
        let stop = await service.handleSupervisorAutoAnswer(
            outcome: outcome(providerID: nil),
            stepID: stepID,
            supervisorMode: .autonomous,
            task: child,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: LLMConfig(),
            conversationMessages: &conversation
        )

        guard case .continueLoop = stop else {
            return XCTFail("A delegation child must not be suppressed, got \(String(describing: stop))")
        }
        XCTAssertEqual(client.callCount, 1)
    }

    /// The manager's OWN task is excluded from its own supervision — otherwise it
    /// would park waiting for itself.
    func testAutoAnswer_managerOwnTask_isNotSuppressed() async {
        installAutovisorSnapshot(managerTaskID: 0)  // task under test has id 0
        let client = ScriptedAnswerClient(answer: "Continue the pass.")
        var conversation: [ChatMessage] = []

        let stop = await service.handleSupervisorAutoAnswer(
            outcome: outcome(providerID: nil),
            stepID: stepID,
            supervisorMode: .autonomous,
            task: mockDelegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: LLMConfig(),
            conversationMessages: &conversation
        )

        guard case .continueLoop = stop else {
            return XCTFail("The manager's own task must not be suppressed, got \(String(describing: stop))")
        }
        XCTAssertEqual(client.callCount, 1)
    }

    /// Feature on but the `onTaskNeedsSupervisor` trigger off: the manager is not
    /// acting as the folder Supervisor, so suppression must not fire either.
    func testAutoAnswer_triggerDisabled_isNotSuppressed() async {
        installAutovisorSnapshot(needsSupervisorTrigger: false)
        let client = ScriptedAnswerClient(answer: "Go ahead.")
        var conversation: [ChatMessage] = []

        let stop = await service.handleSupervisorAutoAnswer(
            outcome: outcome(providerID: nil),
            stepID: stepID,
            supervisorMode: .autonomous,
            task: mockDelegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: LLMConfig(),
            conversationMessages: &conversation
        )

        guard case .continueLoop = stop else {
            return XCTFail("A disabled trigger must not suppress, got \(String(describing: stop))")
        }
        XCTAssertEqual(client.callCount, 1)
    }

    /// The feature switched off entirely — same conclusion, different input.
    func testAutoAnswer_autovisorDisabled_isNotSuppressed() async {
        installAutovisorSnapshot(enabled: false)
        let client = ScriptedAnswerClient(answer: "Go ahead.")
        var conversation: [ChatMessage] = []

        let stop = await service.handleSupervisorAutoAnswer(
            outcome: outcome(providerID: nil),
            stepID: stepID,
            supervisorMode: .autonomous,
            task: mockDelegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: LLMConfig(),
            conversationMessages: &conversation
        )

        guard case .continueLoop = stop else {
            return XCTFail("A disabled Autovisor must not suppress, got \(String(describing: stop))")
        }
        XCTAssertEqual(client.callCount, 1)
    }

    // MARK: - Post-teardown write barrier

    /// After teardown the `isExecutionLive` barrier drops every persisted write, so a
    /// cancelled step can't land an answer on whatever currently answers to its taskID.
    /// The in-memory conversation is the caller's own array and is still threaded.
    func testAutoAnswer_afterTeardown_persistsNothing() async {
        service.clearRunningTask(stepID: stepID, taskID: task.id)
        let client = ScriptedAnswerClient(answer: "Too late.")
        var conversation: [ChatMessage] = []

        _ = await service.handleSupervisorAutoAnswer(
            outcome: outcome(providerID: nil),
            stepID: stepID,
            supervisorMode: .autonomous,
            task: mockDelegate.taskToMutate!,
            runIndex: 0,
            stepIndex: 0,
            client: client,
            config: LLMConfig(),
            conversationMessages: &conversation
        )

        XCTAssertNil(persistedStep?.supervisorAnswer,
                     "A torn-down step must not have an answer written behind it")
        XCTAssertTrue(persistedStep?.llmConversation.isEmpty ?? false,
                      "…nor an attributed turn recorded")
    }
}

// MARK: - checkAndInjectLoopWarning (the PERSIST half)

/// `+ToolLoopState.checkAndInjectLoopWarning`. The existing coverage asserts the wire
/// array only, and conditionally at that. The half that regressed historically is the
/// PERSIST side: the warning used to be recorded as `.system`, which put a
/// mid-conversation system message into every stateless rebuild.
@MainActor
final class ToolLoopStateLoopWarningCoverageTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tracker: ToolCallTracker!
    private var task: NTMSTask!
    private let stepID = "swe"

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        tracker = ToolCallTracker()

        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "W", status: .running)
        task = NTMSTask(id: 0, title: "T", supervisorTask: "goal", runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() async throws {
        service = nil
        mockDelegate = nil
        tracker = nil
        task = nil
        try await super.tearDown()
    }

    /// Six IDENTICAL reads is the deterministic loop trigger — `.repetitiveTool(read_file, 6)`
    /// (`detectLoopPattern` needs 6 recent calls; identity = tool + canonical arguments).
    private func recordSixReadOnlyCalls() {
        for _ in 0..<6 {
            tracker.record(
                toolName: ToolNames.readFile,
                argumentsJSON: #"{"path":"a.swift"}"#,
                resultJSON: #"{"ok":true}"#,
                isError: false)
        }
    }

    private var persistedUserTurns: [LLMMessage] {
        (mockDelegate.taskToMutate?.runs.last?.steps.first?.llmConversation ?? [])
            .filter { $0.role == .user }
    }

    func testLoopWarning_isPersistedAsAUserTurn_neverSystem() async {
        recordSixReadOnlyCalls()
        var messages: [ChatMessage] = []

        await service.checkAndInjectLoopWarning(
            stepID: stepID, taskID: task.id, tracker: tracker,
            allowedToolNames: [ToolNames.askSupervisor], conversationMessages: &messages)

        XCTAssertEqual(messages.count, 1, "Six read-only calls must trigger the warning")
        XCTAssertEqual(messages[0].role, .user)

        let persisted = mockDelegate.taskToMutate?.runs.last?.steps.first?.llmConversation ?? []
        XCTAssertEqual(persisted.count, 1, "The warning must also be recorded")
        XCTAssertEqual(
            persisted[0].role, .user,
            "Persisting as .system puts a mid-conversation system message into every rebuild")
    }

    /// RED: delete the `warnedLoopSignatures` gate → 5 warnings on the wire and 5 recorded.
    ///
    /// `detectLoopPattern` is stateless: while the model keeps reading, the condition keeps
    /// reporting. `maxToolIterations` is 0 (unbounded) and a successful read batch counts as
    /// PRODUCTIVE, so no escalation ceiling advances either — the identical sentence was
    /// appended on every iteration for the rest of the step, to a conversation resent whole
    /// each time. Neither request builder dedupes it: Ollama merges consecutive user turns
    /// and LM Studio flattens them, so every copy is paid for in tokens.
    func testLoopWarning_repeatedIterationsOfTheSameCondition_warnOnlyOnce() async {
        recordSixReadOnlyCalls()
        var messages: [ChatMessage] = []

        for _ in 0..<5 {
            await service.checkAndInjectLoopWarning(
                stepID: stepID, taskID: task.id, tracker: tracker,
                allowedToolNames: [ToolNames.askSupervisor], conversationMessages: &messages)
        }

        XCTAssertEqual(messages.count, 1, "the same condition must not be re-stated every iteration")
        XCTAssertEqual(persistedUserTurns.count, 1)
    }

    /// …but a run RESUMED after information reached the model is a new condition. Without
    /// the epoch in the signature the gate would retire the whole information-boundary
    /// mechanism after one use: the post-boundary run is detected and then swallowed under
    /// the signature the pre-boundary run inserted, so a role that loops, is told
    /// something, and loops again passes in silence.
    ///
    /// RED: drop the `epoch:` argument from `loopWarningSignature` → the second warning
    /// disappears and only the first is on the wire.
    func testLoopWarning_sameToolAfterAnInformationBoundary_isReported() async {
        recordSixReadOnlyCalls()
        var messages: [ChatMessage] = []

        await service.checkAndInjectLoopWarning(
            stepID: stepID, taskID: task.id, tracker: tracker,
            allowedToolNames: [ToolNames.askSupervisor], conversationMessages: &messages)
        XCTAssertEqual(messages.count, 1, "the pre-boundary loop is warned about once")

        // An event notice lands, and the role goes right back to the same call.
        tracker.noteExternalInformationArrived()
        recordSixReadOnlyCalls()

        await service.checkAndInjectLoopWarning(
            stepID: stepID, taskID: task.id, tracker: tracker,
            allowedToolNames: [ToolNames.askSupervisor], conversationMessages: &messages)

        XCTAssertEqual(messages.count, 2,
                       "being told something and looping anyway is a new condition to state")
        XCTAssertEqual(persistedUserTurns.count, 2)
    }

    /// The other side of that gate, and the one an eager epoch gets wrong. An arrival
    /// advances `ToolCallTracker.informationEpoch` the instant the turn is delivered —
    /// BEFORE the model has made a single call under it, and the warning check runs later
    /// in that very same iteration. Keying the signature on the tracker's value therefore
    /// re-armed the gate and re-stated an identical warning about a run made ENTIRELY
    /// before the news. The signature keys on the epoch of the DETECTED RUN instead
    /// (`ToolCallLoopDetector.epochOfTrailingRun`), which has not moved yet.
    ///
    /// RED: pass `tracker.informationEpoch` to `loopWarningSignature` instead → a second
    /// identical nudge appears here, on a transport that resends the whole array.
    func testLoopWarning_arrivalWithNoCallYet_doesNotReStateTheSameLoop() async {
        recordSixReadOnlyCalls()
        var messages: [ChatMessage] = []
        await service.checkAndInjectLoopWarning(
            stepID: stepID, taskID: task.id, tracker: tracker,
            allowedToolNames: [ToolNames.askSupervisor], conversationMessages: &messages)
        XCTAssertEqual(messages.count, 1)

        // News arrives; the model has not acted on it yet, so the run the detector sees is
        // unchanged — every call in it predates the arrival.
        tracker.noteExternalInformationArrived()

        await service.checkAndInjectLoopWarning(
            stepID: stepID, taskID: task.id, tracker: tracker,
            allowedToolNames: [ToolNames.askSupervisor], conversationMessages: &messages)

        XCTAssertEqual(messages.count, 1,
                       "no visible call has been made since the arrival — there is nothing new "
                       + "to say about a run that ended before it")
        XCTAssertEqual(persistedUserTurns.count, 1)
    }

    /// Same shape, but the model's one move since the arrival is INVISIBLE to the detector
    /// (`update_scratchpad` is excluded from repetition — and it is the likeliest move
    /// right after being told something). The trailing run is still entirely pre-arrival,
    /// so the warning must still not repeat.
    func testLoopWarning_arrivalFollowedOnlyByAnExcludedCall_doesNotReStateTheSameLoop() async {
        recordSixReadOnlyCalls()
        var messages: [ChatMessage] = []
        await service.checkAndInjectLoopWarning(
            stepID: stepID, taskID: task.id, tracker: tracker,
            allowedToolNames: [ToolNames.askSupervisor], conversationMessages: &messages)
        XCTAssertEqual(messages.count, 1)

        tracker.noteExternalInformationArrived()
        tracker.record(
            toolName: ToolNames.updateScratchpad,
            argumentsJSON: #"{"content":"noted the message"}"#,
            resultJSON: #"{"ok":true}"#, isError: false)

        await service.checkAndInjectLoopWarning(
            stepID: stepID, taskID: task.id, tracker: tracker,
            allowedToolNames: [ToolNames.askSupervisor], conversationMessages: &messages)

        XCTAssertEqual(messages.count, 1,
                       "an excluded call is not the model resuming the run under new information")
        XCTAssertEqual(persistedUserTurns.count, 1)
    }

    /// …and the gate is per CONDITION, not per step: a role that stops read-looping and
    /// starts repeating one call has a genuinely new thing to be told.
    ///
    /// RED: key the gate on a constant instead of `loopWarningSignature` → the second
    /// warning is swallowed and the model is never told about the new loop.
    func testLoopWarning_aDifferentCondition_isStillReported() async {
        recordSixReadOnlyCalls()
        var messages: [ChatMessage] = []
        await service.checkAndInjectLoopWarning(
            stepID: stepID, taskID: task.id, tracker: tracker,
            allowedToolNames: [], conversationMessages: &messages)
        XCTAssertEqual(messages.count, 1)

        for _ in 0..<6 {
            tracker.record(
                toolName: ToolNames.writeFile,
                argumentsJSON: #"{"path":"a.swift","content":"x"}"#,
                resultJSON: #"{"ok":true}"#, isError: false)
        }
        await service.checkAndInjectLoopWarning(
            stepID: stepID, taskID: task.id, tracker: tracker,
            allowedToolNames: [], conversationMessages: &messages)

        XCTAssertEqual(messages.count, 2, "a new loop condition is new information")
        XCTAssertTrue(messages[1].content?.contains(ToolNames.writeFile) ?? false,
                      "got: \(messages[1].content ?? "nil")")
    }

    /// The bytes that went over the wire and the bytes recorded must be one string —
    /// a divergence would make the replayed conversation differ from what was sent.
    func testLoopWarning_wireAndPersistedTextAreIdentical() async {
        recordSixReadOnlyCalls()
        var messages: [ChatMessage] = []

        await service.checkAndInjectLoopWarning(
            stepID: stepID, taskID: task.id, tracker: tracker,
            allowedToolNames: [ToolNames.askSupervisor], conversationMessages: &messages)

        XCTAssertEqual(messages.first?.content, persistedUserTurns.first?.content)
    }

    /// The escalation clause is schema-gated: a role without `ask_supervisor` must not
    /// be steered toward a tool that can only answer `tool_not_authorized`.
    func testLoopWarning_withoutAskSupervisorInSchema_doesNotNameIt() async {
        recordSixReadOnlyCalls()
        var messages: [ChatMessage] = []

        await service.checkAndInjectLoopWarning(
            stepID: stepID, taskID: task.id, tracker: tracker,
            allowedToolNames: [ToolNames.readFile], conversationMessages: &messages)

        let text = messages.first?.content ?? ""
        XCTAssertTrue(text.contains("Loop detected"), "Sanity: the warning fired. Got: \(text)")
        XCTAssertFalse(text.contains(ToolNames.askSupervisor),
                       "Not in the role's schema → must not be suggested. Got: \(text)")
    }

    func testLoopWarning_belowSixCalls_persistsNothing() async {
        for _ in 0..<5 {
            tracker.record(
                toolName: ToolNames.readFile, argumentsJSON: #"{"path":"a.swift"}"#,
                resultJSON: #"{"ok":true}"#, isError: false)
        }
        var messages: [ChatMessage] = []

        await service.checkAndInjectLoopWarning(
            stepID: stepID, taskID: task.id, tracker: tracker,
            allowedToolNames: [ToolNames.askSupervisor], conversationMessages: &messages)

        XCTAssertTrue(messages.isEmpty)
        XCTAssertTrue(persistedUserTurns.isEmpty)
    }

    /// The write barrier again: a torn-down step still gets its caller's array mutated
    /// (that array belongs to the caller), but nothing is written behind it.
    func testLoopWarning_afterTeardown_persistsNothing() async {
        recordSixReadOnlyCalls()
        service.clearRunningTask(stepID: stepID, taskID: task.id)
        var messages: [ChatMessage] = []

        await service.checkAndInjectLoopWarning(
            stepID: stepID, taskID: task.id, tracker: tracker,
            allowedToolNames: [ToolNames.askSupervisor], conversationMessages: &messages)

        XCTAssertEqual(messages.count, 1, "The wire array is the caller's own")
        XCTAssertTrue(persistedUserTurns.isEmpty, "…but the barrier drops the persisted copy")
    }
}

// MARK: - Queued Supervisor message injection: where the gate actually lives

/// CLAUDE.md still describes the injection gate as "skipped on iteration 1 when
/// `session != nil`". Server-side sessions were removed in the statelessness work, and
/// `injectQueuedSupervisorMessage` no longer takes an iteration at all — the only gate
/// left is the CALL SITE's `isExecutionLive` check in `runOneLLMToolIteration`.
/// These pin what is actually true so a future reader doesn't hunt for a gate that is
/// no longer in the function.
@MainActor
final class QueuedSupervisorInjectionGateCoverageTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service = nil
        mockDelegate = nil
        try await super.tearDown()
    }

    /// The un-pinned guard arm: with no delegate there is nobody to pop the queue.
    func testInject_withoutDelegate_isNoOp() async {
        service.delegate = nil
        var conversation: [ChatMessage] = [ChatMessage(role: .assistant, content: "prior")]

        let delivered = await service.injectQueuedSupervisorMessage(
            stepID: "pm", taskID: 1, roleID: "pm", conversationMessages: &conversation)

        XCTAssertFalse(delivered, "No delegate means no delivery — and no information epoch")
        XCTAssertEqual(conversation.count, 1)
        XCTAssertTrue(mockDelegate.consumedQueuedMessages.isEmpty)
    }

    /// The function itself carries NO liveness check — that protection is the caller's.
    /// Characterizing it here is what makes the source pin below meaningful rather than
    /// decorative: if the gate were ever moved into the function, this test changes too.
    func testInject_functionItselfDoesNotConsultLiveness() async {
        mockDelegate.scriptedQueuedMessages = [(taskID: 1, roleID: "pm", content: "Supervisor: go")]
        service._testRegisterStepTask(stepID: "pm", taskID: 1)
        service.clearRunningTask(stepID: "pm", taskID: 1)  // torn down
        var conversation: [ChatMessage] = []

        let delivered = await service.injectQueuedSupervisorMessage(
            stepID: "pm", taskID: 1, roleID: "pm", conversationMessages: &conversation)

        XCTAssertTrue(delivered, "It reports the pop it performed, gate or no gate")
        XCTAssertEqual(conversation.count, 1,
                       "No liveness gate inside the function — the call site owns it")
        XCTAssertEqual(mockDelegate.consumedQueuedMessages.count, 1,
                       "A destructive pop happened, which is exactly why the call site must gate")
    }

    /// A message queued for a DIFFERENT task must never be delivered — otherwise a
    /// concurrent task's steering lands on the wrong role.
    func testInject_messageForAnotherTask_isNotConsumed() async {
        mockDelegate.scriptedQueuedMessages = [(taskID: 2, roleID: "pm", content: "other task")]
        var conversation: [ChatMessage] = []

        let delivered = await service.injectQueuedSupervisorMessage(
            stepID: "pm", taskID: 1, roleID: "pm", conversationMessages: &conversation)

        XCTAssertFalse(delivered, "Another task's message is not information for THIS role")
        XCTAssertTrue(conversation.isEmpty)
        XCTAssertEqual(mockDelegate.scriptedQueuedMessages.count, 1)
    }

    // MARK: - Source pin for the real gate

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
    }

    /// A build source, so it exists in every compiling checkout (including the public
    /// mirror, which ships no non-build files) — and it is also this pin's own marker.
    private static let scannedPath = "NanoTeams/Services/LLM/LLMExecutionService+ToolIteration.swift"

    func testRepoRootResolves() {
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent(Self.scannedPath).path),
            "A broken #filePath derivation would make the scan below pass vacuously")
    }

    /// The queued-message injection inside `runOneLLMToolIteration` must stay behind a
    /// liveness check. Without it a cancelled step destructively pops the Supervisor's
    /// queue and drops the message into a conversation nobody will ever send.
    func testInjectionCallSite_isGatedOnExecutionLiveness() throws {
        // Line comments are stripped so the scan can only be satisfied by CODE. The
        // window around this call site carries a long explanatory block; without the
        // strip, deleting the guard and leaving prose that merely NAMES it would keep
        // this pin green — a structural guard rotting into decoration.
        let raw = try String(
            contentsOf: repoRoot.appendingPathComponent(Self.scannedPath), encoding: .utf8)
        let source = raw
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
        guard let iterationStart = source.range(of: "func runOneLLMToolIteration") else {
            return XCTFail("runOneLLMToolIteration not found — did the file move?")
        }
        let needle = "injectQueuedSupervisorMessage" + "("
        guard let callSite = source.range(
            of: needle, range: iterationStart.upperBound..<source.endIndex)
        else {
            return XCTFail("The tool loop no longer injects queued Supervisor messages")
        }
        // Look back a bounded window so the pin survives reflowing but not removal.
        let lookbackStart = source.index(
            callSite.lowerBound, offsetBy: -400, limitedBy: iterationStart.upperBound)
            ?? iterationStart.upperBound
        let preceding = String(source[lookbackStart..<callSite.lowerBound])
        XCTAssertTrue(
            preceding.contains("isExecutionLive"),
            "The injection call site must be gated on isExecutionLive — the function itself "
            + "does not check (see testInject_functionItselfDoesNotConsultLiveness). Window: \(preceding)")
    }
}

// MARK: - StepFlowControl: the escalation caps' FAILURE arms

/// Every escalation cap in `+StepFlowControl` ends in
/// `guard escalated else { return .toolFailure(...) }`. That arm exists because a
/// silent transition to "needs Supervisor input" with no question rendered is strictly
/// worse than the loop the cap replaced — and none of the four were exercised.
///
/// `mockDelegate.taskToMutate = nil` is the lever: `mutateTask` then returns `false`,
/// so `setNeedsSupervisorInput` reports a failed persist while `executionStates` (and
/// therefore every counter) stays live.
@MainActor
final class StepFlowControlCapFailureCoverageTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private let stepID = "swe"

    /// A `<|call|>` block whose JSON never balances → `.malformedJSON`.
    private static let brokenCallEnvelope =
        ##"<|call|>{"name":"write_file","arguments":{"path":"x""##

    private static let refusal =
        "I'm sorry, but I don't have the ability to create files in this environment."

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)

        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "W", status: .running)
        task = NTMSTask(id: 0, title: "T", supervisorTask: "goal", runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() async throws {
        service = nil
        mockDelegate = nil
        task = nil
        try await super.tearDown()
    }

    /// Detaches persistence while leaving the step's execution state live.
    private func breakPersistence() { mockDelegate.taskToMutate = nil }

    private func refusalConversation() -> [ChatMessage] {
        [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .assistant, content: Self.refusal),
            ChatMessage(role: .user, content: "try again"),
            ChatMessage(role: .assistant, content: Self.refusal),
            ChatMessage(role: .user, content: "try again"),
            ChatMessage(role: .assistant, content: Self.refusal),
        ]
    }

    // MARK: - Refusal loop (the whole branch was unexercised through handleNoToolCalls)

    func testRefusalLoop_escalatesWithExcerpt_andPersistsTheQuestion() async {
        var messages = refusalConversation()

        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: Self.refusal, sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: nil,
            conversationMessages: &messages)

        guard case .needsSupervisorInput(let question) = stop else {
            return XCTFail("Three refusals must escalate, got \(stop)")
        }
        XCTAssertTrue(question.contains("consecutive refusal messages"),
                      "The question must name the observed pattern, got: \(question)")
        XCTAssertTrue(question.contains("Last message excerpt:"),
                      "…and carry the excerpt the human needs, got: \(question)")
        XCTAssertTrue(question.contains("I'm sorry"), "…which is the model's own text")

        let step = mockDelegate.taskToMutate?.runs.last?.steps.first
        XCTAssertEqual(step?.status, .needsSupervisorInput)
        XCTAssertEqual(step?.needsSupervisorInput, true)
        XCTAssertEqual(step?.supervisorQuestion,
                       question.trimmingCharacters(in: .whitespacesAndNewlines),
                       "The rendered question is the persisted one")
        XCTAssertTrue(mockDelegate.notifyQueuedMessageBackstopCalls.contains(task.id),
                      "A successful park fires the queued-message backstop")
    }

    func testRefusalLoop_persistFails_returnsToolFailure() async {
        breakPersistence()
        var messages = refusalConversation()

        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: Self.refusal, sawHarmonyMarker: false,
            task: task, roleDefinition: nil, conversationMessages: &messages)

        guard case .toolFailure(let message) = stop else {
            return XCTFail("A failed persist must fail the step, not park it silently. Got \(stop)")
        }
        XCTAssertTrue(message.contains("Refusal-loop cap exceeded"), message)
        XCTAssertTrue(message.contains("failed to persist"), message)
    }

    /// Loop detection is skipped during revision — the Supervisor is already driving,
    /// so escalating again would recurse.
    func testRefusalLoop_duringRevision_fallsThroughToTheGenericNudge() async {
        mockDelegate.taskToMutate?.runs[0].steps[0].revisionComment = "Please redo X"
        var messages = refusalConversation()

        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: Self.refusal, sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: nil,
            conversationMessages: &messages)

        guard case .continueLoop = stop else {
            return XCTFail("Revision must suppress the refusal escalation, got \(stop)")
        }
        XCTAssertTrue((messages.last?.content ?? "").contains("did not call any tools"),
                      "Expected the generic nudge, got: \(messages.last?.content ?? "nil")")
        XCTAssertEqual(mockDelegate.taskToMutate?.runs[0].steps[0].status, .running,
                       "The step must not be parked during revision")
    }

    // MARK: - Drift cap

    func testDriftCap_persistFails_returnsToolFailure_andResetsTheCounter() async {
        breakPersistence()
        let huge = String(repeating: "a", count: 20_000)

        var first: [ChatMessage] = []
        let firstStop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: task, roleDefinition: nil, conversationMessages: &first,
            thinkingContent: huge)
        guard case .continueLoop = firstStop else {
            return XCTFail("First drift nudges, got \(firstStop)")
        }
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 1)

        var second: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: task, roleDefinition: nil, conversationMessages: &second,
            thinkingContent: huge)

        guard case .toolFailure(let message) = stop else {
            return XCTFail("A failed drift escalation must fail the step, got \(stop)")
        }
        XCTAssertTrue(message.contains("Drift cap exceeded"), message)
        XCTAssertTrue(message.contains("Question would have been:"),
                      "The lost question must survive into the failure message: \(message)")
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 0,
                       "The counter is reset before the escalation is attempted")
    }

    // MARK: - Harmony parse-failure cap

    func testParseFailureCap_persistFails_returnsToolFailure() async {
        breakPersistence()

        for i in 1...2 {
            var messages: [ChatMessage] = []
            let stop = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "\n\n", sawHarmonyMarker: true,
                task: task, roleDefinition: nil, conversationMessages: &messages,
                harmonyBuffer: Self.brokenCallEnvelope)
            guard case .continueLoop = stop else {
                return XCTFail("Attempt \(i) must nudge, got \(stop)")
            }
            XCTAssertEqual(
                service._testHarmonyParseFailureCounter(stepID: stepID, taskID: task.id), i)
        }

        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "\n\n", sawHarmonyMarker: true,
            task: task, roleDefinition: nil, conversationMessages: &messages,
            harmonyBuffer: Self.brokenCallEnvelope)

        guard case .toolFailure(let message) = stop else {
            return XCTFail("A failed parse-cap escalation must fail the step, got \(stop)")
        }
        XCTAssertTrue(message.contains("Parse-failure cap exceeded"), message)
        XCTAssertEqual(
            service._testHarmonyParseFailureCounter(stepID: stepID, taskID: task.id), 0,
            "The counter is reset before the escalation is attempted")
    }

    // MARK: - Non-productive-turn cap

    /// Note the deliberate asymmetry with the drift cap: this arm returns BEFORE the
    /// reset, so the counter stays at the cap and the next iteration re-attempts.
    func testNonProductiveCap_persistFails_returnsToolFailure_andKeepsTheCounter() async {
        breakPersistence()

        for i in 1..<LLMConstants.maxNonProductiveTurns {
            var messages: [ChatMessage] = []
            let stop = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "Turn \(i).", sawHarmonyMarker: false,
                task: task, roleDefinition: nil, conversationMessages: &messages)
            guard case .continueLoop = stop else {
                return XCTFail("Turn \(i) must nudge below the cap, got \(stop)")
            }
        }

        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "Final turn.", sawHarmonyMarker: false,
            task: task, roleDefinition: nil, conversationMessages: &messages)

        guard case .toolFailure(let message) = stop else {
            return XCTFail("A failed non-productive escalation must fail the step, got \(stop)")
        }
        XCTAssertTrue(message.contains("Non-productive-turn cap exceeded"), message)
        XCTAssertEqual(
            service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id),
            LLMConstants.maxNonProductiveTurns,
            "This arm returns before the reset — the breach must stay visible to the next iteration")
    }

    /// Without a delegate the bypass cannot land at all, so `noteNonProductiveTurn`
    /// returns nil rather than announcing a completion that never happened — and it
    /// leaves the counter incremented so the next iteration still sees the breach.
    func testNonProductiveCap_withoutDelegate_returnsNilAndKeepsCounting() async {
        service.delegate = nil

        for _ in 1...LLMConstants.maxNonProductiveTurns {
            var messages: [ChatMessage] = []
            _ = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "Ping.", sawHarmonyMarker: false,
                task: task, roleDefinition: nil, conversationMessages: &messages)
        }
        XCTAssertEqual(
            service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id),
            LLMConstants.maxNonProductiveTurns)

        var messages: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "Ping.", sawHarmonyMarker: false,
            task: task, roleDefinition: nil, conversationMessages: &messages)

        guard case .continueLoop = stop else {
            return XCTFail("Without a delegate the cap must not manufacture a terminal, got \(stop)")
        }
        XCTAssertEqual(
            service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id),
            LLMConstants.maxNonProductiveTurns + 1,
            "The counter keeps climbing so the breach is not silently buried")
    }

    // MARK: - isStepInRevision guard chain

    func testIsStepInRevision_withoutDelegate_isFalse() async {
        service.delegate = nil
        XCTAssertFalse(service.isStepInRevision(stepID: stepID, taskID: task.id))
    }

    func testIsStepInRevision_unknownTask_isFalse() async {
        XCTAssertFalse(service.isStepInRevision(stepID: stepID, taskID: 4242))
    }

    func testIsStepInRevision_taskWithNoRuns_isFalse() async {
        mockDelegate.taskToMutate = NTMSTask(id: 0, title: "T", supervisorTask: "g", runs: [])
        XCTAssertFalse(service.isStepInRevision(stepID: stepID, taskID: 0))
    }

    func testIsStepInRevision_unknownStepID_isFalse() async {
        mockDelegate.taskToMutate?.runs[0].steps[0].revisionComment = "redo"
        XCTAssertFalse(service.isStepInRevision(stepID: "not_a_step", taskID: task.id),
                       "Revision is per-step; a miss must not inherit a sibling's flag")
    }

    func testIsStepInRevision_readsTheLatestRunOnly() async {
        // Revision recorded on an OLD run must not gate the live one.
        var older = Run(id: 0, steps: [
            StepExecution(id: stepID, role: .softwareEngineer, title: "W", status: .done)
        ])
        older.steps[0].revisionComment = "old feedback"
        let newer = Run(id: 1, steps: [
            StepExecution(id: stepID, role: .softwareEngineer, title: "W", status: .running)
        ])
        mockDelegate.taskToMutate = NTMSTask(
            id: 0, title: "T", supervisorTask: "g", runs: [older, newer])

        XCTAssertFalse(service.isStepInRevision(stepID: stepID, taskID: 0),
                       "Only the latest run's step decides")
    }

    // MARK: - finishStepGraceful (non-chat branch + barrier)

    func testFinishStepGraceful_nonChatTeam_completesAsNeedsApproval() async {
        let role = makeAdvisoryRoleFixtureForLoopStateSuite(id: stepID)
        let team = makeNonChatTeamFixtureForLoopStateSuite(worker: role)
        XCTAssertFalse(team.isChatMode, "Sanity: a Supervisor-required artifact makes it non-chat")
        mockDelegate.taskToMutate?.adoptGeneratedTeam(team)

        await service.finishStepGraceful(stepID: stepID, taskID: task.id)

        XCTAssertEqual(
            mockDelegate.taskToMutate?.runs.last?.steps.first?.status, .needsApproval,
            "A non-chat team must route through the acceptance flow, never a direct .done")
        XCTAssertNotEqual(
            mockDelegate.taskToMutate?.runs.last?.roleStatuses[role.id], .done,
            "The bypass is chat-mode only — the engine's acceptance plumbing owns this role")
    }

    func testFinishStepGraceful_afterTeardown_doesNotMutateTheStep() async {
        service.clearRunningTask(stepID: stepID, taskID: task.id)

        await service.finishStepGraceful(stepID: stepID, taskID: task.id)

        XCTAssertEqual(mockDelegate.taskToMutate?.runs.last?.steps.first?.status, .running,
                       "The write barrier must drop a completion aimed at a torn-down step")
    }

    func testMarkChatModeAdvisoryStepDone_afterTeardown_returnsFalse() async {
        service.clearRunningTask(stepID: stepID, taskID: task.id)
        let applied = await service.markChatModeAdvisoryStepDone(stepID: stepID, taskID: task.id)
        XCTAssertFalse(applied)
        XCTAssertEqual(mockDelegate.taskToMutate?.runs.last?.steps.first?.status, .running)
    }

    func testMarkChatModeAdvisoryStepDone_missingStep_returnsFalse() async {
        mockDelegate.taskToMutate?.runs[0].steps = []
        let applied = await service.markChatModeAdvisoryStepDone(stepID: stepID, taskID: task.id)
        XCTAssertFalse(
            applied,
            "CLAUDE.md §7: mutateTask==true only proves persistence — the captured flag must "
            + "catch a closure that short-circuited")
    }
}

// MARK: - startStepExecution: the guard + teardown arms

/// `+StepLifecycle.startStepExecution`. Its guards all run AFTER the execution-state
/// entry is replaced, and the replacement is preceded by a cancel of whatever was
/// still registered — the pre-fix order replaced first and then cancelled, which
/// targeted the FRESH state's nil `runningTask` and leaked the previous execution.
@MainActor
final class StepLifecycleStartGuardCoverageTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var tempDir: URL!
    private let stepID = "swe"

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(
            repository: NTMSRepository(),
            clientFactory: { SilentStreamClient() })
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        service = nil
        mockDelegate = nil
        try await super.tearDown()
    }

    private func makeTask(status: StepStatus, wireTranscript: [ChatMessage] = [],
                          llmConversation: [LLMMessage] = []) -> NTMSTask {
        var step = StepExecution(id: stepID, role: .softwareEngineer, title: "W", status: status)
        step.wireTranscript = wireTranscript
        step.llmConversation = llmConversation
        let run = Run(id: 0, steps: [step])
        return NTMSTask(id: 0, title: "T", supervisorTask: "goal", runs: [run])
    }

    private func hasState(_ taskID: Int) -> Bool {
        service._testHasExecutionState(stepID: stepID, taskID: taskID)
    }

    // MARK: - Guard arms

    func testStart_withoutDelegate_replacesStateButStartsNothing() async {
        let task = makeTask(status: .running)
        service.delegate = nil

        service.startStepExecution(
            stepID: stepID, taskID: task.id, task: task, runIndex: 0, stepIndex: 0)

        XCTAssertTrue(hasState(task.id),
                      "The state entry is replaced BEFORE the guards — that is what makes the "
                      + "cancel-then-replace ordering observable")
        XCTAssertFalse(service.isStepRunning(stepID: stepID, taskID: task.id))
    }

    func testStart_withoutWorkFolder_replacesStateButStartsNothing() async {
        let task = makeTask(status: .running)
        mockDelegate.workFolderURL = nil

        service.startStepExecution(
            stepID: stepID, taskID: task.id, task: task, runIndex: 0, stepIndex: 0)

        XCTAssertTrue(hasState(task.id))
        XCTAssertFalse(service.isStepRunning(stepID: stepID, taskID: task.id))
    }

    func testStart_stepNotRunning_replacesStateButStartsNothing() async {
        let task = makeTask(status: .done)

        service.startStepExecution(
            stepID: stepID, taskID: task.id, task: task, runIndex: 0, stepIndex: 0)

        XCTAssertTrue(hasState(task.id))
        XCTAssertFalse(service.isStepRunning(stepID: stepID, taskID: task.id))
        XCTAssertNil(
            service.executionStates[TaskStepKey(taskID: task.id, stepID: stepID)]?.replaySource,
            "A step that never started records no replay source")
    }

    /// The documented regression: a same-key re-entry must cancel the still-registered
    /// execution BEFORE the entry is replaced, or the previous one leaks and keeps
    /// streaming into a step nobody is watching.
    func testStart_cancelsAStillRegisteredExecutionBeforeReplacingTheEntry() async {
        let task = makeTask(status: .done)  // guard fails → no NEW task is spawned
        let latch = CancellationLatch()
        let handle = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            latch.set()
        }
        service._testInjectRunningTask(stepID: stepID, taskID: task.id, runningTask: handle)
        XCTAssertTrue(service.isStepRunning(stepID: stepID, taskID: task.id), "Sanity: injected")

        service.startStepExecution(
            stepID: stepID, taskID: task.id, task: task, runIndex: 0, stepIndex: 0)

        // Bounded, so a regression fails the assertion instead of hanging the suite.
        let finished = await LLMExecutionService.awaitTaskWithTimeout(handle, seconds: 3)
        handle.cancel()
        XCTAssertTrue(finished, "The prior execution must have been cancelled by the re-entry")
        XCTAssertTrue(latch.isSet)
        XCTAssertFalse(service.isStepRunning(stepID: stepID, taskID: task.id),
                       "…and the replacement entry starts with no running task")
    }

    /// The replacement is a whole fresh `StepExecutionState`, so every retry counter the
    /// previous execution accumulated is cleared. A carried-over counter would let a new
    /// run escalate on its very first drift turn.
    func testStart_replacementClearsPriorCounters() async {
        let task = makeTask(status: .done)
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
        service._testSetThinkingLoopBreakCount(stepID: stepID, taskID: task.id, count: 2)
        XCTAssertEqual(service._testThinkingLoopBreakCount(stepID: stepID, taskID: task.id), 2)

        service.startStepExecution(
            stepID: stepID, taskID: task.id, task: task, runIndex: 0, stepIndex: 0)

        XCTAssertEqual(service._testThinkingLoopBreakCount(stepID: stepID, taskID: task.id), 0)
        XCTAssertEqual(service._testDriftCounter(stepID: stepID, taskID: task.id), 0)
        XCTAssertEqual(service._testNonProductiveTurnCounter(stepID: stepID, taskID: task.id), 0)
    }

    // MARK: - Replay-source recording (synchronous, before the loop spawns)

    /// A fresh step records NO replay source. That `nil` is what
    /// `forgetPrefixChainForFreshConversation` keys on, and what makes exemption 5 in
    /// `reportPrefixCacheMissIfAny` reachable at all.
    func testStart_freshStep_recordsNoReplaySource_andRegistersARunningTask() async {
        let task = makeTask(status: .running)
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: task.id, task: task, runIndex: 0, stepIndex: 0)

        XCTAssertTrue(service.isStepRunning(stepID: stepID, taskID: task.id),
                      "The happy path must register a running task")
        XCTAssertNil(
            service.executionStates[TaskStepKey(taskID: task.id, stepID: stepID)]?.replaySource,
            "A genuinely fresh conversation has no replay source")

        service.cancelAllExecutions()  // synchronous teardown; the barrier drops late writes
    }

    /// A step carrying a wire transcript replays it byte-faithfully — the prefix-cache
    /// hit case, which must be distinguishable from the lossy rebuild below.
    func testStart_withWireTranscript_recordsWireTranscriptSource() async {
        let task = makeTask(
            status: .running,
            wireTranscript: [
                ChatMessage(role: .system, content: "sys"),
                ChatMessage(role: .user, content: "task"),
            ])
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: task.id, task: task, runIndex: 0, stepIndex: 0)

        XCTAssertEqual(
            service.executionStates[TaskStepKey(taskID: task.id, stepID: stepID)]?.replaySource,
            .wireTranscript)

        service.cancelAllExecutions()
    }

    /// Only a display record survives (a step persisted before `wireTranscript` existed):
    /// the rebuild is a documented guaranteed prefix-cache miss, and recording WHERE the
    /// conversation came from is the only thing that lets the detector report it.
    func testStart_withOnlyDisplayRecord_recordsLegacyConversationSource() async {
        let task = makeTask(
            status: .running,
            llmConversation: [
                LLMMessage(role: .user, content: "do the thing"),
                LLMMessage(role: .assistant, content: "on it"),
            ])
        mockDelegate.taskToMutate = task

        service.startStepExecution(
            stepID: stepID, taskID: task.id, task: task, runIndex: 0, stepIndex: 0)

        XCTAssertEqual(
            service.executionStates[TaskStepKey(taskID: task.id, stepID: stepID)]?.replaySource,
            .legacyConversation)

        service.cancelAllExecutions()
    }
}
