import XCTest

@testable import NanoTeams

// MARK: - Shared scaffolding

/// Capturing stub that records the RESOLVED `LLMConfig` each request went out with —
/// `CapturingStubLLMClient` (RevisionContinuationSendPathTests) drops the config, and the
/// config is exactly what the pre-flight fallback changes.
///
/// The stream yields one delta and then hangs until cancelled, mirroring the house pattern:
/// finishing immediately would send the step back around a tool loop whose iteration cap is
/// `LLMConstants.maxToolIterations == 0` (unbounded) and spin.
private final class CExecCapturingClient: LLMClient, @unchecked Sendable {
    struct Call {
        let config: LLMConfig
        let messages: [ChatMessage]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock { _calls.append(Call(config: config, messages: messages)) }
        return AsyncThrowingStream { continuation in
            let producer = Task.detached {
                continuation.yield(StreamEvent(contentDelta: "Working."))
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

/// Never streams anything — used where the assertion is that the model was NEVER reached.
private final class CExecSilentClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock { _callCount += 1 }
        return AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

private struct CExecWaitTimeout: Error, LocalizedError {
    let timeout: TimeInterval
    var errorDescription: String? { "cExecWaitUntil: condition not met within \(timeout)s." }
}

@MainActor
private func cExecWaitUntil(
    timeout: TimeInterval = 5.0,
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw CExecWaitTimeout(timeout: timeout) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Pre-flight at step start (`+StepLifecycle`)

/// `startStepExecution` runs `preflightCheck` ONLY when the role override moved the request
/// to a different provider or server. Nothing exercised that branch, so the behaviour it
/// exists for — "a role pinned to a server that is down must fall back to the global config
/// rather than wedge the run, and must SAY it did" — was unverified end to end.
///
/// The override points at the loopback discard port (9), which refuses instantly: no external
/// network, no timeout budget, deterministic.
@MainActor
final class CExecPreflightAtStepStartTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var stub: CExecCapturingClient!
    private var tempDir: URL!

    private let stepID = "cexec_preflight_swe"
    // Both are loopback ports nothing binds (a privileged bind is required below 1024, and
    // neither 9 nor 10 has a macOS default listener), so every probe refuses instantly. Using
    // a real provider port here would make the documented RED mutation pass on any machine
    // that happens to be running that provider.
    private let globalURL = "http://127.0.0.1:9"
    private let unreachableOverrideURL = "http://127.0.0.1:10"

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let client = CExecCapturingClient()
        stub = client
        service = LLMExecutionService(
            repository: NTMSRepository(),
            clientFactory: { client }
        )
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        mockDelegate.globalLLMConfig = LLMConfig(
            baseURLString: globalURL, modelName: "cexec-global-model")
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        stub = nil
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    /// RED: replace the `effectiveConfig.provider != globalConfig.provider || …baseURLString != …`
    /// condition in `+StepLifecycle` with `false` (i.e. never pre-flight) -> the request goes out
    /// on `cexec-override-model` at the dead URL and no system note is written, so both the
    /// model-name assertion and the system-note assertion fail.
    func testUnreachableRoleOverride_fallsBackToGlobalConfig_andRecordsWhy() async throws {
        let team = makeTeam(roleOverride: LLMOverride(
            baseURLString: unreachableOverrideURL, modelName: "cexec-override-model"))
        let task = makeTask(team: team)
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)

        service.startStepExecution(
            stepID: stepID, taskID: task.id, task: task, runIndex: 0, stepIndex: 0)
        try await cExecWaitUntil { !self.stub.calls.isEmpty }
        await service.cancelStepExecution(stepID: stepID, taskID: task.id)

        let used = stub.calls[0].config
        XCTAssertEqual(
            used.baseURLString, globalURL,
            "A role override whose server refuses the pre-flight probe must fall back to the "
                + "global server — keeping it would wedge the step on an unreachable host")
        XCTAssertEqual(
            used.modelName, "cexec-global-model",
            "The fallback replaces the WHOLE config, not just the URL — a half-fallback would "
                + "ask the global server for a model only the override server has")

        let systemNotes = (mockDelegate.taskToMutate?.runs[0].steps[0].llmConversation ?? [])
            .filter { $0.role == .system }
            .map(\.content)
        XCTAssertTrue(
            systemNotes.contains {
                $0.contains(unreachableOverrideURL) && $0.contains("unavailable, using default")
            },
            "The fallback must be visible in the step's conversation, naming the server that "
                + "was skipped — a silent swap makes the role look like it honoured its "
                + "override. got: \(systemNotes)")
    }

    /// The complement, and the reason the branch is conditional at all: an override that only
    /// narrows the MODEL on the SAME server must not pay a probe round-trip, and must not
    /// fall back — the model override has to survive.
    ///
    /// RED: widen the condition to `effectiveConfig != globalConfig` -> this override now
    /// pre-flights against `globalURL` (nothing listening in the test process), falls back,
    /// and `modelName` reads "cexec-global-model" instead of the override.
    func testModelOnlyOverride_onSameServer_skipsPreflightAndKeepsTheOverride() async throws {
        let team = makeTeam(roleOverride: LLMOverride(modelName: "cexec-override-model"))
        let task = makeTask(team: team)
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)

        service.startStepExecution(
            stepID: stepID, taskID: task.id, task: task, runIndex: 0, stepIndex: 0)
        try await cExecWaitUntil { !self.stub.calls.isEmpty }
        await service.cancelStepExecution(stepID: stepID, taskID: task.id)

        let used = stub.calls[0].config
        XCTAssertEqual(
            used.modelName, "cexec-override-model",
            "A model-only override targets the SAME server, so there is nothing to pre-flight "
                + "and nothing to fall back from")
        XCTAssertEqual(used.baseURLString, globalURL)

        let systemNotes = (mockDelegate.taskToMutate?.runs[0].steps[0].llmConversation ?? [])
            .filter { $0.role == .system }
            .map(\.content)
        XCTAssertFalse(
            systemNotes.contains { $0.contains("unavailable, using default") },
            "No probe ran, so no unavailability note may be written. got: \(systemNotes)")
    }

    // MARK: - Helpers

    private func makeTeam(roleOverride: LLMOverride) -> Team {
        let swe = TeamRoleDefinition(
            id: stepID, name: "Software Engineer", prompt: "p",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Engineering Notes"]),
            llmOverride: roleOverride,
            systemRoleID: "softwareEngineer"
        )
        return Team(
            name: "CExecPreflightTeam", roles: [swe], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
    }

    private func makeTask(team: Team) -> NTMSTask {
        let step = StepExecution(
            id: stepID, role: .softwareEngineer, title: "SWE Step",
            expectedArtifacts: ["Engineering Notes"], status: .running)
        var task = NTMSTask(
            id: 9101, title: "T", supervisorTask: "Implement M2.",
            runs: [Run(id: 0, steps: [step])])
        task.preferredTeamID = team.id
        return task
    }

    private func makeSnapshot(team: Team, task: NTMSTask) -> WorkFolderContext {
        let projection = WorkFolderProjection(
            state: WorkFolderState(name: "T", activeTeamID: team.id),
            settings: .defaults,
            teams: [team]
        )
        return WorkFolderContext(
            projection: projection,
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: task.id,
            activeTask: task
        )
    }
}

// MARK: - Upstream artifact bodies reaching the wire (`+ConversationManagement`)

/// `buildChatMessages` hands `PromptBuilder` an `artifactReader` closure that resolves an
/// upstream deliverable's bytes off disk. That closure is the ONLY way a downstream role ever
/// sees what the role before it produced — everything else it gets is a NAME. If it returns
/// nil the prompt still renders, just with "(content not available)", so the failure is silent
/// and shows up only as a downstream role inventing the input it was supposed to consume.
@MainActor
final class CExecUpstreamArtifactInjectionTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var stub: CExecCapturingClient!
    private var tempDir: URL!

    private let upstreamStepID = "cexec_inject_pm"
    private let downstreamStepID = "cexec_inject_swe"
    private let artifactBody = "REQ-1: the calculator must support square roots."
    private let artifactRelativePath = "cexec_artifact_product_requirements.md"

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        let nanoteamsDir = NTMSPaths(workFolderRoot: tempDir).nanoteamsDir
        try? FileManager.default.createDirectory(at: nanoteamsDir, withIntermediateDirectories: true)
        try? Data(artifactBody.utf8).write(
            to: nanoteamsDir.appendingPathComponent(artifactRelativePath))

        let client = CExecCapturingClient()
        stub = client
        service = LLMExecutionService(
            repository: NTMSRepository(),
            clientFactory: { client }
        )
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        stub = nil
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    /// RED: make the `artifactReader` closure in `buildChatMessages` return nil unconditionally
    /// (or drop the `delegate?.workFolderURL` it resolves against) -> the required-artifacts
    /// section renders "(content not available)" and the body assertion fails while the
    /// section-header assertion still passes, which is exactly how the silent version looks.
    func testDownstreamRole_receivesTheUpstreamArtifactBody_notJustItsName() async throws {
        let team = makeTeam()
        let task = makeTask(team: team)
        mockDelegate.taskToMutate = task
        mockDelegate.snapshot = makeSnapshot(team: team, task: task)

        service.startStepExecution(
            stepID: downstreamStepID, taskID: task.id, task: task, runIndex: 0, stepIndex: 1)
        try await cExecWaitUntil { !self.stub.calls.isEmpty }
        await service.cancelStepExecution(stepID: downstreamStepID, taskID: task.id)

        let wire = stub.calls[0].messages.compactMap(\.content).joined(separator: "\n")
        // Anti-vacuum: prove the required-artifacts section was built at all before asserting
        // what is inside it — otherwise a prompt that dropped the section entirely would look
        // the same as one that dropped only the body.
        XCTAssertTrue(
            wire.contains("Required Artifacts"),
            "The downstream role's prompt must carry a required-artifacts section")
        XCTAssertTrue(
            wire.contains(artifactBody),
            "The upstream deliverable's BODY must reach the downstream role — a name-only "
                + "reference leaves it inventing the input it was meant to consume")
        XCTAssertFalse(
            wire.contains("(content not available)"),
            "The artifact exists on disk; reporting it as unreadable is the silent failure "
                + "this test exists to catch")
    }

    // MARK: - Helpers

    private func makeTeam() -> Team {
        let pm = TeamRoleDefinition(
            id: upstreamStepID, name: "Product Manager", prompt: "p",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Product Requirements"]),
            systemRoleID: "productManager"
        )
        let swe = TeamRoleDefinition(
            id: downstreamStepID, name: "Software Engineer", prompt: "p",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Product Requirements"],
                producesArtifacts: ["Engineering Notes"]),
            systemRoleID: "softwareEngineer"
        )
        return Team(
            name: "CExecInjectionTeam", roles: [pm, swe], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
    }

    private func makeTask(team: Team) -> NTMSTask {
        let pmStep = StepExecution(
            id: upstreamStepID, role: .productManager, title: "PM step",
            expectedArtifacts: ["Product Requirements"], status: .done,
            artifacts: [
                Artifact(
                    name: "Product Requirements", mimeType: "text/markdown",
                    relativePath: artifactRelativePath)
            ])
        let sweStep = StepExecution(
            id: downstreamStepID, role: .softwareEngineer, title: "SWE step",
            expectedArtifacts: ["Engineering Notes"], status: .running)
        var task = NTMSTask(
            id: 9105, title: "T", supervisorTask: "Build a calculator.",
            runs: [Run(id: 0, steps: [pmStep, sweStep])])
        task.preferredTeamID = team.id
        return task
    }

    private func makeSnapshot(team: Team, task: NTMSTask) -> WorkFolderContext {
        let projection = WorkFolderProjection(
            state: WorkFolderState(name: "T", activeTeamID: team.id),
            settings: .defaults,
            teams: [team]
        )
        return WorkFolderContext(
            projection: projection,
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: task.id,
            activeTask: task
        )
    }
}

// MARK: - Producing role, no tool calls (`+StepFlowControl`)

/// A producing role that stops calling tools has two very different meanings, and
/// `handleNoToolCalls` has to tell them apart before it nudges: if the deliverables are
/// already in, the step is DONE; only if they are missing is a retry the right answer.
///
/// The "already in" arm (`checkArtifactCompleteness` -> `.completed`) had no coverage, so
/// nothing stopped a regression that nags a role for artifacts it has already submitted —
/// which, because a nudge is `.continueLoop`, is an unbounded retry loop against a role
/// that has nothing left to do (`maxToolIterations == 0`).
@MainActor
final class CExecNoToolCallsProducingRoleTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    private let stepID = "cexec_producer"

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    /// RED: make the producing branch skip `checkArtifactCompleteness` (delete the
    /// `if let artifactStop = … { return artifactStop }`) -> the step falls through to the
    /// "Missing deliverables" retry, so the stop is `.continueLoop` and a nudge is appended.
    /// Both assertions fail.
    func testProducingRole_noToolCalls_withAllArtifactsIn_completesInsteadOfNagging() async {
        let task = makeTask(artifacts: ["Engineering Notes"])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        var conversation: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "Engineering Notes are submitted; nothing further to do.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: makeRoleDefinition(),
            conversationMessages: &conversation
        )

