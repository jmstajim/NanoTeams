import SwiftUI

// MARK: - Settings View

/// Main settings window with sidebar navigation
struct SettingsView: View {
    @Environment(StoreConfiguration.self) var config
    @AppStorage(UserDefaultsKeys.appAppearance) private var appAppearance: AppAppearance = .system

    enum SettingsTab: String, CaseIterable, Identifiable, Codable {
        case llm = "LLM"
        case workFolder = "Work Folder"
        case general = "General"
        case teams = "Teams"
        case tools = "Tools"
        case help = "Help"

        var id: String { rawValue }

        private static let iconMap: [SettingsTab: String] = [
            .llm: "brain", .workFolder: "folder", .general: "gearshape",
            .teams: "rectangle.3.group", .tools: "wrench.and.screwdriver", .help: "questionmark.circle",
        ]

        var icon: String { Self.iconMap[self] ?? "questionmark" }
    }

    @AppStorage(UserDefaultsKeys.selectedSettingsTab) private var storedTab: SettingsTab = .llm
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            settingsSidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
        } detail: {
            settingsContent
                .background(Colors.surfacePrimary)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .frame(minWidth: 900, minHeight: 700)
        .background(Colors.surfacePrimary)
        .preferredColorScheme(appAppearance.colorScheme)
    }

    // MARK: - Sidebar

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsSection("Configuration", tabs: [.llm, .workFolder, .general])
            settingsSection("Team", tabs: [.teams, .tools])
            settingsSection("Support", tabs: [.help])
            Spacer()
        }
        .padding(.top, Spacing.standard)
        .background(Colors.surfaceBackground)
    }

    private func settingsSection(_ title: String, tabs: [SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title.uppercased())
                .font(Typography.captionSemibold)
                .foregroundStyle(Colors.textTertiary)
                .tracking(1.0)
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
        switch storedTab {
        case .llm:
            LLMSettingsView()
                .navigationTitle(SettingsTab.llm.rawValue)
        case .workFolder:
            WorkFolderSettingsView()
                .navigationTitle(SettingsTab.workFolder.rawValue)
        case .general:
            GeneralSettingsView()
                .navigationTitle(SettingsTab.general.rawValue)
        case .teams:
            TeamEditorView()
                .navigationTitle(SettingsTab.teams.rawValue)
        case .tools:
            ToolDefinitionEditorView()
                .navigationTitle(SettingsTab.tools.rawValue)
        case .help:
            HelpSettingsView()
                .navigationTitle(SettingsTab.help.rawValue)
        }
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
                    .font(isSelected ? Typography.subheadlineSemibold : Typography.subheadlineMedium)
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
    SettingsView()
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .frame(width: 900, height: 700)
}
