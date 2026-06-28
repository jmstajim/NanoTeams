import Foundation

/// Extension for tool result side effects: scratchpad updates, artifact persistence,
/// tool event recording, and error guidance generation.
extension LLMExecutionService {

    // MARK: - Scratchpad Result Processing

    func processScratchpadResult(
        result: ToolExecutionResult,
        stepID: String,
        taskID: Int,
        memoryStore: MemoryTagStore,
        conversationMessages: inout [ChatMessage]
    ) async {
        guard result.toolName == ToolNames.updateScratchpad, !result.isError else { return }
        guard let dict = JSONUtilities.parseJSONDictionary(result.argumentsJSON),
              let content = resolveContentString(dict) else { return }

        await updateScratchpad(stepID: stepID, taskID: taskID, content: content)

        // Autovisor memory write-through: the manager's scratchpad IS its
        // standing memory. Persist it to folder settings so it survives across
        // fresh runs (recurrence creates a new run each fire) and is editable in
        // Settings. Other roles' scratchpads stay step-scoped as before. A failed
        // write is surfaced to the manager (memory is its only cross-run state — a
        // silent failure means it silently forgets and re-derives next pass).
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           isAutovisorStep(stepID: stepID, taskID: taskID) {
            let persisted = await delegate?.persistAutovisorMemory(content) ?? false
            if !persisted {
                let warning = "⚠️ Failed to persist your memory to disk — it may NOT survive the next run. Retry update_scratchpad, or report this if it keeps failing."
                conversationMessages.append(ChatMessage(role: .user, content: warning))
                await appendLLMMessage(stepID: stepID, taskID: taskID, role: .system, content: warning)
            }
        }

        memoryStore.registerPlanUpdate(content: content, iteration: memoryStore.currentIteration)

        // Log the plan FIRST (before TRANSITION message)
        let planMessage = """
            Your current implementation plan:
            \(content)

            Update the plan after each completed action using update_scratchpad.
            Mark completed items with ~~strikethrough~~.
            """
        let stepKey = TaskStepKey(taskID: taskID, stepID: stepID)
        executionStates[stepKey]?.planMessageIndex = conversationMessages.count
        conversationMessages.append(
            ChatMessage(role: .user, content: planMessage)
        )
        await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: planMessage)

        // Inject transition message only on the FIRST scratchpad update (planning → implementation).
        // Subsequent scratchpad updates (marking items done) skip this to avoid redundant messages.
        if executionStates[stepKey]?.planningTransitionDone != true {
            executionStates[stepKey]?.planningTransitionDone = true
            let transitionMessage = """
            ✅ Plan recorded. Now proceeding to IMPLEMENTATION PHASE.

            You now have access to all tools. Execute your plan step by step.
            Do NOT call update_scratchpad again unless marking items complete with ~~strikethrough~~.

            Start with step 1 of your plan.
            """
            conversationMessages.append(
                ChatMessage(role: .user, content: transitionMessage)
            )
            await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: transitionMessage)
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

    // MARK: - Error Guidance