        guard case .completed = stop else {
            XCTFail(
                "A producing role whose expected artifacts are all present must complete, not "
                    + "be asked to submit them again. got: \(stop)")
            return
        }
        XCTAssertTrue(
            conversation.isEmpty,
            "Completing must not also append a retry nudge — the role would answer a question "
                + "asked after its step already ended. got: \(conversation.map(\.content))")
    }

    /// The discriminating half: with the deliverable still missing the SAME inputs must produce
    /// a retry that names it in the exact quoted form the artifact-name resolver expects. Without
    /// this test the completion assertion above could be satisfied by a branch that completes
    /// unconditionally.
    ///
    /// RED: drop the quoting from the retry message (`expected.joined(separator: ", ")`) ->
    /// the `"Engineering Notes"` (with quotes) assertion fails.
    func testProducingRole_noToolCalls_withArtifactMissing_retriesNamingItVerbatim() async {
        let task = makeTask(artifacts: [])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        var conversation: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "I think that covers it.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: makeRoleDefinition(),
            conversationMessages: &conversation
        )

        guard case .continueLoop = stop else {
            XCTFail("A producing role with a missing deliverable must retry. got: \(stop)")
            return
        }
        XCTAssertEqual(conversation.count, 1, "Exactly one retry turn per non-productive turn")
        let nudge = conversation.first?.content ?? ""
        XCTAssertTrue(
            nudge.contains("\"Engineering Notes\""),
            "The missing deliverable must be named in quotes and verbatim — an unquoted or "
                + "reworded name is what `resolveArtifactName` then fails to match. got: \(nudge)")
    }

    /// Build diagnostics are a byproduct the runtime writes for itself, never something the
    /// model submits — so a step listing it among its expected artifacts must still be able to
    /// finish. This is the arm reached through `handleNoToolCalls`, i.e. exactly when the model
    /// has stopped acting and the only way out is completion.
    ///
    /// RED: drop the `.filter { $0 != ArtifactConstants.buildDiagnosticsName }` from
    /// `StepExecution.isArtifactComplete` -> completeness is never satisfied, the step falls to
    /// the "Missing deliverables" retry, and the `.completed` assertion fails. (Removing the
    /// mirror filter in `handleNoToolCalls` does NOT red this test — it only widens a list that
    /// is already non-empty — which is why the assertion is worded around completion, not
    /// around the two filters agreeing.)
    func testProducingRole_buildDiagnosticsNeverBlocksCompletion() async {
        var task = makeTask(artifacts: ["Engineering Notes"])
        task.runs[0].steps[0].expectedArtifacts = [
            ArtifactConstants.buildDiagnosticsName, "Engineering Notes",
        ]
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)

        let roleDef = TeamRoleDefinition(
            id: stepID, name: "Software Engineer", prompt: "p",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: [
                ArtifactConstants.buildDiagnosticsName, "Engineering Notes",
            ]),
            systemRoleID: "softwareEngineer"
        )

        var conversation: [ChatMessage] = []
        let stop = await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: "Notes submitted.",
            sawHarmonyMarker: false,
            task: task,
            roleDefinition: roleDef,
            conversationMessages: &conversation
        )

        guard case .completed = stop else {
            XCTFail(
                "Build diagnostics are a byproduct, not a deliverable — they must not hold a "
                    + "step open. got: \(stop)")
            return
        }
    }

    // MARK: - Helpers

    private func makeRoleDefinition() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: stepID, name: "Software Engineer", prompt: "p",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Engineering Notes"]),
            systemRoleID: "softwareEngineer"
        )
    }

    private func makeTask(artifacts: [String]) -> NTMSTask {
        let step = StepExecution(
            id: stepID, role: .softwareEngineer, title: "SWE Step",
            expectedArtifacts: ["Engineering Notes"], status: .running,
            artifacts: artifacts.map { Artifact(name: $0) })
        return NTMSTask(
            id: 9102, title: "T", supervisorTask: "Implement M2.",
            runs: [Run(id: 0, steps: [step])])
    }
}

