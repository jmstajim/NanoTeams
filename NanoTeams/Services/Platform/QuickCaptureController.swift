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
    /// The one production instance, and the one place the two LIVE dependencies are named.
    ///
    /// Both seams default to inert (`InertHotkeyManager`, `InertSelectionCapturer`), so these two
    /// arguments are what make ⌃⌥⌘0 and ⌃⌥⌘K do anything at all. Losing either one is a silent
    /// product failure — the shortcuts simply never fire — which is why both are pinned by
    /// `QuickCaptureSelectionCoverageTests.testDefaultsAreInertAndProductionOverridesThem`.
    static let shared = QuickCaptureController(
        hotkeyManager: GlobalHotkeyManager.shared,
        selectionCapturer: SystemSelectionCapturer()
    )

    // MARK: - Dependencies

    weak var store: NTMSOrchestrator?

    /// NSPanel hosts its own SwiftUI tree; the main WindowGroup's
    /// `.environment(...)` chain does not reach it, so the canonical
    /// `DictationService` is injected here and re-applied in `buildFormView`.
    @ObservationIgnored weak var dictation: DictationService?

    /// `internal` (not `private`) because `+Hotkeys` registers through it.
    @ObservationIgnored let hotkeyManager: any HotkeyManager
    @ObservationIgnored private let modeCoordinator: any QuickCaptureModeCoordinator

    /// `internal` because `+ClipboardHandling` captures through it. Defaults INWARD to
    /// an inert capturer — see `InertSelectionCapturer` for why the live one is named
    /// at the `shared` site instead of being the default.
    @ObservationIgnored let selectionCapturer: any SelectionCapturing

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
    @ObservationIgnored var pendingWorkingMode = false
    @ObservationIgnored var forceNewTaskMode = false
    @ObservationIgnored private var lastRefreshedTaskID: Int?
    /// `QuickCapturePresentationPolicy.renderIdentity` of the mode the hosting view was
    /// last BUILT with — i.e. what is on screen right now, not what we would resolve now.
    /// Written by `updatePanelContent` (the only builder) so the rebuild decision compares
    /// rendered-vs-resolved rather than two independently-maintained opinions.
    @ObservationIgnored private var lastRenderedIdentity: String?
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
        formState: QuickCaptureFormState? = nil,
        selectionCapturer: (any SelectionCapturing)? = nil
    ) {
        self.hotkeyManager = hotkeyManager ?? InertHotkeyManager()
        self.modeCoordinator = modeCoordinator ?? DefaultQuickCaptureModeCoordinator()
        self.formState = formState ?? QuickCaptureFormState()
        self.selectionCapturer = selectionCapturer ?? InertSelectionCapturer()
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
            // `pullKeyBack: true` — this is an explicit request for the panel, and it is
            // reachable from the sidebar `+`, which has just made the MAIN window key. The
            // responder restore itself now lives inside `updatePanelContent`, where every
            // other rebuild path gets it too.
            updatePanelContent(pullKeyBack: true)
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
        switch QuickCapturePresentationPolicy.toggleRoute(
            isPanelVisible: isPanelVisible,
            hasOpenWorkFolder: store?.workFolderURL != nil
        ) {
        case .dismiss:
            dismissPanel()
        case .presentSynchronously:
            presentPanelSync()
        case .bootstrapThenPresent:
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
            await captureClipboardContent(mode: resolveMode())
        }

        presentPanelSync()
    }

    /// Resolves the form's team pin when it has none, through the same
    /// `QuickCaptureFormLogic.resolveSelectedTeam` the view's getter uses — so the
    /// header and the pin can never disagree about which team is selected.
    private func seedSelectedTeamIfNeeded() {
        guard formState.selectedTeamID == nil, let store else { return }
        formState.selectedTeamID = QuickCaptureFormLogic.resolveSelectedTeam(
            selectedTeamID: nil,
            activeTeamID: store.snapshot?.workFolder.activeTeamID,
            availableTeams: store.snapshot?.workFolder.teams ?? []
        )?.id
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

        // This path runs with the panel OFF screen, and it takes the hand-off like any other:
        // ownership says whose content the bucket holds, so reopening onto the SAME task is a
        // no-op (the Drafts-app pattern this form states) while reopening onto another chat
        // task parks the content under the task it was typed for instead of handing it to the
        // arriving one's send button. The old `previousTaskID: nil` opt-out existed because
        // the decision keyed on the previous VISUAL mode, which this path cannot speak for.
        applyAnswerModeTransition(needsAnswerMode: needsAnswerMode, resolvedMode: resolvedMode)
        // Showing the panel IS a resolve — it reads the mode, takes the hand-off and decides on
        // a rebuild — so it leaves the same footprint a refresh leaves. `refreshPanelIfVisible`
        // derives `taskChanged` from this baseline and uses it to cancel `forceNewTaskMode`; with
        // only the refresh recording it, the first refresh after every open compared against
        // whatever the LAST refresh had seen and read a task change that had not happened. The
        // sibling baseline `lastRenderedIdentity` states the same rule for the rebuild half.
        lastRefreshedTaskID = store?.activeTaskID

        let isNewPanel = panel == nil
        let capturePanel = panel ?? createPanel()
        panel = capturePanel
        // Compare what the view RENDERS, not the coarse visual mode. `hide()` is `orderOut`
        // with `isReleasedWhenClosed = false` and `dismissPanel` never nils `panel`, so a reopen
        // re-orders-in the SAME view graph — and under the old `modeChanged` test a second,
        // different supervisor question was "the same mode" and the panel kept showing the first.
        if isNewPanel
            || QuickCapturePresentationPolicy.renderIdentity(of: resolvedMode) != lastRenderedIdentity {
            updatePanelContent()
        }
        // Seed the team pin HERE and not only in the form's `.onAppear`, because that
        // appear does not re-fire on a same-mode reopen: `hide()` is `orderOut` with
        // `isReleasedWhenClosed = false`, and the branch above rebuilds the hosting view
        // only when the panel is new or the visual mode changed. So a panel dismissed
        // and reopened in `.overlay` re-orders-in the SAME view graph.
        //
        // This matters because "New Team..." deliberately releases the pin
        // (`teamSelectionAfterNewTeamNavigation`) before navigating away. Without a
        // re-seed the header still renders correctly — `selectedTeam` is a computed
        // fallback — but `formState.selectedTeamID` stays nil, so no row shows a
        // checkmark and `createTask` forwards a nil `teamID` while the UI claims a team.
        seedSelectedTeamIfNeeded()
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
        // Answer mode saves its draft per task and restores the stashed new-task text.
        // Every OTHER mode keeps what it was holding: a dismiss is neither a submit nor a
        // task switch, and the panel reopens onto the same task.
        //
        // There used to be an `else { formState.clearAnswerSession() }` here. That method's
        // documented job was "saves draft first so it persists across open/close", but the
        // save is gated on `pendingAnswer`, which is non-nil exactly when `isInAnswerMode`
        // is — i.e. exactly when the branch above runs. So on this fork the save could
        // never fire, and what remained was a bare clear of `answerAttachments` /
        // `answerClippedTexts` — the very buckets the chat-working composer renders. The
        // asymmetry was the tell: the typed text survived a dismiss and the attachments
        // beside it did not.
        if formState.isInAnswerMode {
            formState.exitAnswerMode()
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
        let previousTaskID = lastRefreshedTaskID
        let taskChanged = currentTaskID != previousTaskID
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

        // Same comparison as `presentPanelSync`, for the same reason: a second question on
        // the SAME task, or a role handoff inside a running chat team, changes neither the
        // visual mode nor the task id — and both are content the panel prints.
        let contentChanged =
            QuickCapturePresentationPolicy.renderIdentity(of: resolvedMode) != lastRenderedIdentity
        if contentChanged || taskChanged || explicitTaskNavigation {
            let needsAnswerMode = newVisualMode == .answer
            applyAnswerModeTransition(
                needsAnswerMode: needsAnswerMode, resolvedMode: resolvedMode)
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

    /// Which task the live composer content belongs to is read from
    /// `QuickCaptureFormState.answerFieldsOwnerTaskID` — a recorded claim, not the panel's
    /// previous surface. Chat-mode `.taskWorking` and `.supervisorAnswer` bind the same live
    /// fields and the send button reads them against `store.activeTaskID`, so whenever the panel
    /// re-resolves onto another task the content in them still belongs to the earlier one;
    /// filing or submitting it under the arriving task is how a message typed for A gets queued
    /// to, or answers, B.
    private func applyAnswerModeTransition(
        needsAnswerMode: Bool,
        resolvedMode: QuickCaptureMode
    ) {
        if needsAnswerMode && !formState.isInAnswerMode {
            if case .supervisorAnswer(let payload) = resolvedMode {
                // Chat-mode `.taskWorking` and `.supervisorAnswer` bind the composer to the
                // same three live fields (answerText / answerAttachments / answerClippedTexts).
                // When the LLM finishes thinking and asks a question, snapshot whatever the
                // user was composing so `enterAnswerMode`'s has-draft branch loads it back
                // instead of clearing.
                //
                // No clear afterwards: `enterAnswerMode` writes all three fields on both of its
                // branches, so clearing here would be a redundant step whose only remaining
                // justification — stashing an empty `savedSupervisorTask` — went away with the
                // stash itself when the task composer got its own text field.
                //
                // Gated on the bucket having an OWNER rather than on the previous visual mode
                // and the arriving payload's chat-ness: what has to be saved is content the
                // bucket is already holding for some task, which is exactly what an owner
                // means. The old pair of conditions dropped it whenever the panel had taken a
                // detour, and again whenever the arriving question happened to be non-chat.
                if let owner = formState.answerFieldsOwnerTaskID {
                    // Under the task the content BELONGS to. Filing it under `payload.taskID`
                    // when the panel had just followed a task switch loaded A's half-typed
                    // message straight back as the draft answer to B's question.
                    formState.captureLiveComposerAsAnswerDraft(taskID: owner)
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
        } else if case .reassign(let from, let to) = QuickCapturePresentationPolicy
            .chatComposerHandoff(
                liveFieldsOwnerTaskID: formState.answerFieldsOwnerTaskID,
                resolvedMode: resolvedMode,
                newTaskID: store?.activeTaskID)
        {
            // The fourth quadrant — neither entering nor leaving answer mode. Two running chat
            // tasks share one composer, and nothing above matches a working→working switch, so
            // the half-typed message for A stayed in the fields the send button now reads
            // against B. Same save-then-load shape as the answer-mode task switch beside it.
            formState.captureLiveComposerAsAnswerDraft(taskID: from)
            formState.answerText = ""
            formState.answerAttachments = []
            formState.answerClippedTexts = []
            formState.restoreAnswerDraftToLiveFields(taskID: to)
        }

        // Whatever branch ran, an arriving chat-working composer now holds this task's content:
        // record the claim where the binding happens. First arrival (no owner yet) is the case
        // that matters — without it the bucket has no owner until an answer mode claims one, and
        // the hand-off above has nothing to compare against on the very first task switch.
        //
        // An UNCLAIMED bucket also loads this task's saved draft. Three of the four ways to
        // arrive here already did: leaving answer mode restores (the branch above), and a
        // hand-off from another chat task restores after parking. The fourth — arriving with no
        // owner at all — did not, and it is the ordinary one: `dismissPanel` in answer mode saves
        // the draft and releases the bucket, so reopening onto the same task's chat composer,
        // which binds the very same three fields, showed the user an empty box where their text
        // had been. Retyping then left two copies, and the next entry into answer mode destroyed
        // one of them.
        //
        // Safe rather than merely convenient: the only two writers that release the bucket
        // (`exitAnswerMode`, `discardFolderScopedState`) clear its three fields in the same
        // breath, so unclaimed means provably empty and the load can displace nothing. An owner
        // that is neither nil nor this task cannot reach here — that is exactly what the
        // `.reassign` branch above consumes.
        if case .taskWorking(_, let isChatMode) = resolvedMode, isChatMode,
           let taskID = store?.activeTaskID {
            if formState.answerFieldsOwnerTaskID == nil {
                formState.restoreAnswerDraftToLiveFields(taskID: taskID)
            } else {
                formState.claimAnswerFields(for: taskID)
            }
        }
    }

    /// The panel reported it went off screen by a route we did not initiate
    /// (AppKit `orderOut`, e.g. the Escape fallback when no host is wired).
    /// Named rather than inlined into `createPanel` so the controller-side
    /// effect is reachable without constructing and showing a real NSPanel.
    func handlePanelHidden() {
        isPanelVisible = false
    }

    /// Panel saw a focusable field but AppKit refused `makeFirstResponder`
    /// across every retry — the caret never landed and keystrokes will be
    /// dropped. Surface so the user isn't stuck typing into the void.
    ///
    /// Named for the same reason as `handlePanelHidden`: this banner is the
    /// user's ONLY signal for the silent-caret bug, so its wording has to be
    /// assertable without a live panel.
    func handleFocusRestorationFailure() {
        store?.lastErrorMessage = "Quick Capture could not focus the input field. Click into the field again."
    }

    private func createPanel() -> QuickCapturePanel {
        let newPanel = QuickCapturePanel()
        newPanel.onPanelHidden = { [weak self] in
            self?.handlePanelHidden()
        }
        newPanel.onFocusRestorationFailed = { [weak self] in
            self?.handleFocusRestorationFailure()
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
    ///
    /// - Parameter pullKeyBack: whether the caller is an explicit user request for the
    ///   panel (⌃⌥⌘0 / the sidebar `+`), in which case the panel takes key focus back from
    ///   whatever holds it. Passive rebuilds — an engine transition, a post-submit mode
    ///   flip — leave key where it is; the user may be typing in the main window, and the
    ///   responder is restored either way.
    func updatePanelContent(pullKeyBack: Bool = false) {
        // panel / store / dictation are all prerequisites for building the form
        // view. `dictation` is folded into the same graceful skip as panel/store
        // (not a hard precondition) so tests that legitimately drive the panel
        // path without a DictationService — which SFSpeechRecognizer can't safely
        // construct on CI (CLAUDE.md #47) — no-op instead of crashing the process.
        // In production `setup(store:dictation:)` sets all three at launch, so this
        // never skips; an async `showPanel` Task firing before setup would crash
        // here purely as a test artifact.
        guard let panel, let store, let dictation else { return }

        let currentMode: QuickCaptureMode
        if pendingWorkingMode {
            pendingWorkingMode = false
            currentMode = .taskWorking(roleName: "", isChatMode: true)
        } else {
            currentMode = resolveMode()
        }

        let formView = QuickCaptureFormView(
            mode: currentMode,
            formState: formState,
            onSubmit: submitAction(for: currentMode),
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
        lastRenderedIdentity = QuickCapturePresentationPolicy.renderIdentity(of: currentMode)

        // `setContent` builds a NEW `NSHostingView` and assigns it to `contentView`, which
        // takes the old subtree — and the AppKit first responder with it — out of the
        // window. Only two things ever put a caret back: `show(expectsFocusableField:)`,
        // which runs on the present path only, and this call. Exactly ONE of the three
        // composers self-heals (`autofocusOnAppear: true`, task creation); the answer and
        // chat-queue composers do not, so a rebuild into either left the panel accepting no
        // keystrokes — and silently, since the "could not focus" banner is wired to the
        // retry loop that never ran.
        //
        // Gated on the panel being on screen (`show` owns the present path) and on the mode
        // actually rendering a field: `refocusInputField` hardcodes `expectsFocusableField:
        // true`, so running it against the loader-only working mode would exhaust the retry
        // and fire that banner for a panel that legitimately has nothing to focus.
        if isPanelVisible, currentMode.expectsFocusableField {
            panel.refocusInputField(pullKeyBack: pullKeyBack)
        }
    }

    /// The closure the panel's send button is wired to for `mode`.
    ///
    /// `internal` and named rather than built inline inside `updatePanelContent`, because
    /// there it is captured into the SwiftUI view and unreachable: all four bodies were
    /// dead, and a body wired to the wrong destination is silent — the send button either
    /// does nothing or sends to the wrong place, with no error either way.
    ///
    /// The routing itself is `QuickCapturePresentationPolicy.submitAction(for:)`; this is
    /// only the application of it.
    func submitAction(for mode: QuickCaptureMode) -> @MainActor @Sendable () -> Void {
        switch QuickCapturePresentationPolicy.submitAction(for: mode) {
        case .submitSupervisorAnswer:
            return { [weak self] in
                Task { @MainActor in await self?.submitAnswer() }
            }
        case .queueChatMessage:
            return { [weak self] in self?.submitQueuedMessageFromForm() }
        case .disabled:
            return {}
        case .createTask:
            return { [weak self] in
                Task { @MainActor in await self?.createTask() }
            }
        }
    }

    // MARK: - Test Helpers

    #if DEBUG
    /// Flush tasks spawned by `tryFlushQueuedMessages`, retained so a test can JOIN the drain
    /// instead of polling for a side effect.
    ///
    /// Polling cannot express what these tests assert. `flushQueuedChatMessage` pops the queue
    /// SYNCHRONOUSLY (its documented atomicity contract) and writes the embed-failure banner only
    /// after `await answerSupervisorQuestion`, which itself suspends twice — a detached JSON
    /// encode + atomic file write, then `resumeRun`. So every signal a poll can watch is produced
    /// on the near side of the suspension while the asserted value lands on the far side:
    /// `!hasQueuedMessage` flips at the pop, and `supervisorAnswer` is committed inside the first
    /// `mutateTask`, with all of `resumeRun` still to run. Measured on macOS 26: at wait-exit the
    /// queue was empty, `supervisorAnswer` was set, the banner was nil — and it arrived **6.4 ms
    /// later**, above the tests' own 5 ms poll granularity. The local pass was marginal luck; the
    /// CI runner lost the same race (`testBackstopDrain_reportsFilesItCouldNotEmbed`, 2026-08-15).
    ///
    /// A join is not merely more reliable, it is the only thing that works for the COUNTER-test:
    /// `testBackstopDrain_saysNothingWhenEveryFileEmbedded` asserts an ABSENCE, and you cannot
    /// poll for one — under the race it passed by observing nothing, i.e. it guarded nothing.
    var _testPendingFlushTasks: [Task<Void, Never>] = []

    /// Drains in a LOOP rather than awaiting the batch once: a flush wakes a run, and that state
    /// change can re-enter `tryFlushQueuedMessages` and append more tasks while we are awaiting
    /// the first batch.
    func _testAwaitPendingFlushes() async {
        while !_testPendingFlushTasks.isEmpty {
            let batch = _testPendingFlushTasks
            _testPendingFlushTasks = []
            for task in batch { await task.value }
        }
    }
    #endif

    /// The one call site's view of the retention above: a no-op in release, so the flush stays
    /// fire-and-forget in production and neither the call site nor a release build carries a
    /// dangling binding.
    #if DEBUG
    func retainFlushTaskForTests(_ task: Task<Void, Never>) { _testPendingFlushTasks.append(task) }
    #else
    func retainFlushTaskForTests(_ task: Task<Void, Never>) {}
    #endif

    #if DEBUG
    func _testResolveMode() -> QuickCaptureMode { resolveMode() }
    func _testEnterAnswerMode(_ mode: QuickCaptureMode) {
        if case .supervisorAnswer(let payload) = mode {
            formState.enterAnswerMode(payload: payload)
        }
    }
    func _testExitAnswerMode() { formState.exitAnswerMode() }
    var _testIsInAnswerMode: Bool { formState.isInAnswerMode }
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

    /// Full transient-state reset for test isolation. `QuickCaptureController.shared`
    /// is a process-global singleton; without this, state a sibling test class leaves
    /// on it — most importantly a `panel` created by `presentPanelSync` (`dismissPanel`
    /// reuses, never nils, the NSPanel) — contaminates the next class. A leaked panel
    /// with `store != nil`, `dictation == nil` (weak, unset in tests) crashes
    /// `updatePanelContent`'s setup precondition. Call at the top of every QuickCapture
    /// test's setUp.
    func _testReset() {
        panel = nil
        isPanelVisible = false
        pendingWorkingMode = false
        forceNewTaskMode = false
        lastRefreshedTaskID = nil
        isTaskSelected = false
        store = nil
        dictation = nil
        pendingResumeForQueueFlush.removeAll()
        failedResumeAttemptedMessageIDs.removeAll()
        chatStartAttemptedMessageIDs.removeAll()
        resumeRunForTesting = nil
        startRunForTesting = nil
        formState._testReset()
    }
    #endif
    nonisolated deinit {}
}
