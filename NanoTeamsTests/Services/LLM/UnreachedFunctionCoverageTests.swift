import XCTest

@testable import NanoTeams

// MARK: - File-scope fixtures
//
// Every file-scope declaration is `private`: this module is written into by many
// suites at once and a bare `ScriptedClient` / `stepID` would collide.

private let ufcStepID = "ufc_iteration_step"
private let ufcTaskID = 77

private func ufcConfig() -> LLMConfig {
    LLMConfig(
        provider: .lmStudio,
        baseURLString: "http://localhost",
        modelName: "stub",
        temperature: nil
    )
}

/// Replays one `StreamEvent` script PER CALL, so a single iteration that issues a
/// second request (the Supervisor auto-answer) can be scripted independently of
/// the first. Records `roleName` because the iteration's
/// `displayName.isEmpty ? nil : displayName` ternary is only observable there.
///
/// The last script is reused once the list is exhausted — a caller that only
/// cares about the first request need not enumerate the rest.
private final class UFCScriptedStreamClient: LLMClient, @unchecked Sendable {
    private let scripts: [[StreamEvent]]
    private(set) var sentMessages: [[ChatMessage]] = []
    private(set) var roleNames: [String?] = []

    init(_ scripts: [[StreamEvent]]) { self.scripts = scripts }

    func streamChat(
        config _: LLMConfig,
        messages: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let index = min(sentMessages.count, scripts.count - 1)
        sentMessages.append(messages)
        roleNames.append(roleName)
        let scripted = scripts.isEmpty ? [] : scripts[index]
        return AsyncThrowingStream { continuation in
            for event in scripted { continuation.yield(event) }
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

private func ufcToolCallEvent(index: Int, id: String, name: String, args: String) -> StreamEvent {
    StreamEvent(toolCallDeltas: [
        StreamEvent.ToolCallDelta(index: index, id: id, name: name, argumentsDelta: args)
    ])
}

private func ufcEnvelope(_ json: String) throws -> [String: Any] {
    let any = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [])
    return try XCTUnwrap(any as? [String: Any], "not a JSON object: \(json)")
}

/// `error.message` out of a tool-result envelope, or nil when the envelope
/// carries no error object.
private func ufcErrorMessage(_ json: String) -> String? {
    guard let any = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: []),
          let dict = any as? [String: Any],
          let error = dict["error"] as? [String: Any]
    else { return nil }
    return error["message"] as? String
}

// =============================================================================
// MARK: - runOneLLMToolIteration: the guard arms nothing reaches today
// =============================================================================

/// `LLMToolIterationOrchestrationTests` (in `DelegateToTeamAndIterationTests.swift`)
/// drives the iteration's happy paths. Every arm below is an EARLY RETURN or a
/// merge branch that only fires under a condition that suite never builds: an
/// in-stream reasoning loop, the shape-independent non-productive ceiling, a
/// permission gate that synthesizes a result, and the autonomous Supervisor
/// auto-answer. Each one is a place where the iteration decides to stop doing
/// work, so an unpinned regression there is silent: the loop keeps running and
/// the user sees only "it never finishes".
@MainActor
final class IterationTerminalArmsCoverageTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!
    private var tempDir: URL!
    private var emptyRuntime: ToolRuntime!
    private var tracker: ToolCallTracker!
    private var memoryStore: MemoryTagStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt-ufc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        delegate.workFolderURL = tempDir
        service.attach(delegate: delegate)

        // Empty on purpose: an unregistered tool yields an ERROR result, which is
        // exactly the input the non-productive accounting needs.
        emptyRuntime = ToolRuntime(registry: ToolRegistry(), logger: nil)
        tracker = ToolCallTracker()
        memoryStore = MemoryTagStore(workFolderRoot: tempDir)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        memoryStore = nil
        tracker = nil
        emptyRuntime = nil
        service = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: Fixtures

    @discardableResult
    private func seedTask() -> NTMSTask {
        let step = StepExecution(
            id: ufcStepID, role: .softwareEngineer, title: "Engineer", status: .running)
        var task = NTMSTask(id: ufcTaskID, title: "T", supervisorTask: "build")
        task.runs = [Run(id: 0, steps: [step])]
        delegate.taskToMutate = task
        service._testRegisterStepTask(stepID: ufcStepID, taskID: ufcTaskID)
        return task
    }

