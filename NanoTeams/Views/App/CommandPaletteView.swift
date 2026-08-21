import SwiftUI

// MARK: - Command Palette View

/// Global command palette for quick navigation and actions
/// Command palette with typeahead search and keyboard navigation
struct CommandPaletteView: View {
    @Binding var selectedItem: MainLayoutView.NavigationItem?
    @Binding var isPresented: Bool
    @Environment(NTMSOrchestrator.self) var store
    @Environment(\.openWindow) private var openWindow

    @State private var searchText = ""
    @State private var hoveredCommandID: String?
    @FocusState private var isSearchFocused: Bool

    enum CommandCategory: String, CaseIterable {
        case navigate, create, workspace, recent
    }

    struct Command: Identifiable {
        let id: String
        let title: String
        let icon: String
        let category: CommandCategory
        let action: () -> Void
    }

    /// One terminal section in the palette — uppercase-mono header over its rows.
    struct CommandGroup: Identifiable {
        let category: CommandCategory
        let commands: [Command]
        var id: CommandCategory { category }
    }

    /// All commands in canonical order, before search filtering.
    private var allCommands: [Command] {
        var commands: [Command] = []

        commands.append(Command(id: "watchtower", title: "Go to Watchtower", icon: "binoculars", category: .navigate) {
            selectedItem = .watchtower
        })
        commands.append(Command(id: "new-task", title: "Create New Task", icon: "plus.circle", category: .create) {
            Task {
                if let taskID = await store.createTask(title: "New Task", supervisorTask: "TBD") {
                    await store.switchTask(to: taskID)
                    selectedItem = .task(taskID)
                }
            }
        })
        commands.append(Command(id: "settings", title: "Go to Settings", icon: "gear", category: .workspace) {
            SettingsNavigation.open(using: openWindow)
        })
        commands.append(Command(id: "open-folder", title: "Open Work Folder...", icon: "folder.badge.plus", category: .workspace) {
            NotificationCenter.default.post(name: .openProject, object: nil)
        })
        commands.append(Command(id: "close-folder", title: "Close Work Folder", icon: "xmark.circle", category: .workspace) {
            NotificationCenter.default.post(name: .closeProject, object: nil)
        })

        if let activeTask = store.activeTask {
            commands.insert(Command(id: "active-task", title: "Go to Active Task: \(activeTask.title)", icon: "hammer.circle", category: .navigate) {
                selectedItem = .task(activeTask.id)
            }, at: 0)
        }

        // Inject recent projects for quick switching
        let recentURLs = NSDocumentController.shared.recentDocumentURLs.prefix(5)
        for url in recentURLs where url != store.workFolderURL {
            commands.append(Command(id: "recent-\(url.lastPathComponent)", title: "Open Recent: \(url.lastPathComponent)", icon: "folder", category: .recent) {
                Task { await store.openWorkFolder(url) }
            })
        }

        return commands
    }

    /// Search-filtered commands grouped into terminal sections (canonical category order).
    /// Computed ONCE per render in `body` (see the `let groups` binding there) — it
    /// rebuilds `allCommands`, which touches `NSDocumentController.recentDocumentURLs`
    /// and `store.activeTask`, so reading it more than once per keystroke would
    /// repeat that work.
    private var groupedCommands: [CommandGroup] {
        let filtered = searchText.isEmpty
            ? allCommands
            : allCommands.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        return CommandCategory.allCases.compactMap { category in
            let matches = filtered.filter { $0.category == category }
            return matches.isEmpty ? nil : CommandGroup(category: category, commands: matches)
        }
    }

    private func commandRow(_ command: Command) -> some View {
        Button {
            command.action()
            isPresented = false
        } label: {
            HStack {
                Image(systemName: command.icon)
                    .frame(width: 24)
                    .foregroundStyle(hoveredCommandID == command.id ? Colors.accent : Colors.textPrimary)
                Text(command.title)
                Spacer()
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(hoveredCommandID == command.id ? Colors.accentTint : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            hoveredCommandID = isHovered ? command.id : nil
        }
    }

    var body: some View {
        // Compute the search pipeline ONCE per render. `groupedCommands` rebuilds
        // `allCommands` (recent-documents lookup + active-task read) every access,
        // so deriving both the empty-state check and the flat Enter-target list
        // from one binding avoids running it 2–3× per keystroke.
        let groups = groupedCommands
        let flat = groups.flatMap(\.commands)
        return VStack(spacing: 0) {
            HStack {
                PromptMarker(cursor: false)
                TextField("type a command…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Typography.termXl)
                    .focused($isSearchFocused)
                    .onSubmit {
                        if let firstCommand = flat.first {
                            firstCommand.action()
                            isPresented = false
                        }
                    }
                
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Colors.surfaceCard)

            TerminalDivider()

            if flat.isEmpty {
                VStack(spacing: Spacing.m) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(Colors.textTertiary)
                        .accessibilityHidden(true)
                    Text("No commands found")
                        .font(Typography.termLg)
                        .foregroundStyle(Colors.textSecondary)
                    Text("Try a different search term")
                        .font(Typography.termBase)
                        .foregroundStyle(Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.commands) { command in
                                commandRow(command)
                            }
                        } header: {
                            MonoLabel(text: group.category.rawValue)
                                .padding(.top, Spacing.xs)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 450, idealWidth: 500, maxWidth: 600)
        .frame(minHeight: 280, idealHeight: 320, maxHeight: 500)
        .background(NTMSBackground())
        .onAppear {
            isSearchFocused = true
        }
        .onExitCommand {
            isPresented = false
        }
    }
}

// MARK: - Previews

#Preview("Default") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var selected: MainLayoutView.NavigationItem? = .watchtower
    @Previewable @State var isPresented = true
    CommandPaletteView(selectedItem: $selected, isPresented: $isPresented)
        .environment(store)
}

#Preview("With Search") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var selected: MainLayoutView.NavigationItem? = nil
    @Previewable @State var isPresented = true
    CommandPaletteView(selectedItem: $selected, isPresented: $isPresented)
        .environment(store)
}
