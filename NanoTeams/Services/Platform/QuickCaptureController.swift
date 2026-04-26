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

    /// In-flight guard for the queue-driven `resumeRun` wake-up. Prevents two
    /// `tryFlush` ticks (e.g. an enqueue immediately followed by an engineState
    /// onChange) from spawning two concurrent `resumeRun(taskID:)` calls before
    /// the first transitions the engine out of `.paused`. Cleared in the
    /// dispatched `Task`'s `defer` so back-to-back callers within the same
    /// in-flight cycle collapse to one resume.
    @ObservationIgnored private var pendingResumeForQueueFlush: Set<Int> = []

    /// Test seam — overrides the `Task { resumeRun }` dispatched by the
    /// `.paused`/`.pending`/`.none` branch of `tryFlushQueuedMessages`. Production
    /// path is `nil`. Tests inject a synchronous closure so the in-flight guard
    /// + branch routing can be exercised without spinning a real engine. Mirrors
    /// the `engineFactory` seam pattern in `NTMSOrchestrator`.
    @ObservationIgnored var resumeRunForTesting: ((Int) -> Void)?

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
        } else {
            Task { await showPanel(withClip: false) }
        }
    }

    /// Toggles the overlay: hides if visible, shows if hidden.
    func togglePanel() {
        if isPanelVisible {
            dismissPanel()
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

        // Resolve mode before clipboard handling so clips go to the right destination
        let resolvedMode = resolveMode()
        let needsAnswerMode: Bool
        if case .supervisorAnswer = resolvedMode { needsAnswerMode = true } else { needsAnswerMode = false }

        if withClip {
            await captureClipboardContent(mode: resolvedMode, needsAnswerMode: needsAnswerMode)
        }

        // Already visible — clip was appended above, bindings update the UI
        guard !isPanelVisible else { return }

        // Detect mode change and rebuild content if needed
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
        capturePanel.showWithAnimation()
        isPanelVisible = true
    }

    /// Hides the overlay. Preserves both task draft and answer drafts across open/close cycles.
    /// Answer-mode state is saved per-task so reopening restores attachments/clips.
    func dismissPanel() {
        panel?.hideWithAnimation()
        isPanelVisible = false
        forceNewTaskMode = false
        if formState.isInAnswerMode {
            formState.exitAnswerMode()
        } else {
            formState.clearAnswerSession()
        }
    }

    /// Rebuilds panel content if visible and mode or active task has changed.
    func refreshPanelIfVisible() {
        guard isPanelVisible else { return }

        // Detect task switch: even if visual mode is the same, the payload/context may differ
        let currentTaskID = store?.activeTaskID
        let taskChanged = currentTaskID != lastRefreshedTaskID
        lastRefreshedTaskID = currentTaskID

        // Navigating INTO a specific task cancels force-new-task mode — the panel should
        // reflect that task's state. Watchtower (currentTaskID == nil) preserves the flag
        // so the new-task form stays visible after `showNewTask()`.
        if taskChanged, currentTaskID != nil {
            forceNewTaskMode = false
        }

        let resolvedMode = resolveMode()
        let newVisualMode = QuickCaptureVisualMode(resolvedMode)

        if newVisualMode != currentVisualMode || taskChanged {
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
    /// Returns `true` if the message was queued (validated non-empty via
    /// `QueuedChatMessage.init?`), `false` if rejected.
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
        // Drive the wake-up immediately so a `.paused` engine doesn't leave the
        // message hanging until the next unrelated `engineState` onChange. Cheap
        // for `.running`/`.needsAcceptance` (default branch is no-op); for
        // `.needsSupervisorInput` and `.paused`/`.pending`/`.none` it triggers the
        // appropriate dispatch path.
        tryFlushQueuedMessages()
        return true
    }

    /// Backstop for the queue — handles the `.needsSupervisorInput` case (primary
    /// consumption happens in `LLMExecutionService.injectQueuedSupervisorMessage`
    /// for `.running` roles). Drains every eligible queued message for the chosen
    /// waiting role into one combined `answerSupervisorQuestion` call (matches the
    /// primary path's drain-all-at-once batching), or discards the entire task's
    /// queue on `.done` / `.failed`. Called from
    /// `MainLayoutView.onChange(of: engineState.taskEngineStates)` — panel-visibility
    /// independent (queue must resolve even when the overlay is closed).
    ///
    /// Terminal-state discard surfaces `store.lastInfoMessage` with a count so users
    /// aren't silently stranded. The terminal paths in practice: non-chat teams finish
    /// their pipeline and reach `.done`; any team can reach `.failed` (LLM/network
    /// errors, or the `TeamEngine+RunLoop` stall detector). Chat-mode teams do not
    /// naturally reach `.done` because `allRolesComplete(isChatMode:)` hard-returns
    /// `false` — chat runs terminate only via `.failed` or user close.
    ///
    /// NOTE: This discards at the **task** level on engine-terminal states only —
    /// it does NOT fire on individual role completion. Queued messages for a
    /// `.done` role stay queued so `restartRole` can deliver them on iteration 1
    /// of the restarted step.
    func tryFlushQueuedMessages() {
        guard let store else { return }
        for taskID in formState.taskIDsWithQueuedMessages {
            switch store.taskEngineStates[taskID] {
            case .needsSupervisorInput:
                Task { @MainActor [weak self] in await self?.flushQueuedChatMessage(taskID: taskID) }
            case .done, .failed:
                let count = formState.queuedMessages(for: taskID).count
                formState.clearQueuedMessages(for: taskID)
                if count > 0 {
                    let reason = store.taskEngineStates[taskID] == .failed ? "failed" : "completed"
                    store.lastInfoMessage = "\(count) queued message(s) discarded — task \(reason)."
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

    /// Dispatches a `resumeRun(taskID:)` for a `.paused`/`.pending`/`.none` engine
    /// when the task has queued messages. Three guards — in priority order:
    ///
    /// 1. **Closed-task discard** — `closedAt != nil` means the task is finalized
    ///    (active-task close is normally caught by `handleActiveTaskClosedAtChanged`,
    ///    but: (a) there's a race when `stopEngine` removes the engine state before
    ///    the `closedAt` onChange fires, and (b) background-task close has no
    ///    closedAt onChange wired). Drop the queue and surface the discard message
    ///    so we don't resurrect a closed task by creating a fresh engine.
    /// 2. **In-flight dedupe** — a single resumeRun per (taskID, in-flight cycle).
    ///    Multiple `tryFlush` ticks can fire before the first resume changes
    ///    engineState (see `pendingResumeForQueueFlush` doc).
    /// 3. **Test seam** — `resumeRunForTesting` short-circuits the `Task` dispatch
    ///    so unit tests can assert call sequencing synchronously.
    private func wakeRunForQueuedMessages(taskID: Int, store: NTMSOrchestrator) {
        if store.loadedTask(taskID)?.closedAt != nil {
            let count = formState.queuedMessages(for: taskID).count
            formState.clearQueuedMessages(for: taskID)
            if count > 0 {
                store.lastInfoMessage = "\(count) queued message(s) discarded — task closed."
            }
            return
        }
        guard !pendingResumeForQueueFlush.contains(taskID) else { return }
        pendingResumeForQueueFlush.insert(taskID)
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
    }

    #if DEBUG
    /// Test-only: clears the in-flight resume guard for a given task, simulating
    /// completion of the production `Task { resumeRun }`. Lets tests verify that
    /// a subsequent `tryFlush` after the prior resume "finishes" can dispatch
    /// another resume.
    func clearPendingResumeForQueueFlushForTesting(taskID: Int) {
        pendingResumeForQueueFlush.remove(taskID)
    }
    #endif

    /// Discards all queued chat messages for the given task. Use on task delete/close
    /// to prevent a stale queue from re-applying to a reincarnated task ID.
    func discardQueuedChatMessage(taskID: Int) {
        formState.clearQueuedMessages(for: taskID)
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

        // answerSupervisorQuestion auto-resumes the run — do NOT call resumeRun separately.
        let delivered = await store.answerSupervisorQuestion(
            stepID: step.id,
            taskID: taskID,
            answer: combinedAnswer,
            attachments: combinedAttachments
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

        let submitAction: () -> Void
        if case .supervisorAnswer = currentMode {
            submitAction = { [weak self] in
                Task { @MainActor in await self?.submitAnswer() }
            }
        } else if case .taskWorking(_, let isChatMode) = currentMode {
            // Chat-mode working lets the user queue a message for the next prompt.
            // Non-chat working is loader-only — submit is disabled.
            submitAction = isChatMode
                ? { [weak self] in self?.submitQueuedMessageFromForm() }
                : {}
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
