import Foundation
@testable import NanoTeams

/// Renders the wire payload that production would send to LM Studio on the
/// FIRST `/api/v1/chat` request for a (team, role) pair — without LM Studio,
/// without running anything.
///
/// Reuses production assembly path (no parallel rendering logic):
///   1. `NTMSRepository.openOrCreateWorkFolder` to load the team catalog.
///   2. `LLMExecutionService.resolveToolSchemas` for the role's tool array
///      (the pure subset extracted out of the orchestrator-bound instance method).
///   3. `filterForDefaultStorage` + `filterForGitAvailability` to mirror
///      production's post-resolution tool strip (see `startStepExecution`).
///   4. `PromptBuilder.buildChatMessages` for system_prompt + initial input messages.
///   5. `NativeLMStudioClient.buildRequest` to fuse them into the actual
///      `NativeChatRequest` shape — same encoder, same field names, same
///      `system_prompt` += `## Tool Calling` preamble logic.
///
/// Output is a JSON envelope `{ "wire": {...}, "render_meta": {...} }`:
///   - `wire` is char-identical to a record's `.body` field in a real
///     `network_log.json` (same encoder + same builder).
///   - `render_meta` describes resolution choices and breaks out the tools
///     array for audit (production inlines tool schemas into `system_prompt`,
///     so `tools[]` doesn't appear at top level — `render_meta.tools`
///     surfaces them separately).
///
/// The envelope keeps `wire` structurally identical to what `--from-logs`
/// extracts as `.body` from a real `network_log.json`, so the two surfaces
/// can be diffed without filtering.
enum FirstPromptRenderer {

    enum RenderError: Error, CustomStringConvertible {
        case workfolderNotFound(String)
        case teamNotFound(searched: String, available: [String])
        case roleNotFound(team: String, searched: String, available: [String])
        case ambiguousTeam(searched: String, matches: [String])
        case ambiguousRole(team: String, searched: String, matches: [String])
        case generatedTeamNotRenderable(String)
        case internalInvariantViolation(String)

        var description: String {
            switch self {
            case .workfolderNotFound(let path):
                return "workfolder not found at \(path) (expected .nanoteams/internal/ inside)"
            case .teamNotFound(let searched, let available):
                return "team not found: '\(searched)' (available: \(available.joined(separator: ", ")))"
            case .roleNotFound(let team, let searched, let available):
                return "role '\(searched)' not found in team '\(team)' (available: \(available.joined(separator: ", ")))"
            case .ambiguousTeam(let searched, let matches):
                return "team name '\(searched)' matches \(matches.count) teams (\(matches.joined(separator: ", "))) — pass {\"id\": ...} instead"
            case .ambiguousRole(let team, let searched, let matches):
                return "role substring '\(searched)' matches \(matches.count) roles in team '\(team)' (\(matches.joined(separator: ", "))) — pass {\"id\": ...} instead"
            case .generatedTeamNotRenderable(let teamName):
                return """
                team '\(teamName)' uses the Generated Team placeholder; its real team is built by an LLM call at run time, so the first wire payload cannot be rendered offline. \
                Run the task once and use `./train_first_prompt.sh --from-logs` to extract the real wire payload from the resulting `network_log.json`.
                """
            case .internalInvariantViolation(let detail):
                return "internal invariant violated: \(detail) — please file a bug"
            }
        }
    }

