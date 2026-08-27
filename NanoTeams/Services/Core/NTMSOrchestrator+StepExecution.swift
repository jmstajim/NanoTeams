import Foundation

/// Step execution: run, pause, answer Supervisor questions, find/create steps.
extension NTMSOrchestrator {

    // MARK: - Step Execution

    /// Synchronous variant for `LLMStateDelegate.setLastErrorMessageForUI`.
    /// Surfaces a user-visible error banner (auto-dismissing, red).
    func setLastErrorMessageForUI(_ message: String) {
        lastErrorMessage = message
    }

    /// Synchronous variant for `LLMStateDelegate.setLastInfoMessageForUI`.
    /// Surfaces a user-visible info banner (auto-dismissing, neutral style).
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func setLastInfoMessageForUI(_ message: String) {
        lastInfoMessage = message
    }

    /// `LLMStateDelegate.reportPrefixCacheMiss`. The service detects the miss; every user-visible
    /// surface is owned here.
    ///
    /// The count always moves — that is the always-on surface, and it is idempotent under
    /// repetition, which the 4-second single-slot banner is not. The banner fires only when
    /// `PrefixCacheReporter` says this miss earns one (once per task+run+cause, on-screen task
    /// only).
    // periphery:ignore - protocol conformance (LLMStateDelegate)
    func reportPrefixCacheMiss(_ miss: PrefixCacheMiss) {
        guard let message = prefixCacheReporter.report(miss) else { return }
        lastErrorMessage = message
    }

    /// Registers a request against a prompt-prefix chain on behalf of a taskless service that
    /// has no ledger of its own. Routes to THIS orchestrator's execution service — never a
    /// global (CLAUDE.md Swift Style #49), which is the whole reason the ledger is an injected
    /// instance rather than a singleton.
    func recordPrefixChainForTasklessCall(
        owner: LLMCallOwner, config: LLMConfig, messages: [ChatMessage]
    ) async {
        _ = await llmExecutionService.prefixLedger.record(
            baseURL: config.baseURLString,
            model: config.modelName,
            owner: owner,
            messages: messages,
            toolSchemaText: "")
    }

