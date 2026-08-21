import Foundation

/// Stateless service for generating a team from a task description via direct LLM call.
/// Does NOT create a task or run — invokes the Team Creator prompt directly and parses
/// the `create_team` tool call (via `TeamConfigParser`) to construct a `Team`.
nonisolated enum TeamGenerationService {

    enum GenerationError: Error, LocalizedError {
        case noResponse
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .noResponse:
                return "AI did not return a team configuration. Try again or rephrase the task."
            case .invalidResponse(let msg):
                return "AI returned invalid team configuration: \(msg)"
            }
        }
    }

    /// Parsing path + raw content + token usage captured from one LLM attempt.
    struct GenerationDiagnostics {
        enum ParsingPath: String, Codable {
            /// Standard OpenAI-style streamed tool call.
            case toolCall = "tool_call"
            /// Harmony `<|channel|>commentary to=functions.create_team<|message|>{...}<|call|>`.
            case harmony
            /// Balanced-brace JSON object scanned out of plain text content.
            case jsonExtract = "json_extract"
            /// No tool call resolved and no JSON found.
            case none
        }

        var parsingPath: ParsingPath
        var rawContent: String
        /// `nil` when the provider didn't emit token usage; distinguishes "free request" from "0 tokens".
        var inputTokens: Int?
        var outputTokens: Int?
        var elapsedSeconds: Double
        /// The argument-JSON string that was passed to `decodeTeamConfig` on the last
        /// attempt — populated for trainer debugging so we can diff what the parser
        /// extracted vs. what the LLM actually emitted. Only the last attempt is kept.
        var lastArgumentsJSON: String?
    }

    /// Result + diagnostics. Never throws at the outcome level — parsing and stream
    /// failures land in `result.failure` while diagnostics still populate.
    struct GenerationOutcome {
        var result: Result<GeneratedTeamBuilder.BuildResult, Error>
        var diagnostics: GenerationDiagnostics
    }

    /// Generates a team by calling the LLM with the Team Creator prompt + user task description.
    /// Returns a `GeneratedTeamBuilder.BuildResult` (team + non-fatal warnings) ready
    /// to install on a task or append to `workFolder.teams`.
    static func generate(
        taskDescription: String,
        config: LLMConfig,
        client: any LLMClient = LLMClientRouter(),
        systemPrompt: String? = nil,
        logger: NetworkLogger? = nil,
        stepID: String? = nil
    ) async throws -> GeneratedTeamBuilder.BuildResult {
        let outcome = await generateWithDiagnostics(
            taskDescription: taskDescription, config: config, client: client,
            systemPrompt: systemPrompt,
            logger: logger, stepID: stepID
        )
        if case .success = outcome.result { return try outcome.result.get() }

        // ONE corrective retry. The failure class this exists for is a well-formed call
        // with one field wrong — `gemma-4-e4b` lost a whole milestone to a missing
        // `roles[].name`, with no retry and no nudge, while the role tool loop next door
        // has both. `describeDecodingError` already produces the exact sentence
        // (`Key not found: name at \`roles.Index 0\``); handing it back is usually
        // sufficient. Retry only when there is something to correct WITH: a transport
        // failure re-run verbatim would just pay the latency twice.
        //
        // Exactly one, never a loop — every caller blocks on this. The delegation path
        // (`handleDelegateToTeam`) is the one that hurts: a parent role's tool loop is
        // suspended for the whole duration.
        //
        // `lastArgumentsJSON != nil` IS the discriminator, and it is the only one needed:
        // it is set exactly on the three parse paths (`.toolCall` / `.harmony` /
        // `.jsonExtract`), each of which sets it BEFORE calling `decodeTeamConfig`, while
        // the transport `catch`, `firstContentTimedOut` and `noResponse` arms leave it nil.
        // An additional `!(error is GenerationError)` clause was tried and is WRONG — it
        // reads as "not a generation-layer error" but `decodeTeamConfig` wraps every one of
        // its throws in `GenerationError.invalidResponse`, so the two conditions are
        // mutually exclusive and the retry never ran (dead from the day it was written).
        guard case .failure(let error) = outcome.result,
              let attempted = outcome.diagnostics.lastArgumentsJSON
        else { return try outcome.result.get() }

        // Never spend a second request on a run the user already stopped. The guard above
        // can still be satisfied under cancellation (the cancel can land while the parse
        // cascade is running, after `lastArgumentsJSON` is set), and `pauseRun` cancelling
        // team generation is a routine action, not an edge case.
        if Task.isCancelled { throw CancellationError() }

        let retry = await generateWithDiagnostics(
            taskDescription: taskDescription, config: config, client: client,
            systemPrompt: systemPrompt,
            logger: logger, stepID: stepID,
            priorAttempt: (arguments: attempted,
                           reason: TeamConfigParser.describeDecodingError(error))
        )
        if case .success = retry.result { return try retry.result.get() }

        // A CANCELLATION during the retry is the user stopping the run, and it must reach
        // the caller intact — `runTeamGeneration` classifies it with `isCancellation` to
        // mark the step `.paused` and suppress the error banner. Reporting attempt 1's
        // parse error instead makes that read false, so a Pause during the (multi-second)
        // retry surfaced as "AI returned invalid team configuration" and the Autovisor was
        // told the generation "failed again". Before the retry existed there was a single
        // stream, so a cancellation always reached the classifier — this is the one way the
        // retry could regress behaviour, and it is the reason the arm below is not simply
        // `return try outcome.result.get()`.
        if case .failure(let retryError) = retry.result, isCancellation(retryError) {
            throw retryError
        }
        // Otherwise report the FIRST error: it describes the model's own config, whereas
        // the retry's may describe a different, less representative one.
        return try outcome.result.get()
    }

    /// True for `CancellationError` and for the `URLError.cancelled` that `URLSession`
    /// emits when its streaming task is cancelled mid-request.
    ///
    /// Shared with `NTMSOrchestrator.runTeamGeneration`'s failure arm — the two must agree,
    /// or a paused generation is marked `.failed` at one layer and `.paused` at the other.
    /// The rule itself belongs to cancellation, not to team generation, so it now lives in
    /// `CancellationClassifier`, where three other services that were getting it wrong can
    /// reach it. Kept as a forwarding alias: this name is the one the call sites read.
    static func isCancellation(_ error: Error) -> Bool {
        CancellationClassifier.isCancellation(error)
    }

    /// Diagnostics-emitting variant — never throws; failures surface via `outcome.result`.
    ///
    /// `firstContentDeadlineSeconds` bounds how long we wait for the FIRST piece
    /// of content or tool-call delta before assuming the model is stuck in a
    /// reasoning loop (some models emit thousands of `reasoning_content` tokens
    /// with empty `content` on open-ended prompts). Once any token of
    /// `content`/`tool_calls` arrives the deadline stops applying and the stream
    /// runs to completion. `nil` (default) disables the deadline entirely.
    static func generateWithDiagnostics(
        taskDescription: String,
        config: LLMConfig,
        client: any LLMClient = LLMClientRouter(),
        firstContentDeadlineSeconds: Double? = nil,
        systemPrompt: String? = nil,
        logger: NetworkLogger? = nil,
        stepID: String? = nil,
        priorAttempt: (arguments: String, reason: String)? = nil
    ) async -> GenerationOutcome {
        let startedAt = Date()
        var diagnostics = GenerationDiagnostics(
            parsingPath: .none,
            rawContent: "",
            inputTokens: nil,
            outputTokens: nil,
            elapsedSeconds: 0,
            lastArgumentsJSON: nil
        )

        var messages: [ChatMessage] = [
            ChatMessage(role: .system, content: systemPrompt ?? Self.defaultSystemPrompt),
            ChatMessage(role: .user, content: """
            Task:
            \(taskDescription)
            
            Analyze this task and call create_team ONCE with the optimal team configuration.
            """),
        ]
        if let priorAttempt {
            // Show the model its own payload back, then name the single defect. Anything
            // vaguer ("that failed, try again") reproduces the same config.
            messages.append(ChatMessage(role: .assistant, content: priorAttempt.arguments))
            messages.append(ChatMessage(role: .user, content: """
            That config was rejected: \(priorAttempt.reason)
            
            Call create_team once more. Keep everything that was fine and fix only that.
            """))
        }

        var toolAccumulator = ToolCallAccumulator()
        var fullContent = ""
        var fullReasoning = ""

        /// What the parse cascade below actually consumes, and what the diagnostics must
        /// therefore record. `prepare` only trims: `ModelTokenCleaner.clean` would strip the
        /// very `<|channel|>…<|call|>` envelope path 2 exists to read, and path 3 cleans for
        /// itself. Reading it at call time, so it sees whatever has streamed in so far.
        func parseSource() -> String {
            ModelReplyChannels.answer(
                content: fullContent,
                reasoning: fullReasoning,
                prepare: { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }

        // Wire `logger` + `stepID` through to the streaming call so the
        // request/response land in the per-task `network_log.json`. Pre-fix
        // the team-generation LLM call was invisible to operators — when the
        // model emits an unparseable `create_team` envelope, the only
        // surfaced signal was a generic `COMMAND_FAILED: Could not parse
        // tool arguments as JSON` with no payload to diagnose. Per
        // CORE_PRINCIPLES the program LEARNS from model behavior; that
        // requires recording the behavior in the first place. `roleName`
        // is fixed to "Team Generator" so the log row is attributable
        // separately from the delegating role's own calls.
        // prefix-cache-owner: registered by each caller — `+DelegateToTeam`,
        // `NTMSOrchestrator+TeamGeneration` and `TeamEditorView+Actions` note
        // `.oneShot("team generation")`.
        let stream = client.streamChat(
            config: config,
            messages: messages,
            tools: [CreateTeamTool.schema],
            logger: logger,
            stepID: stepID,
            roleName: "Team Generator"
        )

        var sawContent = false
        var firstContentTimedOut = false
        do {
            for try await event in stream {
                // Cooperative cancellation — lets `withTimeout` actually stop the request
                // instead of letting tokens stream into a discarded outcome.
                try Task.checkCancellation()
                if !event.contentDelta.isEmpty || !event.toolCallDeltas.isEmpty {
                    sawContent = true
                }
                fullContent += event.contentDelta
                // Collected but deliberately NOT counted towards `sawContent`: that guard
                // exists to catch a model stuck emitting reasoning and nothing else, so
                // feeding this channel into it would disable the one detector aimed at it.
                fullReasoning += event.thinkingDelta
                if !event.toolCallDeltas.isEmpty {
                    toolAccumulator.absorb(event.toolCallDeltas)
                }
                if let usage = event.tokenUsage {
                    diagnostics.inputTokens = usage.inputTokens
                    diagnostics.outputTokens = usage.outputTokens
                }
                if !sawContent,
                   let deadline = firstContentDeadlineSeconds,
                   Date().timeIntervalSince(startedAt) > deadline
                {
                    firstContentTimedOut = true
                    break
                }
            }
            // The in-loop `checkCancellation` only fires when ANOTHER event is delivered,
            // so a stream that ends right after the cancel lands falls through here. Without
            // this guard the parse cascade below runs on a truncated payload:
            // `ToolCallAccumulator.finalize` returns a call for any non-empty NAME regardless
            // of whether its arguments are complete JSON, so a cancelled run would set
            // `lastArgumentsJSON`, throw a parse error, and be reported to the user as a bad
            // config for an action they took themselves. Mirrors the role-step streaming
            // path, which carries the same post-loop guard beside its in-loop one.
            try Task.checkCancellation()
        } catch {
            diagnostics.rawContent = parseSource()
            diagnostics.elapsedSeconds = Date().timeIntervalSince(startedAt)
            return GenerationOutcome(result: .failure(error), diagnostics: diagnostics)
        }

        if firstContentTimedOut {
            diagnostics.rawContent = parseSource()
            diagnostics.elapsedSeconds = Date().timeIntervalSince(startedAt)
            let seconds = firstContentDeadlineSeconds ?? 0
            return GenerationOutcome(
                result: .failure(GenerationError.invalidResponse(
                    "LLM produced no content or tool calls within \(Int(seconds))s — likely stuck in a reasoning loop."
                )),
                diagnostics: diagnostics
            )
        }

        diagnostics.rawContent = parseSource()
        diagnostics.elapsedSeconds = Date().timeIntervalSince(startedAt)

        // Cascade through all three parsing paths. A path that extracts an arguments
        // string but fails to decode (e.g. Harmony grabs a partial envelope for a model
        // that emits the full config in the content stream) should not block the next
        // path from attempting its own decode — only the FINAL path's error is surfaced.
        var lastError: Error?

        // 1. Resolved OpenAI-style tool calls.
        let resolved = toolAccumulator.finalize()
        if let call = resolved.first(where: { $0.name == ToolNames.createTeam }) {
            diagnostics.parsingPath = .toolCall
            diagnostics.lastArgumentsJSON = call.argumentsJSON
            do {
                let build = try TeamConfigParser.decodeTeamConfig(from: call.argumentsJSON)
                return GenerationOutcome(result: .success(build), diagnostics: diagnostics)
            } catch {
                lastError = error
            }
        }

        // 2. Harmony-format tool call.
        let harmony = HarmonyToolCallParser().extractAllToolCalls(from: parseSource())
        if let call = harmony.first(where: { $0.name == ToolNames.createTeam }) {
            diagnostics.parsingPath = .harmony
            diagnostics.lastArgumentsJSON = call.argumentsJSON
            do {
                let build = try TeamConfigParser.decodeTeamConfig(from: call.argumentsJSON)
                return GenerationOutcome(result: .success(build), diagnostics: diagnostics)
            } catch {
                lastError = error
            }
        }

        // 3. Balanced JSON object scanned from the content — handles models that
        //    return JSON as prose instead of calling the tool.
        let cleanedContent = ModelTokenCleaner.clean(parseSource())
        if let json = TeamConfigParser.extractJSONObject(from: cleanedContent) {
            diagnostics.parsingPath = .jsonExtract
            diagnostics.lastArgumentsJSON = json
            do {
                let build = try TeamConfigParser.decodeTeamConfig(from: json)
                return GenerationOutcome(result: .success(build), diagnostics: diagnostics)
            } catch {
                lastError = error
            }
        }

        if let err = lastError {
            return GenerationOutcome(result: .failure(err), diagnostics: diagnostics)
        }
        return GenerationOutcome(
            result: .failure(GenerationError.noResponse), diagnostics: diagnostics
        )
    }

    // MARK: - System Prompt

    /// Built-in default system prompt. Settings can read this to seed the
    /// custom-prompt editor.
    static let defaultSystemPrompt: String = """
    You design teams of LLM-driven roles to execute the user's task. Call `create_team` ONCE with a `team_config` matching the schema.
    
    ## Role types
    - **Producing** — has `produces_artifacts`; auto-finishes when all artifacts are submitted via create_artifact.
    - **Chat** — has `requires_artifacts` only, empty `produces_artifacts`; talks via ask_supervisor until paused. A team with empty `supervisor_requires` runs in Chat mode.
    - **Observer** — no artifacts; speaks only in meetings. Use for personality-driven debate teams.
    
    ## Role object
    Every role needs `name` AND `prompt` — both required, no defaults:
    `{"name":"Backend Engineer","prompt":"…","tools":["read_file","write_file"],"requires_artifacts":["Supervisor Task"],"produces_artifacts":["API Specification"]}`
    
    ## Design rules
    - `Supervisor Task` is always the first dependency. The Supervisor produces it automatically.
    - The final deliverable(s) go into `supervisor_requires` for review — list them there even when a review role also requires them. Use `supervisor_requires: []` only for open-ended dialogue with no requested deliverable (Chat mode).
    - Artifact names are conceptual deliverables (`API Specification`, `Deployment Runbook`), never file names (`server.js`, `convert.py`, `overview.json`) — the runtime rejects file-shaped names and degrades them to a generic label. Roles still write the real source files with write_file.
    - Give every role a detailed `prompt` for THIS task and tools matching its responsibility.
    - Include `ask_supervisor` for roles that may need clarification.
    - Add `ask_teammate` / `request_team_meeting` for roles that benefit from collaboration.
    - `supervisor_mode`: `autonomous` or `manual`. `autonomous` for clear specs, `manual` for creative/ambiguous tasks.
    - `acceptance_mode`: `finalOnly` (default — Supervisor reviews only the final deliverable), `afterEachRole`, or `afterEachArtifact`. Use exact enum values — `manual`/`autonomous` are NOT valid here.
    
    ## Tool selection
    | Task type                              | Mandatory tools per producing role                                          |
    |----------------------------------------|------------------------------------------------------------------------------|
    | Modifies on-disk files (any language)  | write_file + edit_file + read_file + list_files + search                    |
    | Apple-ecosystem (Swift / Xcode / iOS / macOS / watchOS / tvOS / visionOS / UIKit / AppKit / SwiftUI / XCTest / .xcodeproj) | also add run_xcodebuild + run_xcodetests on at least one role |
    | Review / plan / research / writing     | read_file + read_lines + list_files + search + ask_supervisor + update_scratchpad — NO writers, NO git |
    | Chat / assistant                       | read_file + write_file + edit_file + list_files + search + update_scratchpad + ask_supervisor + analyze_image |
    
    The writer rule triggers on any request to change files, in any language (e.g. "fix", "implement", "переписать") — such roles need write_file to produce their output.
    
    The Xcode row applies to any work on Apple-ecosystem code (the technologies listed in its table row); every other stack ships without Xcode tools.
    
    Git write tools come as a set: `git_status + git_add + git_commit` together or omit all three.
    Add `analyze_image` only when the task plausibly involves image content.
    
    ## Language
    Write role names, team name, team description, role prompts, and artifact names in the SAME language as the user's task. No force-translation to English.
    
    ## Output
    Call `create_team` exactly once with the full config — no prose, no other tool calls. The payload is strict valid JSON.
    
    ## Final reminder
    Use exact enum values: `supervisor_mode` ∈ {`autonomous`, `manual`}, `acceptance_mode` ∈ {`finalOnly`, `afterEachRole`, `afterEachArtifact`}. One `create_team` tool call, strict valid JSON.
    """
}
