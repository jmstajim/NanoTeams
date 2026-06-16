import Foundation

/// Teammate consultation: ask_teammate tool handling, validation, and record-keeping.
extension LLMExecutionService {

    // MARK: - Teammate Consultation

    func handleTeammateConsultation(
        stepID: String,
        consultedRoleID: String,
        question: String,
        context: String?,
        requestingRole: Role,
        task: NTMSTask,
        runIndex: Int,
        stepIndex: Int,
        client: any LLMClient,
        config: LLMConfig,
        networkLogger: NetworkLogger? = nil
    ) async -> CollaborationReply {
        guard let delegate else { return .failed("Unable to consult teammate — delegate not available.") }
        let tid = task.id
        guard isExecutionLive(stepID: stepID, taskID: tid) else {
            return .failed("Unable to consult teammate — no task context.")
        }

        // Resolve team
        let team = resolveTeam(task: task)
        let teamSettings = team?.settings ?? .default

        // Get the consulted role — try built-in ID first, then team lookup by any identifier
        let consultedRole: Role
        if let builtIn = Role.builtInRole(for: consultedRoleID) {
            consultedRole = builtIn
        } else if let teamRole = team?.findRole(byIdentifier: consultedRoleID) {
            consultedRole = Role.fromDefinition(teamRole)
        } else {
            return .failed("Unknown teammate role: \(consultedRoleID). Available teammates: \(MeetingParticipantResolver.availableTeammatesList(team: team, teamSettings: teamSettings, excludeRoleID: requestingRole.baseID))")
        }

        if let validationError = consultationValidationError(
            consultedRole: consultedRole,
            consultedRoleID: consultedRoleID,
            requestingRoleID: requestingRole.baseID,
            team: team,
            teamSettings: teamSettings
        ) {
            return .failed(validationError)
        }

        // Re-read fresh task to get current consultation state (the `task` parameter
        // is a snapshot captured at step start and doesn't reflect mutations from prior iterations).
        let step: StepExecution
        if let freshTask = delegate.loadedTask(tid),
           runIndex < freshTask.runs.count,
           stepIndex < freshTask.runs[runIndex].steps.count {
            step = freshTask.runs[runIndex].steps[stepIndex]
        } else {
            step = task.runs[runIndex].steps[stepIndex]
        }

        if TeammateConsultationService.hasReachedLimit(
            consultations: step.consultations,
            limits: teamSettings.limits
        ) {
            return .failed("Consultation limit reached. Cannot ask more questions in this step.")
        }

        if TeammateConsultationService.wouldExceedSameTeammateLimit(
            consultations: step.consultations,
            targetTeammate: consultedRole,
            limits: teamSettings.limits
        ) {
            return .failed("You've already asked \(consultedRole.displayName) multiple times. Consider asking a different teammate or making a decision based on available information.")
        }

        if TeammateConsultationService.isDuplicateQuestion(
            consultations: step.consultations,
            targetTeammate: consultedRole,
            question: question
        ) {
            if let previousAnswer = step.consultations.first(where: {
                $0.consultedRole == consultedRole
                    && $0.question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        == question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            })?.response {
                return .ok("(Previously answered) \(previousAnswer)")
            }
        }

        // Create consultation record
        var consultation = TeammateConsultationService.createConsultation(
            requestingRole: requestingRole,
            consultedRole: consultedRole,
            question: question,
            context: context
        )

        // Resolve consulted role's LLM config
        let resolvedConsultedID = team?.findRole(byIdentifier: consultedRoleID)?.id ?? consultedRoleID
        let consultedOverride = team?.roles.first(where: { $0.id == resolvedConsultedID })?.llmOverride
        let consultedConfig = Self.buildEffectiveConfig(
            globalConfig: config, roleOverride: consultedOverride
        )

        // === Consultation Chat Flow ===

        // 1. Get or create consultation chat for the consulted role
        var chat = getOrCreateConsultationChat(
            roleID: consultedRoleID, task: task, runIndex: runIndex, team: team
        )

        // 2. Build question message
        let requestingRoleName = team?.findRole(byIdentifier: requestingRole.baseID)?.name
            ?? requestingRole.displayName
        var questionMsg = "\(requestingRoleName) asks: \(question)"
        if let ctx = context, !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            questionMsg += "\nContext: \(ctx)"
        }
        chat.messages.append(LLMMessage(role: .user, content: questionMsg))

        // 3. Resolve session for stateful providers
        let session = chat.sessionID.map { LLMSession(responseID: $0) }

        // 4. Build messages to send (stateful: only new, stateless: full history)
        let messagesToSend = chat.messagesToSend(session: session)

