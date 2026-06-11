import Carbon
import SwiftUI

// MARK: - Quick Capture Controller

/// Coordinator for Quick Capture — owns the floating panel lifecycle, hotkey
/// registration, and the routing between new-task / supervisor-answer / working modes.
///
/// Form state (title, supervisorTask, attachments, clipped texts) lives in `QuickCaptureFormState`
/// and persists between open/close cycles (Drafts-app pattern). Mode resolution lives
/// in `QuickCaptureModeCoordinator`. Hotkey registration is abstracted via `HotkeyManager`.
///
/// When the active task has a pending Supervisor question, the overlay switches to
/// "answer mode" — showing the LLM's response and an answer input instead of the
/// new-task form. The task draft is preserved and restored when answer mode exits.
@Observable @MainActor
final class QuickCaptureController {
    static let shared = QuickCaptureController()

    // MARK: - Dependencies

    weak var store: NTMSOrchestrator?

    /// NSPanel hosts its own SwiftUI tree; the main WindowGroup's
    /// `.environment(...)` chain does not reach it, so the canonical
    /// `DictationService` is injected here and re-applied in `buildFormView`.
    @ObservationIgnored weak var dictation: DictationService?

    @ObservationIgnored private let hotkeyManager: any HotkeyManager
    @ObservationIgnored private let modeCoordinator: any QuickCaptureModeCoordinator

    /// Shared form state observed by `QuickCaptureFormView`.
    let formState: QuickCaptureFormState

    /// Set by MainLayoutView when the sidebar selection changes.
    /// Answer mode activates only when a task (not Watchtower) is selected.
    var isTaskSelected = false

    /// When enabled, the overlay stays open after submitting an answer in chat-mode tasks.
    var keepOpenInChat: Bool {
        didSet { UserDefaults.standard.set(keepOpenInChat, forKey: UserDefaultsKeys.quickCaptureKeepOpenInChat) }
    }

    /// When enabled, file attachment contents are read and embedded directly into the prompt
    /// instead of being passed as file paths for the LLM to read via `read_file`.
    /// Reads from `StoreConfiguration` via the store.
    var embedFilesInPrompt: Bool {
        store?.configuration.embedFilesInPrompt ?? false
    }

    // MARK: - Panel State

    private(set) var isPanelVisible = false
    @ObservationIgnored private var panel: QuickCapturePanel?
    @ObservationIgnored private var currentVisualMode: QuickCaptureVisualMode = .newTask
    @ObservationIgnored private var pendingWorkingMode = false
    @ObservationIgnored private var forceNewTaskMode = false
    @ObservationIgnored private var lastRefreshedTaskID: Int?
    @ObservationIgnored private var didSetupHotkeys = false

    /// In-flight guard for the queue-driven wake-ups (`resumeRun` AND the
    /// `.done`-chat `startRun`). Prevents two `tryFlush` ticks (e.g. an enqueue
    /// immediately followed by an engineState onChange) from spawning two
    /// concurrent wake calls before the first transitions the engine. Cleared in
    /// the dispatched `Task`'s `defer` so back-to-back callers within the same
    /// in-flight cycle collapse to one wake. Shared across both wake modes — a
    /// task can only be in one wake at a time, so a racing `.done`-start and a
    /// flickering `.failed`-resume dedupe against each other too.
    @ObservationIgnored private var pendingResumeForQueueFlush: Set<Int> = []

    /// One-shot guard for `.failed`-engine queue resumes, keyed by the specific queued
    /// MESSAGE IDs a `resumeRun` was already attempted for. A `.failed` task routes a
    /// queued message to `resumeRun` (which revives transiently-failed steps). But if a
    /// resume completes and the engine lands back at `.failed` with the message still
    /// unconsumed — no revivable step — re-resuming would loop forever
    /// (wake→terminal→onChange→wake…). Tracking the attempted message IDs (not a
    /// per-task bool) makes the guard robust two ways: (1) a brand-new message — from
    /// ANY enqueue path, including the Autovisor's `message_task` which appends
    /// directly, not via `queueChatMessage` — has an ID not yet attempted, so it always
    /// earns a fresh attempt; (2) the transient `.running` that a wake sets before the
    /// run re-terminates can't reset the guard (only the terminal arms touch the maps).
    /// Consumed IDs prune themselves: each tick intersects with the live queue. Give up
    /// only when every still-queued message has already been attempted and no attempt
    /// is in-flight.
    ///
    /// DELIBERATELY SEPARATE from `chatStartAttemptedMessageIDs`: the two wake
    /// mechanisms operate on different state (revive an existing run vs create a fresh
    /// one), so a spent `.failed`-resume attempt is no evidence that a `.done`-chat
    /// start would also fail — sharing one map would prematurely discard a message on
    /// a `.failed`→`.done` transition without the second mechanism ever being tried.
    @ObservationIgnored private var failedResumeAttemptedMessageIDs: [Int: Set<UUID>] = [:]

    /// `.done`-chat counterpart of `failedResumeAttemptedMessageIDs`: one `startRun`
    /// attempt per message ID. The fresh run drains the queue on iteration 1, so the
    /// only way a message survives a completed attempt is a consume-side persistence
    /// failure that re-prepended the batch — bound that to one full LLM pass per
    /// message instead of a wake-loop. Same set algebra, same self-pruning.
    @ObservationIgnored private var chatStartAttemptedMessageIDs: [Int: Set<UUID>] = [:]

    /// Test seam — overrides the `Task { resumeRun }` dispatched by the
    /// `.paused`/`.pending`/`.none`/`.failed` branches of `tryFlushQueuedMessages`.
    /// Production path is `nil`. Tests inject a synchronous closure so the in-flight
    /// guard + branch routing can be exercised without spinning a real engine. Mirrors
    /// the `engineFactory` seam pattern in `NTMSOrchestrator`. The in-flight flag is
    /// intentionally NOT cleared after the closure (mirrors the in-flight `Task`);
    /// tests simulate completion via `clearPendingResumeForQueueFlushForTesting`.
    @ObservationIgnored var resumeRunForTesting: ((Int) -> Void)?

    /// Test seam — same contract as `resumeRunForTesting`, for the `Task { startRun }`
    /// dispatched by the `.done`-chat branch (`QueueWakeMode.start`).
    @ObservationIgnored var startRunForTesting: ((Int) -> Void)?

    // MARK: - Hotkey IDs

    private static let openHotkeyID: UInt32 = 1
    private static let clipHotkeyID: UInt32 = 2

    // MARK: - Init

