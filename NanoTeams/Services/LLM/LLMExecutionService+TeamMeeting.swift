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
    ) async -> String {
        guard let delegate else { return "Unable to conduct meeting — delegate not available." }
        guard let tid = taskIDForStep(stepID) else { return "Unable to conduct meeting — no task context." }
        guard let workFolderRoot = delegate.workFolderURL else { return "Unable to conduct meeting — no work folder." }

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
            return "No valid participants for this meeting.\(rejected) Available teammates: \(available)"
        }

        // Re-read fresh task to get current meeting count (the `task` parameter
        // is a snapshot captured at step start and doesn't reflect mutations from prior iterations).
        let run = task.runs[runIndex]
        let freshMeetings: [TeamMeeting]
        if let freshTask = await { delegate.loadedTask(tid) }(),
           runIndex < freshTask.runs.count {
            freshMeetings = freshTask.runs[runIndex].meetings
        } else {
            freshMeetings = run.meetings
        }
        if TeamMeetingService.hasReachedMeetingLimit(
            meetings: freshMeetings, limits: teamSettings.limits
        ) {
            return "Meeting limit reached for this run (\(teamSettings.limits.maxMeetingsPerRun)). Cannot conduct another meeting."
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

        // Resolve coordinator
        let coordinatorRoleID = team?.settings.meetingCoordinatorRoleID
            ?? team?.roles.first(where: { !$0.isSupervisor })?.id
        let coordinator: Role = coordinatorRoleID.flatMap { id in
            if let systemRoleID = team?.roles.first(where: { $0.id == id })?.systemRoleID {
                return Role.builtInRole(for: systemRoleID)
            }
            return .custom(id: id)
        } ?? .tpm

        // Per-role LLM config resolver
        let meetingConfigResolver: (Role) -> LLMConfig = { speakerRole in
            let roleDef = team?.findRole(byIdentifier: speakerRole.baseID)
            return Self.buildEffectiveConfig(
                globalConfig: config, roleOverride: roleDef?.llmOverride
            )
        }

        // Build meeting context (still needed for tool loop fallback + turn completion)
        let meetingContext = TeamMeetingService.MeetingContext(
            topic: topic,
            initiatedBy: initiatingRole,
            participants: participants,
            additionalContext: context,
            task: task,
            availableArtifacts: availableArtifacts,
            artifactReader: { [weak self] artifact in
                guard let workFolderRoot = self?.delegate?.workFolderURL else { return nil }
                return ArtifactService.readContent(artifact: artifact, workFolderRoot: workFolderRoot)
            },
            team: team,
            coordinatorRole: coordinator,
            limits: teamSettings.limits
        )

        // Tool runtime for meeting tool calls
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        let isDefaultStorage = workFolderRoot == NTMSOrchestrator.defaultStorageURL
        let meetingToolCallsLogURL: URL? = delegate.loggingEnabled
            ? paths.toolCallsJSONL(taskID: tid, runID: run.id)
            : nil
        let (_, runtime) = ToolRegistry.defaultRegistry(
            workFolderRoot: workFolderRoot, toolCallsLogURL: meetingToolCallsLogURL,
            isDefaultStorage: isDefaultStorage
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
                    await recordMeeting(stepID: stepID, meeting: meeting)
                    break
                }

                // Determine next speaker
                let speaker = MeetingStreamingService.determineNextSpeaker(
                    meeting: meeting, participants: participants, coordinator: coordinator
                )
                let speakerConfig = meetingConfigResolver(speaker)
                let speakerTools = MeetingCoordinator.filterMeetingTools(
                    Self.filterForDefaultStorage(
                        toolSchemas(for: speaker, team: team),
                        isDefaultStorage: isDefaultStorage
                    )
                )

                // Get speaker's consultation chat
                var chat = getOrCreateConsultationChat(
                    roleID: speaker.baseID, task: task, runIndex: runIndex, team: team
                )

                // Build meeting turn message for the chat
                let meetingTurnMsg = MeetingCoordinator.buildTurnMessage(
                    speaker: speaker, meeting: meeting, context: meetingContext
                )
                chat.messages.append(LLMMessage(role: .user, content: meetingTurnMsg))

                // Resolve session
                let chatSession = chat.sessionID.map { LLMSession(responseID: $0) }
                let messagesToSend = chat.messagesToSend(session: chatSession)

                // Stream initial response via consultation chat
                let streamResult = try await MeetingStreamingService.streamParticipantResponse(
                    messages: messagesToSend,
                    client: client,
                    config: speakerConfig,
                    tools: speakerTools,
                    session: chatSession,
                    logger: networkLogger,
                    stepID: stepID
                )

                // Execute tool loop if needed
                let (finalContent, allThinking, toolSummaries) = try await MeetingToolExecutor.executeTurnToolLoop(
                    initialResult: streamResult,
                    speaker: speaker,
                    meeting: meeting,
                    meetingContext: meetingContext,
                    client: client,
                    config: speakerConfig,
                    tools: speakerTools,
                    runtime: runtime,
                    toolContext: toolContext,
                    stepID: stepID,
                    networkLogger: networkLogger
                )

                // Save speaker's response to consultation chat
                chat.messages.append(LLMMessage(role: .assistant, content: finalContent))
                if let newSession = streamResult.session {
                    chat.sessionID = newSession.responseID
                }
                chat.updatedAt = MonotonicClock.shared.now()
                await saveConsultationChat(
                    taskID: tid, runIndex: runIndex, roleID: speaker.baseID, chat: chat
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
                await recordMeeting(stepID: stepID, meeting: meeting)
            }

            // Auto-conclude if needed
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

            await recordMeeting(stepID: stepID, meeting: meeting)
            return TeamMeetingService.generateMeetingResultForConversation(meeting: meeting)

        } catch is CancellationError {
            meeting.cancel()
            await recordMeeting(stepID: stepID, meeting: meeting)
            return "Meeting cancelled."
        } catch {
            meeting.cancel()
            await recordMeeting(stepID: stepID, meeting: meeting)
            return "Meeting failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Meeting Record

    func recordMeeting(stepID: String, meeting: TeamMeeting) async {
        guard let delegate, let tid = taskIDForStep(stepID) else { return }

        await delegate.mutateTask(taskID: tid) { task in
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
