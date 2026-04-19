import SwiftUI

// MARK: - Menu Command Notifications

extension Notification.Name {
    static let navigateToWatchtower = Notification.Name("navigateToWatchtower")
    static let navigateToActiveTask = Notification.Name("navigateToActiveTask")
    static let openProject = Notification.Name("openProject")
    static let closeProject = Notification.Name("closeProject")
    static let createNewTask = Notification.Name("createNewTask")
    static let startRun = Notification.Name("startRun")
    static let pauseRun = Notification.Name("pauseRun")
    static let resumeRun = Notification.Name("resumeRun")
    static let scrollFeedToBottom = Notification.Name("scrollFeedToBottom")
}

// MARK: - App

@main
struct NanoTeamsApp: App {
    /// True when the process is hosted by XCTest — skip heavy init to avoid crashes on CI.
    private static let isRunningTests = NSClassFromString("XCTestCase") != nil

    @State private var store: NTMSOrchestrator
    @State private var folderAccess = FolderAccessManager()
    @State private var llmStatusMonitor = LLMStatusMonitor()
    @State private var appUpdateState: AppUpdateState
    @AppStorage(UserDefaultsKeys.appAppearance) private var appAppearance: AppAppearance = .system

    init() {
        // Explicit init so `AppUpdateState` can share the same `StoreConfiguration`
        // instance that `NTMSOrchestrator` owns. SwiftUI's `@State` default-value
        // initializers can't reference each other, so we build both here and
        // inject via `State(initialValue:)`.
        let orchestrator = NTMSOrchestrator(repository: NTMSRepository())
        _store = State(initialValue: orchestrator)
        _appUpdateState = State(initialValue: AppUpdateState(config: orchestrator.configuration))
    }

    var body: some Scene {
        WindowGroup {
            if Self.isRunningTests {
                Color.clear
            } else {
                MainLayoutView()
                    .environment(store)
                    .environment(store.engineState)
                    .environment(store.configuration)
                    .environment(store.streamingPreviewManager)
                    .environment(folderAccess)
                    .environment(llmStatusMonitor)
                    .environment(appUpdateState)
                    .preferredColorScheme(appAppearance.colorScheme)
                    .onAppear {
                        QuickCaptureController.shared.setup(store: store)
                        llmStatusMonitor.startMonitoring(
                            baseURLProvider: { store.configuration.llmBaseURLString }
                        )
                    }
                    .task {
                        // Background GitHub releases probe — 24h throttled.
                        // Silent on failure so offline users don't see banners.
                        await appUpdateState.refresh()
                    }
            }
        }
        .defaultSize(
            width: WindowLayout.mainDefaultWidth,
            height: WindowLayout.mainDefaultHeight
        )
        .commands {
            // File Menu - Open Work Folder
            CommandGroup(after: .newItem) {
                Button("Open Work Folder...") {
                    NotificationCenter.default.post(name: .openProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Close Work Folder") {
                    NotificationCenter.default.post(name: .closeProject, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }

            // Replace New Item with New Task
            CommandGroup(replacing: .newItem) {
                Button("New Task...") {
                    NotificationCenter.default.post(name: .createNewTask, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            // View Menu — append to system View menu (preserves Show/Hide Sidebar)
            CommandGroup(after: .sidebar) {
                Divider()

                Button("Watchtower") {
                    NotificationCenter.default.post(name: .navigateToWatchtower, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Active Task") {
                    NotificationCenter.default.post(name: .navigateToActiveTask, object: nil)
                }
                .keyboardShortcut("3", modifiers: .command)
            }

            // Task Menu (context-sensitive commands)
            CommandMenu("Task") {
                Button("Quick Task...") {
                    QuickCaptureController.shared.togglePanel()
                }
                .keyboardShortcut("0", modifiers: [.command, .option, .control])

                Divider()

                Button("Start Run...") {
                    NotificationCenter.default.post(name: .startRun, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Pause") {
                    NotificationCenter.default.post(name: .pauseRun, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Resume") {
                    NotificationCenter.default.post(name: .resumeRun, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)
            }

            // Help Menu addition
            CommandGroup(replacing: .help) {
                Link("NanoTeams Help", destination: URL(string: "https://github.com/NanoTeams/docs")!)
            }
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(store)
                .environment(store.engineState)
                .environment(store.configuration)
                .environment(store.streamingPreviewManager)
                .environment(appUpdateState)
        }
        .defaultSize(width: 1000, height: 700)
        .restorationBehavior(.disabled)
    }
}