    init(
        hotkeyManager: (any HotkeyManager)? = nil,
        modeCoordinator: (any QuickCaptureModeCoordinator)? = nil,
        formState: QuickCaptureFormState? = nil
    ) {
        self.hotkeyManager = hotkeyManager ?? GlobalHotkeyManager.shared
        self.modeCoordinator = modeCoordinator ?? DefaultQuickCaptureModeCoordinator()
        self.formState = formState ?? QuickCaptureFormState()
        let key = UserDefaultsKeys.quickCaptureKeepOpenInChat
        self.keepOpenInChat = UserDefaults.standard.object(forKey: key) != nil
            ? UserDefaults.standard.bool(forKey: key)
            : true
    }

    // MARK: - Setup

    /// Registers global hotkeys. Call once from NanoTeamsApp on appear.
    func setup(store: NTMSOrchestrator, dictation: DictationService) {
        self.store = store
        self.dictation = dictation
        guard !didSetupHotkeys else { return }
        didSetupHotkeys = true

        // Ctrl+Opt+Cmd+0 — open overlay (no clip)
        // Key code 29 = '0', modifiers: cmdKey | optionKey | controlKey
        hotkeyManager.register(
            id: Self.openHotkeyID,
            keyCode: 29,
            modifiers: UInt32(cmdKey | optionKey | controlKey),
            handler: { [weak self] in
                self?.togglePanel()
            }
        )

        // Ctrl+Opt+Cmd+K — capture selection (files → attachments, text → clips) + open overlay
        // Key code 40 = 'k'
        hotkeyManager.register(
            id: Self.clipHotkeyID,
            keyCode: 40,
            modifiers: UInt32(cmdKey | optionKey | controlKey),
            handler: { [weak self] in
                Task { @MainActor in
                    await self?.showPanel(withClip: true)
                }
            }
        )
    }

    // MARK: - Panel Lifecycle

    /// Opens the overlay in new-task mode, bypassing answer/working detection.
    func showNewTask() {
        if formState.isInAnswerMode { formState.exitAnswerMode() }
        forceNewTaskMode = true
        NotificationCenter.default.post(name: .navigateToWatchtower, object: nil)
        if isPanelVisible {
            currentVisualMode = .newTask
            updatePanelContent()
            // `updatePanelContent` rebuilds the NSHostingView, which drops the
            // AppKit first responder; the panel's retry loop reacquires it
            // (SwiftUI `@FocusState` inside `NSHostingView` is unreliable).
            panel?.refocusInputField()
        } else {
            Task { await showPanel(withClip: false) }
        }
    }

    /// Toggles the overlay: hides if visible, shows if hidden.
    ///
    /// The warm path (work folder already open, no clipboard capture) runs
    /// synchronously to avoid the Task-hop dispatch latency. The cold path
    /// awaits `bootstrapDefaultStorageIfNeeded` first.
    func togglePanel() {
        if isPanelVisible {
            dismissPanel()
            return
        }
        if store?.workFolderURL != nil {
            presentPanelSync()
        } else {
            Task { await showPanel(withClip: false) }
        }
    }

    /// Shows the floating overlay panel.
    /// - Parameter withClip: If `true`, captures selected content (files or text) from the frontmost app first.
    func showPanel(withClip: Bool) async {
        // Ensure default storage exists if no project is open
        if store?.workFolderURL == nil {
            await store?.bootstrapDefaultStorageIfNeeded()
        }

        if withClip {
            // Resolve mode once so clips go to the right destination
            // (answer vs new-task fields). `presentPanelSync` resolves
            // again — that call is sub-ms.
            let preResolvedMode = resolveMode()
            let preNeedsAnswerMode: Bool
            if case .supervisorAnswer = preResolvedMode { preNeedsAnswerMode = true } else { preNeedsAnswerMode = false }
            await captureClipboardContent(mode: preResolvedMode, needsAnswerMode: preNeedsAnswerMode)
        }

        presentPanelSync()
    }

    /// Synchronous panel-show pipeline. Shared by the warm `togglePanel` path
    /// (called directly) and the async `showPanel` path (called after
    /// bootstrap + optional clipboard capture).
    private func presentPanelSync() {
        let resolvedMode = resolveMode()
        let needsAnswerMode: Bool
        if case .supervisorAnswer = resolvedMode { needsAnswerMode = true } else { needsAnswerMode = false }

        // Already visible — bindings update the UI directly.
        guard !isPanelVisible else { return }

        let newVisualMode = QuickCaptureVisualMode(resolvedMode)
        let modeChanged = newVisualMode != currentVisualMode
        applyAnswerModeTransition(needsAnswerMode: needsAnswerMode, resolvedMode: resolvedMode)
        currentVisualMode = newVisualMode

        let isNewPanel = panel == nil
        let capturePanel = panel ?? createPanel()
        panel = capturePanel
        if isNewPanel || modeChanged {
            updatePanelContent()
        }
        // `expectsFocusableField` is passed as a parameter (not a panel property)
        // so it locks in at show-time — a concurrent re-show can't race the
        // in-flight retry through a mutable flag. Loader-only working mode is
        // the single legitimate "no field" case; every other mode renders a
        // composer whose absence would be a real form-rendering regression.
        capturePanel.show(expectsFocusableField: resolvedMode.expectsFocusableField)
        isPanelVisible = true
    }

    /// Hides the overlay. Preserves both task draft and answer drafts across open/close cycles.
    /// Answer-mode state is saved per-task so reopening restores attachments/clips.
    func dismissPanel() {
        panel?.hide()
        isPanelVisible = false
        forceNewTaskMode = false
        if formState.isInAnswerMode {
            formState.exitAnswerMode()
        } else {
            formState.clearAnswerSession()
        }
    }

    /// Rebuilds panel content if visible and mode or active task has changed.
    ///
    /// Pass `explicitTaskNavigation: true` when the caller is an explicit user
    /// navigation INTO a task (sidebar click). Passive refreshes (engine ticks,
    /// status changes, Watchtower nav, close-at observers) use the default.
    func refreshPanelIfVisible(explicitTaskNavigation: Bool = false) {
        guard isPanelVisible else { return }

        let currentTaskID = store?.activeTaskID
        let taskChanged = currentTaskID != lastRefreshedTaskID
        lastRefreshedTaskID = currentTaskID

        // Two triggers for clearing forceNewTaskMode:
        //   (a) taskChanged — passive refresh detected the active task changed.
        //   (b) explicitTaskNavigation — explicit re-selection covers the case
        //       where `switchTask(X)` short-circuits because activeTaskID is
        //       already X, so taskChanged stays false.
        // Watchtower (currentTaskID == nil) preserves the flag so the new-task
        // form stays visible.
        if currentTaskID != nil, taskChanged || explicitTaskNavigation {
            forceNewTaskMode = false
        }

        let resolvedMode = resolveMode()
        let newVisualMode = QuickCaptureVisualMode(resolvedMode)

        if newVisualMode != currentVisualMode || taskChanged || explicitTaskNavigation {
            let needsAnswerMode = newVisualMode == .answer
            applyAnswerModeTransition(needsAnswerMode: needsAnswerMode, resolvedMode: resolvedMode)
            currentVisualMode = newVisualMode
            updatePanelContent()
        }
    }

