import Foundation

/// Team generation flow for "Generated Team" template tasks.
///
/// When a task is started with `preferredTeamID` pointing to the Generated Team template,
/// we inject a synthetic Supervisor step containing a `create_team` tool call, then run
/// `TeamGenerationService` in the background. The tool call appears in the activity feed
/// (like `analyze_image`), and the graph shows a loader while generation is in progress.
/// On completion, `task.generatedTeam` is set and the engine proceeds with the new team.
extension NTMSOrchestrator {

    /// Checks if the given task uses the Generated Team template and hasn't generated a team yet.
    func needsTeamGeneration(taskID: Int) -> Bool {
        guard let task = loadedTask(taskID) else { return false }
        guard task.generatedTeam == nil else { return false }
        guard let preferredID = task.preferredTeamID,
              let team = workFolder?.team(withID: preferredID) else { return false }
        return team.isGeneratedPlaceholder
    }

    /// Runs the team generation flow for a task. Creates a Supervisor step with a
    /// `create_team` tool call (isAnalyzing-style placeholder), calls `TeamGenerationService`,
    /// and updates the tool call + sets `task.generatedTeam` when done.
    ///
    /// Returns `true` on success (team generated and set on the task), `false` on failure.
    @discardableResult
    func runTeamGeneration(taskID: Int) async -> Bool {
        guard let task = loadedTask(taskID) else {
            lastErrorMessage = "Cannot generate team for task \(taskID): task not loaded."
            return false
        }
        let taskDescription = task.effectiveSupervisorBrief

        guard !taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastErrorMessage = "Cannot generate a team without a task description."
            return false
        }

        // 1. Create a Supervisor step with the placeholder tool call.
        let stepID = "\(StepExecution.teamGenerationIDPrefix)\(UUID().uuidString)"
        let toolCallID = UUID()
        let placeholderArgs = TeamGenerationEnvelopes.makeGenerationArgsJSON(taskDescription: taskDescription)
        let placeholderResult = TeamGenerationEnvelopes.makeGeneratingEnvelope()

        let step = StepExecution(
            id: stepID,
            role: .supervisor,
            title: "Generate Team",
            status: .running,
            toolCalls: [
                StepToolCall(
                    id: toolCallID,
                    name: ToolNames.createTeam,
                    argumentsJSON: placeholderArgs,
                    resultJSON: placeholderResult,
                    isError: false
                )
            ]
        )

        await mutateTask(taskID: taskID) { task in
            guard let ri = task.runs.indices.last else { return }
            task.runs[ri].steps.append(step)
            task.runs[ri].updatedAt = MonotonicClock.shared.now()
        }

        // `mutateTask` returning true means "persisted", NOT "the closure did
        // something" (CLAUDE.md §7), so the guard above can drop the step while
        // reporting success. Verify it landed before spending a multi-second,
        // billable LLM call whose result would have no card to land on, no
        // spinner, and no Retry affordance — the user would see a task that
        // simply did nothing. The logger thirty lines below already treats this
        // same missing-run condition as an `assertionFailure`; this makes the
        // more consequential half agree.
        // Deliberately NOT an `assertionFailure` like the logger's twin below: a
        // trap makes the branch unreachable from a test, and a guard that cannot
        // be tested is how this one came to be silent in the first place.
        guard loadedTask(taskID)?.runs.last?.steps.contains(where: { $0.id == stepID }) == true else {
            lastErrorMessage =
                "Cannot generate a team for task \(taskID): the task has no run to attach it to."
            return false
        }

