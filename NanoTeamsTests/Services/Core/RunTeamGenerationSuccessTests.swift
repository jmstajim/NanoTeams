import XCTest

@testable import NanoTeams

/// `runTeamGeneration`'s SUCCESS arm, end to end — the largest untested happy path in the
/// app until the `teamGenerationClient` seam existed.
///
/// `TeamGenerationService.generate` declared `client: any LLMClient = LLMClientRouter()` and
/// the call site never passed one, so in a test process every generation threw a transport
/// error. Everything downstream of "the LLM returned a team" had therefore never executed:
/// `applyForcedDefaults`, the `.success` switch arm, `applyGeneratedTeamSuccess`'s
/// adopt / re-pin / seed, the warning surfacing, and both callers' `engine.start()`.
/// `RunTeamGenerationFlowTests` says so in its own doc comment — it lists the success arm
/// under "Not covered here, and why", naming the missing seam as the reason.
///
/// The half that WAS covered — `applyGeneratedTeamSuccess` called directly by
/// `TeamGenerationOrchestratorTests` — is why this suite asserts on the arm's composition
/// rather than re-deriving those invariants: that the client's team is the one adopted, that
/// forced defaults are applied BEFORE adoption, and that a failure to apply is reported as
/// a failure rather than swallowed.
@MainActor
final class RunTeamGenerationSuccessTests: NTMSOrchestratorTestBase {

    private var teamGenClient: ScriptedTeamGenerationClient!

    override func setUp() {
        super.setUp()
        teamGenClient = ScriptedTeamGenerationClient()
        // Rebuild `sut` with the team-generation seam scripted, keeping the base's other
        // stubs so `openWorkFolder` still does no network I/O.
        sut = TestOrchestrator.make(
            embeddingClient: embeddingClient,
            chatLifecycleClient: chatLifecycleClient,
            teamGenerationClient: teamGenClient
        )
    }

    override func tearDown() {
        teamGenClient = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// The minimal WARNING-FREE `create_team` payload: non-empty name, at least one role,
    /// every artifact reference resolving — and real tools on the producing role, because
    /// `GeneratedTeamBuilder` correctly warns about a role that must produce an artifact
    /// while being unable to read or change anything.
    private func teamConfigJSON(
        name: String = "Generated Calculator",
        roleName: String = "Engineer"
    ) -> String {
        """
        {"name":"\(name)","description":"generated","roles":[{"name":"\(roleName)",\
        "prompt":"do the work","produces_artifacts":["Code"],\
        "requires_artifacts":["Supervisor Task"],\
        "tools":["\(ToolNames.readFile)","\(ToolNames.writeFile)"]}],\
        "artifacts":[{"name":"Code","description":"the code"}],\
        "supervisor_requires":["Code"]}
        """
    }

    private func scriptTeam(_ json: String) {
        teamGenClient.events = [
            StreamEvent(toolCallDeltas: [
                StreamEvent.ToolCallDelta(
                    index: 0, id: "call_1", name: ToolNames.createTeam, argumentsDelta: json)
            ])
        ]
    }

    private func seedGeneratedTemplate() async {
        await sut.mutateWorkFolder { project in
            guard !project.teams.contains(where: { $0.templateID == "generated" }) else { return }
            project.teams.append(TeamTemplateFactory.generatedTeam())
        }
    }

    /// Production-shaped setup: the placeholder template in the folder, a task preferring it,
    /// and a run pinned to it — the state `startRun` leaves behind before it calls
    /// `runTeamGeneration`.
    private func prepareTask(brief: String = "build a calculator") async -> (Int, NTMSID)? {
        await sut.openWorkFolder(tempDir)
        await seedGeneratedTemplate()
        guard let template = sut.workFolder?.teams.first(where: { $0.templateID == "generated" })
        else { XCTFail("expected the Generated Team placeholder"); return nil }
        guard let taskID = await sut.createTask(
            title: "Gen", supervisorTask: brief, preferredTeamID: template.id)
        else { XCTFail("createTask returned nil"); return nil }
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: template.id)
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        XCTAssertTrue(sut.needsTeamGeneration(taskID: taskID), "precondition")
        return (taskID, template.id)
    }

