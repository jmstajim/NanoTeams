import SwiftUI
import AppKit

// MARK: - Work Folder Cards

extension SidebarView {

    /// No-folder state — labelled `▌ WORK FOLDER` section explaining default
    /// storage, with an `[ open folder ]` CTA and a muted "show storage"
    /// secondary affordance. Sibling of `projectInfoCard` — shares its
    /// terminal-DS chrome (MonoLabel marker, mono type, TerminalDivider,
    /// bracketed buttons) so the two states read as the same block.
    var defaultStorageCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            // Section label — pairs with `▌ TASKS` below and matches the
            // active state's header for visual rhythm.
            MonoLabel(text: "Work folder", marker: true)

            // Status row: glyph + name + supporting subtitle.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(TerminalGlyph.idle)
                        .font(Typography.termSm)
                        .foregroundStyle(Colors.textTertiary)
                        .accessibilityHidden(true)
                    Text("No folder selected")
                        .font(Typography.termMd)
                        .foregroundStyle(Colors.textPrimary)
                        .lineLimit(1)
                }
                Text("Files stored in default storage.")
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Primary CTA — bracketed DS button.
            HStack(spacing: Spacing.s) {
                Button { isPresentingFolderPicker = true } label: {
                    Text("open folder")
                }
                .buttonStyle(.terminalSecondary)
                .accessibilityHint("Choose a folder to open as the work folder")

                Spacer(minLength: 0)
            }

            // Secondary affordance — muted text link to default-storage dir.
            Button {
                if !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NTMSOrchestrator.defaultStorageURL.path) {
                    store.lastErrorMessage = "Could not open storage folder"
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Text(TerminalGlyph.prompt)
                        .font(Typography.term2xs)
                        .foregroundStyle(Colors.accent)
                        .accessibilityHidden(true)
                    Text("show storage in finder")
                        .font(Typography.term2xs)
                        .foregroundStyle(Colors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, Spacing.xs)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Flat DS block — no card; full-width bottom hairline (TerminalDivider).
        .overlay(alignment: .bottom) { TerminalDivider() }
    }

    /// Active work-folder block — a labelled `▌ WORK FOLDER` section with the
    /// folder name + home-relative path, an inline ⋯ actions menu, and a
    /// context slot underneath (generate CTA / live loader / context body).
    /// Aligns with the design's terminal language (MonoLabel marker, mono
    /// type, TerminalDivider hairline, `.terminalGhost` bracketed CTA).
    func projectInfoCard(folder: URL) -> some View {
        let hasContext = !(store.workFolder?.settings.context.isEmpty ?? true)
        let isGenerating = store.isGeneratingWorkFolderContext
        return VStack(alignment: .leading, spacing: Spacing.s) {
            // Section label — pairs with `▌ TASKS` below for rhythm.
            MonoLabel(text: "Work folder", marker: true)

            // Folder identity: name + home-relative path on the left,
            // ⋯ actions menu on the right.
            HStack(alignment: .top, spacing: Spacing.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "folder")
                                .font(Typography.termSm)
                                .foregroundStyle(Colors.textTertiary)
                                .accessibilityHidden(true)
                            Text(folder.lastPathComponent)
                                .font(Typography.termMd)
                                .foregroundStyle(Colors.textPrimary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")

                    // Home-relativized path — truncates at the leading edge so
                    // the deepest folder stays visible (real-terminal trait).
                    Text(homeRelativePath(folder))
                        .font(Typography.term2xs)
                        .foregroundStyle(Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(folder.path)
                }

                Spacer(minLength: Spacing.xs)

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
                                Label(url.lastPathComponent, systemImage: "folder")
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
                    Divider()
                    Button {
                        SettingsNavigation.open(tab: .workFolder, using: openWindow)
                    } label: {
                        Label("Work Folder Settings", systemImage: "gearshape")
                    }
                } label: {
                    SidebarIconButton(icon: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }

            // Context slot — `Generating` takes priority over `hasContext`
            // so a regeneration kicked off from Settings (which keeps the
            // previous context in place until the new one streams in) is
            // visible here too. Tap-to-cancel works from either surface.
            contextSlot(hasContext: hasContext, isGenerating: isGenerating)
        }
        .padding(.leading, Spacing.m)
        // Shared single source of truth for the trailing ⋯ alignment: the card
        // pads to `menuTrailingInset` directly; the Autovisor nav row reaches the
        // same x as chrome inset + a derived nudge. See `SidebarNavRowMetrics`.
        .padding(.trailing, SidebarNavRowMetrics.menuTrailingInset)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Flat DS block — no card; full-width bottom hairline (TerminalDivider).
        .overlay(alignment: .bottom) { TerminalDivider() }
    }

    /// Context slot variants — generating loader, body text, or generate CTA.
    @ViewBuilder
    private func contextSlot(hasContext: Bool, isGenerating: Bool) -> some View {
        if isGenerating {
            Button {
                store.cancelWorkFolderContextGeneration()
            } label: {
                HStack(spacing: Spacing.xs) {
                    NTMSLoader(font: Typography.termXs, color: Colors.accent)
                    Text("generating context…")
                        .font(Typography.termXs)
                        .foregroundStyle(Colors.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Tap to cancel")
        } else if hasContext {
            Text(store.workFolder?.settings.context ?? "")
                .font(Typography.termXs)
                .foregroundStyle(Colors.textSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
        } else {
            Button {
                store.startGeneratingWorkFolderContext()
            } label: {
                Text("generate context")
            }
            .buttonStyle(.terminalGhost)
            .accessibilityHint("Describe this project so the AI understands it")
        }
    }

    /// Replace `$HOME` prefix with `~` for terminal-style path display.
    /// Falls back to the absolute path when the folder is outside the home dir.
    private func homeRelativePath(_ url: URL) -> String {
        let path = url.path
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - Sidebar Icon Button

/// Compact circular icon button with hover highlight. Shared by the work-folder
/// card and the Autovisor nav entry (both expose an ⋯ actions menu).
struct SidebarIconButton: View {
    let icon: String
    @State private var isHovered = false

    var body: some View {
        Image(systemName: icon)
            .font(Typography.caption)
            .foregroundStyle(Colors.textSecondary)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(isHovered ? Colors.surfaceElevated : .clear)
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

// MARK: - Preview Helpers

// periphery:ignore - used in #Preview below
private func makeCardPreviewStore(folder: URL?) -> NTMSOrchestrator {
    let s = PreviewStore.make()
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
        .environment(LLMStatusMonitor())
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
        .environment(LLMStatusMonitor())
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
        .environment(LLMStatusMonitor())
        .frame(width: 280, height: 500)
}
