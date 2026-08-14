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
    ) async -> CollaborationReply {
        guard let delegate else { return .failed("Unable to process change request — delegate not available.") }
        let tid = task.id
        guard isExecutionLive(stepID: stepID, taskID: tid) else {
            return .failed("Unable to process change request — no task context.")
        }

        let team = resolveTeam(task: task)
        let teamSettings = team?.settings ?? .default

        // Re-read fresh task to get current run state (the `task` parameter
        // is a snapshot captured at step start and doesn't reflect mutations from prior iterations).
        let run: Run
        if let freshTask = delegate.loadedTask(tid),
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
        if let error = validation.error { return .failed(error) }
        guard let targetRoleDef = validation.targetRoleDef else { return .failed("Validation failed.") }

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

        // If the voting meeting cannot run (no participants, meeting-limit reached,
        // cancellation, no work folder), DO NOT fall through to the tally. This guard
        // predates `.noVotes` and used to be the ONLY thing standing between an empty
        // `meetingMessages` and an auto-approving `.tied`; `tallyVotes([])` now answers
        // `.noVotes`, so the tally is no longer a trapdoor. The guard stays because the
        // two situations are not the same fact and must not read alike to the requester:
        // "the meeting never happened" is an infrastructure failure it can retry, while
        // `.noVotes` is a meeting that ran and decided nothing. It also still avoids
        // tallying a stale prior `meetings.last`, which a non-persisted voting meeting
        // would leave pointing at — a real vote from an EARLIER meeting deciding this one.
        let meetingReply = await handleTeamMeeting(
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
        guard meetingReply.succeeded else {
            changeRequest.status = .rejected
            await recordChangeRequest(taskID: tid, changeRequest: changeRequest)
            return .failed("Change request could not be voted on — the voting meeting did not run: \(meetingReply.text)")
        }

        // Read back meeting messages from persisted state
        let updatedTask = delegate.loadedTask(tid)
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
                targetRole: targetRoleDef,
                changes: changes,
                reasoning: reasoning,
                requestingRoleID: requestingRole.baseID,
                requesterStepID: stepID,
                meetingID: meeting?.id,
                team: team
            )

            if case .failed = amendmentResult {
                return .failed("Change request APPROVED by team vote, but \(amendmentResult.text)")
            }
            return .ok("Change request APPROVED by team vote. \(amendmentResult.text)")

        case .rejected:
            changeRequest.status = .rejected
            await recordChangeRequest(taskID: tid, changeRequest: changeRequest)
            return .ok("Change request REJECTED by team vote. The existing work stands.")

        case .noVotes:
            // The meeting ran and decided nothing — no participant emitted a VOTE: token.
            // Rejecting is the only direction that cannot destroy work: approving here would
            // reset the target role and cascade a revision downstream on the strength of zero
            // votes. The existing work stands and the requester is told why.
            changeRequest.status = .rejected
            await recordChangeRequest(taskID: tid, changeRequest: changeRequest)
            return .ok(
                "Change request NOT carried — the voting meeting produced no votes. "
                + "Participants must reply with `VOTE: APPROVE` or `VOTE: REJECT`. "
                + "The existing work stands; ask again with a clearer request if the change is still needed."
            )

        case .tied:
            // V1: auto-approve on a genuine deadlock (Supervisor escalation in V2). Reachable
            // only with at least one vote on each side — 0-0 is `.noVotes` above.
            changeRequest.status = .approved
            await recordChangeRequest(taskID: tid, changeRequest: changeRequest)

            let amendmentResult = await executeAmendment(
                taskID: tid,
                targetRole: targetRoleDef,
                changes: changes,
                reasoning: reasoning,
                requestingRoleID: requestingRole.baseID,
                requesterStepID: stepID,
                meetingID: meeting?.id,
                team: team
            )

            if case .failed = amendmentResult {
                return .failed("Change request had a TIED VOTE — auto-approved, but \(amendmentResult.text)")
            }
            return .ok("Change request had a TIED VOTE — auto-approved. \(amendmentResult.text)")
        }
    }

    /// Outcome of `executeAmendment`. Typed rather than a bare `String` because the
    /// caller has to ROUTE it: an amendment that never ran must not be reported to the
    /// model inside a `.ok(...)` reply, which is what happens when success and failure
    /// share one return type and the caller string-interpolates it.
    nonisolated enum AmendmentOutcome {
        case initiated(String)
        case failed(String)

        var text: String {
            switch self {
            case .initiated(let t), .failed(let t): return t
            }
        }
    }

    func executeAmendment(
        taskID: Int,
        targetRole: TeamRoleDefinition,
        changes: String,
        reasoning: String,
        requestingRoleID: String,
        requesterStepID: String,
        meetingID: UUID?,
        team: Team?
    ) async -> AmendmentOutcome {
        // The `roleStatuses` key, which the engine seeds from `role.id`
        // (`RunService.initialRoleStatuses`) — deliberately NOT the step's id, which
        // may be the system role id on the runs `targetStep(in:for:)` exists for.
        let targetRoleID = targetRole.id
        guard let delegate else { return .failed("Amendment failed: no delegate.") }

        // Read current task state to get step info. Resolved through the SAME predicate
        // validation used — see `ChangeRequestService.targetStep(in:for:)`.
        guard let currentTask = delegate.loadedTask(taskID),
              let run = currentTask.runs.last,
              let targetStep = ChangeRequestService.targetStep(in: run, for: targetRole) else {
            return .failed("Amendment failed: target step not found.")
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
            guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == targetStep.id }) else { return }

            task.runs[runIndex].steps[stepIndex].amendments.append(amendment)

            let amendmentContext = """
                ## AMENDMENT REQUEST
                Requested by: \(requestingRoleID)
                Changes needed: \(changes)
                Reasoning: \(reasoning)

                Update your work to address these changes. Your original conversation and artifacts are preserved above. Produce updated artifacts that incorporate the requested changes.
                """

            task.runs[runIndex].steps[stepIndex].messages.append(
                StepMessage(role: .supervisor, content: amendmentContext)
            )
            // Raw revision payload — `resetStepForRevision` prefers this over re-deriving
            // from the last supervisor message, so the reset doesn't depend on the
            // amendment block still being the last `.supervisor` entry in `step.messages`
            // (`injectSupervisorCommentIfNeeded` appends "Supervisor Comment:" entries
            // there). The "Supervisor Feedback: " attribution is applied once at send
            // time, same as the requestRevision path.
            task.runs[runIndex].steps[stepIndex].revisionComment = amendmentContext
            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()

            // Set role to revisionRequested — engine picks this up via startRevisionRoles()
            task.runs[runIndex].roleStatuses[targetRoleID] = .revisionRequested
        }

        // Propagate to downstream roles (done AND running). Running roles are then
        // held (cancelled + queued for revision) so they don't keep working on the
        // now-stale upstream output. The requester (`requesterStepID`) is held WITHOUT
        // task-cancellation — see `holdDownstreamForRevision`.
        let propagation = await propagateAmendmentDownstream(
            taskID: taskID,
            sourceRoleID: targetRoleID,
            changes: changes,
            team: team
        )
        if !propagation.runningRoleIDs.isEmpty {
            await delegate.holdDownstreamForRevision(
                taskID: taskID,
                runningRoleIDs: propagation.runningRoleIDs,
                requesterRoleID: requesterStepID
            )
        }

        return .initiated("Amendment initiated for \(targetRoleID). \(propagation.summary)")
    }

    /// Result of fanning an amendment out to downstream roles.
    /// `runningRoleIDs` are downstream roles caught mid-execution — the caller hands
    /// them to `holdDownstreamForRevision` so they stop (strict pipeline) instead of
    /// finishing on the upstream's now-stale output.
    nonisolated struct PropagationResult {
        var summary: String
        var runningRoleIDs: [String]
    }

    func propagateAmendmentDownstream(
        taskID: Int,
        sourceRoleID: String,
        changes: String,
        team: Team?
    ) async -> PropagationResult {
        guard let delegate else { return PropagationResult(summary: "", runningRoleIDs: []) }
        let roles = team?.roles ?? []

        let downstreamRoleIDs = ArtifactDependencyResolver.getDownstreamRoles(
            of: sourceRoleID,
            roles: roles
        )

        guard !downstreamRoleIDs.isEmpty else {
            return PropagationResult(summary: "No downstream roles affected.", runningRoleIDs: [])
        }

        var amendedRoles: [String] = []
        var runningRoleIDs: [String] = []

        await delegate.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }

            // Strict pipeline: a downstream role is re-run whether it had finished
            // (`.done`) OR was caught mid-execution (`.running`). Both get the
            // amendment notice + raw `revisionComment`; only the engine-side teardown
            // differs (the running set is handled by `holdDownstreamForRevision`).
            for roleID in downstreamRoleIDs {
                guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.effectiveRoleID == roleID }) else { continue }

                let stepStatus = task.runs[runIndex].steps[stepIndex].status
                let roleStatus = task.runs[runIndex].roleStatuses[roleID] ?? .idle
                let isDone = stepStatus == .done && (roleStatus == .done || roleStatus == .accepted || roleStatus == .needsAcceptance)
                let isRunning = stepStatus == .running
                guard isDone || isRunning else { continue }  // idle / not started: no action

                let contextMsg = """
                    ## UPSTREAM AMENDMENT NOTICE
                    Role '\(sourceRoleID)' is amending their work.
                    Changes: \(changes)

                    Review and update your work if affected by these upstream changes.
                    """
                task.runs[runIndex].steps[stepIndex].messages.append(
                    StepMessage(role: .supervisor, content: contextMsg)
                )
                // Raw revision payload — same invariant as executeAmendment above.
                task.runs[runIndex].steps[stepIndex].revisionComment = contextMsg
                task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()

                if isDone {
                    // Already terminal — queue the revision directly. (Running roles are
                    // NOT flipped here: their status is set by `holdDownstreamForRevision`
                    // after the step is forced terminal, so the run loop can't try to
                    // re-run a still-`.running` step.)
                    task.runs[runIndex].roleStatuses[roleID] = .revisionRequested
                    amendedRoles.append(roleID)
                } else {
                    runningRoleIDs.append(roleID)
                }
            }
        }

        var result = ""
        if !amendedRoles.isEmpty {
            result += "Downstream amendments triggered: \(amendedRoles.joined(separator: ", ")). "
        }
        if !runningRoleIDs.isEmpty {
            result += "Running downstream roles held for revision: \(runningRoleIDs.joined(separator: ", "))."
        }
        if amendedRoles.isEmpty && runningRoleIDs.isEmpty {
            result = "No downstream roles needed updates."
        }
        return PropagationResult(summary: result, runningRoleIDs: runningRoleIDs)
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