// MARK: - Fresh-task re-read vs. step-start snapshot

/// Both `handleChangeRequest` and `handleTeammateConsultation` open by re-reading the task from
/// the delegate, because the `task` they were handed is a snapshot taken when the step STARTED
/// and does not carry mutations from earlier iterations. Each falls back to that snapshot when
/// the re-read is unavailable.
///
/// Neither the precedence (fresh wins) nor the fallback (snapshot is still consulted, rather
/// than an empty run being invented) had coverage. A fallback that silently degraded to "no
/// history" would drop every consultation-limit and every completed-step check the guards exist
/// to enforce.
@MainActor
final class CExecFreshTaskFallbackTests: XCTestCase {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var silentClient: CExecSilentClient!

    private let requestingStepID = "cexec_swe"
    private let targetStepID = "cexec_pm"
    private let taskID = 9103

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        silentClient = CExecSilentClient()
        service.attach(delegate: mockDelegate)
        // Deliberately NO workFolderURL: a change request that gets past validation runs its
        // voting meeting, which short-circuits at its own no-work-folder guard. That keeps the
        // "validation passed" outcome cheap and distinguishable from "validation rejected".
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        silentClient = nil
        mockDelegate = nil
        service = nil
        try await super.tearDown()
    }

    /// RED: delete the `if let freshTask = delegate.loadedTask(tid), runIndex < …` branch in
    /// `handleChangeRequest` (always use the snapshot) -> validation reads the STALE `.running`
    /// target and rejects, so the reply carries "has not completed their work yet" and the
    /// "the voting meeting did not run" assertion fails too (validation returns before it).
    func testChangeRequest_freshTaskWins_overStaleStepStartSnapshot() async {
        let team = makeTeam()
        // Snapshot: target still mid-flight. Fresh: target finished. Production must read fresh.
        let stale = makeTask(team: team, targetStatus: .running)
        mockDelegate.taskToMutate = makeTask(team: team, targetStatus: .done)
        mockDelegate.snapshot = makeSnapshot(team: team, task: stale)
        service._testRegisterStepTask(stepID: requestingStepID, taskID: taskID)

        let reply = await service.handleChangeRequest(
            stepID: requestingStepID,
            targetRoleID: targetStepID,
            changes: "Tighten the error handling.",
            reasoning: "The current path swallows failures.",
            requestingRole: .softwareEngineer,
            task: stale,
            runIndex: 0,
            stepIndex: 0,
            client: silentClient,
            config: LLMConfig()
        )

        XCTAssertFalse(
            reply.text.contains("has not completed their work yet"),
            "The step-start snapshot is stale by construction — validating against it rejects "
                + "change requests to work that finished during this step. got: \(reply.text)")
        // Anti-vacuum: prove we actually got PAST validation rather than failing some other way.
        // This phrase is emitted only by the `guard meetingReply.succeeded` arm, which sits
        // BELOW the validation block — so reaching it is proof validation passed. (It is not
        // "produced no votes": with no work folder the meeting never runs at all, so the tally
        // is never reached.)
        XCTAssertTrue(
            reply.text.contains("the voting meeting did not run"),
            "Validation must have passed and the voting meeting must have been attempted. "
                + "got: \(reply.text)")
    }

    /// RED: change the else-branch to synthesize an empty run (`run = Run(id: 0, steps: [])`)
    /// -> the error becomes "has no step in this run", so both assertions fail.
    func testChangeRequest_whenFreshReadUnavailable_stillValidatesAgainstTheSnapshot() async {
        let team = makeTeam()
        let stale = makeTask(team: team, targetStatus: .running)
        mockDelegate.taskToMutate = nil  // `loadedTask` now returns nil -> fallback arm
        mockDelegate.snapshot = makeSnapshot(team: team, task: stale)
        service._testRegisterStepTask(stepID: requestingStepID, taskID: taskID)

        let reply = await service.handleChangeRequest(
            stepID: requestingStepID,
            targetRoleID: targetStepID,
            changes: "Tighten the error handling.",
            reasoning: "The current path swallows failures.",
            requestingRole: .softwareEngineer,
            task: stale,
            runIndex: 0,
            stepIndex: 0,
            client: silentClient,
            config: LLMConfig()
        )

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(
            reply.text.contains("has not completed their work yet"),
            "With no fresh read available the snapshot is the only history there is; inventing "
                + "an empty run would waive every completed-work check. got: \(reply.text)")
        XCTAssertTrue(
            reply.text.contains("running"),
            "The rejection must report the status it actually saw. got: \(reply.text)")
    }

    /// RED: change the else-branch in `handleTeammateConsultation` to a freshly built
    /// `StepExecution` (no consultations) -> the limit no longer trips, the consulted role's
    /// LLM call goes out, and both the message and the `callCount == 0` assertions fail.
    func testTeammateConsultation_whenFreshReadUnavailable_stillEnforcesTheSnapshotLimit() async {
        let team = makeTeam()
        var stale = makeTask(team: team, targetStatus: .done)
        stale.runs[0].steps[0].consultations = (0..<TeamLimits.default.maxConsultationsPerStep)
            .map { i in
                TeammateConsultation(
                    requestingRole: .softwareEngineer,
                    consultedRole: .productManager,
                    question: "q\(i)")
            }
        mockDelegate.taskToMutate = nil  // fallback arm
        mockDelegate.snapshot = makeSnapshot(team: team, task: stale)
        service._testRegisterStepTask(stepID: requestingStepID, taskID: taskID)

        let reply = await service.handleTeammateConsultation(
            stepID: requestingStepID,
            consultedRoleID: targetStepID,
            question: "One more thing?",
            context: nil,
            requestingRole: .softwareEngineer,
            task: stale,
            runIndex: 0,
            stepIndex: 0,
            client: silentClient,
            config: LLMConfig()
        )

        XCTAssertFalse(reply.succeeded)
        XCTAssertTrue(
            reply.text.contains("Consultation limit reached"),
            "The per-step consultation budget lives in the step's history; losing it on the "
                + "fallback path makes the limit unenforceable. got: \(reply.text)")
        XCTAssertEqual(
            silentClient.callCount, 0,
            "A budget rejection must stop BEFORE the teammate's LLM call — otherwise the limit "
                + "costs exactly what it exists to save")
    }

    // MARK: - Helpers

    private func makeTeam() -> Team {
        let pm = TeamRoleDefinition(
            id: targetStepID, name: "Product Manager", prompt: "p",
            toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(producesArtifacts: ["Product Requirements"]),
            systemRoleID: "productManager"
        )
        let swe = TeamRoleDefinition(
            id: requestingStepID, name: "Software Engineer", prompt: "p",
            toolIDs: [ToolNames.requestChanges], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: ["Product Requirements"]),
            systemRoleID: "softwareEngineer"
        )
        return Team(
            name: "CExecFallbackTeam", roles: [pm, swe], artifacts: [],
            settings: TeamSettings(), graphLayout: TeamGraphLayout()
        )
    }

    /// SWE step first so `stepIndex: 0` addresses the requesting step, mirroring how the
    /// runtime hands `runIndex`/`stepIndex` down from `startStepExecution`.
    private func makeTask(team: Team, targetStatus: StepStatus) -> NTMSTask {
        let sweStep = StepExecution(
            id: requestingStepID, role: .softwareEngineer, title: "SWE step", status: .running)
        let pmStep = StepExecution(
            id: targetStepID, role: .productManager, title: "PM step", status: targetStatus)
        var task = NTMSTask(
            id: taskID, title: "T", supervisorTask: "...",
            runs: [Run(id: 0, steps: [sweStep, pmStep])])
        task.preferredTeamID = team.id
        return task
    }

    private func makeSnapshot(team: Team, task: NTMSTask) -> WorkFolderContext {
        let projection = WorkFolderProjection(
            state: WorkFolderState(name: "T", activeTeamID: team.id),
            settings: .defaults,
            teams: [team]
        )
        return WorkFolderContext(
            projection: projection,
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: task.id,
            activeTask: task
        )
    }
}

