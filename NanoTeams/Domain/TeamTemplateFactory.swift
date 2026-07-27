import Foundation

/// Creates built-in Team instances from system templates.
/// Use `Team.defaultTeams` or `Team.default` as entry points — they delegate here.
nonisolated enum TeamTemplateFactory {

    // MARK: - Template Metadata

    /// Display metadata for the team template picker UI (NewTeamSheet).
    struct TeamTemplateMetadata: Identifiable {
        let id: String
        let name: String
        let icon: String
        let description: String
    }

    /// Ordered list of template metadata including the "Empty Team" entry.
    static let templateMetadata: [TeamTemplateMetadata] = [
        TeamTemplateMetadata(id: "empty", name: "Empty Team", icon: "plus.square.dashed", description: "Start with no roles or artifacts"),
        TeamTemplateMetadata(id: "codingAssistant", name: "Coding Assistant", icon: "curlybraces", description: "Interactive coding companion with files, git, and Xcode tools"),
        TeamTemplateMetadata(id: "codingAgent", name: "Coding Agent", icon: "wand.and.rays", description: "Hybrid coding agent: handles small edits directly, delegates complex work to teams"),
        TeamTemplateMetadata(id: "assistant", name: "Personal Assistant", icon: "bubble.left.and.text.bubble.right", description: "Interactive assistant for any task"),
        TeamTemplateMetadata(id: "faang", name: "FAANG Team", icon: "building.2", description: "Full product development pipeline"),
        TeamTemplateMetadata(id: "engineering", name: "Engineering Team", icon: "wrench.and.screwdriver", description: "Lean engineering pipeline"),
        TeamTemplateMetadata(id: "startup", name: "Startup", icon: "bolt", description: "Minimal team for rapid prototyping"),
        TeamTemplateMetadata(id: "questParty", name: "Quest Party", icon: "scroll", description: "Adventure creation and management"),
        TeamTemplateMetadata(id: "discussionClub", name: "Discussion Club", icon: "bubble.left.and.bubble.right", description: "Meeting-driven discussion"),
    ]

    // MARK: - Public API

    static var allTemplates: [Team] {
        [codingAssistant(), codingAgent(), assistant(), faang(), engineering(), startup(), questParty(), discussionClub()]
    }

    static func faang() -> Team {
        buildTeam(
            name: "FAANG Team",
            description: "Full product development pipeline with specialized roles for requirements, design, architecture, implementation, code review, SRE, and release management.",
            templateID: "faang",
            roleIDs: ["productManager", "uxResearcher", "uxDesigner", "techLead",
                      "softwareEngineer", "codeReviewer", "sre", "tpm"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName, "Product Requirements", "Research Report", "Design Spec",
                           "Implementation Plan", "Engineering Notes",
                           "Code Review Summary", "Production Readiness", "Production Readiness Summary", "Release Notes"],
            coordinatorIndex: 8,
            supervisorRequires: ["Release Notes"],
            supervisorMode: .autonomous
        )
    }

    static func engineering() -> Team {
        buildTeam(
            name: "Engineering Team",
            description: "Lean engineering pipeline: architecture, implementation, code review, and release management.",
            templateID: "engineering",
            roleIDs: ["techLead", "softwareEngineer", "codeReviewer", "tpm"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName,
                           "Implementation Plan", "Engineering Notes",
                           "Code Review Summary", "Release Notes"],
            coordinatorIndex: 4,
            supervisorRequires: ["Release Notes"],
            supervisorMode: .autonomous
        ) { roles in
            // TechLead depends on Supervisor Task directly (no PM in this team)
            roles[1].dependencies.requiredArtifacts = [SystemTemplates.supervisorTaskArtifactName]
            // SWE depends on Implementation Plan only
            roles[2].dependencies.requiredArtifacts = ["Implementation Plan"]
            // TPM depends on Code Review Summary only (no SRE in this team)
            roles[4].dependencies.requiredArtifacts = ["Code Review Summary"]
        }
    }

    static func startup() -> Team {
        buildTeam(
            name: "Startup",
            description: "Lean two-person team where the Supervisor provides direction and a Software Engineer handles all implementation.",
            templateID: "startup",
            roleIDs: ["softwareEngineer"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName, "Engineering Notes"],
            coordinatorIndex: 1,
            supervisorRequires: ["Engineering Notes"],
            supervisorCanBeInvited: true
        ) { roles in
            typealias TN = ToolNames
            // SWE depends on Supervisor Task directly and has no teammate tools
            roles[1].toolIDs = [
                TN.readFile, TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile,
                TN.listFiles, TN.search, TN.updateScratchpad,
                TN.gitAdd, TN.gitCommit,
                TN.runXcodebuild, TN.runXcodetests,
                TN.bash, TN.bashOutput,
                TN.askSupervisor,
            ]
            roles[1].dependencies.requiredArtifacts = [SystemTemplates.supervisorTaskArtifactName]
        }
    }

    static func questParty() -> Team {
        buildTeam(
            name: "Quest Party",
            description: "Single-player adventure team: specialists build a personalized world, characters, and encounters, then the Quest Master narrates an interactive story where the Supervisor plays the hero.",
            templateID: "questParty",
            roleIDs: ["loreMaster", "npcCreator", "encounterArchitect", "rulesArbiter", "questMaster"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName, "World Compendium", "NPC Compendium",
                           "Encounter Guide", "Balance Review"],
            coordinatorIndex: 5,
            supervisorRequires: [],
            supervisorCanBeInvited: true
        )
    }

    static func discussionClub() -> Team {
        buildTeam(
            name: "Discussion Club",
            description: "Lively discussion group where strong personalities engage, debate, and challenge each other in natural conversation.",
            templateID: "discussionClub",
            roleIDs: ["theAgreeable", "theOpen", "theConscientious", "theExtrovert", "theNeurotic"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName, "Discussion Summary"],
            coordinatorIndex: 1,
            supervisorRequires: ["Discussion Summary"],
            supervisorCanBeInvited: true,
            limits: .discussionClub,
            supervisorMode: .autonomous
        )
    }

    static func assistant() -> Team {
        buildTeam(
            name: "Personal Assistant",
            description: "One-on-one assistant that handles any task through interactive dialog — reading and writing documents, analyzing images, research, planning, and more.",
            templateID: "assistant",
            roleIDs: ["assistant"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName],
            coordinatorIndex: 1,
            supervisorRequires: [],
            supervisorCanBeInvited: true
        ) { roles in
            typealias TN = ToolNames
            // Document-focused: files (read + write) + scratchpad + supervisor + vision
            // + computer use (screen control — gated per-action by the permission layer).
            // NO git, xcode, or teammate tools
            roles[1].toolIDs = [
                TN.readFile, TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile,
                TN.listFiles, TN.search,
                TN.updateScratchpad,
                TN.askSupervisor, TN.analyzeImage,
                TN.screenCapture, TN.uiClick, TN.uiType, TN.uiKey, TN.uiScroll,
            ]
            roles[1].dependencies.requiredArtifacts = [SystemTemplates.supervisorTaskArtifactName]
        }
    }

    /// Coding Agent — hybrid coding agent that handles small edits directly and
    /// delegates complex implementation work to other teams via `delegate_to_team`.
    /// Default whitelist includes the built-in programming-focused teams except
    /// FAANG: Engineering and Startup. Generated teams are enabled by default so
    /// the agent can spawn a tailored team when no stored team is a good fit.
    static func codingAgent() -> Team {
        // Default delegation whitelist — IDs are deterministic via NTMSID.from(name:),
        // so we can refer to siblings before they're built.
        let engineeringID = NTMSID.from(name: "Engineering Team")
        let startupID = NTMSID.from(name: "Startup")

        return buildTeam(
            name: "Coding Agent",
            description: "Hybrid coding agent: edits files directly for small changes, delegates complex implementation to a chosen team.",
            templateID: "codingAgent",
            roleIDs: ["codingAgent"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName],
            coordinatorIndex: 1,
            supervisorRequires: [],
            supervisorCanBeInvited: true,
            supervisorMode: .manual
        ) { roles in
            roles[1].dependencies.requiredArtifacts = [SystemTemplates.supervisorTaskArtifactName]
            // Programming-focused teams except FAANG. Coding Assistant is chat-mode and
            // therefore filtered out at delegate time even if listed — omit for clarity.
            //
            // These two assignments together flip `hasDelegationConfigured` to true, which
            // (a) makes `buildSettings` skip the `reportsTo` wiring (peer-with-Supervisor),
            // and (b) makes `LLMExecutionService+ToolResolution` auto-inject the 4-tool
            // delegation pack into the LLM schema. The role's `toolIDs` does NOT contain
            // `delegate_to_team` — that's an auto-injected tool now (like `ask_supervisor`).
            roles[1].allowedDelegationTeamIDs = [engineeringID, startupID]
            roles[1].allowDelegationToGeneratedTeams = true
        }
    }

    static func codingAssistant() -> Team {
        buildTeam(
            name: "Coding Assistant",
            description: "One-on-one coding companion that reads, edits, and ships code via git + Xcode tools through interactive dialog.",
            templateID: "codingAssistant",
            roleIDs: ["codingAssistant"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName],
            coordinatorIndex: 1,
            supervisorRequires: [],
            supervisorCanBeInvited: true,
            supervisorMode: .manual
        ) { roles in
            typealias TN = ToolNames
            // Full coding kit: files (read + write) + search + scratchpad + git + xcode
            // + vision + computer use (gated per-action by the permission layer) + supervisor
            // NO teammate tools (single-role team has no consultations)
            roles[1].toolIDs = [
                TN.readFile, TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile,
                TN.listFiles, TN.search, TN.updateScratchpad,
                TN.gitStatus, TN.gitDiff, TN.gitLog, TN.gitBranchList,
                TN.gitAdd, TN.gitCommit, TN.gitCheckout, TN.gitBranch,
                TN.gitMerge, TN.gitPull, TN.gitStash,
                TN.runXcodebuild, TN.runXcodetests,
                TN.bash, TN.bashOutput,
                TN.askSupervisor, TN.analyzeImage,
                TN.screenCapture, TN.uiClick, TN.uiType, TN.uiKey, TN.uiScroll,
            ]
            roles[1].dependencies.requiredArtifacts = [SystemTemplates.supervisorTaskArtifactName]
        }
    }

    /// "Generated Team" — Supervisor-only placeholder. When a task is started with this
    /// template, the orchestrator triggers a background `create_team` generation (attributed
    /// to Supervisor, shown in activity feed like `analyze_image`). The resulting team is
    /// stored on `NTMSTask.generatedTeam` and takes over the run.
    static func generatedTeam() -> Team {
        buildTeam(
            name: "Generated Team",
            description: "AI assembles the optimal team from your task description.",
            templateID: "generated",
            roleIDs: [],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName],
            coordinatorIndex: 0,
            supervisorRequires: [],
            supervisorMode: .manual
        )
    }

    /// "Autovisor" — the per-folder automated Supervisor. A hidden singleton
    /// chat-mode team with one advisory `Manager` role, instantiated lazily by
    /// `ensureAutovisorTask` when the user enables the feature. NOT part of
    /// `allTemplates` / `templateMetadata` — it is infrastructure, not a user-pickable
    /// template, and is filtered out of every team picker (same as `"generated"`).
    ///
    /// MUST be `supervisorMode: .autonomous` + chat-mode (empty `supervisorRequires`)
    /// + advisory (role requires the Supervisor Task artifact) so the engine runs it
    /// and the flow-control backstops apply. A healthy pass ends at `wait_for_events`;
    /// `.autonomous` is what arms `noteNonProductiveTurn`, which parks a
    /// manager that stops calling tools instead of letting it spin forever.
    static func autovisor() -> Team {
        buildTeam(
            name: "Autovisor",
            description: "Autonomous per-folder Supervisor: watches all tasks, creates/runs/stops them, answers their questions, and maintains the folder's goal, memory, and shared context.",
            templateID: AutovisorConstants.teamTemplateID,
            roleIDs: ["autovisor"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName],
            // Auto coordinator (nil): the lone Manager role would be the only
            // possible coordinator anyway, and Auto reads correctly in the UI.
            coordinatorIndex: nil,
            supervisorRequires: [],
            supervisorCanBeInvited: true,
            supervisorMode: .autonomous
        ) { roles in
            // Advisory (not observer) so the engine executes the step; this is the
            // single line that makes the Manager run (see CLAUDE.md role completion types).
            roles[1].dependencies.requiredArtifacts = [SystemTemplates.supervisorTaskArtifactName]
        }
    }

    // MARK: - Shared Builder

    private static func buildTeam(
        name: String,
        description: String,
        templateID: String,
        roleIDs: [String],
        artifactNames: [String],
        coordinatorIndex: Int?,
        supervisorRequires: [String],
        supervisorCanBeInvited: Bool = false,
        limits: TeamLimits = .default,
        acceptanceMode: AcceptanceMode = .finalOnly,
        supervisorMode: SupervisorMode = .manual,
        customize: ((inout [TeamRoleDefinition]) -> Void)? = nil
    ) -> Team {
        let teamSeed = NTMSID.from(name: name)
        let supervisorTemplate = SystemTemplates.roles["supervisor"]!
        var roles = [SystemTemplates.createRole(from: supervisorTemplate, teamSeed: teamSeed)]
        roles += roleIDs.compactMap { id in
            SystemTemplates.roles[id].map { SystemTemplates.createRole(from: $0, teamSeed: teamSeed) }
        }
        roles[0].dependencies.requiredArtifacts = supervisorRequires
        customize?(&roles)

        let artifacts = artifactNames.compactMap { artifactName in
            SystemTemplates.artifacts[artifactName].map { SystemTemplates.createArtifact(from: $0, teamSeed: teamSeed) }
        }

        let config = SystemTemplates.templateConfigs[templateID]!

        return Team(
            id: NTMSID.from(name: name),
            name: name,
            description: description,
            templateID: templateID,
            systemPromptTemplate: config.system,
            consultationPromptTemplate: config.consultation,
            meetingPromptTemplate: config.meeting,
            roles: roles,
            artifacts: artifacts,
            settings: buildSettings(
                roles: roles,
                coordinatorIndex: coordinatorIndex,
                supervisorCanBeInvited: supervisorCanBeInvited,
                limits: limits,
                acceptanceMode: acceptanceMode,
                supervisorMode: supervisorMode
            ),
            graphLayout: TeamGraphLayout.autoLayout(for: roles)
        )
    }

    /// Builds TeamSettings from a role array, wiring up hierarchy and invitable roles.
    private static func buildSettings(
        roles: [TeamRoleDefinition],
        coordinatorIndex: Int?,
        supervisorCanBeInvited: Bool = false,
        limits: TeamLimits = .default,
        acceptanceMode: AcceptanceMode = .finalOnly,
        supervisorMode: SupervisorMode = .manual
    ) -> TeamSettings {
        let supervisorID = roles[0].id
        let nonSupervisorRoles = roles.filter { $0.id != supervisorID }
        let invitableRoles = Set(nonSupervisorRoles.map(\.id))

        // Auto-wire non-Supervisor roles to report to Supervisor — EXCEPT roles
        // configured for delegation (whitelist non-empty OR generated permission).
        // Those are peer-level with the human Supervisor by definition (only peer-
        // level roles may delegate; see `Team.roleIsTopLevelDelegator`). Skipping
        // the entry here is the single source of truth: delegation settings alone
        // decide peer status — no extra flag, no post-mutation. The toolset is
        // independent (delegation tools auto-inject from settings, not toolIDs).
        var reportsTo: [String: String] = [:]
        for role in nonSupervisorRoles where !role.hasDelegationConfigured {
            reportsTo[role.id] = supervisorID
        }

        return TeamSettings(
            hierarchy: TeamHierarchy(reportsTo: reportsTo),
            // nil coordinatorIndex → Auto mode (the meeting initiator coordinates).
            meetingCoordinatorRoleID: coordinatorIndex.map { roles[$0].id },
            invitableRoles: invitableRoles,
            supervisorCanBeInvited: supervisorCanBeInvited,
            limits: limits,
            defaultAcceptanceMode: acceptanceMode,
            supervisorMode: supervisorMode
        )
    }
}
