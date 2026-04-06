import Foundation

// MARK: - Fallback Tool IDs (single source of truth)

extension SystemTemplates {

    private typealias TN = ToolNames

    private static let readOnlyTools: Set<String> = [
        TN.listFiles, TN.readFile, TN.readLines, TN.search,
    ]
    private static let memoryToolIDs: Set<String> = [
        TN.updateScratchpad,
    ]
    private static let fileWriteTools: Set<String> = [
        TN.writeFile, TN.editFile, TN.deleteFile,
    ]
    private static let engineerOnlyTools: Set<String> = [
        TN.writeFile, TN.deleteFile,
        TN.runXcodebuild, TN.runXcodetests,
        TN.gitStatus, TN.gitDiff, TN.gitLog, TN.gitBranchList,
        TN.gitCheckout, TN.gitBranch, TN.gitAdd, TN.gitCommit,
        TN.gitMerge, TN.gitPull, TN.gitStash,
    ]
    private static let teammateToolIDs: Set<String> = [
        TN.askTeammate, TN.requestTeamMeeting,
    ]
    private static let pmOnlyToolIDs: Set<String> = [
        TN.concludeMeeting,
    ]
    private static let changeRequestToolIDs: Set<String> = [
        TN.requestChanges,
    ]
    private static let visionToolIDs: Set<String> = [
        TN.analyzeImage,
    ]
    private static let supervisorToolIDs: Set<String> = [
        TN.askSupervisor,
    ]

    /// Fallback tool IDs for roles without a team configuration.
    /// Custom roles default to readOnlyTools + memoryToolIDs + teammateToolIDs.
    static let fallbackToolIDs: [String: Set<String>] = [
        "supervisor": [],
        "softwareEngineer": readOnlyTools.union(engineerOnlyTools).union(memoryToolIDs).union(teammateToolIDs).union(supervisorToolIDs).union(visionToolIDs),
        "productManager": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(pmOnlyToolIDs).union(supervisorToolIDs),
        "theAgreeable": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(pmOnlyToolIDs).union(supervisorToolIDs),
        "tpm": teammateToolIDs.union(changeRequestToolIDs).union(supervisorToolIDs),
        "techLead": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(supervisorToolIDs),
        "codeReviewer": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(changeRequestToolIDs).union(visionToolIDs).union(supervisorToolIDs),
        "sre": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(changeRequestToolIDs).union(supervisorToolIDs),
        "questMaster": readOnlyTools.union(teammateToolIDs).union(supervisorToolIDs),
        "uxDesigner": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(visionToolIDs).union(supervisorToolIDs),
        "uxResearcher": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(visionToolIDs).union(supervisorToolIDs),
        "loreMaster": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(supervisorToolIDs),
        "npcCreator": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(supervisorToolIDs),
        "encounterArchitect": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(supervisorToolIDs),
        "rulesArbiter": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(supervisorToolIDs),
        "theOpen": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(supervisorToolIDs),
        "theConscientious": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(supervisorToolIDs),
        "theExtrovert": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(supervisorToolIDs),
        "theNeurotic": readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(supervisorToolIDs),
        "assistant": readOnlyTools.union(fileWriteTools).union(memoryToolIDs).union(supervisorToolIDs).union(visionToolIDs),
    ]

    /// Default fallback tool IDs for roles not in the map (custom roles).
    static let fallbackCustomRoleToolIDs: Set<String> = readOnlyTools.union(memoryToolIDs).union(teammateToolIDs).union(supervisorToolIDs)
}
