import Foundation
import Observation

// MARK: - NTMSOrchestrator

@Observable @MainActor
final class NTMSOrchestrator {
    var workFolderURL: URL?
    var snapshot: WorkFolderContext? {
        didSet { storeWriteRevision &+= 1 }
    }
    private(set) var activeTaskID: Int?
    var activeTask: NTMSTask? {
        didSet { storeWriteRevision &+= 1 }
    }

    /// Monotonic counter of WRITES to `snapshot` / `activeTask` — not of changes to them.
    ///
    /// A view that must react to anything inside the active task otherwise has to
    /// fold the task itself in an `onChange` KEY, and a key is evaluated on every
    /// body pass whether or not the handler fires (CLAUDE.md #113). The Watchtower
    /// timeline did exactly that: `WatchtowerTimelineBuilder.inputsVersion` walks
    /// every run x every step with eight `hasher.combine` per step, three of them
    /// over `String`, on every pass of the app's default detail pane.
    ///
    /// Deliberately a WRITE counter and not a derived fact — the opposite choice
    /// from `TaskFactsProjection`, and for the opposite reason. That projection
    /// answers "did this row's STATUS move", a question with few distinct answers,
    /// so it can afford to compare and stay inert on the common `updatedAt` tick.
    /// A timeline consumer needs every field the builder reads, and deciding
    /// "did any of them move" IS the Theta(runs x steps) fold being avoided. So this
    /// counter over-fires by construction, and the consumer pays the exact fold ONCE
    /// per write to confirm — moving it off the body pass without ever risking the
    /// failure mode a cheap key invites, which is a memo that stops refreshing.
    ///
    /// Both stores, because a consumer of task CONTENT also depends on the team that
    /// names its roles, and a team edit rewrites `snapshot` without touching
    /// `activeTask`. One counter for both: it answers "might anything I read have
    /// moved", and two counters would invite a consumer to watch the wrong one.
    ///
    /// `didSet` rather than a bump at each assignment: `activeTask` alone is written
    /// at four sites (`apply`, `applyTaskUpdate`, the streaming commit, the
    /// work-folder close), and a counter maintained at N sites is the shape
    /// CLAUDE.md #51 is about.
    private(set) var storeWriteRevision: Int = 0
    var selectedRunID: Int?
    var lastErrorMessage: String? {
        didSet {
            guard let lastErrorMessage else { return }
            errorSurfaceCount &+= 1
            lastSurfacedError = lastErrorMessage
        }
    }
    var lastInfoMessage: String?

    /// Monotonic count of errors SURFACED, bumped on every non-nil assignment to
    /// `lastErrorMessage`, and the message that came with the latest one.
    ///
    /// `lastErrorMessage` is a single-shot slot that the error banner CONSUMES (writes nil)
    /// on any render, so "did that operation fail?" cannot be answered by comparing the slot
    /// across an `await`: a real failure reads back as nil the moment SwiftUI renders during
    /// the suspension, and a REPEATED identical error never differs from the snapshot even
    /// when nothing consumed it. Both failure modes report success for a failed operation.
    /// This pair is never cleared and never compared for equality, so it survives both.
    ///
    /// `@ObservationIgnored` deliberately — it is bookkeeping for callers that need an
    /// outcome, not state any view renders; the banner still observes `lastErrorMessage`.
    @ObservationIgnored private(set) var errorSurfaceCount: Int = 0
    @ObservationIgnored private(set) var lastSurfacedError: String?

    /// The error surfaced since `baseline` (a `errorSurfaceCount` sample taken before
    /// the `await`), or `nil` when the operation surfaced none.
    ///
    /// This is the ONLY correct way to ask "did what I just awaited fail, and why?".
    /// Reading `lastErrorMessage` after an `await` answers a different question — "what
    /// should the user see right now" — and gets both directions wrong: the banner nils
    /// the slot on any render during the suspension, so a real failure reads back as
    /// nil; and a FOREIGN message parked there by an unrelated operation reads back as
    /// this one's reason, which is how a failed close came to be reported to the
    /// Autovisor with an unrelated disk error as its diagnosis.
    ///
    /// Callers that only need the Bool ("did it fail?") compare the count themselves;
    /// this returns the message so a failure can be reported with its own reason.
    func errorSurfaced(since baseline: Int) -> String? {
        errorSurfaceCount != baseline ? lastSurfacedError : nil
    }
    /// Latched copy of the open-time bundled-update report.
    ///
    /// `WorkFolderContext.bundledUpdate` is populated only by
    /// `openOrCreateWorkFolder`; `assembleContext` (the path every
    /// `mutateWorkFolder` takes) rebuilds the context without it, so reading the
    /// snapshot would lose the report on the first unrelated edit. Plain `var`,
    /// not `private(set)`: the writer lives in the `+WorkFolderManagement`
    /// extension file and `private(set)` setters are file-scoped (CLAUDE.md #2).
    var bundledUpdateReport: BundledUpdateReport?
    private(set) var toolDefinitions: [ToolDefinitionRecord] = []

    /// Extracted engine state — views can observe this directly to avoid
    /// re-evaluating when unrelated orchestrator properties change.
    let engineState: OrchestratorEngineState

    /// Per-task derived status + durable Supervisor-wait facts, maintained
    /// incrementally so the shell's `onChange` keys are `Int` compares rather
    /// than whole-index `Dictionary` rebuilds per body pass. See the type.
    let taskFacts = TaskFactsProjection()
    /// Prompt-prefix (KV) cache-miss aggregate. Drives the always-on status-bar count and
    /// decides which misses earn the single-slot banner. Injected like the other observables so
    /// tests get a fresh one.
    let prefixCacheReporter: PrefixCacheReporter

    /// Streaming preview manager for real-time LLM response display.
    let streamingPreviewManager: StreamingPreviewManager

    /// Extracted configuration — views can observe this directly to avoid
    /// triggering orchestrator-wide re-evaluation on settings changes.
    let configuration: StoreConfiguration

    /// Re-entrancy guard for `reconcileChatModelResidency`. Settings can change
    /// faster than a reconcile completes (a second picker click while an unload
    /// is mid-round-trip), and two concurrent passes would race to unload the
    /// same orphan. Not observed by any view.
    @ObservationIgnored var isReconcilingResidency = false

    /// Coalescing latch paired with `isReconcilingResidency`: a reconcile that
    /// arrives while a pass is in flight sets this instead of being dropped, and
    /// the running pass loops once more when it finishes. Without it a dedicated
    /// de-reference sweep (removeTask / switchTeam) could be silently swallowed
    /// by the run-boundary sweep the same flow spawns — whose snapshot predates
    /// the de-reference — leaving the model resident with no further trigger.
    @ObservationIgnored var pendingResidencyReconcile = false

