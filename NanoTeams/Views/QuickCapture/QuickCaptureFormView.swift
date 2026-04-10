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
    /// Floating overlay panel (forced dark, compact)
    case overlay
    /// In-app sheet (follows system appearance)
    case sheet
    /// Supervisor answer input — overlay shows LLM question + answer field
    case supervisorAnswer(payload: SupervisorAnswerPayload)
    /// Task is running (LLM working) — overlay shows a loader
    case taskWorking(roleName: String, isChatMode: Bool)
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
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @Environment(NTMSOrchestrator.self) private var store
    @Environment(StoreConfiguration.self) private var config
    @Environment(StreamingPreviewManager.self) private var streamingManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingFilePicker = false
    @FocusState private var focusedField: Field?

    /// Fixed vertical slot reserved for the streaming preview line in `.taskWorking`.
    /// Scales with Dynamic Type at the `.caption` metric so the preview Text (also
    /// `.font(.caption)`) never clips and the symmetric loader-centering reserve
    /// grows in lockstep. Must be a stored property — `@ScaledMetric` only works
    /// as a property wrapper.
    @ScaledMetric(relativeTo: .caption) private var previewLineHeight: CGFloat = 18

    private enum Field: Hashable { case supervisorTask }

    // MARK: - Mode Derivations

    private var answerPayload: SupervisorAnswerPayload? {
        if case .supervisorAnswer(let payload) = mode { return payload }
        return nil
    }

    private var isSheetMode: Bool {
        if case .sheet = mode { return true }
        return false
    }

    private var isWorkingMode: Bool {
        if case .taskWorking = mode { return true }
        return false
    }

    private var availableTeams: [Team] {
        store.snapshot?.workFolder.teams ?? [Team.default]
    }

    private var selectedTeam: Team? {
        let targetID = formState.selectedTeamID ?? store.snapshot?.workFolder.activeTeamID
        if let targetID {
            return availableTeams.first { $0.id == targetID }
        }
        return availableTeams.first
    }

    /// Draft ID for attachment staging. Always uses the form state's UUID-based draft ID
    /// (step IDs are role ID strings and cannot serve as staging directory names).
    private var activeDraftID: UUID {
        formState.draftID
    }

    private var canSubmit: Bool {
        formState.canSubmit(mode: mode)
    }

    private var contentSpacing: CGFloat {
        !isSheetMode ? Spacing.s : Spacing.m
    }

    private var contentPadding: CGFloat {
        !isSheetMode ? Spacing.m : Spacing.l
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            header
            if isWorkingMode {
                taskWorkingBody
            } else if answerPayload != nil {
                answerModeBody
            } else {
                taskCreationBody
            }
        }
        .padding(contentPadding)
        .background(Colors.surfacePrimary)
        .preferredColorScheme(!isSheetMode ? .dark : nil)
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
                formState.selectedTeamID = store.snapshot?.workFolder.activeTeamID ?? availableTeams.first?.id
            }
        }
        .task {
            focusedField = .supervisorTask
        }
    }

    // MARK: - Answer Mode

    private var answerModeBody: some View {
        Group {
            if let payload = answerPayload {
                questionText(payload.question)
            }
            SupervisorAnswerComposer(
                text: $formState.supervisorTask,
                attachments: $formState.answerAttachments,
                clips: $formState.answerClippedTexts,
                placeholder: "Type your answer...",
                canSubmit: canSubmit,
                isSubmitting: false,
                onSubmit: onSubmit,
                onStageAttachment: { url in store.stageAttachment(url: url, draftID: activeDraftID) },
                onRemoveAttachment: { attachment in store.removeStagedAttachment(attachment) },
                filePickerBinding: $isShowingFilePicker
            ) {
                if !isSheetMode {
                    quickCaptureSettingsMenu
                }
            }
        }
    }

    // MARK: - Task Creation Mode

    private var taskCreationBody: some View {
        Group {
            if !isSheetMode {
                Spacer(minLength: 0)
            }
            taskField
            if isSheetMode {
                teamPicker
            }
            AttachmentGridView(
                formState: formState,
                mode: mode,
                activeDraftID: activeDraftID,
                isSheetMode: isSheetMode,
                onRequestFilePicker: { isShowingFilePicker = true }
            )
            actions
        }
    }

    // MARK: - Header

    private var header: some View {
        Group {
            if let payload = answerPayload {
                overlayHeaderRow { SupervisorAnswerHeaderView(payload: payload) }
            } else if case .taskWorking(let roleName, _) = mode {
                overlayHeaderRow { workingHeader(roleName: roleName) }
            } else if !isSheetMode {
                overlayHeaderRow { overlayHeader }
            } else {
                SheetHeader(
                    title: "New Task",
                    subtitle: "Create a new task for your AI team",
                    systemImage: "plus.square.fill",
                    tintColor: Colors.accent
                )
            }
        }
    }

    private func overlayHeaderRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            content()
                .layoutPriority(1)
            Spacer(minLength: 0)
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Colors.surfaceElevated))
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    private var overlayHeader: some View {
        HStack(spacing: 3) {
            Text("New")
                .font(.headline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            overlayTeamMenu

            Text(selectedTeam?.isChatMode == true ? "chat" : "task")
                .font(.headline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var overlayTeamMenu: some View {
        Menu {
            ForEach(availableTeams) { team in
                Button {
                    withAnimation(Animations.quick) {
                        formState.selectedTeamID = team.id
                    }
                } label: {
                    HStack {
                        if team.id == formState.selectedTeamID {
                            Image(systemName: "checkmark")
                        }
                        Text(team.name)
                        Text("(\(team.memberCount) members)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            Text(selectedTeam?.name ?? "Team")
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(Colors.accent)
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: - Task Working

    private func workingHeader(roleName: String) -> some View {
        HStack(spacing: Spacing.s) {
            Text(roleName.isEmpty ? "Thinking..." : "\(roleName) is thinking...")
                .font(.headline.weight(.medium))
                .foregroundStyle(.secondary)
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

    /// Single-line live preview of the currently streaming model content.
    /// Mirrors the activity feed's polling pattern in `TeamActivityFeedView.messageBubble`
    /// (including the reduce-motion rate). Only the Text polls — the loader and layout
    /// spacers stay outside TimelineView so they aren't rebuilt on every tick.
    private var streamingPreviewLine: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1.0 : 0.15)) { _ in
            Text(currentStreamingLine ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        guard let stepID = runningStepID else { return nil }
        return Self.resolveStreamingLine(
            content: streamingManager.streamingContent(for: stepID),
            thinking: streamingManager.streamingThinking(for: stepID)
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
        ScrollView {
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Task Field

    private var taskField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if isSheetMode {
                Text(SystemTemplates.supervisorTaskArtifactName)
                    .font(Typography.subheadlineMedium)
                    .foregroundStyle(.secondary)
            }
            TextField(taskFieldPlaceholder, text: $formState.supervisorTask, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...10)
                .padding(Spacing.s)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(Colors.surfaceCard)
                )
                .focused($focusedField, equals: .supervisorTask)
                .enterSendsMessage(
                    config.enterSendsMessage,
                    canSubmit: canSubmit,
                    onSubmit: onSubmit
                )
        }
    }

    private var taskFieldPlaceholder: String {
        if selectedTeam?.isChatMode == true { return "Send a message..." }
        return "Describe your task..."
    }

    // MARK: - Team Picker

    private var teamPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Team")
                .font(Typography.subheadlineMedium)
                .foregroundStyle(.secondary)
            Menu {
                ForEach(availableTeams) { team in
                    Button {
                        withAnimation(Animations.quick) {
                            formState.selectedTeamID = team.id
                        }
                    } label: {
                        HStack {
                            if team.id == formState.selectedTeamID {
                                Image(systemName: "checkmark")
                            }
                            Text(team.name)
                            Text("(\(team.memberCount) members)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } label: {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "person.3.fill")
                        .foregroundStyle(Colors.info)
                    Text(selectedTeam?.name ?? "Select Team")
                        .fontWeight(.medium)
                    Text("(\(selectedTeam?.memberCount ?? 0))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                .padding(Spacing.m)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(Colors.surfaceCard)
                )
            }
            .menuStyle(.borderlessButton)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: Spacing.m) {
            Button {
                isShowingFilePicker = true
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title2)
                    .foregroundStyle(Colors.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Attach files")

            if !isSheetMode {
                quickCaptureSettingsMenu
            }

            Spacer()

            Button {
                onSubmit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(!canSubmit ? Colors.textTertiary : Colors.accent)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
        .background {
            Button("", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    // MARK: - Settings Menu

    private var quickCaptureSettingsMenu: some View {
        let controller = QuickCaptureController.shared
        return EmbedFilesSettingsButton {
            Toggle("Keep open in chat mode", isOn: Binding(
                get: { controller.keepOpenInChat },
                set: { controller.keepOpenInChat = $0 }
            ))
            .toggleStyle(.checkbox)
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
