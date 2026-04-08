import Foundation

/// Extension for tool result side effects: scratchpad updates, artifact persistence,
/// tool event recording, and error guidance generation.
extension LLMExecutionService {

    // MARK: - Scratchpad Result Processing

    func processScratchpadResult(
        result: ToolExecutionResult,
        stepID: String,
        memoryStore: MemoryTagStore,
        conversationMessages: inout [ChatMessage]
    ) async {
        guard result.toolName == ToolNames.updateScratchpad, !result.isError else { return }
        guard let dict = JSONUtilities.parseJSONDictionary(result.argumentsJSON),
              let content = resolveContentString(dict) else { return }

        await updateScratchpad(stepID: stepID, content: content)
        memoryStore.registerPlanUpdate(content: content, iteration: memoryStore.currentIteration)

        // Log the plan FIRST (before TRANSITION message)
        let planMessage = """
            Your current implementation plan:
            \(content)

            Update the plan after each completed action using update_scratchpad.
            Mark completed items with ~~strikethrough~~.
            """
        executionStates[stepID]?.planMessageIndex = conversationMessages.count
        conversationMessages.append(
            ChatMessage(role: .user, content: planMessage)
        )
        await appendLLMMessage(stepID: stepID, role: .user, content: planMessage)

        // Inject transition message only on the FIRST scratchpad update (planning → implementation).
        // Subsequent scratchpad updates (marking items done) skip this to avoid redundant messages.
        if executionStates[stepID]?.planningTransitionDone != true {
            executionStates[stepID]?.planningTransitionDone = true
            let transitionMessage = """
            ✅ Plan recorded. Now proceeding to IMPLEMENTATION PHASE.

            You now have access to all tools. Execute your plan step by step.
            Do NOT call update_scratchpad again unless marking items complete with ~~strikethrough~~.

            Start with step 1 of your plan.
            """
            conversationMessages.append(
                ChatMessage(role: .user, content: transitionMessage)
            )
            await appendLLMMessage(stepID: stepID, role: .user, content: transitionMessage)
        }
    }

    // MARK: - Create Artifact Result Processing

    func processCreateArtifactResult(result: ToolExecutionResult, stepID: String) async {
        guard result.toolName == ToolNames.createArtifact, !result.isError,
              case .artifact(let name, let content, let format) = result.signal,
              let delegate, let tid = taskIDForStep(stepID),
              let workFolderRoot = delegate.workFolderURL,
              let task = delegate.loadedTask(tid),
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
        await delegate.mutateTask(taskID: tid) { task in
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
    /// LLMs often embellish names (e.g., "Design Spec – Calculator", "Calculator: Design Spec").
    /// Uses slugified prefix/contains matching. Prefers prefix match over contains match.
    static func resolveArtifactName(_ name: String, expectedArtifacts: [String]) -> String {
        // Exact match — fast path
        if expectedArtifacts.contains(name) { return name }

        let slugifiedName = Artifact.slugify(name)

        // Pre-compute slugs sorted by length descending (longest first = most specific match)
        let slugged = expectedArtifacts
            .map { (original: $0, slug: Artifact.slugify($0)) }
            .sorted { $0.slug.count > $1.slug.count }

        // Pass 1: prefix match (stronger signal — "Design Spec – Calculator")
        for entry in slugged {
            if slugifiedName.hasPrefix(entry.slug) {
                return entry.original
            }
        }

        // Pass 2: contains match (weaker — "Calculator: Design Spec")
        // Longest slug first prevents short names (e.g., "Code") from shadowing
        // longer ones (e.g., "Code Review").
        for entry in slugged {
            if slugifiedName.contains(entry.slug) {
                return entry.original
            }
        }

        return name
    }

    // MARK: - Error Guidance

    func buildToolErrorGuidance(result: ToolExecutionResult) -> String {
        let errorDetail: String = {
            if let dict = JSONUtilities.parseJSONDictionary(result.outputJSON),
               let errorObj = dict["error"] as? [String: Any],
               let msg = errorObj["message"] as? String {
                return msg
            }
            if let dict = JSONUtilities.parseJSONDictionary(result.outputJSON),
               let msg = dict["message"] as? String {
                return msg
            }
            return "unknown error"
        }()
        return "Tool '\(result.toolName)' failed: \(errorDetail). Retry the tool call with the correct arguments."
    }

}
