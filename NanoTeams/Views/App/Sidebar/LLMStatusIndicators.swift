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
            SettingsNavigation.open(tab: .exploratorySearch, using: openWindow)
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

    var body: some View {
        let isReachable = monitor.isReachable
        Button {
            SettingsNavigation.open(tab: .llm, using: openWindow)
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
        .help(Self.tooltip(isReachable: isReachable, lastCheckedAt: monitor.lastCheckedAt))
        .accessibilityLabel("LLM status: \(isReachable ? "Online" : "Offline")")
    }

    /// Carries `lastCheckedAt`, which had no reader at all. Without it a re-probe
    /// that finds the server still down changes nothing on screen, so the user
    /// cannot tell the check ran — which is exactly the case they are staring at.
    ///
    /// ABSOLUTE time, not "N seconds ago", and that is forced rather than chosen.
    /// `.help(...)` takes a `String` computed during `body`, and this view's only
    /// observation dependencies are the two monitor properties `publish()` writes
    /// together — so a self-driven render always sees ~0 elapsed. A relative clause
    /// would therefore be baked as "just now" and keep saying it minutes later,
    /// i.e. state something false about the world. A wall-clock stamp stays true no
    /// matter when the body last ran, and still moves visibly when a probe lands.
    nonisolated static func tooltip(isReachable: Bool, lastCheckedAt: Date?) -> String {
        let base = isReachable ? "LLM is online" : "LLM is offline — click to configure"
        guard let lastCheckedAt else { return base }
        return "\(base) — checked \(lastCheckedAt.formatted(date: .omitted, time: .standard))"
    }
}
