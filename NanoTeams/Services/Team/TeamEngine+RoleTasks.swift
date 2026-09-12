import Foundation

// MARK: - Role Tasks

extension TeamEngine {

    /// The per-role acceptance gate for this pass, resolved ONCE (the run loop reconciles
    /// every role on every 250 ms tick — re-resolving per role would re-walk the task).
    func acceptanceGate() -> AcceptanceService.Gate? {
        guard let store, let task = store.activeTask else { return nil }
        return AcceptanceService.Gate(task: task, teamSettings: store.teamSettings)
    }

    /// Applies `RoleStepReconciler` — the rule shared with `StatusRecoveryService` — to a
    /// single role. Writes only on `.settle`.
    ///
    /// - Returns: `true` iff a status was written.
    @discardableResult
    func reconcileRole(
        roleID: String,
        roleStatus: RoleExecutionStatus?,
        stepStatus: StepStatus?,
        gate: AcceptanceService.Gate
    ) async -> Bool {
        guard case .settle(let newStatus) = RoleStepReconciler.outcome(
            roleStatus: roleStatus,
            stepStatus: stepStatus,
            gate: gate,
            roleID: roleID
        ) else { return false }

        await store?.updateRoleStatus(roleID: roleID, status: newStatus)
        onRoleStatusChanged?(roleID, newStatus)
        return true
    }

    /// Settles every (role, step) pair of the latest run through `RoleStepReconciler`.
    /// Shared by the pre-loop pass (`launchRunLoop`) and by every iteration of `runLoop`,
    /// so the two can never drift.
    func reconcileRoleStatuses() async {
        guard let store, let run = store.activeTask?.runs.last, let gate = acceptanceGate() else { return }
        let stepMap = run.stepsByRoleBaseID()
        for (roleID, status) in run.roleStatuses {
            await reconcileRole(
                roleID: roleID,
                roleStatus: status,
                stepStatus: stepMap[roleID]?.status,
                gate: gate
            )
        }
    }

    /// Reconcile role statuses after pause — a role task may have completed
    /// (step → .done/.failed) before cancellation took effect, or a step may
    /// have been paused after an external event (e.g., Supervisor answered ask_supervisor).
    ///
    /// Also runs on `start()` (see `launchRunLoop`), which is the path a post-restart
    /// `resumeRun` takes.
    ///
    /// The restart arm is now `admitAndRestartParkedRoles`, shared with the run loop, which
    /// applies it on EVERY iteration. Both are needed and neither is redundant:
    ///
    ///  - Here, because the loop returns early for a task with any `.needsSupervisorInput`
    ///    step — so with two roles parked on questions and one of them answered, the loop
    ///    never reaches its own pass and the answered role would starve behind its sibling.
    ///  - In the loop, because under a cap the parked roles that missed the slot need
    ///    somebody to pick them up later, and once per launch is not that.
    func reconcileAfterPause() async {
        await reconcileRoleStatuses()
        await admitAndRestartParkedRoles()
    }

    /// Restarts as many parked roles as the concurrency cap allows.
    /// - Returns: the roles restarted.
    @discardableResult
    func admitAndRestartParkedRoles() async -> [String] {
        guard let store, let run = store.activeTask?.runs.last else { return [] }
        let roles = store.activeTeam?.roles ?? []
        let parked = parkedRoleIDs(run: run, roles: roles)
        guard !parked.isEmpty else { return [] }
        let admitted = RoleAdmissionControl.admit(
            candidates: parked,
            occupied: occupiedRoleIDs(run: run, roles: roles),
            limit: store.maxConcurrentRoles)
        await restartParkedRoles(admitted, in: run)
        return admitted
    }

    /// Who holds an execution slot right now: the durable rule
    /// (`RoleAdmissionControl.occupiedRoleIDs`) unioned with this engine's own in-flight set.
    ///
    /// Two independent sources of truth, because neither is sufficient alone: the durable one
    /// cannot see the milliseconds in which a step exists only as a `.pending` row inside a
    /// task that is about to run it, and the in-flight one is gone the moment an app restart
    /// leaves a `.running` step behind with no engine.
    func occupiedRoleIDs(run: Run, roles: [TeamRoleDefinition]) -> Set<String> {
        RoleAdmissionControl.occupiedRoleIDs(run: run, roles: roles).union(liveRoleTaskIDs())
    }

    // MARK: - Restarting Parked Roles

