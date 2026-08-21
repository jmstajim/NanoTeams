import SwiftUI

// MARK: - Settings View

/// Main settings window with sidebar navigation
struct SettingsView: View {
    @Environment(StoreConfiguration.self) var config
    @AppStorage(UserDefaultsKeys.activeTheme) private var activeThemeRaw: String = Theme.defaultTheme.rawValue

    private var activeTheme: Theme {
        Theme(rawValue: activeThemeRaw) ?? Theme.defaultTheme
    }

    nonisolated enum SettingsTab: String, CaseIterable, Identifiable, Codable {
        case llm = "LLM"
        case workFolder = "Work Folder"
        case autovisor = "Autovisor"
        case general = "General"
        case theme = "Theme"
        case dictation = "Dictation"
        case vision = "Vision"
        case exploratorySearch = "Exploratory Search"
        case benchmark = "Benchmark"
        case toolBehavior = "Tool Behavior"
        case bash = "Bash"
        case computerUse = "Computer Use"
        case debug = "Debug"
        case teams = "Teams"
        case generateTeam = "Generate Team"
        case tools = "Tools"
        case help = "Help"
        case updates = "Updates"

        var id: String { rawValue }

        private static let iconMap: [SettingsTab: String] = [
            .llm: "brain", .benchmark: "speedometer", .workFolder: "folder",
            .autovisor: AutovisorConstants.symbolName, .general: "gearshape",
            .theme: "paintbrush.pointed",
            .dictation: "mic", .vision: "eye", .exploratorySearch: "binoculars",
            .toolBehavior: "slider.horizontal.3",
            .bash: "terminal",
            .computerUse: "cursorarrow.rays",
            .debug: "ladybug",
            .teams: "rectangle.3.group",
            .generateTeam: "wand.and.stars",
            .tools: "wrench.and.screwdriver", .help: "questionmark.circle",
            .updates: "sparkles",
        ]

        var icon: String { Self.iconMap[self] ?? "questionmark" }
    }

    nonisolated struct SettingsSection: Identifiable {
        let id: String
        /// `nil` renders the section with no `MonoLabel` header (a pinned, header-less group).
        let title: String?
        let tabs: [SettingsTab]
    }

    /// Single source of truth for the sidebar grouping (pinned by `SettingsSidebarSectionsTests`).
    /// Membership rules — so sections don't regrow into a grab-bag like the old 7-tab "Advanced":
    /// - (pinned) Updates + LLM: header-less quick-access rows at the very top — the two screens
    ///   reached most often. LLM is also the default tab (`storedTab` below) and the setting the
    ///   whole app hangs off, so it renders as the one hero row (`SettingsLLMHeroRow`) — emphasis
    ///   by weight and live status, not by position. Capped at two tabs by
    ///   `SettingsSidebarSectionsTests` — a pinned group that grows stops being pinned.
    /// - Workspace: who does the work in this folder — the folder itself, its teams, and the
    ///   automation supervising them
    /// - Capabilities: optional model-powered add-ons the app can switch on, each with its own
    ///   server/model (Vision, Exploratory Search, Generate Team — the last is app-scoped
    ///   generation defaults + LLM override, capability-shaped rather than folder-shaped).
    ///   The app's primary model endpoint is pinned at the top, not here.
    /// - Agent Tools: governs what agents may execute and how far tools reach (gates → caps → registry)
    /// - Application: personal app-shell preferences (Dictation is input, not a model)
    /// - Support: maintenance and diagnostics — Benchmark lives here because it measures the
    ///   configured endpoint's generation speed and grants no capability
    nonisolated static let sidebarSections: [SettingsSection] = [
        SettingsSection(id: "pinned", title: nil, tabs: [.updates, .llm]),
        SettingsSection(id: "workspace", title: "Workspace", tabs: [.workFolder, .teams, .autovisor]),
        SettingsSection(id: "capabilities", title: "Capabilities", tabs: [.vision, .exploratorySearch, .generateTeam]),
        SettingsSection(id: "agentTools", title: "Agent Tools", tabs: [.bash, .computerUse, .toolBehavior, .tools]),
        SettingsSection(id: "application", title: "Application", tabs: [.general, .theme, .dictation]),
        SettingsSection(id: "support", title: "Support", tabs: [.benchmark, .debug, .help]),
    ]

