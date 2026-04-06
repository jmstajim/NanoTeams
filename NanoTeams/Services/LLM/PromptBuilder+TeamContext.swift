import Foundation

/// Team context helpers: team roles, position context, description, artifact instructions.
extension PromptBuilder {

    /// Build team context string from team roles (excludes Supervisor).
    static func buildTeamContext(team: Team?) -> String {
        guard let team = team else { return "(unknown team)" }
        let roles = team.nonSupervisorRoles
        guard !roles.isEmpty else { return "(no team members)" }
        return roles.map(\.name).joined(separator: ", ")
    }

    /// Build position context string from role dependencies.
    static func buildPositionContext(roleDefinition: TeamRoleDefinition?, team: Team?) -> String {
        guard let roleDefinition = roleDefinition else { return "(unknown position)" }
        var parts: [String] = []

        let required = roleDefinition.dependencies.requiredArtifacts
        let produces = roleDefinition.dependencies.producesArtifacts

        if !required.isEmpty {
            // Find which roles produce the required artifacts
            let producers = required.compactMap { artifactName -> String? in
                guard let team = team else { return nil }
                return team.rolesProducing(artifactName: artifactName).first?.name
            }
            if !producers.isEmpty {
                parts.append("You work after \(producers.joined(separator: ", "))")
            }
            parts.append("Receives: \(required.joined(separator: ", "))")
        }
        if !produces.isEmpty {
            // Find which roles consume the produced artifacts
            let consumers = produces.flatMap { artifactName -> [String] in
                guard let team = team else { return [] }
                return team.rolesRequiring(artifactName: artifactName).map(\.name)
            }
            let uniqueConsumers = Array(Set(consumers))
            if !uniqueConsumers.isEmpty {
                parts.append("Feeds into: \(uniqueConsumers.joined(separator: ", "))")
            }
            parts.append("Produces: \(produces.joined(separator: ", "))")
        }

        if parts.isEmpty {
            return "(no artifact dependencies)"
        }
        return parts.joined(separator: ". ")
    }

    /// Build team description line if available.
    static func buildTeamDescriptionLine(team: Team?) -> String {
        guard let team = team,
              !team.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return "\nTeam purpose: \(team.description.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    static func buildTeamRolesLine(team: Team?, run: Run) -> String {
        // Prefer team role definitions (includes observers that have no steps)
        if let team {
            let names = team.nonSupervisorRoles.map(\.name)
            if !names.isEmpty { return names.joined(separator: ", ") }
        }
        // Fallback for nil team
        var teamRoles: [String] = []
        var seenRoles = Set<String>()
        for item in run.steps {
            let name = item.role.displayName
            if !seenRoles.contains(name) {
                teamRoles.append(name)
                seenRoles.insert(name)
            }
        }
        return teamRoles.isEmpty ? "(unknown)" : teamRoles.joined(separator: ", ")
    }

    static func buildArtifactInstructions(
        step: StepExecution,
        teamArtifacts: [TeamArtifact]
    ) -> (expectedLine: String, instructionsBlock: String) {
        var artifactInstructions: [String] = []
        var expectedArtifactNames: [String] = []

        for artifactName in step.expectedArtifacts {
            expectedArtifactNames.append(artifactName)
            if let match = teamArtifacts.first(where: { $0.name == artifactName }) {
                if !match.description.isEmpty {
                    artifactInstructions.append(
                        "- For \(match.name): \(match.description)")
                }
            }
        }

        let expectedArtifactsLine: String
        if !expectedArtifactNames.isEmpty {
            expectedArtifactsLine = expectedArtifactNames.sorted().joined(separator: ", ")
        } else {
            expectedArtifactsLine = step.expectedArtifacts.sorted().joined(separator: ", ")
        }

        let artifactInstructionsBlock =
            artifactInstructions.isEmpty
            ? ""
            : "\nArtifact Instructions:\n" + artifactInstructions.joined(separator: "\n")

        return (expectedArtifactsLine, artifactInstructionsBlock)
    }
}