    /// Roles whose step was parked while the role stayed `.working` — what a pause/resume, an
    /// answered `ask_supervisor`, or an app restart leaves behind — and that have no
    /// execution in flight.
    ///
    /// Returned in ROSTER order so the choice of who gets a scarce slot is reproducible.
    ///
    /// The liveness key is `hasLiveRoleTask`, not the step status alone: a step is briefly
    /// `.pending` INSIDE a task that is already running it (`findOrCreateStep` →
    /// `prepareStepForExecution` → `runStep`), and restarting on that transient would drive a
    /// second execution into one step.
    func parkedRoleIDs(run: Run, roles: [TeamRoleDefinition]) -> [String] {
        let stepMap = run.stepsByRoleBaseID()
        let rosterIDs = roles.map(\.id)
        let rosterSet = Set(rosterIDs)
        // Roster first (the order a scarce slot is handed out in), then whatever the roster no
        // longer knows, sorted. Orphans are KEPT: this arm is what resumes a step after an
        // answered question, and a role the team dropped mid-run still has a live step to
        // finish. Dropping them would strand it with nothing to restart it, ever.
        let candidates =
            rosterIDs + run.roleStatuses.keys.filter { !rosterSet.contains($0) }.sorted()
        return candidates.filter { roleID in
            guard run.roleStatuses[roleID] == .working,
                  let step = stepMap[roleID],
                  step.status == .paused || step.status == .pending,
                  !hasLiveRoleTask(roleID)
            else { return false }
            return true
        }
    }

    /// Restarts the given parked roles. The role status is already `.working`; only the step
    /// needs re-entering, which is why this does NOT write a status the way `startRoles` does.
    func restartParkedRoles(_ roleIDs: [String], in run: Run) async {
        let stepMap = run.stepsByRoleBaseID()
        for roleID in roleIDs {
            guard let step = stepMap[roleID] else { continue }
            let stepID = step.id
            launchRoleTask(roleID: roleID) { engine, store in
                await store.prepareStepForExecution(stepID: stepID)
                await store.runStep(stepID: stepID)
                await engine.waitForStepCompletion(stepID: stepID, roleID: roleID)
            }
        }
    }

    // MARK: - Finding Ready Roles

    /// The roles that may start THIS pass.
    ///
    /// Readiness is not just "my inputs exist and I am idle". An artifact can exist and be
    /// STALE: while an upstream role is `.revisionRequested` or `.working`, the artifact
    /// bearing its name in `producedArtifacts` is the pre-amendment one, and a consumer that
    /// starts on it produces a report nobody will read. That was reachable on every edge
    /// where a `request_changes` requester has consumers of its own: the requester is held
    /// (`holdDownstreamForRevision`) but its step PLAYS OUT and must end in an artifact, so
    /// the stale artifact is there the moment the target's amendment lands — and the
    /// consumer started in the same pass as the requester's re-run, in parallel with it.
    ///
    /// `startableRevisionRoleIDs` already forbids exactly this for a revision role. The rule
    /// is the same rule, so it is applied from ONE place with ONE list of blocking statuses:
    /// a role is not ready while any of its dependency roles is in `revisionBlockingStatuses`.
    ///
    /// No deadlock: the blocked consumer simply does not appear in `readyRoleIDs`, and the
    /// revision cascade is driven by `startRevisionRoles`, which is not gated on this. Once
    /// the upstream reaches `.done` the consumer becomes ready with the FRESH artifact.
    func findReadyRoles(
        roles: [TeamRoleDefinition],
        producedArtifacts: Set<String>,
        roleStatuses: [String: RoleExecutionStatus]
    ) -> [String] {
        // Filter to only active roles (exclude observers — they don't execute steps)
        let filteredRoles = roles.filter { !$0.isObserver }

        // Exclude Supervisor (user-controlled) and roles already in progress/done
        let supervisorRoleIDs = Set(roles.filter(\.isSupervisor).map(\.id))
        let excludeIDs: Set<String> = Set(roleStatuses.compactMap { (roleID, status) in
            switch status {
            case .working, .done, .accepted, .needsAcceptance, .failed, .skipped, .revisionRequested:
                return roleID
            case .idle, .ready:
                return nil
            }
        }).union(supervisorRoleIDs)

        // Find roles with satisfied dependencies
        let readyRoleIDs = ArtifactDependencyResolver.findReadyRoles(
            roles: filteredRoles,
            producedArtifacts: producedArtifacts,
            excludeRoleIDs: excludeIDs
        )

        let resolver = ArtifactDependencyResolver(roles: roles)
        return readyRoleIDs.filter { roleID in
            !Self.hasBlockingUpstream(roleID: roleID, roleStatuses: roleStatuses, resolver: resolver)
        }
    }