    private func runIteration(
        task: NTMSTask,
        client: any LLMClient,
        tools: [ToolSchema],
        runtime: ToolRuntime? = nil,
        supervisorMode: SupervisorMode = .manual,
        roleForMessage: Role = .softwareEngineer,
        conversation: inout [ChatMessage],
        observer: (([StepToolCall], [ToolExecutionResult]) -> Void)? = nil
    ) async throws -> LLMStepStop {
        var usage = TokenUsage()
        let effectiveRuntime: ToolRuntime = runtime ?? emptyRuntime
        return try await service.runOneLLMToolIteration(
            stepID: ufcStepID,
            roleForMessage: roleForMessage,
            client: client,
            config: ufcConfig(),
            tools: tools,
            runtime: effectiveRuntime,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            supervisorMode: supervisorMode,
            conversationMessages: &conversation,
            tracker: tracker,
            memoryStore: memoryStore,
            cumulativeUsage: &usage,
            toolObserver: observer
        )
    }

    /// Walks `consecutiveNonProductiveTurns` up to one BELOW the ceiling through
    /// the production incrementer (`handleNoToolCalls` bumps it at its very first
    /// line), so the iteration under test supplies the turn that trips it.
    ///
    /// A fresh empty conversation per call keeps `detectMessageLoop` from firing
    /// on the accumulated nudges — that branch escalates too, and the test must
    /// be able to attribute the terminal to the ceiling and nothing else.
    private func primeNonProductiveTurnsToOneBelowCeiling(task: NTMSTask) async {
        for i in 1..<LLMConstants.maxNonProductiveTurns {
            var throwaway: [ChatMessage] = []
            _ = await service._testHandleNoToolCalls(
                stepID: ufcStepID,
                assistantContent: "prose turn \(i)",
                sawHarmonyMarker: false,
                task: task,
                roleDefinition: nil,
                conversationMessages: &throwaway
            )
        }
        XCTAssertEqual(
            service._testNonProductiveTurnCounter(stepID: ufcStepID, taskID: ufcTaskID),
            LLMConstants.maxNonProductiveTurns - 1,
            "Precondition: the ceiling must be one turn away before the iteration runs")
    }

    // MARK: - 2c. In-stream thinking-loop break

    /// The stream was aborted mid-generation because the model's reasoning buffer
    /// started repeating, and the looping generation was DISCARDED — it is in
    /// neither `conversationMessages` nor `step.messages`. So the iteration must
    /// hand off to `handleStreamLoopBreak` and return BEFORE
    /// `processStreamingResult`, which would otherwise append an assistant turn
    /// for content that was deliberately thrown away, and before
    /// `resetThinkingLoopBreakCount`, which would erase the very episode that
    /// just happened.
    ///
    /// RED: delete the `if let loopSignal = streamResult.thinkingLoopSignal`
    /// early return → the break count stays 0 (the line below resets it) and no
    /// correction turn is appended, so the next request is byte-identical to the
    /// one that just looped and the model re-enters the same loop.
    func testThinkingLoopSignal_recoversAndReturnsBeforeTheCounterReset() async throws {
        let task = seedTask()

        // One delta past `streamLoopScanCadenceChars` whose tail is a live
        // periodic repeat — the shape `LoopScanner.scanStreaming(.thinkingOnly)`
        // fires on (10 substantive chars × 60 reps, well past both thresholds).
        let looping = String(repeating: "Oh, wait! ", count: 60)
        XCTAssertGreaterThan(looping.count, LLMConstants.streamLoopScanCadenceChars,
                             "test premise: the buffer must clear the scan cadence")
        let client = UFCScriptedStreamClient([[StreamEvent(thinkingDelta: looping)]])

        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        let stop = try await runIteration(
            task: task, client: client, tools: [], conversation: &conversation)

        guard case .continueLoop = stop else {
            return XCTFail("The first break inside the budget retries, got \(stop)")
        }
        XCTAssertEqual(
            service._testThinkingLoopBreakCount(stepID: ufcStepID, taskID: ufcTaskID), 1,
            "The break must be counted — the reset below the guard would zero it")
        XCTAssertFalse(delegate.discardStreamingCalls.isEmpty,
                       "The looping generation must be discarded, not committed as a turn")
        XCTAssertTrue(
            (conversation.last?.content ?? "").contains(LoopRecoveryPolicy.nudgePrefix),
            "Recovery must PERTURB the conversation or the resend is byte-identical")
    }

