import Foundation

/// Extension for tool result side effects: scratchpad updates, artifact persistence,
/// tool event recording, and error guidance generation.
extension LLMExecutionService {

    // MARK: - Scratchpad Result Processing

    func processScratchpadResult(
        result: ToolExecutionResult,
        stepID: String,
        taskID: Int,
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
                let warning = "Memory write to disk failed — it may not survive the next run. Retry update_scratchpad, or report this if it keeps failing."
                conversationMessages.append(ChatMessage(role: .user, content: warning))
                // Persist with the wire role (.user) — a `.system` copy corrupts
                // stateless rebuilds with a mid-conversation system message.
                await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: warning)
            }
        }

        // ONE acknowledgement per update. The plan itself is NOT echoed back —
        // it is verbatim in the model's own tool-call turn one message earlier
        // (a stateful chain carries it; echoing was pure duplication), and the
        // pre-fix pair "Update the plan after each completed action" +
        // "Do NOT call update_scratchpad again" landed back-to-back with
        // opposite surface readings.
        // Derived from the WIRE, not from a latch. The old
        // `planningTransitionDone` flag lived in `StepExecutionState`, which is
        // rebuilt on every entry — so a step resuming after a Supervisor answer
        // announced a "transition to your full toolset" that had happened long
        // ago, and a role with no phase at all announced one that never happened.
        // `isMidPlanning`, not `wireCarriesBrief`: after `.closeWithoutRebuild` the brief is
        // still on the wire but no boundary will ever fire, so the planning wording would
        // promise a fresh conversation that never arrives.
        let ackMessage = PlanningPhasePolicy.scratchpadAck(
            isPlanningWire: PlanningPhasePolicy.isMidPlanning(conversationMessages))
        conversationMessages.append(
            ChatMessage(role: .user, content: ackMessage)
        )
        await appendLLMMessage(stepID: stepID, taskID: taskID, role: .user, content: ackMessage)
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

        case "plan_required":
            // The ONLY rejection that is temporal rather than structural: the
            // tool is real, the role has it, and the very same call works once
            // the plan is recorded. Steering toward "pick a different tool"
            // here (what `precondition_failed` and `tool_not_authorized` both
            // say) would send the model looking for a substitute that does not
            // exist, and it would never record the plan that unblocks it.
            let toolName = (dict?["tool"] as? String) ?? result.toolName
            let intro = (dict?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Tool '\(toolName)' becomes available once your plan is recorded."
            return "\(intro) Record your findings and numbered plan with update_scratchpad; "
                + "'\(toolName)' works on the next turn."

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
            // `old_text` didn't match the file's current content. Two common
            // causes: a transcription error in the anchor (a wrong character,
            // lost whitespace, `/` ↔ `\` slash confusion), or an anchor copied
            // from a PRE-EDIT read after the model's own edit changed the
            // region. A re-read always returns the file's CURRENT content in
            // full (the tag store performs no dedup — 2026-08-11), so it is the
            // reliable remedy and the guidance recommends it outright. Path
            // comes from args (handler envelope doesn't include it in details).
            let argsDict = JSONUtilities.parseJSONDictionary(result.argumentsJSON)
            let path = (argsDict?["path"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            let target = path.map { "'\($0)'" } ?? "the file"
            var guidance = "old_text not found in \(target). It must match the file's current content exactly, character for character — including whitespace, indentation, and slash direction (`/` vs `\\`). If you edited this file after reading it, your copy is stale — re-read the region first. Otherwise compare your old_text against the content you read and fix the transcription."
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
            let code = errorObj?["code"] as? String
            let codePrefix = code.map { "[\($0)] " } ?? ""
            // The recovery direction must match the code family. The pre-fix
            // fixed suffix always blamed arguments — actively misleading weaker
            // models on timeouts/denials where arguments are not the cause.
            let direction: String
            switch code {
            case "INVALID_ARGS":
                // Name the WHOLE contract, not just the first key that tripped. Handlers
                // throw on the first missing argument they read, so a call short three
                // arguments costs three round-trips of "Missing required argument: X" —
                // and the model is never told which of the ones it DID send arrived. The
                // schema is the authority; `result.argumentsJSON` is what actually landed.
                direction = "Fix the arguments and retry."
                    + Self.requiredArgumentsHint(
                        toolName: result.toolName, argumentsJSON: result.argumentsJSON)
            case let c? where c.hasSuffix("_TIMED_OUT") || c == "TIMEOUT":
                direction = "This may be transient — retry once; if it fails again, choose a different approach."
            case let c? where c.hasSuffix("_DENIED") || c == "tool_not_authorized":
                direction = "Do not retry this call — choose a different approach."
            default:
                direction = "If the message indicates bad arguments, fix them and retry; otherwise choose a different approach."
            }
            return "Tool '\(result.toolName)' failed: \(codePrefix)\(msg). \(direction)"
        }
    }

    /// " `edit_file` requires: new_text, old_text, path. Your call carried: new_text."
    /// — or "" when the tool has no schema here, or declares nothing required.
    ///
    /// A runtime failure envelope, not schema text: it ships once, on the call that
    /// already failed, so the instruction budget that keeps `ToolSchema.description`
    /// lean does not apply. What it buys is the difference between one corrective
    /// round-trip and one per missing argument.
    nonisolated static func requiredArgumentsHint(
        toolName: String, argumentsJSON: String
    ) -> String {
        guard let schema = ToolHandlerRegistry.allSchemas.first(where: { $0.name == toolName })
        else { return "" }
        let required = schema.parameters.required ?? []
        guard !required.isEmpty else { return "" }

        var hint = " `\(toolName)` requires: \(required.sorted().joined(separator: ", "))."
        if let carried = JSONUtilities.parseJSONDictionary(argumentsJSON), !carried.isEmpty {
            hint += " Your call carried: \(carried.keys.sorted().joined(separator: ", "))."
        } else {
            hint += " Your call carried no arguments."
        }
        return hint
    }
}