    // MARK: - Task Creation

    /// Creates a task from the current form state and starts execution.
    func createTask() async {
        guard let store else { return }

        // Check if the selected team is chat mode before creating
        let teamID = formState.selectedTeamID ?? store.snapshot?.workFolder.activeTeamID
        let team: Team?
        if let teamID {
            team = store.snapshot?.workFolder.teams.first { $0.id == teamID }
        } else {
            team = store.snapshot?.workFolder.activeTeam
        }
        // Generated Team template is a placeholder — treat as non-chat so Quick Capture
        // dismisses and navigates to the task after submission.
        let isChatMode = (team?.templateID == "generated") ? false : (team?.isChatMode ?? false)

        // Build the supervisor task text with optional file embedding
        let built = AnswerTextBuilder.build(
            text: formState.supervisorTask,
            clips: formState.clippedTexts,
            attachments: formState.attachments,
            embedFiles: embedFilesInPrompt
        )
        if !built.failedFiles.isEmpty {
            store.lastErrorMessage = "Could not embed \(built.failedFiles.count) file(s) as text: \(built.failedFiles.joined(separator: ", ")). They may be binary files."
        }
        // When clips were provided to the builder, they are always embedded into the text
        let remainingClips = formState.clippedTexts.isEmpty ? formState.clippedTexts : [String]()

        if await store.submitQuickCaptureForm(
            title: formState.title,
            supervisorTask: built.answer,
            teamID: formState.selectedTeamID,
            clippedTexts: remainingClips,
            attachments: formState.attachments,
            draftID: formState.draftID
        ) != nil {
            formState.clearTaskDraft()
            NotificationCenter.default.post(name: .navigateToActiveTask, object: nil)
            if keepOpenInChat && isChatMode {
                // Task just created — force working mode, refreshPanelIfVisible will update later
                forceNewTaskMode = false
                isTaskSelected = true
                pendingWorkingMode = true
                currentVisualMode = .working
                updatePanelContent()
            } else {
                dismissPanel()
            }
        }
    }

    // MARK: - Supervisor Answer

    /// Submits the supervisor answer. In chat mode with `keepOpenInChat`, stays open and shows loader.
    func submitAnswer() async {
        guard let payload = formState.pendingAnswer, let store else { return }
        let answer = formState.supervisorTask.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasClips = !formState.answerClippedTexts.isEmpty
        guard !answer.isEmpty || !formState.answerAttachments.isEmpty || hasClips else { return }

        let result = AnswerTextBuilder.build(
            text: answer,
            clips: formState.answerClippedTexts,
            attachments: formState.answerAttachments,
            embedFiles: embedFilesInPrompt
        )
        let fullAnswer = result.answer
        if !result.failedFiles.isEmpty {
            store.lastErrorMessage = "Could not embed \(result.failedFiles.count) file(s) as text: \(result.failedFiles.joined(separator: ", ")). They may be binary files."
        }

        let isChatMode = payload.isChatMode

        let success = await store.answerSupervisorQuestion(
            stepID: payload.stepID,
            taskID: payload.taskID,
            answer: fullAnswer,
            attachments: formState.answerAttachments
        )
        guard success else { return }

        // Discard the per-task draft on successful submit
        formState.discardAnswerDraft(taskID: payload.taskID)
        formState.supervisorTask = ""
        formState.answerAttachments = []
        formState.answerClippedTexts = []

        if keepOpenInChat && isChatMode {
            formState.exitAnswerMode()
            currentVisualMode = .working
            updatePanelContent()
        } else {
            formState.exitAnswerMode()
            dismissPanel()
        }
    }

    /// Queues the currently-typed composer message for the active task's next
    /// supervisor-input prompt. Called from the Quick Capture overlay when the LLM
    /// is still streaming (`.taskWorking` mode with chat-mode team) and the user
    /// wants to line up their next message without waiting for a question.
    /// Silently no-ops when no task is active (guarded upstream by `canSubmit`);
    /// callers rely on `queueChatMessage` to accept/reject the payload.
    ///
    /// Targets the same role the QuickCapture title displays — i.e. the first
    /// running step's role. This keeps title and queue recipient in lockstep
    /// (multi-role chat teams like Quest Party show one role at a time and
    /// auto-switch as the engine progresses; submit-time lookup follows that
    /// switch). If no running step exists during a transient state transition,
    /// `targetRoleID` falls back to `nil` and the message is drained tier-2
    /// (untargeted) on the next backstop fire.
    func submitQueuedMessageFromForm() {
        guard let store else {
            return
        }
        guard let taskID = store.activeTaskID else {
            store.lastErrorMessage = "No active task — open or create a task first."
            return
        }
        let targetRoleID = store.loadedTask(taskID).flatMap(Self.firstRunningStepRoleID(in:))
        let queued = queueChatMessage(
            text: formState.supervisorTask,
            attachments: formState.answerAttachments,
            clippedTexts: formState.answerClippedTexts,
            taskID: taskID,
            targetRoleID: targetRoleID
        )
        guard queued else { return }
        formState.supervisorTask = ""
        formState.answerAttachments = []
        formState.answerClippedTexts = []
    }

    /// The role ID of the first running step in `task`'s latest run, if any.
    /// Single source of truth used by both `QuickCaptureModeCoordinator` (to
    /// build the `.taskWorking` title) and `submitQueuedMessageFromForm` (to
    /// target the queue at the same role). Without this shared call site, a
    /// future tweak to either site could silently desync title vs. queue target.
    static func firstRunningStepRoleID(in task: NTMSTask) -> String? {
        task.runs.last?.steps.first(where: { $0.status == .running })?.effectiveRoleID
    }

    // MARK: - Chat Queue