// MARK: - Approval-request identity

/// Both approval requests are `Identifiable` and are rendered as feed cards, so `id` is a
/// `ForEach` key (CLAUDE.md #22). Two facts have to hold and neither was pinned:
///   1. two DIFFERENT held commands/actions in the same step must not share an id, or one card
///      replaces the other and the human approves something they cannot see;
///   2. `createdAt` must NOT participate — which is exactly why `bashApprovalDidEnd` /
///      `computerUseApprovalDidEnd` take `createdAt` as a separate discriminator to avoid a late
///      `didEnd` from a prior hold clearing a freshly republished card.
final class CExecApprovalRequestIdentityTests: XCTestCase {

    /// RED: drop `commandKey` from `BashApprovalRequest.id` -> the two differing-command ids
    /// become equal and the first assertion fails.
    func testBashApprovalRequestID_discriminatesByCommandKeyButNotByTimestamp() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)

        let ls = makeBash(commandKey: "ls", createdAt: early)
        let rm = makeBash(commandKey: "rm", createdAt: early)
        XCTAssertNotEqual(
            ls.id, rm.id,
            "Two commands held in the same step must be distinguishable — a shared id makes one "
                + "approval card silently replace the other")

        let lsLater = makeBash(commandKey: "ls", createdAt: late)
        XCTAssertEqual(
            ls.id, lsLater.id,
            "`createdAt` must stay OUT of the identity: the re-published card for the same held "
                + "command is the same row, which is why `bashApprovalDidEnd` carries the "
                + "timestamp separately")
        XCTAssertNotEqual(
            ls, lsLater,
            "Equality still has to see the timestamp — otherwise a stale `didEnd` could not be "
                + "told apart from the live hold")
    }

    /// RED: drop `stepID` from `ComputerUseApprovalRequest.id` -> the two parallel roles'
    /// requests collide and the assertion fails.
    func testComputerUseApprovalRequestID_discriminatesByStepAndAction() {
        let stamp = Date(timeIntervalSince1970: 1_000)
        let roleA = makeComputerUse(stepID: "role_a", actionKey: "click:10,10", createdAt: stamp)
        let roleB = makeComputerUse(stepID: "role_b", actionKey: "click:10,10", createdAt: stamp)
        XCTAssertNotEqual(
            roleA.id, roleB.id,
            "Parallel roles on one task legitimately hold the same action; their cards must not "
                + "collapse into one row")

        let otherAction = makeComputerUse(
            stepID: "role_a", actionKey: "click:99,99", createdAt: stamp)
        XCTAssertNotEqual(roleA.id, otherAction.id)

        let sameHoldLater = makeComputerUse(
            stepID: "role_a", actionKey: "click:10,10",
            createdAt: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(
            roleA.id, sameHoldLater.id,
            "`createdAt` must stay out of the identity here for the same reason it does on the "
                + "bash side")
    }

    private func makeBash(commandKey: String, createdAt: Date) -> BashApprovalRequest {
        BashApprovalRequest(
            taskID: 1, stepID: "swe", commandKey: commandKey, command: "run \(commandKey)",
            workingDirectory: nil, offerAlways: true, createdAt: createdAt)
    }

    private func makeComputerUse(
        stepID: String, actionKey: String, createdAt: Date
    ) -> ComputerUseApprovalRequest {
        ComputerUseApprovalRequest(
            taskID: 1, stepID: stepID, actionKey: actionKey, actionSummary: "Click",
            targetApp: nil, offerAlways: false, screenshotBase64: nil,
            targetX: nil, targetY: nil, createdAt: createdAt)
    }
}