    // MARK: - 5. ask_supervisor-only turn at the ceiling

    /// `ask_supervisor` is auto-answered under autonomous mode, so a turn whose
    /// only call is that one advanced nothing. Once such turns reach
    /// `maxNonProductiveTurns` the iteration must stop BEFORE executing anything:
    /// running the call would produce another question for a Supervisor who is
    /// already being escalated to.
    ///
    /// RED: drop the `if let stop = await noteNonProductiveTurn(...) { return stop }`
    /// arm in the `isAskSupervisorOnly` branch → the iteration proceeds to
    /// `executeToolCalls` (the observer fires) and returns `.continueLoop`, so a
    /// model that only ever asks questions loops forever (`maxToolIterations` is
    /// unlimited by default).
    func testAskSupervisorOnlyTurn_atTheCeiling_stopsBeforeExecutingAnything() async throws {
        let task = seedTask()
        await primeNonProductiveTurnsToOneBelowCeiling(task: task)

        let tools = [
            ToolSchema(name: ToolNames.askSupervisor, description: "Ask",
                       parameters: .object(properties: [:]))
        ]
        let client = UFCScriptedStreamClient([[
            ufcToolCallEvent(index: 0, id: "c1", name: ToolNames.askSupervisor,
                             args: "{\"question\":\"which option?\"}")
        ]])

        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        var observed: [[StepToolCall]] = []
        let stop = try await runIteration(
            task: task, client: client, tools: tools, conversation: &conversation,
            observer: { calls, _ in observed.append(calls) })

        guard case .needsSupervisorInput(let question) = stop else {
            return XCTFail("The ceiling escalates when no role definition resolves, got \(stop)")
        }
        // The EXACT string, not `contains("20")`: a substring test also passes for 120 or 205,
        // so it cannot tell the real count from an arithmetic slip in the builder.
        XCTAssertEqual(
            question,
            LLMExecutionService.nonProductiveEscalationQuestion(
                roleName: ufcStepID, turns: LLMConstants.maxNonProductiveTurns),
            """
            The escalation must be the builder's own text. `roleName` falls back to the \
            stepID (`roleDefinition?.name ?? stepID`) precisely because no role definition \
            resolves here, which is the condition this arm exists for.
            """)
        XCTAssertTrue(
            observed.isEmpty,
            "The terminal sits ABOVE executeToolCalls — the observer firing means the arm was skipped")
    }

    // MARK: - 6a. Post-results non-productive turn at the ceiling

    /// The other half of the ceiling, and the one that needs the tool RESULTS:
    /// a batch whose every result is an error advanced nothing either, but that
    /// is only knowable after execution. So this terminal is taken after
    /// `processToolResults`, which is what leaves a well-formed conversation
    /// (every assistant tool call has its `.tool` reply) for the next replay.
    ///
    /// RED: drop the `case .nonProductive: if let stop = ... { return stop }`
    /// arm → a model emitting a tool call that always fails (a hallucinated tool
    /// name, a denied command) re-arms nothing and runs unbounded.
    func testAllErrorToolBatch_atTheCeiling_stopsAfterResultsAreProcessed() async throws {
        let task = seedTask()
        await primeNonProductiveTurnsToOneBelowCeiling(task: task)

        let tools = [
            ToolSchema(name: ToolNames.readFile, description: "Read",
                       parameters: .object(properties: [:]))
        ]
        let client = UFCScriptedStreamClient([[
            ufcToolCallEvent(index: 0, id: "c1", name: ToolNames.readFile,
                             args: "{\"path\":\"a.txt\"}")
        ]])

        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        var observed: [[ToolExecutionResult]] = []
        let stop = try await runIteration(
            task: task, client: client, tools: tools, conversation: &conversation,
            observer: { _, results in observed.append(results) })

        guard case .needsSupervisorInput = stop else {
            return XCTFail("An all-error batch at the ceiling must escalate, got \(stop)")
        }
        XCTAssertFalse(
            observed.isEmpty,
            "This terminal is BELOW execution — unlike the ask_supervisor arm, the batch must have run")
        XCTAssertEqual(observed.first?.allSatisfy(\.isError), true,
                       "Test premise: the empty registry must make every result an error")
    }

    // MARK: - 5a/5b. Gate synthetics merged back into emit order

