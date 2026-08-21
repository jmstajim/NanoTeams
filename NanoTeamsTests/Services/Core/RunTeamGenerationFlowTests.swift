import XCTest

@testable import NanoTeams

/// `NTMSOrchestrator+TeamGeneration` — the parts of the flow that only run once
/// `runTeamGeneration` is actually ENTERED.
///
/// `TeamGenerationOrchestratorTests` covers the extracted success arm
/// (`applyGeneratedTeamSuccess`), the envelope/spinner substring contract and the
/// concurrency reserve; `TeamGenerationRetryReportingTests` covers the two refusal
/// arms of `retryTeamGenerationReportingResult`. This suite drives the body itself:
/// the two entry guards, the synthetic `team_generation_*` Supervisor step that gets
/// injected, the failure arm that flips that step's placeholder envelope to
/// `{ok:false,…}`, and the `retryTeamGeneration` /
/// `retryTeamGenerationReportingResult` arms that sit on top of a real (failed)
/// generation rather than a hand-seeded one.
///
/// ## How this stays offline
///
/// A `teamGenerationClient` seam now exists on the orchestrator, and
/// `RunTeamGenerationSuccessTests` uses it to drive the arms listed as unreachable at
/// the bottom of this comment. This suite keeps the empty-base-URL lever because what
/// it needs is a *transport failure*, and an unreachable endpoint is a more faithful
/// model of one than a client that throws on command.
///
/// The deterministic, network-free substitute is an **empty
/// base URL**: both provider clients open with
/// `guard let baseURL = URL(string: config.baseURLString)` and throw
/// `LLMClientError.invalidBaseURL` before any `URLSession` work. That is the same
/// lever `LLMClientRouterTests` already uses to prove routing ("An empty baseURL
/// triggers invalidBaseURL"), so it is a pinned property of this codebase rather
/// than an assumption about Foundation's URL parsing.
///
/// `.ollama` is chosen over `.lmStudio` deliberately: `OllamaClient.streamChat` does
/// not bracket the request in `ChatModelEnsurer`'s process-global request census
/// (`LLMProvider.managesModelResidency == false`), so a suite running in parallel
/// with the residency suites touches nothing shared at all.
///
/// **Not covered here, and why**: the `.success` arm of `runTeamGeneration` moved to
/// `RunTeamGenerationSuccessTests` once the client seam existed. What remains out of
/// reach is the `isCancellation` fork of the failure arm (step `.paused`, no error
/// banner): it needs a `CancellationError` out of the stream, which cannot be produced
/// deterministically against a URL that fails before the stream ever yields — racing a
/// `Task.cancel()` against the producer would be a flake, not a pin.
@MainActor
final class RunTeamGenerationFlowTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - Entry guards

    /// The description guard fires BEFORE the placeholder step is injected. A refusal
    /// must therefore leave no `create_team` card behind — a task that never had a
    /// description would otherwise accumulate a permanently-`.running` spinner step
    /// (nothing later in the function runs to finalize it).
    func testRunTeamGeneration_emptyBrief_refusesBeforeInjectingAStep() async {
        await sut.openWorkFolder(tempDir)
        pinUnreachableEndpoint()
        guard let taskID = await sut.createTask(title: "Gen", supervisorTask: "") else {
            XCTFail("createTask returned nil"); return
        }
        await seedRun(taskID: taskID, teamID: NTMSID.from(name: "Generated Team"))
        XCTAssertEqual(
            sut.loadedTask(taskID)?.effectiveSupervisorBrief, "",
            "precondition: there is nothing to generate a team from")

        sut.lastErrorMessage = nil
        let ok = await sut.runTeamGeneration(taskID: taskID)

        XCTAssertFalse(ok)
        XCTAssertTrue(
            sut.lastErrorMessage?.contains("without a task description") == true,
            "expected the description refusal, got: \(sut.lastErrorMessage ?? "nil")")
        XCTAssertTrue(
            generationSteps(taskID: taskID).isEmpty,
            "the guard runs before step injection — a refused generation must leave no card")
        XCTAssertNil(sut.loadedTask(taskID)?.generatedTeam)
    }

    /// `effectiveSupervisorBrief` trims, and the guard trims again. A whitespace-only
    /// brief must reach the same refusal rather than spending an LLM round-trip on a
    /// prompt whose `Task:` section is blank.
    func testRunTeamGeneration_whitespaceOnlyBrief_isRefusedLikeAnEmptyOne() async {
        await sut.openWorkFolder(tempDir)
        pinUnreachableEndpoint()
        guard let taskID = await sut.createTask(title: "Gen", supervisorTask: "   \n\t  ")
        else { XCTFail("createTask returned nil"); return }
        await seedRun(taskID: taskID, teamID: NTMSID.from(name: "Generated Team"))

        sut.lastErrorMessage = nil
        let ok = await sut.runTeamGeneration(taskID: taskID)

        XCTAssertFalse(ok)
        XCTAssertTrue(
            sut.lastErrorMessage?.contains("without a task description") == true,
            "expected the description refusal, got: \(sut.lastErrorMessage ?? "nil")")
        XCTAssertTrue(generationSteps(taskID: taskID).isEmpty)
    }

    /// The step injection is `guard let ri = task.runs.indices.last else { return }`
    /// INSIDE the `mutateTask` closure, and `mutateTask` reports "persisted", not
    /// "the closure did something" (CLAUDE.md §7). So with no run the step was
    /// silently dropped while the function carried on and spent the multi-second,
    /// billable LLM call — landing its result on a card that does not exist, with
    /// no spinner and no Retry affordance. The user saw a task that did nothing.
    func testRunTeamGeneration_taskWithNoRun_refusesBeforeSpendingTheLLMCall() async {
        await sut.openWorkFolder(tempDir)
        pinUnreachableEndpoint()
        guard let taskID = await sut.createTask(title: "Gen", supervisorTask: "Build a CLI")
        else { XCTFail("createTask returned nil"); return }

        XCTAssertTrue(
            sut.loadedTask(taskID)?.runs.isEmpty == true,
            "precondition: this test deliberately does NOT seed a run")

        sut.lastErrorMessage = nil
        let ok = await sut.runTeamGeneration(taskID: taskID)

        XCTAssertFalse(ok, "a generation with nowhere to put its step must report failure")
        XCTAssertTrue(
            sut.lastErrorMessage?.contains("no run") == true,
            "expected the missing-run refusal, got: \(sut.lastErrorMessage ?? "nil")")
        XCTAssertTrue(
            generationSteps(taskID: taskID).isEmpty,
            "nothing was attached, which is exactly why the call must not proceed")
        XCTAssertNil(sut.loadedTask(taskID)?.generatedTeam)
    }

    // MARK: - The step `runTeamGeneration` injects

    /// Step 1 of the flow: exactly one Supervisor-attributed `team_generation_*` step
    /// carrying a single `create_team` call whose ARGUMENTS are the brief that was
    /// actually sent. Quotes / newlines / non-ASCII are in the fixture because
    /// `makeGenerationArgsJSON` hand-builds this payload through `JSONSerialization`
    /// and the card renders it verbatim.
    func testRunTeamGeneration_injectsOneSupervisorStep_carryingTheBriefAsArguments() async {
        let brief = "Ship a \"tiny\" CLI\nwith tests — и документацию"
        guard let prepared = await prepareGeneratedTeamTask(brief: brief) else { return }
        let taskID = prepared.taskID
        let updatedBefore = sut.loadedTask(taskID)?.runs.last?.updatedAt

        _ = await sut.runTeamGeneration(taskID: taskID)

        let steps = generationSteps(taskID: taskID)
        XCTAssertEqual(steps.count, 1, "exactly one synthetic step per attempt")
        guard let step = steps.first else { return }
        XCTAssertTrue(
            step.id.hasPrefix(StepExecution.teamGenerationIDPrefix),
            "the id namespace is what `resolveManagedRoleStep` and the retry cleanup key on")
        XCTAssertEqual(step.role, .supervisor, "generation is Supervisor-attributed, like analyze_image")
        XCTAssertEqual(step.title, "Generate Team")

        XCTAssertEqual(step.toolCalls.count, 1)
        guard let call = step.toolCalls.first else { return }
        XCTAssertEqual(call.name, ToolNames.createTeam)
        guard let args = Self.jsonObject(call.argumentsJSON) else {
            XCTFail("the placeholder arguments must be valid JSON: \(call.argumentsJSON)"); return
        }
        XCTAssertEqual(
            args["task"] as? String, brief,
            "the card must show the exact brief that was sent, quotes and newlines included")

        if let updatedBefore, let updatedAfter = sut.loadedTask(taskID)?.runs.last?.updatedAt {
            XCTAssertGreaterThan(
                updatedAfter, updatedBefore,
                "both the injection and the completion arm bump the run's timestamp")
        } else {
            XCTFail("expected a run timestamp before and after the attempt")
        }
    }

    // MARK: - Failure arm

    /// The `.failure` closure: the placeholder envelope is replaced with
    /// `{ok:false,error:{…}}`, the call is flagged, and the step is finalized `.failed`
    /// with a completion timestamp. If the envelope were left as-is the graph's
    /// `NTMSLoader` would spin forever, which is exactly what `isGeneratingTeam` reads.
    func testRunTeamGeneration_transportFailure_finalizesTheStepAsFailedWithADiagnosis() async {
        guard let prepared = await prepareGeneratedTeamTask() else { return }
        let taskID = prepared.taskID

        sut.lastErrorMessage = nil
        let ok = await sut.runTeamGeneration(taskID: taskID)

        XCTAssertFalse(ok, "a failed generation must not report success")

        guard let step = generationSteps(taskID: taskID).first else {
            XCTFail("expected the synthetic generation step"); return
        }
        XCTAssertEqual(step.status, .failed)
        XCTAssertNotNil(step.completedAt, "a finalized step carries a completion timestamp")

        guard let call = step.toolCalls.first else {
            XCTFail("expected the create_team call"); return
        }
        XCTAssertEqual(call.isError, true)
        XCTAssertFalse(
            call.isGeneratingTeam,
            "the generating placeholder must be replaced, or the graph spinner never stops")

        // `StepToolCall.errorMessage` is the single reader shared by the graph panel's
        // retry overlay and the Autovisor's `task_status.last_error`.
        guard let reason = call.errorMessage else {
            XCTFail("the failure envelope must carry a diagnosable message: \(call.resultJSON ?? "nil")")
            return
        }
        XCTAssertFalse(
            reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "a whitespace-only message reads as no diagnosis at all")
        XCTAssertEqual(
            reason, sut.lastErrorMessage,
            "the banner and the card must show the same diagnosis")
    }

    /// Adoption and the `run.teamID` re-pin belong to the SUCCESS arm only. After a
    /// failure the task must still look exactly like one that needs generation, or the
    /// Retry affordance (and `retryTeamGenerationReportingResult`'s precondition)
    /// disappears with nothing to replace it.
    func testRunTeamGeneration_transportFailure_adoptsNothingAndLeavesTheRunPinned() async {
        guard let prepared = await prepareGeneratedTeamTask() else { return }
        let taskID = prepared.taskID

        let ok = await sut.runTeamGeneration(taskID: taskID)

        XCTAssertFalse(ok)
        XCTAssertNil(
            sut.loadedTask(taskID)?.generatedTeam,
            "a failed generation must not adopt a team")
        XCTAssertEqual(
            sut.loadedTask(taskID)?.runs.last?.teamID, prepared.templateID,
            "the re-pin is the success arm's job — a failure leaves the placeholder pin alone")
        XCTAssertTrue(
            sut.needsTeamGeneration(taskID: taskID),
            "the task still needs generation, so Retry stays available")
        XCTAssertFalse(
            sut.isGeneratingTeam(taskID: taskID),
            "runTeamGeneration does not reserve the slot itself; nothing may leak")
    }

    // MARK: - retryTeamGeneration

    /// The cleanup matches on the `team_generation_` id PREFIX, never on
    /// `toolCalls.contains { name == create_team }`. `handleDelegateToTeam`'s generated
    /// branch appends exactly such a placeholder to the DELEGATING ROLE's own step, so
    /// a name-based match would delete a whole role's step — its conversation,
    /// scratchpad, artifacts and `delegationChildIDs` audit trail with it.
    func testRetryTeamGeneration_keepsADelegatingRoleStepThatCarriesACreateTeamCall() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "T", supervisorTask: "delegate it") else {
            XCTFail("createTask returned nil"); return
        }
        let syntheticID = "\(StepExecution.teamGenerationIDPrefix)PRIOR"
        let roleStepID = "coding_agent"

        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: NTMSID.from(name: "Coding Agent"))
            run.steps = [
                StepExecution(
                    id: syntheticID, role: .supervisor, title: "Generate Team", status: .failed,
                    toolCalls: [
                        StepToolCall(
                            name: ToolNames.createTeam, argumentsJSON: "{}",
                            resultJSON: #"{"ok":false,"error":{"message":"prior failure"}}"#,
                            isError: true)
                    ]),
                // The delegating role mid-`delegate_to_team(team_id: "generated")`.
                StepExecution(
                    id: roleStepID, role: .custom(id: roleStepID), title: "Coding Agent",
                    status: .running,
                    toolCalls: [
                        StepToolCall(
                            name: ToolNames.createTeam, argumentsJSON: #"{"task":"sub-task"}"#,
                            resultJSON: NTMSOrchestrator._testGeneratingEnvelope(), isError: false)
                    ],
                    scratchpad: "notes that must survive",
                    delegationChildIDs: [7]),
            ]
            task.runs = [run]
        }

        // `preferredTeamID` is nil, so `needsTeamGeneration` short-circuits AFTER the
        // cleanup mutation — no LLM work, and the cleanup is what this test is about.
        await sut.retryTeamGeneration(taskID: taskID)

        let steps = sut.loadedTask(taskID)?.runs.last?.steps ?? []
        XCTAssertFalse(
            steps.contains { $0.id == syntheticID },
            "the synthetic generation step is removed before a retry")
        guard let survivor = steps.first(where: { $0.id == roleStepID }) else {
            XCTFail(
                "the delegating role's step must survive — a create_team NAME match would delete it")
            return
        }
        XCTAssertEqual(steps.count, 1, "only the synthetic step is removed")
        XCTAssertEqual(survivor.scratchpad, "notes that must survive")
        XCTAssertEqual(survivor.delegationChildIDs, [7], "the delegation audit trail survives")
        XCTAssertEqual(survivor.toolCalls.count, 1)
        XCTAssertEqual(survivor.status, .running)
    }

    /// End-to-end: cleanup, then a fresh (failing) attempt. The prior card must be gone
    /// and the surviving one must belong to THIS attempt — a stacked pair, or a
    /// surviving prior card, is what makes `retryTeamGenerationReportingResult` blame
    /// the wrong attempt. And `guard generated else { return }` means no engine starts.
    func testRetryTeamGeneration_replacesThePriorFailedStep_andStartsNoEngine() async {
        guard let prepared = await prepareGeneratedTeamTask() else { return }
        let taskID = prepared.taskID
        let priorID = await appendGenerationStep(
            taskID: taskID, id: "\(StepExecution.teamGenerationIDPrefix)PRIOR",
            status: .failed, message: "prior failure")

        await sut.retryTeamGeneration(taskID: taskID)

        let steps = generationSteps(taskID: taskID)
        XCTAssertEqual(
            steps.count, 1, "cleanup removes the prior attempt before the new one is injected")
        XCTAssertNotEqual(steps.first?.id, priorID, "the surviving card belongs to this attempt")
        XCTAssertEqual(steps.first?.status, .failed)
        XCTAssertFalse(
            steps.first?.toolCalls.first?.errorMessage?.contains("prior failure") ?? false,
            "the new card must carry this attempt's diagnosis, not the previous one's")
        XCTAssertNil(
            sut.taskEngines[taskID],
            "`guard generated else { return }` — a failed retry must not start the engine")
        XCTAssertFalse(
            sut.isGeneratingTeam(taskID: taskID), "the reserve is released by the defer")
    }

    // MARK: - retryTeamGenerationReportingResult

    /// The "failed again" arm, reached through a REAL failed retry rather than a
    /// hand-seeded step. The reported reason must be the one recorded on the step's own
    /// tool call — that durable read is the whole point: `lastErrorMessage` is a
    /// single-shot slot the error banner nils on any render during the await.
    func testReportingResult_afterAFailedRetry_reportsTheDurableStepsError() async {
        guard let prepared = await prepareGeneratedTeamTask() else { return }
        let taskID = prepared.taskID

        let result = await sut.retryTeamGenerationReportingResult(taskID: taskID)

        XCTAssertFalse(result.ok, result.message)
        XCTAssertTrue(result.message.contains("failed again"), result.message)
        XCTAssertFalse(result.message.contains("did not restart"), result.message)
        guard let recorded = generationSteps(taskID: taskID).last?.toolCalls.last?.errorMessage
        else {
            XCTFail("expected a recorded failure reason on the step"); return
        }
        XCTAssertTrue(
            result.message.contains(recorded),
            "the reported reason must be the one on the step: \(result.message)")
    }

    /// "Did it START?" is asked before "did it FAIL?", and the two must not be
    /// confusable. Here the retry genuinely runs — cleanup removes the prior card — but
    /// `runTeamGeneration` refuses at its description guard and leaves nothing behind,
    /// so the only honest answer is "did not restart". Reporting the (now-deleted)
    /// prior failure would blame this call for a failure it never produced.
    func testReportingResult_whenGenerationNeverStarted_reportsDidNotRestart() async {
        await sut.openWorkFolder(tempDir)
        pinUnreachableEndpoint()
        await seedGeneratedTemplate()
        guard let template = generatedTemplate() else { return }
        // An EMPTY brief is the one way a retry can run to completion and produce no
        // step at all (`runTeamGeneration` bails before injecting one).
        guard let taskID = await sut.createTask(
            title: "Gen", supervisorTask: "", preferredTeamID: template.id)
        else { XCTFail("createTask returned nil"); return }
        await seedRun(taskID: taskID, teamID: template.id)
        await appendGenerationStep(
            taskID: taskID, id: "\(StepExecution.teamGenerationIDPrefix)PRIOR",
            status: .failed, message: "prior failure")
        XCTAssertTrue(sut.needsTeamGeneration(taskID: taskID), "precondition: a pending generation")

        let result = await sut.retryTeamGenerationReportingResult(taskID: taskID)

        XCTAssertFalse(result.ok, result.message)
        XCTAssertTrue(result.message.contains("did not restart"), result.message)
        XCTAssertFalse(
            result.message.contains("failed again"),
            "the deleted prior attempt must not be reported as this call's failure: \(result.message)")
        XCTAssertTrue(
            generationSteps(taskID: taskID).isEmpty,
            "cleanup ran; there is simply nothing new to report on")
    }

    /// A `preferredTeamID` that no longer resolves is not a pending generation, so the
    /// destructive retry must be refused up front — and the refusal must leave the
    /// `create_team` record intact, since it is the only account of how the team was
    /// produced.
    func testReportingResult_whenPreferredTeamWasDeleted_refusesAndPreservesTheRecord() async {
        await sut.openWorkFolder(tempDir)
        await seedGeneratedTemplate()
        guard let template = generatedTemplate() else { return }
        guard let taskID = await sut.createTask(
            title: "Gen", supervisorTask: "build something", preferredTeamID: template.id)
        else { XCTFail("createTask returned nil"); return }
        await seedRun(taskID: taskID, teamID: template.id)
        let recordID = await appendGenerationStep(
            taskID: taskID, id: "\(StepExecution.teamGenerationIDPrefix)RECORD",
            status: .failed, message: "the only record")
        XCTAssertTrue(sut.needsTeamGeneration(taskID: taskID), "precondition: a pending generation")

        await sut.mutateWorkFolder { project in
            project.teams.removeAll { $0.templateID == "generated" }
        }
        XCTAssertFalse(
            sut.needsTeamGeneration(taskID: taskID),
            "a preferredTeamID that no longer resolves is not a pending generation")

        let result = await sut.retryTeamGenerationReportingResult(taskID: taskID)

        XCTAssertFalse(result.ok, result.message)
        XCTAssertTrue(result.message.contains("no pending team generation"), result.message)
        XCTAssertEqual(
            generationSteps(taskID: taskID).map(\.id), [recordID],
            "a refused retry must be non-destructive")
    }

    // MARK: - Envelopes on the generation path

    /// `makeGenerationArgsJSON` hand-builds the payload the card renders. Its fallback
    /// is a bare `{}` that would silently drop the brief, so pin that real content —
    /// including the characters JSON has to escape — round-trips.
    func testGenerationArgs_encodeTheBriefAsJSON_whateverItContains() async {
        let brief = "Ship a \"tiny\" CLI\nwith \\ backslashes, tabs\tand Юникод"
        let json = TeamGenerationEnvelopes.makeGenerationArgsJSON(taskDescription: brief)
        guard let dict = Self.jsonObject(json) else {
            XCTFail("the placeholder arguments must be valid JSON: \(json)"); return
        }
        XCTAssertEqual(dict["task"] as? String, brief)

        // Degenerate input still produces a parseable object rather than the `{}` fallback.
        let empty = TeamGenerationEnvelopes.makeGenerationArgsJSON(taskDescription: "")
        XCTAssertEqual(Self.jsonObject(empty)?["task"] as? String, "")
    }

    /// `GeneratedTeamBuilder` reports non-fatal issues (dropped tool names, an
    /// LLM-emitted Supervisor) as warnings, and the success envelope is the only place
    /// they reach the activity feed. Also pins the role count, which deliberately
    /// EXCLUDES the auto-added Supervisor.
    func testApplyGeneratedTeamSuccess_withWarnings_putsThemOnTheCardBesideTheRoleCount() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "Gen", supervisorTask: "build") else {
            XCTFail("createTask returned nil"); return
        }
        let stepID = "\(StepExecution.teamGenerationIDPrefix)WARN"
        let toolCallID = UUID()
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: NTMSID.from(name: "Generated Team"))
            run.steps = [
                StepExecution(
                    id: stepID, role: .supervisor, title: "Generate Team", status: .running,
                    toolCalls: [
                        StepToolCall(
                            id: toolCallID, name: ToolNames.createTeam, argumentsJSON: "{}",
                            resultJSON: NTMSOrchestrator._testGeneratingEnvelope(), isError: false)
                    ])
            ]
            task.runs = [run]
        }

        // Two roles → one non-Supervisor role in the envelope's count.
        let genTeam = Team(
            id: NTMSID.from(name: "gen_\(UUID().uuidString)"), name: "Gen Team", description: "",
            roles: [
                TeamRoleDefinition(
                    id: "gen_sup", name: "Supervisor", prompt: "", toolIDs: [],
                    usePlanningPhase: false, dependencies: RoleDependencies()),
                TeamRoleDefinition(
                    id: "gen_worker", name: "Worker", prompt: "", toolIDs: [],
                    usePlanningPhase: false, dependencies: RoleDependencies()),
            ],
            artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())
        let warnings = ["Dropped unknown tool 'nope'.", "Ignored an LLM-emitted Supervisor role."]

        let applied = await sut.applyGeneratedTeamSuccess(
            taskID: taskID, team: genTeam, stepID: stepID, toolCallID: toolCallID,
            warnings: warnings)

        XCTAssertTrue(applied)
        guard let call = sut.loadedTask(taskID)?.runs.last?.steps.first?.toolCalls.first,
              let resultJSON = call.resultJSON,
              let dict = Self.jsonObject(resultJSON),
              let data = dict["data"] as? [String: Any]
        else {
            XCTFail("expected a `{ok:true,data:{…}}` success envelope on the card"); return
        }
        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(data["status"] as? String, "created")
        XCTAssertEqual(
            data["warnings"] as? [String], warnings,
            "build warnings must reach the activity-feed card")
        XCTAssertEqual(
            data["roles"] as? String, "1",
            "the reported role count excludes the auto-added Supervisor")
        XCTAssertEqual(call.isError, false)
        XCTAssertFalse(
            call.isGeneratingTeam,
            "a warnings-bearing success must still clear the spinner")
    }

    // MARK: - Helpers

    /// Points the global LLM config at an endpoint that cannot even build a URL, so
    /// `streamChat` throws `invalidBaseURL` before any `URLSession` work.
    ///
    /// Order is load-bearing: `llmProvider.didSet` restores the incoming provider's
    /// remembered (URL, model) pair, so clearing the URL first would be undone by the
    /// provider flip.
    private func pinUnreachableEndpoint() {
        sut.configuration.llmProvider = .ollama
        sut.configuration.llmBaseURLString = ""
    }

    /// Appends the Generated Team placeholder to the work folder. It is deliberately
    /// absent from `allTemplates`, so bootstrap never creates one.
    private func seedGeneratedTemplate() async {
        await sut.mutateWorkFolder { project in
            guard !project.teams.contains(where: { $0.templateID == "generated" }) else { return }
            project.teams.append(TeamTemplateFactory.generatedTeam())
        }
    }

    private func generatedTemplate() -> Team? {
        guard let team = sut.workFolder?.teams.first(where: { $0.templateID == "generated" }) else {
            XCTFail("expected the Generated Team placeholder after seeding")
            return nil
        }
        return team
    }

    /// `createTask` does not create a run, but `startRun` always does before reaching
    /// `runTeamGeneration` — and the flow's network logger asserts on that ordering.
    private func seedRun(taskID: Int, teamID: NTMSID) async {
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(id: 0, teamID: teamID)
            run.updatedAt = MonotonicClock.shared.now()
            task.runs = [run]
        }
    }

    /// Full production-shaped setup for a Generated-Team task whose generation is
    /// guaranteed to fail in transport: placeholder template in the folder, task
    /// preferring it, run pinned to it, endpoint that cannot build a URL.
    private func prepareGeneratedTeamTask(
        brief: String = "build a calculator"
    ) async -> (taskID: Int, templateID: NTMSID)? {
        await sut.openWorkFolder(tempDir)
        pinUnreachableEndpoint()
        await seedGeneratedTemplate()
        guard let template = generatedTemplate() else { return nil }
        guard let taskID = await sut.createTask(
            title: "Gen", supervisorTask: brief, preferredTeamID: template.id)
        else { XCTFail("createTask returned nil"); return nil }
        await seedRun(taskID: taskID, teamID: template.id)
        XCTAssertTrue(
            sut.needsTeamGeneration(taskID: taskID),
            "precondition: the task is on the Generated Team template with no team yet")
        return (taskID, template.id)
    }

    @discardableResult
    private func appendGenerationStep(
        taskID: Int, id: String, status: StepStatus, message: String
    ) async -> String {
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
        return id
    }

    private func generationSteps(taskID: Int) -> [StepExecution] {
        (sut.loadedTask(taskID)?.runs.last?.steps ?? []).filter {
            $0.isTeamGenerationStep
        }
    }

    private static func jsonObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parsed
    }
}
