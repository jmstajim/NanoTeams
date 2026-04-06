import Foundation

/// Tool schema resolution, effective config building, and pre-flight checks.
extension LLMExecutionService {

    // MARK: - Effective Config Resolution

    /// Builds the effective LLM config for a role, applying per-role overrides to the global config.
    static func buildEffectiveConfig(
        globalConfig: LLMConfig,
        roleOverride: LLMOverride?
    ) -> LLMConfig {
        guard let override = roleOverride, !override.isEmpty else {
            return globalConfig
        }

        return LLMConfig(
            provider: .lmStudio,
            baseURLString: override.baseURLString ?? globalConfig.baseURLString,
            modelName: override.modelName ?? globalConfig.modelName,
            maxTokens: override.maxTokens ?? globalConfig.maxTokens,
            temperature: override.temperature ?? globalConfig.temperature
        )
    }

    // MARK: - LLM Override Pre-flight

    /// Pre-flight check — verifies LM Studio server reachability before use.
    static func preflightCheck(
        effectiveConfig: LLMConfig,
        globalConfig: LLMConfig,
        stepID: String,
        service: LLMExecutionService,
        session: any NetworkSession = URLSession.shared
    ) async -> LLMConfig {
        // Check server reachability (5s timeout)
        do {
            guard let checkURL = URL(string: effectiveConfig.baseURLString)?
                .appendingPathComponent("v1/models") else {
                throw LLMClientError.invalidBaseURL(effectiveConfig.baseURLString)
            }
            var request = URLRequest(url: checkURL)
            request.timeoutInterval = 5
            let (_, response) = try await session.sessionData(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw LLMClientError.badHTTPStatus(
                    (response as? HTTPURLResponse)?.statusCode ?? 0, nil)
            }
            return effectiveConfig
        } catch {
            await service.appendLLMMessage(
                stepID: stepID, role: .system,
                content: "LLM server (\(effectiveConfig.baseURLString)) unavailable, using default.")
            return globalConfig
        }
    }

    // MARK: - Tool Definitions

    func toolSchemas(for role: Role, team: Team? = nil) -> [ToolSchema] {
        guard let delegate else { return [] }

        // 1. Find role definition from team or defaults
        let targetID = role.baseID
        let roleDefinition = team?.roles.first(where: { $0.id == targetID || $0.systemRoleID == targetID })

        // 2. Resolve Tool IDs
        let allowedIDs: Set<String>
        if let roleDefinition {
            allowedIDs = Set(roleDefinition.toolIDs)
        } else {
            // Fall back to defaults for built-in roles (only when no team role found)
            allowedIDs = SystemTemplates.fallbackToolIDs[role.baseID] ?? SystemTemplates.fallbackCustomRoleToolIDs
        }

        // 3. Filter all tools
        let allTools = ToolDefinitionRegistry.shared.allToolSchemas()
        var allowedTools = allTools.filter { toolDef in
            allowedIDs.contains(toolDef.name)
        }

        let tn = ToolNames.self

        // 3.1 Dynamic filtering based on project settings
        if let wf = delegate.snapshot?.workFolder, wf.settings.selectedScheme == nil {
            allowedTools.removeAll { $0.name == tn.runXcodebuild || $0.name == tn.runXcodetests }
        }

        // 3.2 Remove analyze_image if no vision model is configured
        if delegate.visionLLMConfig == nil {
            allowedTools.removeAll { $0.name == tn.analyzeImage }
        }

        // 4. Auto-inject ask_supervisor for non-producing, non-observer roles
        if let roleDefinition, roleDefinition.shouldAutoInjectAskSupervisor {
            if let supervisorTool = allTools.first(where: { $0.name == tn.askSupervisor }) {
                if !allowedTools.contains(where: { $0.name == tn.askSupervisor }) {
                    allowedTools.append(supervisorTool)
                }
            }
        }

        // 5. Auto-inject create_artifact for roles that produce artifacts
        if let roleDefinition,
           !roleDefinition.dependencies.producesArtifacts.isEmpty,
           !roleDefinition.isSupervisor {
            if let artifactTool = allTools.first(where: { $0.name == tn.createArtifact }) {
                if !allowedTools.contains(where: { $0.name == tn.createArtifact }) {
                    allowedTools.append(artifactTool)
                }
            }
        }

        return allowedTools
    }

    /// Removes blocked tools from schemas when no real work folder is open.
    static func filterForDefaultStorage(_ tools: [ToolSchema], isDefaultStorage: Bool) -> [ToolSchema] {
        guard isDefaultStorage else { return tools }
        let blocked = ToolHandlerRegistry.defaultStorageBlocked
        return tools.filter { !blocked.contains($0.name) }
    }
}
