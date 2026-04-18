import Foundation

/// Pipeline context building: prior steps summary and project description.
extension PromptBuilder {

    /// Builds context from previous pipeline steps.
    /// - Parameters:
    ///   - run: The current run containing steps.
    ///   - upToStepIndex: The index of the current step (exclusive).
    ///   - artifactReader: A closure to read artifact content.
    ///   - excludeArtifactNames: Artifact names to exclude (already shown as required artifacts).
    static func buildPipelineContext(
        run: Run,
        upToStepIndex: Int,
        artifactReader: (Artifact) -> String?,
        excludeArtifactNames: Set<String> = []
    ) -> String {
        guard upToStepIndex > 0 else { return "" }

        var lines: [String] = []
        lines.append("Context from previous steps (for handoff):")

        for idx in 0..<upToStepIndex {
            let step = run.steps[idx]
            lines.append("")
            if step.title != step.role.displayName && !step.title.isEmpty {
                lines.append("Step \(idx + 1) — \(step.role.displayName): \(step.title)")
            } else {
                lines.append("Step \(idx + 1) — \(step.role.displayName)")
            }
            lines.append("Status: \(step.status.rawValue)")

            if let q = step.supervisorQuestion, let a = step.effectiveSupervisorAnswer, !q.isEmpty, !a.isEmpty {
                lines.append("Supervisor Q: \(q)")
                lines.append("Supervisor A: \(a)")
            } else if let q = step.supervisorQuestion, !q.isEmpty {
                lines.append("Supervisor Q: \(q)")
            } else if let a = step.effectiveSupervisorAnswer, !a.isEmpty {
                lines.append("Supervisor A: \(a)")
            }

            // Filter out artifacts that are already shown as required artifacts
            let artifactsToShow = step.artifacts.filter { !excludeArtifactNames.contains($0.name) }
            if !artifactsToShow.isEmpty {
                lines.append("Artifacts:")
                for artifact in artifactsToShow {
                    let shouldAutoInject = (step.role == .supervisor)

                    if shouldAutoInject {
                        lines.append("- \(artifact.name):")
                        if let content = artifactReader(artifact) {
                            lines.append("```")
                            lines.append(content)
                            lines.append("```")
                        } else {
                            lines.append("(content missing or unreadable)")
                        }
                    } else {
                        var meta = "- \(artifact.name)"
                        if let rel = artifact.relativePath, !rel.isEmpty {
                            meta += " (path: \(rel))"
                        }
                        lines.append(meta)
                    }
                }
            }

            if !step.amendments.isEmpty {
                lines.append("Amendments: \(step.amendments.count)")
                for amendment in step.amendments {
                    lines.append("  - \(amendment.reason) [requested by \(amendment.requestedByRoleID), \(amendment.meetingDecision)]")
                }
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the project context message.
    static func buildWorkFolderContextMessage(workFolder: WorkFolderProjection?) -> String? {
        guard let wf = workFolder else { return nil }

        var lines: [String] = []
        lines.append("Work folder context:")
        lines.append("Name: \(wf.name)")

        var description = wf.settings.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.count > ArtifactConstants.maxDescriptionChars {
            description =
                String(description.prefix(ArtifactConstants.maxDescriptionChars)) + "..."
        }
        if description.isEmpty {
            return nil  // No useful project context to send
        }
        lines.append("Description: \(description)")

        return lines.joined(separator: "\n")
    }
}