    /// Runs one render pass per the config, writes JSON to `config.outputPath`.
    /// Returns the number of bytes written.
    @discardableResult
    @MainActor
    static func run(
        config: FirstPromptRendererConfig,
        fileManager: FileManager = .default
    ) throws -> Int {
        // 1. Load workfolder
        let workfolderURL = URL(fileURLWithPath: config.projectPath)
        guard fileManager.fileExists(atPath: workfolderURL.path) else {
            throw RenderError.workfolderNotFound(config.projectPath)
        }
        let repository = NTMSRepository(fileManager: fileManager)
        let snapshot = try repository.openOrCreateWorkFolder(at: workfolderURL)

        // 2. Resolve team
        let team = try resolveTeam(in: snapshot.projection.teams, target: config.target.team)
        // 2a. Generated Team placeholder cannot be rendered offline — the real
        //     team is materialised by `runTeamGeneration` at start-of-run.
        //     Rendering the placeholder would silently fabricate a wire payload
        //     that never actually ships.
        if team.templateID == "generated" {
            throw RenderError.generatedTeamNotRenderable(team.name)
        }
        // 3. Resolve role within team
        let roleDefinition = try resolveRole(in: team, target: config.target.role)

        // 4. Build synthetic execution context — the smallest NTMSTask / Run /
        //    Step quartet that PromptBuilder.buildChatMessages can consume.
        let role = Role.fromDefinition(roleDefinition)
        let step = StepExecution.make(for: roleDefinition)
        let run = Run(id: 0, steps: [step], teamID: team.id)
        let task = NTMSTask(
            id: 0,
            title: "render-only",
            supervisorTask: config.supervisorTaskBrief,
            runs: [run],
            preferredTeamID: team.id
        )

        // 5. Resolve tool schemas via the pure static subset — same logic
        //    `LLMExecutionService.toolSchemas` runs in production.
        let rawToolSchemas = LLMExecutionService.resolveToolSchemas(
            for: role,
            team: team,
            allTeams: snapshot.projection.teams,
            selectedScheme: config.selectedScheme,
            isVisionConfigured: config.resolvedVisionConfigured
        )

        // 5a. `URL ==` is the exact comparison `startStepExecution` uses;
        //     anything fancier here (path standardisation, case folding) would
        //     silently diverge from production's runtime classification.
        let isDefaultStorage = workfolderURL == NTMSOrchestrator.defaultStorageURL
        let toolSchemas = LLMExecutionService.filterForGitAvailability(
            LLMExecutionService.filterForDefaultStorage(
                rawToolSchemas,
                isDefaultStorage: isDefaultStorage
            ),
            workFolderRoot: workfolderURL,
            fileManager: fileManager
        )

        // 6. Build chat messages via the production PromptBuilder. No artifacts
        //    exist on first call, so artifactReader returns nil for everything.
        let promptContext = PromptBuilder.Context(
            task: task,
            step: step,
            stepIndex: 0,
            run: run,
            workFolder: snapshot.projection,
            artifactReader: { _ in nil },
            activeTeam: team,
            roleDefinition: roleDefinition,
            globalContext: config.resolvedGlobalContext
        )
        let messages = PromptBuilder.buildChatMessages(context: promptContext, tools: toolSchemas)

        // 7. Fuse into the actual NativeChatRequest via the production builder.
        //    `session: nil` = first stateless call → system_prompt is NOT
        //    omitted, tool schema section IS appended.
        let llmConfig = LLMConfig(
            provider: .lmStudio,
            baseURLString: LLMProvider.lmStudio.defaultBaseURL,
            modelName: config.resolvedModelName,
            maxTokens: config.resolvedMaxTokens,
            temperature: config.temperature
        )
        let wireRequest = NativeLMStudioClient.buildRequest(
            config: llmConfig,
            messages: messages,
            tools: toolSchemas,
            session: nil
        )

        // 8. Encode wire payload, wrap in `{wire, render_meta}` envelope, write
        //    out. Envelope keeps `wire` structurally identical to a real
        //    `network_log.json` record's `.body`, so audits can diff
        //    `--render`'s `wire` directly against `--from-logs`'s `wire`.
        let wireData = try JSONCoderFactory.makeWireEncoder().encode(wireRequest)
        guard let wireDict = try JSONSerialization.jsonObject(with: wireData) as? [String: Any] else {
            throw RenderError.internalInvariantViolation(
                "wire encode did not produce a JSON object"
            )
        }
        let renderMeta = try makeRenderMeta(
            team: team,
            roleDefinition: roleDefinition,
            toolSchemas: toolSchemas,
            wireDict: wireDict
        )
        let renderMetaData = try JSONCoderFactory.makeWireEncoder().encode(renderMeta)
        guard let renderMetaJSON = try JSONSerialization.jsonObject(with: renderMetaData) as? [String: Any] else {
            throw RenderError.internalInvariantViolation("render_meta encode did not produce a JSON object")
        }
        let envelope: [String: Any] = [
            "wire": wireDict,
            "render_meta": renderMetaJSON
        ]

        let outData = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let outURL = URL(fileURLWithPath: config.outputPath)
        try outData.write(to: outURL, options: .atomic)
        return outData.count
    }

    // MARK: - Resolution helpers