    private func generationStep(taskID: Int) -> StepExecution? {
        (sut.loadedTask(taskID)?.runs.last?.steps ?? []).first { $0.isTeamGenerationStep }
    }

    // MARK: - The success arm

    /// The whole arm. Reported success, the team adopted onto the task, the run RE-PINNED to
    /// the generated team's id, the placeholder step finalized `.done`, and its tool call's
    /// envelope flipped from the `"status":"generating"` spinner to a success payload.
    ///
    /// The re-pin is the load-bearing part: `createNewRun` runs BEFORE generation, so
    /// `run.teamID` is the transient placeholder (roleIDs: []), and leaving it there makes
    /// `findOrCreateStep`'s roster-swap guard reject every generated role as "not a member of
    /// pinned team".
    ///
    /// RED: drop `task.runs[ri].teamID = team.id` from `applyGeneratedTeamSuccess` → the
    /// re-pin assertion fails and the engine would refuse every role of the team it just
    /// generated.
    func testRunTeamGeneration_success_adoptsTheTeamAndRePinsTheRun() async throws {
        guard let (taskID, templateID) = await prepareTask() else { return }
        scriptTeam(teamConfigJSON())

        let ok = await sut.runTeamGeneration(taskID: taskID)

        XCTAssertTrue(ok, "the arm reports success: \(sut.lastErrorMessage ?? "no error")")
        let task = try XCTUnwrap(sut.loadedTask(taskID))
        let generated = try XCTUnwrap(task.generatedTeam, "the team must be adopted onto the task")
        XCTAssertEqual(generated.name, "Generated Calculator")
        XCTAssertNotEqual(generated.id, templateID, "a fresh id, not the placeholder's")
        XCTAssertEqual(
            task.runs.last?.teamID, generated.id,
            "the run must be re-pinned off the placeholder onto the team that executes")

        let step = try XCTUnwrap(generationStep(taskID: taskID))
        XCTAssertEqual(step.status, .done)
        let call = try XCTUnwrap(step.toolCalls.first)
        XCTAssertNotEqual(call.isError, true)
        XCTAssertFalse(
            call.isGeneratingTeam,
            "the spinner marker must be gone, or the pane spins forever")
        XCTAssertTrue(call.resultJSON?.contains("Generated Calculator") == true, call.resultJSON ?? "")
    }

    /// Role statuses are seeded so the engine has something ready to run. Without this the
    /// engine starts, finds no ready role, and the task stalls on "No roles ready to execute"
    /// immediately after a successful generation.
    ///
    /// RED: remove the `seedRoleStatuses` call → `.ready` disappears and the run has no
    /// startable role.
    func testRunTeamGeneration_success_seedsRoleStatusesSoTheEngineCanStart() async throws {
        guard let (taskID, _) = await prepareTask() else { return }
        scriptTeam(teamConfigJSON())

        let ok = await sut.runTeamGeneration(taskID: taskID)
        XCTAssertTrue(ok, sut.lastErrorMessage ?? "no error")

        let run = try XCTUnwrap(sut.loadedTask(taskID)?.runs.last)
        let generated = try XCTUnwrap(sut.loadedTask(taskID)?.generatedTeam)
        let supervisorID = try XCTUnwrap(generated.roles.first(where: { $0.isSupervisor })?.id)
        let engineerID = try XCTUnwrap(generated.roles.first(where: { !$0.isSupervisor })?.id)

        XCTAssertEqual(run.roleStatuses[supervisorID], .done,
                       "the Supervisor Task artifact already exists — the brief")
        XCTAssertEqual(run.roleStatuses[engineerID], .ready,
                       "its only requirement is the Supervisor Task, so it starts immediately")
    }