    /// Client used by the chat-model residency reconciler. Injectable so tests
    /// don't issue live HTTP from `openWorkFolder` (CLAUDE.md #49) — `nil`
    /// means "build a real `LLMClientRouter` on demand", the production path.
    @ObservationIgnored let chatLifecycleClient: (any LLMClient)?

    /// Client used by `runTeamGeneration`'s `create_team` call. Same shape and same
    /// reason as `chatLifecycleClient`: `nil` means "build a real `LLMClientRouter`
    /// on demand".
    ///
    /// It exists because `TeamGenerationService.generate` carried
    /// `client: any LLMClient = LLMClientRouter()` and the call site never passed
    /// one — so in a test process every generation threw a transport error, and
    /// `runTeamGeneration`'s ENTIRE success arm (adopt the team, re-pin `run.teamID`,
    /// seed role statuses, start the engine) had never once executed. That made it
    /// the largest untested happy path in the app, and the untestable half of the
    /// `applyGeneratedTeamSuccess` invariants its own doc comment describes.
    @ObservationIgnored let teamGenerationClient: (any LLMClient)?

    /// Ownership ledger for chat models. Defaults to the process-global
    /// singleton; tests inject a fresh actor so ownership can't leak between
    /// suites — or out to the developer's running LM Studio.
    @ObservationIgnored let chatModelEnsurer: ChatModelEnsurer

    /// Reads/removes the model downloads occupying disk on a provider's host
    /// (Settings → LLM → Downloaded Models). Injectable for the same reason as
    /// `chatLifecycleClient` (CLAUDE.md #49), and more urgently: the LM Studio
    /// implementation walks — and can Trash — real directories under
    /// `~/.lmstudio/models`, which no test may ever reach.
    @ObservationIgnored let downloadedModelStore: any DownloadedModelStore

    /// `bash` commands currently HELD awaiting the human's in-loop Allow/Deny
    /// decision, keyed by (taskID, stepID). Mirrors the gate's await state so the
    /// activity feed renders the approval buttons. Mutated only via the
    /// `LLMStateDelegate` bash-approval hooks (see `NTMSOrchestrator+BashAdvice`).
    var bashApprovalRequests: [TaskStepKey: BashApprovalRequest] = [:]

    /// Computer-use actions currently HELD awaiting the human's Allow/Deny/Always decision,
    /// keyed by (taskID, stepID). Mirrors the gate's await state so the activity feed renders
    /// the approval card (with a screenshot + crosshair preview). Mutated only via the
    /// `LLMStateDelegate` computer-use approval hooks (see `NTMSOrchestrator+ComputerUseApproval`).
    var computerUseApprovalRequests: [TaskStepKey: ComputerUseApprovalRequest] = [:]

    // MARK: - Computed Properties

    /// Engine states keyed by task ID.
    /// Prefer observing `engineState` directly in views for finer-grained reactivity.
    var taskEngineStates: [Int: TeamEngineState] {
        engineState.taskEngineStates
    }