    private static func resolveTeam(in teams: [Team], target: TeamTarget) throws -> Team {
        switch target {
        case .id(let id):
            guard let team = teams.first(where: { $0.id == id }) else {
                throw RenderError.teamNotFound(searched: id, available: teams.map(\.name))
            }
            return team
        case .name(let name):
            let lower = name.lowercased()
            let matches = teams.filter { $0.name.lowercased() == lower }
            if matches.count == 1 { return matches[0] }
            if matches.isEmpty {
                throw RenderError.teamNotFound(searched: name, available: teams.map(\.name))
            }
            throw RenderError.ambiguousTeam(searched: name, matches: matches.map(\.name))
        }
    }

    private static func resolveRole(in team: Team, target: RoleTarget) throws -> TeamRoleDefinition {
        switch target {
        case .id(let id):
            if let role = team.findRole(byIdentifier: id) { return role }
            throw RenderError.roleNotFound(team: team.name, searched: id, available: team.roles.map(\.name))
        case .name(let name):
            // findRole handles formatted display names via the
            // systemRoleID / name / formatted-display-name fallback chain.
            if let role = team.findRole(byIdentifier: name) { return role }
            // Last-resort: case-insensitive substring on the role's display name.
            let lower = name.lowercased()
            let matches = team.roles.filter { $0.name.lowercased().contains(lower) }
            if matches.count == 1 { return matches[0] }
            if matches.isEmpty {
                throw RenderError.roleNotFound(team: team.name, searched: name, available: team.roles.map(\.name))
            }
            throw RenderError.ambiguousRole(team: team.name, searched: name, matches: matches.map(\.name))
        }
    }

    // MARK: - Render meta (typed audit envelope)

    /// Audit metadata emitted alongside the wire payload. Typed end-to-end so
    /// the renderer can't silently corrupt the audit on encode failure (would
    /// throw instead of fall back to `0` / empty dicts).
    struct RenderMeta: Codable {
        struct ToolAudit: Codable {
            let name: String
            let chars: Int
        }
        struct Sizes: Codable {
            let system_prompt_chars: Int
            let input_chars: Int
            let tools_count: Int
            let tools_total_chars: Int
        }
        let team_id: String
        let team_name: String
        let role_id: String
        let role_display_name: String
        let rendered_at: String
        let tools: [ToolAudit]
        let tool_schemas: [ToolSchema]
        let sizes: Sizes
    }

    private static func makeRenderMeta(
        team: Team,
        roleDefinition: TeamRoleDefinition,
        toolSchemas: [ToolSchema],
        wireDict: [String: Any]
    ) throws -> RenderMeta {
        let encoder = JSONCoderFactory.makeWireEncoder()
        // Per-tool char sizes for the audit's token-economy dimension. Each
        // tool is a `ToolSchema` (Codable since LLMTypes.swift §ToolSchema) —
        // encode failures bubble up rather than masquerading as a `0` char
        // entry that would silently distort the audit.
        let toolsAudit: [RenderMeta.ToolAudit] = try toolSchemas.map { tool in
            let encoded = try encoder.encode(tool)
            return RenderMeta.ToolAudit(name: tool.name, chars: encoded.count)
        }
        let systemPrompt = (wireDict["system_prompt"] as? String) ?? ""
        let inputChars: Int
        if let s = wireDict["input"] as? String {
            inputChars = s.count
        } else if let arr = wireDict["input"] as? [[String: Any]] {
            // Multimodal — text parts contribute by char count; image parts
            // contribute by base64 payload length (which is also the byte
            // cost on the wire). This keeps `input_chars` consistent with
            // what actually ships, not just the text we can see.
            inputChars = arr.reduce(into: 0) { acc, part in
                if let text = part["content"] as? String { acc += text.count }
                if let dataURL = part["data_url"] as? String { acc += dataURL.count }
            }
        } else {
            inputChars = 0
        }
        return RenderMeta(
            team_id: team.id,
            team_name: team.name,
            role_id: roleDefinition.id,
            role_display_name: roleDefinition.name,
            rendered_at: JSONCoderFactory.iso8601Formatter.string(from: Date()),
            tools: toolsAudit,
            tool_schemas: toolSchemas,
            sizes: RenderMeta.Sizes(
                system_prompt_chars: systemPrompt.count,
                input_chars: inputChars,
                tools_count: toolSchemas.count,
                tools_total_chars: toolsAudit.reduce(0) { $0 + $1.chars }
            )
        )
    }
}
