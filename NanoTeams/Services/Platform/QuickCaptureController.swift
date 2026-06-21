import SwiftUI

// MARK: - Quick Capture Controller

/// Coordinator for Quick Capture — owns the floating panel lifecycle and the
/// routing between new-task / supervisor-answer / working modes.
///
/// The controller is split across focused extension files (project idiom,
/// mirroring `NTMSOrchestrator` / `LLMExecutionService`):
/// - `+Hotkeys` — global hotkey registration (`setup`)
/// - `+TaskCreation` — `createTask` / `submitAnswer` / `cancelDraft`
/// - `+ClipboardHandling` — selection capture + attachment staging
/// - `+QueueManagement` — the Supervisor chat-message queue control plane
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

    /// `internal` (not `private`) because `+Hotkeys` registers through it.
    @ObservationIgnored let hotkeyManager: any HotkeyManager
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
    /// `internal` so `+TaskCreation` can flip into working mode post-submit.
    @ObservationIgnored var currentVisualMode: QuickCaptureVisualMode = .newTask
    @ObservationIgnored var pendingWorkingMode = false
    @ObservationIgnored var forceNewTaskMode = false
    @ObservationIgnored private var lastRefreshedTaskID: Int?
    /// `internal` so `+Hotkeys.setup` can flip the one-shot guard.
    @ObservationIgnored var didSetupHotkeys = false

    /// In-flight guard for the queue-driven wake-ups (`resumeRun` AND the
    /// `.done`-chat `startRun`). Prevents two `tryFlush` ticks (e.g. an enqueue
    /// immediately followed by an engineState onChange) from spawning two
    /// concurrent wake calls before the first transitions the engine. Cleared in
    /// the dispatched `Task`'s `defer` so back-to-back callers within the same
    /// in-flight cycle collapse to one wake. Shared across both wake modes — a
    /// task can only be in one wake at a time, so a racing `.done`-start and a
    /// flickering `.failed`-resume dedupe against each other too.
    ///
    /// `internal` (with the two give-up maps below) so the `+QueueManagement`
    /// extension owns the queue control plane while the storage lives here.
    @ObservationIgnored var pendingResumeForQueueFlush: Set<Int> = []

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
    @ObservationIgnored var failedResumeAttemptedMessageIDs: [Int: Set<UUID>] = [:]

    /// `.done`-chat counterpart of `failedResumeAttemptedMessageIDs`: one `startRun`
    /// attempt per message ID. The fresh run drains the queue on iteration 1, so the
    /// only way a message survives a completed attempt is a consume-side persistence
    /// failure that re-prepended the batch — bound that to one full LLM pass per
    /// message instead of a wake-loop. Same set algebra, same self-pruning.
    @ObservationIgnored var chatStartAttemptedMessageIDs: [Int: Set<UUID>] = [:]

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

    /// `internal` so `+TaskCreation` can rebuild the panel content after a submit.
    func updatePanelContent() {
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
        // The panel hosts SwiftUI in a standalone NSHostingView, outside the app's
        // scene roots — so carry the terminal mono font + toggle style explicitly,
        // mirroring what NanoTeamsApp applies to each scene.
        .fontDesign(.monospaced)
        .toggleStyle(.terminal)

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
}
