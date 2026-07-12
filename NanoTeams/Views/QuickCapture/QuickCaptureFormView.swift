import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Supervisor Answer Payload

/// Data needed to render the QuickCapture overlay in supervisor-answer mode.
struct SupervisorAnswerPayload {
    let stepID: String
    let taskID: Int
    let role: Role
    let roleDefinition: TeamRoleDefinition?
    let question: String
    let messageContent: String?
    let thinking: String?
    let isChatMode: Bool
}

// MARK: - Quick Capture Mode

enum QuickCaptureMode {
    /// Floating overlay panel (compact)
    case overlay
    /// Supervisor answer input — overlay shows LLM question + answer field
    case supervisorAnswer(payload: SupervisorAnswerPayload)
    /// Task is running (LLM working) — overlay shows a loader
    case taskWorking(roleName: String, isChatMode: Bool)

    /// Will the rendered form for this mode include a focusable text field?
    /// Drives `QuickCapturePanel.show(expectsFocusableField:)` so the focus-
    /// retry banner only surfaces when the absence-of-field IS a regression.
    /// Loader-only working mode (non-chat) is the single legitimate "no field"
    /// case — every other mode renders a `MessageComposer` and must focus it.
    var expectsFocusableField: Bool {
        switch self {
        case .overlay, .supervisorAnswer:
            return true
        case .taskWorking(_, let isChatMode):
            return isChatMode
        }
    }
}

// MARK: - Quick Capture Form View

/// Shared form for creating tasks — used in both the floating overlay panel and in-app sheet.
///
/// State is owned by `QuickCaptureFormState` (injected via `@Bindable`). In answer mode,
/// attachment/clip reads/writes route to the answer-mode fields; in task mode they route
/// to the task-draft fields. The view itself is pure presentation.
struct QuickCaptureFormView: View {
    let mode: QuickCaptureMode
    @Bindable var formState: QuickCaptureFormState
    let onSubmit: @MainActor @Sendable () -> Void
    let onCancel: @MainActor @Sendable () -> Void

    @Environment(NTMSOrchestrator.self) private var store
    @Environment(StreamingPreviewManager.self) private var streamingManager
    @Environment(DictationService.self) private var dictation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingFilePicker = false

    /// Active theme observed directly — the panel hosts its own SwiftUI tree
    /// inside an NSPanel, so the root `.preferredColorScheme(...)` on the main
    /// `WindowGroup` doesn't reach this view. Reading `@AppStorage` here makes
    /// the form recompute when the user changes theme in Settings.
    @AppStorage(UserDefaultsKeys.activeTheme) private var activeThemeRaw: String = Theme.defaultTheme.rawValue

    private var activeTheme: Theme {
        Theme(rawValue: activeThemeRaw) ?? Theme.defaultTheme
    }

    /// Measured panel content height — drives the dynamic line-limit upper bound so
    /// the input field can grow up to roughly half of whatever the user has resized
    /// the panel to. Starts at 0 (sentinel for "not yet measured"); falls back to the
    /// historical 1...6 cap until the first geometry pass lands.
    @State private var measuredFormHeight: CGFloat = 0

    /// Fixed vertical slot reserved for the streaming preview line in `.taskWorking`.
    /// Scales with Dynamic Type at the `.caption` metric so the preview Text (also
    /// `.font(Typography.caption)`) never clips and the symmetric loader-centering reserve
    /// grows in lockstep. Must be a stored property — `@ScaledMetric` only works
    /// as a property wrapper.
    @ScaledMetric(relativeTo: .caption) private var previewLineHeight: CGFloat = 18

    // MARK: - Mode Derivations

    private var answerPayload: SupervisorAnswerPayload? {
        if case .supervisorAnswer(let payload) = mode { return payload }
        return nil
    }

    private var isWorkingMode: Bool {
        if case .taskWorking = mode { return true }
        return false
    }

    /// True when the overlay is working on a chat-mode task. Enables the queue composer
    /// so the user can line up their next message while the LLM is still streaming.
    private var isChatWorkingMode: Bool {
        if case .taskWorking(_, let isChatMode) = mode { return isChatMode }
        return false
    }