        // 5. Call LLM via consultation chat
        let startTime = Date()
        do {
            var fullResponse = ""
            var fullThinking = ""
            var newSession: LLMSession?
            let stream = client.streamChat(
                config: consultedConfig,
                messages: messagesToSend,
                tools: [],
                session: session,
                logger: networkLogger,
                stepID: nil
            )

            for try await event in stream {
                fullResponse += event.contentDelta
                fullThinking += event.thinkingDelta
                if let s = event.session { newSession = s }
            }

            // Prefer the visible content. When a reasoning model emits its whole
            // answer in the reasoning channel (empty content), fall back to the
            // cleaned thinking so the answer isn't silently dropped; only when
            // BOTH are empty do we treat the consultation as failed.
            let content = ModelTokenCleaner.clean(
                fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let thinking = ModelTokenCleaner.clean(
                fullThinking.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let answer = content.isEmpty ? thinking : content
            let responseTimeMs = Int(Date().timeIntervalSince(startTime) * 1000)

            guard !answer.isEmpty else {
                let message = "(\(consultedRole.displayName) returned an empty response.)"
                consultation.fail(with: message)
                await recordConsultation(stepID: stepID, taskID: tid, consultation: consultation)
                return .failed(message)
            }

            // 6. Save response to consultation chat
            chat.messages.append(LLMMessage(role: .assistant, content: answer))
            if let s = newSession { chat.sessionID = s.responseID }
            chat.updatedAt = MonotonicClock.shared.now()
            await saveConsultationChat(
                stepID: stepID, taskID: tid, runIndex: runIndex, roleID: consultedRoleID, chat: chat
            )

            // 7. Record consultation
            consultation.complete(with: answer, responseTimeMs: responseTimeMs)
            await recordConsultation(stepID: stepID, taskID: tid, consultation: consultation)

            return .ok(answer)
        } catch {
            let message = "Unable to get response from \(consultedRole.displayName): \(error.localizedDescription)"
            consultation.fail(with: message)
            await recordConsultation(stepID: stepID, taskID: tid, consultation: consultation)
            return .failed(message)
        }
    }

    // MARK: - Consultation Record

    func recordConsultation(stepID: String, taskID: Int, consultation: TeammateConsultation) async {
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return }

        await delegate.mutateTask(taskID: taskID) { task in
            guard let runIndex = task.runs.indices.last else { return }
            guard let stepIndex = task.runs[runIndex].steps.firstIndex(where: { $0.id == stepID })
            else { return }

            task.runs[runIndex].steps[stepIndex].consultations.append(consultation)
            task.runs[runIndex].steps[stepIndex].updatedAt = MonotonicClock.shared.now()
        }
    }

    // MARK: - Validation Helpers

    func consultationValidationError(
        consultedRole: Role,
        consultedRoleID: String,
        requestingRoleID: String,
        team: Team?,
        teamSettings: TeamSettings
    ) -> String? {
        if consultedRoleID == requestingRoleID {
            return "You cannot ask yourself. Available teammates: \(MeetingParticipantResolver.availableTeammatesList(team: team, teamSettings: teamSettings, excludeRoleID: requestingRoleID))"
        }

        // Use findRole to resolve by id, systemRoleID, or name
        if let team, team.findRole(byIdentifier: consultedRoleID) == nil {
            return "\(consultedRole.displayName) is not a member of this team. Available teammates: \(MeetingParticipantResolver.availableTeammatesList(team: team, teamSettings: teamSettings, excludeRoleID: requestingRoleID))"
        }

        if let team, let found = team.findRole(byIdentifier: consultedRoleID), found.isSupervisor && !teamSettings.supervisorCanBeInvited {
            return "Supervisor cannot be consulted in this team configuration. Available teammates: \(MeetingParticipantResolver.availableTeammatesList(team: team, teamSettings: teamSettings, excludeRoleID: requestingRoleID))"
        }

        let resolvedID = team?.findRole(byIdentifier: consultedRoleID)?.id ?? consultedRoleID
        if !teamSettings.invitableRoles.isEmpty && !teamSettings.invitableRoles.contains(resolvedID) {
            return "\(consultedRole.displayName) is not available for consultation. Available teammates: \(MeetingParticipantResolver.availableTeammatesList(team: team, teamSettings: teamSettings, excludeRoleID: requestingRoleID))"
        }

        return nil
    }

}

// MARK: - Test Helpers

#if DEBUG
extension LLMExecutionService {
    func _testConsultationValidationError(
        consultedRoleID: String,
        requestingRoleID: String,
        team: Team?,
        teamSettings: TeamSettings
    ) -> String? {
        guard let consultedRole = Role.builtInRole(for: consultedRoleID) else {
            return "Unknown teammate role: \(consultedRoleID)"
        }
        return consultationValidationError(
            consultedRole: consultedRole,
            consultedRoleID: consultedRoleID,
            requestingRoleID: requestingRoleID,
            team: team,
            teamSettings: teamSettings
        )
    }

}
#endif
