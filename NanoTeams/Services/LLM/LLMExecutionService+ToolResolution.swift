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
            temperature: override.temperature ?? globalConfig.temperature,
            requestTimeoutSeconds: globalConfig.requestTimeoutSeconds
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

        // 1. Find role definition — findRole handles id, systemRoleID, and name (custom roles
        // created via Role.fromDefinition carry the role's name, not its id, in `.custom(id:)`).
        let roleDefinition = team?.findRole(byIdentifier: role.baseID)

        // 2. Resolve Tool IDs
        let allowedIDs: Set<String>
        if let roleDefinition {
            allowedIDs = Set(roleDefinition.toolIDs)
        } else {
            if let team {
                // Always-on so stale `systemRoleID` / id collisions surface in release logs,
                // not just DEBUG builds — otherwise the role silently runs with the wrong tools.
                print("[LLMExecutionService] WARNING: role \(role.baseID) not found in team "
                    + "'\(team.name)' — using fallback tool IDs")
            }
            // Fall back to defaults for built-in roles (only when no team role found)
            allowedIDs = SystemTemplates.fallbackToolIDs[role.baseID] ?? SystemTemplates.fallbackCustomRoleToolIDs
        }

        // 3. Filter all tools (and strip control-flow tools that have a dedicated invocation path)
        let allTools = ToolDefinitionRegistry.shared.allToolSchemas()
        let unavailable = ToolHandlerRegistry.unavailableToRoles
        var allowedTools = allTools.filter { toolDef in
            allowedIDs.contains(toolDef.name) && !unavailable.contains(toolDef.name)
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

        // 6. Auto-inject conclude_meeting for the team's Meeting Coordinator.
        // Previously granted ONLY via the `pmOnlyToolIDs` fallback path, which only fires
        // when `team?.findRole(byIdentifier:)` returns nil — never the case in production
        // FAANG / Discussion Club templates. Net effect: pre-fix, NO role in those teams
        // could call `conclude_meeting` at all. Now dispatched through team settings'
        // `meetingCoordinatorRoleID` (TPM in FAANG, theAgreeable in Discussion Club).
        if let roleDefinition, let team,
           let coordinatorID = team.settings.meetingCoordinatorRoleID,
           coordinatorID == roleDefinition.id {
            if let concludeTool = allTools.first(where: { $0.name == tn.concludeMeeting }) {
                if !allowedTools.contains(where: { $0.name == tn.concludeMeeting }) {
                    allowedTools.append(concludeTool)
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

    /// True when `<workFolderRoot>/.git` exists (dir or worktree/submodule file).
    /// Does not walk upward: git tools always run with `workFolderRoot` as `cwd`.
    static func isGitRepository(at workFolderRoot: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: workFolderRoot.appendingPathComponent(".git").path)
    }

    /// Strips git tools from schemas when the work folder isn't a git repository.
    /// `GitErrorClassifier.notARepositoryError` remains as a runtime fallback.
    static func filterForGitAvailability(
        _ tools: [ToolSchema],
        workFolderRoot: URL,
        fileManager: FileManager = .default
    ) -> [ToolSchema] {
        if isGitRepository(at: workFolderRoot, fileManager: fileManager) { return tools }
        let gitTools = ToolHandlerRegistry.gitReadTools.union(ToolHandlerRegistry.gitWriteTools)
        return tools.filter { !gitTools.contains($0.name) }
    }
}
