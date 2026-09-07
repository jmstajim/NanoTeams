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
            if let updateMsg = buildArtifactUpdateMessage(newArtifacts) {
                chat.messages.append(LLMMessage(role: .user, content: updateMsg))
                chat.injectedArtifactIDs.formUnion(newArtifacts.map(\.id))
            }
            return chat
        }

        // Create new chat
        let systemPrompt = buildConsultationSystemPrompt(roleID: roleID, team: team)

        var messages: [LLMMessage] = []
        messages.append(LLMMessage(role: .system, content: systemPrompt))

        // Task context as the first user turn — variant data stays out of the
        // system prompt (stable prefix; the template is the invariant block). A `## `
        // heading, like every block the consultation template itself uses: a `Label:` line
        // here was a second marker family in one wire (R1.3.2).
        messages.append(LLMMessage(
            role: .user,
            content: """
            ## Task: \(task.title)
            \(task.effectiveSupervisorBrief)
            """
        ))

        // Inject the role's own artifacts
        let roleStep = run.steps.first(where: { $0.effectiveRoleID == roleID })
        if let artifactContext = buildOwnArtifactsContext(roleStep?.artifacts ?? []) {
            messages.append(LLMMessage(role: .user, content: artifactContext))
        }

        // Inject upstream artifacts
        let upstreamArtifacts = collectUpstreamArtifacts(run: run, excludeRoleID: roleID)
        if let context = buildUpstreamArtifactsContext(upstreamArtifacts) {
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
    ///
    /// `stepID` is the EXECUTING step driving the consultation/meeting (not the
    /// consulted role) — the `isExecutionLive` barrier drops the write when that
    /// execution was torn down mid-consultation, so an orphaned save can't land
    /// on a fresh run after a recurrence supersede.
    func saveConsultationChat(
        stepID: String, taskID: Int, runIndex: Int, roleID: String, chat: RoleConsultationChat
    ) async {
        guard let delegate, isExecutionLive(stepID: stepID, taskID: taskID) else { return }
        await delegate.mutateTask(taskID: taskID) { task in
            guard runIndex < task.runs.count else { return }
            task.runs[runIndex].consultationChats[roleID] = chat
        }
    }

    /// Builds the system prompt for a role's consultation chat by resolving the
    /// team's user-editable `consultationPromptTemplate` — the SAME template the
    /// Settings preview renders (`PromptBuilder.buildWirePromptPreview(kind: .consultation)`).
    /// Pre-fix, the runtime shipped an unrelated hand-built prose prompt while the
    /// preview showed the template — the user-edited template never reached the wire.
    ///
    /// `{requestingRoleName}` resolves to a generic value: this persistent chat is
    /// shared by every requester across the run, and each question turn already
    /// names who is asking.
    private func buildConsultationSystemPrompt(roleID: String, team: Team?) -> String {
        let roleDef = team?.findRole(byIdentifier: roleID)
        let roleName = roleDef?.name
            ?? (Role.builtInRole(for: roleID)?.displayName ?? roleID)
        let roleGuidance = roleDef?.prompt
            ?? (SystemTemplates.roles[roleID]?.prompt ?? "")
        let template = team?.consultationPromptTemplate
            ?? SystemTemplates.genericConsultationTemplate
        let globalContext = delegate?.globalLLMContext ?? ""

        return TemplateResolver.resolveSystemPrompt(
            template,
            placeholders: [
                "consultedRoleName": roleName,
                "requestingRoleName": "a teammate",
                "roleGuidance": roleGuidance,
                "teamDescription": team?.description ?? "",
                "globalContext": PromptBuilder.formatGlobalContext(globalContext),
                // Role-attached skills ride the STEP prompt only. Mapped to ""
                // rather than left out so a hand-typed `{roleSkills}` chip in a
                // user-edited consultation template resolves away instead of
                // shipping as a literal token.
                "roleSkills": "",
            ],
            globalContext: globalContext
        )
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

    // The three artifact turns share `PromptBuilder.buildArtifactSection` with the step's
    // required-artifacts block: one `## `/`### ` shape and one "(content not available)"
    // for an unreadable body, on every path a model reads artifacts (R1.3.2). Each returns
    // `nil` for no artifacts, so no caller appends a heading over nothing.

    private func buildOwnArtifactsContext(_ artifacts: [Artifact]) -> String? {
        PromptBuilder.buildArtifactSection(
            heading: "Your artifacts", artifacts: artifacts, cap: 2000,
            artifactReader: readArtifactContent)
    }

    private func buildUpstreamArtifactsContext(_ artifacts: [Artifact]) -> String? {
        PromptBuilder.buildArtifactSection(
            heading: "Available team artifacts", artifacts: artifacts, cap: 1500,
            artifactReader: readArtifactContent)
    }

    private func buildArtifactUpdateMessage(_ artifacts: [Artifact]) -> String? {
        PromptBuilder.buildArtifactSection(
            heading: "New artifacts", artifacts: artifacts, cap: 1500,
            artifactReader: readArtifactContent)
    }

    func readArtifactContent(_ artifact: Artifact) -> String? {
        guard let workFolderRoot = delegate?.workFolderURL else { return nil }
        return ArtifactService.readContent(artifact: artifact, workFolderRoot: workFolderRoot)
    }
}