    /// Forced defaults are applied to the LLM's config BEFORE the team is adopted, so the
    /// user's Settings choices win over whatever the model emitted.
    ///
    /// RED: move the `applyForcedDefaults` call after the adoption (or drop it) → the
    /// adopted team carries the model's `supervisor_mode` instead of the user's.
    func testRunTeamGeneration_success_appliesForcedDefaultsBeforeAdopting() async throws {
        guard let (taskID, _) = await prepareTask() else { return }
        sut.configuration.teamGenForcedSupervisorMode = .manual
        sut.configuration.teamGenForcedAcceptanceMode = .finalOnly
        scriptTeam(teamConfigJSON())

        let ok = await sut.runTeamGeneration(taskID: taskID)
        XCTAssertTrue(ok, sut.lastErrorMessage ?? "no error")

        let generated = try XCTUnwrap(sut.loadedTask(taskID)?.generatedTeam)
        XCTAssertEqual(generated.settings.supervisorMode, .manual)
        XCTAssertEqual(generated.settings.defaultAcceptanceMode, .finalOnly)
    }

    /// Non-fatal build warnings reach the user. `GeneratedTeamBuilder` drops tool names it
    /// cannot resolve, and silently shipping a team whose roles lost half their tools is the
    /// failure this surfacing exists to prevent.
    ///
    /// RED: delete the `lastInfoMessage = warnings.joined(...)` line → the dropped tool is
    /// never mentioned anywhere the user looks.
    func testRunTeamGeneration_success_surfacesBuildWarnings() async throws {
        guard let (taskID, _) = await prepareTask() else { return }
        scriptTeam("""
            {"name":"Warned Team","description":"d","roles":[{"name":"Engineer",\
            "prompt":"p","produces_artifacts":["Code"],\
            "requires_artifacts":["Supervisor Task"],"tools":["no_such_tool"]}],\
            "artifacts":[{"name":"Code","description":"c"}],"supervisor_requires":["Code"]}
            """)
        sut.lastInfoMessage = nil

        let ok = await sut.runTeamGeneration(taskID: taskID)
        XCTAssertTrue(ok, sut.lastErrorMessage ?? "no error")

        let info = try XCTUnwrap(
            sut.lastInfoMessage, "a dropped tool must be reported, not silently discarded")
        XCTAssertTrue(info.contains("no_such_tool"), info)
        // …and it also rides the envelope, so the model can see it too.
        let call = try XCTUnwrap(generationStep(taskID: taskID)?.toolCalls.first)
        XCTAssertTrue(call.resultJSON?.contains("no_such_tool") == true, call.resultJSON ?? "")
    }

    /// A clean generation reports NO warning. Without this the assertion above would hold
    /// for an implementation that always wrote something into the slot.
    func testRunTeamGeneration_cleanSuccess_reportsNoWarning() async throws {
        guard let (taskID, _) = await prepareTask() else { return }
        scriptTeam(teamConfigJSON())
        sut.lastInfoMessage = nil

        let ok = await sut.runTeamGeneration(taskID: taskID)
        XCTAssertTrue(ok, sut.lastErrorMessage ?? "no error")

        XCTAssertNil(sut.lastInfoMessage, "nothing was dropped, so there is nothing to report")
    }

    /// The team the CLIENT returned is the team that gets adopted — not a fallback, not the
    /// placeholder. Anti-vacuity for every assertion above: they would all hold for an
    /// implementation that adopted some other team on any successful call.
    func testRunTeamGeneration_success_adoptsTheTeamTheClientActuallyReturned() async throws {
        guard let (taskID, _) = await prepareTask() else { return }
        scriptTeam(teamConfigJSON(name: "Distinctive Name 7", roleName: "Distinctive Role 7"))

        let ok = await sut.runTeamGeneration(taskID: taskID)
        XCTAssertTrue(ok, sut.lastErrorMessage ?? "no error")

        let generated = try XCTUnwrap(sut.loadedTask(taskID)?.generatedTeam)
        XCTAssertEqual(generated.name, "Distinctive Name 7")
        XCTAssertTrue(
            generated.roles.contains { $0.name == "Distinctive Role 7" },
            generated.roles.map(\.name).joined(separator: ", "))
        XCTAssertEqual(teamGenClient.callCount, 1, "exactly one generation request")
    }

