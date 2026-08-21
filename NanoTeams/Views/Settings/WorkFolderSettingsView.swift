import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct WorkFolderSettingsView: View {
    @Environment(NTMSOrchestrator.self) var store
    @State private var contextDraft: String = ""
    @State private var promptDraft: String = ""
    @State private var isShowingResetConfirmation = false
    @State private var isShowingCloseConfirmation = false
    @State private var isPromptExpanded = false
    @State private var isShowingContextEditor = false
    @State private var isShowingInstructionPicker = false
    /// Last value the debounced autosave dispatched — lets the settings-echo
    /// `onChange` distinguish OUR save landing (skip: overwriting the draft
    /// would delete keystrokes typed during the await) from an external write
    /// (Generate, Autovisor `set_work_folder_context` → adopt).
    @State private var lastAutosavedContext: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var promptSaveTask: Task<Void, Never>?
    @State private var availableSchemes: [String] = []
    @State private var recentProjects: [URL] = []

    var body: some View {
        if store.hasRealWorkFolder {
            workFolderContent
        } else {
            SettingsEmptyState(
                title: "No Work Folder",
                systemImage: "folder.badge.questionmark",
                description: "Select a folder to access and manage files",
                actionTitle: "Open Folder",
                action: { Task { await openProjectFromPanel() } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Main Content

    private var workFolderContent: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                folderHeaderCard
                bundledUpdateBlockedCard
                descriptionCard
                if store.workFolder != nil {
                    schemeCard
                }
                dangerCard
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
        .confirmationDialog(
            "Reset Work Folder Settings?",
            isPresented: $isShowingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                Task { await store.resetWorkFolderSettings() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will restore the work folder context, teams, roles, and tools to their default values. Existing tasks and runs will be preserved but might reference missing configurations. This action cannot be undone.")
        }
        .confirmationDialog(
            "Close Work Folder?",
            isPresented: $isShowingCloseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) {
                Task { await store.closeProject() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tasks are still running. Closing the work folder will stop all active tasks.")
        }
        .sheet(isPresented: $isShowingContextEditor) {
            WorkFolderContextEditorSheet(
                contextDraft: $contextDraft,
                isSaving: isContextSaving
            )
        }
        // Debounced autosave lives on the container (not the preview `Text`) so
        // it fires whether the draft changes via the Edit sheet or via Generate.
        .onChange(of: contextDraft) { _, newValue in
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                if store.workFolder?.settings.context != newValue {
                    lastAutosavedContext = newValue
                    await store.updateWorkFolderContext(newValue)
                }
            }
        }
        .onAppear {
            if let p = store.workFolder {
                contextDraft = p.settings.context
                promptDraft = p.settings.contextPrompt
            }
            recentProjects = NSDocumentController.shared.recentDocumentURLs
            Task { availableSchemes = await store.fetchAvailableSchemes() }
            // Keep the attached-instructions grid honest when returning to this
            // tab (a CLAUDE.md may have been added/removed since open).
            Task { await store.refreshAgentInstructions() }
        }
        .onChange(of: store.workFolder?.id) { _, _ in
            if let p = store.workFolder {
                contextDraft = p.settings.context
                promptDraft = p.settings.contextPrompt
            }
        }
        .onChange(of: store.workFolder?.settings.context) { _, newValue in
            // Echo-clobber guard: when the change is OUR autosave landing, keep
            // the draft — the user may have typed more during the await, and
            // overwriting would delete those keystrokes mid-edit. External
            // writes (Generate, Autovisor) still adopt.
            guard let val = newValue, val != lastAutosavedContext else { return }
            contextDraft = val
        }
        .onChange(of: store.workFolder?.settings.contextPrompt) { _, newValue in
            if let val = newValue { promptDraft = val }
        }
    }

    // MARK: - Folder Header Card

    private var folderHeaderCard: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let folder = store.workFolderURL {
                SettingsItemHeader(
                    icon: "folder",
                    title: folder.lastPathComponent,
                    subtitle: folder.path
                )

                HStack(spacing: Spacing.s) {
                    SettingsPillButton(title: "Reveal in Finder", icon: "arrow.right.circle") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                    }

                    SettingsPillButton(title: "Open Other...", icon: "folder.badge.plus") {
                        Task { await openProjectFromPanel() }
                    }

                    SettingsPillButton(title: "Close Work Folder", icon: "xmark.circle", isDestructive: true) {
                        if store.hasRunningTasks {
                            isShowingCloseConfirmation = true
                        } else {
                            Task { await store.closeProject() }
                        }
                    }

                    Spacer(minLength: 0)
                }

                if !recentProjects.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        MonoLabel(text: "Recent")

                        ForEach(Array(recentProjects.prefix(5)), id: \.self) { url in
                            Button {
                                var isDir: ObjCBool = false
                                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                                    Task { await store.openWorkFolder(url) }
                                } else {
                                    store.lastErrorMessage = "Folder not found: \(url.lastPathComponent)"
                                }
                            } label: {
                                HStack(spacing: Spacing.s) {
                                    Image(systemName: "folder")
                                        .font(Typography.caption)
                                        .foregroundStyle(Colors.textTertiary)
                                    Text(url.lastPathComponent)
                                        .font(Typography.caption)
                                        .foregroundStyle(url == store.workFolderURL ? Colors.textTertiary : Colors.textSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(url == store.workFolderURL)
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Blocked Bundled Updates

    /// Durable surface for the ONE permanent failure mode: a `task.json` the
    /// reconcile can't read, which fail-closes bundled prompt/tool updates for
    /// every team until the user repairs it.
    ///
    /// Deliberately not shown for a deferral — those clear on the next open, so
    /// a row here would be stale before it could be read, and the open-time
    /// banner already says so.
    @ViewBuilder
    private var bundledUpdateBlockedCard: some View {
        if let message = store.bundledUpdateReport?.durableMessage {
            SettingsCard(
                header: "Prompt Updates Blocked",
                systemImage: "exclamationmark.triangle"
            ) {
                HStack(alignment: .top, spacing: Spacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Colors.error)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.s)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small).fill(Colors.errorTint)
                )
            }
        }
    }

    // MARK: - Context Card

    private var descriptionCard: some View {
        SettingsCard(
            header: "Work Folder Context",
            systemImage: "doc.text",
            footer: "This context is sent to all AI roles. Use Generate to build it from your files, or write your own."
        ) {
            // Read-only preview (up to 7 lines). Editing happens in the sheet
            // opened by the Edit button — a plain `Text` (not `TextEditor`) so
            // there is no NSScrollView here (CLAUDE.md #50 moot).
            HStack(alignment: .top, spacing: Spacing.xs) {
                PromptMarker()
                Group {
                    if contextDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No context yet — Generate from your files or Edit to write your own.")
                            .foregroundStyle(Colors.textTertiary)
                    } else {
                        Text(contextDraft)
                            .foregroundStyle(Colors.textPrimary)
                            .lineLimit(7)
                    }
                }
                .font(Typography.termBase)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(Spacing.s)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.surfaceElevated)
            )

            HStack {
                SettingsPillButton(title: "Edit", icon: "square.and.pencil") {
                    isShowingContextEditor = true
                }

                let isGenerating = store.isGeneratingWorkFolderContext
                Button {
                    if isGenerating {
                        store.cancelWorkFolderContextGeneration()
                    } else {
                        store.startGeneratingWorkFolderContext()
                    }
                } label: {
                    HStack(spacing: Spacing.s) {
                        ZStack {
                            if isGenerating {
                                NTMSLoader(.inline)
                            } else {
                                Image(systemName: "sparkles")
                            }
                        }
                        .frame(width: 14, height: 14)
                        Text(isGenerating ? "Generating..." : "Generate")
                    }
                    .font(Typography.captionSemibold)
                    .foregroundStyle(isGenerating ? Colors.textSecondary : Colors.surfaceBackground)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(RoundedRectangle.squircle(CornerRadius.small).fill(isGenerating ? Colors.surfaceElevated : Colors.accent))
                }
                .buttonStyle(.plain)

                Button {
                    isPromptExpanded.toggle()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Prompt")
                    }
                    .font(Typography.captionSemibold)
                    .foregroundStyle(Colors.textSecondary)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(
                        RoundedRectangle.squircle(CornerRadius.small)
                            .fill(Colors.surfaceElevated)
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isPromptExpanded) {
                    promptPopoverContent
                }

                Spacer()

                if isContextSaving { SavingIndicator() }
            }

            agentInstructionsSection
        }
    }

    /// `true` while the debounced autosave hasn't caught up with the draft.
    private var isContextSaving: Bool {
        store.workFolder?.settings.context != contextDraft
    }

    /// Agent instruction files: auto-discovered (CLAUDE.md, AGENTS.md, …) plus
    /// user-attached, as an editable Quick-Capture-style grid — remove badge on
    /// each card (manual → detach; discovered → exclude from injection, dimmed
    /// + restorable), "+" cell attaches any file from within the work folder.
    @ViewBuilder
    private var agentInstructionsSection: some View {
        if let root = store.workFolderURL {
            let snap = store.agentInstructions ?? .empty
            VStack(alignment: .leading, spacing: Spacing.s) {
                MonoLabel(text: "Agent Instructions", marker: true)

                AgentInstructionsGrid(
                    items: snap.items,
                    workFolderRoot: root,
                    onRemove: { path in Task { await store.removeAgentInstruction(relativePath: path) } },
                    onRestore: { path in Task { await store.restoreAgentInstruction(relativePath: path) } },
                    onSetInjected: { path, injected in
                        Task { await store.setAgentInstructionInjected(relativePath: path, injected: injected) }
                    },
                    onAdd: { isShowingInstructionPicker = true }
                )

                Text(agentInstructionsHint(snap))
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
            .fileImporter(
                isPresented: $isShowingInstructionPicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    Task { await store.addAgentInstructions(urls: urls) }
                }
            }
            .fileDialogDefaultDirectory(root)
        }
    }

    private func agentInstructionsHint(_ snap: AgentInstructionsSnapshot) -> String {
        let injected = snap.injectedFiles.map(\.relativePath)
        if injected.isEmpty {
            return "Attach files to inject them into every role's system prompt (images are listed for on-demand reading)."
        }
        return "\(injected.joined(separator: ", ")) — injected into every role's system prompt; other files are listed for on-demand reading."
    }

    // MARK: - Scheme Card

    private var schemeCard: some View {
        SettingsCard(
            header: "Xcode Scheme",
            systemImage: "hammer",
            footer: "The Xcode scheme used by run_xcodebuild and run_xcodetests tools."
        ) {
            SchemeSection(
                availableSchemes: availableSchemes,
                selectedScheme: Binding(
                    get: { store.workFolder?.settings.selectedScheme },
                    set: { newValue in
                        Task { await store.updateSelectedScheme(newValue) }
                    }
                )
            )
        }
    }

    // MARK: - Danger Card

    private var dangerCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            MonoLabel(text: "Danger Zone", rule: true)

            VStack(alignment: .leading, spacing: Spacing.m) {
                Button {
                    isShowingResetConfirmation = true
                } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset Work Folder")
                    }
                    .font(Typography.captionSemibold)
                    .foregroundStyle(Colors.error)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(
                        RoundedRectangle.squircle(CornerRadius.small)
                            .fill(Colors.errorTint)
                    )
                }
                .buttonStyle(.plain)

                Text("Removes all tasks, runs, teams, and settings, then recreates defaults. Your files are not affected.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
            .padding(Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .fill(Colors.errorTint)
            )
        }
    }

    // MARK: - Helpers

    private var promptPopoverContent: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            MonoLabel(text: "Generation Prompt", marker: true)

            Text("Controls what the AI focuses on when analyzing the folder.")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)

            HStack(alignment: .top, spacing: Spacing.xs) {
                PromptMarker()
                TextEditor(text: $promptDraft)
                    .font(Typography.termBase)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
            }
            .padding(Spacing.s)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.surfaceElevated)
            )
            .onChange(of: promptDraft) { _, newValue in
                promptSaveTask?.cancel()
                promptSaveTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    if store.workFolder?.settings.contextPrompt != newValue {
                        await store.updateContextPrompt(newValue)
                    }
                }
            }

            HStack {
                Button {
                    promptDraft = AppDefaults.workFolderContextPrompt
                } label: {
                    Text("Reset to Default")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.accent)
                }
                .buttonStyle(.plain)
                .disabled(promptDraft == AppDefaults.workFolderContextPrompt)

                Spacer()

                if store.workFolder?.settings.contextPrompt != promptDraft { SavingIndicator() }
            }
        }
        .padding(Spacing.standard)
        .frame(width: 380)
    }

    private func openProjectFromPanel() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Work Folder"
        panel.message = "Select a work folder to open"
        if panel.runModal() == .OK, let url = panel.url {
            await store.openWorkFolder(url)
            recentProjects = NSDocumentController.shared.recentDocumentURLs
        }
    }
}