    var globalLLMConfig: LLMConfig {
        configuration.globalLLMConfig
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var globalLLMContext: String {
        configuration.globalContext
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var maxLLMRetries: Int {
        get { configuration.maxLLMRetries }
        set { configuration.maxLLMRetries = newValue }
    }

    var visionLLMConfig: LLMConfig? {
        configuration.visionLLMConfig
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var bashPolicy: BashPolicy {
        configuration.bashPolicy
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var computerUsePolicy: ComputerUsePolicy {
        configuration.computerUsePolicy
    }

    var loggingEnabled: Bool {
        configuration.loggingEnabled
    }

    var exploratorySearchEnabled: Bool {
        configuration.exploratorySearchEnabled
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var searchExploratoryByDefault: Bool {
        configuration.searchExploratoryByDefault
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var readFileMaxLines: Int {
        configuration.readFileMaxLines
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var searchMaxResults: Int {
        configuration.searchMaxResults
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var searchContextBefore: Int {
        configuration.searchContextBefore
    }

    // periphery:ignore - protocol conformance (LLMStateDelegate)
    var searchContextAfter: Int {
        configuration.searchContextAfter
    }

    func awaitSearchIndex() async -> SearchIndex? {
        guard let coordinator = searchIndexCoordinator else { return nil }
        return await coordinator.awaitIndex()
    }

    func expandSearchQuery(
        query: String,
        tokens: [String]
    ) async -> VocabVectorIndexService.ExpansionResult {
        guard let coordinator = searchIndexCoordinator else {
            return .unavailable(reason: VocabVectorIndexService.reasonMissing)
        }
        return await coordinator.vectorIndex.expand(
            query: query,
            tokens: tokens,
            config: configuration.effectiveEmbeddingConfig,
            perTokenThreshold: Float(configuration.exploratorySearchPerTokenThreshold),
            phraseThreshold: Float(configuration.exploratorySearchPhraseThreshold)
        )
    }

    /// Coordinator that owns the search index + FS watcher. Populated on work
    /// folder open when `configuration.exploratorySearchEnabled == true`. `nil` when
    /// feature is off or no folder is open.
    ///
    /// Views DO observe this identity change — `ExploratorySearchSettingsView` passes
    /// `store.searchIndexCoordinator` into the status cards, and
    /// `SidebarWorkFolderCards` reads `store.searchIndexCoordinator?.isBuilding`.
    /// `@ObservationIgnored` would freeze the cards at their initial nil
    /// snapshot so enabling the toggle would not refresh them.
    var searchIndexCoordinator: SearchIndexCoordinator?

    /// Why the index files are still on disk after the user turned Exploratory Search OFF.
    ///
    /// Needed because the coordinator is the ONLY thing that knows a delete failed
    /// (`SearchIndexCoordinator.clear()` records it) and the disable path drops the
    /// coordinator on the next line — so the diagnosis died with the object that held it.
    /// A banner is the wrong slot twice over: `reconcileEmbeddingLifecycle()` runs
    /// immediately after and writes `lastInfoMessage` on its own failure, and `.errorBanner()`
    /// is applied only to `MainLayoutView` while the user who flipped the toggle is looking at
    /// the Settings *window*. So it is rendered where the toggle is, in the status card's
    /// disabled branch, and cleared by the next successful clear or re-enable.
    ///
    /// `nil` means "nothing left behind" — the state after every successful disable.
    var searchIndexClearFailure: String?

    /// Serial pipeline for exploratory-search toggle events. Each enqueued task
    /// awaits the prior one so three rapid detached-Task clicks from
    /// `ExploratorySearchToggleCard.onChanged` can't interleave inside
    /// `applyExploratorySearchSettingChange`, which would produce a non-deterministic
    /// final state. See `onExploratorySearchSettingChanged` in +WorkFolderManagement.
    @ObservationIgnored var pendingExploratorySearchToggle: Task<Void, Never>?

    /// Manages load/unload of the LM Studio embed model used by Exploratory
    /// Search. Reconciled at the end of every public lifecycle method
    /// (openWorkFolder, applyExploratorySearchSettingChange, embed-config change)
    /// so the model loaded in LM Studio tracks `searchIndexCoordinator != nil`.
    /// Test-injected via init to avoid real network calls in CI.
    @ObservationIgnored let embeddingLifecycle: EmbeddingModelLifecycleService
    /// Embedding client used by the per-folder `SearchIndexCoordinator` for
    /// vocab-vector builds. DI seam — tests inject a recording mock so the
    /// vector phase doesn't issue real `/v1/embeddings` round-trips.
    @ObservationIgnored let searchEmbeddingClient: any EmbeddingClient

    /// Shared "is the work-folder context currently being generated" flag.
    /// Both Settings and the Sidebar work-folder card observe this so generation
    /// triggered from either surface lights up the other.
    var isGeneratingWorkFolderContext: Bool = false

    /// Agent instruction files for the open work folder: auto-discovered
    /// (CLAUDE.md, AGENTS.md, …) composed with the user's persisted overrides
    /// (`settings.agentInstructionExtraPaths` / `…ExcludedPaths`). In-memory
    /// only (derived from disk, can be large — never persisted). Refreshed on
    /// work-folder open, at each top-level `startRun`, on the Work Folder
    /// settings tab appear, and after add/remove/restore edits. `nil` in
    /// default storage / no folder. Injected content + listed paths ride the
    /// `{workFolderContext}` placeholder into every role's system prompt.
    /// Satisfies `LLMStateDelegate.agentInstructions`.
    var agentInstructions: AgentInstructionsSnapshot?

    /// CLAUDE.md #38 generation counter for `refreshAgentInstructions` — a
    /// completed scan only lands when no newer refresh started meanwhile, so
    /// concurrent same-folder refreshes can't clobber fresh results with stale
    /// ones (folder switch/close bump it too, dropping in-flight old-folder scans).
    @ObservationIgnored var agentInstructionsScanGeneration: Int = 0
    /// Inputs + completion time of the last landed scan — short-TTL memo so
    /// back-to-back run starts (recurrence tick firing several tasks, Autovisor
    /// passes) don't re-walk an unchanged folder within seconds.
    @ObservationIgnored var agentInstructionsLastScanKey: AgentInstructionsScanKey?
    @ObservationIgnored var agentInstructionsLastScanAt: Date?

    /// Agent skills discoverable for this install, plus the bodies of the ones
    /// roles have attached (`TeamRoleDefinition.attachedSkillIDs`).
    ///
    /// Two halves with two lifetimes, and the distinction is what keeps a run start
    /// cheap. `items` is the CATALOGUE — a fact about the machine, cached on disk by
    /// `AgentSkillsCatalogueStore` and re-walked only when the user asks. `bodies` is
    /// CONTENT — re-read on work-folder open, at each top-level `startRun`, and
    /// before prompt-preview renders, so a `SKILL.md` edited since launch always
    /// reaches the wire.
    ///
    /// Unlike `agentInstructions` this is **never nil'd for default storage**:
    /// global skills (`~/.claude/skills`, `~/.codex/prompts`, plugins) exist
    /// with no work folder open, which is exactly the mode the app boots into.
    /// Satisfies `LLMStateDelegate.roleSkills`.
    var roleSkills: RoleSkillsSnapshot?

    /// CLAUDE.md #38 generation counter for `refreshAgentSkills` — same contract
    /// as `agentInstructionsScanGeneration`.
    @ObservationIgnored var roleSkillsScanGeneration: Int = 0

    /// The attachment set a catalogue rescan has already been attempted for.
    ///
    /// Bounds the "an attached id is missing → look again" retry to ONCE per set. A
    /// dangling attachment — the skill was deleted from disk after a role attached
    /// it — is unresolvable by definition, so without this the retry would fire a
    /// full walk of every skill root on every single run start, reintroducing
    /// exactly the per-send cost the catalogue cache removes, and silently. Changing
    /// what is attached is a new question and earns a fresh attempt.
    @ObservationIgnored var roleSkillsRescanAttemptedFor: [String]?

    /// Where the skill CATALOGUE is cached between launches.
    ///
    /// A seam, not a process global, for the reason CLAUDE.md #49 records: the
    /// default resolves OUTWARD to the developer's real
    /// `~/Library/Application Support/NanoTeams/skills/`, so a test that omitted it
    /// would both read the machine's installed skills and write its fixtures over
    /// them. `TestOrchestrator.make` injects a temp directory.
    @ObservationIgnored let skillsCatalogueStore: AgentSkillsCatalogueStore

    /// Which start each in-flight launch belongs to, keyed by task ID.
    ///
    /// Bumped by `claimRunStart` and by `abortRunStart`. `launchRun` captures the value
    /// at entry and re-checks it after every suspension, so a start the Supervisor has
    /// since aborted refuses to write — and a `releaseRunStart` arriving late from that
    /// aborted launch cannot drop the claim of the start that replaced it (CLAUDE.md
    /// #74: a key that outlives what it identifies makes "still mine" indistinguishable
    /// from "someone else's").
    ///
    /// A counter rather than an abort FLAG because it needs no clearing: a fresh claim
    /// is simply a new value, so there is no window in which a stale "aborted" mark
    /// could refuse the start that follows it. Same idiom as
    /// `agentInstructionsScanGeneration` (CLAUDE.md #38).
    ///
    /// It is what makes Pause work on the INLINE start path (Play, Autovisor,
    /// recurrence), where `backgroundRunLaunches` is legitimately empty and there is no
    /// `Task` to cancel. Cancellation still runs for the background path — it only
    /// unwinds sooner; the refusal itself is this counter's (CLAUDE.md #51: a guard on
    /// one of two paths is a coincidence).
    @ObservationIgnored var runStartGeneration: [Int: Int] = [:]

    /// Join handles for run launches that were spawned in the BACKGROUND rather
    /// than awaited inline — today only the Quick Capture create path, which
    /// returns to the UI as soon as the run is materialized so the chat can open,
    /// and lets the launch (instruction/skill rescan, engine start) finish behind it.
    ///
    /// Not a second home for `engineState.initializingRunTaskIDs` (CLAUDE.md #95):
    /// that set answers "is a start in flight" for EVERY path and is what the
    /// double-start guards and the four Initializing surfaces read; this dictionary
    /// answers "is there a background launch I can join" and is legitimately empty
    /// during an inline `startRun`, where the caller's own `await` already is the
    /// join. Read it through `runStartTask(for:)`.
    @ObservationIgnored var backgroundRunLaunches: [Int: Task<Void, Never>] = [:]

    /// Tasks whose FORCED Autovisor pass (`startAutovisorPass(force:)`) is between
    /// its claim and `startRun`. A separate set from
    /// `engineState.initializingRunTaskIDs` because the force path's vulnerable
    /// window OPENS EARLIER: it `await`s `pauseRun` before ever reaching `startRun`,
    /// and `TeamEngine.pause()` writes `.paused` on its LAST line — so for that whole
    /// suspension the engine mirror still reads `.running` and a second click observes
    /// exactly the state the first did. It cannot reuse the run-start claim:
    /// `startRun` bails on membership, so claiming that set here would make the force
    /// path never start a run.
    @ObservationIgnored var forcingRunTaskIDs: Set<Int> = []

    @ObservationIgnored var workFolderContextGenerationTask: Task<Void, Never>?

    /// Generation counter for `startGeneratingWorkFolderContext`. The spawned
    /// lambda captures the value at start; on completion it only writes back
    /// state when the counter still matches. `cancelWorkFolderContextGeneration`
    /// bumps the counter so a late-firing lambda from a cancelled run can't
    /// clobber the flag / handle of a freshly started new run.
    @ObservationIgnored var workFolderContextGenerationGeneration: Int = 0

    /// All top-level tasks currently in memory (active + background).
    /// Child tasks created via `delegate_to_team` (`parentTaskID != nil`) are excluded —
    /// they are internal to the parent's tool call and never surface as Supervisor work.
    /// The Autovisor task is also excluded: it IS the (automated) Supervisor, so it
    /// must not appear as supervised work in Watchtower notifications.
    var allLoadedTasks: [NTMSTask] {
        let managerID = autovisorTaskID
        var tasks: [NTMSTask] = []
        if let active = activeTask, active.parentTaskID == nil, active.id != managerID {
            tasks.append(active)
        }
        if let loaded = snapshot?.loadedTasks {
            for (id, task) in loaded where id != activeTaskID && task.parentTaskID == nil && id != managerID {
                tasks.append(task)
            }
        }
        return tasks
    }

    /// Variant including delegated child tasks. Used by internal lifecycle code
    /// (recursive removal, awaiter cleanup) that genuinely needs the full set.
    var allLoadedTasksIncludingChildren: [NTMSTask] {
        var tasks: [NTMSTask] = []
        if let active = activeTask { tasks.append(active) }
        if let loaded = snapshot?.loadedTasks {
            for (id, task) in loaded where id != activeTaskID {
                tasks.append(task)
            }
        }
        return tasks
    }

    /// True when a run pinned to `teamID` is still in flight, so a Team Editor
    /// edit that would invalidate live run state must be refused.
    ///
    /// Reads `allLoadedTasksIncludingChildren` — delegated children run on their
    /// own team and are just as wedgeable — and defers the rule itself to
    /// `TeamBusyScan` so it stays unit-testable without an orchestrator.
    func hasInFlightRun(forTeamID teamID: NTMSID) -> Bool {
        TeamBusyScan.hasInFlightRun(teamID: teamID, tasks: allLoadedTasksIncludingChildren)
    }

    @ObservationIgnored let repository: any NTMSRepositoryProtocol
    /// Engine instances keyed by task ID.
    @ObservationIgnored var taskEngines: [Int: TeamEngine] = [:]
    /// Background poll loop that fires due task recurrences and enforces per-run
    /// timeouts. Owned here (extensions can't add stored properties); started on
    /// `openWorkFolder`, cancelled on the next open. See `NTMSOrchestrator+Scheduling`.
    @ObservationIgnored var automationPollTask: Task<Void, Never>?
    /// Fixed delay between automation poll ticks, or `nil` for the production
    /// cadence (phase-aligned wall-clock minute boundaries). Injectable because the
    /// production cadence makes the loop a NONDETERMINISM source under test: every
    /// `openWorkFolder` arms it, and a minute boundary landing inside a test's
    /// window runs the full tick body — recurrence fires, timeout sweeps, and the
    /// Autovisor backstop wake — against whatever conditions the test just staged.
    /// That is exactly how `testWake_freshCondition_wakesWithNoThrottle` flaked
    /// (DEBTS.md §5, D-4 form B): the backstop delivered the staged Review
    /// condition first, the test's own wake correctly declined re-delivery
    /// (deliver-once), and the assert read the un-moved stamp.
    /// `TestOrchestratorFactory` passes a delay no test process lives to see; a
    /// scheduler test passes a sub-second value to watch real ticks.
    @ObservationIgnored let automationTickInterval: TimeInterval?
    /// Notification side-channel for synchronous delegation: `handleDelegateToTeam`
    /// awaits this when it spawns a child task. Wired in `engineForTask` — the
    /// engine's `onStateChanged` callback delivers terminal / `.needsSupervisorInput`
    /// transitions here in addition to the normal `engineState[taskID]` write.
    @ObservationIgnored let completionAwaiter: TaskCompletionAwaiter = TaskCompletionAwaiter()
    /// Watches delegated child tasks for pathologically repetitive output and
    /// auto-triggers Pause-and-Decide via `notifyDelegationInterrupt(...)`.
    /// Hooks fire from streaming (throttled), `commitStreaming`, and
    /// llmConversation appends — see `DelegationLoopWatcher`. The watcher
    /// holds a weak ref back to the orchestrator (resolved via `bind` after
    /// init since `self` isn't available in the property initializer).
    @ObservationIgnored let delegationLoopWatcher: DelegationLoopWatcher = DelegationLoopWatcher()
    /// Atomic reserve flag for generated-team creation. Inserted by
    /// `beginTeamGeneration` before the detached Task is spawned so concurrent
    /// `startRun` / `retryTeamGeneration` callers see the slot as taken even
    /// during the brief window before `registerTeamGenerationTask` installs
    /// the cancellation handle.
    @ObservationIgnored var teamGenerationInFlight: Set<Int> = []
    /// Cancellation handles for detached team-generation Tasks, keyed by taskID.
    /// `pauseRun` cancels these so an in-flight `TeamGenerationService.generate`
    /// stream stops before it can transition the engine.
    @ObservationIgnored var teamGenerationTasks: [Int: Task<Void, Never>] = [:]
    /// Serialization chain for `switchTask` cached-fast-path active-task pointer
    /// writes. Each new fast-path call captures the prior Task into its own
    /// closure as `previous` and awaits it before dispatching its own
    /// off-MainActor `setActiveTaskID`, so two fast-path switches issued in
    /// rapid succession commit to disk in MainActor-invocation order. Without
    /// this the two `Task.detached` writes would race on the cooperative pool
    /// and a "later-to-finish" A could leave disk pointing at the stale task
    /// while the UI is on B. The orchestrator slot only points to the LATEST
    /// Task — the chain is extended through closure captures, and prior links
    /// are released when each new Task's `_ = try? await previous?.value`
    /// returns and the closure-captured `previous` falls out of scope.
    /// Cancelled (and nil'd) on `closeProject` / `resetAllData` so an
    /// in-flight write doesn't fire against a torn-down workfolder.
    /// Other writers of `activeTaskID` (slow-path `switchTask`, top-level
    /// `createTask`, `deleteTask` active-task fallback) must
    /// `await flushPendingActiveTaskWrite()` first — see that helper for
    /// the ordering invariant they restore.
    @ObservationIgnored var pendingActiveTaskWrite: Task<Void, Error>?
    @ObservationIgnored let llmExecutionService: LLMExecutionService
    @ObservationIgnored let settingsService: SettingsService
    @ObservationIgnored let taskService: TaskService
    @ObservationIgnored let workFolderManagementService: WorkFolderManagementService
    @ObservationIgnored let engineFactory: @MainActor () -> TeamEngine
    @ObservationIgnored let fileManager: FileManager
    /// Source of queued Supervisor messages delivered on a role's next LLM iteration.
    /// Wired by `NanoTeamsApp` after `QuickCaptureController.shared.setup(...)`. Weak
    /// because `QuickCaptureController` already owns the strong reference to the
    /// shared form state.
    @ObservationIgnored weak var quickCaptureFormState: QuickCaptureFormState?

    /// Timestamp of the manager's last review pass start (any path: event-wake,
    /// recurrence, Run-now, open-time). A "last reviewed" diagnostic signal, NOT a
    /// throttle — the event-wake debounce was removed: events reach the manager
    /// immediately when it's idle, or queue (mid-review injection) when it's running.
    /// Stamped in `startRun`'s manager hook.
    @ObservationIgnored var autovisorLastWakeAt: Date?

    /// Top-level task ids the Autovisor has already seen, so the `onTaskCreated`
    /// activation trigger fires once per genuinely-new task rather than every tick.
    /// Seeded at open from the existing tasks; refreshed whenever the manager wakes.
    @ObservationIgnored var autovisorSeenTaskIDs: Set<Int> = []

    /// (task, trigger) conditions already delivered into the manager's LIVE
    /// conversation as a mid-review event notice, so a still-matching level doesn't
    /// re-inject the same message every tick of a long pass. Scoped to the
    /// mid-review injection branch ONLY — the fresh-pass wake path deliberately
    /// stays edge-dedup-free (a `handled`-style set there was adversarially
    /// rejected; see `AutovisorOrchestratorTests.testWake_freshCondition_wakesWithNoThrottle`).
    /// Seeded with every
    /// non-stuck condition matching at pass start (`seedAutovisorNotifiedKeysForPassStart`
    /// deliberately passes `stuck: []` — one stuck notice per pass is intended)
    /// and pruned on each wake to keys still matching among the triggers that wake
    /// evaluated (`.stuck` keys survive observer wakes, which never run the stuck
    /// detector), so a condition that clears and later re-fires notifies again.
    @ObservationIgnored var autovisorNotifiedAttentionKeys: Set<AutovisorAttentionKey> = []

    /// Stable snapshot of the attention conditions present at the manager's last
    /// review pass start — the DELIVER-ONCE baseline for event wakes. There is no
    /// time-throttle: a condition NOT in this set is "fresh" — it arose SINCE the last
    /// pass (typically a task the manager created mid-pass whose artifact /
    /// `ask_supervisor` landed after it parked) — and wakes the manager immediately
    /// (or, if it's already running, is injected into the live conversation). A
    /// condition already in the snapshot is NOT re-delivered while it keeps matching; the
    /// periodic recurrence sweep re-reviews unresolved ones. The pass-start seed RECOMPUTES `.stuck` into
    /// the baseline so a stuck task is delivered once, not every poll. Deliberately SEPARATE
    /// from `autovisorNotifiedAttentionKeys` (the mid-review injection dedup set —
    /// pruned + `formUnion`'d during a pass): that one is delivery bookkeeping WITHIN a
    /// pass, this one records what a pass was STARTED for. WHERE a spent key is retired is
    /// derived per trigger from `AutovisorAttentionTrigger.keyRetirement`, never listed at
    /// any one site (CLAUDE.md #143) — a key is retired on the `upsertTaskSummary` edge when
    /// its level is a pure function of the index row, by the wake's prune when its level ORs
    /// in something no index write observes, and not at all when its remedy is an attempt
    /// rather than a consumption. Keeping a spent key made the next occurrence of the same
    /// condition read as already-delivered (#74) — for questions until 2026-08-20, and for
    /// Review until 2026-08-30.
    /// FOUR maintainers: set at every pass start (`seedAutovisorNotifiedKeysForPassStart`),
    /// pruned + recorded in `wakeAutovisorForEvents`, and single-key-retired by
    /// `noteSupervisorQuestionResolved` and `noteDerivedStatusTransition`.
    /// The record in `wakeAutovisorForEvents` happens
    /// synchronously before the `await` — that synchronous record is the
    /// SOLE serialization between the concurrent observer + poll callers (a second wake
    /// for the same conditions sees them as not-fresh and bails, so neither
    /// double-starts a `createNewRun`).
    @ObservationIgnored var autovisorLastPassAttentionKeys: Set<AutovisorAttentionKey> = []

    /// Attention keys already re-delivered once because the pass that baselined them
    /// died in a reasoning loop rather than reviewing them.
    ///
    /// `autovisorLastPassAttentionKeys` encodes "the manager has SEEN this condition",
    /// and a pass terminated by `LoopRecoveryPolicy.parkForSupervisor` saw nothing — so
    /// its baseline is a false claim and `noteAutovisorLoopPark` rolls it back. This
    /// ledger is what keeps that rollback BOUNDED: at most one extra pass per key per
    /// loop-park episode. Without it, a manager that loops every pass would roll back
    /// its own baseline forever and the poll would restart it every minute — exactly
    /// the tight wake loop the deliver-once design exists to prevent.
    ///
    /// Cleared on any HEALTHY terminal (`.done` / `.needsAcceptance`), which re-arms
    /// the one free re-delivery for the next episode.
    @ObservationIgnored var autovisorLoopParkRedelivered: Set<AutovisorAttentionKey> = []

    /// Tasks the Autovisor created during the CURRENT review pass. Reset to 0
    /// on each manager run start (in `startRun`); bounded in `createManagedTask` by
    /// `settings.autovisorTuning.maxManagedTasksPerReview` (default
    /// `AutovisorConstants.maxManagedTasksPerReview`).
    @ObservationIgnored var autovisorCreationsThisReview: Int = 0

    /// In-memory auto-off deadline (sleep timer). Armed by `rearmAutovisorAutoDisable`
    /// on enable / duration edit / folder open; consumed by `evaluateAutovisorAutoDisable`
    /// each scheduler tick. Deliberately NOT persisted — the countdown restarts fresh
    /// each launch. Observable (unlike the wake bookkeeping above) so Settings can show
    /// the off time; it changes rarely, so no hot-path cost.
    var autovisorAutoDisableAt: Date?

    /// Default internal storage used when no real work folder is selected.
    /// Teams like Quest Party and Discussion Club work without a real folder.
    static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NanoTeams", isDirectory: true)
    }

    /// Whether a real user-chosen work folder is set (vs default internal storage).
    var hasRealWorkFolder: Bool {
        guard let url = workFolderURL else { return false }
        return url != Self.defaultStorageURL
    }

    init(
        repository: any NTMSRepositoryProtocol,
        llmExecutionService: LLMExecutionService? = nil,
        settingsService: SettingsService? = nil,
        taskService: TaskService? = nil,
        workFolderManagementService: WorkFolderManagementService? = nil,
        engineFactory: @MainActor @escaping () -> TeamEngine = { TeamEngine() },
        engineState: OrchestratorEngineState? = nil,
        prefixCacheReporter: PrefixCacheReporter? = nil,
        streamingPreviewManager: StreamingPreviewManager? = nil,
        configuration: StoreConfiguration? = nil,
        fileManager: FileManager? = nil,
        embeddingLifecycle: EmbeddingModelLifecycleService? = nil,
        searchEmbeddingClient: (any EmbeddingClient)? = nil,
        chatLifecycleClient: (any LLMClient)? = nil,
        teamGenerationClient: (any LLMClient)? = nil,
        chatModelEnsurer: ChatModelEnsurer = .shared,
        downloadedModelStore: (any DownloadedModelStore)? = nil,
        skillsCatalogueStore: AgentSkillsCatalogueStore? = nil,
        automationTickInterval: TimeInterval? = nil
    ) {
        self.skillsCatalogueStore = skillsCatalogueStore ?? .shared
        self.automationTickInterval = automationTickInterval
        self.chatLifecycleClient = chatLifecycleClient
        self.teamGenerationClient = teamGenerationClient
        self.chatModelEnsurer = chatModelEnsurer
        self.downloadedModelStore = downloadedModelStore ?? DownloadedModelStoreRouter()
        self.repository = repository
        // `computerUse: .system` is named HERE and nowhere else: the seam defaults to `.inert` so a
        // test that omits it cannot synthesize input, which makes this the one line that hands the
        // finalizer the real screenshot / AX / CGEvent adapters.
        self.llmExecutionService = llmExecutionService
            ?? LLMExecutionService(repository: repository, computerUse: .system)
        self.settingsService = settingsService ?? SettingsService(repository: repository)
        self.taskService = taskService ?? TaskService(repository: repository)
        self.workFolderManagementService = workFolderManagementService ?? WorkFolderManagementService(repository: repository)
        self.engineFactory = engineFactory
        self.engineState = engineState ?? OrchestratorEngineState()
        self.prefixCacheReporter = prefixCacheReporter ?? PrefixCacheReporter()
        self.streamingPreviewManager = streamingPreviewManager ?? StreamingPreviewManager()
        self.configuration = configuration ?? StoreConfiguration()
        self.fileManager = fileManager ?? .default
        self.embeddingLifecycle = embeddingLifecycle ?? EmbeddingModelLifecycleService()
        self.searchEmbeddingClient = searchEmbeddingClient ?? LMStudioEmbeddingClient()
        self.llmExecutionService.attach(delegate: self)
        // Bind the delegation loop watcher AFTER `self` is fully initialized
        // — its weak orchestrator ref can't be set in the property
        // initializer. Watcher's hooks fire from streaming/commit paths and
        // call `notifyDelegationInterrupt(...)` for child tasks that emit
        // pathologically repetitive output.
        self.delegationLoopWatcher.bind(orchestrator: self)
        // Wire soft-warning surfacing — VRAM-leak / transient-list failures
        // previously went silent. Use a weak self capture so the lifecycle
        // service doesn't keep the orchestrator alive after teardown.
        self.embeddingLifecycle.onWarning = { [weak self] message in
            self?.lastInfoMessage = message
        }
    }

    // MARK: - UI Helpers

    /// Set by Watchtower before navigating to a task; consumed by TeamBoardView on appear
    var pendingRoleSelection: String?

    /// Signals that a specific role should be selected when TeamBoardView appears.
    func selectRole(roleID: String) {
        pendingRoleSelection = roleID
    }

    /// Armed by the QuickCapture panel's "New Team..." entry immediately before it
    /// navigates to Settings → Teams; consumed by `TeamEditorView`.
    ///
    /// A flag on this object rather than a `NotificationCenter` post because
    /// `TeamEditorView()` is constructed lazily inside `SettingsView`'s tab switch —
    /// it does not exist in the frame that would post, and `NotificationCenter` has no
    /// replay, so the intent would be dropped. Every *existing* panel→app notification
    /// is received by `MainLayoutView`, which is always mounted; that is what makes the
    /// notification idiom look safer here than it is. `MainLayoutView` is also not a
    /// usable relay: it is a `WindowGroup` root, and the main window can be closed
    /// (no `NSApplicationDelegateAdaptor` anywhere, ⌘W unclaimed) while the panel keeps
    /// working off its process-level Carbon hotkey.
    ///
    /// This works because the orchestrator is the SAME instance in both places — the app
    /// root hands it to `QuickCaptureController.setup` and to the Settings `Window`'s
    /// `.environment`.
    ///
    /// Deliberately in-memory, NOT `@AppStorage`: a persisted intent outlives a
    /// navigation that never completed and then ambushes an unrelated Settings → Teams
    /// visit with an unexplained sheet, possibly days later. A transient navigation
    /// intent is not a setting.
    private(set) var pendingNewTeamSheet = false

    /// Arms the latch. Call BEFORE navigating — window creation and view mount both
    /// happen later on the run loop, so the consume is strictly after this write.
    func requestNewTeamSheet() {
        pendingNewTeamSheet = true
    }

    /// Read-and-clear. Returns `true` exactly once per arm.
    ///
    /// A method rather than the bare `var` + hand-clear that `pendingRoleSelection`
    /// above uses, because this latch is read from two triggers (appear AND change —
    /// the Settings window may already be mounted on the Teams tab, where `.onAppear`
    /// never re-fires) and a bare var is two chances to forget the clear, which leaves
    /// the sheet re-presenting on every later visit.
    ///
    /// Callers must PEEK (`pendingNewTeamSheet`) before consuming and defer while any
    /// other sheet/alert is up: macOS allows one presentation per window, so consuming
    /// into a dropped presentation loses the intent with no way to retry.
    func consumeNewTeamSheetRequest() -> Bool {
        guard pendingNewTeamSheet else { return false }
        pendingNewTeamSheet = false
        return true
    }

    var workFolder: WorkFolderProjection? { snapshot?.workFolder }

    var selectedRunSnapshot: Run? {
        RunService.selectedRunSnapshot(from: activeTask, selectedRunID: selectedRunID)
    }

    /// Resolves the effective team for a task. Pins a started run to its
    /// `Run.teamID` (see `TeamResolution.resolve`). Non-optional convenience /
    /// display resolver: a pin-failure coalesces to `Team.default` and does NOT
    /// surface a diagnostic — this method is called from SwiftUI `body` (7 view
    /// sites), so it MUST NOT mutate observable state (`lastErrorMessage`) during
    /// view evaluation. The LOUD diagnostic is owned by the engine paths that
    /// actually fail the run: `TaskEngineStoreAdapter.resolvedTeam` and
    /// `findOrCreateStep`'s roster-swap guard.
    func resolvedTeam(for task: NTMSTask?) -> Team {
        guard let task else { return workFolder?.activeTeam ?? Team.default }
        switch TeamResolution.resolve(
            task: task,
            teamProvider: { workFolder?.team(withID: $0) },
            activeTeam: workFolder?.activeTeam
        ) {
        case .resolved(let team):
            return team
        case .failed, .noTeam:
            return workFolder?.activeTeam ?? Team.default
        }
    }

    /// True when the team is the pinned team (`runs.last?.teamID`) of any
    /// non-closed task — i.e. deleting it would strand that task's run on a team
    /// that no longer exists. Used to block team deletion.
    ///
    /// Scans the in-memory `tasksIndex` (every task's `TaskSummary`, including
    /// paused/evicted/never-loaded tasks and children), NOT just `loadedTasks` —
    /// `evictIfReclaimable` can drop a paused non-closed task from memory, so a
    /// loaded-only scan would miss it and silently allow the destructive delete.
    /// A summary `status == .done` means closed (a non-chat task only derives
    /// `.done` once `closedAt` is set), so non-`.done` is the "still needs its
    /// team" proxy. No per-task disk I/O.
    func teamIsInUseByActiveRun(_ teamID: NTMSID) -> Bool {
        guard let summaries = snapshot?.tasksIndex.tasks else { return false }
        return summaries.contains { summary in
            // A `.done` task with an ENABLED recurrence will re-run on this team on
            // its next fire — deleting the team now would strand that future run.
            // `toSummary` sets `nextRecurrenceFireAt = isEnabled ? nextFireAt : nil`,
            // so it is non-nil for any enabled recurrence that still has a scheduled
            // fire — INCLUDING one already due but not yet rescheduled (still the safe
            // direction: keep a team that's about to re-run un-deletable). A spent
            // rule self-disables via `TaskRecurrence.reschedule`, nilling it.
            summary.pinnedTeamID == teamID
                && (summary.status != .done || summary.nextRecurrenceFireAt != nil)
        }
    }


    // MARK: - Loaded Task Access

    /// Returns a task by ID — active or background.
    func loadedTask(_ taskID: Int) -> NTMSTask? {
        if taskID == activeTaskID { return activeTask }
        return snapshot?.loadedTasks[taskID]
    }

    /// Removes a background task from the in-memory loaded tasks map.
    func evictLoadedTask(_ taskID: Int) {
        snapshot?.loadedTasks.removeValue(forKey: taskID)
    }

    /// Whether any task engines are currently in the `.running` state.
    var hasRunningTasks: Bool {
        engineState.taskEngineStates.values.contains(.running)
    }

    // MARK: - Private

    func apply(_ snapshot: WorkFolderContext) {
        // Whole-index replacement (folder open/switch, task delete, any path that
        // rebuilds rather than upserts). O(T) once, on a path already O(T).
        taskFacts.replaceAll(with: snapshot.tasksIndex.tasks)
        let previousTaskID = activeTaskID
        let previousFolderID = self.snapshot?.projection.id
        let previousActiveRunID = activeTask?.runs.last?.id
        let previousSelectedRunID = selectedRunID

        // Preserve loadedTasks from the old snapshot — but ONLY within the same
        // work folder. Task IDs are sequential ints per folder, so collisions
        // across folders are the norm: carrying folder A's loaded tasks into
        // folder B's snapshot lets any background write path (status sweep,
        // recurrence reconcile, mutateTask) resolve a colliding ID against the
        // ghost and persist folder A's content into folder B's task.json.
        var newSnapshot = snapshot
        let sameFolder = previousFolderID == newSnapshot.projection.id
        if sameFolder, let oldLoaded = self.snapshot?.loadedTasks {
            newSnapshot.loadedTasks = oldLoaded
        } else if !sameFolder {
            // Same argument, one layer up: the QuickCapture queue and the per-task answer
            // drafts are keyed by the same folder-local task id, but live in a
            // process-global singleton that no folder-lifecycle path was clearing. Left
            // behind, a Supervisor message typed for folder A's task #3 is delivered to
            // folder B's unrelated task #3 — and `tryFlushQueuedMessages` iterates the
            // surviving keys, so merely OPENING a folder woke runs on tasks nobody touched.
            quickCaptureFormState?.discardFolderScopedState()
        }

        // When the active task changes (within the same folder), preserve the
        // old active task in loadedTasks so background engines can still access
        // it via loadedTask(_:).
        if sameFolder,
           let oldTaskID = activeTaskID,
           let oldTask = activeTask,
           oldTaskID != newSnapshot.activeTaskID {
            newSnapshot.loadedTasks[oldTaskID] = oldTask
        }

        self.snapshot = newSnapshot
        self.activeTaskID = newSnapshot.activeTaskID
        self.activeTask = newSnapshot.activeTask
        self.toolDefinitions = newSnapshot.toolDefinitions
        ToolDefinitionRegistry.shared.update(newSnapshot.toolDefinitions)

        // The preserve logic in syncSelectedRunID only makes sense within ONE
        // task. Run IDs are sequential ints per task (0, 1, 2…) AND task IDs are
        // sequential ints per work folder, so on a task switch — or a folder
        // switch where the new folder's active task happens to share the old
        // task's id — the old selection can collide with an unrelated run id in
        // the new task and pin the feed to a stale run (seen as "task ran but
        // the chat shows nothing new"). Reset to the new task's latest run.
        if previousTaskID != newSnapshot.activeTaskID || previousFolderID != newSnapshot.projection.id {
            selectedRunID = newSnapshot.activeTask?.runs.last?.id
            return
        }

        syncSelectedRunID(
            task: newSnapshot.activeTask,
            previousActiveRunID: previousActiveRunID,
            previousSelectedRunID: previousSelectedRunID
        )
    }

    /// The inverse of `apply(_:)`: drop every field that describes a work folder's CONTENTS,
    /// leaving the process holding a `workFolderURL` and nothing loaded.
    ///
    /// Exists for one caller — `openWorkFolder`'s catch. `workFolderURL` is committed before
    /// the open can fail (deliberately: `closeProject` / `resetAllData` rely on it flipping to
    /// default storage as their "no project open" signal), so a failed open used to leave the
    /// process describing TWO folders at once — the new URL beside the previous folder's
    /// snapshot, active task and loaded tasks. Every writer binds those separately:
    /// `mutateWorkFolder` takes `url` from one and `projection` from the other and writes folder
    /// A's teams/settings/state wholesale into folder B's files; `mutateTask` writes folder A's
    /// task into `B/tasks/<same sequential id>/task.json`. That is precisely the collision
    /// `apply(_:)` guards against above — through a hole `apply` cannot cover, because on this
    /// path it never runs.
    ///
    /// Clearing rather than reverting is the honest half: lines 42-56 of `openWorkFolder` have
    /// already stopped the previous folder's engines, scheduler and search index, so "the old
    /// folder is still open" would be a claim about a folder nothing is running against. With
    /// the fields nil, both `mutateWorkFolder` and `mutateTask` short-circuit on their own
    /// guards and no write can be misdirected.
    ///
    /// Lives here, not in the extension, because `activeTaskID` is `private(set)` — its setter
    /// is file-scoped, so the inverse of `apply` has to sit beside `apply`.
    func discardWorkFolderState() {
        // Folder-scoped ids: keeping them would let one folder's task 3 answer
        // for another's, the same class as the QuickCapture cleanup below.
        taskFacts.clear()
        // The Autovisor's four id-keyed sets are the same class and were the sites this
        // guard had not reached (CLAUDE.md #51). A surviving `(3, .completed)` makes the
        // NEXT folder's task 3 read as already-reviewed and silently denies it a pass —
        // and the wake's prune cannot undo that, since a task legitimately sitting at
        // Review is among the still-matching keys it preserves. A stale `seen` id denies
        // the new folder's task 3 its `onTaskCreated` trigger the same way.
        autovisorLastPassAttentionKeys = []
        autovisorNotifiedAttentionKeys = []
        autovisorLoopParkRedelivered = []
        autovisorSeenTaskIDs = []
        snapshot = nil
        activeTaskID = nil
        activeTask = nil
        selectedRunID = nil
        toolDefinitions = []
        ToolDefinitionRegistry.shared.update([])
        // Same reason as `apply`'s `!sameFolder` branch, and the same hole: the
        // folder-local task ids the QuickCapture queue and answer drafts are keyed by
        // belong to a folder that is no longer described by anything here.
        quickCaptureFormState?.discardFolderScopedState()
    }

    /// Update the in-memory snapshot with a modified active task without rebuilding from disk.
    /// This is the fast path for task mutations — only the task and its index entry are updated.
    func applyTaskUpdate(_ task: NTMSTask) {
        let previousActiveRunID = activeTask?.runs.last?.id
        let previousSelectedRunID = selectedRunID

        self.activeTask = task

        guard var snap = snapshot else { return }
        snap.activeTask = task

        // Update index entry. `upsert` keeps the descending-`updatedAt` order without
        // re-sorting the whole index on every task mutation — see `TasksIndex.upsert`.
        upsertTaskSummary(task.toSummary(), in: &snap)

        self.snapshot = snap

        syncSelectedRunID(
            task: task,
            previousActiveRunID: previousActiveRunID,
            previousSelectedRunID: previousSelectedRunID
        )
    }

    /// The ONE way an in-memory index row is written.
    ///
    /// `tasksIndex` and `taskFacts` describe the same rows, so they must move
    /// together or the shell reacts to a fact the index no longer holds. Three
    /// call sites used to spell `snap.tasksIndex.upsert(task.toSummary())`
    /// inline; routing them here is what makes a fourth one impossible to add
    /// without noticing (CLAUDE.md #51).
    ///
    /// It is also the one place a row TRANSITION is observable — synchronously, on both
    /// `mutateTask` branches, with or without a window mounted — which is why an Autovisor
    /// retirement that must not be MISSED is recorded here rather than sampled later by a
    /// wake. See `noteRowLevelsCleared`.
    func upsertTaskSummary(_ summary: TaskSummary, in snap: inout WorkFolderContext) {
        let previousRow = snap.tasksIndex.upsert(summary)
        taskFacts.apply(summary)
        noteRowLevelsCleared(from: previousRow, to: summary)
    }

    private func syncSelectedRunID(
        task: NTMSTask?, previousActiveRunID: Int?, previousSelectedRunID: Int?
    ) {
        guard let task else {
            selectedRunID = nil
            return
        }

        let newActiveRunID = task.runs.last?.id

        // A direct `contains` rather than `Set(task.runs.map(\.id))`: this runs on every
        // active-task mutation (i.e. every LLM message), and the set was allocated — array
        // plus hash table — to answer ONE membership question. `task.runs` grows
        // monotonically for a recurring task (a daily recurrence is ~90 runs a quarter).
        if let previousSelectedRunID,
           task.runs.contains(where: { $0.id == previousSelectedRunID }) {
            if let previousActiveRunID, previousSelectedRunID == previousActiveRunID,
               previousActiveRunID != newActiveRunID
            {
                selectedRunID = newActiveRunID
            } else {
                selectedRunID = previousSelectedRunID
            }
        } else {
            selectedRunID = newActiveRunID
        }
    }

    // MARK: - Team Meetings

    func setActiveMeetingParticipants(_ participantIDs: Set<String>, for taskID: Int) {
        engineState.setMeetingParticipants(participantIDs, for: taskID)
    }

    func clearActiveMeetingParticipants(for taskID: Int) {
        engineState.clearMeetingParticipants(for: taskID)
    }

    nonisolated deinit {}
}

// MARK: - LLMExecutionDelegate Conformance

extension NTMSOrchestrator: LLMExecutionDelegate {}

#if DEBUG
extension NTMSOrchestrator {
    /// Held open by `RunStartOrderingTests` so it can assert what is true at the
    /// navigation boundary — i.e. after `materializeRun` and before `launchRun` has
    /// done anything. Awaited as the first statement of `launchRun`.
    ///
    /// A deterministic seam rather than a wall-clock race, for the same reason
    /// `NTMSRepository._testCreateTaskBeforeSummaryAppend` exists: the window is
    /// shorter than the suspension the assertion itself would take, so "check
    /// quickly and hope" would pass against the very ordering it is meant to pin.
    /// Cleared in the test's `tearDown` — a leaked gate would hang every later suite.
    static var _testRunLaunchGate: (@Sendable () async -> Void)?

    func _testRegisterStepTask(stepID: String, taskID: Int) {
        llmExecutionService._testRegisterStepTask(stepID: stepID, taskID: taskID)
    }

    func _testFinishStepWithWarning(stepID: String, taskID: Int, warning: String) async {
        await llmExecutionService._testFinishStepWithWarning(
            stepID: stepID, taskID: taskID, warning: warning)
    }

    // periphery:ignore - used in #Preview helpers (SidebarView, TeamBoardView+Previews, QuickCapturePanel+Previews)
    func _setActiveTaskID(_ id: Int?) {
        activeTaskID = id
    }
}
#endif

