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

    /// Fence line for wrapping an artifact body: one backtick longer than the
    /// longest backtick run inside the content, minimum four. CommonMark closes
    /// a fence only on an equal-or-longer run, so no body — markdown with ```
    /// samples, or documentation that itself nests ````-fences — can close the
    /// wrapper early and spill artifact text into prompt structure.
    static func artifactFence(for content: String) -> String {
        var longest = 0
        var current = 0
        for ch in content {
            if ch == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return String(repeating: "`", count: max(4, longest + 1))
    }

    /// `content` cut to `cap` graphemes with a truncation marker, probing one grapheme past
    /// the cap rather than counting the whole body — `String.count` walks every grapheme,
    /// and a body can be megabytes. The fence around it is sized by `buildArtifactSection`
    /// over the body that actually SHIPS (the truncated text plus its marker), because
    /// sizing it over the pre-cap string picks a wrapper for a backtick run that was cut
    /// away. (`fencedArtifactBody`, which did both, lost its last caller when the three
    /// side paths moved onto `buildArtifactSection` on 2026-09-06 and was deleted.)
    static func cappedBody(_ content: String, cap: Int) -> String {
        let probe = String(content.prefix(cap + 1))
        return probe.count > cap ? String(probe.dropLast()) + "\n... (truncated)" : probe
    }

    /// Builds the Required Artifacts section with full content.
    static func buildRequiredArtifactsSection(
        artifacts: [Artifact],
        artifactReader: (Artifact) -> String?
    ) -> String? {
        buildArtifactSection(
            heading: "Required Artifacts (Input for This Role)", artifacts: artifacts,
            artifactReader: artifactReader)
    }

    /// One `## <heading>` block with a `### <name>` sub-heading per artifact and each body in
    /// a fence that cannot be closed from inside it — the ONE shape for every artifact block
    /// a model reads: the step's required-artifacts section, the consultation chat's three
    /// artifact turns and the meeting speaker's grounding. `cap` bounds each body the way
    /// the consultation and meeting paths always did; `nil` ships the whole body. `nil` for
    /// no artifacts, so no caller emits a heading over nothing (R3.9.2).
    ///
    /// Until 2026-09-06 the three side paths rendered `Label:` on its own line and `[Name]:`
    /// brackets while the step path rendered `## `/`### ` — two families for the same data
    /// in one wire, and an unreadable body on the meeting path rendered as a bare bracket
    /// (R1.3.2, R1.8.7).
    /// `text` cut to at most `maxChars` characters WITHOUT opening a fence it cannot close:
    /// lines are kept whole, a fenced block is kept whole or dropped whole, and a dropped
    /// remainder is announced on its own line. Fences follow CommonMark: a line opening
    /// with three or more backticks starts a block whatever follows them (the info string,
    /// ```swift), and only a line of backticks ALONE at least as long as the opener closes
    /// it. Until 2026-09-07 an opener with an info string was no fence at all, so the
    /// block's own closing line opened a fence nothing closed. `String.prefix` over a block that carries
    /// fenced artifact bodies could stop inside a fence, and everything the caller appended
    /// after the cut — the question it wanted answered — then read as fenced data (R1.3.3;
    /// the Supervisor auto-answer did exactly that until 2026-09-07).
    static func truncatedOutsideFences(_ text: String, maxChars: Int) -> String {
        // Sizes are UTF-8 byte counts kept as running totals: a byte count never
        // undercounts characters, so the cap holds, and no line or block is measured
        // twice (`.count` on a String is a grapheme walk; a `reduce` over the pending
        // block on every close re-walked the block — coverage axes a5 / a1).
        guard text.utf8.count > maxChars else { return text }
        let marker = "(earlier context truncated)"
        var kept: [String] = []
        var keptCount = 0
        var pendingFence: [String] = []
        var pendingCount = 0
        var openFence: Int?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let lineCount = rawLine.utf8.count + 1
            // Length of the leading backtick run; a backtick is one byte, so the run
            // spans the whole line exactly when it equals the line's byte count.
            let fenceRun = trimmed.utf8.prefix { $0 == UInt8(ascii: "`") }.count
            let opensFence = fenceRun >= 3
            let isBareFence = opensFence && fenceRun == trimmed.utf8.count
            if let fence = openFence {
                pendingFence.append(rawLine)
                pendingCount += lineCount
                if isBareFence, fenceRun >= fence {
                    guard keptCount + pendingCount <= maxChars else { break }
                    kept += pendingFence
                    keptCount += pendingCount
                    pendingFence = []
                    pendingCount = 0
                    openFence = nil
                }
                continue
            }
            if opensFence {
                openFence = fenceRun
                pendingFence = [rawLine]
                pendingCount = lineCount
                continue
            }
            guard keptCount + lineCount <= maxChars else { break }
            kept.append(rawLine)
            keptCount += lineCount
        }
        return (kept.joined(separator: "\n") + "\n" + marker)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func buildArtifactSection(
        heading: String,
        artifacts: [Artifact],
        cap: Int? = nil,
        artifactReader: (Artifact) -> String?
    ) -> String? {
        guard !artifacts.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("## \(heading)")
        lines.append("")

        for artifact in artifacts {
            lines.append("### \(artifact.name)")

            if let content = artifactReader(artifact) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let body = cap.map { cappedBody(trimmed, cap: $0) } ?? trimmed
                    let fence = artifactFence(for: body)
                    lines.append(fence)
                    lines.append(body)
                    lines.append(fence)
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
