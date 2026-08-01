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

    /// Reconcile role statuses after pause — a role task may have completed
    /// (step → .done/.failed) before cancellation took effect, or a step may
    /// have been paused after an external event (e.g., Supervisor answered ask_supervisor).
    ///
    /// Also runs on `start()` (see `launchRunLoop`), which is the path a post-restart
    /// `resumeRun` takes.
    func reconcileAfterPause() async {
        guard let store, let run = store.activeTask?.runs.last, let gate = acceptanceGate() else { return }
        let stepMap = run.stepsByRoleBaseID()
        for (roleID, status) in run.roleStatuses {
            let step = stepMap[roleID]

            // Settle first — this arm is gated on the ROLE's own status via
            // `RoleStepReconciler`, so it also heals a role a previous launch's
            // recovery left at `.idle` next to a terminal step. It additionally
            // covers `.needsApproval`, which this method never used to handle.
            if await reconcileRole(roleID: roleID, roleStatus: status, stepStatus: step?.status, gate: gate) {
                continue
            }

            // The RESTART arm stays `.working`-gated on purpose. Settling is bookkeeping;
            // restarting is an execution decision, and this arm does NOT write `.working`
            // — firing it for an `.idle` role would run a step while the role reads
            // `.idle`, and would duplicate `resumeRun`'s own recovery branch, re-running
            // work the Supervisor never asked to resume.
            guard status == .working, let step,
                  step.status == .paused || step.status == .pending
            else { continue }

            // Step was paused or reset to pending while role was working
            // (e.g., Supervisor answered ask_supervisor sets .pending, or pause/resume sets .paused).
            // Restart step execution so the LLM can continue with the full conversation.
            roleTasks[roleID] = Task { [weak self] in
                guard let self, let store = self.store else { return }
                await store.prepareStepForExecution(stepID: step.id)
                await store.runStep(stepID: step.id)
                await self.waitForStepCompletion(stepID: step.id, roleID: roleID)
            }
        }
    }

    // MARK: - Finding Ready Roles

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

        return readyRoleIDs
    }

    // MARK: - Starting Roles

    func startRoles(roleIDs: [String]) async {
        guard let store else { return }

        for roleID in roleIDs {
            // Skip if already running
            if let existingTask = roleTasks[roleID], !existingTask.isCancelled {
                continue
            }

            // Update status to working
            await store.updateRoleStatus(roleID: roleID, status: .working)
            onRoleStatusChanged?(roleID, .working)

            // Create step if needed and start execution
            roleTasks[roleID] = Task { [weak self] in
                guard let self, let store = self.store else { return }

                guard let stepID = await store.findOrCreateStep(roleID: roleID) else {
                    await store.updateRoleStatus(roleID: roleID, status: .failed)
                    self.onRoleStatusChanged?(roleID, .failed)
                    return
                }

                await store.prepareStepForExecution(stepID: stepID)
                await store.runStep(stepID: stepID)

                // Wait for step to complete
                await self.waitForStepCompletion(stepID: stepID, roleID: roleID)
            }
        }
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
    nonisolated static func startableRevisionRoleIDs(
        roleStatuses: [String: RoleExecutionStatus],
        roles: [TeamRoleDefinition]
    ) -> [String] {
        let revisionRoleIDs = roleStatuses.compactMap { (roleID, status) -> String? in
            status == .revisionRequested ? roleID : nil
        }
        guard !revisionRoleIDs.isEmpty else { return [] }

        let resolver = ArtifactDependencyResolver(roles: roles)
        let blockingStatuses: [RoleExecutionStatus] = [.revisionRequested, .working]

        return revisionRoleIDs.filter { roleID in
            let upstream = resolver.dependencyRoleIDs(of: roleID)
            return !upstream.contains { blockingStatuses.contains(roleStatuses[$0] ?? .idle) }
        }
    }

    /// Starts the revision-requested roles whose upstream dependencies are clear
    /// (see `startableRevisionRoleIDs`). Returns the number of startable roles
    /// scheduled this pass so the run loop can distinguish "made progress" from
    /// "everything is blocked" (a dependency cycle) and fail loudly instead of
    /// busy-looping. (A scheduled role may still flip to `.failed` in its task if its
    /// step can't be created — the run loop catches that on the next iteration.)
    @discardableResult
    func startRevisionRoles(roleStatuses: [String: RoleExecutionStatus]) async -> Int {
        guard let store else { return 0 }

        let startableRoleIDs = Self.startableRevisionRoleIDs(
            roleStatuses: roleStatuses,
            roles: store.activeTeam?.roles ?? []
        )

        for roleID in startableRoleIDs {
            await store.updateRoleStatus(roleID: roleID, status: .working)
            onRoleStatusChanged?(roleID, .working)

            roleTasks[roleID] = Task { [weak self] in
                guard let self, let store = self.store else { return }

                guard let stepID = await store.findOrCreateStep(roleID: roleID) else {
                    await store.updateRoleStatus(roleID: roleID, status: .failed)
                    store.setLastErrorMessageForUI("Revision failed for '\(roleID)': step not found.")
                    self.onRoleStatusChanged?(roleID, .failed)
                    return
                }

                // Reset the step from .done/.failed to .pending for re-execution.
                // This also clears completedAt so it reflects the revision completion time.
                await store.resetStepForRevision(stepID: stepID)

                await store.prepareStepForExecution(stepID: stepID)
                await store.runStep(stepID: stepID)
                await self.waitForStepCompletion(stepID: stepID, roleID: roleID)
            }
        }

        return startableRoleIDs.count
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
