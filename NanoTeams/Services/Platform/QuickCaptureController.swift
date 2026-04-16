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
    func setup(store: NTMSOrchestrator) {
        self.store = store
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
        let resolvedMode = resolveMode()
        let newVisualMode = QuickCaptureVisualMode(resolvedMode)

        // Detect task switch: even if visual mode is the same, the payload/context may differ
        let currentTaskID = store?.activeTaskID
        let taskChanged = currentTaskID != lastRefreshedTaskID
        lastRefreshedTaskID = currentTaskID

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
                formState.enterAnswerMode(payload: payload)
            }
        } else if !needsAnswerMode && formState.isInAnswerMode {
            formState.exitAnswerMode()
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
        } else if case .taskWorking = currentMode {
            submitAction = {}
        } else {
            submitAction = { [weak self] in
                Task { @MainActor in await self?.createTask() }
            }
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
    #endif
    nonisolated deinit {}
}
