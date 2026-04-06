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

    struct Command: Identifiable {
        let id: String
        let title: String
        let icon: String
        let action: () -> Void
    }

    var filteredCommands: [Command] {
        var commands: [Command] = []

        commands.append(Command(id: "watchtower", title: "Go to Watchtower", icon: "binoculars.fill") {
            selectedItem = .watchtower
        })
        commands.append(Command(id: "new-task", title: "Create New Task", icon: "plus.circle.fill") {
            Task {
                if let taskID = await store.createTask(title: "New Task", supervisorTask: "TBD") {
                    await store.switchTask(to: taskID)
                    selectedItem = .task(taskID)
                }
            }
        })
        commands.append(Command(id: "settings", title: "Go to Settings", icon: "gear") {
            openWindow(id: "settings")
        })
        commands.append(Command(id: "open-folder", title: "Open Work Folder...", icon: "folder.badge.plus") {
            NotificationCenter.default.post(name: .openProject, object: nil)
        })
        commands.append(Command(id: "close-folder", title: "Close Work Folder", icon: "xmark.circle") {
            NotificationCenter.default.post(name: .closeProject, object: nil)
        })

        if let activeTask = store.activeTask {
            commands.insert(Command(id: "active-task", title: "Go to Active Task: \(activeTask.title)", icon: "hammer.circle.fill") {
                selectedItem = .task(activeTask.id)
            }, at: 0)
        }

        // Inject recent projects for quick switching
        let recentURLs = NSDocumentController.shared.recentDocumentURLs.prefix(5)
        for url in recentURLs where url != store.workFolderURL {
            commands.append(Command(id: "recent-\(url.lastPathComponent)", title: "Open Recent: \(url.lastPathComponent)", icon: "folder.fill") {
                Task { await store.openWorkFolder(url) }
            })
        }

        if searchText.isEmpty {
            return commands
        } else {
            return commands.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                TextField("Type a command...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit {
                        if let firstCommand = filteredCommands.first {
                            firstCommand.action()
                            isPresented = false
                        }
                    }
                
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Colors.surfaceCard)
            
            Divider()
            
            if filteredCommands.isEmpty {
                VStack(spacing: Spacing.m) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("No commands found")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Try a different search term")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredCommands) { command in
                        Button {
                            command.action()
                            isPresented = false
                        } label: {
                            HStack {
                                Image(systemName: command.icon)
                                    .frame(width: 24)
                                    .foregroundStyle(hoveredCommandID == command.id ? Colors.accent : .primary)
                                Text(command.title)
                                Spacer()
                            }
                            .padding(.horizontal, Spacing.s)
                            .padding(.vertical, Spacing.xs)
                            .background(
                                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                    .fill(hoveredCommandID == command.id ? Colors.accentTint : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovered in
                            hoveredCommandID = isHovered ? command.id : nil
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
