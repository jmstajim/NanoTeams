import SwiftUI

// MARK: - Terminal Status Bar
//
// tmux-style single-line status strip docked at the bottom of the main window.
// Settings + LLM reachability + endpoint on the left, model quick-picker in the
// middle, exploratory-search index progress on the right. All data is read
// straight from environment so the bar is a self-contained surface.

struct TerminalStatusBar: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(StoreConfiguration.self) private var config

    // Read straight from this leaf's own `config` environment rather than as
    // parameters from `MainLayoutView`. Passing them down made `MainLayoutView.body`
    // an observer of these two properties, so every model/URL change re-evaluated
    // the whole layout (sidebar + detail), not just this status strip.
    private var baseURL: String { config.llmBaseURLString }

    /// Strip scheme + trailing slash for the tmux-style `host:port` reading. The rule itself lives
    /// on `String` — the benchmark's target label and its leaderboard rows shorten endpoints the
    /// same way, and three copies of it drifted apart on the fallback branch.
    private var hostAndPort: String { baseURL.endpointHostLabel }

    var body: some View {
        VStack(spacing: 0) {
            TerminalDivider()
            statusRow
        }
        .background(Colors.surfaceBackground)
    }

    private var statusRow: some View {
        HStack(spacing: Spacing.s) {
            settingsButton
            LLMStatusIndicator()
            separator
            statusLabel(hostAndPort)
            separator
            ModelQuickPicker()

            Spacer(minLength: Spacing.s)

            PrefixCacheStatusIndicator()
            ExploratorySearchStatusIndicator()
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
    }

    private var settingsButton: some View {
        Button {
            SettingsNavigation.open(using: openWindow)
        } label: {
            Image(systemName: "gearshape")
                .font(Typography.term2xs)
                .foregroundStyle(Colors.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(",", modifiers: .command)
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
    }

    private func statusLabel(_ text: String) -> some View {
        Text(text)
            .font(Typography.term2xs)
            .tracking(Typography.labelTracking)
            .foregroundStyle(Colors.textSecondary)
            .lineLimit(1)
    }

    private var separator: some View {
        Text("·")
            .font(Typography.term2xs)
            .foregroundStyle(Colors.textQuaternary)
    }
}

// MARK: - Previews

#Preview("Status Bar") {
    @Previewable @State var monitor = LLMStatusMonitor()
    @Previewable @State var store = PreviewStore.make()
    @Previewable @State var catalog = PreviewStore.catalog()
    VStack {
        Spacer()
        TerminalStatusBar()
    }
    .frame(width: 1000, height: 240)
    .background(Colors.surfacePrimary)
    .environment(monitor)
    .environment(store)
    .environment(store.configuration)
    .environment(catalog)
}
