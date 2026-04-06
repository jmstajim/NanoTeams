import Foundation

/// Change request flow: validate → voting meeting → tally → amend → propagate downstream.
extension LLMExecutionService {

    // MARK: - Change Requests

    /// Orchestrates the full change request flow: validate → meeting → vote → amend.
    func handleChangeRequest(
        stepID: String,
        targetRoleID: String,
        changes: String,
        reasoning: String,
        requestingRole: Role,
        task: NTMSTask,
        runIndex: Int,
        stepIndex: Int,
        client: any LLMClient,
        config: LLMConfig,
        networkLogger: NetworkLogger? = nil
    ) async -> String {
        guard let delegate else { return "Unable to process change request — delegate not available." }
        guard let tid = taskIDForStep(stepID) else { return "Unable to process change request — no task context." }

        let team = resolveTeam(task: task)
        let teamSettings = team?.settings ?? .default

        // Re-read fresh task to get current run state (the `task` parameter
        // is a snapshot captured at step start and doesn't reflect mutations from prior iterations).
        let run: Run
        if let freshTask = await { delegate.loadedTask(tid) }(),
           runIndex < freshTask.runs.count {
            run = freshTask.runs[runIndex]
        } else {
            run = task.runs[runIndex]
        }

        // Validate change request
        let validation = ChangeRequestService.validateChangeRequest(
            targetRoleID: targetRoleID,
            requestingRole: requestingRole,
            team: team,
            teamSettings: teamSettings,
            run: run
        )
        if let error = validation.error { return error }
        guard let targetRoleDef = validation.targetRoleDef else { return "Validation failed." }

        // Create ChangeRequest record (use resolved role def ID, not raw LLM string)
        var changeRequest = ChangeRequest(
            requestingRoleID: requestingRole.baseID,
            targetRoleID: targetRoleDef.id,
            changes: changes,
            reasoning: reasoning,
            status: .pending
        )

        // Determine meeting participants: target + downstream consumers of target's artifacts
        let targetArtifacts = Set(targetRoleDef.dependencies.producesArtifacts)
        let resolvedTargetID = targetRoleDef.id
        let downstreamRoleIDs = (team?.roles ?? []).compactMap { roleDef -> String? in
            guard !roleDef.isSupervisor,
                  roleDef.id != requestingRole.baseID,
                  roleDef.id != resolvedTargetID,
                  !Set(roleDef.dependencies.requiredArtifacts).isDisjoint(with: targetArtifacts) else { return nil }
            return roleDef.id
        }

        var participantIDs = [resolvedTargetID] + downstreamRoleIDs
        let filtered = MeetingParticipantResolver.filterParticipants(
            participantIDs: participantIDs,
            initiatingRole: requestingRole,
            team: team,
            teamSettings: teamSettings
        )
        participantIDs = filtered.participants.map { $0.baseID }

        // Run voting meeting
        let voting = ChangeRequestService.buildVotingContext(
            requestingRole: requestingRole,
            targetRoleDef: targetRoleDef,
            changes: changes,
            reasoning: reasoning
        )

        let meetingResultString = await handleTeamMeeting(
            stepID: stepID,
            topic: voting.topic,
            participantIDs: participantIDs,
            context: voting.context,
            initiatingRole: requestingRole,
            task: task,
            runIndex: runIndex,
            stepIndex: stepIndex,
            client: client,
            config: config,
            networkLogger: networkLogger
        )

        // Read back meeting messages from persisted state
        let updatedTask = await { () -> NTMSTask? in
            return delegate.loadedTask(tid)
        }()
        let latestRun = updatedTask?.runs.last
        let meeting = latestRun?.meetings.last
        changeRequest.meetingID = meeting?.id

        let meetingMessages = meeting?.messages ?? []

        // Tally votes
        let voteResult = ChangeRequestService.tallyVotes(meetingMessages: meetingMessages)

        // Handle decision
        switch voteResult {
        case .approved:
            changeRequest.status = .approved
            await recordChangeRequest(taskID: tid, changeRequest: changeRequest)

            let amendmentResult = await executeAmendment(
                taskID: tid,
                targetRoleID: resolvedTargetID,
                changes: changes,
                reasoning: reasoning,
                requestingRoleID: requestingRole.baseID,
                meetingID: meeting?.id,
                team: team
            )

            return "Change request APPROVED by team vote. \(amendmentResult)"

        case .rejected:
            changeRequest.status = .rejected
            await recordChangeRequest(taskID: tid, changeRequest: changeRequest)
            return "Change request REJECTED by team vote. The existing work stands."

        case .tied:
            // V1: auto-approve on tie (Supervisor escalation in V2)
            changeRequest.status = .approved
            await recordChangeRequest(taskID: tid, changeRequest: changeRequest)

            let amendmentResult = await executeAmendment(
                taskID: tid,
                targetRoleID: resolvedTargetID,
                changes: changes,
                reasoning: reasoning,
                requestingRoleID: requestingRole.baseID,
                meetingID: meeting?.id,
                team: team
            )

            return "Change request had a TIED VOTE — auto-approved. \(amendmentResult)"
        }
    }

