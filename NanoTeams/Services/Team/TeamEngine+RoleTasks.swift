import Foundation

// MARK: - Role Tasks

extension TeamEngine {

    /// Reconcile role statuses after pause — a role task may have completed
    /// (step → .done/.failed) before cancellation took effect, or a step may
    /// have been paused after an external event (e.g., Supervisor answered ask_supervisor).
    func reconcileAfterPause() async {
        guard let store, let run = store.activeTask?.runs.last else { return }
        let stepMap = run.stepsByRoleBaseID()
        for (roleID, status) in run.roleStatuses where status == .working {
            if let step = stepMap[roleID] {
                if step.status == .done {
                    await handleRoleCompleted(roleID: roleID)
                } else if step.status == .failed {
                    await store.updateRoleStatus(roleID: roleID, status: .failed)
                    onRoleStatusChanged?(roleID, .failed)
                } else if step.status == .paused || step.status == .pending {
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

    func startRevisionRoles(roleStatuses: [String: RoleExecutionStatus]) async {
        guard let store else { return }

        let revisionRoleIDs = roleStatuses.compactMap { (roleID, status) -> String? in
            status == .revisionRequested ? roleID : nil
        }

        for roleID in revisionRoleIDs {
            await store.updateRoleStatus(roleID: roleID, status: .working)
            onRoleStatusChanged?(roleID, .working)

            roleTasks[roleID] = Task { [weak self] in
                guard let self, let store = self.store else { return }

                guard let stepID = await store.findOrCreateStep(roleID: roleID) else {
                    await store.updateRoleStatus(roleID: roleID, status: .failed)
                    await store.setLastErrorMessageForUI("Revision failed for '\(roleID)': step not found.")
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
                // consult ErrorRecoveryService here. If strategy == .skip, use .skipped.
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
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func handleRoleCompleted(roleID: String) async {
        guard let store else { return }
        guard let task = store.activeTask else { return }

        // Prevent double-processing: both reconciliation pass and waitForStepCompletion
        // can detect step .done and call this method. Only process once while .working.
        guard let run = task.runs.last,
              run.roleStatuses[roleID] == .working else { return }

        let acceptanceMode = AcceptanceService.effectiveAcceptanceMode(
            for: task,
            teamSettings: store.teamSettings
        )
        let checkpoints = AcceptanceService.effectiveCheckpoints(
            for: task,
            teamSettings: store.teamSettings
        )

        // Determine if this is the last role
        let isLastRole = isLastRoleToComplete(roleID: roleID)

        // Check if acceptance is needed
        let needsAcceptance = AcceptanceService.shouldRequestAcceptance(
            roleID: roleID,
            mode: acceptanceMode,
            checkpoints: checkpoints,
            isLastRole: isLastRole
        )

        if needsAcceptance {
            await store.updateRoleStatus(roleID: roleID, status: .needsAcceptance)
            onRoleStatusChanged?(roleID, .needsAcceptance)
        } else {
            await store.updateRoleStatus(roleID: roleID, status: .done)
            onRoleStatusChanged?(roleID, .done)
        }
    }

    func isLastRoleToComplete(roleID: String) -> Bool {
        guard let store else { return true }
        guard let run = store.activeTask?.runs.last else { return true }

        let roleStatuses = run.roleStatuses
        let roles = store.activeTeam?.roles ?? []

        for role in roles {
            guard !role.isSupervisor else { continue }
            guard !role.isObserver else { continue }
            guard role.id != roleID else { continue }  // Skip the completing role

            let status = roleStatuses[role.id] ?? .idle
            if !status.isComplete {
                return false
            }
        }

        return true
    }
}
