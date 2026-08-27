import XCTest

@testable import NanoTeams

/// `resumeRun` on a task whose team generation never completed.
///
/// Before this suite, `resumeRun` never consulted `needsTeamGeneration`: it fell through
/// to `engineForTask(taskID).start()` on the Generated Team placeholder's Supervisor-only
/// roster, where `Run.activeWorkRoleIDs` is trivially empty and the chat-mode
/// auto-complete arm retired the run `.done` with no team ever generated — after which
/// `TeamBoardRunControl.select` returns `nil` and the user has no toolbar control at all.
///
/// ## How this stays offline
///
/// Same lever `RunTeamGenerationFlowTests` documents: an EMPTY base URL on `.ollama`, so
/// `streamChat` throws `LLMClientError.invalidBaseURL` before any `URLSession` work.
/// Generation therefore always fails in transport, which is exactly what we want — the
/// assertions are about whether generation was ENTERED, not about its result.
@MainActor
final class ResumeTeamGenerationTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - The fix

    /// The headline. Resume must re-enter generation rather than hand the placeholder
    /// roster to the engine.
    func testResumeRun_onATaskNeedingGeneration_reEntersGenerationInsteadOfRetiringTheRun() async {
        guard let (taskID, _) = await prepareGeneratedTeamTask() else { return }

        await sut.resumeRun(taskID: taskID)
        XCTAssertTrue(
            sut.isGeneratingTeam(taskID: taskID),
            "the reserve is taken synchronously, so it is already visible here")
        await drainGeneration(taskID: taskID)

        XCTAssertNotEqual(
            sut.taskEngineStates[taskID], .done,
            "the run must not be retired with no team generated")
        XCTAssertNil(sut.loadedTask(taskID)?.generatedTeam, "transport failed, so nothing adopted")
        XCTAssertEqual(
            generationSteps(taskID: taskID).count, 1,
            "exactly one generation attempt is recorded")
        XCTAssertEqual(generationSteps(taskID: taskID).first?.status, .failed)
    }

    /// The user's live shape: `restartRole` emptied the synthetic step to `.pending` with
    /// no tool calls, leaving a phantom `roleStatuses` key. Resume replaces it with a
    /// fresh attempt rather than stacking a second card beside the wedged one.
    func testResumeRun_onAWedgedPendingGenerationStep_replacesItWithAFreshAttempt() async {
        guard let (taskID, _) = await prepareGeneratedTeamTask() else { return }
        let wedgedID = "\(StepExecution.teamGenerationIDPrefix)WEDGED"
        await sut.mutateTask(taskID: taskID) { task in
            guard let ri = task.runs.indices.last else { return }
            task.runs[ri].steps.append(
                StepExecution(
                    id: wedgedID, role: .supervisor, title: "Generate Team", status: .pending))
            task.runs[ri].roleStatuses[wedgedID] = .idle
        }

        await sut.resumeRun(taskID: taskID)
        await drainGeneration(taskID: taskID)

        let steps = generationSteps(taskID: taskID)
        XCTAssertEqual(steps.count, 1, "the destroyed record is replaced, not stacked")
        XCTAssertNotEqual(steps.first?.id, wedgedID)
    }

    /// A cancelled generation leaves a `.paused` step carrying "Team generation was
    /// cancelled". Resume must not leave two `create_team` cards behind — that is what
    /// makes `retryTeamGenerationReportingResult` blame the wrong attempt.
    func testResumeRun_onACancelledPausedGeneration_replacesTheStaleCard() async {
        guard let (taskID, _) = await prepareGeneratedTeamTask() else { return }
        await appendGenerationStep(
            taskID: taskID, id: "\(StepExecution.teamGenerationIDPrefix)CANCELLED",
            status: .paused, message: "Team generation was cancelled")

        await sut.resumeRun(taskID: taskID)
        await drainGeneration(taskID: taskID)

        let steps = generationSteps(taskID: taskID)
        XCTAssertEqual(steps.count, 1)
        XCTAssertFalse(
            steps.first?.toolCalls.first?.errorMessage?.contains("cancelled") ?? false,
            "the surviving card belongs to the new attempt")
    }

    // MARK: - Placement

    /// The branch sits BELOW the `closedAt` guard: a closed task is terminal and must
    /// never spend an LLM call being revived.
    func testResumeRun_onAClosedGeneratedTeamTask_doesNothing() async {
        guard let (taskID, _) = await prepareGeneratedTeamTask() else { return }
        await sut.mutateTask(taskID: taskID) { $0.closedAt = MonotonicClock.shared.now() }

        await sut.resumeRun(taskID: taskID)

        XCTAssertFalse(sut.isGeneratingTeam(taskID: taskID))
        XCTAssertTrue(generationSteps(taskID: taskID).isEmpty)
    }

    /// The gate is `needsTeamGeneration`, not "the template is generated" — a task that
    /// already adopted a team resumes normally.
    func testResumeRun_afterAdoption_doesNotReEnterGeneration() async {
        guard let (taskID, _) = await prepareGeneratedTeamTask() else { return }
        let adopted = TeamTemplateFactory.startup()
        await sut.mutateTask(taskID: taskID) { $0.adoptGeneratedTeam(adopted) }
        XCTAssertFalse(sut.needsTeamGeneration(taskID: taskID), "precondition")

        await sut.resumeRun(taskID: taskID)

        XCTAssertFalse(sut.isGeneratingTeam(taskID: taskID))
        XCTAssertTrue(generationSteps(taskID: taskID).isEmpty)
    }

    /// The branch sits BELOW the child cascade, so a parent that needs generation still
    /// resumes its delegated children first. Hoisting it above would silently change
    /// cascade semantics.
    func testResumeRun_stillCascadesToChildrenBeforeReturning() async {
        guard let (parentID, _) = await prepareGeneratedTeamTask() else { return }
        guard let childID = await sut.createDelegatedTask(
            parentTaskID: parentID, parentRoleID: "some_role", title: "Child",
            supervisorTask: "sub-work", preferredTeamID: nil, depth: 1)
        else { XCTFail("child createTask returned nil"); return }
        // `resumeRun` bails on a task with no runs, so the child needs one for the
        // cascade to be observable at all.
        await sut.mutateTask(taskID: childID) { task in
            task.runs = [Run(id: 0)]
            task.status = .paused
        }
        // The resume cascade is filtered on `hasWaiters` (2026-08-25): a child nothing awaits
        // is an orphan left by a restart, and reviving it burns LLM cycles for no one. This
        // test's subject is the ORDERING of the generation branch against the cascade, so the
        // fixture has to be a child the cascade actually visits — otherwise it would assert
        // the very behaviour the filter removed.
        let handler = await registerSuspendedDelegationHandler(on: sut, childID: childID)
        defer { sut.completionAwaiter.cancelAll(taskID: childID); handler.cancel() }

        await sut.resumeRun(taskID: parentID)
        await drainGeneration(taskID: parentID)

        XCTAssertNotEqual(
            sut.loadedTask(childID)?.status, .paused,
            "the child's recovery latch is cleared by its own resume pass")
    }

    // MARK: - Re-entrancy

    /// `spawnTeamGeneration` reserves synchronously, so a second resume in the same tick
    /// is refused — and the caller must NOT fall through to its own engine start.
    func testResumeRun_whileAGenerationIsAlreadyReserved_doesNotSpawnASecond() async {
        guard let (taskID, _) = await prepareGeneratedTeamTask() else { return }
        XCTAssertTrue(sut.beginTeamGeneration(taskID: taskID), "hand-take the reserve")
        defer { sut.endTeamGeneration(taskID: taskID) }

        await sut.resumeRun(taskID: taskID)

        XCTAssertTrue(generationSteps(taskID: taskID).isEmpty, "no second attempt was injected")
        XCTAssertNil(sut.taskEngineStates[taskID], "and no engine was started behind its back")
    }

    // MARK: - The engine must refuse a task whose team isn't ready

    /// `TaskEngineStoreAdapter.resolvedTeam` is the engine's single team-resolution point.
    /// Without this clause it resolves the Generated Team PLACEHOLDER — a Supervisor-only
    /// roster where `Run.activeWorkRoleIDs` is trivially empty, so the chat-mode
    /// auto-complete arm retires the run `.done` with no team ever generated. Covers every
    /// engine entry at once (the `restartRole` wake, `notifyExternalEvent`, recurrence,
    /// the queued-message backstop), not just resume.
    func testEngineAdapter_whileTeamGenerationIsOutstanding_refusesToResolveATeam() async {
        guard let (taskID, _) = await prepareGeneratedTeamTask() else { return }
        let adapter = TaskEngineStoreAdapter(orchestrator: sut, taskID: taskID)

        XCTAssertNil(
            adapter.activeTeam,
            "the placeholder roster must not be handed to the engine")
        XCTAssertEqual(
            adapter.teamSettings, .default,
            "settings fall back rather than borrowing the placeholder's")
        XCTAssertTrue(
            sut.lastErrorMessage?.localizedCaseInsensitiveContains("team generation") ?? false,
            "the refusal is loud — nil alone would look like a deleted team")
    }

    /// Once a team is adopted the guard is inert and the engine resolves normally.
    func testEngineAdapter_afterAdoption_resolvesTheGeneratedTeam() async {
        guard let (taskID, _) = await prepareGeneratedTeamTask() else { return }
        let adopted = TeamTemplateFactory.startup()
        await sut.mutateTask(taskID: taskID) { $0.adoptGeneratedTeam(adopted) }

        let adapter = TaskEngineStoreAdapter(orchestrator: sut, taskID: taskID)
        XCTAssertEqual(adapter.activeTeam?.id, adopted.id)
    }

    // MARK: - The Autovisor's control_task resume

    /// `reportingError` reports `ok:true` whenever no *error* surfaces, and both of the
    /// retry path's silent exits set `lastInfoMessage` — so routing a generation-blocked
    /// task through it would report a resume that regenerated nothing. It would also let
    /// `retryTeamGeneration` delete the `create_team` record before any precondition
    /// check, which is exactly what `manage_role`'s own guard exists to prevent.
    func testAutovisorControlTaskResume_onAGenerationBlockedTask_reportsTheRealOutcome() async {
        guard let (taskID, _) = await prepareGeneratedTeamTask() else { return }

        let result = await sut.performAutovisorAction(
            .controlTask(taskID: taskID, verb: .resume))

        XCTAssertFalse(
            result.ok,
            "transport failed, so the honest answer is failure — not \"Resumed task #N.\"")
        XCTAssertFalse(
            result.message.localizedCaseInsensitiveContains("resumed"),
            "the message must describe generation, not a resume: \(result.message)")
    }

    /// Non-regression: an ordinary task still routes through the plain resume wrapper.
    func testAutovisorControlTaskResume_onAnOrdinaryTask_stillReportsResumed() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Plain", supervisorTask: "do") else {
            XCTFail("createTask returned nil"); return
        }
        await sut.mutateTask(taskID: taskID) { $0.runs = [Run(id: 0)] }

        let result = await sut.performAutovisorAction(
            .controlTask(taskID: taskID, verb: .resume))

        XCTAssertTrue(result.ok, result.message)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("resumed"), result.message)
    }

    // MARK: - Helpers

    /// Points the global LLM config at an endpoint that cannot even build a URL, so
    /// `streamChat` throws `invalidBaseURL` before any `URLSession` work. Order is
    /// load-bearing: `llmProvider.didSet` restores the incoming provider's remembered
    /// (URL, model) pair, so clearing the URL first would be undone by the provider flip.
    private func pinUnreachableEndpoint() {
        sut.configuration.llmProvider = .ollama
        sut.configuration.llmBaseURLString = ""
    }

    private func prepareGeneratedTeamTask() async -> (taskID: Int, templateID: NTMSID)? {
        await sut.openWorkFolder(tempDir)
        pinUnreachableEndpoint()
        await sut.mutateWorkFolder { project in
            guard !project.teams.contains(where: { $0.isGeneratedPlaceholder }) else { return }
            project.teams.append(TeamTemplateFactory.generatedTeam())
        }
        guard let template = sut.workFolder?.teams.first(where: { $0.isGeneratedPlaceholder }) else {
            XCTFail("expected the Generated Team placeholder after seeding"); return nil
        }
        guard let taskID = await sut.createTask(
            title: "Gen", supervisorTask: "build a calculator", preferredTeamID: template.id)
        else { XCTFail("createTask returned nil"); return nil }
        // `createTask` does not create a run, but every path into `runTeamGeneration` does.
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: template.id)
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
        XCTAssertTrue(
            sut.needsTeamGeneration(taskID: taskID),
            "precondition: on the Generated Team template with no team yet")
        return (taskID, template.id)
    }

    /// Awaits the detached generation Task `spawnTeamGeneration` registered, so assertions
    /// see its terminal state rather than racing it.
    private func drainGeneration(taskID: Int) async {
        await sut.teamGenerationTasks[taskID]?.value
    }

    private func appendGenerationStep(
        taskID: Int, id: String, status: StepStatus, message: String
    ) async {
        await sut.mutateTask(taskID: taskID) { task in
            guard let ri = task.runs.indices.last else { return }
            task.runs[ri].steps.append(
                StepExecution(
                    id: id, role: .supervisor, title: "Generate Team", status: status,
                    toolCalls: [
                        StepToolCall(
                            name: ToolNames.createTeam, argumentsJSON: "{}",
                            resultJSON:
                            #"{"ok":false,"error":{"code":"GENERATION_FAILED","message":"\#(message)"}}"#,
                            isError: true)
                    ]))
        }
    }

    private func generationSteps(taskID: Int) -> [StepExecution] {
        (sut.loadedTask(taskID)?.runs.last?.steps ?? []).filter(\.isTeamGenerationStep)
    }
}
