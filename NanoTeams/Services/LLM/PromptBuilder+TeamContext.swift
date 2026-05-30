import Foundation

/// Team context helpers: team roles, position context, description, artifact instructions.
nonisolated extension PromptBuilder {

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
            // Dedup while PRESERVING team-declaration order. `Array(Set(...))`
            // iterates in per-process hash-seed order, so the same team rendered
            // twice (preview vs wire) could emit a different "Feeds into" order —
            // a non-deterministic byte mismatch that fails CI intermittently.
            var seen = Set<String>()
            let uniqueConsumers = consumers.filter { seen.insert($0).inserted }
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

    /// Trimmed team description, or empty string when unset. The `Team purpose:`
    /// label lives in the consuming template (`softwareTemplate` /
    /// `discussionTemplate` / `genericTemplate`) so the preview can render the
    /// label as plain text and only the value with the placeholder's category
    /// colour — matching `Members: {teamRoles}.` and
    /// `Your position: {positionContext}.`. When this returns `""`, the
    /// resulting orphan `Team purpose: ` line is collapsed by
    /// `TemplateResolver.stripOrphanInlineLabels` (and its attributed-string
    /// sibling in the preview path).
    static func buildTeamDescriptionLine(team: Team?) -> String {
        guard let team = team,
              !team.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return team.description.trimmingCharacters(in: .whitespacesAndNewlines)
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

        // No `Artifact Instructions:` flat-colon label — the block renders
        // immediately under the template's `## Deliverables` header, so the
        // label was redundant duplication of the section heading. List items
        // alone are clean and consistent with the surrounding `##` sectioning.
        let artifactInstructionsBlock =
            artifactInstructions.isEmpty
            ? ""
            : "\n" + artifactInstructions.joined(separator: "\n")

        return (expectedArtifactsLine, artifactInstructionsBlock)
    }
}
