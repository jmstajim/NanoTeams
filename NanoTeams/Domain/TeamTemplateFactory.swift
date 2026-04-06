import Foundation

/// Creates built-in Team instances from system templates.
/// Use `Team.defaultTeams` or `Team.default` as entry points — they delegate here.
enum TeamTemplateFactory {

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
        TeamTemplateMetadata(id: "assistant", name: "Personal Assistant", icon: "bubble.left.and.text.bubble.right", description: "Interactive assistant for any task"),
        TeamTemplateMetadata(id: "faang", name: "FAANG Team", icon: "building.2", description: "Full product development pipeline"),
        TeamTemplateMetadata(id: "engineering", name: "Engineering Team", icon: "wrench.and.screwdriver.fill", description: "Lean engineering pipeline"),
        TeamTemplateMetadata(id: "startup", name: "Startup", icon: "bolt.fill", description: "Minimal team for rapid prototyping"),
        TeamTemplateMetadata(id: "questParty", name: "Quest Party", icon: "scroll.fill", description: "Adventure creation and management"),
        TeamTemplateMetadata(id: "discussionClub", name: "Discussion Club", icon: "bubble.left.and.bubble.right.fill", description: "Meeting-driven discussion"),
    ]

    // MARK: - Public API

    static var allTemplates: [Team] {
        [assistant(), faang(), engineering(), startup(), questParty(), discussionClub()]
    }

    static func faang() -> Team {
        buildTeam(
            name: "FAANG Team",
            description: "Full product development pipeline with specialized roles for requirements, design, architecture, implementation, code review, SRE, and release management.",
            templateID: "faang",
            roleIDs: ["productManager", "uxResearcher", "uxDesigner", "techLead",
                      "softwareEngineer", "codeReviewer", "sre", "tpm"],
            artifactNames: [SystemTemplates.supervisorTaskArtifactName, "Product Requirements", "Research Report", "Design Spec",
                           "Implementation Plan", "Engineering Notes", "Build Diagnostics",
                           "Code Review", "Code Review Summary", "Production Readiness", "Production Readiness Summary", "Release Notes"],
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
                           "Implementation Plan", "Engineering Notes", "Build Diagnostics",
                           "Code Review", "Code Review Summary", "Release Notes"],
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
            artifactNames: [SystemTemplates.supervisorTaskArtifactName, "Engineering Notes", "Build Diagnostics"],
            coordinatorIndex: 1,
            supervisorRequires: ["Engineering Notes", "Build Diagnostics"],
            supervisorCanBeInvited: true
        ) { roles in
            typealias TN = ToolNames
            // SWE depends on Supervisor Task directly and has no teammate tools
            roles[1].toolIDs = [
                TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile,
                TN.listFiles, TN.search, TN.updateScratchpad,
                TN.gitAdd, TN.gitCommit,
                TN.runXcodebuild, TN.runXcodetests,
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
            // NO git, xcode, or teammate tools
            roles[1].toolIDs = [
                TN.readFile, TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile,
                TN.listFiles, TN.search,
                TN.updateScratchpad,
                TN.askSupervisor, TN.analyzeImage,
            ]
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
        coordinatorIndex: Int,
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
        coordinatorIndex: Int,
        supervisorCanBeInvited: Bool = false,
        limits: TeamLimits = .default,
        acceptanceMode: AcceptanceMode = .finalOnly,
        supervisorMode: SupervisorMode = .manual
    ) -> TeamSettings {
        let supervisorID = roles[0].id
        let nonSupervisorRoles = roles.filter { $0.id != supervisorID }
        let invitableRoles = Set(nonSupervisorRoles.map(\.id))

        var reportsTo: [String: String] = [:]
        for role in nonSupervisorRoles {
            reportsTo[role.id] = supervisorID
        }

        return TeamSettings(
            hierarchy: TeamHierarchy(reportsTo: reportsTo),
            meetingCoordinatorRoleID: roles[coordinatorIndex].id,
            invitableRoles: invitableRoles,
            supervisorCanBeInvited: supervisorCanBeInvited,
            limits: limits,
            defaultAcceptanceMode: acceptanceMode,
            supervisorMode: supervisorMode
        )
    }
}
