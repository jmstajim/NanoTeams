import Foundation

/// Extension for tool result side effects: scratchpad updates, artifact persistence,
/// tool event recording, and error guidance generation.
extension LLMExecutionService {

    // MARK: - Scratchpad Result Processing

    /// - Parameter wireIsMidPlanning: the phase verdict `applyPlanningPhase` derived this
    ///   iteration (`Authorization.wireIsMidPlanning`); no default, because a default would
    ///   assert a fact about the caller's wire.
    func processScratchpadResult(
        result: ToolExecutionResult,
        stepID: String,
        taskID: Int,
        wireIsMidPlanning: Bool,
        conversationMessages: inout [ChatMessage]
    ) async {
        guard result.toolName == ToolNames.updateScratchpad, !result.isError else { return }
        guard let dict = JSONUtilities.parseJSONDictionary(result.argumentsJSON),
              let content = resolveContentString(dict) else { return }

        await updateScratchpad(stepID: stepID, taskID: taskID, content: content)

        // Resolved ONCE, and BEFORE the content branch. It used to sit behind
        // `!content.isEmpty &&`, so a blank manager write short-circuited past it
        // and could not be classified at all — which is the one case that has to
        // be told apart, because it is the case where the app declines to do what
        // the call asked for.
        let isAutovisor = isAutovisorStep(stepID: stepID, taskID: taskID)
        let hasContent = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Autovisor memory write-through: the manager's scratchpad IS its
        // standing memory. Persist it to folder settings so it survives across
        // fresh runs (recurrence creates a new run each fire) and is editable in
        // Settings. Other roles' scratchpads stay step-scoped as before. A failed
        // write is surfaced to the manager (memory is its only cross-run state — a
        // silent failure means it silently forgets and re-derives next pass).
        var memoryOutcome: ScratchpadNotePolicy.MemoryOutcome?
        if isAutovisor {
            guard hasContent else {
                // Blank content never overwrites standing memory — see
                // `.clearedWithoutPersisting`. Not an error, but not what was asked either.
                await emitScratchpadSurfaces(
                    for: .autovisorMemory(.clearedWithoutPersisting),
                    stepID: stepID, taskID: taskID,
                    conversationMessages: &conversationMessages)
                return
            }
            let persisted = await delegate?.persistAutovisorMemory(content) ?? false
            memoryOutcome = persisted ? .persisted : .writeFailed
            if !persisted {
                let warning = "Memory write to disk failed — it may not survive the next run. Retry update_scratchpad, or report this if it keeps failing."
                conversationMessages.append(ChatMessage(role: .user, content: warning))
                // Persist with the wire role (.user) — a `.system` copy corrupts
                // stateless rebuilds with a mid-conversation system message.
                // `.runtimeWarning` because the remedy (a full disk, a permissions problem) is
                // the HUMAN's, and an unattributed `.user` turn is dropped by the feed's
                // no-source filter — the manager was told, the Supervisor never was.
                await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: warning,
                                       sourceContext: .runtimeWarning)
            }
        }

