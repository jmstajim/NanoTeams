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
    @State private var isShowingFilePicker = false
    @FocusState private var focusedField: Field?

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
            } else {
                if let payload = answerPayload {
                    questionText(payload.question)
                }
                if !isSheetMode && answerPayload == nil {
                    Spacer(minLength: 0)
                }
                taskField
                if answerPayload == nil && isSheetMode {
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
        VStack(spacing: Spacing.m) {
            Spacer()
            NTMSLoader(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .onKeyPress(.return, phases: .down) { press in
                    if config.enterSendsMessage {
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.command) {
                            NSApp.sendAction(#selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                        } else if canSubmit {
                            onSubmit()
                        }
                    } else {
                        if press.modifiers.contains(.command) {
                            if canSubmit { onSubmit() }
                        } else {
                            NSApp.sendAction(#selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                        }
                    }
                    return .handled
                }
        }
    }

    private var taskFieldPlaceholder: String {
        if answerPayload != nil { return "Type your answer..." }
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

    @State private var isShowingSettings = false

    private var quickCaptureSettingsMenu: some View {
        Button {
            isShowingSettings.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.subheadline)
                .foregroundStyle(Colors.textTertiary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingSettings) {
            let controller = QuickCaptureController.shared
            VStack(alignment: .leading, spacing: Spacing.s) {
                Toggle("Keep open in chat mode", isOn: Binding(
                    get: { controller.keepOpenInChat },
                    set: { controller.keepOpenInChat = $0 }
                ))
                .toggleStyle(.checkbox)

                Toggle("Embed files in prompt", isOn: Binding(
                    get: { controller.embedFilesInPrompt },
                    set: { controller.embedFilesInPrompt = $0 }
                ))
                .toggleStyle(.checkbox)
            }
            .padding(Spacing.m)
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
