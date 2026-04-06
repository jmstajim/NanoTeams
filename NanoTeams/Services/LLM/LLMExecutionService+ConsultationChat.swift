import Foundation

/// Consultation chat infrastructure: create/restore per-role chat sessions and artifact helpers.
extension LLMExecutionService {

    // MARK: - Consultation Chat Infrastructure

    /// Gets an existing consultation chat or creates a new one for the given role.
    /// Injects new artifacts if they appeared since the chat was last used.
    func getOrCreateConsultationChat(
        roleID: String,
        task: NTMSTask,
        runIndex: Int,
        team: Team?
    ) -> RoleConsultationChat {
        let run = task.runs[runIndex]

        // Return existing chat with artifact updates
        if var chat = run.consultationChats[roleID] {
            let newArtifacts = collectNewArtifacts(
                run: run, alreadyInjected: chat.injectedArtifactIDs
            )
            if !newArtifacts.isEmpty {
                let updateMsg = buildArtifactUpdateMessage(newArtifacts)
                chat.messages.append(LLMMessage(role: .user, content: updateMsg))
                chat.injectedArtifactIDs.formUnion(newArtifacts.map(\.id))
            }
            return chat
        }

        // Create new chat
        let systemPrompt = buildConsultationSystemPrompt(
            roleID: roleID, team: team, task: task
        )

        var messages: [LLMMessage] = []
        messages.append(LLMMessage(role: .system, content: systemPrompt))

        // Inject the role's own artifacts
        let roleStep = run.steps.first(where: { $0.effectiveRoleID == roleID })
        if let step = roleStep, !step.artifacts.isEmpty {
            let artifactContext = buildOwnArtifactsContext(step.artifacts)
            messages.append(LLMMessage(role: .user, content: artifactContext))
        }

        // Inject upstream artifacts
        let upstreamArtifacts = collectUpstreamArtifacts(run: run, excludeRoleID: roleID)
        if !upstreamArtifacts.isEmpty {
            let context = buildUpstreamArtifactsContext(upstreamArtifacts)
            messages.append(LLMMessage(role: .user, content: context))
        }

        let artifactIDs = collectAllArtifactIDs(run: run)
        return RoleConsultationChat(
            id: roleID,
            messages: messages,
            injectedArtifactIDs: artifactIDs
        )
    }

    /// Persists a consultation chat to the run.
    func saveConsultationChat(
        taskID: Int, runIndex: Int, roleID: String, chat: RoleConsultationChat
    ) async {
        guard let delegate else { return }
        await delegate.mutateTask(taskID: taskID) { task in
            guard runIndex < task.runs.count else { return }
            task.runs[runIndex].consultationChats[roleID] = chat
        }
    }

    /// Builds the system prompt for a role's consultation chat.
    private func buildConsultationSystemPrompt(
        roleID: String, team: Team?, task: NTMSTask
    ) -> String {
        let roleDef = team?.findRole(byIdentifier: roleID)
        let roleName = roleDef?.name
            ?? (Role.builtInRole(for: roleID)?.displayName ?? roleID)
        let roleGuidance = roleDef?.prompt
            ?? (SystemTemplates.roles[roleID]?.prompt ?? "")
        let teamDescription = team?.description ?? ""

        return """
            You are \(roleName)\(teamDescription.isEmpty ? "" : " on a team: \(teamDescription)").

            \(roleGuidance)

            You answer questions from teammates, participate in team meetings, and provide your expertise.
            Be concise and professional. Draw on your role's expertise to give specific, actionable answers.

            Current task: \(task.title)
            Supervisor Task: \(task.effectiveSupervisorBrief)
            """
    }

    // MARK: - Consultation Chat Artifact Helpers

    func collectNewArtifacts(
        run: Run, alreadyInjected: Set<String>
    ) -> [Artifact] {
        var newArtifacts: [Artifact] = []
        for step in run.steps {
            for artifact in step.artifacts where !alreadyInjected.contains(artifact.id) {
                newArtifacts.append(artifact)
            }
        }
        return newArtifacts
    }

    func collectAllArtifactIDs(run: Run) -> Set<String> {
        var ids = Set<String>()
        for step in run.steps {
            for artifact in step.artifacts {
                ids.insert(artifact.id)
            }
        }
        return ids
    }

    func collectUpstreamArtifacts(run: Run, excludeRoleID: String) -> [Artifact] {
        var artifacts: [Artifact] = []
        for step in run.steps where step.effectiveRoleID != excludeRoleID {
            artifacts.append(contentsOf: step.artifacts)
        }
        return artifacts
    }

    private func buildOwnArtifactsContext(_ artifacts: [Artifact]) -> String {
        var context = "Your produced artifacts:\n"
        for artifact in artifacts {
            context += "\n[\(artifact.name)]:"
            if let content = readArtifactContent(artifact) {
                let truncated = String(content.prefix(2000))
                context += "\n```\n\(truncated)\(content.count > 2000 ? "\n... (truncated)" : "")\n```"
            } else {
                context += " (content not available)"
            }
        }
        return context
    }

    private func buildUpstreamArtifactsContext(_ artifacts: [Artifact]) -> String {
        var context = "Available team artifacts:\n"
        for artifact in artifacts {
            context += "\n[\(artifact.name)]:"
            if let content = readArtifactContent(artifact) {
                let truncated = String(content.prefix(1500))
                context += "\n```\n\(truncated)\(content.count > 1500 ? "\n... (truncated)" : "")\n```"
            }
        }
        return context
    }

    private func buildArtifactUpdateMessage(_ artifacts: [Artifact]) -> String {
        var msg = "New artifacts available:\n"
        for artifact in artifacts {
            msg += "\n[\(artifact.name)]:"
            if let content = readArtifactContent(artifact) {
                let truncated = String(content.prefix(1500))
                msg += "\n```\n\(truncated)\(content.count > 1500 ? "\n... (truncated)" : "")\n```"
            }
        }
        return msg
    }

    func readArtifactContent(_ artifact: Artifact) -> String? {
        guard let workFolderRoot = delegate?.workFolderURL else { return nil }
        return ArtifactService.readContent(artifact: artifact, workFolderRoot: workFolderRoot)
    }
}