    /// Stores a message for `taskID`. There are **two** consumption paths and the
    /// queue is the shared storage for both:
    /// - Primary (`.running` roles): `LLMExecutionService.injectQueuedSupervisorMessage`
    ///   pops eligible messages at the top of each `runOneLLMToolIteration`, so
    ///   the LLM sees them on its next request without needing to call
    ///   `ask_supervisor` first.
    /// - Backstop (`.needsSupervisorInput`): `tryFlushQueuedMessages` below
    ///   delivers via `answerSupervisorQuestion` when the role has already paused
    ///   waiting for an answer. Either path pops from the same queue, so no
    ///   double-delivery.
    /// `targetRoleID` narrows delivery to a specific role (delivered only when
    /// THAT role's step iterates or asks for input); `nil` delivers on whichever
    /// role's step consumes first.
    /// Queued messages for a role that completes (`.done`) stay in the queue —
    /// restarting the role (`NTMSOrchestrator.restartRole`) resets the step's
    /// session, so iteration 1 of the restarted step satisfies the injection
    /// hook's guard and delivers them.
    /// Returns `true` if the message was queued AND survived the immediate flush;
    /// `false` if rejected (empty payload via `QueuedChatMessage.init?`) or
    /// synchronously discarded by the flush (non-chat completed task, closed
    /// task) — callers keep the draft and must not show a "queued" confirmation.
    @discardableResult
    func queueChatMessage(
        text: String,
        attachments: [StagedAttachment],
        clippedTexts: [String],
        taskID: Int,
        targetRoleID: String? = nil
    ) -> Bool {
        guard let message = QuickCaptureFormState.QueuedChatMessage(
            text: text,
            attachments: attachments,
            clippedTexts: clippedTexts,
            targetRoleID: targetRoleID
        ) else {
            return false
        }
        formState.appendQueuedMessage(message, for: taskID)
        // Delegation-interrupt path: when the message is targeted at a role
        // that's currently mid-`delegate_to_team`, the role's tool loop is
        // suspended on `awaitTaskTerminalState` — the normal queue
        // consumption paths (next-iteration injection, supervisor-input
        // backstop) can't fire because the role isn't iterating and its
        // engine isn't transitioning. Wake the handler instead so it can
        // pause the child engine and surface the message text inside a
        // `paused_by_supervisor` success envelope on the parent role's next
        // iteration. This is the "team is looping, stop it" feedback loop.
        if let role = targetRoleID,
           let store,
           store.notifyDelegationInterrupt(
               parentTaskID: taskID,
               parentRoleID: role,
               text: text
           )
        {
            // The interrupt embedded `text` in the paused envelope returned
            // to the role. Drop the queue entry now — without this the
            // role's next iteration would hit `injectQueuedSupervisorMessage`
            // and consume the same message a second time, delivering the
            // Supervisor's guidance twice (once via the envelope, once as a
            // fresh user turn). Skip `tryFlushQueuedMessages` since the
            // role is mid-delegation, not in any state the flush paths
            // handle.
            formState.removeQueuedMessage(withID: message.id, for: taskID)
            return true
        }
        // Drive the wake-up immediately so a `.paused` engine doesn't leave the
        // message hanging until the next unrelated `engineState` onChange. Cheap
        // for `.running`/`.needsAcceptance` (default branch is no-op); for
        // `.needsSupervisorInput` and `.paused`/`.pending`/`.none` it triggers the
        // appropriate dispatch path.
        tryFlushQueuedMessages()
        // Honest return: the SYNCHRONOUS part of the flush can discard this very
        // message (non-chat `.done` arm; closed-task discard in
        // `wakeRunForQueuedMessages`). Callers use the Bool to clear their draft
        // and show a "queued" confirmation banner — returning `true` after a
        // discard would destroy the draft and overwrite the discard banner with a
        // lie. The async consumption paths (`.needsSupervisorInput` flush Task,
        // resume/start wakes) can't pop before this returns (no await between
        // their dispatch and here), so "still queued" is exactly "not discarded".
        return formState.queuedMessages(for: taskID).contains { $0.id == message.id }
    }

    /// Backstop for the queue — handles the `.needsSupervisorInput` case (primary
    /// consumption happens in `LLMExecutionService.injectQueuedSupervisorMessage`
    /// for `.running` roles). Drains every eligible queued message for the chosen
    /// waiting role into one combined `answerSupervisorQuestion` call (matches the
    /// primary path's drain-all-at-once batching). Called from
    /// `MainLayoutView.onChange(of: engineState.taskEngineStates)` — panel-visibility
    /// independent (queue must resolve even when the overlay is closed).
    ///
    /// `.done` splits by team kind. A non-chat pipeline that reached `.done` is
    /// genuinely finished — discard the queue with a banner (reopening is
    /// `restartRole`'s job). A CHAT task at `.done` is just an ended turn/pass:
    /// chat-mode advisory steps DO reach `.done` via `markChatModeAdvisoryStepDone`
    /// (`attemptAdvisoryAutoFinish` after 3 no-tool turns; historically also the
    /// Autovisor's `wait_for_events`, which now parks instead) — so a queued
    /// message wakes the task with a FRESH `startRun` (`resumeRun` would re-enter
    /// the all-terminal run, execute no step, and bounce straight back to `.done`).
    /// The fresh run's step has `session == nil`, so the iteration-1 injection
    /// gate passes and the queue drains.
    ///
    /// Terminal-state discard surfaces `store.lastInfoMessage` with a count so users
    /// aren't silently stranded. `.failed` (any team) and `.done`-chat each apply an
    /// attempted-message-IDs give-up so an unconsumable queue can't wake-loop — via
    /// SEPARATE maps, because the two wake mechanisms are independent (see the
    /// `failedResumeAttemptedMessageIDs` doc).
    ///
    /// NOTE: This discards at the **task** level on engine-terminal states only —
    /// it does NOT fire on individual role completion. Queued messages for a
    /// `.done` role stay queued so `restartRole` can deliver them on iteration 1
    /// of the restarted step.
    func tryFlushQueuedMessages() {
        guard let store else { return }
        // Prune both give-up attempted-IDs maps to tasks that still have queued
        // messages, so entries for deleted/consumed tasks don't accumulate. Safe:
        // the `.failed` and `.done`-chat arms only read entries for tasks present
        // in `taskIDsWithQueuedMessages` (kept here).
        if !failedResumeAttemptedMessageIDs.isEmpty {
            failedResumeAttemptedMessageIDs = failedResumeAttemptedMessageIDs.filter {
                formState.hasQueuedMessage(for: $0.key)
            }
        }
        if !chatStartAttemptedMessageIDs.isEmpty {
            chatStartAttemptedMessageIDs = chatStartAttemptedMessageIDs.filter {
                formState.hasQueuedMessage(for: $0.key)
            }
        }
        for taskID in formState.taskIDsWithQueuedMessages {
            switch store.taskEngineStates[taskID] {
            case .needsSupervisorInput:
                Task { @MainActor [weak self] in await self?.flushQueuedChatMessage(taskID: taskID) }
            case .done:
                if Self.isChatModeTask(taskID, store: store) {
                    // Chat-mode `.done` is an ended turn, not a finished pipeline —
                    // a queued message continues the chat via a fresh run (drained
                    // on iteration 1). Same give-up shape as `.failed` (own map) so a
                    // run that completes WITHOUT consuming the queue (persistence
                    // failure re-prepends the batch) can't wake-loop LLM passes.
                    let queuedIDs = Set(formState.queuedMessages(for: taskID).map(\.id))
                    let attempted = (chatStartAttemptedMessageIDs[taskID] ?? []).intersection(queuedIDs)
                    let allAlreadyAttempted = !queuedIDs.isEmpty && queuedIDs.isSubset(of: attempted)
                    if allAlreadyAttempted, !pendingResumeForQueueFlush.contains(taskID) {
                        formState.clearQueuedMessages(for: taskID)
                        chatStartAttemptedMessageIDs[taskID] = nil
                        store.lastInfoMessage = "\(queuedIDs.count) queued message(s) discarded — the chat couldn't be restarted."
                    } else {
                        chatStartAttemptedMessageIDs[taskID] = attempted.union(queuedIDs)
                        wakeRunForQueuedMessages(taskID: taskID, store: store, mode: .start)
                    }
                } else {
                    // A completed non-chat task is reopened via `restartRole`, not by
                    // a stray message — discard the queue and surface the count so
                    // the user isn't silently stranded.
                    failedResumeAttemptedMessageIDs[taskID] = nil
                    chatStartAttemptedMessageIDs[taskID] = nil
                    let count = formState.queuedMessages(for: taskID).count
                    formState.clearQueuedMessages(for: taskID)
                    if count > 0 {
                        store.lastInfoMessage = "\(count) queued message(s) discarded — task completed."
                    }
                }
            case .failed:
                // First send → attempt a resume: `resumeRun` revives transiently-failed
                // steps (retry, conversation intact) and the queue drains on the revived
                // step's first iteration. But if every queued message has ALREADY had an
                // attempt that completed (not in-flight) and the engine is STILL `.failed`,
                // the run had no revivable step — resuming again would wake-loop
                // (resume→re-fail→onChange→resume…) and the messages would never be
                // consumed. Discard honestly instead (restores the pre-change "task failed"
                // feedback). Keyed by message ID so a brand-new message (any enqueue path)
                // always earns its own attempt, and the transient `.running` of a doomed
                // resume can't reset the guard. Prune to the live queue so consumed IDs drop.
                let queuedIDs = Set(formState.queuedMessages(for: taskID).map(\.id))
                let attempted = (failedResumeAttemptedMessageIDs[taskID] ?? []).intersection(queuedIDs)
                let allAlreadyAttempted = !queuedIDs.isEmpty && queuedIDs.isSubset(of: attempted)
                if allAlreadyAttempted, !pendingResumeForQueueFlush.contains(taskID) {
                    formState.clearQueuedMessages(for: taskID)
                    failedResumeAttemptedMessageIDs[taskID] = nil
                    if !queuedIDs.isEmpty {
                        store.lastInfoMessage = "\(queuedIDs.count) queued message(s) discarded — task failed and couldn't be retried."
                    }
                } else {
                    failedResumeAttemptedMessageIDs[taskID] = attempted.union(queuedIDs)
                    wakeRunForQueuedMessages(taskID: taskID, store: store)
                }
            case .paused, .pending, .none:
                // Wake the run so the primary path (`injectQueuedSupervisorMessage`)
                // can drain the queue on the next tool-loop iteration. Without this,
                // the queue silently waits for an unrelated `engineState` onChange
                // (the user-reported "messages just sit there after restart" bug).
                wakeRunForQueuedMessages(taskID: taskID, store: store)
            case .running, .needsAcceptance:
                continue
            }
        }
    }