// MARK: - Collaboration signal routing agreement

/// `appendCollaborationResult`'s `default:` arm exists to catch drift between the routing
/// predicate (`isCollaborationDeferredSignal`) and the dispatch switch. It cannot be reached
/// from a test process: it calls `assertionFailure`, which traps in DEBUG. So the drift it
/// guards is pinned here instead, at the two places the drift would appear.
final class CExecCollaborationSignalRoutingTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
    }

    private let processingPath =
        "NanoTeams/Services/LLM/LLMExecutionService+ToolResultProcessing.swift"
    private let dispatchingPath =
        "NanoTeams/Services/LLM/LLMExecutionService+ToolResultDispatching.swift"

    /// Every signal the router DEFERS must have a matching `case` in the dispatch switch.
    /// A signal listed in the predicate but absent from the switch reaches `default:` — which
    /// traps the app in DEBUG and, in release, answers the model with "Unhandled collaboration
    /// signal" for a tool that ran no side effects at all.
    ///
    /// RED: add a case name to `isCollaborationDeferredSignal` without adding it to the switch
    /// (or delete a `case .taskStatus(` line from the switch) -> the missing name is reported.
    func testEveryDeferredSignal_hasADispatchCase() throws {
        let predicateNames = try caseNames(
            inBodyOf: "isCollaborationDeferredSignal", path: processingPath)
        XCTAssertGreaterThanOrEqual(
            predicateNames.count, 10,
            "The scan found almost nothing — the predicate was renamed or reshaped, so this pin "
                + "is measuring the wrong thing. found: \(predicateNames.sorted())")

        let dispatchSource = try source(dispatchingPath)
        // The dispatch switch holds exactly one `default:` — its drift-guard arm — so slicing to
        // the first occurrence is unambiguous and survives reindentation.
        let switchBody = try XCTUnwrap(
            slice(of: dispatchSource, from: "switch result.signal {", to: "default:"),
            "Could not locate the dispatch switch — its shape changed and this pin is vacuous")
        let dispatchNames = caseNames(inSwitchBody: switchBody)

        let missing = predicateNames.subtracting(dispatchNames)
        XCTAssertTrue(
            missing.isEmpty,
            "These signals are routed to `appendCollaborationResult` but have no case there, so "
                + "they land on the `default:` arm (DEBUG trap / bogus release envelope): "
                + "\(missing.sorted())")
    }

    /// The Autovisor subset is the one with no other UI surface: its tool-call card is the only
    /// place a manager action's result appears. A manager signal missing from the deferred set
    /// keeps its card on the synchronous `{"status":"pending"}` placeholder forever.
    ///
    /// RED: remove `.waitForEvents` (or any manager case) from `isCollaborationDeferredSignal`
    /// -> that signal reports `false` and the assertion names it.
    func testEveryAutovisorSignal_isAlsoDeferred() {
        let managerSignals: [ToolSignal] = [
            .listTasks,
            .taskStatus(taskID: 1),
            .createManagedTask(title: "t", brief: "b", teamID: nil),
            .controlTask(taskID: 1, verb: .pause),
            .manageRole(taskID: 1, roleID: "r", verb: .accept),
            .answerTaskQuestion(taskID: 1, answer: "a"),
            .messageTask(taskID: 1, text: "m", roleID: nil),
            .scheduleTask(taskID: 1, intervalMinutes: 5),
            .setWorkFolderContext(content: "c"),
            .waitForEvents,
        ]
        for signal in managerSignals {
            XCTAssertTrue(
                LLMExecutionService.isAutovisorSignal(signal),
                "\(signal) must be recognised as a manager signal so its card reflects the real "
                    + "result instead of staying on the pending placeholder")
            XCTAssertTrue(
                LLMExecutionService.isCollaborationDeferredSignal(signal),
                "\(signal) is a manager signal, so it MUST also be deferred — otherwise it takes "
                    + "the regular tool path and never runs its handler")
        }
    }

    /// Guards the other direction: the predicate is not simply `true`. A `default: return true`
    /// would send ordinary tool results down the collaboration path, which double-appends their
    /// tool message and reflects a collaboration envelope onto a plain tool card.
    ///
    /// RED: change either predicate's `default:` to `return true` -> both assertions fail.
    func testNonCollaborationSignals_areNotDeferred() {
        for signal in [ToolSignal.supervisorQuestion("q"),
                       .artifact(name: "n", content: "c", format: nil)] {
            XCTAssertFalse(LLMExecutionService.isCollaborationDeferredSignal(signal), "\(signal)")
            XCTAssertFalse(LLMExecutionService.isAutovisorSignal(signal), "\(signal)")
        }
    }

    // MARK: - Source scanning

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(of text: String, from start: String, to end: String) -> String? {
        guard let lower = text.range(of: start) else { return nil }
        guard let upper = text.range(of: end, range: lower.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[lower.upperBound..<upper.lowerBound])
    }

    /// Case names inside the `switch signal { … }` of a named predicate function.
    private func caseNames(inBodyOf function: String, path: String) throws -> Set<String> {
        let text = try source(path)
        let body = try XCTUnwrap(
            slice(of: text, from: "func \(function)", to: "return false"),
            "Could not locate \(function) — this pin is vacuous")
        return caseNames(inSwitchBody: body)
    }

    /// Pulls `.identifier` tokens out of `case` lines, ignoring comments and `default:`.
    private func caseNames(inSwitchBody body: String) -> Set<String> {
        var names: Set<String> = []
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), !line.hasPrefix("///") else { continue }
            guard line.hasPrefix("case ") || line.hasPrefix(".") else { continue }
            var token = ""
            var collecting = false
            for character in line {
                if character == "." {
                    collecting = true
                    token = ""
                    continue
                }
                if collecting {
                    if character.isLetter || character.isNumber || character == "_" {
                        token.append(character)
                    } else {
                        if !token.isEmpty { names.insert(token) }
                        collecting = false
                        token = ""
                    }
                }
            }
            if collecting, !token.isEmpty { names.insert(token) }
        }
        names.remove("signal")
        return names
    }
}

