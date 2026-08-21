import Foundation

/// Team meeting orchestration: request_team_meeting tool handling, turn loop, and participant filtering.
extension LLMExecutionService {

    // MARK: - Team Meetings

    func handleTeamMeeting(
        stepID: String,
        topic: String,
        participantIDs: [String],
        context: String?,
        initiatingRole: Role,
        task: NTMSTask,
        runIndex: Int,
        stepIndex: Int,
        client: any LLMClient,
        config: LLMConfig,
        networkLogger: NetworkLogger? = nil
    ) async -> CollaborationReply {
        guard let delegate else { return .failed("Unable to conduct meeting — delegate not available.") }
        let tid = task.id
        guard isExecutionLive(stepID: stepID, taskID: tid) else {
            return .failed("Unable to conduct meeting — no task context.")
        }
        guard let workFolderRoot = delegate.workFolderURL else { return .failed("Unable to conduct meeting — no work folder.") }

        // Resolve team
        let team = resolveTeam(task: task)
        let teamSettings = team?.settings ?? .default

        // Convert participant IDs to Roles, filtering against team constraints
        let filteredParticipants = MeetingParticipantResolver.filterParticipants(
            participantIDs: participantIDs,
            initiatingRole: initiatingRole,
            team: team,
            teamSettings: teamSettings
        )
        let participants = filteredParticipants.participants
        let rejectedReasons = filteredParticipants.rejectedReasons

        if participants.isEmpty {
            let available = MeetingParticipantResolver.availableTeammatesList(team: team, teamSettings: teamSettings, excludeRoleID: initiatingRole.baseID)
            let rejected = rejectedReasons.isEmpty ? "" : " Rejected: \(rejectedReasons.joined(separator: ", "))."
            return .failed("No valid participants for this meeting.\(rejected) Available teammates: \(available)")
        }

        // Re-read fresh task to get current meeting count (the `task` parameter
        // is a snapshot captured at step start and doesn't reflect mutations from prior iterations).
        let run = task.runs[runIndex]
        let freshMeetings: [TeamMeeting]
        if let freshTask = delegate.loadedTask(tid),
           runIndex < freshTask.runs.count {
            freshMeetings = freshTask.runs[runIndex].meetings
        } else {
            freshMeetings = run.meetings
        }
        if TeamMeetingService.hasReachedMeetingLimit(
            meetings: freshMeetings, limits: teamSettings.limits
        ) {
            return .failed("Meeting limit reached for this run (\(teamSettings.limits.maxMeetingsPerRun)). Cannot conduct another meeting.")
        }

        // Create meeting
        var meeting = TeamMeetingService.createMeeting(
            topic: topic, initiatedBy: initiatingRole, participants: participants, context: context
        )

        // Signal UI
        var allParticipantIDs: Set<String> = []
        for p in participants {
            allParticipantIDs.insert(team?.findRole(byIdentifier: p.baseID)?.id ?? p.baseID)
        }
        allParticipantIDs.insert(team?.findRole(byIdentifier: initiatingRole.baseID)?.id ?? initiatingRole.baseID)
        delegate.setActiveMeetingParticipants(allParticipantIDs, for: tid)

        defer {
            Task { @MainActor in
                delegate.clearActiveMeetingParticipants(for: tid)
            }
        }

        // Collect available artifacts
        let step = run.steps[stepIndex]
        var availableArtifacts: [Artifact] = []
        for i in 0..<stepIndex {
            availableArtifacts.append(contentsOf: run.steps[i].artifacts)
        }
        availableArtifacts.append(contentsOf: step.artifacts)

        // Resolve the effective coordinator for THIS meeting. In Auto mode
        // (no designated coordinator) or when the designated ID is orphaned
        // (deleted role), the initiator becomes the coordinator of meetings
        // they start — so wrap-up / steering / conclusion attribution all
        // land on the initiating role. Never nil.
        let coordinator: Role = effectiveCoordinator(team: team, initiator: initiatingRole)
        // Orphan path is silent runtime self-heal; surface a one-shot info
        // message so the Supervisor learns their explicit coordinator pick
        // was dropped (and where to fix it).
        reportOrphanCoordinatorIfNeeded(team: team)

        // Per-role LLM config resolver
        let meetingConfigResolver: (Role) -> LLMConfig = { speakerRole in
            let roleDef = team?.findRole(byIdentifier: speakerRole.baseID)
            return Self.buildEffectiveConfig(
                globalConfig: config, roleOverride: roleDef?.llmOverride
            )
        }

        // Build meeting context (still needed for tool loop fallback + turn completion)
        let meetingContext = TeamMeetingService.MeetingContext(
            initiatedBy: initiatingRole,
            participants: participants,
            availableArtifacts: availableArtifacts,
            artifactReader: { [weak self] artifact in
                guard let workFolderRoot = self?.delegate?.workFolderURL else { return nil }
                return ArtifactService.readContent(artifact: artifact, workFolderRoot: workFolderRoot)
            },
            team: team,
            coordinatorRole: coordinator,
            limits: teamSettings.limits,
            globalContext: delegate.globalLLMContext
        )

        // Tool runtime for meeting tool calls
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let isDefaultStorage = workFolderRoot == NTMSOrchestrator.defaultStorageURL
        let meetingToolCallsLogURL: URL? = delegate.loggingEnabled
            ? paths.toolCallsJSONL(taskID: tid, runID: run.id,
                                   ancestors: delegate.snapshot?.tasksIndex.ancestorIDs(of: tid) ?? [])
            : nil
        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: workFolderRoot, toolCallsLogURL: meetingToolCallsLogURL,
            networkLogger: networkLogger,
            isDefaultStorage: isDefaultStorage,
            searchExploratoryByDefault: delegate.searchExploratoryByDefault,
            readFileMaxLines: delegate.readFileMaxLines,
            searchMaxResults: delegate.searchMaxResults,
            searchContextBefore: delegate.searchContextBefore,
            searchContextAfter: delegate.searchContextAfter
        )
        let meetingRoleID = stepID
        let toolContext = ToolExecutionContext(
            workFolderRoot: workFolderRoot, taskID: tid, runID: run.id, roleID: meetingRoleID
        )