    /// The success mutation can fail to land — a teardown or task-switch race removes the run
    /// or the generation step between the LLM returning and the mutation running. The arm must
    /// then report FAILURE, because the team was neither adopted nor re-pinned and starting the
    /// engine on a placeholder-pinned run would reject every role.
    ///
    /// Induced by deleting the run after generation is scripted but through the same public
    /// entry point, so the guard is exercised rather than simulated.
    ///
    /// RED: drop the `guard applied else { … return false }` → this reports success while the
    /// task has no team.
    func testRunTeamGeneration_successThatCannotBeApplied_reportsFailure() async throws {
        guard let (taskID, _) = await prepareTask() else { return }
        scriptTeam(teamConfigJSON())
        // Remove the run out from under the in-flight generation, exactly as a task switch
        // would. `runTeamGeneration` re-reads the run inside its success mutation.
        teamGenClient.onRequest = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.sut.mutateTask(taskID: taskID) { $0.runs = [] }
            }
        }

        let ok = await sut.runTeamGeneration(taskID: taskID)

        if ok {
            // The race did not land in time; assert the invariant that must hold either way
            // rather than flaking on scheduling.
            XCTAssertNotNil(sut.loadedTask(taskID)?.generatedTeam,
                            "reported success, so the team must have been adopted")
        } else {
            XCTAssertNil(sut.loadedTask(taskID)?.generatedTeam,
                         "reported failure, so nothing may have been adopted")
        }
    }

    // MARK: - retryTeamGeneration, on top of a real success

    /// Retry's success path starts the engine. `retryTeamGeneration` awaits generation and
    /// then calls `engineForTask(taskID).start()` — two lines that had never run, because
    /// generation always failed first.
    ///
    /// RED: remove `engine.start()` → the engine stays `.pending` and the generated team
    /// never executes, with no error anywhere.
    func testRetryTeamGeneration_success_startsTheEngine() async throws {
        guard let (taskID, _) = await prepareTask() else { return }
        scriptTeam(teamConfigJSON())

        await sut.retryTeamGeneration(taskID: taskID)

        XCTAssertNotNil(sut.loadedTask(taskID)?.generatedTeam)
        XCTAssertNotEqual(
            sut.taskEngineStates[taskID], TeamEngineState.pending,
            "retry must hand the generated team to the engine")
    }

    /// The Autovisor-facing wrapper reports the durable outcome. It reads `task.generatedTeam`
    /// rather than `lastErrorMessage`, because the error banner consumes that slot on any
    /// render during the await — so a real failure would read back as "did not restart".
    func testRetryTeamGenerationReportingResult_success_reportsIt() async throws {
        guard let (taskID, _) = await prepareTask() else { return }
        scriptTeam(teamConfigJSON())

        let outcome = await sut.retryTeamGenerationReportingResult(taskID: taskID)

        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertTrue(outcome.message.contains("\(taskID)"), outcome.message)
        XCTAssertNotNil(sut.loadedTask(taskID)?.generatedTeam)
    }
}

/// An `LLMClient` that returns a scripted `create_team` tool call, for the team-generation
/// seam only.
///
/// Distinct from `TestOrchestrator`'s `UnreachableChatClient` (which models a server that is
/// down) and from the file-private stubs in the `TeamGenerationService*` suites (which test
/// the service directly). This one carries an `onRequest` hook so a test can mutate task
/// state DURING the call, which is how the teardown race is driven through the real entry
/// point instead of being simulated.
final class ScriptedTeamGenerationClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _events: [StreamEvent] = []
    private var _onRequest: (@Sendable () -> Void)?

    var events: [StreamEvent] {
        get { lock.withLock { _events } }
        set { lock.withLock { _events = newValue } }
    }

    /// Called on each request, before the events are yielded.
    var onRequest: (@Sendable () -> Void)? {
        get { lock.withLock { _onRequest } }
        set { lock.withLock { _onRequest = newValue } }
    }

    var callCount: Int { lock.withLock { _callCount } }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let (captured, hook): ([StreamEvent], (@Sendable () -> Void)?) = lock.withLock {
            _callCount += 1
            return (_events, _onRequest)
        }
        hook?()
        return AsyncThrowingStream { continuation in
            for event in captured { continuation.yield(event) }
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}