    /// A permission gate answers some calls itself and lets the rest through, so
    /// the merge has to re-interleave two lists into the model's original emit
    /// order. `processToolResults` pairs them by INDEX (`zip(resolvedToolCalls,
    /// results)`), so a misaligned merge attributes the denial to the wrong call
    /// — the model is told the file read was blocked by a deny rule and the
    /// shell command failed to parse.
    ///
    /// Driven with a MIXED batch, and with the EXECUTED call first, which is the
    /// only ordering that can see the failure. With the gated call at index 0 a
    /// naive `Array(gateResults.values) + executedResults` yields
    /// `[bash, read_file]` — byte-identical to the correct answer — so every
    /// assertion passes and the test is blind to the bug it names. Emitting
    /// `read_file` at 0 and `bash` at 1 makes the naive merge produce
    /// `[bash, read_file]` while the index-aligned merge produces
    /// `[read_file, bash]`, and `toolName` separates them.
    ///
    /// `providerID` is asserted too: `processToolResults` pairs by
    /// `zip(resolvedToolCalls, results)`, so the id is what a misaligned merge
    /// actually corrupts on the wire — the model gets a `tool_call_id` answering
    /// a call it never made.
    ///
    /// RED: delete the `if let synth = gateResults[idx]` arm → `toolResults.count`
    /// is 1 and the count assertion fails. (An earlier draft of this comment named
    /// "swap the two branches" as the mutation; that is not well-formed — the
    /// else-if arm is then left with nothing to append at index 1.)
    func testDeniedBashCall_isMergedBackAtItsOwnIndex() async throws {
        let task = seedTask()
        delegate.bashPolicy = BashPolicy(denyRules: ["rm"])

        let tools = [
            ToolSchema(name: ToolNames.bash, description: "Shell",
                       parameters: .object(properties: [:])),
            ToolSchema(name: ToolNames.readFile, description: "Read",
                       parameters: .object(properties: [:])),
        ]
        let client = UFCScriptedStreamClient([[
            ufcToolCallEvent(index: 0, id: "c1", name: ToolNames.readFile,
                             args: "{\"path\":\"a.txt\"}"),
            ufcToolCallEvent(index: 1, id: "c2", name: ToolNames.bash,
                             args: "{\"command\":\"rm -rf build\"}"),
        ]])

        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        var observedCalls: [StepToolCall] = []
        var observedResults: [ToolExecutionResult] = []
        _ = try await runIteration(
            task: task, client: client, tools: tools, conversation: &conversation,
            observer: { calls, results in
                observedCalls = calls
                observedResults = results
            })

        XCTAssertEqual(observedCalls.map(\.name), [ToolNames.readFile, ToolNames.bash],
                       "test premise: both calls must survive to the observer in emit order")
        XCTAssertEqual(observedResults.count, 2,
                       "The merge must yield one result per emitted call, or `zip` misaligns")
        XCTAssertEqual(observedResults.map(\.toolName), [ToolNames.readFile, ToolNames.bash],
                       "Each result must sit at the index of the call it answers. A merge that "
                           + "appends the synthetics instead yields [bash, read_file] here.")
        XCTAssertEqual(observedCalls.map(\.providerID), ["c1", "c2"],
                       "processToolResults pairs by zip(resolvedToolCalls, results), so a "
                           + "misaligned merge hands the model a tool_call_id for a call it "
                           + "never made")
        XCTAssertFalse(observedResults[0].outputJSON.contains("deny rule"),
                       "Index 0 was never gated — it must carry the runtime's own error: "
                           + observedResults[0].outputJSON)
        XCTAssertEqual(ufcErrorMessage(observedResults[1].outputJSON)?.contains("deny rule"), true,
                       "Index 1 is the gated bash call: " + observedResults[1].outputJSON)
    }

    // MARK: - 6b. Autonomous Supervisor auto-answer

