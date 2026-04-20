import Foundation

/// Pipeline context building: prior steps summary and project description.
extension PromptBuilder {

    /// Builds context from previous pipeline steps.
    /// - Parameters:
    ///   - run: The current run containing steps.
    ///   - upToStepIndex: The index of the current step (exclusive).
    ///   - artifactReader: A closure to read artifact content.
    ///   - excludeArtifactNames: Artifact names to exclude (already shown as required artifacts).
    ///   - requiredArtifactNames: Names of artifacts the CURRENT role requires. When non-nil,
    ///     in-progress steps that don't produce any required artifact are omitted from the
    ///     handoff — they contribute only noise (a name + `Status: running` with no content
    ///     makes models reason in circles about whether they need to fetch the missing artifact).
    ///     Parallel branches (e.g. FAANG PM running in parallel with UXR) are the common case.
    ///     Done steps are always shown (their artifacts are useful even if not strictly required).
    ///     Supervisor is always shown (auto-injects the Supervisor Task content).
    ///     Pass `nil` (default) to preserve legacy no-filter behavior (e.g. for supervisor
    ///     auto-answer, where the supervisor needs broader awareness than any single role).
    static func buildPipelineContext(
        run: Run,
        upToStepIndex: Int,
        artifactReader: (Artifact) -> String?,
        excludeArtifactNames: Set<String> = [],
        requiredArtifactNames: Set<String>? = nil
    ) -> String {
        guard upToStepIndex > 0 else { return "" }

        var lines: [String] = []
        lines.append("Context from previous steps (for handoff):")

        // Statuses that mean "still in flight" — only these are noise candidates when
        // the step isn't a dependency. Failure / blocked states (`.failed`,
        // `.needsSupervisorInput`, `.needsApproval`, `.paused`) MUST always reach the
        // downstream role: a downstream that depends on a failed upstream needs to
        // know it's stuck, and even a non-dependency failure can reframe the run for
        // later roles.
        let inFlightStatuses: Set<StepStatus> = [.pending, .running]

        for idx in 0..<upToStepIndex {
            let step = run.steps[idx]

            // Skip in-progress non-dependency parallel steps. Regression: Run 14
            // UX Researcher drifted 67k+76k chars of thinking reasoning about
            // PM's "Product Requirements Status: running" because it couldn't
            // tell whether it needed to wait for / fetch the missing artifact.
            // PR wasn't in UXR's required_artifacts, so pure noise.
            //
            // Filter intentionally narrow: in-flight (pending/ready/running) only.
            // Failed/paused/needsSupervisorInput stay visible — silently dropping
            // those would hide real upstream problems from downstream roles.
            if let required = requiredArtifactNames,
               step.role != .supervisor,
               inFlightStatuses.contains(step.status),
               !step.artifacts.contains(where: { required.contains($0.name) })
            {
                continue
            }

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