        // Run meeting turns via consultation chats
        let maxTurns = teamSettings.limits.maxMeetingTurns
        var shouldContinue = true

        do {
            while shouldContinue {
                if Task.isCancelled { throw CancellationError() }

                // Start meeting if pending
                if meeting.status == .pending { meeting.start() }

                // Check turn limit
                if TeamMeetingService.hasReachedTurnLimit(meeting: meeting, limits: teamSettings.limits) {
                    meeting.complete()
                    await recordMeeting(stepID: stepID, taskID: tid, meeting: meeting)
                    break
                }

                // Determine next speaker
                let speaker = MeetingStreamingService.determineNextSpeaker(
                    meeting: meeting, participants: participants, coordinator: coordinator
                )
                let speakerConfig = meetingConfigResolver(speaker)
                let speakerTools = MeetingCoordinator.filterMeetingTools(
                    Self.filterForGitAvailability(
                        Self.filterForDefaultStorage(
                            toolSchemas(for: speaker, team: team),
                            isDefaultStorage: isDefaultStorage
                        ),
                        workFolderRoot: workFolderRoot
                    )
                )

                // Build the speaker's meeting conversation: the team's MEETING
                // template as system prompt + artifact grounding + one
                // consolidated turn (header, discussion so far, directive).
                // Meetings run on their own per-turn stateless stack — NOT the
                // role's consultation chat, whose system prompt is the
                // consultation template. Pre-fix, the user-editable meeting
                // template never reached the wire on the initial call, and the
                // tool follow-up swapped system prompts mid-turn.
                let turnMessages = MeetingStreamingService.buildMeetingMessages(
                    speaker: speaker,
                    meeting: meeting,
                    context: meetingContext,
                    tools: speakerTools
                )

                // A meeting turn is a genuine accumulating chain, not a one-shot: its tool
                // follow-ups continue this exact array (see `executeTurnToolLoop` below), so it
                // both loses its own prefix and evicts other callers on the shared model.
                // `LLMCallOwner` names it as a required `.chain` and it was never registered.
                //
                // Keyed by (task, run, meeting, SPEAKER). The speaker belongs in the key because
                // each one gets its own system prompt — segment 0 differs by construction, so two
                // speakers are two conversations and comparing them would manufacture a
                // `systemPromptChanged` on every rotation. Within one speaker the wire is
                // append-only (`buildMeetingMessages`), so this chain measures something real: the
                // discussion should stay cached from that speaker's previous turn onward.
                //
                // Built ONCE here and handed to the follow-up loop rather than recomputed there,
                // so a turn and its tool follow-ups land on the same chain.
                let meetingChainID =
                    "meeting:\(tid):\(run.id):\(meeting.id.uuidString):\(speaker.baseID)"
                _ = await prefixLedger.record(
                    baseURL: speakerConfig.baseURLString,
                    model: speakerConfig.modelName,
                    owner: .chain(id: meetingChainID),
                    messages: turnMessages,
                    toolSchemaText: "")

                let streamResult = try await MeetingStreamingService.streamParticipantResponse(
                    messages: turnMessages,
                    client: client,
                    config: speakerConfig,
                    tools: speakerTools,
                    logger: networkLogger,
                    stepID: stepID
                )

                // The cancellation registrar gives the orchestrator a handle
                // on the in-flight detached batch so `cancelAllExecutions` can
                // stop a meeting tool turn mid-run — without it, pause-during-
                // meeting would silently run the batch to completion.
                //
                // Tool follow-ups CONTINUE the same conversation the initial
                // stream was grounded on (full stateless render of the chat,
                // including its system prompt and artifact context) — never a
                // rebuilt stack with a different system prompt.
                let meetingStepKey = TaskStepKey(taskID: tid, stepID: stepID)
                let (finalContent, allThinking, toolSummaries) =
                    try await MeetingToolExecutor.executeTurnToolLoop(
                        initialResult: streamResult,
                        conversationSoFar: turnMessages,
                        meetingContext: meetingContext,
                        client: client,
                        config: speakerConfig,
                        tools: speakerTools,
                        runtime: runtime,
                        toolContext: toolContext,
                        stepID: stepID,
                        networkLogger: networkLogger,
                        cancellationRegistrar: { [weak self] batchTask in
                            guard let self else { return }
                            if let batchTask {
                                self.executionStates[meetingStepKey]?.currentToolBatchTask = batchTask
                            } else if self.executionStates[meetingStepKey]?.currentToolBatchTask != nil {
                                self.executionStates[meetingStepKey]?.currentToolBatchTask = nil
                            }
                        },
                        recordPrefixChain: { [weak self] conversation in
                            guard let self else { return }
                            _ = await self.prefixLedger.record(
                                baseURL: speakerConfig.baseURLString,
                                model: speakerConfig.modelName,
                                owner: .chain(id: meetingChainID),
                                messages: conversation,
                                toolSchemaText: "")
                        }
                    )

                // Complete the turn
                let thinkingValue = allThinking.isEmpty ? nil : allThinking
                let toolsValue = toolSummaries.isEmpty ? nil : toolSummaries
                shouldContinue = TeamMeetingService.completeTurn(
                    meeting: &meeting,
                    speaker: speaker,
                    content: finalContent,
                    thinking: thinkingValue,
                    toolSummaries: toolsValue,
                    context: meetingContext
                ) && meeting.turnCount < maxTurns

                // Persist after each turn for real-time UI
                await recordMeeting(stepID: stepID, taskID: tid, meeting: meeting)
            }

            // Auto-conclude if needed. The local `coordinator` is the
            // effective coordinator computed above (designated coordinator,
            // or initiator in Auto/orphan mode), so `TeamDecision.proposedBy`
            // is always populated correctly without an extra fallback here.
            if meeting.status == .inProgress {
                let summary = meeting.messages.last?.content
                    ?? "Meeting concluded after \(meeting.turnCount) turns."
                TeamMeetingService.concludeMeeting(
                    meeting: &meeting,
                    decision: summary,
                    rationale: "All participants heard.",
                    nextSteps: nil,
                    concludedBy: coordinator
                )
            }

            await recordMeeting(stepID: stepID, taskID: tid, meeting: meeting)
            return .ok(TeamMeetingService.generateMeetingResultForConversation(meeting: meeting))

        } catch is CancellationError {
            meeting.cancel()
            await recordMeeting(stepID: stepID, taskID: tid, meeting: meeting)
            return .failed("Meeting cancelled.")
        } catch {
            meeting.cancel()
            await recordMeeting(stepID: stepID, taskID: tid, meeting: meeting)
            return .failed("Meeting failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Meeting Record

    func recordMeeting(stepID: String, taskID: Int, meeting: TeamMeeting) async {
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return }

        await delegate.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }
            guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }

            // Upsert: replace existing meeting or append new one
            if let meetingIndex = task.runs[runIndex].meetings.firstIndex(where: { $0.id == meeting.id }) {
                task.runs[runIndex].meetings[meetingIndex] = meeting
            } else {
                task.runs[runIndex].meetings.append(meeting)
                task.runs[runIndex].steps[stepIndex].meetingIDs.append(meeting.id)
            }
            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
        }
    }

}