    func runStep(stepID: String, taskID: Int) async {
        guard let task = loadedTask(taskID) else { return }
        guard let runIndex = task.runs.indices.last else { return }
        guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID }) else { return }

        await mutateTask(taskID: taskID) { task in
            StepExecutionService.markStepRunning(stepID: stepID, in: &task)
        }

        if let updatedTask = loadedTask(taskID) {
            llmExecutionService.startStepExecution(
                stepID: stepID,
                taskID: taskID,
                task: updatedTask,
                runIndex: runIndex,
                stepIndex: stepIndex
            )
        }
    }

    func pauseStep(stepID: String, taskID: Int) async {
        await llmExecutionService.cancelStepExecution(stepID: stepID, taskID: taskID)

        await mutateTask(taskID: taskID) { task in
            StepExecutionService.pauseStep(stepID: stepID, in: &task)
        }
    }

    /// Submits a Supervisor answer. Returns `true` on success, `false` if attachment finalization failed.
    /// `isAutoAnswer` flags answers produced by an automated supervisor path (a
    /// delegating parent role, the Autovisor's `answer_task_question`) so the
    /// activity feed shows the "Auto-answered" badge only for those — human
    /// call sites use the default `false`.
    @discardableResult
    func answerSupervisorQuestion(
        stepID: String,
        taskID: Int,
        answer: String,
        attachments: [StagedAttachment] = [],
        isAutoAnswer: Bool = false
    ) async -> Bool {
        // Bash approvals are NOT answered here — they are held in-loop by the gate
        // and resolved DIRECTLY via the Allow/Deny buttons (`resolveBashApproval`),
        // bypassing the model. This path handles only normal `ask_supervisor`.

        // Finalize staged attachments. There is deliberately no draft-directory cleanup here:
        // the parameter that drove one (`draftID`) had no caller and its body was the same
        // whole-directory delete `cancelDraft` had to stop doing — `formState.draftID` names one
        // `.nanoteams/staged/<id>/` that the task draft and every saved answer draft write into.
        // Staged copies that outlive a submit are swept at the next `openWorkFolder`
        // (`cleanupAllStagedDrafts`), so removing it costs nothing and removes a landmine.
        var finalPaths: [String] = []
        if let workFolderRoot = workFolderURL {
            if !attachments.isEmpty {
                do {
                    finalPaths = try repository.finalizeAttachments(
                        at: workFolderRoot,
                        taskID: taskID,
                        stagedEntries: attachments.map {
                            (path: $0.stagedRelativePath, isProjectReference: $0.isProjectReference)
                        }
                    )
                } catch {
                    lastErrorMessage = "Failed to finalize attachments: \(error.localizedDescription)"
                    return false  // Do not submit answer without the attachments the user expects
                }
            }
        }

        // Capture whether the closure actually located the step. `mutateTask` itself
        // returns `true` for "persisted" even when the closure short-circuits
        // (CLAUDE.md §7), so we relay applied-state via this captured flag.
        var applied = false
        await mutateTask(taskID: taskID) { task in
            applied = StepMessagingService.answerSupervisorQuestion(
                stepID: stepID,
                answer: answer,
                attachmentPaths: finalPaths,
                isAutoAnswer: isAutoAnswer,
                in: &task
            )
        }
        guard applied else {
            // Race scenario: the step was restarted, removed, or rebuilt between
            // when the composer rendered the Answer chip and when the user
            // submitted. Set a specific `lastErrorMessage` so the Supervisor
            // sees the cause instead of a generic "submission failed". The
            // composer's `.answer` branch clears its draft synchronously on
            // submit and restores it from snapshots when this returns `false`
            // (see `TeamActivityComposer.performAnswerSubmit`), so the user
            // can pick another recipient and retry without retyping.
            lastErrorMessage = "This question is no longer active — the role may have been restarted. Please pick another recipient and try again."
            return false
        }

        // The answer is the durable "question consumed" event, so retire the
        // persisted sidebar "read" marker HERE, not only in the view observer:
        // `MainLayoutView`'s `onChange(of: allTaskWaitStates)` sweep exists only
        // while the window is mounted, and an answer submitted from the Quick
        // Capture panel with the main window closed would otherwise leave the
        // flag standing — the NEXT question then finds the task already "seen"
        // and the unread dot never lights for a question nobody has read. The
        // mounted mirror (`TaskManagementState`) converges through that same
        // observer; this write covers the unmounted window.
        if let workFolderID = snapshot?.projection.id {
            configuration.unmarkTaskSeen(workFolderID: workFolderID, taskID: taskID)
        }

        // Same reason, for the Autovisor's deliver-once ledgers: the answer is the durable
        // "question consumed" event, and a key that outlives the question it names makes
        // the NEXT question on this task read as already-delivered.
        noteSupervisorQuestionResolved(taskID: taskID)

        let engineState = taskEngineStates[taskID] ?? .pending
        if engineState == .paused || engineState == .needsSupervisorInput {
            await resumeRun(taskID: taskID)
        } else if engineState != .done && engineState != .failed {
            taskEngines[taskID]?.notifyExternalEvent()
        }
        return true
    }

    // MARK: - Step Creation (used by TaskEngineStoreAdapter)

    func findOrCreateStep(taskID: Int, roleID: String) async -> String? {
        guard let task = loadedTask(taskID) else { return nil }
        guard let runIndex = task.runs.indices.last else { return nil }

        if let step = task.runs[runIndex].steps.first(where: { $0.effectiveRoleID == roleID }) {
            return step.id
        }

        // Roster-swap guard (defense-in-depth). This is the chokepoint where a
        // deleted-team fallback previously commingled a SECOND roster into one run
        // (e.g. two "Tech Lead" steps from two teams). A nil return marks the role
        // `.failed` in the engine.
        let run = task.runs[runIndex]
        if let pinned = run.teamID {
            // Pinned run: the role MUST belong to the pinned team, which must exist.
            // Resolve the pinned id generatedTeam-aware — a generated team lives on
            // `task.generatedTeam`, never in `workFolder.teams`, so a teams.json-only
            // lookup would falsely report it "no longer exists". This is PIN-FIRST
            // (use generatedTeam only when its id equals the pin), deliberately
            // STRICTER than `TeamResolution.resolve` (which is generatedTeam-first):
            // a pin that matches neither must still fail loudly "no longer exists".
            // It nonetheless AGREES with `resolvedTeam(for:)` (used by makeStep below)
            // in every reachable state, because `generatedTeam` is only ever set while
            // the run is pinned to it — adopt + re-pin happen together in
            // `applyGeneratedTeamSuccess`, and `switchTeam` clears it on a roster swap.
            let pinnedTeam = (task.generatedTeam?.id == pinned)
                ? task.generatedTeam
                : workFolder?.team(withID: pinned)
            guard let pinnedTeam else {
                lastErrorMessage = "Refusing to seed role '\(roleID)' into run \(run.id): pinned team '\(pinned)' no longer exists."
                return nil
            }
            guard pinnedTeam.findRole(byIdentifier: roleID) != nil else {
                lastErrorMessage = "Refusing to seed role '\(roleID)' into run \(run.id): it is not a member of pinned team '\(pinned)'. Roster swap blocked."
                return nil
            }
        } else if let anchorRoleID = run.steps.first?.effectiveRoleID,
                  // Legacy run with no pinned teamID. Generated runs always carry a pin
                  // (createTeamRun + the runTeamGeneration re-pin), so this branch is
                  // unreachable for them — it is generatedTeam-blind by omission, not by bug.
                  let rosterTeam = workFolder?.teams.first(where: { $0.findRole(byIdentifier: anchorRoleID) != nil }),
                  rosterTeam.findRole(byIdentifier: roleID) == nil {
            // Legacy run without a pinned teamID: infer the roster from an existing
            // step and refuse any role outside it.
            lastErrorMessage = "Refusing to seed role '\(roleID)' into run \(run.id): it is not a member of the run's team '\(rosterTeam.name)'. Roster swap blocked."
            return nil
        }

        let taskTeam = resolvedTeam(for: task)
        guard let step = taskTeam.makeStep(forRoleID: roleID) else { return nil }

        // Supervisor task is injected by PromptBuilder.buildSupervisorTaskSection() — no need to duplicate here

        let stepID = step.id

        await mutateTask(taskID: taskID) { task in
            task.runs[task.runs.count - 1].steps.append(step)
        }

        return stepID
    }

}
