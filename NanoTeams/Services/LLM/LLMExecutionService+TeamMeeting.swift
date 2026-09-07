import Foundation

/// Team meeting orchestration: request_team_meeting tool handling, turn loop, and participant filtering.
extension LLMExecutionService {

    // MARK: - Team Meetings

    func handleTeamMeeting(
        stepID: String,
        topic: String,
        participantIDs: [String],
        context: String?,
        kind: TeamMeetingKind = .discussion,
        initiatingRole: Role,
        initiatorSeat: TeamMeetingService.InitiatorSeat,
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

        // The schema resolver already withholds `request_team_meeting` from a team that
        // cannot meet (`Team.meetingAvailability`); this is the dispatcher's own refusal
        // for a call that arrives anyway — a stale schema, an alias. Says what to do
        // instead and names no settings pane (the model is the reader).
        switch team?.meetingAvailability ?? .available {
        case .switchedOff:
            return .failed("Team meetings are off for this team. Continue without one.")
        case .noPartner:
            return .failed("This team has no teammate to meet with. Continue without a meeting.")
        case .available:
            break
        }

        // Convert participant IDs to Roles, filtering against team constraints
        let filteredParticipants = MeetingParticipantResolver.filterParticipants(
            participantIDs: participantIDs,
            initiatingRole: initiatingRole,
            team: team,
            teamSettings: teamSettings
        )
        var participants = filteredParticipants.participants
        let rejectedReasons = filteredParticipants.rejectedReasons

        if participants.isEmpty {
            let available = MeetingParticipantResolver.availableTeammatesList(team: team, teamSettings: teamSettings, excludeRoleID: initiatingRole.baseID)
            let rejected = rejectedReasons.isEmpty ? "" : " Rejected: \(rejectedReasons.joined(separator: ", "))."
            return .failed("No valid participants for this meeting.\(rejected) Available teammates: \(available)")
        }

        // The team's coordinator runs THIS meeting: opens it, speaks after every round,
        // takes the last turn and is the only role holding `conclude_meeting`. Resolved
        // through `Team.meetingCoordinatorID` — never nil for a team with roles; the
        // initiator stands in only for a fixture with no team.
        let coordinator: Role = effectiveCoordinator(team: team, initiator: initiatingRole)
        // A stored coordinator id that no longer resolves is healed on open; if one
        // slipped in since, surface a one-shot info message naming who coordinates now.
        reportOrphanCoordinatorIfNeeded(team: team)
        // Two structural seats, both bypassing `invitableRoles` on purpose — convening and
        // coordinating are not invitations. "No valid participants" above judged the
        // INVITED list alone: a role that invited only itself still gets the roster back.
        //
        // The initiator, when its seat SPEAKS (`request_team_meeting`), goes to index 0: the
        // meeting is its topic, so it takes the first turn after the coordinator's opening.
        // A `request_changes` vote passes `.presentsOnly` — the requester must not vote on
        // its own request. Until 2026-09-07 the initiator was filtered OUT ("you — the
        // initiator") and never spoke in a meeting it convened.
        if case .speaks = initiatorSeat,
           !participants.contains(where: { $0.baseID == initiatingRole.baseID }) {
            participants.insert(initiatingRole, at: 0)
        }
        // The coordinator — the rotation gives it the opening turn and the last one whether
        // or not the initiator thought to invite it, so the record, the header and
        // `agreedBy` must list it too. Appended last: `determineNextSpeaker` rotates over
        // the participants MINUS the coordinator, so its position only affects the header.
        if !participants.contains(where: { $0.baseID == coordinator.baseID }) {
            participants.append(coordinator)
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
            topic: topic, initiatedBy: initiatingRole, participants: participants, context: context,
            kind: kind
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
        // One tool resolution per speaker for the whole meeting — the meeting analogue of
        // the step's one-resolution-per-entry rule (`SystemPromptStabilityTests`). Resolved
        // per TURN until 2026-09-07: `filterForGitAvailability` read the filesystem each
        // time, so a `git init` by a parallel role mid-meeting changed segment 0 (the tool
        // catalog) and re-prefilled the whole discussion (R4.2.1).
        var toolsBySpeaker: [Role: [ToolSchema]] = [:]

        do {
            while shouldContinue {
                if Task.isCancelled { throw CancellationError() }

                // Start meeting if pending
                if meeting.status == .pending { meeting.start() }

                // A limit already reached at entry — `maxMeetingTurns == 0` — means no turn
                // is allowed; leave the loop and let the turn-limit fallback below record
                // how the meeting ended. Until 2026-09-06 this arm `complete()`d the meeting
                // with no decision and no `conclusionKind`, the one ending the card could not
                // name. After a turn, `completeTurn` stops the loop before this check.
                if TeamMeetingService.hasReachedTurnLimit(meeting: meeting, limits: teamSettings.limits) {
                    break
                }

                // Determine next speaker — the last turn under the limit is always the
                // coordinator's, so the `conclude_meeting` directive lands on a holder.
                let speaker = MeetingStreamingService.determineNextSpeaker(
                    meeting: meeting, participants: participants, coordinator: coordinator,
                    maxTurns: maxTurns
                )
                let speakerConfig = meetingConfigResolver(speaker)
                let speakerTools: [ToolSchema]
                if let resolved = toolsBySpeaker[speaker] {
                    speakerTools = resolved
                } else {
                    speakerTools = MeetingCoordinator.speakerTools(
                        base: Self.filterForGitAvailability(
                            Self.filterForDefaultStorage(
                                // `bash` and the computer-use tools are `excludedInMeetings`, so
                                // the presence answer never changes a meeting schema; it is
                                // threaded anyway because the resolver has no default for it.
                                toolSchemas(
                                    for: speaker, team: team,
                                    humanPresent: approvalHumanPresent(
                                        task: task, supervisorMode: teamSettings.supervisorMode)),
                                isDefaultStorage: isDefaultStorage
                            ),
                            workFolderRoot: workFolderRoot
                        ),
                        isCoordinator: speaker == coordinator
                    )
                    toolsBySpeaker[speaker] = speakerTools
                }

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
                let (finalContent, allThinking, toolSummaries, conclusion) =
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
                if let conclusion {
                    // The coordinator ended the meeting. Its spoken turn is whatever it
                    // said around the call, else the decision itself — never a blank line
                    // under "Discussion so far" in the record.
                    let spoken = ModelTokenCleaner.clean(finalContent).trimmingCharacters(in: .whitespacesAndNewlines)
                    _ = TeamMeetingService.completeTurn(
                        meeting: &meeting,
                        speaker: speaker,
                        content: spoken.isEmpty ? conclusion.decision : finalContent,
                        thinking: thinkingValue,
                        toolSummaries: toolsValue,
                        context: meetingContext,
                        messageType: .conclusion
                    )
                    TeamMeetingService.concludeMeeting(
                        meeting: &meeting,
                        decision: conclusion.decision,
                        rationale: conclusion.rationale,
                        nextSteps: conclusion.nextSteps,
                        concludedBy: coordinator
                    )
                    meeting.conclusionKind = .coordinatorCall
                    shouldContinue = false
                } else {
                    shouldContinue = TeamMeetingService.completeTurn(
                        meeting: &meeting,
                        speaker: speaker,
                        content: finalContent,
                        thinking: thinkingValue,
                        toolSummaries: toolsValue,
                        context: meetingContext
                    )
                }

                // Persist after each turn for real-time UI
                await recordMeeting(stepID: stepID, taskID: tid, meeting: meeting)
            }

            // Turn-limit fallback. The coordinator held the last turn and the
            // `conclude_meeting` directive and still did not call it; the meeting must
            // terminate (the initiator is blocked on it), so its last contribution is
            // recorded as the decision and the record says how it ended —
            // `conclusionKind` for the card, the "Concluded at the turn limit" line for
            // the initiator's tool result.
            if meeting.status == .inProgress {
                let lastCoordinatorLine = meeting.messages.last(where: { $0.role == coordinator })?.content
                let summary = lastCoordinatorLine
                    ?? meeting.messages.last?.content
                    ?? "Meeting ended after \(meeting.turnCount) turns without a decision."
                TeamMeetingService.concludeMeeting(
                    meeting: &meeting,
                    decision: summary,
                    rationale: "Turn limit reached without a conclude_meeting call.",
                    nextSteps: nil,
                    concludedBy: coordinator
                )
                meeting.conclusionKind = .turnLimitFallback
            }

            await recordMeeting(stepID: stepID, taskID: tid, meeting: meeting)
            return .ok(TeamMeetingService.generateMeetingResultForConversation(
                meeting: meeting, context: meetingContext))

        } catch is CancellationError {
            meeting.cancel()
            await recordMeeting(stepID: stepID, taskID: tid, meeting: meeting)
            return .failed("Meeting cancelled.")
        } catch {
            meeting.cancel()
            await recordMeeting(stepID: stepID, taskID: tid, meeting: meeting)
            // The initiator reads this as its tool result — classified, never localized (R1.8.2).
            return .failed("Meeting failed: \(ToolErrorHandler.classify(error).message)")
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
