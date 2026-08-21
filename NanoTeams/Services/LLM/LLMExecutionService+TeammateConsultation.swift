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

        // 1. Get or create consultation chat for the consulted role.
        //
        // Re-read the fresh task first — `task` is a snapshot captured at STEP start and
        // does not reflect mutations from prior tool-loop iterations (the same reason
        // `handleChangeRequest` re-reads). Reading the chat out of the stale snapshot
        // missed one an earlier iteration of this same step had already created, so a
        // SECOND chat was made and the accumulated history was lost — the exact opposite
        // of the persistent-chat contract this feature exists for. It also hid artifacts
        // produced since step start from `collectNewArtifacts`.
        let chatTask = delegate.loadedTask(task.id) ?? task
        let chatRunIndex = runIndex < chatTask.runs.count ? runIndex : chatTask.runs.count - 1
        var chat = getOrCreateConsultationChat(
            roleID: consultedRoleID, task: chatTask, runIndex: chatRunIndex, team: team
        )

        // 2. Build question message
        let requestingRoleName = team?.findRole(byIdentifier: requestingRole.baseID)?.name
            ?? requestingRole.displayName
        var questionMsg = "\(requestingRoleName) asks: \(question)"
        if let ctx = context, !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            questionMsg += "\nContext: \(ctx)"
        }
        chat.messages.append(LLMMessage(role: .user, content: questionMsg))

        // 3. Call the LLM with the chat's FULL history — the consultation chat
        // accumulates across the run and every call resends it, so the provider's
        // prompt-prefix cache carries the cost, not a server-side chain.
        let startTime = Date()
        // A consultation is a `.chain`, not a one-shot: the chat above accumulates for the whole
        // run and every call resends it, so it has a real prefix to lose — exactly what the
        // detector protects. Recording it also lets a step's `serverDroppedCache` name it.
        //
        // Scoped to the task AND the run because that is the chat's real lifetime:
        // `Run.consultationChats` is per-run, so a new run rebuilds this chat from scratch, and
        // `Run.id` is per-task sequential so it does not identify a run on its own (the same
        // reason `PrefixCacheReporter`'s banner latch keys `(taskID, runID, causeClass)`).
        // Without the task, two tasks on one team consulting the same role concurrently —
        // `delegate_to_team` runs children in parallel — interleave into ONE chain and
        // manufacture rewrites out of unrelated conversations, the exact failure per-owner
        // keying exists to prevent.
        _ = await prefixLedger.record(
            baseURL: consultedConfig.baseURLString,
            model: consultedConfig.modelName,
            owner: .chain(
                id: "consultation:\(tid):\(task.runs[runIndex].id):\(consultedRoleID)"),
            messages: chat.messagesToSend(),
            toolSchemaText: "")
        do {
            var fullResponse = ""
            var fullThinking = ""
            let stream = client.streamChat(
                config: consultedConfig,
                messages: chat.messagesToSend(),
                tools: [],
                logger: networkLogger,
                stepID: nil
            )

            for try await event in stream {
                fullResponse += event.contentDelta
                fullThinking += event.thinkingDelta
            }

            // Prefer the visible content; fall back to the reasoning channel when a
            // reasoning model leaves content empty. Only when BOTH are empty is the
            // consultation genuinely failed. The rule lives in `ModelReplyChannels` —
            // this site had it right and four others did not.
            let answer = ModelReplyChannels.answer(
                content: fullResponse,
                reasoning: fullThinking,
                prepare: {
                    ModelTokenCleaner.clean(
                        $0.trimmingCharacters(in: .whitespacesAndNewlines))
                })
            let responseTimeMs = Int(Date().timeIntervalSince(startTime) * 1000)

            guard !answer.isEmpty else {
                let message = "(\(consultedRole.displayName) returned an empty response.)"
                consultation.fail(with: message)
                await recordConsultation(stepID: stepID, taskID: tid, consultation: consultation)
                return .failed(message)
            }

            // 4. Save response to consultation chat
            chat.messages.append(LLMMessage(role: .assistant, content: answer))
            chat.updatedAt = MonotonicClock.shared.now()
            await saveConsultationChat(
                stepID: stepID, taskID: tid, runIndex: runIndex, roleID: consultedRoleID, chat: chat
            )

            // 5. Record consultation
            consultation.complete(with: answer, responseTimeMs: responseTimeMs)
            await recordConsultation(stepID: stepID, taskID: tid, consultation: consultation)

            return .ok(answer)
        } catch {
            // A Pause is not a failed consultation. `consultation.fail` is DURABLE — the
            // record is persisted onto `step.consultations` and `RoleConsultationsPanel`
            // renders it red for the life of the run — so recording "Unable to get response
            // from X: cancelled" turns the user stopping the run into a permanent defect on
            // the transcript, and feeds `.failed` back into the wire conversation as the
            // teammate's answer. Leave the record untouched; the step is being torn down.
            if CancellationClassifier.isCancellation(error) {
                return .failed("Consultation cancelled.")
            }
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