    /// In autonomous mode nobody is watching, so an `ask_supervisor` question is
    /// answered by the model itself and the loop CONTINUES. Returning here is
    /// what keeps the iteration from falling through to
    /// `outcome.shouldStopForSupervisor` two lines below, which parks the step
    /// for a human who will never arrive.
    ///
    /// RED: drop the `if let autoAnswerStop = await handleSupervisorAutoAnswer(...)`
    /// return → the next statement fires and the stop becomes
    /// `.needsSupervisorInput`, wedging every autonomous team on its first question.
    func testAutonomousSupervisorQuestion_isAutoAnsweredAndTheLoopContinues() async throws {
        let task = seedTask()

        // A real handler, so the call actually emits `.supervisorQuestion`.
        let registry = ToolRegistry()
        registry.register(name: ToolNames.askSupervisor) { context, args in
            AskSupervisorTool().handle(context: context, args: args)
        }
        let runtime = ToolRuntime(registry: registry, logger: nil)

        let tools = [
            ToolSchema(name: ToolNames.askSupervisor, description: "Ask",
                       parameters: .object(properties: [:]))
        ]
        // Request 1 = the step's turn; request 2 = the auto-answer generation.
        let client = UFCScriptedStreamClient([
            [ufcToolCallEvent(index: 0, id: "c1", name: ToolNames.askSupervisor,
                              args: "{\"question\":\"ship option A or B?\"}")],
            [StreamEvent(contentDelta: "Ship option A.")],
        ])

        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        let stop = try await runIteration(
            task: task, client: client, tools: tools, runtime: runtime,
            supervisorMode: .autonomous, conversation: &conversation)

        guard case .continueLoop = stop else {
            return XCTFail("An auto-answered question must not park the step, got \(stop)")
        }
        XCTAssertEqual(client.sentMessages.count, 2,
                       "The auto-answer is a second request against the same model")

        let step = try XCTUnwrap(delegate.taskToMutate?.runs[0].steps[0])
        XCTAssertEqual(step.supervisorAnswer, "Ship option A.")
        XCTAssertTrue(step.supervisorAnswerWasAuto,
                      "The feed's 'Auto-answered' badge reads this flag — a human never replied")
        XCTAssertFalse(step.needsSupervisorInput,
                       "The step must NOT be parked: there is no human in autonomous mode")
    }

    // MARK: - 2b. roleName passed to the provider

    /// `roleName` rides into `NetworkLogger` and the provider request purely as a
    /// label. A role whose display name is empty — the shape
    /// `Role.fromDefinition` produces for a definition with a blank name — must
    /// send `nil` rather than an empty string, so the log shows "no role" instead
    /// of a role called "".
    ///
    /// RED: replace the ternary with a bare `roleForMessage.displayName` →
    /// the recorded name becomes `""` instead of `nil`.
    func testEmptyRoleDisplayName_sendsNilRoleNameRatherThanEmptyString() async throws {
        let task = seedTask()
        let anonymous = Role.custom(id: "")
        XCTAssertTrue(anonymous.displayName.isEmpty, "test premise: this role renders as empty")

        let client = UFCScriptedStreamClient([[StreamEvent(contentDelta: "ok")]])
        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        _ = try await runIteration(
            task: task, client: client, tools: [],
            roleForMessage: anonymous, conversation: &conversation)

        XCTAssertEqual(client.roleNames.count, 1)
        XCTAssertNil(client.roleNames[0],
                     "An empty display name must collapse to nil, not travel as \"\"")
    }

    /// The complementary arm, so the ternary is pinned in both directions: a real
    /// role's name must reach the provider verbatim.
    ///
    /// RED: replace the ternary with a literal `nil` → the log loses every
    /// role attribution.
    func testNonEmptyRoleDisplayName_isForwardedVerbatim() async throws {
        let task = seedTask()
        let client = UFCScriptedStreamClient([[StreamEvent(contentDelta: "ok")]])
        var conversation: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        _ = try await runIteration(
            task: task, client: client, tools: [],
            roleForMessage: .softwareEngineer, conversation: &conversation)

        XCTAssertEqual(client.roleNames.first ?? nil, Role.softwareEngineer.displayName)
    }
}

// =============================================================================
// MARK: - LLMStateDelegate: the default no-op witnesses
// =============================================================================

/// `reportPrefixCacheMiss` and `requeueSupervisorMessageAtHead` are protocol
/// REQUIREMENTS (`LLMExecutionDelegate.swift:301` and `:329`) that additionally
/// carry no-op DEFAULTS in `extension LLMStateDelegate` (`:335`, `:340`). That
/// default is the only reason the ~44 existing doubles did not have to grow two
/// methods each when the prompt-prefix ledger and the planning-phase re-queue
/// landed. The contract is therefore precisely "a conformer that implements
/// neither inherits a NO-OP": not a crash, and not a side effect a narrow double
/// would be surprised by.
///
/// The requirement-vs-extension-only distinction is not pedantry and this comment
/// had it backwards: because they ARE requirements, dispatch goes through the
/// witness table, so a conformer's own implementation shadows the default. Were
/// they extension-only, dispatch would be static and a stub's implementation
/// would be bypassed entirely through an `any LLMStateDelegate` existential —
/// which is exactly the bug the anti-vacuum source pin below is guarding against.
///
/// Driven through `MultiTaskDelegateStub` rather than a fresh double because
/// `LLMStateDelegate` carries 50+ members; that stub is the test target's one
/// bare conformer, and hand-rolling a second would rot the moment the protocol
/// grows. The source pin below is what stops this suite going vacuous if the
/// stub ever grows its own implementations.
@MainActor
final class DelegateDefaultWitnessCoverageTests: XCTestCase {