// MARK: - Scheme Section

struct SchemeSection: View {
    let availableSchemes: [String]
    @Binding var selectedScheme: String?

    var body: some View {
        if availableSchemes.isEmpty {
            HStack(spacing: Spacing.s) {
                StatusGlyph(glyph: TerminalGlyph.review, color: Colors.warning)
                Text("No Xcode schemes found")
                    .font(Typography.subheadline)
                    .foregroundStyle(Colors.textSecondary)
            }
        } else {
            HStack {
                Text("Scheme")
                    .font(Typography.subheadline)
                Spacer()
                TerminalPicker(
                    selection: Binding(
                        get: { selectedScheme ?? "" },
                        set: { selectedScheme = $0.isEmpty ? nil : $0 }
                    ),
                    options: [("", "Select a scheme")] + availableSchemes.map { ($0, $0) }
                )
            }
        }
    }
}

// MARK: - Agent Instructions Grid

/// Editable Quick-Capture-style grid of agent instruction files. Mirrors
/// `MessageComposer.attachmentGrid`'s cell vocabulary: icon + truncated
/// filename + `RemoveBadgeButton`. Discovered files the user excluded render
/// dimmed with a restore badge instead; the trailing "+" cell opens the file
/// picker (any file INSIDE the work folder).
private struct AgentInstructionsGrid: View {
    let items: [AgentInstructionsSnapshot.Item]
    let workFolderRoot: URL
    let onRemove: (String) -> Void
    let onRestore: (String) -> Void
    let onSetInjected: (String, Bool) -> Void
    let onAdd: () -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 64, maximum: 72), spacing: Spacing.s, alignment: .top)],
            alignment: .leading,
            spacing: Spacing.s
        ) {
            ForEach(items) { item in
                AgentInstructionCell(
                    item: item,
                    url: workFolderRoot.appendingPathComponent(item.relativePath),
                    onRemove: { onRemove(item.relativePath) },
                    onRestore: { onRestore(item.relativePath) }
                )
            }
            if !items.isEmpty {
                AgentInstructionsListCell(
                    items: items, workFolderRoot: workFolderRoot, onSetInjected: onSetInjected)
            }
            addCell
        }
    }

    private var addCell: some View {
        Button(action: onAdd) {
            VStack(spacing: Spacing.xxs) {
                Image(systemName: "plus")
                    .font(Typography.termLg)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(width: 48, height: 48)
                    .overlay {
                        RoundedRectangle.squircle(CornerRadius.micro)
                            .strokeBorder(Colors.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .accessibilityHidden(true)

                Text("Add")
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(width: 64)
            }
            .frame(width: 64)
            // Whole cell is hittable — without this only the glyph strokes and
            // the 1pt dashed border pass hit-testing (transparent fill).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Attach a file from the work folder as an agent instruction")
        .accessibilityLabel("Add agent instruction file")
    }
}

/// Virtual "one file" card summarizing every found instruction — same footprint
/// as the real file cells, count badge top-right. Tap opens a popover listing
/// all paths (injected → IN PROMPT badge, listed → plain, excluded → dimmed
/// strikethrough); row tap opens QuickLook. Height-capped auto-sizing mirrors
/// `ClipPopoverContent`.
private struct AgentInstructionsListCell: View {
    let items: [AgentInstructionsSnapshot.Item]
    let workFolderRoot: URL
    let onSetInjected: (String, Bool) -> Void

    @State private var isShowingList = false
    @State private var quickLookURL: URL?
    @State private var contentHeight: CGFloat = .infinity

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "list.bullet.rectangle")
                    .font(Typography.termXl)
                    .foregroundStyle(Colors.textSecondary)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle.squircle(CornerRadius.micro)
                            .fill(Colors.surfacePrimary)
                    )
                    .overlay {
                        RoundedRectangle.squircle(CornerRadius.micro)
                            .strokeBorder(Colors.borderSubtle, lineWidth: 1)
                    }
                    .accessibilityHidden(true)

                Text("\(items.count)")
                    .font(Typography.term2xs.weight(.bold))
                    .foregroundStyle(Colors.textOnAccent)
                    .padding(.horizontal, Spacing.xs)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(
                        RoundedRectangle.squircle(CornerRadius.small)
                            .fill(Colors.accent)
                    )
                    .offset(x: 6, y: -6)
            }

            Text("All files")
                .font(Typography.term2xs)
                .foregroundStyle(Colors.textSecondary)
                .lineLimit(1)
                .frame(width: 64)
        }
        .frame(width: 64)
        .contentShape(Rectangle())
        .onTapGesture { isShowingList = true }
        .help("Show every found instruction file")
        .accessibilityLabel("All instruction files (\(items.count))")
        .popover(isPresented: $isShowingList) {
            listPopover
        }
    }

    private var listPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(items) { item in
                    row(item)
                }
            }
            .padding(Spacing.m)
            .frame(width: 320, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                if abs(newHeight - contentHeight) > 1 { contentHeight = newHeight }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, 240))
        .quickLookPreview($quickLookURL)
    }

    private func row(_ item: AgentInstructionsSnapshot.Item) -> some View {
        let isInjected = !item.isExcluded && item.injectedContent != nil
        return HStack(spacing: Spacing.xs) {
            // Path opens QuickLook; the trailing capsule toggles injection.
            Button {
                quickLookURL = workFolderRoot.appendingPathComponent(item.relativePath)
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "doc.text")
                        .font(Typography.caption)
                        .foregroundStyle(isInjected ? Colors.accent : Colors.textTertiary)
                        .accessibilityHidden(true)
                    Text(item.relativePath)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: Spacing.xs)

            if isInjected {
                Button {
                    onSetInjected(item.relativePath, false)
                } label: {
                    HStack(spacing: Spacing.xxs) {
                        Text("IN PROMPT")
                            .tracking(Typography.labelTracking)
                        Image(systemName: "xmark")
                            .accessibilityHidden(true)
                    }
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.accent)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xxs)
                    .background(Capsule().fill(Colors.accentTint))
                }
                .buttonStyle(.plain)
                .help("Stop injecting this file's content")
                .accessibilityLabel("Stop injecting \(item.relativePath)")
            } else {
                Button {
                    onSetInjected(item.relativePath, true)
                } label: {
                    Text("INJECT")
                        .tracking(Typography.labelTracking)
                        .font(Typography.term2xs)
                        .foregroundStyle(Colors.textSecondary)
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, Spacing.xxs)
                        .background(
                            Capsule().strokeBorder(Colors.borderSubtle, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Inject this file's content into every role's system prompt")
                .accessibilityLabel("Inject \(item.relativePath)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One instruction-file cell: 48×48 thumbnail (cached like
/// `ReadOnlyAttachmentGrid.FileCell` — body-time `NSWorkspace` icon as the
/// first-frame fallback, real thumbnail swapped in via `.task`), filename,
/// QuickLook on tap. Non-excluded cells carry a `RemoveBadgeButton`; excluded
/// (discovered) cells render dimmed with a restore badge.
private struct AgentInstructionCell: View {
    let item: AgentInstructionsSnapshot.Item
    let url: URL
    let onRemove: () -> Void
    let onRestore: () -> Void

    @State private var quickLookURL: URL?
    @State private var cachedThumbnail: NSImage?

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: cachedThumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle.squircle(CornerRadius.micro))
                    .opacity(item.isExcluded ? 0.35 : 1)
                    .onTapGesture { quickLookURL = url }

                if item.isExcluded {
                    restoreBadge
                } else if item.source == .manual || item.injectedContent != nil {
                    // X = "stop injecting" (discovered) / "detach" (manual).
                    // A plain listed discovered file gets no badge — excluding
                    // it would be a no-op (it stays listed either way).
                    RemoveBadgeButton(action: onRemove)
                }
            }

            Text(url.lastPathComponent)
                .font(Typography.term2xs)
                .foregroundStyle(item.isExcluded ? Colors.textTertiary : Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)
        }
        .frame(width: 64)
        .help(helpText)
        .quickLookPreview($quickLookURL)
        .task(id: url) {
            if let attachment = try? StagedAttachment(url: url, stagedRelativePath: item.relativePath) {
                cachedThumbnail = attachment.thumbnail()
            }
        }
    }

    /// Mirrors `RemoveBadgeButton`'s chip geometry with the opposite verb.
    private var restoreBadge: some View {
        Button(action: onRestore) {
            Image(systemName: "arrow.uturn.backward")
                .font(Typography.term2xs.weight(.bold))
                .foregroundStyle(Colors.textOnAccent)
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .offset(x: 6, y: -6)
        .help("Re-enable this instruction file")
        .accessibilityLabel("Restore \(item.relativePath)")
    }

    private var helpText: String {
        if item.isExcluded {
            return "\(item.relativePath) — content not injected; still listed for on-demand reading"
        }
        if item.injectedContent != nil {
            return "\(item.relativePath) — content injected into every role's system prompt"
        }
        return "\(item.relativePath) — listed in the prompt; roles read it on demand"
    }
}

// MARK: - Previews

#Preview("Work Folder Settings - No Folder") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    WorkFolderSettingsView()
        .environment(store)
        .frame(width: 500, height: 400)
}

#Preview("Scheme Section") {
    @Previewable @State var scheme: String? = "NanoTeams"
    SchemeSection(
        availableSchemes: ["NanoTeams", "NanoTeamsTests", "NanoTeamsUITests"],
        selectedScheme: $scheme
    )
    .padding()
    .background(Colors.surfacePrimary)
    .frame(width: 500, height: 100)
}

#Preview("Scheme Section - Empty") {
    @Previewable @State var scheme: String? = nil
    SchemeSection(availableSchemes: [], selectedScheme: $scheme)
        .padding()
        .background(Colors.surfacePrimary)
        .frame(width: 500, height: 100)
}