        // 2. Call TeamGenerationService in the background.
        let generationResult: Result<GeneratedTeamBuilder.BuildResult, Error>
        do {
            let effectiveConfig = LLMExecutionService.buildEffectiveConfig(
                globalConfig: globalLLMConfig,
                roleOverride: configuration.teamGenLLMOverride
            )
            // Construct a logger pointed at the same per-task `network_log.json`
            // the role's own LLM calls use, so the team-generation request +
            // response land in the existing trace next to the surrounding
            // delegating activity. Without this, an unparseable `create_team`
            // envelope leaves nothing to diagnose. Keyed off `loggingEnabled`
            // so the user's privacy toggle still controls capture.
            //
            // Invariant: `runTeamGeneration` is always invoked AFTER
            // `createNewRun(taskID:)` (see `startRun` in
            // `NTMSOrchestrator+RunControl.swift`), so the latest run exists by
            // the time we reach here. If it doesn't, something upstream is
            // out of order — surface it loudly in DEBUG and skip logging
            // (rather than silently disabling logging on the call we most
            // wanted to capture).
            let networkLogger: NetworkLogger? = {
                guard loggingEnabled else { return nil }
                guard let runID = loadedTask(taskID)?.runs.last?.id,
                      let url = networkLogURL(taskID: taskID, runID: runID)
                else {
                    assertionFailure("runTeamGeneration: latest run missing for task \(taskID); team-gen log will be skipped")
                    lastErrorMessage = "Team generation log skipped — no run available for task \(taskID)"
                    return nil
                }
                return NetworkLogger(logURL: url)
            }()
            // Runs on the global model unless a team-gen override is set, so it interleaves
            // with any role step streaming on that model and can evict its prefix cache.
            await llmExecutionService.noteInterleavingCall(
                label: "team generation", config: effectiveConfig)
            let raw = try await TeamGenerationService.generate(
                taskDescription: taskDescription,
                config: effectiveConfig,
                client: teamGenerationClient ?? LLMClientRouter(),
                systemPrompt: configuration.teamGenSystemPromptOrNil,
                logger: networkLogger,
                stepID: stepID
            )
            let buildResult = GeneratedTeamBuilder.applyForcedDefaults(
                to: raw,
                supervisorMode: configuration.teamGenForcedSupervisorMode,
                acceptanceMode: configuration.teamGenForcedAcceptanceMode
            )
            generationResult = .success(buildResult)
        } catch {
            generationResult = .failure(error)
        }

        // 3. Update the tool call + set task.generatedTeam on success.
        switch generationResult {
        case .success(let buildResult):
            let applied = await applyGeneratedTeamSuccess(
                taskID: taskID,
                team: buildResult.team,
                stepID: stepID,
                toolCallID: toolCallID,
                warnings: buildResult.warnings
            )
            // Teardown / task-switch race: the run or generation step vanished
            // before the success mutation could land, so the team was NOT adopted
            // or re-pinned. Don't report success — returning `false` keeps the
            // detached `startRun` Task from starting the engine on a non-adopted
            // (placeholder-pinned) team.
            guard applied else {
                lastErrorMessage = "Team generation finished but could not be applied (the task or its run changed). Try again."
                return false
            }
            if !buildResult.warnings.isEmpty {
                lastInfoMessage = buildResult.warnings.joined(separator: " ")
            }
            return true

        case .failure(let error):
            // Distinguish user-initiated cancellation (pauseRun → cancelTeamGeneration)
            // from genuine failures. On cancellation: mark the step `.paused` so a
            // subsequent resume/retry can continue, and skip `lastErrorMessage` so
            // the user isn't shown an error banner for an action they took themselves.
            let isCancellation = TeamGenerationService.isCancellation(error)
            let message = isCancellation
                ? "Team generation was cancelled"
                : (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let errorEnvelope = TeamGenerationEnvelopes.makeErrorEnvelope(message: message)
            await mutateTask(taskID: taskID) { task in
                guard let ri = task.runs.indices.last,
                      let si = task.runs[ri].steps.firstIndex(where: { $0.id == stepID })
                else { return }
                if let ti = task.runs[ri].steps[si].toolCalls.firstIndex(where: { $0.id == toolCallID }) {
                    task.runs[ri].steps[si].toolCalls[ti].resultJSON = errorEnvelope
                    task.runs[ri].steps[si].toolCalls[ti].isError = true
                }
                task.runs[ri].steps[si].status = isCancellation ? .paused : .failed
                task.runs[ri].steps[si].completedAt = MonotonicClock.shared.now()
                task.runs[ri].steps[si].updatedAt = MonotonicClock.shared.now()
                task.runs[ri].updatedAt = MonotonicClock.shared.now()
            }
            if !isCancellation {
                lastErrorMessage = message
                // The one condition the engine-state seam structurally cannot speak for: a
                // generation failure flips the task to `.failed` with NO engine in existence
                // to transition, so `onStateChanged` never fires and the manager's `.failed`
                // trigger would wait for the ≤60 s poll. Named site rather than a blanket
                // status-edge hook — every other derived-status move that matters to the
                // manager rides an engine transition.
                scheduleAutovisorWake()
            }
            return false
        }
    }