    /// `MultiTaskDelegateStub` is `@MainActor`-inferred (it conforms to the
    /// `@MainActor` `LLMExecutionDelegate` in its primary declaration), so every
    /// test that builds one must be `async` — a sync `@MainActor` test method
    /// aborts the process on Xcode 26 (CLAUDE.md §Testing Conventions).
    private func bareConformer() -> DelegatedSupervisorAnswerServiceTests.MultiTaskDelegateStub {
        DelegatedSupervisorAnswerServiceTests.MultiTaskDelegateStub()
    }

    /// Called through an existential so dispatch goes via the witness table —
    /// which is how production reaches it (`LLMExecutionService.delegate` is
    /// `(any LLMExecutionDelegate)?`).
    ///
    /// RED: change the extension body to `fatalError("not implemented")` (the
    /// obvious alternative to a defaulted witness) → this test crashes the
    /// process, which is what every prefix-cache-reporting iteration would do
    /// against a double that never opted in.
    func testBareConformer_reportPrefixCacheMiss_isANoOpAndTouchesNoTaskState() async {
        let stub = bareConformer()
        stub.tasks[1] = NTMSTask(id: 1, title: "T", supervisorTask: "b")
        let delegate: any LLMStateDelegate = stub

        delegate.reportPrefixCacheMiss(
            PrefixCacheMiss(
                owner: .oneShot(label: "coverage"),
                runID: 0,
                modelName: "stub",
                diagnosis: PrefixCachePolicy.Diagnosis(
                    cause: .degradedReplay,
                    commonSegments: 0,
                    previousSegments: 0,
                    discardedTokens: 9_000)))

        XCTAssertEqual(stub.tasks.count, 1,
                       "The default witness must observe, not mutate — it has nowhere to report to")
    }

    /// The drop IS the contract: only the orchestrator owns a Supervisor queue,
    /// so a conformer without one must discard rather than fabricate delivery.
    ///
    /// RED: give the extension a body that mutates anything reachable (or remove
    /// the default so every narrow double must implement it) → a re-queue against
    /// a double becomes visible state instead of a silent drop, and the ~44
    /// doubles that never opted in stop compiling.
    func testBareConformer_requeueSupervisorMessageAtHead_isANoOpAndTouchesNoTaskState() async {
        let stub = bareConformer()
        stub.tasks[2] = NTMSTask(id: 2, title: "T", supervisorTask: "b")
        let before = stub.tasks
        let delegate: any LLMStateDelegate = stub

        delegate.requeueSupervisorMessageAtHead(
            taskID: 2, roleID: "engineer", text: "look at the parser instead")

        XCTAssertEqual(stub.tasks.count, before.count)
        // Whole-value equality, not `runs.count`: an empty witness can only mutate through
        // `mutateTask`, and comparing one field would miss a body that touched any other.
        XCTAssertEqual(stub.tasks[2], before[2],
                       "A no-op witness must not invent a delivery record, or alter any other field")
    }

