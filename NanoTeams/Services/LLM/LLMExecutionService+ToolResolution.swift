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
            // Override provider wins when set (the override URL may point at a
            // different provider's server); otherwise the global provider
            // flows through — hardcoding `.lmStudio` here would silently talk
            // the wrong wire format after a global provider switch.
            provider: override.provider ?? globalConfig.provider,
            baseURLString: override.baseURLString ?? globalConfig.baseURLString,
            modelName: override.modelName ?? globalConfig.modelName,
            // The override carries no sampling params (LM Studio owns those),
            // but the global value must survive — dropping it here would let a
            // URL-only override silently reset an explicitly-set temperature.
            temperature: globalConfig.temperature,
            requestTimeoutSeconds: globalConfig.requestTimeoutSeconds,
            // Same reason as the timeout above: a URL-only override must not silently
            // drop the residency hint and let the model evict mid-step.
            keepAliveSeconds: globalConfig.keepAliveSeconds
        )
    }

    // MARK: - LLM Override Pre-flight

    /// Pre-flight check — verifies LM Studio server reachability before use.
    /// On auth failure (401/403) the override is **kept** rather than silently
    /// falling back to the global config — that would mask "user enabled auth
    /// on this server but didn't add a token", which is the exact situation
    /// the user needs to know about. Transport / non-auth HTTP errors still
    /// fall back to the global config so the run isn't wedged by a momentarily
    /// unreachable override server.
    static func preflightCheck(
        effectiveConfig: LLMConfig,
        globalConfig: LLMConfig,
        stepID: String,
        taskID: Int,
        service: LLMExecutionService,
        session: any NetworkSession = URLSession.shared,
        resolver: any LLMTokenResolver = DefaultLLMTokenResolver()
    ) async -> LLMConfig {
        await preflightDecision(
            effectiveConfig: effectiveConfig,
            globalConfig: globalConfig,
            session: session,
            resolver: resolver,
            appendSystemMessage: { content in
                await service.appendLLMMessage(stepID: stepID, taskID: taskID, role: .system, content: content)
            }
        )
    }

    /// Pure decision-with-callback variant — tests inject a `NetworkSession`
    /// returning the desired status and capture the system messages via the
    /// closure. Not constructing a real `LLMExecutionService` keeps preflight
    /// tests independent of the orchestrator + repository scaffolding.
    static func preflightDecision(
        effectiveConfig: LLMConfig,
        globalConfig: LLMConfig,
        session: any NetworkSession,
        resolver: any LLMTokenResolver,
        appendSystemMessage: (String) async -> Void
    ) async -> LLMConfig {
        do {
            guard let checkURL = URL(string: effectiveConfig.baseURLString)?
                .appendingPathComponent(effectiveConfig.provider.reachabilityProbePath) else {
                throw LLMClientError.invalidBaseURL(effectiveConfig.baseURLString)
            }
            var request = URLRequest(url: checkURL)
            request.timeoutInterval = 5
            request.applyLMStudioBearer(baseURL: effectiveConfig.baseURLString, resolver: resolver)
            let (_, response) = try await session.sessionData(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LLMClientError.badHTTPStatus(0, nil)
            }
            if !(200..<300).contains(http.statusCode) {
                // 401/403: keep the override and let the LLM call surface the
                // auth failure. Falling back to global would hide the misconfig.
                if LLMAuthErrorClassifier.authFailureKind(status: http.statusCode) != nil {
                    await appendSystemMessage(
                        LLMAuthErrorClassifier.message(forStatus: http.statusCode, body: nil)
                    )
                    return effectiveConfig
                }
                throw LLMClientError.badHTTPStatus(http.statusCode, nil)
            }
            return effectiveConfig
        } catch let error as LLMClientError {
            // `invalidBaseURL` is not a transient transport failure — the
            // override URL itself is malformed. Falling back to the global
            // would mask the misconfig (every subsequent role-override
            // request would also fail). Keep the override and surface the
            // validation error so the user fixes the URL instead of
            // wondering why their override silently runs on the global.
            if case .invalidBaseURL = error {
                await appendSystemMessage(
                    "LLM override URL is invalid: \(effectiveConfig.baseURLString). "
                        + "Fix the URL in Settings → LLM or per-role override."
                )
                return effectiveConfig
            }
            await appendSystemMessage(
                "LLM server (\(effectiveConfig.baseURLString)) unavailable, using default."
            )
            return globalConfig
        } catch {
            await appendSystemMessage(
                "LLM server (\(effectiveConfig.baseURLString)) unavailable, using default."
            )
            return globalConfig
        }
    }

    // MARK: - Tool Definitions

    func toolSchemas(for role: Role, team: Team? = nil) -> [ToolSchema] {
        guard let env = toolResolutionEnvironment() else { return [] }
        // Schema-build is the earliest and most universal detection point for
        // an orphan-coordinator (`reportOrphanCoordinatorIfNeeded` throttles
        // per team so this is safe to call on every iteration). The meeting
        // entry-point in `+TeamMeeting.swift` calls it too — defense in depth.
        reportOrphanCoordinatorIfNeeded(team: team)
        return Self.resolveToolSchemas(
            for: role,
            team: team,
            allTeams: env.allTeams,
            selectedScheme: env.selectedScheme,
            isVisionConfigured: env.isVisionConfigured,
            isComputerUseEnabled: env.isComputerUseEnabled,
            autovisorAllowTeamGeneration: env.autovisorAllowTeamGeneration
        )
    }

    /// Definition-taking sibling. Prefer it wherever the caller already resolved
    /// the role — it skips the lossy `Role → findRole` hop that can bind a
    /// duplicated system role to its twin's toolset. See the static
    /// `resolveToolSchemas(forDefinition:…)` for the full rationale.
    func toolSchemas(forDefinition roleDefinition: TeamRoleDefinition, team: Team? = nil) -> [ToolSchema] {
        guard let env = toolResolutionEnvironment() else { return [] }
        reportOrphanCoordinatorIfNeeded(team: team)
        return Self.resolveToolSchemas(
            forDefinition: roleDefinition,
            team: team,
            allTeams: env.allTeams,
            selectedScheme: env.selectedScheme,
            isVisionConfigured: env.isVisionConfigured,
            isComputerUseEnabled: env.isComputerUseEnabled,
            autovisorAllowTeamGeneration: env.autovisorAllowTeamGeneration
        )
    }

    /// Delegate-sourced inputs shared by both `toolSchemas` shims — kept in one
    /// place so the two entry points can't drift on which environment they read.
    private func toolResolutionEnvironment() -> (
        allTeams: [Team],
        selectedScheme: String?,
        isVisionConfigured: Bool,
        isComputerUseEnabled: Bool,
        autovisorAllowTeamGeneration: Bool
    )? {
        guard let delegate else { return nil }
        return (
            allTeams: delegate.snapshot?.workFolder.teams ?? [],
            selectedScheme: delegate.snapshot?.workFolder.settings.selectedScheme,
            isVisionConfigured: delegate.visionLLMConfig != nil,
            isComputerUseEnabled: delegate.computerUsePolicy.isEnabled,
            autovisorAllowTeamGeneration: delegate.snapshot?.workFolder.settings.autovisorAllowTeamGeneration ?? true
        )
    }

    /// Pure subset of `toolSchemas` — orchestrator-free. Inputs are explicit
    /// instead of pulled from `delegate.snapshot`, so non-runtime callers
    /// (FirstPromptRenderer, future preview/audit tools) can reuse the same
    /// resolution logic without standing up an `LLMExecutionService` instance.
    /// The instance method above is a thin shim that fills the explicit
    /// parameters from the delegate's snapshot.
    ///
    /// `nonisolated` because the body touches no `@MainActor` state — all
    /// inputs are passed in explicitly, all callees (`Team`, `Role`,
    /// `ToolDefinitionRegistry.shared.allToolSchemas`, the per-role schema
    /// builders) are themselves `nonisolated`. Lets the renderer call it
    /// from a non-main-actor context.
    nonisolated static func resolveToolSchemas(
        for role: Role,
        team: Team?,
        allTeams: [Team] = [],
        selectedScheme: String? = nil,
        isVisionConfigured: Bool = false,
        isComputerUseEnabled: Bool = false,
        autovisorAllowTeamGeneration: Bool = true
    ) -> [ToolSchema] {
        // 1. Find role definition — findRole handles id, systemRoleID, and name (custom roles
        // created via Role.fromDefinition carry the role's name, not its id, in `.custom(id:)`).
        //
        // This lookup is LOSSY and callers holding a definition must NOT round-trip
        // through it — see the `forDefinition:` overload below.
        if let roleDefinition = team?.findRole(byIdentifier: role.baseID) {
            return resolveToolSchemas(
                forDefinition: roleDefinition,
                team: team,
                allTeams: allTeams,
                selectedScheme: selectedScheme,
                isVisionConfigured: isVisionConfigured,
                isComputerUseEnabled: isComputerUseEnabled,
                autovisorAllowTeamGeneration: autovisorAllowTeamGeneration
            )
        }

        if let team {
            // Always-on so stale `systemRoleID` / id collisions surface in release logs,
            // not just DEBUG builds — otherwise the role silently runs with the wrong tools.
            print("[LLMExecutionService] WARNING: role \(role.baseID) not found in team "
                + "'\(team.name)' — using fallback tool IDs")
        }
        // Fall back to defaults for built-in roles (only when no team role found)
        return resolveToolSchemasCore(
            allowedIDs: SystemTemplates.fallbackToolIDs[role.baseID] ?? SystemTemplates.fallbackCustomRoleToolIDs,
            roleDefinition: nil,
            isAutovisorManagerRole: role.baseID == AutovisorConstants.managerRoleSystemID,
            team: team,
            allTeams: allTeams,
            selectedScheme: selectedScheme,
            isVisionConfigured: isVisionConfigured,
            isComputerUseEnabled: isComputerUseEnabled,
            autovisorAllowTeamGeneration: autovisorAllowTeamGeneration
        )
    }

    /// Same resolution, entered with the role DEFINITION already in hand.
    ///
    /// Prefer this over the `Role`-taking overload whenever you have a
    /// `TeamRoleDefinition`. `Role.fromDefinition` collapses every role sharing a
    /// `systemRoleID` onto one enum case, and `Team.findRole` then returns the
    /// FIRST such role — so a `definition → Role → findRole` round-trip can hand
    /// back a *different* role's toolset, silently (the lookup succeeds, so the
    /// warning above never fires). One "Duplicate" click on a system role in the
    /// team editor reaches that state: `handleDuplicateRole` copies `systemRoleID`
    /// verbatim. Entering with the definition skips the lossy hop entirely.
    nonisolated static func resolveToolSchemas(
        forDefinition roleDefinition: TeamRoleDefinition,
        team: Team?,
        allTeams: [Team] = [],
        selectedScheme: String? = nil,
        isVisionConfigured: Bool = false,
        isComputerUseEnabled: Bool = false,
        autovisorAllowTeamGeneration: Bool = true
    ) -> [ToolSchema] {
        resolveToolSchemasCore(
            allowedIDs: Set(roleDefinition.toolIDs),
            roleDefinition: roleDefinition,
            // `fromDefinition` is the FORWARD direction (definition → enum) and is
            // deterministic; only the reverse lookup is lossy. Computing the step-8
            // arm this way keeps it byte-identical to what the `Role`-taking entry
            // point produced before this split.
            isAutovisorManagerRole: Role.fromDefinition(roleDefinition).baseID
                == AutovisorConstants.managerRoleSystemID,
            team: team,
            allTeams: allTeams,
            selectedScheme: selectedScheme,
            isVisionConfigured: isVisionConfigured,
            isComputerUseEnabled: isComputerUseEnabled,
            autovisorAllowTeamGeneration: autovisorAllowTeamGeneration
        )
    }

    /// Shared core of both entry points: everything from candidate-set assembly
    /// (step 3) through the Autovisor hard gate (step 8). `roleDefinition` is nil
    /// only on the fallback-IDs path, where no definition exists by construction.
    private nonisolated static func resolveToolSchemasCore(
        allowedIDs: Set<String>,
        roleDefinition: TeamRoleDefinition?,
        isAutovisorManagerRole: Bool,
        team: Team?,
        allTeams: [Team],
        selectedScheme: String?,
        isVisionConfigured: Bool,
        isComputerUseEnabled: Bool,
        autovisorAllowTeamGeneration: Bool
    ) -> [ToolSchema] {

        // 3. Build the candidate set from the LIVE handler registry — the
        // authoritative list of tools that actually have runnable handlers —
        // overlaid with any persisted user customizations (edited descriptions
        // in tools.json). Sourcing availability from the persisted snapshot
        // alone is unsafe: tools.json lags the bundled set until a version-bump
        // reconcile or explicit save runs, so a freshly added tool (e.g. the
        // Autovisor management tools) is absent from the snapshot and would
        // be silently dropped here — the model calls it and hits
        // `tool_not_authorized` even though its handler is registered and
        // runnable. The same gap silently drops the `ask_supervisor` /
        // `conclude_meeting` / delegation auto-injections below (all sourced
        // from `allTools`). Then strip control-flow tools that have a dedicated
        // invocation path.
        let persistedByName = Dictionary(
            ToolDefinitionRegistry.shared.allToolSchemas().map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let allTools = ToolHandlerRegistry.allSchemas.map { persistedByName[$0.name] ?? $0 }
        let unavailable = ToolHandlerRegistry.unavailableToRoles
        var allowedTools = allTools.filter { toolDef in
            allowedIDs.contains(toolDef.name) && !unavailable.contains(toolDef.name)
        }

        let tn = ToolNames.self

        // 3.0 Delegation tools (`delegate_to_team` + the 3 companions) NEVER come
        // from `toolIDs` — they auto-inject in step 7 from delegation settings.
        // Filter them out here defensively so any legacy `toolIDs` carrying them
        // (pre-migration boot, hand-edited JSON, mid-rewire test fixtures) doesn't
        // bypass the `delegationEnabled` gate. Legacy literal `"list_teams"` is
        // also stripped — the tool was removed (catalog now embeds inline in
        // `delegate_to_team`'s description), but stale `teams.json` may still
        // carry it.
        let delegationToolNames: Set<String> = [
            tn.delegateToTeam,
            tn.cancelDelegation, tn.resumeDelegation, tn.forwardToTeam,
            "list_teams",
        ]
        allowedTools.removeAll { delegationToolNames.contains($0.name) }

        // 3.1 Dynamic filtering based on project settings
        if selectedScheme == nil {
            allowedTools.removeAll { $0.name == tn.runXcodebuild || $0.name == tn.runXcodetests }
        }

        // 3.2 Remove analyze_image if no vision model is configured
        if !isVisionConfigured {
            allowedTools.removeAll { $0.name == tn.analyzeImage }
        }

        // 3.2-bis Remove the computer-use tools when the feature is off
        // (Settings → Computer Use → Approval = Off). The permission gate
        // denies every action at runtime anyway, but without this filter the
        // 5 schemas keep being advertised to the model on every iteration and
        // it burns turns getting denied. Default `false` — feature-off is the
        // safe default for orchestrator-free callers (preview/renderer pass
        // the real state explicitly).
        if !isComputerUseEnabled {
            let computerUse = ToolHandlerRegistry.computerUseTools
            allowedTools.removeAll { computerUse.contains($0.name) }
        }

        // 3.3 Autovisor: embed the team catalog inline in create_managed_task's
        // description (per-build, same pattern as delegate_to_team) so the manager knows
        // valid team_ids. Only the hidden Manager role carries create_managed_task.
        if let idx = allowedTools.firstIndex(where: { $0.name == tn.createManagedTask }) {
            allowedTools[idx] = CreateManagedTaskTool.buildSchema(
                allTeams: allTeams, allowGenerated: autovisorAllowTeamGeneration)
        }

        // 4. Auto-inject ask_supervisor for non-producing, non-observer roles —
        // EXCEPT the Autovisor. The manager IS the top Supervisor (no one to
        // escalate to); under autonomous mode its own ask_supervisor would just be
        // auto-answered in a self-loop. The human steers it by messaging it instead.
        if let roleDefinition, roleDefinition.shouldAutoInjectAskSupervisor,
           team?.templateID != AutovisorConstants.teamTemplateID {
            if let supervisorTool = allTools.first(where: { $0.name == tn.askSupervisor }) {
                if !allowedTools.contains(where: { $0.name == tn.askSupervisor }) {
                    allowedTools.append(supervisorTool)
                }
            }
        }

        // 5. Auto-inject create_artifact for roles that produce artifacts.
        // Schema is built per-role (`CreateArtifactTool.buildSchema`) so the
        // role's expected deliverables are inlined in the description AND
        // constrained on the `name` parameter as a JSON-schema enum — same
        // at-the-decision-point pattern as `delegate_to_team` (step 7). The
        // static schema is reserved for callers without role context.
        if let roleDefinition,
           !roleDefinition.dependencies.producesArtifacts.isEmpty,
           !roleDefinition.isSupervisor {
            if !allowedTools.contains(where: { $0.name == tn.createArtifact }) {
                allowedTools.append(CreateArtifactTool.buildSchema(role: roleDefinition))
            }
        }

        // 6. Auto-inject conclude_meeting for roles that can start meetings.
        // Coordinator mode (designated coordinator set & live): only the
        // named coordinator gets it. Auto mode (`nil` OR orphan designation):
        // every role with `request_team_meeting` gets it — under Auto, the
        // role that starts a meeting becomes its effective coordinator and
        // therefore needs to be able to close it. Orphan stored IDs (the
        // designated role was removed) are normalized to nil here so the
        // runtime self-heal in `effectiveCoordinator` matches the schema —
        // without this normalization no role got `conclude_meeting` despite
        // being able to start meetings.
        if let roleDefinition, let team,
           roleDefinition.toolIDs.contains(tn.requestTeamMeeting) {
            let coordID = DesignatedCoordinatorResolver.normalize(
                storedID: team.settings.meetingCoordinatorRoleID,
                // Supervisor is filtered so a stored Supervisor ID
                // self-heals to Auto-mode (symmetric with picker + runtime).
                availableIDs: team.roles.filter { !$0.isSupervisor }.map(\.id)
            )
            let shouldInject = coordID == nil || coordID == roleDefinition.id
            if shouldInject,
               let concludeTool = allTools.first(where: { $0.name == tn.concludeMeeting }),
               !allowedTools.contains(where: { $0.name == tn.concludeMeeting }) {
                allowedTools.append(concludeTool)
            }
        }

        // 7. Auto-inject the full 4-tool delegation pack when the role's
        // delegation is enabled — peer-level with Supervisor AND has at least
        // one configured target (whitelisted team OR generated permission).
        // Settings are the single source of truth — `toolIDs` no longer carries
        // `delegate_to_team`; the tool is delivered to the LLM only when usable.
        //
        // `delegate_to_team`'s schema is built per-role via
        // `DelegateToTeamTool.buildSchema(role:allTeams:)` so the team catalog
        // (filtered by `allowedDelegationTeamIDs`, with the `"generated"`
        // sentinel appended iff allowed) is embedded inline in the description.
        // This replaces the old `list_teams` discovery round-trip.
        //
        // The pack is mandatory as a unit:
        //   - `delegate_to_team` — the entry point (catalog inline in description)
        //   - `cancel_delegation` / `resume_delegation` / `forward_to_team` —
        //     pause-and-decide control plane needed when `delegate_to_team`
        //     returns with `status: "paused_by_supervisor"`. Without these
        //     companions the role can't react to a Supervisor interrupt
        //     during an in-flight delegation.
        if let roleDefinition, let team, team.delegationEnabled(for: roleDefinition) {
            // `delegationEnabled` only checks `hasDelegationConfigured` (i.e.
            // whitelist non-empty OR generated permission). It does NOT check
            // that whitelisted teams still EXIST in the catalog or are
            // delegatable (chat-mode teams are filtered). If every whitelisted
            // team has been deleted AND generated permission is off, injecting
            // the pack would give the LLM a tool it can never call successfully
            // — every invocation would hit `delegationDenied` at the handler
            // and the LLM has no signal that its catalog is empty. Skip the
            // entire pack in that case (companions are nonsensical without an
            // active delegation entry point). `TeamValidationService.noDelegationTargets`
            // already surfaces this configuration mistake at validation time;
            // this guard is the runtime defense.
            let allowedSet = Set(roleDefinition.allowedDelegationTeamIDs)
            let hasUsableTeam = allTeams.contains { allowedSet.contains($0.id) && !$0.isChatMode }
            let hasUsableTarget = hasUsableTeam || roleDefinition.allowDelegationToGeneratedTeams
            if hasUsableTarget {
                if !allowedTools.contains(where: { $0.name == tn.delegateToTeam }) {
                    allowedTools.append(DelegateToTeamTool.buildSchema(role: roleDefinition, allTeams: allTeams))
                }
                let companionPack = [
                    tn.cancelDelegation,
                    tn.resumeDelegation,
                    tn.forwardToTeam,
                ]
                for toolName in companionPack {
                    guard !allowedTools.contains(where: { $0.name == toolName }) else { continue }
                    guard let schema = allTools.first(where: { $0.name == toolName }) else { continue }
                    allowedTools.append(schema)
                }
            }
        }

        // 8. Autovisor hard gate: the manager IS the top Supervisor — ask_supervisor
        // must NEVER ship in its schema regardless of origin (planted stored toolIDs,
        // the roleDefinition-miss fallback, or any future auto-inject step). The
        // step-4 gate only refuses to ADD the tool; this strip is the structural
        // guarantee, mirroring the step-3.0 delegation strip. Keyed on BOTH the team
        // templateID and the role's builtin id so a stored team that lost its
        // templateID still strips (the builtin `.autovisor` survives via
        // `Role.fromDefinition`'s systemRoleID resolution), and `team == nil` is
        // covered by the role arm. Runtime rejection follows for free:
        // `allowedToolNames` in +ToolIteration derives from this schema set, so a
        // hallucinated call gets `tool_not_authorized` with NO signal — the
        // supervisorQuestion machinery (self-answer loop / un-wakeable park) can't
        // fire. Residual: team == nil AND a `.custom` role identity would still take
        // the generic custom fallback, but the manager's runtime step role is always
        // the builtin `.autovisor`, and with no team the step fails at the engine.
        if team?.templateID == AutovisorConstants.teamTemplateID || isAutovisorManagerRole {
            allowedTools.removeAll { $0.name == tn.askSupervisor }
        }

        return allowedTools
    }

    /// Removes blocked tools from schemas when no real work folder is open.
    /// `nonisolated`: pure filter, no MainActor state touched.
    nonisolated static func filterForDefaultStorage(_ tools: [ToolSchema], isDefaultStorage: Bool) -> [ToolSchema] {
        guard isDefaultStorage else { return tools }
        let blocked = ToolHandlerRegistry.defaultStorageBlocked
        return tools.filter { !blocked.contains($0.name) }
    }

    /// True when `<workFolderRoot>/.git` exists (dir or worktree/submodule file).
    /// Does not walk upward: git tools always run with `workFolderRoot` as `cwd`.
    nonisolated static func isGitRepository(at workFolderRoot: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: workFolderRoot.appendingPathComponent(".git").path)
    }

    /// Strips git tools from schemas when the work folder isn't a git repository.
    /// `GitErrorClassifier.notARepositoryError` remains as a runtime fallback.
    /// `nonisolated`: pure filter (FileManager `.git` read is documented as thread-safe).
    nonisolated static func filterForGitAvailability(
        _ tools: [ToolSchema],
        workFolderRoot: URL,
        fileManager: FileManager = .default
    ) -> [ToolSchema] {
        if isGitRepository(at: workFolderRoot, fileManager: fileManager) { return tools }
        let gitTools = ToolHandlerRegistry.gitReadTools.union(ToolHandlerRegistry.gitWriteTools)
        return tools.filter { !gitTools.contains($0.name) }
    }
}
