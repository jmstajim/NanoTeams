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
        case toolBehavior = "Tool Behavior"
        case debug = "Debug"
        case teams = "Teams"
        case generateTeam = "Generate Team"
        case tools = "Tools"
        case help = "Help"
        case updates = "Updates"

        var id: String { rawValue }

        private static let iconMap: [SettingsTab: String] = [
            .llm: "brain", .workFolder: "folder", .autovisor: "bolt.badge.automatic", .general: "gearshape",
            .theme: "paintbrush.pointed",
            .dictation: "mic", .vision: "eye", .exploratorySearch: "binoculars",
            .toolBehavior: "slider.horizontal.3",
            .debug: "ladybug",
            .teams: "rectangle.3.group",
            .generateTeam: "wand.and.stars",
            .tools: "wrench.and.screwdriver", .help: "questionmark.circle",
            .updates: "sparkles",
        ]

        var icon: String { Self.iconMap[self] ?? "questionmark" }
    }

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
        VStack(alignment: .leading, spacing: 0) {
            settingsSection("Configuration", tabs: [.general, .theme, .llm, .workFolder, .autovisor])
            settingsSection("Advanced", tabs: [.exploratorySearch, .vision, .dictation, .toolBehavior, .debug])
            settingsSection("Team", tabs: [.teams, .generateTeam, .tools])
            settingsSection("Support", tabs: [.help, .updates])
            Spacer()
        }
        .padding(.top, Spacing.standard)
        .background(Colors.surfaceBackground)
    }

    private func settingsSection(_ title: String, tabs: [SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            MonoLabel(text: title, rule: true)
                .padding(.horizontal, Spacing.standard)
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.xs)

            ForEach(tabs) { tab in
                SettingsRowView(tab: tab, isSelected: storedTab == tab) {
                    storedTab = tab
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
            case .toolBehavior:
                ToolBehaviorSettingsView()
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
    SettingsView()
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .environment(modelCatalog)
        .environment(dictation)
        .environment(AppUpdateState(config: store.configuration))
        .frame(width: 900, height: 700)
}
