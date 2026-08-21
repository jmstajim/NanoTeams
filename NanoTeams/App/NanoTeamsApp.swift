import SwiftUI

// MARK: - Menu Command Notifications

/// `nonisolated` — these are Foundation value constants with no actor
/// affinity. Without it the app target's `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor` makes each `static let` main-actor isolated, which blocks any
/// `nonisolated` type (e.g. the `AppMenuCommand` effect table) from naming
/// them.
nonisolated extension Notification.Name {
    static let navigateToWatchtower = Notification.Name("navigateToWatchtower")
    static let navigateToActiveTask = Notification.Name("navigateToActiveTask")
    static let navigateToAutovisor = Notification.Name("navigateToAutovisor")
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
    @State private var dictation: DictationService
    @State private var appUpdateState: AppUpdateState
    /// Process-wide cache of LM Studio model lists. Shared across every
    /// settings surface that picks a model so opening multiple cards on
    /// the same server doesn't re-issue `/api/v1/models`.
    @State private var modelCatalog = ModelCatalog()
    /// The benchmark's measuring loop and its scan of what each provider has.
    ///
    /// Owned here rather than by `BenchmarkSettingsView` because a sweep over
    /// every model on the machine runs for the better part of an hour, and
    /// `SettingsView` swaps its content on every tab switch — state held by that
    /// view loses its progress the first time the user looks at anything else.
    /// Closing Settings deliberately does not stop it.
    @State private var benchmarkSweep: BenchmarkSweepRunner
    /// Single source of truth for the active theme — System / Light / Dark /
    /// OLED / Arctic / ... Observed at app root so a switch invalidates every
    /// descendant `body`; `Colors.themed(...)` reads `Theme.current` per
    /// resolution to pull fresh hexes, and the matching
    /// `.preferredColorScheme(_:)` modifier propagates scheme intent.
    @AppStorage(UserDefaultsKeys.activeTheme) private var activeThemeRaw: String = Theme.defaultTheme.rawValue

    init() {
        // One-shot migration of the legacy `appAppearance` UserDefaults key
        // ("system" / "light" / "dark") into the unified `activeTheme` slot.
        // Idempotent — once `activeTheme` is set, subsequent launches no-op.
        Theme.migrateLegacyAppearanceIfNeeded()

        // Explicit init so dependents share the same `StoreConfiguration` /
        // orchestrator reference. SwiftUI's `@State` default-value initializers
        // can't reference each other, so we build them here and inject via
        // `State(initialValue:)`.
        let orchestrator = NTMSOrchestrator(repository: NTMSRepository())
        _store = State(initialValue: orchestrator)
        _appUpdateState = State(initialValue: AppUpdateState(config: orchestrator.configuration))
        _dictation = State(initialValue: DictationService(
            onErrorSurfaced: { message in orchestrator.lastErrorMessage = message }
        ))

        let catalog = ModelCatalog()
        _modelCatalog = State(initialValue: catalog)
        _benchmarkSweep = State(initialValue: Self.makeBenchmarkSweep(
            store: orchestrator, catalog: catalog))
    }

    /// Assembles the benchmark's measuring loop.
    ///
    /// Every seam of `GenerationBenchmarkRunner` is passed explicitly because each of its `nil`s
    /// would resolve OUTWARD to a live server (CLAUDE.md #49) — and this is now the app's single
    /// construction site for it, so the arguments are stated once, here, where they can be read
    /// beside each other.
    private static func makeBenchmarkSweep(
        store: NTMSOrchestrator, catalog: ModelCatalog
    ) -> BenchmarkSweepRunner {
        let history = BenchmarkHistoryStore()
        let configuration = store.configuration
        return BenchmarkSweepRunner(
            runner: GenerationBenchmarkRunner(
                client: LLMClientRouter(),
                // The single construction site, and therefore the kill switch: swapping this one
                // argument disables every provenance probe, websocket included, without a setting
                // to maintain.
                probe: ServerProvenanceRouter(),
                store: history,
                // The app's own H1 hygiene check: roles stream concurrently by design, and a
                // sample taken while another stream shares the machine measures both.
                isBusy: { [weak store] in store?.hasRunningTasks ?? false }),
            history: history,
            discovery: ModelCatalogDiscovery(catalog: catalog),
            isBusy: { [weak store] in store?.hasRunningTasks ?? false },
            settings: configuration)
    }

    /// Resolved active theme — single point that decodes the persisted raw
    /// value used by `.preferredColorScheme(...)` callers below.
    private var activeTheme: Theme {
        Theme(rawValue: activeThemeRaw) ?? Theme.defaultTheme
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
                    .environment(dictation)
                    .environment(appUpdateState)
                    .environment(modelCatalog)
                    .preferredColorScheme(activeTheme.preferredColorScheme)
                    .fontDesign(.monospaced)
                    // Drive native SwiftUI controls (focus rings, pickers, default
                    // selection) off the THEMED accent rather than the fixed
                    // AccentColor asset, so they don't diverge per theme.
                    .tint(Colors.accent)
                    // Force a tree rebuild when the user picks a new theme so
                    // every `Colors.*` access pulls fresh hexes. Theme switches
                    // are rare (one tap from Settings), so the rebuild cost is
                    // acceptable in exchange for an instant, complete visual
                    // swap including AppKit-resident views.
                    .id(activeThemeRaw)
                    // Every hand-off lives in `AppDependencyWiring` — this closure is
                    // unreachable under XCTest (see `isRunningTests` above), so wiring
                    // written inline here can never be verified.
                    .onAppear {
                        AppDependencyWiring.wire(
                            store: store,
                            dictation: dictation,
                            quickCapture: .shared,
                            statusMonitor: llmStatusMonitor
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
        // Which commands appear in which menu, and in what order, is genuine
        // SwiftUI declaration and stays here. WHAT each command is — title,
        // shortcut, effect — lives in `AppMenuCommand`, where the table can be
        // checked for shortcut collisions and dead notifications.
        .commands {
            // File Menu - Open Work Folder
            CommandGroup(after: .newItem) {
                AppMenuButton(.openWorkFolder)
                Divider()
                AppMenuButton(.closeWorkFolder)
            }

            // Replace New Item with New Task
            CommandGroup(replacing: .newItem) {
                AppMenuButton(.newTask)
            }

            // View Menu — append to system View menu (preserves Show/Hide Sidebar)
            CommandGroup(after: .sidebar) {
                Divider()
                AppMenuButton(.watchtower)
                AppMenuButton(.activeTask)
            }

            // Task Menu (context-sensitive commands)
            CommandMenu("Task") {
                AppMenuButton(.quickTask)
                Divider()
                AppMenuButton(.startRun)
                AppMenuButton(.pause)
                AppMenuButton(.resume)
            }

            // Help Menu addition
            CommandGroup(replacing: .help) {
                Link(AppMenuCommand.HelpLink.title,
                     destination: AppMenuCommand.HelpLink.destination)
            }
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(store)
                .environment(store.engineState)
                .environment(store.configuration)
                .environment(store.streamingPreviewManager)
                .environment(dictation)
                .environment(appUpdateState)
                .environment(modelCatalog)

                .environment(benchmarkSweep)
                // Without this, Test Connection can report SUCCESS while the status
                // strip keeps saying OFFLINE until the next poll tick.
                .environment(llmStatusMonitor)
                .preferredColorScheme(activeTheme.preferredColorScheme)
                .fontDesign(.monospaced)
                .tint(Colors.accent)
                .id(activeThemeRaw)
        }
        .defaultSize(width: 1000, height: 700)
        .restorationBehavior(.disabled)

        // Standalone window for any "open in new window" Activity Feed detail
        // (LLM/meeting/supervisor thinking, tool calls, artifacts, meeting tools).
        // SwiftUI dedups by `Hashable` value: clicking the same record again
        // focuses the existing window rather than opening a duplicate.
        WindowGroup(for: ActivityDetailWindow.self) { $detail in
            if let detail {
                ActivityDetailWindowView(detail: detail)
                    .environment(store)
                    .environment(store.configuration)
                    .preferredColorScheme(activeTheme.preferredColorScheme)
                    .fontDesign(.monospaced)
                    .tint(Colors.accent)
                    .id(activeThemeRaw)
            }
        }
        .defaultSize(width: 720, height: 560)
        .restorationBehavior(.disabled)
    }
}