    /// How a queue-driven wake revives the task.
    /// `.resume` — `resumeRun`: paused/pending/failed runs with a revivable step.
    /// `.start` — `startRun`: chat-mode tasks whose run ended `.done`. `resumeRun`
    /// is useless there — it re-enters the same all-terminal run, never executes a
    /// step, and flips straight back to `.done` (the engine's chat auto-complete
    /// arm), wake-looping via the onChange it triggers. A FRESH run's step has
    /// `session == nil`, so the iteration-1 injection gate passes and the queue
    /// drains — the proven `sendMessageToAutovisor` pattern.
    enum QueueWakeMode { case resume, start }

    /// Dispatches a wake (`resumeRun` or `startRun`, per `mode`) for an engine
    /// whose task has queued messages. Three guards — in priority order:
    ///
    /// 1. **Closed-task discard** — `closedAt != nil` means the task is finalized
    ///    (active-task close is normally caught by `handleActiveTaskClosedAtChanged`,
    ///    but: (a) there's a race when `stopEngine` removes the engine state before
    ///    the `closedAt` onChange fires, and (b) background-task close has no
    ///    closedAt onChange wired). Drop the queue and surface the discard message
    ///    so we don't resurrect a closed task by creating a fresh engine. The
    ///    `.start` path re-checks AFTER loading the task: `startRun` has NO closed
    ///    guard and `createNewRun` CLEARS `closedAt`, so waking an unloaded closed
    ///    background task (sync check nil-soft) would silently REOPEN it.
    /// 2. **In-flight dedupe** — a single wake per (taskID, in-flight cycle).
    ///    Multiple `tryFlush` ticks can fire before the first wake changes
    ///    engineState (see `pendingResumeForQueueFlush` doc).
    /// 3. **Test seam** — `resumeRunForTesting`/`startRunForTesting` short-circuit
    ///    the `Task` dispatch so unit tests can assert call sequencing synchronously.
    private func wakeRunForQueuedMessages(
        taskID: Int, store: NTMSOrchestrator, mode: QueueWakeMode = .resume
    ) {
        if store.loadedTask(taskID)?.closedAt != nil {
            discardQueueForClosedTask(taskID: taskID, store: store)
            return
        }
        guard !pendingResumeForQueueFlush.contains(taskID) else { return }
        pendingResumeForQueueFlush.insert(taskID)
        switch mode {
        case .resume:
            if let resume = resumeRunForTesting {
                // Test path: the in-flight flag is intentionally NOT cleared after
                // the closure — that mirrors production semantics where the flag
                // stays set while the dispatched `Task` is in flight. Tests that
                // need to simulate "Task finished, ready for next resume" call
                // `clearPendingResumeForQueueFlushForTesting(taskID:)` explicitly.
                resume(taskID)
                return
            }
            Task { @MainActor [weak self] in
                defer { self?.pendingResumeForQueueFlush.remove(taskID) }
                await self?.store?.resumeRun(taskID: taskID)
            }
        case .start:
            if let start = startRunForTesting {
                start(taskID)
                return
            }
            Task { @MainActor [weak self] in
                defer { self?.pendingResumeForQueueFlush.remove(taskID) }
                await self?.performStartWake(taskID: taskID)
            }
        }
    }

