import Foundation

// Envelope builders + delegation-field cleanup + generated-team tool
// stripping shared across the delegate_to_team entry, awaiter, and
// pause-and-decide handlers.
extension LLMExecutionService {

    /// Envelope shape for the `paused_by_supervisor` outcome. Mirrors the
    /// success-envelope contract used elsewhere (`ok: true`) but with a
    /// distinct `status` value so the LLM disambiguates from terminal
    /// success and reaches for `cancel_delegation` / `resume_delegation` /
    /// `forward_to_team` instead of treating the call as complete.
    func buildPausedEnvelope(
        childTID: Int,
        targetTeamName: String,
        supervisorMessage: String
    ) -> String {
        struct PausedData: Codable {
            var status: String
            var child_task_id: Int
            var team: String
            var supervisor_message: String?
            var next_actions: String
        }
        let data = PausedData(
            status: "paused_by_supervisor",
            child_task_id: childTID,
            team: targetTeamName,
            supervisor_message: supervisorMessage.isEmpty ? nil : supervisorMessage,
            next_actions: "Choose one: `cancel_delegation` (abort), `resume_delegation` (continue waiting), or `forward_to_team` (inject guidance and continue)."
        )
        return makeSuccessEnvelope(data: data)
    }

    /// Removes `delegate_to_team` from every role's toolset and zeroes the
    /// per-role delegation whitelist + generated-team allowance. Applied to
    /// teams synthesized inside `delegate_to_team` so they cannot themselves
    /// delegate further — depth-2+ chains are structurally prevented at
    /// generation time, regardless of what the team-generator LLM emitted
    /// in `tools`. The literal `"list_teams"` is also stripped — that tool
    /// was removed (the catalog now lives inline in `delegate_to_team`'s
    /// description), but smaller models still occasionally emit the legacy
    /// name.
    /// Internal (not private) so unit tests can verify the contract directly
    /// without driving a full `delegate_to_team` invocation.
    func stripDelegationTools(from team: Team) -> Team {
        var stripped = team
        let blocked: Set<String> = [ToolNames.delegateToTeam, "list_teams"]
        for index in stripped.roles.indices {
            stripped.roles[index].toolIDs.removeAll { blocked.contains($0) }
            stripped.roles[index].allowedDelegationTeamIDs = []
            stripped.roles[index].allowDelegationToGeneratedTeams = false
        }
        return stripped
    }

    /// Clears `delegationSession` and `activeDelegationChildID` on the parent step
    /// when the delegation reaches any terminal outcome. Called from every exit
    /// path of the awaiter loop so the next `delegate_to_team` call starts clean
    /// (fresh seeded chain) and `pauseRun` no longer treats the step as mid-delegation.
    func clearDelegationFields(
        parentTID: Int,
        stepID: String,
        delegate: any LLMStateDelegate
    ) async {
        await delegate.mutateTask(taskID: parentTID) { task in
            guard let runIdx = task.runs.indices.last,
                  let stepIdx = task.runs[runIdx].steps.firstIndex(where: { $0.id == stepID })
            else { return }
            // Single mutator clears both `activeChildID` and `session` while
            // preserving the chronological `history` for audit / graph
            // history layers.
            task.runs[runIdx].steps[stepIdx].clearActiveDelegation()
        }
    }

    // MARK: - Envelope Builders

    /// Reads the child task's most recent run, collects produced artifact contents
    /// for the team's required outputs, and returns a success envelope JSON string.
    func buildSuccessEnvelope(
        childTID: Int,
        targetTeam: Team,
        isGeneratedFlow: Bool,
        generationWarnings: [String],
        delegate: any LLMStateDelegate
    ) async -> String {
        struct ArtifactPayload: Codable {
            let content: String
            let role_id: String
        }
        struct DelegationSuccessData: Codable {
            let child_task_id: Int
            let team: String
            let generated: Bool
            let artifacts: [String: ArtifactPayload]
            let missing_artifacts: [String]
            let generation_warnings: [String]?
        }

        var artifacts: [String: ArtifactPayload] = [:]
        var missing: [String] = []
        let requiredNames = targetTeam.supervisorRequiredArtifacts
        if let childTask = delegate.loadedTask(childTID),
           let lastRun = childTask.runs.last
        {
            let produced = lastRun.producedArtifactsByName()
            let workFolderRoot = delegate.workFolderURL
            let setRequired = Set(requiredNames)
            // For chat-mode teams (no required artifacts) we still surface every produced one.
            let namesToReturn: [String] = requiredNames.isEmpty
                ? Array(produced.keys).sorted()
                : requiredNames
            for name in namesToReturn {
                guard let record = produced[name] else {
                    if setRequired.contains(name) { missing.append(name) }
                    continue
                }
                let content: String
                if let root = workFolderRoot,
                   let body = ArtifactService.readContent(artifact: record.artifact, workFolderRoot: root)
                {
                    content = body
                } else {
                    content = ""
                }
                artifacts[name] = ArtifactPayload(content: content, role_id: record.roleID)
            }
        }
        let data = DelegationSuccessData(
            child_task_id: childTID,
            team: targetTeam.name,
            generated: isGeneratedFlow,
            artifacts: artifacts,
            missing_artifacts: missing,
            generation_warnings: generationWarnings.isEmpty ? nil : generationWarnings
        )
        return makeSuccessEnvelope(data: data)
    }
}
