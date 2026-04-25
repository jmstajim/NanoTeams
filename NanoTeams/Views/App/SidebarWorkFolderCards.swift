import SwiftUI
import AppKit

// MARK: - Work Folder Cards

extension SidebarView {

    /// No-folder state — prominent CTA to open a work folder.
    var defaultStorageCard: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.surfaceElevated)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "folder.badge.plus")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    )
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("No Work Folder")
                        .font(Typography.subheadlineSemibold)
                        .foregroundStyle(.primary)
                    Text("Select a folder to access and manage files")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                        .lineLimit(2)
                }
            }

            Button { isPresentingFolderPicker = true } label: {
                Text("Open Folder")
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
            .frame(maxWidth: .infinity)

            Button {
                if !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NTMSOrchestrator.defaultStorageURL.path) {
                    store.lastErrorMessage = "Could not open storage folder"
                }
            } label: {
                Text("Show Storage in Finder")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.m)
        .background(
            RoundedRectangle.squircle(CornerRadius.medium)
                .fill(Colors.surfaceCard)
        )
    }

    /// Active project card — compact row with folder icon, name, dropdown, settings gear.
    func projectInfoCard(folder: URL) -> some View {
        let hasDescription = !(store.workFolder?.settings.description.isEmpty ?? true)
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                // Folder icon — tap to reveal in Finder
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                } label: {
                    RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                        .fill(Colors.surfaceElevated)
                        .frame(width: 30, height: 30)
                        .overlay(
                            Image(systemName: "folder.fill")
                                .font(Typography.caption)
                                .foregroundStyle(.secondary)
                        )
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                // Work folder name
                Text(folder.lastPathComponent)
                    .font(Typography.subheadlineSemibold)
                    .lineLimit(1)
                    .help(folder.path)

                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    // Folder actions menu
                    Menu {
                        Button {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                        } label: {
                            Label("Reveal in Finder", systemImage: "arrow.right.circle")
                        }
                        if let coordinator = store.searchIndexCoordinator {
                            Button {
                                Task { await coordinator.rebuild() }
                            } label: {
                                Label(
                                    coordinator.isBuilding ? "Rebuilding Index…" : "Rebuild Search Index",
                                    systemImage: "arrow.clockwise"
                                )
                            }
                            .disabled(coordinator.isBuilding)
                        }
                        Divider()
                        let recents = recentProjects.prefix(5)
                        if !recents.isEmpty {
                            ForEach(Array(recents), id: \.self) { url in
                                Button {
                                    Task { await store.openWorkFolder(url) }
                                } label: {
                                    Label(url.lastPathComponent, systemImage: "folder.fill")
                                }
                                .disabled(url == store.workFolderURL)
                            }
                            Divider()
                        }
                        Button { isPresentingFolderPicker = true } label: {
                            Label("Open Other...", systemImage: "folder.badge.plus")
                        }
                        Divider()
                        Button(role: .destructive) { handleCloseProject() } label: {
                            Label("Close Work Folder", systemImage: "xmark.circle")
                        }
                    } label: {
                        SidebarIconButton(icon: "ellipsis")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)

                    Button {
                        selectedSettingsTab = .workFolder
                        openWindow(id: "settings")
                    } label: {
                        SidebarIconButton(icon: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .help("Work Folder Settings")
                }
            }

            // Description or generate button
            if hasDescription {
                Text(store.workFolder?.settings.description ?? "")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            } else {
                Button {
                    if isGeneratingDescription {
                        generateDescriptionTask?.cancel()
                        generateDescriptionTask = nil
                        isGeneratingDescription = false
                        store.lastInfoMessage = "Generation stopped"
                    } else {
                        generateDescriptionTask = Task {
                            isGeneratingDescription = true
                            defer { if !Task.isCancelled { isGeneratingDescription = false } }
                            if let description = await store.generateWorkFolderDescription() {
                                guard !Task.isCancelled else { return }
                                await store.updateWorkFolderDescription(description)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        ZStack {
                            if isGeneratingDescription { NTMSLoader(.mini) }
                            else { Image(systemName: "sparkles").font(Typography.caption) }
                        }
                        .frame(width: 12, height: 12)
                        Text(isGeneratingDescription ? "Generating..." : "Generate Description")
                            .font(Typography.caption)
                    }
                    .foregroundStyle(isGeneratingDescription ? Colors.textSecondary : Colors.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, Spacing.xs)
        .padding(.vertical, Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Colors.surfaceCard)
        )
    }
}

// MARK: - Sidebar Icon Button

/// Compact circular icon button with hover highlight.
private struct SidebarIconButton: View {
    let icon: String
    @State private var isHovered = false

    var body: some View {
        Image(systemName: icon)
            .font(Typography.caption)
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(
                Circle()
                    .fill(isHovered ? Colors.surfaceElevated : .clear)
            )
            .contentShape(Circle())
            .onHover { isHovered = $0 }
    }
}

// MARK: - Preview Helpers

// periphery:ignore - used in #Preview below
private func makeCardPreviewStore(folder: URL?) -> NTMSOrchestrator {
    let s = NTMSOrchestrator(repository: NTMSRepository())
    s.workFolderURL = folder
    return s
}

// MARK: - Previews

#Preview("Sidebar — Default Storage Card") {
    @Previewable @State var store = makeCardPreviewStore(folder: NTMSOrchestrator.defaultStorageURL)
    @Previewable @State var taskState = TaskManagementState()
    @Previewable @State var selected: MainLayoutView.NavigationItem? = .watchtower
    SidebarView(taskState: taskState, selectedItem: $selected)
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .frame(width: 280, height: 500)
}

#Preview("Sidebar — Work Folder Card Short Name") {
    @Previewable @State var store = makeCardPreviewStore(folder: URL(fileURLWithPath: "/Users/dev/MyApp"))
    @Previewable @State var taskState = TaskManagementState()
    @Previewable @State var selected: MainLayoutView.NavigationItem? = .watchtower
    SidebarView(taskState: taskState, selectedItem: $selected)
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .frame(width: 280, height: 500)
}

#Preview("Sidebar — Work Folder Card Long Name") {
    @Previewable @State var store = makeCardPreviewStore(folder: URL(fileURLWithPath: "/Users/developer/Documents/VeryLongProjectNameThatWillTruncate"))
    @Previewable @State var taskState = TaskManagementState()
    @Previewable @State var selected: MainLayoutView.NavigationItem? = .watchtower
    SidebarView(taskState: taskState, selectedItem: $selected)
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .frame(width: 280, height: 500)
}
