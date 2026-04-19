import Foundation

/// Stateless service for generating a team from a task description via direct LLM call.
/// Does NOT create a task or run — invokes the Team Creator prompt directly and parses
/// the `create_team` tool call to construct a `Team`.
enum TeamGenerationService {

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
        systemPrompt: String? = nil
    ) async throws -> GeneratedTeamBuilder.BuildResult {
        let outcome = await generateWithDiagnostics(
            taskDescription: taskDescription, config: config, client: client,
            systemPrompt: systemPrompt
        )
        return try outcome.result.get()
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
        systemPrompt: String? = nil
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

        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: systemPrompt ?? Self.defaultSystemPrompt),
            ChatMessage(role: .user, content: """
                Task:
                \(taskDescription)

                Analyze this task and call create_team ONCE with the optimal team configuration.
                """),
        ]

        var toolAccumulator = ToolCallAccumulator()
        var fullContent = ""

        let stream = client.streamChat(
            config: config,
            messages: messages,
            tools: [CreateTeamTool.schema],
            session: nil,
            logger: nil,
            stepID: nil
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
        } catch {
            diagnostics.rawContent = fullContent
            diagnostics.elapsedSeconds = Date().timeIntervalSince(startedAt)
            return GenerationOutcome(result: .failure(error), diagnostics: diagnostics)
        }

        if firstContentTimedOut {
            diagnostics.rawContent = fullContent
            diagnostics.elapsedSeconds = Date().timeIntervalSince(startedAt)
            let seconds = firstContentDeadlineSeconds ?? 0
            return GenerationOutcome(
                result: .failure(GenerationError.invalidResponse(
                    "LLM produced no content or tool calls within \(Int(seconds))s — likely stuck in a reasoning loop."
                )),
                diagnostics: diagnostics
            )
        }

        diagnostics.rawContent = fullContent
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
                let build = try decodeTeamConfig(from: call.argumentsJSON)
                return GenerationOutcome(result: .success(build), diagnostics: diagnostics)
            } catch {
                lastError = error
            }
        }

        // 2. Harmony-format tool call.
        let harmony = HarmonyToolCallParser().extractAllToolCalls(from: fullContent)
        if let call = harmony.first(where: { $0.name == ToolNames.createTeam }) {
            diagnostics.parsingPath = .harmony
            diagnostics.lastArgumentsJSON = call.argumentsJSON
            do {
                let build = try decodeTeamConfig(from: call.argumentsJSON)
                return GenerationOutcome(result: .success(build), diagnostics: diagnostics)
            } catch {
                lastError = error
            }
        }

        // 3. Balanced JSON object scanned from the content — handles models that
        //    return JSON as prose instead of calling the tool.
        let cleanedContent = ModelTokenCleaner.clean(fullContent)
        if let json = extractJSONObject(from: cleanedContent) {
            diagnostics.parsingPath = .jsonExtract
            diagnostics.lastArgumentsJSON = json
            do {
                let build = try decodeTeamConfig(from: json)
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

    /// Fenced blocks are a stronger signal of intent than the first balanced object,
    /// since models often wrap JSON in explanatory prose.
    static func extractJSONObject(from text: String) -> String? {
        // Prefer the first ```json code block when present.
        if let fence = text.range(of: "```json", options: .caseInsensitive),
           let closing = text.range(of: "```", range: fence.upperBound..<text.endIndex) {
            let inner = String(text[fence.upperBound..<closing.lowerBound])
            if let obj = scanBalancedObject(in: inner) { return obj }
        }
        // Any ``` fenced block.
        if let fence = text.range(of: "```"),
           let afterFence = text.index(fence.upperBound, offsetBy: 0, limitedBy: text.endIndex),
           let closing = text.range(of: "```", range: afterFence..<text.endIndex) {
            let inner = String(text[afterFence..<closing.lowerBound])
            if let obj = scanBalancedObject(in: inner) { return obj }
        }
        // Raw scan.
        return scanBalancedObject(in: text)
    }

    /// Respects string boundaries and `\` escapes so braces inside string literals
    /// don't perturb the depth counter.
    ///
    /// **Truncation salvage**: when the scanner reaches EOF with an unbalanced open
    /// object (`0 < depth ≤ 3`) and we're not stuck mid-string, pad the result
    /// with synthetic closing braces. Motivated by LM Studio / gpt-oss-20b
    /// occasionally truncating the stream mid-envelope — e.g. 1013 chars ending
    /// at `…]}"}` with final depth 1 (missing the outer `}`). Depth cap mirrors
    /// the policy in `ToolCallParsingHelpers.extractJSONBracedValue`.
    private static let maxSalvageDepth = 3
    private static func scanBalancedObject(in text: String) -> String? {
        var depth = 0
        var startIndex: String.Index?
        var inString = false
        var isEscaped = false
        var lastCloseEnd: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if isEscaped { isEscaped = false; i = text.index(after: i); continue }
            if inString {
                if c == "\\" { isEscaped = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{":
                    if depth == 0 { startIndex = i }
                    depth += 1
                case "}":
                    depth -= 1
                    lastCloseEnd = text.index(after: i)
                    if depth == 0, let start = startIndex {
                        return String(text[start...i])
                    }
                default: break
                }
            }
            i = text.index(after: i)
        }
        // Salvage path: truncated stream with a shallow unbalanced open object.
        // Prefer the span up to the last observed `}` (dropping trailing junk),
        // then append synthetic closes.
        if !inString, let start = startIndex, depth > 0, depth <= maxSalvageDepth {
            let endIndex = lastCloseEnd ?? text.endIndex
            let body = String(text[start..<endIndex])
            return body + String(repeating: "}", count: depth)
        }
        return nil
    }

    static func decodeTeamConfig(from argumentsJSON: String) throws -> GeneratedTeamBuilder.BuildResult {
        // Strict parse first; if that fails AND the input contains a `team_config`
        // wrapper, extract the inner JSON by brace-depth (ignoring quote state)
        // and decode that directly. Handles gpt-oss-20b inconsistently escaping
        // interior quotes — e.g. `"tools\":["read_file","write_file"]` mixed with
        // properly-escaped neighbors — which corrupts the outer string boundary.
        let dict: [String: Any]
        if let parsed = JSONUtilities.parseJSONDictionary(argumentsJSON) {
            dict = parsed
        } else if let extracted = extractInnerTeamConfig(from: argumentsJSON),
                  let parsed = parseDictionaryStripping(extracted) {
            // Inner extraction path: skip wrapper unwrapping, treat as flat config.
            return try decodeFromConfigDict(parsed)
        } else {
            throw GenerationError.invalidResponse("Could not parse tool arguments as JSON")
        }

        // Accept multiple wrapper shapes the LLM may emit:
        //   1. `{team_config: {...}}`               — canonical nested form
        //   2. `{...}`                              — flat form
        //   3. `{create_team: {team_config: {...}}}` or `{create_team: {...}}` — tool-name wrapper
        //   4. `{name: "create_team", arguments: {team_config: {...}}}` — raw tool-call shape
        return try decodeFromConfigDict(Self.unwrapTeamConfig(dict))
    }

    private static func decodeFromConfigDict(_ configDict: [String: Any]) throws -> GeneratedTeamBuilder.BuildResult {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: configDict)
        } catch {
            throw GenerationError.invalidResponse(error.localizedDescription)
        }

        let decoder = JSONCoderFactory.makeWireDecoder()
        let config: GeneratedTeamConfig
        do {
            config = try decoder.decode(GeneratedTeamConfig.self, from: data)
        } catch {
            throw GenerationError.invalidResponse(error.localizedDescription)
        }

        return GeneratedTeamBuilder.build(from: config)
    }

    /// When the OUTER JSON parse fails because the LLM inconsistently escaped
    /// interior quotes inside the `team_config` string envelope, search for
    /// the literal substring `"team_config":"` and walk forward by **brace
    /// depth alone** (ignoring quote tracking) to find the inner JSON object.
    /// Then JSON-string-unescape the captured span.
    ///
    /// Why brace-depth-only: the model has corrupted quote semantics here, so
    /// we can't trust `inString`. The risk is over-counting if an inner string
    /// value contains a literal `{` or `}` (rare in team configs).
    static func extractInnerTeamConfig(from s: String) -> String? {
        // Two wrapper shapes are observed in failing payloads:
        //   `"team_config":"{…}"`  — string-encoded inner JSON (decode escapes after extraction)
        //   `"team_config":{…}`    — object-form (no escape decode needed)
        let stringForm = s.range(of: "\"team_config\":\"")
        let objectForm = s.range(of: "\"team_config\":{")
        let needsUnescape: Bool
        let searchAfter: String.Index
        if let r = stringForm, (objectForm == nil || r.lowerBound < objectForm!.lowerBound) {
            needsUnescape = true
            searchAfter = r.upperBound
        } else if let r = objectForm {
            needsUnescape = false
            searchAfter = r.lowerBound  // the `{` is part of this match
        } else {
            return nil
        }
        // Find the first `{` from searchAfter — start of inner JSON.
        var pos = searchAfter
        while pos < s.endIndex, s[pos] != "{" { pos = s.index(after: pos) }
        guard pos < s.endIndex else { return nil }
        let innerStart = pos
        var depth = 0
        while pos < s.endIndex {
            let c = s[pos]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let captured = String(s[innerStart...pos])
                    return needsUnescape ? reUnescapeInnerJSON(captured) : captured
                }
            }
            pos = s.index(after: pos)
        }
        return nil
    }

    /// Peels tool-call envelopes until we find the dict that looks like the
    /// team config (has top-level `name` + `roles`). Handles models that emit
    /// `<|call|>{"create_team":{...}}` or the full OpenAI tool-call shape
    /// `{"name":"create_team","arguments":{"team_config":{...}}}` as bare JSON.
    private static func unwrapTeamConfig(_ dict: [String: Any]) -> [String: Any] {
        // Raw tool-call shape: {name: "create_team", arguments: {...}}
        if let name = dict["name"] as? String,
           name == ToolNames.createTeam,
           let args = dict["arguments"] as? [String: Any] {
            return unwrapTeamConfig(args)
        }
        // Partial tool-call shape: {arguments: {...}} — some models emit the
        // arguments envelope without the `name` field (observed on gpt-oss-20b).
        // Only recurse if `team_config` is present inside — otherwise an
        // accidental top-level `arguments` key would swallow a real team config.
        if let args = dict["arguments"] as? [String: Any],
           args["team_config"] != nil {
            return unwrapTeamConfig(args)
        }
        // gpt-oss/Harmony: team_config is sometimes a JSON-encoded string
        // (e.g. `"team_config":"{\"name\":...}"`). Parse and recurse.
        // A subset of models (observed on gpt-oss-20b) additionally double-escape
        // the inner JSON — so after the outer parse the string still contains
        // literal `\n`, `\"`, `\t` escape sequences that must be unescaped once
        // more before the inner JSON becomes parseable.
        if let encoded = dict["team_config"] as? String {
            if let parsed = parseDictionaryStripping(encoded) {
                return unwrapTeamConfig(parsed)
            }
            // Some models doubly-escape the inner JSON; unescape once more.
            let reUnescaped = reUnescapeInnerJSON(encoded)
            if let parsed = parseDictionaryStripping(reUnescaped) {
                return unwrapTeamConfig(parsed)
            }
        }
        // Nested team_config
        if let nested = dict["team_config"] as? [String: Any] {
            return nested
        }
        // Single-key tool-name wrapper: {create_team: {...}}
        if let wrapped = dict[ToolNames.createTeam] as? [String: Any] {
            return unwrapTeamConfig(wrapped)
        }
        return dict
    }

    /// Tries to parse `s` as a JSON dictionary. Attempts, in order:
    ///   1. strict parse,
    ///   2. parse the first balanced `{...}` span (strips trailing junk like an
    ///      extra `}` the LLM appended after the legitimate close),
    ///   3. repair interior unescaped `"` inside string values and re-parse.
    /// Observed on gpt-oss-20b: role prompts routinely contain unescaped quotes
    /// (`"Produce a "Decision Memo" artifact."`) which terminate the string
    /// prematurely for `JSONSerialization`.
    private static func parseDictionaryStripping(_ s: String) -> [String: Any]? {
        if let parsed = JSONUtilities.parseJSONDictionary(s) { return parsed }
        if let trimmed = scanBalancedObject(in: s),
           let parsed = JSONUtilities.parseJSONDictionary(trimmed) {
            return parsed
        }
        let repaired = repairUnescapedInteriorQuotes(s)
        if let parsed = JSONUtilities.parseJSONDictionary(repaired) { return parsed }
        if let trimmed = scanBalancedObject(in: repaired),
           let parsed = JSONUtilities.parseJSONDictionary(trimmed) {
            return parsed
        }
        if let injected = repairMissingArrayClose(s),
           let parsed = JSONUtilities.parseJSONDictionary(injected) {
            return parsed
        }
        if let injected = repairMissingArrayClose(repaired),
           let parsed = JSONUtilities.parseJSONDictionary(injected) {
            return parsed
        }
        return nil
    }

    /// Repairs the `"string"}]` → `"string"]}]` pattern: some models drop the
    /// inner array's closing `]` and jump straight to the outer object-close
    /// `}` and array-close `]`. Insert the missing `]` between the string and
    /// the `}`.
    ///
    /// The substring `"}]` also appears LEGITIMATELY when closing an array of
    /// objects whose last field has a string value (`[{"a":"b"}]`). Blanket
    /// replacement corrupts those. Instead try replacing each `"}]` occurrence
    /// INDEPENDENTLY (leaving the others untouched) and return the first
    /// candidate that parses. This isolates the buggy site from valid sites.
    /// Returns `nil` if no candidate parses or the pattern is not present.
    static func repairMissingArrayClose(_ s: String) -> String? {
        var positions: [String.Index] = []
        var cursor = s.startIndex
        while cursor < s.endIndex,
              let match = s.range(of: "\"}]", range: cursor..<s.endIndex) {
            positions.append(match.lowerBound)
            cursor = match.upperBound
        }
        guard !positions.isEmpty else { return nil }
        for pos in positions {
            let end = s.index(pos, offsetBy: 3)
            let candidate = s.replacingCharacters(in: pos..<end, with: "\"]}]")
            if JSONUtilities.parseJSONDictionary(candidate) != nil { return candidate }
        }
        return nil
    }

    /// Escapes `"` characters that appear inside string values but shouldn't
    /// have closed the enclosing string. Heuristic: when we see `"` while
    /// `inString`, look ahead past whitespace. If the next non-whitespace char
    /// is a structural JSON token (`,`, `}`, `]`, `:`) or EOF, treat as a
    /// proper close. Otherwise, insert `\` before the quote to escape it.
    ///
    /// Motivation: gpt-oss-20b emits role prompts with raw interior quotes
    /// (`"Produce a "Decision Memo" artifact."`). Standard JSON parsing fails,
    /// but the intent is obvious and recoverable.
    static func repairUnescapedInteriorQuotes(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var inString = false
        var isEscaped = false
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if isEscaped {
                result.append(c)
                isEscaped = false
                i += 1
                continue
            }
            if inString {
                if c == "\\" {
                    result.append(c)
                    isEscaped = true
                    i += 1
                    continue
                }
                if c == "\"" {
                    // Lookahead past whitespace.
                    var j = i + 1
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                    let isProperClose = j >= chars.count || "},]:".contains(chars[j])
                    if isProperClose {
                        result.append(c)
                        inString = false
                    } else {
                        result.append("\\")
                        result.append(c)
                    }
                    i += 1
                    continue
                }
                result.append(c)
                i += 1
                continue
            }
            // Outside a string.
            if c == "\"" { inString = true }
            result.append(c)
            i += 1
        }
        return result
    }

    /// Applies one more round of JSON string unescaping to a value that has
    /// already been decoded from an outer JSON but still contains literal escape
    /// sequences (`\n`, `\"`, `\t`, `\r`, `\\`). Used to repair doubly-escaped
    /// nested JSON observed from models like gpt-oss-20b.
    ///
    /// Order matters: `\\` is replaced LAST so that an input `\\n` (which means
    /// the user actually wants a literal backslash followed by `n`) is preserved
    /// rather than being collapsed first into `\n` and then into a newline.
    static func reUnescapeInnerJSON(_ s: String) -> String {
        var result = s.replacingOccurrences(of: "\\\"", with: "\"")
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        result = result.replacingOccurrences(of: "\\t", with: "\t")
        result = result.replacingOccurrences(of: "\\r", with: "\r")
        result = result.replacingOccurrences(of: "\\/", with: "/")
        result = result.replacingOccurrences(of: "\\\\", with: "\\")
        return result
    }

    // MARK: - System Prompt

    /// Built-in default system prompt. Settings can read this to seed the
    /// custom-prompt editor.
    static let defaultSystemPrompt: String = """
        You are an expert team architect. Analyze the user's task and design the optimal team to execute it.

        YOU MUST CALL THE create_team TOOL with the complete team configuration. Do NOT reply with plain text, prose, or explanations. Your ONLY output is a single create_team tool call.

        HOW ROLES WORK:

        Every role falls into one of three types — this determines what the role does and how it finishes.

        **Producing roles** create specific deliverables called artifacts. A PM produces "Product Requirements," an Engineer produces "Engineering Notes." The role works autonomously — reading files, using tools, consulting teammates — and finishes automatically once all its artifacts are submitted via create_artifact. This is the most common role type.

        **Chat roles** don't produce artifacts — instead, they talk to the Supervisor via ask_supervisor. After reading upstream artifacts (or just the task description), the role enters an open-ended conversation loop. The role never finishes on its own — it keeps the conversation going until the Supervisor pauses or closes the task. To create a chat role: give it requires_artifacts but empty produces_artifacts, and set supervisor_requires to [] (empty). When a team has no required deliverables for the Supervisor, it runs in Chat mode.

        **Observer roles** have no artifacts at all — no produces_artifacts and no requires_artifacts. They sit in the team graph but don't run on their own. They come alive only when invited to team meetings, contributing their perspective to group discussions. Use observers for personality-driven debate teams.

        TEAM DESIGN PRINCIPLES:
        - Each producing role should have a clear responsibility and produce specific artifacts.
        - Artifact dependencies create the execution order — a role starts only when its required artifacts exist.
        - "Supervisor Task" is always produced by the Supervisor. Use it as the first dependency.
        - The last artifact(s) in the chain should be listed in supervisor_requires — the Supervisor reviews these.
        - If the task is interactive/conversational (no clear deliverables), make the final role a chat role with empty produces_artifacts and set supervisor_requires to [].
        - Give each role a detailed prompt explaining their specific responsibility for THIS task.
        - Assign appropriate tools to each role (read_file, write_file, edit_file, git_*, etc.).
        - Use ask_supervisor in toolIDs for roles that may need clarification from the user.
        - For coding roles (any language), include: read_file, read_lines, write_file, edit_file, delete_file, list_files, search, git_status, git_add, git_commit, update_scratchpad, ask_supervisor.
        - **`run_xcodebuild` and `run_xcodetests` are Apple-ecosystem ONLY** — include them ONLY when the task explicitly involves an Xcode project (iOS, macOS, watchOS, tvOS, Swift, Objective-C). DO NOT include them for Python, JavaScript/TypeScript, Node.js, Go, Rust, Java, .NET, Ruby, PHP, or other non-Apple stacks.
        - For review/planning/research/writing roles (no code production), include only read tools: read_file, read_lines, list_files, search, ask_supervisor, update_scratchpad. NO write_file, edit_file, delete_file, or git_*.
        - For chat/assistant roles, include: read_file, read_lines, write_file, edit_file, delete_file, list_files, search, update_scratchpad, ask_supervisor, analyze_image.
        - `analyze_image` ONLY for tasks that plausibly involve image content; otherwise omit it.
        - Git write tools come together: include `git_status` + `git_add` + `git_commit` as a set or omit all three. Don't ship `git_commit` without `git_add`.
        - Set supervisor_mode to "autonomous" for tasks that don't need interactive input, "manual" for creative/ambiguous tasks.
        - Roles can consult each other via ask_teammate — include it for roles that benefit from cross-role Q&A.
        - Roles can start team meetings via request_team_meeting — include it for collaborative decision-making.

        EXAMPLE — Producing team:
        ```json
        {
          "team_config": {
            "name": "API Development Team",
            "description": "Team for building a REST API with tests",
            "supervisor_mode": "autonomous",
            "acceptance_mode": "finalOnly",
            "roles": [
              {"name": "API Architect", "prompt": "Design the REST API structure.", "produces_artifacts": ["API Specification"], "requires_artifacts": ["Supervisor Task"], "tools": ["read_file", "list_files", "search", "update_scratchpad", "ask_supervisor"]},
              {"name": "Backend Developer", "prompt": "Implement the API.", "produces_artifacts": ["Implementation Notes", "Build Diagnostics"], "requires_artifacts": ["API Specification"], "tools": ["read_file", "write_file", "edit_file", "list_files", "search", "git_status", "git_add", "git_commit", "update_scratchpad", "ask_supervisor"]},
              {"name": "Code Reviewer", "prompt": "Review the implementation.", "produces_artifacts": ["Code Review"], "requires_artifacts": ["Implementation Notes"], "tools": ["read_file", "list_files", "search", "update_scratchpad", "ask_supervisor"]}
            ],
            "artifacts": [
              {"name": "API Specification", "description": "REST API endpoints"},
              {"name": "Implementation Notes", "description": "Implementation summary"},
              {"name": "Build Diagnostics", "description": "Build and test results"},
              {"name": "Code Review", "description": "Code review findings"}
            ],
            "supervisor_requires": ["Code Review"]
          }
        }
        ```

        EXAMPLE — Chat team (interactive assistant):
        ```json
        {
          "team_config": {
            "name": "Research Assistant",
            "description": "Interactive research assistant",
            "supervisor_mode": "manual",
            "roles": [
              {"name": "Researcher", "prompt": "Help the Supervisor. Use ask_supervisor for ALL communication.", "produces_artifacts": [], "requires_artifacts": ["Supervisor Task"], "tools": ["read_file", "list_files", "search", "write_file", "update_scratchpad", "ask_supervisor", "analyze_image"]}
            ],
            "artifacts": [],
            "supervisor_requires": []
          }
        }
        ```

        LANGUAGE:
        - Write role names, team name, team description, role prompts, and artifact names/descriptions in the SAME language as the user's task. If the task is in Russian, generate Russian content. Same for any other non-English language. Do not force-translate to English.

        CRITICAL:
        - Call create_team EXACTLY ONCE with the team_config JSON object.
        - Do NOT reply with any text, prose, or explanation — ONLY the tool call.
        - Do NOT call any other tools.
        - Emit strict, valid JSON: every key AND every string value must be wrapped in double quotes (e.g. `"supervisor_requires": []`, NOT `"supervisor_requires: []`). Verify all `"` pairs close before the tool call ends.
        """
}