    /// Anti-vacuum guard. Both tests above are only meaningful while
    /// `MultiTaskDelegateStub` declares NEITHER method — the moment it grows one,
    /// dispatch lands on the stub and the extension body stops being executed,
    /// leaving two green tests that pin nothing.
    ///
    /// RED: none against production — this pins the fixture. It fires when
    /// someone adds `func reportPrefixCacheMiss` / `func requeueSupervisorMessageAtHead`
    /// to `MultiTaskDelegateStub`, at which point this suite needs a different
    /// bare conformer.
    func testFixtureStillInheritsBothDefaults_ratherThanImplementingThem() throws {
        // NanoTeamsTests/Services/LLM/<this file> → repo root → sibling suite.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM/
            .deletingLastPathComponent()  // Services/
            .deletingLastPathComponent()  // NanoTeamsTests/
            .deletingLastPathComponent()  // repo root
        let fixture = repoRoot.appendingPathComponent(
            "NanoTeamsTests/Services/LLM/DelegatedSupervisorAnswerServiceTests.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
        // Strip line comments so a doc comment naming the method can't trip the scan.
        let code = source
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let slashes = line.range(of: "//") else { return line }
                return String(line[line.startIndex..<slashes.lowerBound])
            }
            .joined(separator: "\n")

        for method in ["reportPrefixCacheMiss", "requeueSupervisorMessageAtHead"] {
            XCTAssertFalse(
                code.contains("func " + method),
                "MultiTaskDelegateStub now implements \(method) — the default-witness tests in "
                    + "this file no longer execute the protocol extension and must be re-pointed "
                    + "at a conformer that still inherits it.")
        }
    }
}

// =============================================================================
// MARK: - MemoryTagStore: build/test envelopes with fields missing
// =============================================================================

/// `extractBuildSummary` / `extractTestSummary` read JSON that arrived from an
/// xcodebuild run, so a field can be absent for reasons this process does not
/// control (an older envelope, a foreign producer, a truncated write). Every
/// `??` default below therefore has to produce a DEFINED, non-misleading summary
/// — and the summary is what the model is shown in place of the raw log, so a
/// wrong default is a wrong belief the model then acts on.
///
/// `MemoryTagStoreProcessingTests` covers the populated shapes and the
/// `severity`/`failures[].message` defaults; these are the remaining ones.
final class BuildTestSummaryMissingFieldCoverageTests: XCTestCase {

    private var sut: MemoryTagStore!

    override func setUp() {
        super.setUp()
        sut = MemoryTagStore(workFolderRoot: FileManager.default.temporaryDirectory)
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    /// A build issue with no `message` still has to occupy a line: the summary is
    /// the model's only view of the failure, and silently dropping the issue
    /// would make a failing build read as if it had fewer problems than the
    /// header counts.
    ///
    /// RED: change the default to `""` → the rendered line collapses to
    /// `[E] ` (or `[E]  — A.swift`), and two DIFFERENT message-less issues
    /// become one indistinguishable entry in the summary.
    func testBuildIssueWithoutMessage_rendersAPlaceholderRatherThanVanishing() {
        let json = "{\"ok\":true,\"data\":{\"success\":false,\"error_count\":1,"
            + "\"warning_count\":0,\"issues\":[{\"severity\":\"error\",\"file\":\"A.swift\"}]}}"
        let summary = sut.extractBuildSummary(from: json)

        XCTAssertTrue(summary.contains("[E] ? — A.swift"), summary)
        XCTAssertEqual(summary.components(separatedBy: "\n").count, 2,
                       "header + the issue line — a message-less issue must not be dropped")
    }

    /// A test-result payload that parses but carries none of the counters. The
    /// only safe reading is FAILED: reporting "passed" for a run whose outcome is
    /// unknown tells the model its change is green and lets a broken build
    /// through the pipeline.
    ///
    /// `skipped` is the one field supplied, and it is the anti-vacuum control: it
    /// proves the `data` object really was parsed, so the zeros below come from
    /// the `??` defaults rather than from the early `TESTS UNKNOWN` bail-out.
    ///
    /// RED: flip the `success` default to `true` → this returns
    /// "TESTS PASSED: 0 passed", i.e. an unknown outcome summarised as green.
    func testTestSummaryWithNoCounters_defaultsToFailedWithZeroes() {
        let summary = sut.extractTestSummary(from: "{\"ok\":true,\"data\":{\"skipped\":3}}")

        XCTAssertEqual(summary, "TESTS FAILED: 0 passed, 0 failed, 3 skipped",
                       "counters absent ⇒ zero; `skipped` present ⇒ read, proving `data` parsed")
    }

    /// The sibling case that isolates the two counter defaults from the `success`
    /// default: `success` IS present and true, but neither counter spelling is.
    ///
    /// RED: change the `failed` default from `0` to any non-zero value → the
    /// `success && failed == 0` gate flips and a genuinely green run is reported
    /// as failed, which is the noisy-but-safe direction; changing the `passed`
    /// default corrupts the count the model reads back.
    func testTestSummaryWithSuccessButNoCounters_reportsPassedWithZeroCount() {
        let summary = sut.extractTestSummary(from: "{\"ok\":true,\"data\":{\"success\":true}}")
        XCTAssertEqual(summary, "TESTS PASSED: 0 passed")
    }
}

// =============================================================================
// MARK: - EditFileTool: line-number stripping on an all-blank anchor
// =============================================================================

/// `stripLineNumberPrefixes` exists because models paste `old_text` straight out
/// of `read_lines` output, gutter and all. It only strips when EVERY non-empty
/// line carries a gutter prefix, and its `guard !nonEmptyLines.isEmpty` arm is
/// the all-blank anchor — the shape a model sends when it means "split this line
/// in two" or "collapse this blank run".
///
/// MEASURED, and worth knowing before anyone "fixes" that guard: removing it is
/// UNOBSERVABLE. With every line blank, `allSatisfy` over the empty set is
/// vacuously true, the map then hits its own `guard !line.isEmpty` on every
/// line, and the join reproduces the input byte-for-byte — verified for `""`,
/// `"\n"` and `"\n\n"`. The guard is a short-circuit, not a correctness gate,
/// so these tests pin the OUTCOME (a blank anchor survives and matches) rather
/// than pretending the branch itself is load-bearing.
final class EditFileBlankAnchorCoverageTests: XCTestCase {

