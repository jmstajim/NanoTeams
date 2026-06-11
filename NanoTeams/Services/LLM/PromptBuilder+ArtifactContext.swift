import Foundation

/// Artifact-related prompt building: Supervisor task, required artifacts, artifact sections.
nonisolated extension PromptBuilder {

    /// Builds the Supervisor Task section. `header` lets the Autovisor render
    /// it as "Supervisor Goal" (its brief IS its goal) instead of "Supervisor Task".
    static func buildSupervisorTaskSection(supervisorTask: String, header: String = "Supervisor Task") -> String? {
        let trimmed = supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return "## \(header)\n\n\(trimmed)"
    }

    static func buildSupervisorTaskSection(task: NTMSTask, header: String = "Supervisor Task") -> String? {
        buildSupervisorTaskSection(supervisorTask: task.effectiveSupervisorBrief, header: header)
    }

    /// Gets the required artifact names for the current step's role.
    static func getRequiredArtifactNames(
        role: Role,
        team: Team?
    ) -> [String] {
        let roleID = role.baseID

        // Use team role definition if available (findRole checks id, systemRoleID, and name)
        if let roleDef = team?.findRole(byIdentifier: roleID) {
            return roleDef.dependencies.requiredArtifacts
        }

        // Fall back to system template defaults for built-in roles
        return SystemTemplates.roles[role.baseID]?.dependencies.requiredArtifacts ?? []
    }

    /// Finds artifacts from prior steps that match the specified names.
    static func findArtifactsMatchingNames(
        names: [String],
        run: Run,
        upToStepIndex: Int
    ) -> [Artifact] {
        guard upToStepIndex > 0 else { return [] }

        let nameSet = Set(names)
        var matchedArtifacts: [Artifact] = []

        for idx in 0..<upToStepIndex {
            let step = run.steps[idx]
            for artifact in step.artifacts {
                if nameSet.contains(artifact.name) {
                    matchedArtifacts.append(artifact)
                }
            }
        }

        return matchedArtifacts
    }

    /// Builds the Required Artifacts section with full content.
    static func buildRequiredArtifactsSection(
        artifacts: [Artifact],
        artifactReader: (Artifact) -> String?
    ) -> String? {
        guard !artifacts.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("## Required Artifacts (Input for This Role)")
        lines.append("")

        for artifact in artifacts {
            lines.append("### \(artifact.name)")

            if let content = artifactReader(artifact) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lines.append("```")
                    lines.append(trimmed)
                    lines.append("```")
                } else {
                    lines.append("(empty content)")
                }
            } else {
                lines.append("(content not available)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