// MARK: - Test-seam hygiene

/// `_testInjectRunningTask` cancels whatever `runningTask` was already registered under the
/// key. That is not decoration: an un-cancelled predecessor keeps running after its test ends,
/// and its next `mutateTask` lands on the NEXT test's `taskToMutate` — the exact shape of a
/// cross-suite flake that is impossible to attribute from the failure message.
@MainActor
final class CExecInjectedRunningTaskHygieneTests: XCTestCase {

    private var service: LLMExecutionService!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        service = nil
        try await super.tearDown()
    }

    /// RED: remove the `existing.cancel()` from `_testInjectRunningTask` -> the first task never
    /// observes cancellation, the expectation is never fulfilled, and the test times out.
    func testInjectingASecondRunningTask_cancelsTheFirst() async {
        let stepID = "cexec_inject"
        let taskID = 9104
        let observed = expectation(description: "first runningTask observed cancellation")

        let first = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            observed.fulfill()
        }
        service._testInjectRunningTask(stepID: stepID, taskID: taskID, runningTask: first)

        let second = Task<Void, Never> {}
        service._testInjectRunningTask(stepID: stepID, taskID: taskID, runningTask: second)

        await fulfillment(of: [observed], timeout: 3.0)
        XCTAssertTrue(
            first.isCancelled,
            "The replaced runningTask must be cancelled, or it outlives the step it belonged to")
        XCTAssertTrue(
            service._testHasExecutionState(stepID: stepID, taskID: taskID),
            "Replacing the task must not tear the state entry down")
    }
}
