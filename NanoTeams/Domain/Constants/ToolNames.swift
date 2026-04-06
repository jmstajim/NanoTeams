import Foundation

/// Compile-time string constants for all 28 tool names.
/// Use these instead of string literals to get compile-time checking on tool identifiers.
enum ToolNames {
    // File System (7)
    static let listFiles = "list_files"
    static let readFile = "read_file"
    static let readLines = "read_lines"
    static let writeFile = "write_file"
    static let editFile = "edit_file"
    static let deleteFile = "delete_file"
    static let search = "search"
    // Git (11)
    static let gitStatus = "git_status"
    static let gitAdd = "git_add"
    static let gitCommit = "git_commit"
    static let gitPull = "git_pull"
    static let gitBranchList = "git_branch_list"
    static let gitCheckout = "git_checkout"
    static let gitMerge = "git_merge"
    static let gitLog = "git_log"
    static let gitDiff = "git_diff"
    static let gitStash = "git_stash"
    static let gitBranch = "git_branch"
    // Xcode (2)
    static let runXcodebuild = "run_xcodebuild"
    static let runXcodetests = "run_xcodetests"
    // Supervisor (1)
    static let askSupervisor = "ask_supervisor"
    // Memory (1)
    static let updateScratchpad = "update_scratchpad"
    // Collaboration (4)
    static let askTeammate = "ask_teammate"
    static let requestTeamMeeting = "request_team_meeting"
    static let concludeMeeting = "conclude_meeting"
    static let requestChanges = "request_changes"
    // Artifact (1)
    static let createArtifact = "create_artifact"
    // Vision (1)
    static let analyzeImage = "analyze_image"
}
