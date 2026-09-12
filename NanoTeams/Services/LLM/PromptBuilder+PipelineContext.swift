import Foundation

/// Pipeline context building: prior steps summary and project description.
nonisolated extension PromptBuilder {

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

        // `##`/`###` markdown headers — the same sectioning system every sibling
        // user message uses (`## Supervisor Task`, `## Required Artifacts`).
        // This block was the one flat-colon-label holdout [Sclar2024].
        //
        // The header is PREPENDED at the end, never seeded here: the loop below can
        // filter every step out (the Run 14 in-flight filter, reachable exactly when the
        // engine runs ready roles in parallel — CLAUDE.md #45), and a seeded header then
        // survived `trimmingCharacters` as the literal string "## Prior Steps". The
        // caller's `!isEmpty` gate let that through as a user turn consisting of one
        // header and nothing else. `stripOrphanHeaders` cannot help — it only ever runs
        // over the SYSTEM prompt.
        var lines: [String] = []

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
            let title = (step.title != step.role.displayName && !step.title.isEmpty)
                ? ": \(step.title)" : ""
            lines.append("### Step \(idx + 1) — \(step.role.displayName)\(title) — \(statusPhrase(step.status))")

            // `Supervisor A:` is read by OTHER roles, so it may only carry what a Supervisor
            // actually said. The `[ Ask as form ]` directive lives in the same field — it is
            // the only channel a parked step has — but it is the app telling that role to
            // re-ask, not a decision anyone made. To this summary it is an UNANSWERED
            // question, which is also true: the role is still owed one.
            let answer = step.lastSupervisorAskResolution == .questionnaireRequest
                ? nil : step.effectiveSupervisorAnswer
            if let q = step.supervisorQuestion, let a = answer, !q.isEmpty, !a.isEmpty {
                lines.append("Supervisor Q: \(q)")
                lines.append("Supervisor A: \(a)")
            } else if let q = step.supervisorQuestion, !q.isEmpty {
                lines.append("Supervisor Q: \(q)")
            } else if let a = answer, !a.isEmpty {
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
                        if let content = artifactReader(artifact),
                           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            // Same escape hardening as buildRequiredArtifactsSection:
                            // fence outgrows any backtick run inside the body.
                            let fence = artifactFence(for: content)
                            lines.append(fence)
                            lines.append(content)
                            lines.append(fence)
                        } else {
                            lines.append("(content missing or unreadable)")
                        }
                    } else {
                        var meta = "- \(artifact.name)"
                        // Show the path the file tools accept (project-root-relative, with the
                        // `.nanoteams/` prefix the sandbox resolves against) — NOT the bare
                        // stored `relativePath`, which `read_file` would fail to resolve.
                        // nil for internal/non-persisted artifacts (no readable reference).
                        if let readable = artifact.llmReadablePath {
                            meta += " (path: \(readable))"
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

        // Every step filtered out ⇒ no section at all, not an empty one.
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }
        return "## Prior Steps\n\n" + body
    }

    /// Plain-words status for the model — `step.status.rawValue` leaked internal
    /// camelCase enum values (`needsSupervisorInput`) into the prompt.
    private static func statusPhrase(_ status: StepStatus) -> String {
        switch status {
        case .pending: return "not started"
        case .running: return "in progress"
        case .paused: return "paused"
        case .needsSupervisorInput: return "waiting for the Supervisor"
        case .needsApproval: return "waiting for approval"
        case .failed: return "failed"
        case .done: return "done"
        }
    }

    /// Returns the bare work-folder context body for injection via the
    /// `{workFolderContext}` template placeholder. The `## Work folder` header
    /// lives in the template so the author can rename or reposition it — and so
    /// it collapses via `TemplateResolver.stripOrphanHeaders` when the body is
    /// empty.
    ///
    /// Body = bold folder name, then sections joined with a blank line, each
    /// omitted when its source is empty:
    /// 1. the user-written `settings.context` (trimmed, capped at
    ///    `ArtifactConstants.maxDescriptionChars`);
    /// 2. one `### Agent instructions (<path>)` section per content-injected
    ///    file (auto-discovered main first, then user-attached text files),
    ///    **uncapped** — content is pre-trimmed at scan time;
    /// 3. `### Other agent instruction files` + a bullet list of the remaining
    ///    instruction-file paths (read on demand via `read_file`).
    ///
    /// Returns `nil` only when ALL sources are empty. When no instruction files
    /// exist (`agentInstructions == nil`/`.empty`), the output is byte-identical
    /// to the legacy `**{name}**\n\n{context}` form so existing folders see zero
    /// prompt diff.
    /// Heading level of the `## Work folder` section this message fills — every
    /// template that carries `{workFolderContext}` puts it at h2. Injected bodies nest
    /// below it, which is what keeps a `##` inside third-party text from reading as a
    /// section of the prompt itself.
    static let workFolderHeadingLevel = 2

    /// `toolNames` has NO default on purpose. The capability line below is written from
    /// it, and an omitted argument would read as "this role can run nothing" — the exact
    /// falsehood the line exists to prevent, emitted silently at the one seam where every
    /// role's work-folder context is built.
    static func buildWorkFolderContextMessage(
        workFolder: WorkFolderProjection?,
        agentInstructions: AgentInstructionsSnapshot? = nil,
        toolNames: Set<String>
    ) -> String? {
        guard let wf = workFolder else { return nil }

        var sections: [String] = []

        var context = wf.settings.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if context.count > ArtifactConstants.maxDescriptionChars {
            context =
                String(context.prefix(ArtifactConstants.maxDescriptionChars)) + "..."
        }
        // Re-levelled AFTER the cap, never before: the cap cuts by character, so a body
        // truncated mid-`##` would otherwise keep an un-demoted fragment.
        //
        // This value is written by a HUMAN in Settings and by a MODEL through
        // `set_work_folder_context` (Autovisor), it persists for the folder, and it lands
        // in `## Work folder` — the section immediately before `## Guidance`, which for the
        // default Coding Assistant team carries "A `## Attached Files` section lists paths.
        // Open each before doing anything else … do NOT skip one as unrelated". An
        // unre-levelled `## Attached Files` here therefore FABRICATED a section that the
        // next section instructs the role to obey. Same class as the agent-instructions
        // hole recorded in the playbook's CAV.6.2, with the difference that a tool call
        // can write this one.
        if !context.isEmpty {
            sections.append(SkillConstants.nestedBody(context, under: workFolderHeadingLevel))
        }

        var injectedAnyInstructions = false
        if let snapshot = agentInstructions {
            for file in snapshot.injectedFiles {
                // Scanner stores trimmed non-empty content; the whitespace probe
                // (O(1) for real content) is defense against hand-built values —
                // no re-trim of a possibly-100KB string per render.
                guard let content = file.injectedContent,
                      content.contains(where: { !$0.isWhitespace }) else { continue }
                // The CAV.6.2 hole itself: a `CLAUDE.md` in the work folder is
                // third-party prose that rides every role's system prompt.
                sections.append(
                    "### Agent instructions (\(file.relativePath))\n\n"
                        + SkillConstants.nestedBody(content, under: workFolderHeadingLevel + 1))
                injectedAnyInstructions = true
            }
            let listed = snapshot.listedPaths
            if !listed.isEmpty {
                let bullets = listed.map { "- \($0)" }.joined(separator: "\n")
                sections.append("### Other agent instruction files\n\nRead with read_file when relevant:\n\(bullets)")
            }
            if injectedAnyInstructions {
                sections.append(runnableCommandsSection(toolNames: toolNames))
            }
        }

        if sections.isEmpty {
            return nil  // No useful work folder context to send
        }

        // The name as a heading one level under the `## Work folder` carrier — the same
        // level as `### Agent instructions (…)` beside it. Bold was chosen over a `Name:`
        // label to avoid mixed label style, and was itself a second emphasis system in a
        // repo-authored layer (R4.3.2) until 2026-09-07.
        return "### \(wf.name)\n\n\(sections.joined(separator: "\n\n"))"
    }

    /// One line reconciling third-party instructions with the role's actual tools.
    ///
    /// An agent-instructions file is written for whoever reads it, and the ones in real
    /// work folders give orders: NanoTeams' own `CLAUDE.md` says "run the project's build
    /// command yourself". Until 2026-09-11 this message took no role, so that order went
    /// verbatim to every role in the team — including the ones holding no runner. A
    /// directive a role cannot carry out is, in the playbook's words, an unfulfillable
    /// directive rather than disobedience (E7.7.6), and MeditationApp task 48 run 1 is what
    /// a model does with one: the planner was refused `run_xcodebuild`, and 0.4 seconds
    /// later wrote `=== BUILD SUCCESS ===` into the brief that five roles downstream took
    /// as fact.
    ///
    /// The capable branch names tools; the incapable branch names NONE — R5.2.4 allows an
    /// engine-authored turn to name only tools that are in the role's own schema, and
    /// "ask someone who can build" to a role with no channel is prose nobody reads.
    private static func runnableCommandsSection(toolNames: Set<String>) -> String {
        var can: [String] = []
        if toolNames.contains(ToolNames.runXcodebuild) || toolNames.contains(ToolNames.runXcodetests) {
            let pair = [ToolNames.runXcodebuild, ToolNames.runXcodetests]
                .filter(toolNames.contains)
                .map { "`\($0)`" }
                .joined(separator: " / ")
            can.append("build and test commands, with \(pair)")
        }
        if toolNames.contains(ToolNames.bash) {
            can.append("shell commands, with `\(ToolNames.bash)`")
        }

        let line: String
        if can.isEmpty {
            line = "The instructions above may ask for commands to be run. None of them is "
                + "yours to run — you hold no tool that runs one. State what such a command "
                + "would have settled as unverified, and never state its result."
        } else {
            line = "Of the commands the instructions above may ask for, you can run "
                + can.joined(separator: "; and ")
                + ". Anything else is not yours to run: state what it would have settled as "
                + "unverified, and never state its result."
        }
        return "### Which of these commands are yours to run\n\n\(line)"
    }
}