    /// Body of the `.start` wake's dispatched Task — extracted (mirrors
    /// `flushQueuedChatMessage`) so the async path is directly testable; the
    /// `startRunForTesting` seam bypasses it. Re-checks the task AFTER loading:
    /// `startRun` has NO closed guard and `createNewRun` CLEARS `closedAt`, so
    /// waking an unloaded closed background task (the sync pre-check is nil-soft)
    /// would silently REOPEN it. The load itself must be bound explicitly — a
    /// failed load (task deleted concurrently, unreadable task.json) would make
    /// `loadedTask(taskID)?.closedAt == nil` vacuously true and start a run
    /// against a phantom task; instead surface the error and keep the queue for
    /// a later tick.
    func performStartWake(taskID: Int) async {
        guard let store else { return }
        await store.ensureTaskLoaded(taskID)
        guard let task = store.loadedTask(taskID) else {
            // No startRun ran — this was NOT a real attempt, but the `.done`-chat
            // arm stamped `chatStartAttemptedMessageIDs` BEFORE dispatching us.
            // Un-stamp so the next tick genuinely retries; leaving the stamp
            // would discard the queue with a misattributed "chat couldn't be
            // restarted" banner right after promising "kept in queue".
            chatStartAttemptedMessageIDs[taskID] = nil
            store.lastErrorMessage =
                "Couldn't load task #\(taskID) to deliver queued message(s) — kept in queue."
            return
        }
        guard task.closedAt == nil else {
            discardQueueForClosedTask(taskID: taskID, store: store)
            return
        }
        await store.startRun(taskID: taskID)
    }

    /// Shared closed-task discard for the wake paths: drop the queue and surface
    /// the count so the user isn't silently stranded (and a closed task is never
    /// resurrected by a stray message).
    private func discardQueueForClosedTask(taskID: Int, store: NTMSOrchestrator) {
        let count = formState.queuedMessages(for: taskID).count
        formState.clearQueuedMessages(for: taskID)
        if count > 0 {
            store.lastInfoMessage = "\(count) queued message(s) discarded — task closed."
        }
    }

    /// Chat-mode lookup that works for unloaded background tasks: prefers the
    /// loaded task (authoritative — `generatedTeam.isChatMode` dominates), falls
    /// back to the tasks-index summary (`TaskSummary.isChatMode`). Defaults to
    /// `false` when neither source knows the task, preserving the non-chat
    /// discard behavior.
    static func isChatModeTask(_ taskID: Int, store: NTMSOrchestrator) -> Bool {
        if let task = store.loadedTask(taskID) { return task.isChatMode }
        return store.snapshot?.tasksIndex.tasks.first(where: { $0.id == taskID })?.isChatMode ?? false
    }

    #if DEBUG
    /// Test-only: clears the in-flight resume guard for a given task, simulating
    /// completion of the production `Task { resumeRun }`. Lets tests verify that
    /// a subsequent `tryFlush` after the prior resume "finishes" can dispatch
    /// another resume.
    func clearPendingResumeForQueueFlushForTesting(taskID: Int) {
        pendingResumeForQueueFlush.remove(taskID)
    }

    /// Test-only: whether the `.failed`-resume give-up map still holds an entry for
    /// `taskID`. Lets tests assert the map is pruned for tasks with no queued messages.
    func _testHasFailedResumeAttempted(taskID: Int) -> Bool {
        failedResumeAttemptedMessageIDs[taskID] != nil
    }

    /// Test-only sibling for the `.done`-chat give-up map.
    func _testHasChatStartAttempted(taskID: Int) -> Bool {
        chatStartAttemptedMessageIDs[taskID] != nil
    }
    #endif

    /// Discards all queued chat messages for the given task. Use on task delete/close
    /// to prevent a stale queue from re-applying to a reincarnated task ID.
    func discardQueuedChatMessage(taskID: Int) {
        formState.clearQueuedMessages(for: taskID)
        failedResumeAttemptedMessageIDs[taskID] = nil
        chatStartAttemptedMessageIDs[taskID] = nil
    }

    // MARK: - MainLayoutView onChange Handlers
    //
    // Extracted from `MainLayoutView.onChange` blocks so the wiring is unit-testable
    // without mounting a SwiftUI view. `MainLayoutView` still owns the `.onChange`
    // declarations but delegates the body to these methods.

    /// Called when `engineState.taskEngineStates` changes. Refreshes the panel (for
    /// live mode transitions) and drives the queue flush. Two concerns, one entry
    /// point so `MainLayoutView` only has to wire one observer.
    func handleEngineStateChanged() {
        refreshPanelIfVisible()
        tryFlushQueuedMessages()
    }

    /// Called when `store.activeTask?.closedAt` changes. When the task becomes closed
    /// (`closedAt` transitions from `nil` to non-nil), discards any queued messages.
    /// Redundant with terminal-state discard in `tryFlushQueuedMessages`, but covers
    /// the edge case where `closedAt` is set before the engine state transitions to
    /// `.done` — without it a just-closed task briefly retains its queue.
    func handleActiveTaskClosedAtChanged(newValue: Date?, taskID: Int?) {
        guard newValue != nil, let taskID else { return }
        discardQueuedChatMessage(taskID: taskID)
    }

    /// Drains every eligible queued message for the chosen waiting role into
    /// ONE combined `answerSupervisorQuestion` call. Mirrors the primary path's
    /// drain-all semantics in `NTMSOrchestrator.consumeQueuedSupervisorMessage`
    /// — eliminates the previous drip-pattern where messages dribbled out one
    /// per `engineState` transition (and could stall entirely when SwiftUI's
    /// `onChange` coalesced rapid `.needsSupervisorInput` re-entries or the
    /// `TeamEngine` same-state guard suppressed `onStateChanged`).
    ///
    /// Atomicity contract (matches primary path):
    /// 1. Pop every collected message id synchronously BEFORE any `await`. A
    ///    concurrent `flushQueuedChatMessage` invocation triggered by another
    ///    rapid state flip would otherwise see the same messages and double-deliver.
    /// 2. On `answerSupervisorQuestion` failure (attachment finalize, missing step,
    ///    etc.), re-insert popped messages at the queue **head** via
    ///    `prependQueuedMessages` — preserves FIFO under concurrent additions
    ///    (a message queued during the await would otherwise push the failed
    ///    batch behind it).
    private func flushQueuedChatMessage(taskID: Int) async {
        guard let store,
              let task = store.loadedTask(taskID),
              let run = task.runs.last
        else { return }

        let waitingSteps = run.steps.filter { $0.status == .needsSupervisorInput }
        guard !waitingSteps.isEmpty else { return }

        let queue = formState.queuedMessages(for: taskID)
        guard let picked = Self.collectQueuedMessagesForFlush(
            queue: queue,
            waitingStepRoleIDs: waitingSteps.map(\.effectiveRoleID)
        ) else { return }
        guard let step = waitingSteps.first(where: { $0.effectiveRoleID == picked.stepRoleID })
        else { return }

        // ATOMIC RESERVE — pop every collected id synchronously before any await.
        var popped: [QuickCaptureFormState.QueuedChatMessage] = []
        for id in picked.messageIDs {
            if let msg = formState.popFirstQueuedMessage(for: taskID, matching: { $0.id == id }) {
                popped.append(msg)
            }
        }
        guard !popped.isEmpty else { return }

        // Build each message's body and join with a single newline (matching the
        // primary path). No `Supervisor:` prefix here — the backstop delivers
        // through `answerSupervisorQuestion`, which routes via the `ask_supervisor`
        // tool-result path; LLM attribution is intrinsic.
        var bodies: [String] = []
        var combinedAttachments: [StagedAttachment] = []
        for msg in popped {
            let built = AnswerTextBuilder.build(
                text: msg.text,
                clips: msg.clippedTexts,
                attachments: msg.attachments,
                embedFiles: embedFilesInPrompt
            )
            bodies.append(built.answer)
            combinedAttachments.append(contentsOf: msg.attachments)
        }
        let combinedAnswer = bodies.joined(separator: "\n")

        // Attribution for the resolved-answer badge: auto only when EVERY drained
        // message was authored by an automated supervisor (the Autovisor's
        // `message_task`) — any human content in the batch makes it a human answer.
        let allAutomated = popped.allSatisfy(\.isFromAutomatedSupervisor)

        // answerSupervisorQuestion auto-resumes the run — do NOT call resumeRun separately.
        let delivered = await store.answerSupervisorQuestion(
            stepID: step.id,
            taskID: taskID,
            answer: combinedAnswer,
            attachments: combinedAttachments,
            isAutoAnswer: allAutomated
        )
        if !delivered {
            // Re-insert at HEAD (not append) so FIFO holds even if new messages
            // were queued during the await.
            formState.prependQueuedMessages(popped, for: taskID)
            store.lastErrorMessage = (store.lastErrorMessage ?? "Message delivery failed.")
                + " — \(popped.count) queued message(s) kept; retry after resolving the issue."
        }
    }

