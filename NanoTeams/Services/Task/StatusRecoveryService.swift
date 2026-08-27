import Foundation

/// Reconciles task state after an app restart.
///
/// When the app closes while a task is running, its steps and role statuses persist in
/// their "active" states with no engine backing them. This service brings them back to
/// honest values — which means BOTH parking genuinely-interrupted work AND settling work
/// that actually finished but whose role status never caught up.
///
/// The second half matters because role and step status are written by two different
/// subsystems in two separate `mutateTask` calls (`finalizeStepCompletion` writes the
/// step; the engine writes the role later, via `waitForStepCompletion`'s 250 ms poll).
/// Any interruption in between — a quit inside the poll gap, a `pauseRun` (which cancels
/// the engine's `roleTasks` and never touches role statuses), a `stopAllEngines()` on
/// work-folder switch — persists a TORN pair. Blindly demoting the role to `.idle` there
/// used to make the tear permanent: every engine reconciler gates on the role's own
/// status, `derivedStatusFromActiveRun` then took its "roles still working" arm forever,
/// and every Supervisor review affordance disappeared.
///
/// The role pass now routes through `RoleStepReconciler`, the single source of truth
/// shared with the engine, so a completed run survives a restart into a reviewable state
/// and any `task.json` already carrying a torn pair heals on the next launch.
nonisolated enum StatusRecoveryService {

    /// Transitions stale in-flight statuses to safe states and settles torn role↔step pairs.
    ///
    /// Call after loading a task from disk when no engine is running.
    /// - Steps in `.running` or `.needsSupervisorInput` → `.paused`
    /// - Roles whose step is terminal → the status `RoleStepReconciler` derives
    /// - Roles in `.working` whose step is genuinely mid-flight (or absent) → `.idle`
    ///
    /// - Parameter team: the task's effective team, resolved via `TeamResolution.team(for:in:)`.
    ///   Supplies BOTH the per-role acceptance gate (its `settings`) and the roster used to
    ///   strip orphan role statuses. Deliberately has NO default value: a `= nil` default is
    ///   exactly the "resolves outward silently" trap of CLAUDE.md gotcha #49 — every call site
    ///   must state where its team came from. `nil` means the team could NOT be resolved (pinned
    ///   team deleted, or none), which is a third state, not an empty roster: see
    ///   `RoleRosterGuard.orphanRoleIDs` and `AcceptanceService.Gate`.
    ///
    ///   Replaced a `teamSettings:` parameter rather than joining it, so one resolution feeds
    ///   both uses — a second resolve could disagree with the first if the snapshot moved across
    ///   an `await`, which `recoverStaleStatusesAcrossIndex`'s own comment already worried about.
    ///
    /// **Precondition, and the licence for the unconditional delegation clear below: no engine
    /// is running for this task.** All three callers guarantee it — `openWorkFolder` runs after
    /// `stopAllEngines()`, the index sweep is gated on `taskEngines[taskID] == nil`, and
    /// `ensureTaskLoaded` returns early when the task is already in memory.
    /// - Returns: `true` if any changes were made.
    @discardableResult
    static func recoverStaleStatuses(
        in task: inout NTMSTask,
        team: Team?
    ) -> Bool {
        let gate = AcceptanceService.Gate(task: task, teamSettings: team?.settings)
        var changed = false
        // Tracked separately from `changed`: the `task.status = .paused` latch means
        // "a launch found work parked mid-flight". A pass that only settled a torn
        // TERMINAL pair interrupted nothing, so arming the latch there would be a lie —
        // and a durable one, since the latch permanently arms the guard in
        // `derivedStatusFromActiveRun`.
        var parked = false
        let activeRunIndex = task.runs.indices.last

        for runIndex in task.runs.indices {
            var runChanged = false

            // Phantom role entries for the synthetic generation step. `restartRole` writes
            // `roleStatuses["team_generation_<uuid>"]` for an id that no roster contains,
            // so removing them is unconditionally correct — and REQUIRED before the role
            // pass below, which would otherwise reconcile the phantom against the step and
            // settle it, after which `resumeRun`'s failed-step revival would call
            // `runStep` on a step belonging to no team.
            let phantomRoleIDs = task.runs[runIndex].roleStatuses.keys.filter {
                $0.hasPrefix(StepExecution.teamGenerationIDPrefix)
            }
            for roleID in phantomRoleIDs {
                task.runs[runIndex].roleStatuses.removeValue(forKey: roleID)
                runChanged = true
            }

            // Orphan role statuses: a status for a role that is on NO roster AND ran NO step.
            // Same unambiguous class as the phantom strip above — nothing produced it and
            // nothing can advance it — and it must also run BEFORE the role pass, or the
            // reconciler settles it first and the strip becomes a no-op on a lying value.
            //
            // The "no step" half is the whole safety argument, and it is deliberately NARROWER
            // than D-13 asked for. A role WITH a step really did run: its status is a record of
            // work, and deleting it because today's roster no longer lists that role would
            // destroy durable state on a heuristic — a task can outlive a rename, a team edit,
            // or a roster the run was pinned to. The D-13 shape (an orphan written by
            // `requestRevision`) is closed at the WRITE instead, by the roster guards on
            // `requestRevision` and `restartRole`, so no new orphan of that kind can appear.
            //
            // Strip the STATUS, keep the STEP: the step is the audit trail, the run-history
            // graph and the activity feed render it, and `derivedStatusFromActiveRun` reads step
            // statuses through `stepStatusSummary()` where a settled orphan step is harmless. An
            // orphan STATUS is not: it is invisible to `Run.activeWorkRoleIDs` (which iterates
            // definitions) while `derivedStatusFromActiveRun`'s `.done` arm reads `roleStatuses`
            // raw, so the engine retires the run while the task reads "Working" forever.
            //
            // Roster-GATED: `orphanRoleIDs` returns nothing for an unresolvable team, so a task
            // pinned to a deleted team keeps every status (#97).
            let stepIDsInRun = Set(task.runs[runIndex].steps.map(\.effectiveRoleID))
            for roleID in RoleRosterGuard.orphanRoleIDs(
                roleStatuses: task.runs[runIndex].roleStatuses, team: team
            ) where !stepIDsInRun.contains(roleID) {
                task.runs[runIndex].roleStatuses.removeValue(forKey: roleID)
                runChanged = true
            }

            // Recover stale step statuses. Runs FIRST so the role pass below reads the
            // rewritten values — a step just parked to `.paused` is non-terminal, which
            // is what keeps its `.working` role on the demote path.
            for stepIndex in task.runs[runIndex].steps.indices {
                let status = task.runs[runIndex].steps[stepIndex].status
                if status == .running || status == .needsSupervisorInput {
                    task.runs[runIndex].steps[stepIndex].status = .paused
                    task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
                    runChanged = true
                    parked = true
                    continue
                }
                // A DESTROYED team-generation record. `runTeamGeneration` drives its
                // synthetic step `.running` → `.done` / `.failed` / `.paused`, and
                // `retryTeamGeneration` deletes rather than resets — so `.pending` there
                // has exactly one writer, `StepExecution.reset()` via `restartRole`. It
                // means the record was destroyed and nothing will ever advance it, while
                // `Run.derivedTaskStatus()` reads it as work still to come and pins the
                // task at `.running` forever: invisible to the Autovisor's triage, which
                // has no `running` bullet.
                //
                // Park it like any other interrupted work rather than failing it.
                // `resumeRun` re-enters generation for a task that still needs one, so
                // `.paused` is TRUE here and both remedies the manager is told about
                // (`control_task resume`, the pane's Retry) do the same thing. `.failed`
                // would instead hide the toolbar control entirely
                // (`TeamBoardRunControl.select` returns nil for it), split this shape from
                // the cancelled/parked one that is already `.paused`, and steer the
                // manager to a bullet that offers `control_task delete`. A retry that
                // fails again writes `.failed` on its own.
                //
                // With a team already adopted there is nothing left to generate, so the
                // record settles `.done` — otherwise `allDone` can never be true and the
                // task never reaches Review.
                if status == .pending, task.runs[runIndex].steps[stepIndex].isTeamGenerationStep {
                    task.runs[runIndex].steps[stepIndex].status =
                        task.generatedTeam == nil ? .paused : .done
                    task.runs[runIndex].steps[stepIndex].completedAt = MonotonicClock.shared.now()
                    task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
                    runChanged = true
                    // Deliberately NOT `parked`: the latch means "a launch found work
                    // mid-flight", and nothing was interrupted here. The step's own
                    // `.paused` already drives the derived status.
                }
            }

            // Close any delegation that was in flight when the process ended.
            //
            // The marker is stale BY CONSTRUCTION here: its only writer is
            // `setActiveDelegation`, called from inside a live `delegate_to_team` handler, and
            // that handler's continuation cannot survive a restart. So this needs no "is the
            // child still alive" test — the precondition on this function (no engine running)
            // is the whole argument.
            //
            // Deliberately NOT nested in the `.running` / `.needsSupervisorInput` branch above:
            // a `.failed` step can own a marker (`ResumeFailedStepTests` pins exactly that
            // shape), and nesting it there would leave those permanently unrevivable, since
            // `resumeRun`'s revival guard refuses a failed step that still owns a delegation.
            //
            // Runs AFTER the step-status pass so a `.running` step is already parked when its
            // marker clears, and BEFORE `stepsByRoleBaseID()` so the role pass reads the
            // rewritten steps.
            for stepIndex in task.runs[runIndex].steps.indices {
                guard let childID = task.runs[runIndex].steps[stepIndex].activeDelegationChildID
                else { continue }

                // 1. The model-facing closure. Written to `llmConversation` unconditionally —
                //    it is the display record AND `ConversationReplay`'s fallback source.
                task.runs[runIndex].steps[stepIndex].llmConversation.append(
                    LLMMessage(role: .tool,
                               content: DelegationInterruptionEnvelope.toolMessage(childTaskID: childID)))

                // 2. The wire transcript, but ONLY when it is non-empty. `ConversationReplay`
                //    PREFERS a non-empty transcript over rebuilding from the display record, so
                //    appending to an empty one would hand the model a one-message conversation
                //    that is just a tool result and discard everything else. Empty or stale is
                //    the normal case here: the delegation await has no `persistWireTranscript`
                //    arm, so what is on disk predates the call.
                if !task.runs[runIndex].steps[stepIndex].wireTranscript.isEmpty {
                    task.runs[runIndex].steps[stepIndex].wireTranscript.append(
                        ChatMessage(role: .tool,
                                    content: DelegationInterruptionEnvelope.toolMessage(childTaskID: childID)))
                }

                // 3. The human-facing card. Without this the delegation tool call spins on its
                //    `{"status":"pending"}` placeholder forever and nothing ever says the
                //    delegation died.
                let delegationTools: Set<String> = [
                    ToolNames.delegateToTeam, ToolNames.resumeDelegation, ToolNames.forwardToTeam,
                ]
                if let callIndex = task.runs[runIndex].steps[stepIndex].toolCalls.lastIndex(where: {
                    delegationTools.contains($0.name)
                        && ($0.resultJSON?.contains("\"status\"") ?? true)
                }) {
                    task.runs[runIndex].steps[stepIndex].toolCalls[callIndex].resultJSON =
                        DelegationInterruptionEnvelope.envelope(childTaskID: childID)
                    task.runs[runIndex].steps[stepIndex].toolCalls[callIndex].isError = true
                }

                // 4. Finally the marker, preserving `delegation.history` so the graph keeps
                //    rendering the child as a history layer and the audit trail survives.
                task.runs[runIndex].steps[stepIndex].clearActiveDelegation()
                task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
                runChanged = true
                // Deliberately NOT `parked`: the latch means "a launch found work mid-flight",
                // and a `.running` step's own parking above already armed it. Arming it for a
                // `.failed` step's marker clear would be a durable lie.
            }

            let stepMap = task.runs[runIndex].stepsByRoleBaseID()
            let isActiveRun = runIndex == activeRunIndex

            // Reconcile role statuses against their steps.
            for (roleID, roleStatus) in task.runs[runIndex].roleStatuses {
                switch RoleStepReconciler.outcome(
                    roleStatus: roleStatus,
                    stepStatus: stepMap[roleID]?.status,
                    gate: gate,
                    roleID: roleID
                ) {
                case .settle(let settled):
                    // Historical runs settle too — a `.done` step must not leave its role
                    // reading "Working" forever in the run-history graph, which is the
                    // same stale lie this service exists to remove. But NEVER to
                    // `.needsAcceptance`: `TeamBoardView` feeds `displayedRun` (which can
                    // be a historical run) into `ActivityFeedActionBar` un-gated on
                    // `isReadOnly`, while `acceptRole` writes to `runs.last` — an Accept
                    // card there would mutate a DIFFERENT run. A superseded run has no
                    // acceptance gate left to honour, so it collapses to `.done`.
                    let target: RoleExecutionStatus = isActiveRun || settled != .needsAcceptance
                        ? settled
                        : .done
                    guard target != roleStatus else { break }
                    task.runs[runIndex].roleStatuses[roleID] = target
                    runChanged = true

                case .inFlight:
                    guard roleStatus == .working else { break }
                    task.runs[runIndex].roleStatuses[roleID] = .idle
                    runChanged = true
                    parked = true

                case .noAction:
                    break
                }
            }

            if runChanged {
                task.runs[runIndex].updatedAt = MonotonicClock.shared.now()
                changed = true
            }
        }

        if changed {
            task.updatedAt = MonotonicClock.shared.now()
        }
        if parked {
            task.status = .paused
        }

        return changed
    }
}