    func buildToolErrorGuidance(result: ToolExecutionResult) -> String {
        let dict = JSONUtilities.parseJSONDictionary(result.outputJSON)

        // Two envelope shapes carry the error code in different places:
        // executor-emitted errors store a top-level string ("tool_not_authorized",
        // "identical_write_loop"); ToolErrorHandler-emitted errors store a nested
        // object ({"error":{"code":"INVALID_ARGS",...}}).
        let errorCode: String? = {
            if let topLevel = dict?["error"] as? String { return topLevel }
            if let nested = (dict?["error"] as? [String: Any])?["code"] as? String { return nested }
            return nil
        }()

        // Normalize to lowercase so handler-emitted UPPERCASE codes
        // (`TOOL_NOT_AUTHORIZED`) and executor-emitted lowercase literals
        // (`tool_not_authorized`) reach the same branch.
        switch errorCode?.lowercased() {
        case "tool_not_authorized":
            // Args aren't the cause — the tool isn't in this role's schema. The
            // generic "retry with correct arguments" suffix actively misleads
            // weaker models into looping on the same unavailable tool.
            //
            // Prefer the envelope's `message` field — it carries the scope
            // distinction the executor and `MeetingToolExecutor` composed
            // ("for this role" vs "in this meeting"). Synthesizing here would
            // misreport meeting-scope rejections as role-level rejections,
            // sending the model to retry outside the meeting context.
            let toolName = (dict?["tool"] as? String) ?? result.toolName
            let intro = (dict?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Tool '\(toolName)' is not available."
            return "\(intro) Choose a different tool from the list in your system prompt; do not retry '\(toolName)'."

        case "precondition_failed":
            // Like `tool_not_authorized`, args aren't the cause — the work
            // folder lacks a precondition (no .git, no vision model, no
            // xcode scheme, no opened folder). The LLM can't fix any of
            // those from inside the role, so retrying with different args
            // is wasted work. Surface the envelope's actionable message
            // (it names the missing prerequisite) and tell the model to
            // pick a different approach.
            let toolName = (dict?["tool"] as? String) ?? result.toolName
            let intro = (dict?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Tool '\(toolName)' is unavailable."
            return "\(intro) Do not retry '\(toolName)' — the precondition is set by the work folder, not by your arguments. Pick a different tool or proceed without this step."

        case "bash_denied":
            // The command was blocked by the bash-permission policy (deny rule,
            // judge rejection, or human approval unavailable). Like
            // `tool_not_authorized`, the block is policy, not args — retrying the
            // same command loops. Surface the envelope's reason and steer the
            // model to a different approach.
            let nested = ((dict?["error"] as? [String: Any])?["message"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            let reason = nested ?? "The command was blocked by the command-permission policy."
            return "\(reason) Do NOT retry this command — the block is set by policy, not by your arguments. Choose a different approach, use a read-only or already-approved command, or ask the Supervisor."

        case "identical_write_loop":
            // The args ARE the rejected duplicate — retrying with the same args
            // hits the loop guard again. The model needs to verify state, not
            // re-issue. `"?"` is the executor's sentinel when args lack a
            // parseable `path`; collapse it to the generic placeholder so the
            // LLM doesn't see it as a literal path.
            let path = (dict?["path"] as? String)
                .flatMap { ($0.isEmpty || $0 == "?") ? nil : $0 }
            let target = path.map { "'\($0)'" } ?? "the file"
            return "Identical write to \(target) was already attempted in this step. Read the file's current state to verify whether the change is needed; do not re-issue the same write."

        case "anchor_ambiguous":
            // The anchor IS findable — it matched several regions once trailing
            // whitespace is ignored. The anchor_not_found steering below
            // ("character for character") would point the model at the wrong
            // repair; what it needs is MORE surrounding lines. Prefer the
            // envelope's message (it carries the region count).
            let nestedMessage = ((dict?["error"] as? [String: Any])?["message"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            return nestedMessage
                ?? "old_text matches multiple regions of the file — include more surrounding lines in old_text to pinpoint one."

        case "anchor_not_found":
            // `old_text` didn't match the file's current content. This is almost
            // always a transcription error in the anchor (a wrong character, lost
            // whitespace, or `/` ↔ `\` slash confusion), NOT a file mutation — so
            // do not claim "the content changed" and do not hard-demand a re-read
            // (the read-dedup would answer "unchanged, do NOT re-read", deadlocking
            // the model). Steer it to compare against the content it already read
            // and fix the anchor character-for-character. Path comes from args
            // (handler envelope doesn't include it in details).
            let argsDict = JSONUtilities.parseJSONDictionary(result.argumentsJSON)
            let path = (argsDict?["path"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            let target = path.map { "'\($0)'" } ?? "the file"
            var guidance = "old_text not found in \(target). It must match the file's current content exactly, character for character — including whitespace, indentation, and slash direction (`/` vs `\\`). Compare your old_text against the content you already read and correct it; only re-read if you have not yet read this region."
            // The handler attaches a specific diagnosis (indentation mismatch,
            // whitespace-only anchor, anchor longer than file) when it found one —
            // re-state it last so the generic character-level steering doesn't bury it.
            let hint = (((dict?["error"] as? [String: Any])?["details"] as? [String: Any])?["hint"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            if let hint {
                guidance += " " + hint
            }
            return guidance

        default:
            let errorObj = dict?["error"] as? [String: Any]
            let msg = (errorObj?["message"] as? String)
                ?? (dict?["message"] as? String)
                ?? "unknown error"
            // Surface the typed code (when present) so the LLM can disambiguate
            // recovery — e.g. `DELEGATION_DENIED` (don't retry) vs
            // `DELEGATION_TIMED_OUT` (maybe retry later) vs `INVALID_ARGS`
            // (fix args). Only handler-shape envelopes carry `code`; the
            // legacy `{message:...}` shape gets no prefix to avoid `[]` artifacts.
            let codePrefix = (errorObj?["code"] as? String).map { "[\($0)] " } ?? ""
            return "Tool '\(result.toolName)' failed: \(codePrefix)\(msg). Retry the tool call with the correct arguments."
        }
    }

}
