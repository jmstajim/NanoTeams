import Foundation

// MARK: - Run Loop

extension TeamEngine {

    func runLoop() async {
        guard let store else {
            transition(to: .failed)
            return
        }

        while !Task.isCancelled {
            guard let task = store.activeTask, let run = task.runs.last else {
                transition(to: .failed)
                return
            }

            // Check iteration limit
            iterationCount += 1
            if iterationCount >= autoIterationLimit {
                transition(to: .paused)
                await store.setLastErrorMessageForUI(
                    "Run paused: iteration limit (\(autoIterationLimit)) reached. " +
                    "Press Resume to continue, or increase 'Auto iterations limit' in Team Settings."
                )
                return
            }

            // Reconcile working roles whose steps already completed.
            // runStep() is fire-and-forget so artifacts are produced as soon as
            // step.status becomes .done, but waitForStepCompletion (250 ms poll)
            // may not have updated the role status yet.  Without this pass the
            // loop can start a downstream role while the predecessor still shows
            // .working in the graph.
            let stepMap = run.stepsByRoleBaseID()
            for (roleID, roleStatus) in run.roleStatuses where roleStatus == .working {
                if let step = stepMap[roleID] {
                    switch step.status {
                    case .done:
                        await handleRoleCompleted(roleID: roleID)
                    case .failed:
                        await store.updateRoleStatus(roleID: roleID, status: .failed)
                        onRoleStatusChanged?(roleID, .failed)
                    case .needsApproval:
                        await store.updateRoleStatus(roleID: roleID, status: .needsAcceptance)
                        onRoleStatusChanged?(roleID, .needsAcceptance)
                    default:
                        break
                    }
                }
            }

            // Re-read after reconciliation — role statuses may have changed
            guard let currentRun = store.activeTask?.runs.last else {
                transition(to: .failed)
                return
            }

            // Get current role statuses
            let roleStatuses = currentRun.roleStatuses
            let producedArtifacts = store.producedArtifactNames()

            // Check for failed roles
            if roleStatuses.values.contains(.failed) {
                transition(to: .failed)
                return
            }

            // Read team config once per iteration
            guard let team = store.activeTeam else {
                transition(to: .failed)
                return
            }
            let isChatMode = team.isChatMode

            // Check for roles needing acceptance (skip in chat mode — no acceptance flow)
            if !isChatMode {
                let pendingAcceptances = AcceptanceService.getPendingAcceptances(roleStatuses: roleStatuses)
                if !pendingAcceptances.isEmpty {
                    transition(to: .needsAcceptance)
                    return
                }
            }

            // Check for roles needing Supervisor input
            if currentRun.steps.contains(where: { $0.status == .needsSupervisorInput }) {
                if team.settings.supervisorMode == .manual {
                    transition(to: .needsSupervisorInput)
                    return
                }
            }

            // Check if all roles are done (chat-mode teams never auto-complete)
            let teamRoles = team.roles
            if allRolesComplete(roleStatuses: roleStatuses, roles: teamRoles, isChatMode: isChatMode) {
                // Mark observer roles as complete before transitioning
                await markObserversComplete()
                transition(to: .done)
                return
            }

            // Find ready roles (dependencies satisfied, not already working/done)
            let readyRoleIDs = findReadyRoles(
                roles: teamRoles,
                producedArtifacts: producedArtifacts,
                roleStatuses: roleStatuses
            )

            if readyRoleIDs.isEmpty {
                // No ready roles - wait for working roles to complete or external event
                if roleStatuses.values.contains(.working) {
                    // Wait a bit and check again
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                } else if !isChatMode && roleStatuses.values.contains(.needsAcceptance) {
                    // Waiting for Supervisor
                    transition(to: .needsAcceptance)
                    return
                } else if roleStatuses.values.contains(.revisionRequested) {
                    // Roles in revision - start them
                    await startRevisionRoles(roleStatuses: roleStatuses)
                    continue
                } else if isChatMode && allRolesComplete(roleStatuses: roleStatuses, roles: teamRoles, isChatMode: false) {
                    // Chat-mode auto-complete arm: every non-supervisor non-observer role
                    // has reached a terminal status (advisory auto-finish in autonomous
                    // mode is the only existing producer). `allRolesComplete(isChatMode:)`
                    // hard-returns false in chat mode, so we re-call with `false` to use
                    // the underlying check. Without this arm, the only chat-mode path out
                    // of this block is the deadlock else, which transitions to `.failed`
                    // — wrong, since the team genuinely is done.
                    await markObserversComplete()
                    transition(to: .done)
                    return
                } else {
                    // Deadlock or configuration error
                    let stuckRoles = roleStatuses.filter { !$0.value.isComplete && $0.value != .working }
                    let names = stuckRoles.keys.sorted().joined(separator: ", ")
                    transition(to: .failed)
                    await store.setLastErrorMessageForUI(
                        "Execution stalled: roles [\(names)] blocked. Check artifact dependencies in Team Editor."
                    )
                    return
                }
            }

            // Start ready roles (in parallel)
            await startRoles(roleIDs: readyRoleIDs)

            // Small delay before next iteration
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Helpers

    func allRolesComplete(
        roleStatuses: [String: RoleExecutionStatus],
        roles: [TeamRoleDefinition],
        isChatMode: Bool = false
    ) -> Bool {
        // Chat-mode teams never auto-complete — advisory roles run indefinitely
        if isChatMode { return false }

        // Only check roles that are active team members (skip Supervisor and observers)
        for role in roles {
            guard !role.isSupervisor && !role.isObserver else { continue }

            let status = roleStatuses[role.id] ?? .idle
            if !status.isComplete {
                return false
            }
        }

        return true
    }

    /// Marks all observer roles as .done when the run completes.
    /// Observer roles don't execute steps but should show as complete when task is done.
    func markObserversComplete() async {
        let roles = store?.activeTeam?.roles ?? []
        for role in roles where role.isObserver {
            await store?.updateRoleStatus(roleID: role.id, status: .done)
        }
    }
}
