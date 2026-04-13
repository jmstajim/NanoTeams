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

    /// Generates a team by calling the LLM with the Team Creator prompt + user task description.
    /// Returns a `GeneratedTeamBuilder.BuildResult` (team + non-fatal warnings) ready
    /// to install on a task or append to `workFolder.teams`.
    static func generate(
        taskDescription: String,
        config: LLMConfig,
        client: any LLMClient = LLMClientRouter()
    ) async throws -> GeneratedTeamBuilder.BuildResult {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: Self.systemPrompt),
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

        for try await event in stream {
            fullContent += event.contentDelta
            if !event.toolCallDeltas.isEmpty {
                toolAccumulator.absorb(event.toolCallDeltas)
            }
        }

        // 1. Try resolved tool calls
        var resolvedToolCalls = toolAccumulator.finalize()
        // 2. Fall back to Harmony-format tool call parsing
        if resolvedToolCalls.isEmpty {
            resolvedToolCalls = HarmonyToolCallParser().extractAllToolCalls(from: fullContent)
        }

        if let call = resolvedToolCalls.first(where: { $0.name == ToolNames.createTeam }) {
            return try decodeTeamConfig(from: call.argumentsJSON)
        }

        // 3. Fall back to extracting a JSON object from the content (LLMs often
        //    return the config as plain JSON instead of calling the tool).
        let cleanedContent = ModelTokenCleaner.clean(fullContent)
        if let json = extractJSONObject(from: cleanedContent) {
            return try decodeTeamConfig(from: json)
        }

        throw GenerationError.noResponse
    }

    /// Handles ` ```json ` fenced blocks first, then any fenced block, then a raw scan.
    /// This order matters — models often emit explanatory prose around the JSON, so
    /// fenced blocks are a stronger signal of intent than the first balanced object found.
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
    private static func scanBalancedObject(in text: String) -> String? {
        var depth = 0
        var startIndex: String.Index?
        var inString = false
        var isEscaped = false
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
                    if depth == 0, let start = startIndex {
                        return String(text[start...i])
                    }
                default: break
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Extracted for testability — see the `extractJSONObject` fallback in
    /// `generate()` for how arguments arrive.
    static func decodeTeamConfig(from argumentsJSON: String) throws -> GeneratedTeamBuilder.BuildResult {
        guard let dict = JSONUtilities.parseJSONDictionary(argumentsJSON) else {
            throw GenerationError.invalidResponse("Could not parse tool arguments as JSON")
        }

        // Accept both nested ({team_config: {...}}) and flat ({...}) shapes.
        let configDict: [String: Any]
        if let nested = dict["team_config"] as? [String: Any] {
            configDict = nested
        } else {
            configDict = dict
        }

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

    // MARK: - System Prompt

    private static let systemPrompt: String = """
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
        - Assign appropriate tools to each role (read_file, write_file, edit_file, git_*, run_xcodebuild, etc.).
        - Use ask_supervisor in toolIDs for roles that may need clarification from the user.
        - For coding roles, include: read_file, read_lines, write_file, edit_file, delete_file, list_files, search, git_status, git_add, git_commit, run_xcodebuild, run_xcodetests, update_scratchpad, ask_supervisor.
        - For review/planning roles, include: read_file, read_lines, list_files, search, ask_supervisor, update_scratchpad.
        - For chat/assistant roles, include: read_file, read_lines, write_file, edit_file, delete_file, list_files, search, update_scratchpad, ask_supervisor, analyze_image.
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
              {"name": "Backend Developer", "prompt": "Implement the API.", "produces_artifacts": ["Implementation Notes", "Build Diagnostics"], "requires_artifacts": ["API Specification"], "tools": ["read_file", "write_file", "edit_file", "list_files", "search", "git_status", "git_add", "git_commit", "run_xcodebuild", "run_xcodetests", "update_scratchpad", "ask_supervisor"]},
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

        CRITICAL:
        - Call create_team EXACTLY ONCE with the team_config JSON object.
        - Do NOT reply with any text, prose, or explanation — ONLY the tool call.
        - Do NOT call any other tools.
        """
}