    // MARK: - Cancel

    func cancelDraft() {
        if let payload = formState.pendingAnswer {
            // Answer mode: discard staged directory and per-task draft
            store?.discardStagedDraft(draftID: formState.draftID)
            formState.discardAnswerDraft(taskID: payload.taskID)
            formState.supervisorTask = ""
            formState.answerAttachments = []
            formState.answerClippedTexts = []
            formState.exitAnswerMode()
        } else {
            // Task mode: original behavior
            let draftToCleanup = formState.draftID
            store?.discardStagedDraft(draftID: draftToCleanup)
            formState.clearTaskDraft()
        }
        dismissPanel()
    }

    // MARK: - Mode Resolution

    private func resolveMode() -> QuickCaptureMode {
        let activeTask = store?.activeTask
        let engineState: TeamEngineState? = activeTask.flatMap { store?.taskEngineStates[$0.id] }
        return modeCoordinator.resolveMode(
            isTaskSelected: isTaskSelected,
            activeTask: activeTask,
            engineState: engineState,
            activeTeam: store?.resolvedTeam(for: activeTask),
            forceNewTaskMode: forceNewTaskMode
        )
    }

    // MARK: - Private Helpers

    private func applyAnswerModeTransition(needsAnswerMode: Bool, resolvedMode: QuickCaptureMode) {
        if needsAnswerMode && !formState.isInAnswerMode {
            if case .supervisorAnswer(let payload) = resolvedMode {
                // Chat-mode `.taskWorking` and `.supervisorAnswer` bind the composer to the
                // same three live fields (supervisorTask / answerAttachments / answerClippedTexts).
                // When the LLM finishes thinking and asks a question, snapshot whatever the
                // user was composing so `enterAnswerMode`'s has-draft branch loads it back
                // instead of clearing. Gated on `currentVisualMode == .working` to avoid
                // capturing stale `.newTask` content (composer there binds to a different
                // attachments field, so live `answerAttachments` is empty anyway, but
                // `supervisorTask` may legitimately hold a new-task draft we must not hijack)
                // and on `payload.isChatMode` since non-chat working has no composer.
                if currentVisualMode == .working && payload.isChatMode {
                    formState.captureLiveComposerAsAnswerDraft(taskID: payload.taskID)
                    // Clear live fields so `enterAnswerMode`'s `savedSupervisorTask` stash
                    // captures empty — not the chat-working content we just persisted to
                    // the draft. Otherwise `submitAnswer`'s post-submit `exitAnswerMode`
                    // would restore the just-sent text into the composer (regression
                    // observed: "queued message stays after submit"). The draft load
                    // inside `enterAnswerMode` repopulates these from the saved draft.
                    formState.supervisorTask = ""
                    formState.answerAttachments = []
                    formState.answerClippedTexts = []
                }
                formState.enterAnswerMode(payload: payload)
            }
        } else if !needsAnswerMode && formState.isInAnswerMode {
            formState.exitAnswerMode()
            // Symmetric restore: returning to chat-mode `.taskWorking` for the active task
            // reloads the draft `exitAnswerMode` just saved. No-op when no draft exists, so
            // a fresh transition with empty composer stays empty.
            if case .taskWorking(_, let isChatMode) = resolvedMode,
               isChatMode,
               let taskID = store?.activeTaskID {
                formState.restoreAnswerDraftToLiveFields(taskID: taskID)
            }
        } else if needsAnswerMode, case .supervisorAnswer(let payload) = resolvedMode {
            // Already in answer mode — task switch: save old draft, load new
            if let oldPayload = formState.pendingAnswer, oldPayload.taskID != payload.taskID {
                formState.switchAnswerTask(from: oldPayload.taskID, to: payload)
            } else {
                formState.updateAnswerPayload(payload)
            }
        }
    }

    private func captureClipboardContent(mode: QuickCaptureMode, needsAnswerMode: Bool) async {
        ClipboardCaptureService.requestAccessibilityIfNeeded()
        let workFolderRoot = store?.hasRealWorkFolder == true ? store?.workFolderURL : nil
        let captured = await ClipboardCaptureService.captureSelection(workFolderRoot: workFolderRoot)

        if needsAnswerMode, case .supervisorAnswer = mode {
            stageCapturedContent(captured, to: formState.draftID, answerMode: true)
        } else {
            stageCapturedContent(captured, to: formState.draftID, answerMode: false)
        }
    }

    private func stageCapturedContent(
        _ captured: ClipboardCaptureResult,
        to draftID: UUID,
        answerMode: Bool
    ) {
        if !captured.fileURLs.isEmpty, let store {
            var stagedCount = 0
            for url in captured.fileURLs {
                if let staged = store.stageAttachment(url: url, draftID: draftID) {
                    if answerMode {
                        if !formState.answerAttachments.contains(staged) {
                            formState.answerAttachments.append(staged)
                            stagedCount += 1
                        }
                    } else {
                        if !formState.attachments.contains(staged) {
                            formState.attachments.append(staged)
                            stagedCount += 1
                        }
                    }
                }
            }
            if stagedCount < captured.fileURLs.count {
                let skipped = captured.fileURLs.count - stagedCount
                store.lastErrorMessage = "\(skipped) of \(captured.fileURLs.count) files could not be attached."
            }
        } else if let text = captured.text, !text.isEmpty {
            if answerMode {
                formState.answerClippedTexts.append(text)
            } else {
                formState.clippedTexts.append(text)
            }
        }
    }