    /// The statuses of an upstream role that make its artifact stale for a consumer.
    /// Read by BOTH readiness gates — ordinary start and revision restart — because they
    /// are asking the same question about the same graph.
    /// A `Set`, not an array: this is read per role per dependency on every run-loop pass,
    /// and a two-element array `contains` is a linear scan the complexity ratchet counts.
    nonisolated static let revisionBlockingStatuses: Set<RoleExecutionStatus> = [.revisionRequested, .working]

    nonisolated static func hasBlockingUpstream(
        roleID: String,
        roleStatuses: [String: RoleExecutionStatus],
        resolver: ArtifactDependencyResolver
    ) -> Bool {
        resolver.dependencyRoleIDs(of: roleID).contains {
            revisionBlockingStatuses.contains(roleStatuses[$0] ?? .idle)
        }
    }

    // MARK: - Starting Roles

    /// Starts each of `roleIDs` that is not already executing.
    ///
    /// - Returns: the roles actually started, so the caller can tell "dispatched work" from
    ///   "found every candidate already busy" — under a concurrency cap those are different
    ///   answers, and treating the second as the first is a 10 Hz spin with no `.done` and
    ///   no `.failed` at the end of it.
    @discardableResult
    func startRoles(roleIDs: [String]) async -> [String] {
        guard let store else { return [] }

        var started: [String] = []
        for roleID in roleIDs {
            // Skip if already executing. `hasLiveRoleTask` is believable because
            // `launchRoleTask` evicts a finished record; the older `roleTasks[roleID] != nil`
            // form skipped a role whose previous execution had merely RETURNED, which under a
            // cap meant the same role won the only slot on every pass and never used it.
            if hasLiveRoleTask(roleID) { continue }

            // Update status to working
            await store.updateRoleStatus(roleID: roleID, status: .working)
            onRoleStatusChanged?(roleID, .working)
            started.append(roleID)

            // Create step if needed and start execution
            launchRoleTask(roleID: roleID) { engine, store in
                guard let stepID = await store.findOrCreateStep(roleID: roleID) else {
                    await store.updateRoleStatus(roleID: roleID, status: .failed)
                    engine.onRoleStatusChanged?(roleID, .failed)
                    return
                }

                await store.prepareStepForExecution(stepID: stepID)
                await store.runStep(stepID: stepID)

                // Wait for step to complete
                await engine.waitForStepCompletion(stepID: stepID, roleID: roleID)
            }
        }
        return started
    }

    /// From the roles currently in `.revisionRequested`, returns those whose upstream
    /// dependency roles are NOT themselves blocking (`.revisionRequested` or `.working`).
    ///
    /// Serializes a revision cascade: a downstream role (e.g. Code Reviewer) only starts
    /// after the upstream role it depends on (e.g. Software Engineer) finishes its
    /// revision, so it re-runs against the FRESH artifacts rather than the stale ones
    /// left over from the prior run. Independent revision roles still start together.
    /// A fully-blocked set (dependency cycle) returns empty so the run loop can fail
    /// loudly instead of spinning. The change-request target is always the chain root
    /// (its upstream is never revised), so a valid acyclic team always has a startable role.
    /// Order is ROSTER order (then any roles the roster no longer knows, sorted). It used to
    /// be `Dictionary` iteration order, which is not a function of the dictionary's contents:
    /// the same run produced a different order on different launches. Harmless while every
    /// startable role started anyway — and load-bearing the moment a concurrency cap makes
    /// this list decide which role gets the only slot.
    nonisolated static func startableRevisionRoleIDs(
        roleStatuses: [String: RoleExecutionStatus],
        roles: [TeamRoleDefinition]
    ) -> [String] {
        let rosterIDs = roles.map(\.id)
        let rosterSet = Set(rosterIDs)
        // Roles the roster dropped mid-run are kept (sorted) rather than filtered out: they
        // still need to reach `startRevisionRoles`, whose `findOrCreateStep` failure reports
        // "step not found" — a truthful terminal error, where dropping them here would have
        // the run loop announce a dependency cycle that does not exist.
        let revisionRoleIDs =
            rosterIDs.filter { roleStatuses[$0] == .revisionRequested }
                + roleStatuses.keys
                .filter { !rosterSet.contains($0) && roleStatuses[$0] == .revisionRequested }
                .sorted()
        guard !revisionRoleIDs.isEmpty else { return [] }

        let resolver = ArtifactDependencyResolver(roles: roles)
        return revisionRoleIDs.filter { roleID in
            !hasBlockingUpstream(roleID: roleID, roleStatuses: roleStatuses, resolver: resolver)
        }
    }