    /// Applies a successfully-generated team to the task's latest run: finalizes the
    /// `create_team` step (`.done` + success envelope), adopts the team, **re-pins
    /// `run.teamID` to the generated team's id**, and seeds role statuses.
    ///
    /// Why the re-pin: `createNewRun` runs BEFORE generation, so `run.teamID` is the
    /// transient "Generated Team" placeholder (roleIDs: []). Leaving it there makes
    /// `findOrCreateStep`'s roster-swap guard reject every generated role as "not a
    /// member of pinned team". The generated team's own id is what the guard (now
    /// generatedTeam-aware) and `TaskSummary.pinnedTeamID` must carry.
    ///
    /// Extracted from `runTeamGeneration`'s success arm so the adopt / re-pin / seed
    /// invariants are unit-testable without an LLM round-trip — keeping production and
    /// `TeamGenerationOrchestratorTests` in lockstep (same rationale as the shared
    /// `GeneratedTeamBuilder.seedRoleStatuses` helper).
    ///
    /// Returns `true` only when the mutation actually landed (the run + generation
    /// step were still present). `mutateTask` returning `true` means "persisted",
    /// NOT "the closure did something" (CLAUDE.md §7): in a teardown / task-switch
    /// race the generation step can be gone, the `guard` short-circuits, and the
    /// team would NOT be adopted / re-pinned — so the caller must not report
    /// success. Uses a captured flag (the `didPersist` pattern from
    /// `NTMSOrchestrator+QueuedMessages`).
    @discardableResult
    func applyGeneratedTeamSuccess(
        taskID: Int,
        team: Team,
        stepID: String,
        toolCallID: UUID,
        warnings: [String]
    ) async -> Bool {
        let successEnvelope = TeamGenerationEnvelopes.makeSuccessEnvelope(team: team, warnings: warnings)
        var applied = false
        await mutateTask(taskID: taskID) { task in
            guard let ri = task.runs.indices.last,
                  let si = task.runs[ri].steps.firstIndex(where: { $0.id == stepID })
            else { return }
            if let ti = task.runs[ri].steps[si].toolCalls.firstIndex(where: { $0.id == toolCallID }) {
                task.runs[ri].steps[si].toolCalls[ti].resultJSON = successEnvelope
                task.runs[ri].steps[si].toolCalls[ti].isError = false
            }
            task.runs[ri].steps[si].status = .done
            task.runs[ri].steps[si].completedAt = MonotonicClock.shared.now()
            task.runs[ri].steps[si].updatedAt = MonotonicClock.shared.now()

            task.adoptGeneratedTeam(team)
            task.runs[ri].teamID = team.id   // re-pin to the team that actually executes

            // Seed role statuses via the shared helper so this code path stays
            // in sync with `GeneratedTeamBuilderTests.testSeedRoleStatuses_*`.
            let producedArtifacts = TaskEngineStoreAdapter.computeProducedArtifactNames(
                task: task, run: task.runs[ri]
            )
            GeneratedTeamBuilder.seedRoleStatuses(
                for: team,
                existingRun: &task.runs[ri],
                producedArtifacts: producedArtifacts
            )
            // Mirror the `.failure` arm, which bumps the run timestamp on completion.
            task.runs[ri].updatedAt = MonotonicClock.shared.now()
            applied = true
        }
        return applied
    }