    private func createPanel() -> QuickCapturePanel {
        let newPanel = QuickCapturePanel()
        newPanel.onPanelHidden = { [weak self] in
            self?.isPanelVisible = false
        }
        newPanel.onFocusRestorationFailed = { [weak self] in
            // Panel saw a focusable field but AppKit refused
            // `makeFirstResponder` across every retry — the caret never
            // landed and keystrokes will be dropped. Surface so the user
            // isn't stuck typing into the void.
            self?.store?.lastErrorMessage = "Quick Capture could not focus the input field. Click into the field again."
        }
        // AppKit-side Escape route. `cancelDraft` performs the staged-attachment
        // cleanup before calling `dismissPanel`, so we host this here rather
        // than via a SwiftUI hidden Cancel button — that pattern's `.background
        // { Button(...) }` wrapper made the composer re-evaluate per CA frame
        // during NSScrollView scroll (CLAUDE.md Swift Style #50).
        newPanel.onCancelKeyPressed = { [weak self] in
            self?.cancelDraft()
        }
        return newPanel
    }

    private func updatePanelContent() {
        guard let panel, let store else { return }

        let currentMode: QuickCaptureMode
        if pendingWorkingMode {
            pendingWorkingMode = false
            currentMode = .taskWorking(roleName: "", isChatMode: true)
        } else {
            currentMode = resolveMode()
        }

        let submitAction: @MainActor @Sendable () -> Void
        if case .supervisorAnswer = currentMode {
            submitAction = { [weak self] in
                Task { @MainActor in await self?.submitAnswer() }
            }
        } else if case .taskWorking(_, let isChatMode) = currentMode {
            // Chat-mode working lets the user queue a message for the next prompt.
            // Non-chat working is loader-only — submit is disabled.
            if isChatMode {
                submitAction = { [weak self] in self?.submitQueuedMessageFromForm() }
            } else {
                submitAction = {}
            }
        } else {
            submitAction = { [weak self] in
                Task { @MainActor in await self?.createTask() }
            }
        }

        guard let dictation else {
            preconditionFailure("QuickCaptureController.setup(store:dictation:) must run before the panel is shown.")
        }

        let formView = QuickCaptureFormView(
            mode: currentMode,
            formState: formState,
            onSubmit: submitAction,
            onCancel: { [weak self] in self?.cancelDraft() }
        )
        .environment(store)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .environment(dictation)

        panel.setContent(formView)
    }

    // MARK: - Test Helpers

    #if DEBUG
    func _testResolveMode() -> QuickCaptureMode { resolveMode() }
    func _testEnterAnswerMode(_ mode: QuickCaptureMode) {
        if case .supervisorAnswer(let payload) = mode {
            formState.enterAnswerMode(payload: payload)
        }
    }
    func _testExitAnswerMode() { formState.exitAnswerMode() }
    var _testIsInAnswerMode: Bool { formState.isInAnswerMode }
    var _testSavedSupervisorTask: String? { formState._testSavedSupervisorTask }
    var _testForceNewTaskMode: Bool {
        get { forceNewTaskMode }
        set { forceNewTaskMode = newValue }
    }
    var _testIsPanelVisible: Bool {
        get { isPanelVisible }
        set { isPanelVisible = newValue }
    }
    var _testLastRefreshedTaskID: Int? {
        get { lastRefreshedTaskID }
        set { lastRefreshedTaskID = newValue }
    }
    /// Access to the underlying panel for wiring tests
    /// (`QuickCaptureControllerWiringTests` — assert
    /// `show(expectsFocusableField:)` is called with the value derived from
    /// the resolved mode).
    var _testPanel: QuickCapturePanel? { panel }
    /// Drives the synchronous show pipeline from a test, bypassing the async
    /// `showPanel`/`togglePanel` paths' clipboard capture and hotkey wiring.
    func _testPresentPanelSync() { presentPanelSync() }
    #endif
    nonisolated deinit {}

    // MARK: - Backstop Priority (pure, unit-testable)

    /// Collects every deliverable queued message for the `.needsSupervisorInput`
    /// backstop path in priority order. Mirrors the primary path's drain-all
    /// semantics in `NTMSOrchestrator.consumeQueuedSupervisorMessage` — one
    /// combined Supervisor turn per backstop fire instead of dripping one
    /// message per `engineState` transition.
    ///
    /// Tier priority (matches the primary path):
    /// - **Tier 1** — role-targeted messages whose target role is currently
    ///   waiting, FIFO within the tier. The first such message determines the
    ///   recipient role; subsequent tier-1 messages targeted at the *same* role
    ///   join the batch, while messages targeted at other waiting roles stay
    ///   queued for their own backstop fire.
    /// - **Tier 2** — untargeted (Team) messages join the same batch as the
    ///   tier-1 winner's role (FIFO). If no tier-1 messages match, the oldest
    ///   untargeted message picks the first waiting role and drains all
    ///   untargeted messages into that batch.
    ///
    /// Returns the chosen recipient `stepRoleID` and an ordered `[UUID]` to pop
    /// in sequence. Returns `nil` when nothing is deliverable to the current
    /// waiting set. Pure — no I/O, no main-actor dependency — so backstop
    /// priority is trivially unit-testable without an engine.
    static func collectQueuedMessagesForFlush(
        queue: [QuickCaptureFormState.QueuedChatMessage],
        waitingStepRoleIDs: [String]
    ) -> (stepRoleID: String, messageIDs: [UUID])? {
        guard !waitingStepRoleIDs.isEmpty else { return nil }

        // Find the first role-targeted message whose target is waiting — that
        // role becomes the recipient. Targeted messages whose target is NOT
        // waiting are skipped (they stay queued for their own backstop fire).
        let pickedRoleID: String? = queue.lazy
            .compactMap { msg -> String? in
                guard let target = msg.targetRoleID,
                      waitingStepRoleIDs.contains(target) else { return nil }
                return target
            }
            .first ?? (queue.contains(where: { $0.targetRoleID == nil }) ? waitingStepRoleIDs.first : nil)

        guard let roleID = pickedRoleID else { return nil }

        // Tier 1 first (role-targeted to roleID, FIFO), then tier 2 (untargeted, FIFO).
        let targeted = queue.compactMap { $0.targetRoleID == roleID ? $0.id : nil }
        let untargeted = queue.compactMap { $0.targetRoleID == nil ? $0.id : nil }
        let ids = targeted + untargeted
        guard !ids.isEmpty else { return nil }
        return (roleID, ids)
    }
}