    /// Starts the given revision-requested roles — the admitted subset of
    /// `startableRevisionRoleIDs`, chosen by the run loop so the concurrency rule lives in
    /// one place.
    ///
    /// - Returns: the roles actually started, so the run loop can tell "made progress" from
    ///   "every candidate was already executing" and neither busy-loop nor announce a
    ///   dependency cycle that isn't one. (A started role may still flip to `.failed` inside
    ///   its task if its step can't be created — the loop catches that next iteration.)
    @discardableResult
    func startRevisionRoles(roleIDs: [String]) async -> [String] {
        guard let store else { return [] }

        var started: [String] = []
        for roleID in roleIDs {
            // The change REQUESTER is flagged `.revisionRequested` while its own step keeps
            // running (`holdDownstreamForRevision`), and `resetStepForRevision` no-ops on a
            // `.running` step — so without this guard a startable requester got a SECOND
            // concurrent execution driven into one step. Named as the hazard by
            // `EngineWakeTests.testCharacterization_holdDownstreamForRevision_leavesAPendingEngineUnstarted`.
            if hasLiveRoleTask(roleID) { continue }

            await store.updateRoleStatus(roleID: roleID, status: .working)
            onRoleStatusChanged?(roleID, .working)
            started.append(roleID)

            launchRoleTask(roleID: roleID) { engine, store in
                guard let stepID = await store.findOrCreateStep(roleID: roleID) else {
                    await store.updateRoleStatus(roleID: roleID, status: .failed)
                    store.setLastErrorMessageForUI("Revision failed for '\(roleID)': step not found.")
                    engine.onRoleStatusChanged?(roleID, .failed)
                    return
                }

                // Reset the step from .done/.failed to .pending for re-execution.
                // This also clears completedAt so it reflects the revision completion time.
                await store.resetStepForRevision(stepID: stepID)

                await store.prepareStepForExecution(stepID: stepID)
                await store.runStep(stepID: stepID)
                await engine.waitForStepCompletion(stepID: stepID, roleID: roleID)
            }
        }

        return started
    }

    // MARK: - Step Completion

    func waitForStepCompletion(stepID: String, roleID: String) async {
        guard let store else { return }

        while !Task.isCancelled {
            guard let status = store.stepStatus(stepID: stepID) else { return }

            switch status {
            case .done:
                await handleRoleCompleted(roleID: roleID)
                return
            case .failed:
                // TODO: When per-role error strategies are added to TeamSettings,
                // branch here — a role configured to skip on failure should land
                // on `.skipped` rather than `.failed`.
                await store.updateRoleStatus(roleID: roleID, status: .failed)
                onRoleStatusChanged?(roleID, .failed)
                return
            case .needsSupervisorInput:
                // Pause and wait for Supervisor
                return
            case .paused, .needsApproval:
                // Step is paused - wait
                return
            case .pending, .running:
                // Still running - wait a bit
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// The step-is-`.done` entry point, called by `waitForStepCompletion`.
    ///
    /// Double-processing protection is preserved without an explicit `.working` guard:
    /// after the first call the role is `.done` / `.needsAcceptance`, and
    /// `RoleStepReconciler` answers `.noAction` for both — as it does for the other
    /// never-touch statuses the old guard covered (`.revisionRequested`, `.failed`,
    /// `.accepted`, `.skipped`). Passing `.done` literally, rather than looking the step
    /// up, keeps this off any `stepID == roleID` assumption.
    func handleRoleCompleted(roleID: String) async {
        guard let run = store?.activeTask?.runs.last, let gate = acceptanceGate() else { return }

        await reconcileRole(
            roleID: roleID,
            roleStatus: run.roleStatuses[roleID],
            stepStatus: .done,
            gate: gate
        )
    }

}