    func executeAmendment(
        taskID: Int,
        targetRoleID: String,
        changes: String,
        reasoning: String,
        requestingRoleID: String,
        meetingID: UUID?,
        team: Team?
    ) async -> String {
        guard let delegate else { return "Amendment failed: no delegate." }

        // Read current task state to get step info
        guard let currentTask = delegate.loadedTask(taskID),
              let run = currentTask.runs.last,
              let targetStep = run.steps.first(where: { $0.id == targetRoleID }) else {
            return "Amendment failed: target step not found."
        }

        // Snapshot current artifacts
        let snapshots = targetStep.artifacts.map { artifact in
            ArtifactSnapshot(
                artifactName: artifact.name,
                relativePath: artifact.relativePath
            )
        }

        // Create amendment record
        let amendment = StepAmendment(
            requestedByRoleID: requestingRoleID,
            reason: changes,
            meetingID: meetingID,
            meetingDecision: "approved",
            previousArtifactSnapshots: snapshots
        )

        // Record amendment and inject context into step.messages
        await delegate.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }
            guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == targetRoleID }) else { return }

            task.runs[runIndex].steps[stepIndex].amendments.append(amendment)

            let amendmentContext = """
                === AMENDMENT REQUEST ===
                Requested by: \(requestingRoleID)
                Changes needed: \(changes)
                Reasoning: \(reasoning)

                Please update your work to address these changes. Your original conversation and artifacts are preserved above.
                Produce updated artifacts that incorporate the requested changes.
                === END AMENDMENT ===
                """

            task.runs[runIndex].steps[stepIndex].messages.append(
                StepMessage(role: .supervisor, content: amendmentContext)
            )
            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()

            // Set role to revisionRequested — engine picks this up via startRevisionRoles()
            task.runs[runIndex].roleStatuses[targetRoleID] = .revisionRequested
        }

        // Propagate to downstream done roles
        let propagationResult = await propagateAmendmentDownstream(
            taskID: taskID,
            sourceRoleID: targetRoleID,
            changes: changes,
            team: team
        )

        return "Amendment initiated for \(targetRoleID). \(propagationResult)"
    }

    func propagateAmendmentDownstream(
        taskID: Int,
        sourceRoleID: String,
        changes: String,
        team: Team?
    ) async -> String {
        guard let delegate else { return "" }
        let roles = team?.roles ?? []

        let downstreamRoleIDs = ArtifactDependencyResolver.getDownstreamRoles(
            of: sourceRoleID,
            roles: roles
        )

        guard !downstreamRoleIDs.isEmpty else { return "No downstream roles affected." }

        var amendedRoles: [String] = []
        var contextInjectedRoles: [String] = []

        await delegate.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }

            for roleID in downstreamRoleIDs {
                guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.effectiveRoleID == roleID }) else { continue }

                let stepStatus = task.runs[runIndex].steps[stepIndex].status
                let roleStatus = task.runs[runIndex].roleStatuses[roleID] ?? .idle

                if stepStatus == .done && (roleStatus == .done || roleStatus == .accepted || roleStatus == .needsAcceptance) {
                    // Done role: trigger amendment via revisionRequested
                    let contextMsg = """
                        === UPSTREAM AMENDMENT NOTICE ===
                        Role '\(sourceRoleID)' is amending their work.
                        Changes: \(changes)

                        Please review and update your work if affected by these upstream changes.
                        === END NOTICE ===
                        """
                    task.runs[runIndex].steps[stepIndex].messages.append(
                        StepMessage(role: .supervisor, content: contextMsg)
                    )
                    task.runs[runIndex].roleStatuses[roleID] = .revisionRequested
                    task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
                    amendedRoles.append(roleID)

                } else if stepStatus == .running {
                    // Working role: inject context message only (visible on re-execution)
                    let contextMsg = """
                        NOTE: Upstream role '\(sourceRoleID)' is making changes to their work.
                        Changes: \(changes)
                        Take this into account as you continue.
                        """
                    task.runs[runIndex].steps[stepIndex].messages.append(
                        StepMessage(role: .supervisor, content: contextMsg)
                    )
                    task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
                    contextInjectedRoles.append(roleID)
                }
                // Not started / idle: no action needed
            }
        }

        var result = ""
        if !amendedRoles.isEmpty {
            result += "Downstream amendments triggered: \(amendedRoles.joined(separator: ", ")). "
        }
        if !contextInjectedRoles.isEmpty {
            result += "Context injected to working roles: \(contextInjectedRoles.joined(separator: ", "))."
        }
        if amendedRoles.isEmpty && contextInjectedRoles.isEmpty {
            result = "No downstream roles needed updates."
        }
        return result
    }

    func recordChangeRequest(taskID: Int, changeRequest: ChangeRequest) async {
        guard let delegate else { return }
        await delegate.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }
            // Upsert: replace existing or append new
            if let idx = task.runs[runIndex].changeRequests.firstIndex(where: { $0.id == changeRequest.id }) {
                task.runs[runIndex].changeRequests[idx] = changeRequest
            } else {
                task.runs[runIndex].changeRequests.append(changeRequest)
            }
        }
    }
}