        // The manager is classified FIRST: role identity is the stronger fact, and
        // the planning wording would promise a boundary that structurally cannot
        // fire for it. (The two are mutually exclusive anyway — `isEligible`
        // carries `!isAutovisor` — so this only fixes the precedence, it never
        // discards a real planning wire.)
        //
        // The phase half is derived from the WIRE, not from a latch. The old
        // `planningTransitionDone` flag lived in `StepExecutionState`, which is
        // rebuilt on every entry — so a step resuming after a Supervisor answer
        // announced a "transition to your full toolset" that had happened long
        // ago, and a role with no phase at all announced one that never happened.
        // `isMidPlanning`, not `wireCarriesBrief`: after `.closeWithoutRebuild` the brief is
        // still on the wire but no boundary will ever fire, so the planning wording would
        // promise a fresh conversation that never arrives.
        //
        // The value arrives from `applyPlanningPhase`'s once-per-iteration derivation
        // (`Authorization.wireIsMidPlanning`) — still derived from the wire, not stored across
        // entries. Rescanning here cost two O(conversation) substring passes per
        // `update_scratchpad` on a wire with no ceiling.
        let writer: ScratchpadNotePolicy.Writer
        if let memoryOutcome {
            writer = .autovisorMemory(memoryOutcome)
        } else if wireIsMidPlanning {
            writer = .planningPhase
        } else {
            writer = .ordinaryRole
        }
        await emitScratchpadSurfaces(
            for: writer, stepID: stepID, taskID: taskID,
            conversationMessages: &conversationMessages)
    }

    /// Emits whichever of the two surfaces `ScratchpadNotePolicy` says this writer
    /// earns. Neither is unconditional: a plain "it worked" reaches the model
    /// nowhere (the tool envelope already says so) and the feed nowhere (the tool
    /// card already renders `→ ok`).
    private func emitScratchpadSurfaces(
        for writer: ScratchpadNotePolicy.Writer,
        stepID: String,
        taskID: Int,
        conversationMessages: inout [ChatMessage]
    ) async {
        if let wireMessage = ScratchpadNotePolicy.wireMessage(for: writer) {
            conversationMessages.append(ChatMessage(role: .user, content: wireMessage))
        }
        // `.toolAcknowledgement` so the note survives the feed's
        // `.user`-with-no-context filter — an unattributed turn is invisible
        // outside Debug mode.
        if let note = ScratchpadNotePolicy.note(for: writer) {
            await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: note,
                                   sourceContext: .toolAcknowledgement)
        }
    }

    // MARK: - Create Artifact Result Processing

    func processCreateArtifactResult(result: ToolExecutionResult, stepID: String, taskID: Int) async {
        guard result.toolName == ToolNames.createArtifact, !result.isError,
              case .artifact(let name, let content, let format) = result.signal,
              let delegate, isExecutionLive(stepID: stepID, taskID: taskID),
              let workFolderRoot = delegate.workFolderURL,
              let task = delegate.loadedTask(taskID),
              let runIndex = task.runs.indices.last
        else { return }

        // Normalize artifact name: if the LLM embellished the name (e.g., "Design Spec – Calculator"
        // instead of "Design Spec"), match it to the expected artifact name.
        // Must resolve BEFORE persisting so the file slug matches the in-memory artifact name.
        let resolvedName: String
        if let step = task.runs[runIndex].steps.first(where: { $0.id == stepID }) {
            resolvedName = Self.resolveArtifactName(name, expectedArtifacts: step.expectedArtifacts)
        } else {
            resolvedName = name
        }

        // Persist artifact file to disk (uses resolvedName for consistent slug)
        // Markdown is always written — it's the primary format for downstream roles and UI.
        guard let relativePath = try? repository.persistStepArtifactFile(
            at: workFolderRoot,
            taskID: task.id,
            runID: task.runs[runIndex].id,
            roleID: stepID,
            artifactName: resolvedName,
            content: content
        ) else { return }

        // Best-effort binary export (PDF/RTF/DOCX) alongside the markdown file.
        // The markdown remains the primary artifact (relativePath points to .md);
        // the binary file is a side-car for user download.
        if let formatStr = format,
           let exportFormat = DocumentTextExtractor.ExportFormat(rawValue: formatStr.lowercased()),
           let exportData = DocumentTextExtractor.export(text: content, to: exportFormat) {
            _ = try? repository.persistStepArtifactBinary(
                at: workFolderRoot,
                taskID: task.id,
                runID: task.runs[runIndex].id,
                roleID: stepID,
                artifactName: resolvedName,
                data: exportData,
                fileExtension: exportFormat.rawValue
            )
        }

        let now = MonotonicClock.shared.now()
        let artifact = Artifact(
            name: resolvedName,
            icon: Artifact.defaultIconForName(resolvedName),
            mimeType: "text/markdown",
            createdAt: now,
            updatedAt: now,
            relativePath: relativePath
        )

        // Add to step.artifacts (replace if already exists with same name)
        await delegate.mutateTask(taskID: taskID) { task in
            guard let ri = task.runs.indices.last,
                  let si = task.runs[ri].steps.firstIndex(where: { $0.id == stepID })
            else { return }
            if let existing = task.runs[ri].steps[si].artifacts.firstIndex(where: { $0.name == resolvedName }) {
                task.runs[ri].steps[si].artifacts[existing] = artifact
            } else {
                task.runs[ri].steps[si].artifacts.append(artifact)
            }
            // Clear revision flag — LLM has produced an artifact via create_artifact,
            // so checkArtifactCompleteness can resume normal operation.
            if task.runs[ri].steps[si].revisionComment != nil {
                task.runs[ri].steps[si].revisionComment = nil
            }
        }
    }

    // MARK: - Artifact Name Resolution

    /// Matches an LLM-provided artifact name to the closest expected artifact.
    /// LLMs often embellish names — adding camelCase ("CalculatorDesignSpec.md"),
    /// punctuation ("Design Spec — Calculator"), reordering ("Calculator: Design Spec"),
    /// or appending file extensions (".md", ".markdown", ".txt").
    /// Strategy: strip extensions, then try four passes on the slugified form (longest
    /// candidate first to avoid short-name shadowing), falling back to a compact form
    /// (alphanumeric-only, no separators) so "DesignSpec" matches "design_spec".
    static func resolveArtifactName(_ name: String, expectedArtifacts: [String]) -> String {
        // Exact match — fast path
        if expectedArtifacts.contains(name) { return name }

        let strippedName = Self.stripArtifactExtension(name)
        let slugifiedName = Artifact.slugify(strippedName)
        let compactInput = strippedName.lowercased().filter { $0.isLetter || $0.isNumber }

        // Pre-compute candidates sorted by length descending (longest first = most specific match)
        struct Candidate {
            let original: String
            let slug: String
            let compact: String
        }
        let candidates: [Candidate] = expectedArtifacts
            .map { Candidate(
                original: $0,
                slug: Artifact.slugify($0),
                compact: $0.lowercased().filter { $0.isLetter || $0.isNumber }
            )}
            .sorted { $0.slug.count > $1.slug.count }

        // Pass 1: prefix match on slug ("Design Spec – Calculator" → "design_spec_calculator" starts with "design_spec")
        for c in candidates where slugifiedName.hasPrefix(c.slug) { return c.original }
        // Pass 2: contains match on slug ("Calculator: Design Spec" → contains "design_spec")
        for c in candidates where slugifiedName.contains(c.slug) { return c.original }
        // Pass 3: compact contains ("CalculatorDesignSpec.md" → "calculatordesignspec" contains "designspec")
        for c in candidates where !c.compact.isEmpty && compactInput.contains(c.compact) { return c.original }

        return name
    }

    /// Strips a single common artifact file extension (case-insensitive).
    static func stripArtifactExtension(_ name: String) -> String {
        let knownExtensions = [".markdown", ".docx", ".html", ".json", ".pdf", ".rtf", ".txt", ".md"]
        let lowered = name.lowercased()
        for ext in knownExtensions where lowered.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }

}