    private var availableTeams: [Team] {
        store.snapshot?.workFolder.teams ?? [Team.default]
    }

    private var selectableTeams: [Team] {
        QuickCaptureFormLogic.selectableTeams(from: availableTeams)
    }

    private var selectedTeam: Team? {
        QuickCaptureFormLogic.resolveSelectedTeam(
            selectedTeamID: formState.selectedTeamID,
            activeTeamID: store.snapshot?.workFolder.activeTeamID,
            availableTeams: availableTeams
        )
    }

    private var teamModeLabel: String {
        QuickCaptureFormLogic.teamModeLabel(for: selectedTeam)
    }

    /// Draft ID for attachment staging. Always uses the form state's UUID-based draft ID
    /// (step IDs are role ID strings and cannot serve as staging directory names).
    private var activeDraftID: UUID {
        formState.draftID
    }

    private var canSubmit: Bool {
        formState.canSubmit(mode: mode)
    }

    private var taskFieldMaxHeight: CGFloat {
        QuickCaptureFormLogic.taskFieldMaxHeight(measuredFormHeight: measuredFormHeight)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            header
            if isWorkingMode {
                if isChatWorkingMode, let taskID = store.activeTaskID {
                    chatWorkingBody(taskID: taskID)
                } else {
                    taskWorkingBody
                }
            } else if answerPayload != nil {
                answerModeBody
            } else {
                taskCreationBody
            }
        }
        // Fill the panel and top-align content — without this the VStack hugs
        // its content and NSHostingView centers it vertically, leaving an empty
        // band above the header when the user has sized the panel taller than
        // the content needs. Internal `Spacer(minLength: 0)` in
        // `taskCreationBody` still pushes the composer to the bottom because
        // the VStack now accepts the proposed fill height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Spacing.m)
        // Rounded surface fill (NOT a square `.background(Color)`): in the
        // QuickCapture NSPanel the window background is clear and this rounded
        // fill IS what paints the 4pt DS corners. A plain full-frame opaque
        // `Color` background would paint the corner regions square and occlude
        // the panel's intended rounding. `.fill` is non-clipping (#50-safe — it
        // never masks the hosted composer NSScrollView). Harmless in `.sheet`
        // mode (the 4pt curve sits inside the system sheet chrome).
        .background(
            RoundedRectangle.squircle(CornerRadius.large)
                .fill(Colors.surfacePrimary)
        )
        .preferredColorScheme(activeTheme.preferredColorScheme)
        .fontDesign(.monospaced)
        // Recreate the form (incl. the AppKit-resident composer NSTextView) when
        // the user switches themes. The QuickCapture panel hosts a standalone
        // NSHostingView OUTSIDE the app root's `.id(activeTheme)` scene rebuild, so
        // without this its AppKit text would keep the prior theme's colors until
        // the panel's next mode change. `activeThemeRaw` is already observed above
        // (drives `.preferredColorScheme`); the draft survives because it lives in
        // the external `formState`, not in this view's `@State`.
        .id(activeThemeRaw)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            // Dampen sub-pixel oscillation. `measuredFormHeight` feeds
            // `taskFieldMaxHeight` which feeds the inner ScrollView height,
            // which in turn affects the parent's measured height — a feedback
            // loop without a threshold. First non-zero measurement is always
            // accepted (0 is the no-geometry-yet sentinel); after that only
            // ≥ 2pt deltas land so auto-layout jitter is absorbed but real
            // resize gestures still tracked.
            if let accepted = QuickCaptureFormLogic.acceptedMeasuredHeight(
                current: measuredFormHeight,
                incoming: newHeight
            ) {
                measuredFormHeight = accepted
            }
        }
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                stageAttachments(from: urls)
            }
        }
        .onAppear {
            if formState.selectedTeamID == nil {
                formState.selectedTeamID = QuickCaptureFormLogic.resolveSelectedTeam(
                    selectedTeamID: nil,
                    activeTeamID: store.snapshot?.workFolder.activeTeamID,
                    availableTeams: availableTeams
                )?.id
            }
        }
    }

    // MARK: - Answer Mode

    private var answerModeBody: some View {
        Group {
            if let payload = answerPayload {
                questionText(payload.question)
            }
            // No `Spacer` here on purpose. The composer hugs the question
            // directly so there is no "black band" between them at any panel
            // size: empty space lives BELOW the composer (visually a small
            // bottom margin) rather than mid-form.
            //
            // Composer carries `.layoutPriority(1)` so the VStack apportions
            // its natural height first, then the flexible question gets
            // whatever is left. This is what makes R4 hold ("composer always
            // visible regardless of panel height"): when the user shrinks the
            // panel below `header + composer`, the question collapses toward
            // zero — its internal `ScrollView` still scrolls — instead of
            // the composer falling off the bottom edge. Removing this priority
            // re-introduces complaint #6 (composer goes missing on shrink).
            MessageComposer(
                text: $formState.supervisorTask,
                attachments: $formState.answerAttachments,
                clips: $formState.answerClippedTexts,
                placeholder: "Type your answer...",
                canSubmit: canSubmit,
                isSubmitting: false,
                onSubmit: handleSubmit,
                onStageAttachment: { url in store.stageAttachment(url: url, draftID: activeDraftID) },
                onRemoveAttachment: { attachment in store.removeStagedAttachment(attachment) },
                filePickerBinding: $isShowingFilePicker,
                maxTextFieldHeight: taskFieldMaxHeight,
                skillsProjectRoot: store.hasRealWorkFolder ? store.workFolderURL : nil
            ) {
                quickCaptureSettingsMenu
            }
            .layoutPriority(1)
        }
    }

    // MARK: - Task Creation Mode

    private var taskCreationBody: some View {
        // Escape-to-cancel is handled at the AppKit layer via
        // `QuickCapturePanel.cancelOperation` → `onCancelKeyPressed` →
        // `QuickCaptureController.cancelDraft`. We intentionally do NOT add a
        // `.background { Button(...).keyboardShortcut(.cancelAction).hidden() }`
        // wrapper here: that ViewBuilder background sat above the scrolling
        // representable and made SwiftUI re-evaluate the form on every
        // CoreAnimation frame the inner NSScrollView emitted during trackpad
        // scroll (CLAUDE.md Swift Style #50).
        Group {
            Spacer(minLength: 0)
            MessageComposer(
                text: $formState.supervisorTask,
                attachments: $formState.attachments,
                clips: $formState.clippedTexts,
                placeholder: taskFieldPlaceholder,
                canSubmit: canSubmit,
                isSubmitting: false,
                onSubmit: handleSubmit,
                onStageAttachment: { url in store.stageAttachment(url: url, draftID: activeDraftID) },
                onRemoveAttachment: { attachment in store.removeStagedAttachment(attachment) },
                filePickerBinding: $isShowingFilePicker,
                autofocusOnAppear: true,
                maxTextFieldHeight: taskFieldMaxHeight,
                skillsProjectRoot: store.hasRealWorkFolder ? store.workFolderURL : nil
            ) {
                quickCaptureSettingsMenu
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        Group {
            if let payload = answerPayload {
                overlayHeaderRow { SupervisorAnswerHeaderView(payload: payload) }
            } else if case .taskWorking(let roleName, _) = mode {
                overlayHeaderRow { workingHeader(roleName: roleName) }
            } else {
                overlayHeaderRow { overlayHeader }
            }
        }
    }

    private func overlayHeaderRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            content()
                .layoutPriority(1)
            Spacer(minLength: 0)
            CloseButton(action: handleCancel)
        }
    }

    private var overlayHeader: some View {
        HStack(spacing: 3) {
            Text("New")
                .font(Typography.termMd)
                .foregroundStyle(Colors.textSecondary)
                .lineLimit(1)

            overlayTeamMenu

            Text(teamModeLabel)
                .font(Typography.termMd)
                .foregroundStyle(Colors.textSecondary)
                .lineLimit(1)
        }
    }

    private var overlayTeamMenu: some View {
        Menu {
            Button {
                selectGeneratedTeamTemplate()
            } label: {
                Label("Generate Team...", systemImage: "wand.and.stars")
            }

            Divider()

            ForEach(selectableTeams) { team in
                Button {
                    // Persist the pick as the work-folder active team (canonical
                    // mechanism, written to workfolder.json) so the choice survives
                    // panel reopens and app launches. Lightweight `setActiveTeam`,
                    // NOT `store.switchTeam` — the latter pauses the active run and
                    // rewrites the active task's team, which must not happen from a
                    // new-task form. The generated-team branch deliberately skips
                    // this (see `selectGeneratedTeamTemplate`).
                    Task {
                        await store.mutateWorkFolder { $0.setActiveTeam(team.id) }
                        withAnimation(Animations.quick) {
                            formState.selectedTeamID = team.id
                        }
                    }
                } label: {
                    HStack {
                        if team.id == formState.selectedTeamID {
                            Image(systemName: "checkmark")
                        }
                        Text(team.name)
                        Text("(\(team.memberCount) members)")
                            .foregroundStyle(Colors.textSecondary)
                    }
                }
            }
        } label: {
            // Match the DS `QuickCapture.jsx` team trigger: bold mono team
            // name in `text` (`Colors.textPrimary`) with the lavender chevron
            // as Menu's native indicator (so we don't double up). The system
            // borderless-button indicator already sits to the right of the
            // label, which is the spec's `▾` glyph position.
            Text(selectedTeam?.name ?? "Team")
                .font(Typography.termMd)
                .lineLimit(1)
                .foregroundStyle(Colors.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .tint(Colors.accent)
    }

    /// Selects the "Generated Team" template. On submit, the task runs this special
    /// template which triggers background team generation via `create_team` tool call
    /// attributed to Supervisor (similar to `analyze_image`).
    ///
    /// If the Generated Team template isn't in `workFolder.teams` yet (e.g., project was
    /// bootstrapped before this template was added), creates it on-the-fly and appends.
    private func selectGeneratedTeamTemplate() {
        Task {
            var selectedID: NTMSID?
            await store.mutateWorkFolder { project in
                if let existing = project.teams.first(where: { $0.templateID == "generated" }) {
                    selectedID = existing.id
                } else {
                    let newTeam = TeamTemplateFactory.generatedTeam()
                    project.teams.append(newTeam)
                    selectedID = newTeam.id
                }
            }
            if let id = selectedID {
                withAnimation(Animations.quick) {
                    formState.selectedTeamID = id
                }
            }
        }
    }

    // MARK: - Task Working

    private func workingHeader(roleName: String) -> some View {
        HStack(spacing: Spacing.s) {
            Text(roleName.isEmpty ? "Thinking…" : "\(roleName) is thinking…")
                .font(Typography.termMd)
                .foregroundStyle(Colors.textSecondary)
                .lineLimit(1)
        }
    }

    private var taskWorkingBody: some View {
        // Reserved preview region: fixed so the loader stays geometrically centered
        // regardless of whether a preview line is currently visible.
        // `previewLineHeight` is a `@ScaledMetric` property on the view so Dynamic Type
        // grows the reserve in lockstep with the preview Text's `.caption` font.
        let previewGap: CGFloat = Spacing.m

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            // Symmetric invisible block above — matches preview + gap below so the
            // loader's center stays fixed when streaming text appears/disappears.
            Color.clear.frame(height: previewLineHeight + previewGap)
            NTMSLoader(.large)
            Color.clear.frame(height: previewGap)
            streamingPreviewLine
                .frame(height: previewLineHeight)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Chat-mode working body: big centered loader always at the top (same visual as
    /// the non-chat `taskWorkingBody`), with the `MessageComposer` docked at the
    /// bottom for queueing the next message while the LLM is still streaming. The
    /// loader region flexes to fill whatever space the composer doesn't consume.
    /// Submit moves the draft into `formState.queuedChatMessages` and flushes
    /// automatically when the engine next reaches `.needsSupervisorInput`.
    private func chatWorkingBody(taskID: Int) -> some View {
        let previewGap: CGFloat = Spacing.m

        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Color.clear.frame(height: previewLineHeight + previewGap)
                NTMSLoader(.large)
                Color.clear.frame(height: previewGap)
                streamingPreviewLine
                    .frame(height: previewLineHeight)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: Spacing.s) {
                if formState.hasQueuedMessage(for: taskID) {
                    queuedBadge(taskID: taskID)
                }

                MessageComposer(
                    text: $formState.supervisorTask,
                    attachments: $formState.answerAttachments,
                    clips: $formState.answerClippedTexts,
                    placeholder: formState.hasQueuedMessage(for: taskID)
                        ? "Replace queued message..."
                        : "Type to queue a message...",
                    canSubmit: canSubmit,
                    isSubmitting: false,
                    onSubmit: handleSubmit,
                    onStageAttachment: { url in store.stageAttachment(url: url, draftID: activeDraftID) },
                    onRemoveAttachment: { attachment in store.removeStagedAttachment(attachment) },
                    filePickerBinding: $isShowingFilePicker,
                    maxTextFieldHeight: taskFieldMaxHeight,
                    skillsProjectRoot: store.hasRealWorkFolder ? store.workFolderURL : nil
                ) {
                    quickCaptureSettingsMenu
                }
            }
        }
    }

    private func queuedBadge(taskID: Int) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "tray.and.arrow.up")
                .font(Typography.term2xs)
                .foregroundStyle(Colors.accent)
            Text("Queued — will send when the team asks for input")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .lineLimit(1)
            Spacer()
            Button {
                QuickCaptureController.shared.discardQueuedChatMessage(taskID: taskID)
            } label: {
                Image(systemName: "xmark")
                    .font(Typography.term2xs.weight(.semibold))
                    .foregroundStyle(Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Discard the queued message")
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.accentTint)
        )
    }

    /// Single-line live preview of the currently streaming model content.
    /// Mirrors the activity feed's polling pattern in `TeamActivityFeedView.messageBubble`
    /// (including the reduce-motion rate). Only the Text polls — the loader and layout
    /// spacers stay outside TimelineView so they aren't rebuilt on every tick.
    private var streamingPreviewLine: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1.0 : 0.15)) { _ in
            Text(currentStreamingLine ?? "")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, Spacing.m)
                .animation(nil, value: currentStreamingLine)
        }
    }

    /// Resolves the step-ID for the currently running step in the active task, then
    /// returns the most informative single-line summary of its streaming state.
    ///
    /// `streamingContent` returns `Optional("")` (not nil) between `beginStreaming` and
    /// the first content chunk, so a naive `?? thinking` fallback would never fire —
    /// we explicitly check emptiness via `lastNonEmptyLine` before falling through.
    ///
    /// Thinking text is not token-cleaned at source (`appendThinking` in
    /// `StreamingPreviewManager` skips the `ModelTokenCleaner` call that `append` uses),
    /// so we strip tokens here before displaying.
    ///
    /// Returns nil when nothing is streaming — tool execution gaps, team meetings
    /// (meetings stream locally in `MeetingStreamingService`, not via `StreamingPreviewManager`),
    /// or between role transitions. The preview line simply disappears.
    private var currentStreamingLine: String? {
        guard let taskID = store.activeTask?.id, let stepID = runningStepID else { return nil }
        return Self.resolveStreamingLine(
            content: streamingManager.streamingContent(stepID: stepID, taskID: taskID),
            thinking: streamingManager.streamingThinking(stepID: stepID, taskID: taskID)
        )
    }

    /// Pure resolution of content/thinking into a single displayed line.
    /// Extracted from `currentStreamingLine` so it can be exercised directly
    /// without standing up a SwiftUI view + environment (see `#if DEBUG`
    /// accessors below and `QuickCaptureFormViewLogicTests`).
    ///
    /// Contract: prefer content over thinking, skip both the `Optional("")`
    /// pre-first-chunk state and any whitespace-only chunks, strip Harmony
    /// tokens from thinking (`appendThinking` in `StreamingPreviewManager`
    /// doesn't clean at source), return nil when nothing displayable.
    private static func resolveStreamingLine(content: String?, thinking: String?) -> String? {
        if let content, let line = lastNonEmptyLine(in: content) {
            return line
        }
        if let thinking {
            let cleaned = ModelTokenCleaner.stripTokens(thinking)
            if let line = lastNonEmptyLine(in: cleaned) {
                return line
            }
        }
        return nil
    }

    /// A `.running` step in the active task's latest run, or nil if none.
    ///
    /// Multiple steps can be `.running` concurrently: `TeamEngine.startRoles`
    /// (`TeamEngine+RoleTasks.swift`) spawns every ready role in parallel, so any
    /// team whose dependency graph has parallel branches (e.g. FAANG: UXR + UXD + PM
    /// after Supervisor Task) will have several steps streaming at once. This picks
    /// whichever `.running` step happens to come first in `run.steps` array order —
    /// arbitrary and non-deterministic across runs. Acceptable because the preview
    /// is decorative; do not rely on this for logic that needs to target a specific
    /// step. If a deterministic choice is ever needed, tie-break by most-recent
    /// streaming activity or by the currently selected role.
    private var runningStepID: String? {
        store.activeTask?
            .latestRun?
            .steps
            .first(where: { $0.status == .running })?
            .id
    }

    /// Returns the last non-empty trimmed line from a multi-line streaming chunk,
    /// or nil if the text is empty/whitespace-only. Picking the last line shows the
    /// user what was most recently appended rather than a stale first heading.
    private static func lastNonEmptyLine(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for line in trimmed.split(whereSeparator: \.isNewline).reversed() {
            let s = line.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return String(s) }
        }
        return nil
    }

    // MARK: - Question Text

    private func questionText(_ text: String) -> some View {
        // Chat-like layout: question fills whatever the VStack leaves between
        // header and composer and scrolls internally when content is taller.
        //
        // No `minHeight` floor: composer's `.layoutPriority(1)` in
        // `answerModeBody` already guarantees the composer's visibility, and a
        // floor here would re-introduce overflow at minSize whenever the
        // composer's natural height plus the floor exceeds the panel
        // (complaint #6). The question is the give-first piece per R4.
        //
        // No `measuredFormHeight`-derived cap, no `onGeometryChange` on the
        // Text — those create a measurement feedback loop and make the panel
        // "breathe". `maxHeight: .infinity` lets the ScrollView absorb
        // whatever the VStack hands it.
        ScrollView {
            Text(text)
                .font(Typography.termBase)
                .foregroundStyle(Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private var taskFieldPlaceholder: String {
        QuickCaptureFormLogic.taskFieldPlaceholder(for: selectedTeam)
    }

    // Flushes any pending dictation (so the last spoken words land before
    // submit) and cancels it on Escape (so the mic doesn't keep recording
    // after the panel closes).
    private func handleSubmit() { dictation.flushAndThen(onSubmit) }
    private func handleCancel() { dictation.flushAndThen(onCancel) }

    // MARK: - Settings Menu

    private var quickCaptureSettingsMenu: some View {
        let controller = QuickCaptureController.shared
        return EmbedFilesSettingsButton {
            Toggle("Keep open in chat mode", isOn: Binding(
                get: { controller.keepOpenInChat },
                set: { controller.keepOpenInChat = $0 }
            ))
            .toggleStyle(.terminal)
        }
    }

    // MARK: - Helpers

    private func stageAttachments(from urls: [URL]) {
        let isAnswerMode = answerPayload != nil
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            if let attachment = store.stageAttachment(url: url, draftID: activeDraftID) {
                if isAnswerMode {
                    if !formState.answerAttachments.contains(attachment) {
                        formState.answerAttachments.append(attachment)
                    }
                } else {
                    if !formState.attachments.contains(attachment) {
                        formState.attachments.append(attachment)
                    }
                }
            }
        }
    }
}

#if DEBUG
extension QuickCaptureFormView {
    /// Test accessor for the pure single-line extractor. Mirrors the production
    /// call site in `resolveStreamingLine`.
    static func _testLastNonEmptyLine(in text: String) -> String? {
        lastNonEmptyLine(in: text)
    }

    /// Test accessor for the content→thinking resolution logic. Lets unit tests
    /// exercise both the `Optional("")` pre-first-chunk fall-through and the
    /// `appendThinking` token-cleaning asymmetry without constructing the full
    /// SwiftUI view + `StreamingPreviewManager` environment.
    static func _testResolveStreamingLine(content: String?, thinking: String?) -> String? {
        resolveStreamingLine(content: content, thinking: thinking)
    }
}

#endif
