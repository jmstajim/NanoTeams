import Foundation

/// Tool runtime limits and UI display categories.
/// Tool name string constants live in the top-level `ToolNames` enum.
nonisolated enum ToolConstants {
    /// Maximum directory entries returned by `list_files` tool.
    static let maxDirectoryEntries = 1000

    // MARK: - Display Categories

    /// Ordered tool category with display metadata for UI (ToolSelectionView).
    struct ToolCategoryDisplay: Identifiable {
        let id: String
        let name: String
        let icon: String
        let tools: [String]
    }

    private typealias TN = ToolNames

    /// Ordered list of tool categories with display names and icons.
    static let displayCategories: [ToolCategoryDisplay] = [
        ToolCategoryDisplay(id: "filesystem", name: "File System", icon: "folder",
                            tools: [TN.readFile, TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile, TN.listFiles, TN.search]),
        ToolCategoryDisplay(id: "git", name: "Git", icon: "arrow.triangle.branch",
                            tools: [TN.gitStatus, TN.gitAdd, TN.gitCommit, TN.gitPull, TN.gitBranchList,
                                    TN.gitCheckout, TN.gitMerge, TN.gitLog, TN.gitDiff, TN.gitStash, TN.gitBranch]),
        ToolCategoryDisplay(id: "build", name: "Build", icon: "hammer",
                            tools: [TN.runXcodebuild, TN.runXcodetests]),
        // conclude_meeting is auto-injected for the Meeting Coordinator (see `toolSchemas`)
        // and shown in the Auto-injected UI section — not manually selectable.
        ToolCategoryDisplay(id: "collaboration", name: "Collaboration", icon: "bubble.left.and.bubble.right",
                            tools: [TN.askTeammate, TN.requestTeamMeeting, TN.requestChanges]),
        ToolCategoryDisplay(id: "memory", name: "Memory", icon: "brain.head.profile",
                            tools: [TN.updateScratchpad]),
        ToolCategoryDisplay(id: "supervisor", name: "Supervisor", icon: "crown",
                            tools: [TN.askSupervisor]),
        ToolCategoryDisplay(id: "vision", name: "Vision", icon: "eye",
                            tools: [TN.analyzeImage]),
        // Shell tools are granted by default to the code-writing roles (Software
        // Engineer, Coding Assistant, Coding Agent) and opt-in for everyone else;
        // execution is gated by the bash-permission layer (Settings → Bash).
        // Granting them lets a role run arbitrary shell commands subject to that policy.
        ToolCategoryDisplay(id: "shell", name: "Shell", icon: "terminal",
                            tools: [TN.bash, TN.bashOutput]),
        // Computer-use tools (screenshot + mouse/keyboard control of the desktop).
        // Default-OFF for every role; opt-in per role. Execution is gated by the
        // computer-use permission layer (Settings → Computer Use). Requires a
        // vision-capable main model for the screenshot to be useful.
        ToolCategoryDisplay(id: "computerUse", name: "Computer Use", icon: "cursorarrow.rays",
                            tools: [TN.screenCapture, TN.uiClick, TN.uiType, TN.uiKey, TN.uiScroll]),
        // Delegation tools (delegate_to_team + 3 companions) are NEVER manually
        // selectable — they auto-inject when the role's delegation settings
        // (`allowedDelegationTeamIDs` / `allowDelegationToGeneratedTeams`) are
        // populated. See `LLMExecutionService+ToolResolution` and the
        // Auto-injected section in `ToolSelectionView`. The Delegation tab in
        // the role editor is the only entry point.
    ]

    /// COMPLETE categorization for the tool-DEFINITIONS editor
    /// (`ToolDefinitionEditorSheetView`), which lists every registered tool. Unlike
    /// `displayCategories` (the role-editor toolset picker — manually-selectable
    /// tools only), this also groups the auto-injected / control-flow / manager
    /// tools so none of them fall into an "Other" catch-all. Keep this exhaustive:
    /// every tool in `ToolHandlerRegistry.allTypes` should map to exactly one
    /// section here. Do NOT use it for `ToolSelectionView` — these extra tools are
    /// not manually selectable.
    static let definitionDisplayCategories: [ToolCategoryDisplay] =
        displayCategories.map { category in
            // The definitions list shows `conclude_meeting` alongside the other
            // collaboration tools (it's auto-injected, so omitted from the
            // role-editor picker's Collaboration section).
            category.id == "collaboration"
                ? ToolCategoryDisplay(id: category.id, name: category.name, icon: category.icon,
                                      tools: category.tools + [TN.concludeMeeting])
                : category
        } + [
            ToolCategoryDisplay(id: "artifacts", name: "Artifacts", icon: "doc",
                                tools: [TN.createArtifact]),
            ToolCategoryDisplay(id: "teamGeneration", name: "Team Generation", icon: "person.3.sequence",
                                tools: [TN.createTeam]),
            ToolCategoryDisplay(id: "delegation", name: "Delegation", icon: "arrowshape.turn.up.right",
                                tools: [TN.delegateToTeam, TN.cancelDelegation, TN.resumeDelegation, TN.forwardToTeam]),
            ToolCategoryDisplay(id: "autovisor", name: "Autovisor", icon: AutovisorConstants.symbolName,
                                tools: [TN.listTasks, TN.taskStatus, TN.createManagedTask, TN.controlTask,
                                        TN.manageRole, TN.answerTaskQuestion, TN.messageTask, TN.scheduleTask,
                                        TN.setWorkFolderContext, TN.waitForEvents]),
        ]
}
