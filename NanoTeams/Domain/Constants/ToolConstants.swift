import Foundation

/// Tool runtime limits and UI display categories.
/// Tool name string constants live in the top-level `ToolNames` enum.
enum ToolConstants {
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
        ToolCategoryDisplay(id: "filesystem", name: "File System", icon: "folder.fill",
                            tools: [TN.readFile, TN.readLines, TN.writeFile, TN.editFile, TN.deleteFile, TN.listFiles, TN.search]),
        ToolCategoryDisplay(id: "git", name: "Git", icon: "arrow.triangle.branch",
                            tools: [TN.gitStatus, TN.gitAdd, TN.gitCommit, TN.gitPull, TN.gitBranchList,
                                    TN.gitCheckout, TN.gitMerge, TN.gitLog, TN.gitDiff, TN.gitStash, TN.gitBranch]),
        ToolCategoryDisplay(id: "build", name: "Build", icon: "hammer.fill",
                            tools: [TN.runXcodebuild, TN.runXcodetests]),
        ToolCategoryDisplay(id: "collaboration", name: "Collaboration", icon: "bubble.left.and.bubble.right.fill",
                            tools: [TN.askTeammate, TN.requestTeamMeeting, TN.concludeMeeting, TN.requestChanges]),
        ToolCategoryDisplay(id: "memory", name: "Memory", icon: "brain.head.profile",
                            tools: [TN.updateScratchpad]),
        ToolCategoryDisplay(id: "supervisor", name: "Supervisor", icon: "crown.fill",
                            tools: [TN.askSupervisor]),
        ToolCategoryDisplay(id: "vision", name: "Vision", icon: "eye.fill",
                            tools: [TN.analyzeImage]),
    ]
}
