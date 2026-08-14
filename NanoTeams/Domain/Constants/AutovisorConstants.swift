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

    /// Tools the manager MAY use — file + git READ-only, build/test verification, plus
    /// image inspection and memory.
    /// The manager is a pure supervisor: it INSPECTS the repo to triage/steer and DELEGATES
    /// all work via `create_managed_task`; it has NO repo-mutation tools (no write_file /
    /// edit_file / delete_file, no git-write). These are the tools offered for toggling in
    /// the role editor; everything outside (mandatory ∪ optional) is hidden (can't be added —
    /// write/delegation/meetings/team-creation don't apply to the manager) AND is
    /// stripped from a stored manager on open by `syncAutovisorTeamToTemplate`.
    /// (`update_scratchpad` writes the manager's MEMORY and `set_work_folder_context` the
    /// shared context — neither touches repo files, so both stay.)
    static let managerOptionalToolIDs: [String] = [
        // File work — READ-ONLY. write_file / edit_file / delete_file are deliberately
        // excluded; the manager reads to investigate, then delegates any change.
        ToolNames.readFile, ToolNames.readLines, ToolNames.listFiles, ToolNames.search,
        // Git — READ-ONLY (same rationale): inspect history, never mutate the repo. git-WRITE
        // (add/commit/pull/checkout/merge/stash/branch) is excluded.
        ToolNames.gitStatus, ToolNames.gitBranchList, ToolNames.gitLog, ToolNames.gitDiff,
        // Inspection + memory. analyze_image is optional (toggleable) but on by
        // default via `managerDefaultToolIDs` — the user can switch it off and that
        // choice persists (it is NOT union-enforced on open).
        ToolNames.analyzeImage, ToolNames.updateScratchpad,
        // Computer use (screen control) — desktop-level, not repo-mutation, so it
        // doesn't violate the "pure supervisor" rule above. Delivered to EXISTING
        // managers additively by the version-bump reconcile (see
        // `NTMSRepository+Reconcile` autovisor branch); execution is gated by the
        // computer-use permission layer at call time.
        ToolNames.screenCapture, ToolNames.uiClick, ToolNames.uiType,
        ToolNames.uiKey, ToolNames.uiScroll,
        // Build + test — VERIFICATION, not implementation. "Does this repo currently
        // compile / pass?" is a question about the repo's STATE, the same class as a
        // read, and it is what tells the manager whether to open a fix task at all;
        // build products land in DerivedData, never in the repo, so the "no
        // repo-mutation" rule above holds. The prompt's `### Boundaries` names them
        // next to the read tools and immediately re-states the line they must not
        // cross: verify, then DELEGATE the fix — never edit code. A long build cannot
        // trip the stuck-detector either: an in-flight tool suppresses the hang
        // verdict (see `stuckHangSeconds`, which names `run_xcodebuild` outright).
        ToolNames.runXcodebuild, ToolNames.runXcodetests,
    ]

    /// Default toolset seeded into the Autovisor role template (mandatory + optional).
    static var managerDefaultToolIDs: [String] { managerMandatoryToolIDs + managerOptionalToolIDs }

    /// Optional-tool GROUPS the version-bump reconcile delivers to EXISTING managers
    /// all-or-nothing: a stored manager containing NONE of a group predates its
    /// introduction and receives the whole group; a manager containing SOME of it has
    /// seen the group and pruned — the per-tool choice is preserved (pinned by
    /// `testVersionBump_refreshesAutovisorManagerPrompt_preservingToolToggles`).
    /// Known edge: a user who disables an ENTIRE group is indistinguishable from
    /// never-offered, so the next version bump re-delivers it once.
    /// EVERY optional tool added after a manager could already exist on disk needs an
    /// entry here, or it is undeliverable: `syncAutovisorTeamToTemplate` union-enforces
    /// only the MANDATORY list, so nothing else ever ADDS an optional tool to a stored
    /// manager. The failure is silent and asymmetric — the tool appears on brand-new
    /// Autovisor teams and never on an existing work folder. (The file+git reads, image
    /// inspection and memory need no group: they shipped WITH the manager, so no stored
    /// manager can predate them.)
    /// Pinned by `AutovisorTeamTests.testXcodeRunners_areInADeliveryGroup_notJustTheOptionalList`
    /// and, behaviourally, by
    /// `NTMSRepositoryReconcileTests.testVersionBump_deliversXcodeRunners_toAManagerFromABuildWithoutThem`
    /// — both spell the names literally, because a test that reads this array cannot
    /// notice an entry that was never written.
    static let managerOptionalToolGroups: [[String]] = [
        [ToolNames.screenCapture, ToolNames.uiClick, ToolNames.uiType,
         ToolNames.uiKey, ToolNames.uiScroll],
        [ToolNames.runXcodebuild, ToolNames.runXcodetests],
    ]

    /// Max new tasks the manager may create in ONE review pass. Enforced in
    /// `createManagedTask` against a per-pass counter (reset on each manager run
    /// start); bounds a burst of immediately-idle creations that the concurrent
    /// cap alone wouldn't catch.
    static let maxManagedTasksPerReview = 5

    /// Max concurrently-active tasks the manager may have created. Bounds long-term
    /// accumulation across many review passes.
    static let maxConcurrentManagedTasks = 2

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
    ///
    /// Because the match is exact, a park that means something OTHER than "healthy
    /// idle" must carry its own text or it becomes indistinguishable from one — the
    /// sidebar gates the manager's attention badge on `!isIdleParked`. The
    /// thinking-loop terminal relies on that: it parks via
    /// `parkStepForEvents(question:)` with its diagnostic instead of this constant.
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
