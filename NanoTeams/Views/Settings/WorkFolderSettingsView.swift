import SwiftUI

struct WorkFolderSettingsView: View {
    @Environment(NTMSOrchestrator.self) var store
    @State private var descriptionDraft: String = ""
    @State private var promptDraft: String = ""
    @State private var isGenerating = false
    @State private var isShowingResetConfirmation = false
    @State private var isShowingCloseConfirmation = false
    @State private var isPromptExpanded = false
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
            Text("This will restore the work folder description, teams, roles, and tools to their default values. Existing tasks and runs will be preserved but might reference missing configurations. This action cannot be undone.")
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
        .onAppear {
            if let p = store.workFolder {
                descriptionDraft = p.settings.description
                promptDraft = p.settings.descriptionPrompt
            }
            recentProjects = NSDocumentController.shared.recentDocumentURLs
            Task { availableSchemes = await store.fetchAvailableSchemes() }
        }
        .onChange(of: store.workFolder?.id) { _, _ in
            if let p = store.workFolder {
                descriptionDraft = p.settings.description
                promptDraft = p.settings.descriptionPrompt
            }
        }
        .onChange(of: store.workFolder?.settings.description) { _, newValue in
            if let val = newValue { descriptionDraft = val }
        }
        .onChange(of: store.workFolder?.settings.descriptionPrompt) { _, newValue in
            if let val = newValue { promptDraft = val }
        }
    }

    // MARK: - Folder Header Card

    private var folderHeaderCard: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let folder = store.workFolderURL {
                SettingsItemHeader(
                    icon: "folder.fill",
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
                        Text("Recent")
                            .font(Typography.captionSemibold)
                            .foregroundStyle(Colors.textTertiary)

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
                                    Image(systemName: "folder.fill")
                                        .font(Typography.caption)
                                        .foregroundStyle(.tertiary)
                                    Text(url.lastPathComponent)
                                        .font(Typography.caption)
                                        .foregroundStyle(url == store.workFolderURL ? Colors.textTertiary : .secondary)
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

    // MARK: - Description Card

    private var descriptionCard: some View {
        SettingsCard(
            header: "Work Folder Description",
            systemImage: "doc.text",
            footer: "This description is sent to all AI roles as work folder context. Use Generate to create it from your files, or write your own."
        ) {
            TextEditor(text: $descriptionDraft)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150)
                .padding(Spacing.s)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                        .fill(Colors.surfaceElevated)
                )
                .onChange(of: descriptionDraft) { _, newValue in
                    saveTask?.cancel()
                    saveTask = Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        if store.workFolder?.settings.description != newValue {
                            await store.updateWorkFolderDescription(newValue)
                        }
                    }
                }

            HStack {
                Button {
                    Task {
                        isGenerating = true
                        if let description = await store.generateWorkFolderDescription() {
                            descriptionDraft = description
                        }
                        isGenerating = false
                    }
                } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "sparkles")
                        Text(isGenerating ? "Generating..." : "Generate")
                        if isGenerating { NTMSLoader(.inline) }
                    }
                    .font(Typography.captionSemibold)
                    .foregroundStyle(Colors.surfaceBackground)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(Capsule(style: .continuous).fill(Colors.accent))
                }
                .buttonStyle(.plain)
                .disabled(isGenerating)

                Button {
                    isPromptExpanded.toggle()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Prompt")
                    }
                    .font(Typography.captionSemibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Colors.surfaceElevated)
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isPromptExpanded) {
                    promptPopoverContent
                }

                Spacer()

                savingIndicator(isVisible: store.workFolder?.settings.description != descriptionDraft)
            }
        }
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
            NTMSSectionHeader(title: "Danger Zone", systemImage: "exclamationmark.triangle")

            VStack(alignment: .leading, spacing: Spacing.m) {
                Button {
                    isShowingResetConfirmation = true
                } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset Work Folder Settings")
                    }
                    .font(Typography.captionSemibold)
                    .foregroundStyle(Colors.error)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Colors.errorTint)
                    )
                }
                .buttonStyle(.plain)

                Text("Restores work folder description, teams, roles, and tools to their default values. Tasks and runs are preserved.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
            .padding(Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Colors.errorTint)
            )
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func savingIndicator(isVisible: Bool) -> some View {
        if isVisible {
            HStack(spacing: Spacing.xs) {
                NTMSLoader(.inline)
                Text("Saving...")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
        }
    }

    private var promptPopoverContent: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Generation Prompt")
                .font(Typography.subheadlineSemibold)

            Text("Controls what the AI focuses on when analyzing the folder.")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)

            TextEditor(text: $promptDraft)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160)
                .padding(Spacing.s)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                        .fill(Colors.surfaceElevated)
                )
                .onChange(of: promptDraft) { _, newValue in
                    promptSaveTask?.cancel()
                    promptSaveTask = Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        if store.workFolder?.settings.descriptionPrompt != newValue {
                            await store.updateDescriptionPrompt(newValue)
                        }
                    }
                }

            HStack {
                Button {
                    promptDraft = AppDefaults.workFolderDescriptionPrompt
                } label: {
                    Text("Reset to Default")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.accent)
                }
                .buttonStyle(.plain)
                .disabled(promptDraft == AppDefaults.workFolderDescriptionPrompt)

                Spacer()

                savingIndicator(isVisible: store.workFolder?.settings.descriptionPrompt != promptDraft)
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
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Colors.warning)
                Text("No Xcode schemes found")
                    .font(Typography.subheadline)
                    .foregroundStyle(Colors.textSecondary)
            }
        } else {
            Picker(
                "Scheme",
                selection: Binding(
                    get: { selectedScheme ?? "" },
                    set: { selectedScheme = $0.isEmpty ? nil : $0 }
                )
            ) {
                Text("Select a scheme").tag("")
                ForEach(availableSchemes, id: \.self) { scheme in
                    Text(scheme).tag(scheme)
                }
            }
            .pickerStyle(.menu)
        }
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