    private let fm = FileManager.default
    private var workDir: URL!

    override func setUp() {
        super.setUp()
        workDir = fm.temporaryDirectory
            .appendingPathComponent("nt-ufc-edit-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let workDir { try? fm.removeItem(at: workDir) }
        workDir = nil
        super.tearDown()
    }

    /// A newline-only anchor must reach the matcher unmodified, so it matches the
    /// file's first line break literally and the edit lands.
    ///
    /// RED: a whitespace-only `old_text` rejection added to argument validation →
    /// the edit is refused for an anchor that is plainly in the file.
    ///
    /// NOT red against the `guard !nonEmptyLines.isEmpty` line itself (see the
    /// suite comment — removing it changes no output), and an earlier draft of
    /// this comment ALSO claimed a `stripLineNumberPrefixes` returning `""` would
    /// fire it. It would not: `EditFileTool` seeds `candidates = [oldText]` before
    /// consulting `stripped` and appends the stripped form only when it is
    /// non-empty and different, so an empty stripper leaves `["\n"]`, the match
    /// still succeeds, and this test stays green. Recorded rather than deleted:
    /// this line has now produced two false REDs, and the next reader should not
    /// derive a third.
    func testEditFile_anchorOfOnlyBlankLines_isNotRewrittenAndStillMatches() throws {
        let file = workDir.appendingPathComponent("a.txt")
        try "alpha\nbeta\n".write(to: file, atomically: true, encoding: .utf8)

        let result = EditFileTool(
            resolver: SandboxPathResolver(workFolderRoot: workDir), fileManager: fm
        ).handle(
            context: ToolExecutionContext(workFolderRoot: workDir, taskID: 1, runID: 0, roleID: "r"),
            args: ["path": "a.txt", "old_text": "\n", "new_text": "\nGAMMA\n"]
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        let envelope = try ufcEnvelope(result.outputJSON)
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual(data["replacements_made"] as? Int, 1,
                       "the blank anchor must match literally: \(result.outputJSON)")
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8), "alpha\nGAMMA\nbeta\n",
            "an untouched anchor replaces the FIRST newline in place")
    }

    /// The populated counterpart, so the guard is pinned as a special case rather
    /// than as the whole function: a real gutter-prefixed anchor must still be
    /// stripped and matched.
    ///
    /// RED: make `stripLineNumberPrefixes` return its input unchanged → the
    /// gutter-carrying anchor no longer matches and the edit fails, which is the
    /// paste-from-`read_lines` case the helper was written for.
    func testEditFile_gutterPrefixedAnchor_isStrippedAndMatches() throws {
        let file = workDir.appendingPathComponent("b.txt")
        try "let x = 1\nlet y = 2\n".write(to: file, atomically: true, encoding: .utf8)

        let result = EditFileTool(
            resolver: SandboxPathResolver(workFolderRoot: workDir), fileManager: fm
        ).handle(
            context: ToolExecutionContext(workFolderRoot: workDir, taskID: 1, runID: 0, roleID: "r"),
            args: ["path": "b.txt", "old_text": "1\tlet x = 1", "new_text": "let x = 42"]
        )

        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let x = 42\nlet y = 2\n")
    }
}