    @AppStorage(UserDefaultsKeys.selectedSettingsTab) private var storedTab: SettingsTab = .llm

    var body: some View {
        // Custom flat sidebar + detail (mirrors MainLayoutView) — replaces the
        // native NavigationSplitView, whose draggable divider, collapse control,
        // and vibrancy column don't match the terminal design.
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 230)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Colors.borderSubtle)
                        .frame(width: 1)
                        .ignoresSafeArea()
                }

            // Detail in a NavigationStack so per-tab navigationTitle/toolbars still work.
            NavigationStack {
                settingsContent
                    .background(Colors.surfacePrimary)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 700)
        .background(Colors.surfacePrimary)
        .preferredColorScheme(activeTheme.preferredColorScheme)
        .toggleStyle(.terminal)
    }

    // MARK: - Sidebar

    private var settingsSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.sidebarSections) { section in
                    settingsSection(section)
                }
            }
            .padding(.top, Spacing.standard)
        }
        .background(Colors.surfaceBackground)
    }

    private func settingsSection(_ section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            if let title = section.title {
                MonoLabel(text: title, rule: true)
                    .padding(.horizontal, Spacing.standard)
                    .padding(.top, Spacing.l)
                    .padding(.bottom, Spacing.xs)
            }

            ForEach(section.tabs) { tab in
                // LLM is THE emphasized tab (see the pinned-group rationale on
                // `sidebarSections`), so it renders as the hero row wherever the
                // grouping puts it — the array stays the pure source of truth.
                if tab == .llm {
                    SettingsLLMHeroRow(isSelected: storedTab == tab) {
                        storedTab = tab
                    }
                } else {
                    SettingsRowView(tab: tab, isSelected: storedTab == tab) {
                        storedTab = tab
                    }
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var settingsContent: some View {
        // Pin the window title to "Settings" regardless of selected tab —
        // the sidebar already shows the current tab in the highlight cell,
        // so duplicating it in the title bar (`General` / `LLM` / etc.)
        // reads as redundant. Title applied once via `Group` so the chrome
        // stays stable across tab switches.
        Group {
            switch storedTab {
            case .llm:
                LLMSettingsView()
            case .workFolder:
                WorkFolderSettingsView()
            case .autovisor:
                AutovisorSettingsView()
            case .general:
                GeneralSettingsView()
            case .theme:
                ThemeSettingsView()
            case .dictation:
                DictationSettingsView()
            case .vision:
                VisionSettingsView()
            case .exploratorySearch:
                ExploratorySearchSettingsView()
            case .benchmark:
                BenchmarkSettingsView()
            case .toolBehavior:
                ToolBehaviorSettingsView()
            case .bash:
                BashSettingsView()
            case .computerUse:
                ComputerUseSettingsView()
            case .debug:
                DebugSettingsView()
            case .teams:
                TeamEditorView()
            case .generateTeam:
                GenerateTeamSettingsView()
            case .tools:
                ToolDefinitionEditorView()
            case .help:
                HelpSettingsView()
            case .updates:
                UpdatesSettingsView()
            }
        }
        .navigationTitle("")
    }

}

// MARK: - LLM Hero Row

/// The one emphasized sidebar row: LLM is the setting the whole app hangs off, so its
/// row carries live state — the configured model (or the provider, before a model is
/// picked) and the reachability dot — instead of the plain icon+label the other tabs get.
/// Internal rather than `private` so `subtitle(modelName:provider:)` stays pinned from
/// `SettingsSidebarSectionsTests`.
struct SettingsLLMHeroRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    // Observed HERE, not on the sidebar (CLAUDE.md View Conventions #11): the monitor's
    // poll tick and LLM-config edits re-render only this leaf, not the whole section list.
    @Environment(LLMStatusMonitor.self) private var monitor
    @Environment(StoreConfiguration.self) private var configuration

    @State private var isHovered = false

    private static let tab = SettingsView.SettingsTab.llm

    var body: some View {
        let isReachable = monitor.isReachable
        Button(action: onSelect) {
            HStack(spacing: Spacing.m) {
                RoundedRectangle.squircle(CornerRadius.small)
                    // `accentTintStrong` under selection so the icon container stays
                    // distinct from the row's own accentTint selection fill.
                    .fill(isSelected ? Colors.accentTintStrong : Colors.accentTint)
                    .frame(width: SettingsLayout.toggleIconSize, height: SettingsLayout.toggleIconSize)
                    .overlay(
                        Image(systemName: Self.tab.icon)
                            .font(Typography.subheadlineSemibold)
                            .foregroundStyle(Colors.accent)
                    )

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(Self.tab.rawValue)
                        .font(Typography.subheadlineMedium)
                        .foregroundStyle(Colors.textPrimary)
                    Text(Self.subtitle(modelName: configuration.llmModelName, provider: configuration.llmProvider))
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Text("●")
                    .font(.system(size: 7))
                    .foregroundStyle(isReachable ? Colors.success : Colors.error)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(isSelected ? Colors.accentTint : (isHovered ? Colors.surfaceHover : .clear))
                    .padding(.horizontal, Spacing.s)
            )
        }
        .buttonStyle(.plain)
        .trackHover($isHovered)
        .animationWithReduceMotion(Animations.quick, value: isHovered)
        .animationWithReduceMotion(Animations.quick, value: isSelected)
        .help(LLMStatusIndicator.tooltip(isReachable: isReachable, lastCheckedAt: monitor.lastCheckedAt))
        .accessibilityLabel("LLM settings — \(isReachable ? "online" : "offline")")
        .accessibilityHint("Configure llm settings")
        // Opening Settings is an explicit user gesture, same as opening the status-bar
        // model picker — the case `checkNow()`'s doc names; without it the dot is up to
        // one poll interval stale exactly when the user came to look at it. Coalescing
        // against an in-flight probe is built into the monitor.
        .task { await monitor.checkNow() }
    }

    /// What the second line shows: the configured model, or the provider before any
    /// model is picked. Trims because a whitespace-only model name would render as a
    /// blank line — which reads as a layout bug rather than "not configured".
    nonisolated static func subtitle(modelName: String, provider: LLMProvider) -> String {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.displayName : trimmed
    }
}

// MARK: - Settings Row

private struct SettingsRowView: View {
    let tab: SettingsView.SettingsTab
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 20

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Spacing.m) {
                Image(systemName: tab.icon)
                    .font(Typography.subheadlineSemibold)
                    .foregroundStyle(isSelected ? Colors.textPrimary : Colors.textSecondary)
                    .frame(width: iconWidth)

                Text(tab.rawValue)
                    // Fixed weight across selected / unselected so the cell
                    // height + glyph metrics don't reflow on selection — DS
                    // signals selection through the accentTint fill, not
                    // through type-weight emphasis.
                    .font(Typography.subheadlineMedium)
                    .foregroundStyle(isSelected ? Colors.textPrimary : Colors.textSecondary)

                Spacer()
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(isSelected ? Colors.accentTint : (isHovered ? Colors.surfaceHover : .clear))
                    .padding(.horizontal, Spacing.s)
            )
        }
        .buttonStyle(.plain)
        .trackHover($isHovered)
        .animationWithReduceMotion(Animations.quick, value: isHovered)
        .animationWithReduceMotion(Animations.quick, value: isSelected)
        .accessibilityHint("Configure \(tab.rawValue.lowercased()) settings")
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var modelCatalog = ModelCatalog()
    @Previewable @State var dictation = DictationService()
    @Previewable @State var llmStatusMonitor = LLMStatusMonitor()
    SettingsView()
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .environment(modelCatalog)
        .environment(dictation)
        .environment(AppUpdateState(config: store.configuration))
        .environment(llmStatusMonitor)
        .frame(width: 900, height: 700)
}
