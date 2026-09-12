import Foundation

/// Compile-time string constants for all 50 tool names.
/// Use these instead of string literals to get compile-time checking on tool identifiers.
nonisolated enum ToolNames {
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
    // Supervisor (2)
    static let askSupervisor = "ask_supervisor"
    /// Structured sibling of `ask_supervisor`: several questions, each with predefined
    /// options. A recommendation is read from what the model WROTE into
    /// `SupervisorInquiryQuestion.recommendedOptionID`, never from order, and it is nil on
    /// most questions. Deliberately a separate tool
    /// rather than an optional parameter — chat-mode teams route every assistant reply
    /// through `ask_supervisor`, and a form reachable there would turn conversation into
    /// a questionnaire.
    static let askSupervisorForm = "ask_supervisor_form"
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
    // Team (1)
    static let createTeam = "create_team"
    // Delegation (4)
    static let delegateToTeam = "delegate_to_team"
    static let cancelDelegation = "cancel_delegation"
    static let resumeDelegation = "resume_delegation"
    static let forwardToTeam = "forward_to_team"
    // Autovisor (10) — management tools for the per-folder automated Supervisor.
    // All category=.collaboration, excludedInMeetings, availableToRoles only for the Manager role.
    static let listTasks = "list_tasks"
    static let taskStatus = "task_status"
    static let createManagedTask = "create_managed_task"
    static let controlTask = "control_task"
    static let manageRole = "manage_role"
    static let answerTaskQuestion = "answer_task_question"
    static let messageTask = "message_task"
    static let scheduleTask = "schedule_task"
    static let setWorkFolderContext = "set_work_folder_context"
    static let waitForEvents = "wait_for_events"
    // Shell (2) — direct system interaction. category=.shell, excludedInMeetings,
    // blockedInDefaultStorage=false (usable with no work folder — sandboxed to the
    // Application Support root). Default-on for the code-writing roles + opt-in for
    // others. Gated by the command-permission layer.
    static let bash = "bash"
    static let bashOutput = "bash_output"
    // Computer Use (5) — screenshot + mouse/keyboard control of the desktop. category=.computerUse,
    // excludedInMeetings, blockedInDefaultStorage=false (controls the screen, not the work folder),
    // default-OFF for every role. Gated by the computer-use permission layer.
    static let screenCapture = "screen_capture"
    static let uiClick = "ui_click"
    static let uiType = "ui_type"
    static let uiKey = "ui_key"
    static let uiScroll = "ui_scroll"

    /// Every canonical tool name. Used where code must answer "is this string a
    /// known tool?" without reaching into the (`@MainActor`) handler registry —
    /// e.g. the pure Harmony parser distinguishing a flat `create_artifact`
    /// payload (top-level `name` = an unknown ARTIFACT name) from a legitimate
    /// flat call whose top-level `name` IS a tool (e.g. `update_scratchpad`).
    /// Pinned to the constant count by `ToolNamesAllNamesTests`.
    static let allNames: Set<String> = [
        listFiles, readFile, readLines, writeFile, editFile, deleteFile, search,
        gitStatus, gitAdd, gitCommit, gitPull, gitBranchList, gitCheckout, gitMerge,
        gitLog, gitDiff, gitStash, gitBranch,
        runXcodebuild, runXcodetests,
        askSupervisor, askSupervisorForm,
        updateScratchpad,
        askTeammate, requestTeamMeeting, concludeMeeting, requestChanges,
        createArtifact,
        analyzeImage,
        createTeam,
        delegateToTeam, cancelDelegation, resumeDelegation, forwardToTeam,
        listTasks, taskStatus, createManagedTask, controlTask, manageRole,
        answerTaskQuestion, messageTask, scheduleTask, setWorkFolderContext, waitForEvents,
        bash, bashOutput,
        screenCapture, uiClick, uiType, uiKey, uiScroll,
    ]

    /// Tools whose call PARKS the step waiting for the Supervisor — the closed set that
    /// every behavioural site must test against instead of spelling one name.
    ///
    /// Five sites read it, and each one fails differently and silently for a parking tool it
    /// does not recognise: `AskCallIndex` stops indexing the call (so the question loses the
    /// persisted identity its Watchtower dismissal is keyed on, and a re-asked identical
    /// headline is born dismissed); `StepExecution.activeAskCall`
    /// falls through to the flag-only escalation shape; `CompactionPolicy.carriesOpenPark`
    /// folds an epoch ACROSS the open park, orphaning the pending tool result; and
    /// `CompactionPolicy.supervisorAnswerResponse` — the worst of them — stops recognising
    /// the human's answer, so it is dropped from the compacted wire with an identical
    /// result and a clean log.
    ///
    /// `wait_for_events` is deliberately NOT here: it also suspends a role, but it is the
    /// Autovisor's idle park, resolved by folder events rather than by a person.
    static let supervisorAskTools: Set<String> = [askSupervisor, askSupervisorForm]
}
