import Foundation

// MARK: - Role Templates

extension SystemTemplates {

    private typealias TN = ToolNames

    /// Factory helper — eliminates boilerplate in role template entries.
    /// Adding a new role = one `role(...)` call.
    private static func role(
        _ id: String,
        name: String,
        icon: String,
        toolIDs: [String] = [],
        usePlanningPhase: Bool = false,
        requires: [String] = [],
        produces: [String] = []
    ) -> (String, SystemRoleTemplate) {
        (id, SystemRoleTemplate(
            id: id,
            name: name,
            icon: icon,
            prompt: rolePrompts[id] ?? "",
            toolIDs: toolIDs,
            usePlanningPhase: usePlanningPhase,
            dependencies: RoleDependencies(
                requiredArtifacts: requires,
                producesArtifacts: produces
            )
        ))
    }

    /// All available system role templates.
    static let roles: [String: SystemRoleTemplate] = Dictionary(uniqueKeysWithValues: [
        // MARK: Software (FAANG / Startup)
        role("supervisor", name: "Supervisor", icon: "crown.fill",
             produces: [supervisorTaskArtifactName]),
        role("productManager", name: "Product Manager", icon: "doc.text.fill",
             toolIDs: [TN.readFile, TN.readLines, TN.listFiles, TN.search,
                       TN.updateScratchpad, TN.analyzeImage,
                       TN.askTeammate, TN.requestTeamMeeting, TN.askSupervisor],
             usePlanningPhase: true,
             requires: [supervisorTaskArtifactName], produces: ["Product Requirements"]),
        role("uxResearcher", name: "UX Researcher", icon: "person.2.fill",
             toolIDs: [TN.askTeammate, TN.requestTeamMeeting],
             usePlanningPhase: true,
             requires: [supervisorTaskArtifactName], produces: ["Research Report"]),
        role("uxDesigner", name: "UX Designer", icon: "paintbrush.pointed.fill",
             toolIDs: [TN.askTeammate, TN.requestTeamMeeting],
             usePlanningPhase: true,
             requires: ["Product Requirements", "Research Report"], produces: ["Design Spec"]),
        role("techLead", name: "Tech Lead", icon: "brain.head.profile",
             toolIDs: [TN.readFile, TN.readLines, TN.listFiles, TN.search,
                       TN.updateScratchpad, TN.analyzeImage,
                       TN.askTeammate, TN.requestTeamMeeting, TN.askSupervisor],
             usePlanningPhase: true,
             requires: [supervisorTaskArtifactName, "Product Requirements"], produces: ["Implementation Plan"]),
        role("softwareEngineer", name: "Software Engineer", icon: "hammer.fill",
             toolIDs: [TN.readFile, TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile,
                       TN.listFiles, TN.search, TN.updateScratchpad,
                       TN.gitAdd, TN.gitCommit,
                       TN.runXcodebuild, TN.runXcodetests,
                       TN.requestTeamMeeting, TN.askTeammate, TN.askSupervisor],
             usePlanningPhase: true,
             requires: ["Implementation Plan", "Design Spec"], produces: ["Engineering Notes", "Build Diagnostics"]),
        role("codeReviewer", name: "Code Reviewer", icon: "doc.text.magnifyingglass",
             toolIDs: [TN.readFile, TN.readLines, TN.listFiles, TN.search,
                       TN.gitDiff, TN.gitLog, TN.askTeammate,
                       TN.requestTeamMeeting, TN.updateScratchpad, TN.requestChanges],
             usePlanningPhase: true,
             requires: ["Implementation Plan", "Engineering Notes"], produces: ["Code Review", "Code Review Summary"]),
        role("sre", name: "SRE", icon: "shield.checkered",
             toolIDs: [TN.readFile, TN.readLines, TN.listFiles, TN.search,
                       TN.askTeammate, TN.requestTeamMeeting,
                       TN.updateScratchpad, TN.requestChanges],
             usePlanningPhase: true,
             requires: ["Engineering Notes"], produces: ["Production Readiness", "Production Readiness Summary"]),
        role("tpm", name: "TPM", icon: "checklist",
             toolIDs: [TN.readFile, TN.readLines, TN.listFiles, TN.search,
                       TN.updateScratchpad, TN.gitLog,
                       TN.askTeammate, TN.requestTeamMeeting, TN.requestChanges, TN.askSupervisor],
             usePlanningPhase: true,
             requires: ["Code Review Summary", "Production Readiness Summary"], produces: ["Release Notes"]),

        // MARK: Quest Party
        role("loreMaster", name: "Lore Master", icon: "book.fill",
             requires: [supervisorTaskArtifactName], produces: ["World Compendium"]),
        role("npcCreator", name: "NPC Creator", icon: "theatermasks.fill",
             requires: ["World Compendium"], produces: ["NPC Compendium"]),
        role("encounterArchitect", name: "Encounter Architect", icon: "map.fill",
             requires: ["World Compendium", "NPC Compendium"], produces: ["Encounter Guide"]),
        role("rulesArbiter", name: "Rules Arbiter", icon: "scalemass.fill",
             toolIDs: [TN.requestChanges],
             requires: ["NPC Compendium", "Encounter Guide"], produces: ["Balance Review"]),
        role("questMaster", name: "Quest Master", icon: "scroll.fill",
             toolIDs: [TN.askSupervisor],
             requires: ["World Compendium", "NPC Compendium", "Encounter Guide", "Balance Review"]),

        // MARK: Discussion Club
        role("theAgreeable", name: "The Agreeable", icon: "bubble.left.and.bubble.right.fill",
             toolIDs: [TN.requestTeamMeeting],
             requires: [supervisorTaskArtifactName], produces: ["Discussion Summary"]),
        role("theOpen",          name: "The Open",           icon: "lightbulb.fill"),
        role("theConscientious", name: "The Conscientious",  icon: "list.clipboard.fill"),
        role("theExtrovert",     name: "The Extrovert",      icon: "bolt.fill"),
        role("theNeurotic",      name: "The Neurotic",       icon: "exclamationmark.triangle.fill"),

        // MARK: Personal Assistant
        role("assistant", name: "Assistant", icon: "bubble.left.and.text.bubble.right",
             toolIDs: [TN.askSupervisor],
             requires: [supervisorTaskArtifactName]),

        // MARK: Coding Assistant
        role("codingAssistant", name: "Coding Assistant", icon: "curlybraces",
             toolIDs: [TN.readFile, TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile,
                       TN.listFiles, TN.search, TN.updateScratchpad,
                       TN.gitStatus, TN.gitDiff, TN.gitLog, TN.gitBranchList,
                       TN.gitAdd, TN.gitCommit, TN.gitCheckout, TN.gitBranch,
                       TN.gitMerge, TN.gitPull, TN.gitStash,
                       TN.runXcodebuild, TN.runXcodetests,
                       TN.askSupervisor, TN.analyzeImage],
             requires: [supervisorTaskArtifactName]),
    ])
}