    /// `retryTeamGeneration` for a caller that needs to know whether anything happened.
    ///
    /// Wrapping the plain call in `reportingError` would report SUCCESS for a no-op —
    /// exactly the silent-`ok:true` class this codebase has been clearing out — because
    /// both of its silent exits are `lastInfoMessage`, not `lastErrorMessage`.
    ///
    /// The precondition is checked HERE rather than deferred to `retryTeamGeneration`,
    /// which deletes every `team_generation_*` step BEFORE it re-checks
    /// `needsTeamGeneration`. On a task whose team already generated successfully that
    /// call is not a harmless no-op: it destroys the `create_team` card that is the only
    /// record of how the team was produced, and then there is nothing left for a
    /// "did anything change?" test to see.
    func retryTeamGenerationReportingResult(taskID: Int) async -> AutovisorActionResult {
        guard needsTeamGeneration(taskID: taskID) else {
            return .failure(
                "Task #\(taskID) has no pending team generation — its team is already in place. "
                    + "Use manage_role on a role_id from task_status, or control_task delete "
                    + "to drop the task.")
        }
        await retryTeamGeneration(taskID: taskID)

        // Read the outcome off DURABLE task state, never off `lastErrorMessage`: that slot
        // is single-shot and the error banner nils it on any render, and this method awaits
        // an LLM call — so a real failure would read back as nil and be reported as
        // "did not restart", i.e. the opposite of what happened.
        guard let task = loadedTask(taskID) else {
            return .failure("Task #\(taskID) is no longer loaded.")
        }
        if task.generatedTeam != nil {
            return .success("Re-ran team generation for task #\(taskID).")
        }
        // "Did it start?" is asked BEFORE "did it fail?". `retryTeamGeneration`'s
        // re-entrancy guard returns before the cleanup mutation, so on that path the
        // surviving `.failed` step is the PRIOR attempt's — reading it here would report
        // "failed again" for a retry that never ran. Our own run has already cleared the
        // in-flight marker via its `defer` by the time we get here, so this cannot mask a
        // genuine second failure.
        if isGeneratingTeam(taskID: taskID) {
            return .failure(
                "Team generation for task #\(taskID) is already in progress — "
                    + "wait and re-check task_status.")
        }
        if let failed = task.runs.last?.steps.last(where: {
            $0.isTeamGenerationStep && $0.status == .failed
        }) {
            let reason = failed.toolCalls
                .compactMap(\.errorMessage)
                .last
            return .failure(
                reason.map { "Team generation for task #\(taskID) failed again: \($0)" }
                    ?? "Team generation for task #\(taskID) failed again.")
        }
        return .failure("Team generation for task #\(taskID) did not restart.")
    }

    /// Removes every synthetic `team_generation_*` step from the task's latest run.
    ///
    /// Narrow PREFIX match, never a `create_team` NAME match: matching by
    /// `toolCalls.contains { name == createTeam }` would also delete delegating-role steps
    /// that carry a synthetic `create_team` placeholder from `handleDelegateToTeam`'s
    /// generated branch — an entire role's step (llmConversation / messages / scratchpad /
    /// artifacts / delegationChildIDs) would vanish. The prefix is the literal format
    /// `runTeamGeneration` uses; no other code path produces step IDs with this shape.
    func clearPriorTeamGenerationSteps(taskID: Int) async {
        await mutateTask(taskID: taskID) { task in
            guard let ri = task.runs.indices.last else { return }
            task.runs[ri].steps.removeAll { $0.isTeamGenerationStep }
            task.runs[ri].updatedAt = MonotonicClock.shared.now()
        }
    }

