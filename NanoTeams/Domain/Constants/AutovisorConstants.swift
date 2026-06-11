import Foundation

/// Tunables + canonical identifiers for the Autovisor — the per-folder
/// automated Supervisor agent. Single source of truth so the role template,
/// team factory, runtime caps, and manager-step detection stay in lock-step.
nonisolated enum AutovisorConstants {
    /// Canonical `systemRoleID` / `builtInID` of the Manager role — the
    /// `Role.autovisor` ↔ id mapping (`Role.builtInID(.autovisor)`).
    /// NOTE: manager-step *detection* (memory write-through, goal injection,
    /// supervisor-routing) keys off `teamTemplateID`, not this id.
    static let managerRoleSystemID = "autovisor"

    /// `templateID` of the hidden Autovisor team. Filtered out of every team
    /// picker (same as the `"generated"` placeholder).
    static let teamTemplateID = "autovisor"

    /// The management tools that DEFINE the manager — always present. In the role
    /// editor they render as locked/"Required" (non-removable, never offered for
    /// removal); on every folder open they are union-enforced onto the persisted
    /// team's toolset so a stale team can't lose one. Removing any breaks the manager.
    static let managerMandatoryToolIDs: [String] = [
        ToolNames.listTasks, ToolNames.taskStatus, ToolNames.createManagedTask,
        ToolNames.controlTask, ToolNames.manageRole, ToolNames.answerTaskQuestion,
        ToolNames.messageTask, ToolNames.scheduleTask, ToolNames.setWorkFolderContext,
        ToolNames.waitForEvents,
    ]

    /// Tools the manager MAY use — file work (read + write) and full git, plus image
    /// inspection and memory. These are the tools offered for toggling in the role
    /// editor; everything outside (mandatory ∪ optional) is hidden (can't be added —
    /// xcode/delegation/meetings/team-creation don't apply to the manager).
    static let managerOptionalToolIDs: [String] = [
        // File work
        ToolNames.readFile, ToolNames.readLines, ToolNames.listFiles, ToolNames.search,
        ToolNames.writeFile, ToolNames.editFile, ToolNames.deleteFile,
        // Git
        ToolNames.gitStatus, ToolNames.gitAdd, ToolNames.gitCommit, ToolNames.gitPull,
        ToolNames.gitBranchList, ToolNames.gitCheckout, ToolNames.gitMerge,
        ToolNames.gitLog, ToolNames.gitDiff, ToolNames.gitStash, ToolNames.gitBranch,
        // Inspection + memory. analyze_image is optional (toggleable) but on by
        // default via `managerDefaultToolIDs` — the user can switch it off and that
        // choice persists (it is NOT union-enforced on open).
        ToolNames.analyzeImage, ToolNames.updateScratchpad,
    ]

    /// Default toolset seeded into the Autovisor role template (mandatory + optional).
    static var managerDefaultToolIDs: [String] { managerMandatoryToolIDs + managerOptionalToolIDs }

    /// Max new tasks the manager may create in ONE review pass. Enforced in
    /// `createManagedTask` against a per-pass counter (reset on each manager run
    /// start); bounds a burst of immediately-idle creations that the concurrent
    /// cap alone wouldn't catch.
    static let maxManagedTasksPerReview = 5

    /// Max concurrently-active tasks the manager may have created. Bounds long-term
    /// accumulation across many review passes.
    static let maxConcurrentManagedTasks = 2

    /// Lower bound for `AutovisorActivation.minSecondsBetweenRuns` — the
    /// event-wake debounce can never be set below this (a `0`/negative value would
    /// otherwise allow a wake-storm). 30s is well under the 60s default.
    static let minEventWakeDebounceSeconds: TimeInterval = 30

    /// Minimum auto-off (sleep-timer) duration. The scheduler evaluates once a
    /// minute, so sub-minute durations could never be honored on time.
    static let minAutoDisableSeconds: TimeInterval = 60

    /// Maximum auto-off duration — 999 h 59 m, the Settings steppers' ceiling.
    /// Bounds hand-edited `settings.json` values so the editor's `Int(_:)`
    /// seconds→h/m conversions can't trap on a non-representable Double.
    static let maxAutoDisableSeconds: TimeInterval = 3_599_940

    /// Default sleep-timer duration — the `AutovisorActivation` init default and
    /// legacy-decode fallback (the timer is ON by default). 3 hours.
    static let defaultAutoDisableAfterSeconds: TimeInterval = 10800

    /// Default review interval (seconds) seeded on the manager task's recurrence
    /// when the manager is first enabled. 10 minutes.
    static let defaultScheduleIntervalSeconds: TimeInterval = 600

    /// Seconds of COMPLETE stream silence (no token delta, no prompt-processing
    /// progress, no committed message, no fresh tool call — and no tool currently
    /// in flight) on a `.running` role before the Autovisor stuck-detector flags
    /// it as a "hang". Token-silence is a strong signal, so this is far shorter
    /// than a blunt wall-clock budget: a still-flowing (even long) response keeps
    /// refreshing the activity clock and never trips it. 3 minutes.
    ///
    /// NOTE: an in-flight tool suppresses the hang verdict (so a legitimately long
    /// `run_xcodebuild` isn't flagged). The corollary is that a tool subprocess that
    /// blocks *forever* is invisible to this path — that wedge is the run-timeout
    /// watchdog's job (`NTMSTask.runTimeoutSeconds`), not the stuck-detector's.
    static let stuckHangSeconds: TimeInterval = 180

    /// A tool/output loop only counts as "live" if the role produced the repeating
    /// signal within this window of now. Without it, `resetStepForRevision` (which
    /// retains `step.toolCalls` + `llmConversation` for audit) would let a stale
    /// trailing run of identical calls re-flag a freshly-restarted role as looping
    /// before it has emitted anything new. Stateless analogue of the `createdAt`
    /// cutoff `DelegationLoopWatcher` keeps as per-task state. 2 minutes — comfortably
    /// longer than the gap between calls in any real loop, short enough to bound the
    /// post-revision false-positive to a couple of minutes.
    static let stuckLoopRecencySeconds: TimeInterval = 120

    /// The standing "question" the manager's step parks on after `wait_for_events`
    /// (`.needsSupervisorInput`, session preserved). UI-facing: rendered as the
    /// pending question in the activity-feed composer and QuickCapture answer mode.
    /// A human answer continues the SAME conversation via stateful continuation;
    /// event/recurrence wakes supersede the park with a fresh review pass instead.
    /// ALSO a persisted-equality marker: `NTMSOrchestrator.taskHasIdleParkStep`
    /// compares the persisted (trimmed) `step.supervisorQuestion` against this text
    /// verbatim, so it must stay trim-stable, and editing the wording orphans parks
    /// persisted under the old text (cosmetic: the sidebar icon pulses while idle
    /// until the next fresh pass re-parks with the current text).
    static let idleParkQuestion =
        "Idle — waiting for events. Send a message to continue the conversation."

    /// Seeded into `ProjectSettings.autovisorGoal` when the manager task is
    /// first created, so the Goal field starts populated and editable. Until the
    /// human sets a real goal, it directs the manager to just build context and go
    /// idle (via `wait_for_events`) instead of inventing work.
    static let defaultGoal = """
        No goal set yet. For now, don't create or run any tasks — first explore and \
        understand this work folder: read its files, its structure, and any existing \
        tasks to build context, record what you find in memory, then call \
        wait_for_events. I'll set a concrete goal here when I'm ready.
        """

    /// Seeded into `ProjectSettings.autovisorMemory` at first creation so the
    /// Memory field starts non-empty. The manager overwrites this on its first
    /// review pass via `update_scratchpad`.
    static let defaultMemory =
        "(No notes yet — I'll record what I learn about this folder here on my first review.)"
}
