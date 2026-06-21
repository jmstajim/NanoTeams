import SwiftUI

// MARK: - LLM Status Indicators
//
// Status pills that report LLM reachability and exploratory-search index
// build progress. Hosted by `TerminalStatusBar`; tapping either jumps to
// the relevant Settings tab.

/// Exploratory-search index rebuild indicator. Visible only while the coordinator
/// is rebuilding the token index or the vocab vector index. Tapping opens
/// Settings → Exploratory Search.
struct ExploratorySearchStatusIndicator: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(NTMSOrchestrator.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(UserDefaultsKeys.selectedSettingsTab)
    private var selectedSettingsTab: SettingsView.SettingsTab = .llm

    private var isBuilding: Bool {
        guard let coordinator = store.searchIndexCoordinator else { return false }
        return coordinator.isBuilding || coordinator.isBuildingVectorIndex
    }

    var body: some View {
        // The `.transition` on the pill only animates inside an animation
        // transaction — without `.animation(value:)` driving the appear/disappear
        // it pops in/out instantly. The deleted `SidebarFooter` had this driver;
        // re-established here keyed on the build state. (CLAUDE.md observation:
        // a `.transition` is inert unless the conditional change is animated.)
        ZStack {
            if isBuilding { pill }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isBuilding)
    }

    private var pill: some View {
        Button {
            selectedSettingsTab = .exploratorySearch
            openWindow(id: "settings")
        } label: {
            HStack(spacing: Spacing.xs) {
                NTMSLoader(font: Typography.term2xs, color: Colors.accent)
                Text("INDEXING")
                    .font(Typography.term2xs)
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(Colors.accent)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle.squircle(CornerRadius.small).fill(Colors.accentTint)
            )
            .contentShape(RoundedRectangle.squircle(CornerRadius.small))
        }
        .buttonStyle(.plain)
        .help("Rebuilding exploratory-search index — click to open settings")
        .accessibilityLabel("Exploratory search index rebuilding")
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

/// LLM reachability indicator. Tapping opens Settings at the LLM tab.
struct LLMStatusIndicator: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(LLMStatusMonitor.self) private var monitor
    @AppStorage(UserDefaultsKeys.selectedSettingsTab)
    private var selectedSettingsTab: SettingsView.SettingsTab = .llm

    var body: some View {
        let isReachable = monitor.isReachable
        Button {
            selectedSettingsTab = .llm
            openWindow(id: "settings")
        } label: {
            HStack(spacing: Spacing.xs) {
                Text("●")
                    .font(.system(size: 7))
                    .foregroundStyle(isReachable ? Colors.success : Colors.error)
                Text(isReachable ? "ONLINE" : "OFFLINE")
                    .font(Typography.term2xs)
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(isReachable ? Colors.success : Colors.error)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(isReachable ? Colors.successTint : Colors.errorTint)
            )
            .contentShape(RoundedRectangle.squircle(CornerRadius.small))
        }
        .buttonStyle(.plain)
        .help(isReachable ? "LLM is online" : "LLM is offline — click to configure")
        .accessibilityLabel("LLM status: \(isReachable ? "Online" : "Offline")")
    }
}