    /// Reserves the generation slot, spawns the detached generation Task (registered so
    /// `pauseRun`'s `cancelTeamGeneration` can reach it), and starts the engine on success.
    ///
    /// The ONE place the "detached generation" shape lives — `startRun` and `resumeRun`
    /// differ only in `clearingPriorSteps`.
    ///
    /// **Synchronous by design.** The reserve is taken before this returns, so
    /// `isGeneratingTeam(taskID:)` is already true for the caller's next statement. An
    /// `async` helper that reserved only after its first suspension would leave a window in
    /// which `GeneratedTeamPanelState`'s liveness term reads "not in flight" and the pane
    /// flashes a failure, and in which `applyControlTask(.start)`'s outcome check reports a
    /// start that did happen as one that didn't.
    ///
    /// - Parameter clearingPriorSteps: delete every `team_generation_*` step in the latest
    ///   run first. `false` for `startRun` (`createNewRun` just replaced the run). `true`
    ///   for `resumeRun`, whose run may still carry a cancelled `.paused` attempt, a
    ///   `.failed` one, or a `.pending` record `restartRole` destroyed — leaving it stacks
    ///   two `create_team` cards, which is what makes `retryTeamGenerationReportingResult`
    ///   blame the wrong attempt. Nothing a user can miss is lost: those steps hold only
    ///   the placeholder card and its envelope — generation never goes through
    ///   `startStepExecution`, so there is no transcript, no artifacts, no `wireTranscript`.
    /// - Returns: `false` when the slot was already taken. Callers must NOT fall through to
    ///   their own `engine.start()` on `false` — a generation is in flight and will start it.
    @discardableResult
    func spawnTeamGeneration(taskID: Int, clearingPriorSteps: Bool) -> Bool {
        guard beginTeamGeneration(taskID: taskID) else { return false }
        let genTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.endTeamGeneration(taskID: taskID) }
            if clearingPriorSteps {
                await self.clearPriorTeamGenerationSteps(taskID: taskID)
            }
            // Re-check after the cleanup, exactly as `retryTeamGeneration` does: a team
            // adopted concurrently means there is nothing left to generate.
            guard self.needsTeamGeneration(taskID: taskID) else { return }
            let generated = await self.runTeamGeneration(taskID: taskID)
            // Skip engine start if pauseRun cancelled us mid-generation.
            guard !Task.isCancelled else { return }
            guard generated else { return } // failure envelope + lastErrorMessage already set
            self.engineForTask(taskID).start()
        }
        registerTeamGenerationTask(taskID: taskID, task: genTask)
        return true
    }

    /// Retries team generation after a previous attempt failed. Removes any prior
    /// generation step from the latest run, then re-runs the generation flow and starts
    /// the engine on success. No-ops when the task isn't using the Generated Team template.
    ///
    /// Keeps the AWAITING shape (rather than delegating to `spawnTeamGeneration`): the
    /// Retry button and `retryTeamGenerationReportingResult`'s durable-outcome read both
    /// depend on the generation having finished by the time this returns.
    func retryTeamGeneration(taskID: Int) async {
        // Guard against double-retry (rapid button clicks) and against retry racing
        // a still-in-flight detached generation from `startRun`. Surface a banner
        // so the user understands why the click had no visible effect.
        guard beginTeamGeneration(taskID: taskID) else {
            lastInfoMessage = "Team generation is already in progress."
            return
        }
        defer { endTeamGeneration(taskID: taskID) }

        await clearPriorTeamGenerationSteps(taskID: taskID)

        // After cleanup, `needsTeamGeneration` is true again iff the template is
        // "generated" and no team has been adopted — same gate as `startRun`.
        guard needsTeamGeneration(taskID: taskID) else { return }

        let generated = await runTeamGeneration(taskID: taskID)
        guard generated else { return }
        let engine = engineForTask(taskID)
        engine.start()
    }

    /// Saves the generated team to the project (moves from task to teams.json).
    func saveGeneratedTeam(taskID: Int) async {
        guard let task = loadedTask(taskID),
              let team = task.generatedTeam else { return }

        await mutateWorkFolder { proj in
            proj.teams.removeAll { $0.id == team.id }
            proj.teams.append(team)
        }

        await mutateTask(taskID: taskID) { task in
            task.preferredTeamID = team.id
            task.clearGeneratedTeam()
        }

        lastInfoMessage = "Team '\(team.name)' saved"
    }

    // MARK: - Envelopes (test accessors)

    #if DEBUG
    /// Test accessor — verifies the placeholder envelope string matches the substring
    /// `StepToolCall.isGeneratingTeam` looks for. The actual implementation lives in
    /// `TeamGenerationEnvelopes` (shared with the `delegate_to_team` generated-flow
    /// placeholder); these forwards keep `TeamGenerationOrchestratorTests` compiling
    /// and continue to pin the cross-file substring contract.
    static func _testGeneratingEnvelope() -> String {
        TeamGenerationEnvelopes.makeGeneratingEnvelope()
    }
    static func _testSuccessEnvelope(team: Team, warnings: [String] = []) -> String {
        TeamGenerationEnvelopes.makeSuccessEnvelope(team: team, warnings: warnings)
    }
    static func _testErrorEnvelope(message: String) -> String {
        TeamGenerationEnvelopes.makeErrorEnvelope(message: message)
    }
    #endif
}
