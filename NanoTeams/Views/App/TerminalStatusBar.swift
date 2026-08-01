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
    @Environment(ModelCatalog.self) private var modelCatalog

    // Read straight from this leaf's own `config` environment rather than as
    // parameters from `MainLayoutView`. Passing them down made `MainLayoutView.body`
    // an observer of these two properties, so every model/URL change re-evaluated
    // the whole layout (sidebar + detail), not just this status strip.
    private var modelName: String { config.llmModelName }
    private var baseURL: String { config.llmBaseURLString }

    private var hostAndPort: String {
        // Strip scheme + trailing slash for the tmux-style `host:port` reading.
        guard let url = URL(string: baseURL), let host = url.host else {
            return baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    private var displayModel: String {
        let trimmed = modelName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "—" : trimmed.uppercased()
    }

    private var availableModels: [String] {
        modelCatalog.models(for: baseURL, provider: config.llmProvider)
    }

    private var isFetchingModels: Bool {
        modelCatalog.isFetching(baseURL, provider: config.llmProvider)
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalDivider()
            statusRow
        }
        .background(Colors.surfaceBackground)
        .task(id: baseURL) {
            await modelCatalog.loadIfNeeded(url: baseURL, provider: config.llmProvider)
        }
    }

    private var statusRow: some View {
        HStack(spacing: Spacing.s) {
            settingsButton
            LLMStatusIndicator()
            separator
            statusLabel(hostAndPort)
            separator
            modelPicker

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

    /// Quick model switcher. Tapping the model label opens a menu listing the
    /// LM Studio server's loaded chat models; picking one writes through to
    /// `StoreConfiguration.llmModelName`. The fetched list is shared via
    /// `ModelCatalog` so settings cards stay in lockstep.
    private var modelPicker: some View {
        Menu {
            if availableModels.isEmpty {
                Text(isFetchingModels ? "Loading models…" : "No models available")
                    .foregroundStyle(Colors.textTertiary)
            } else {
                ForEach(availableModels, id: \.self) { model in
                    Button {
                        config.llmModelName = model
                    } label: {
                        if model == modelName {
                            Label(model, systemImage: "checkmark")
                        } else {
                            Text(model)
                        }
                    }
                }
            }

            Divider()

            Button {
                Task { await modelCatalog.refresh(url: baseURL, provider: config.llmProvider) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isFetchingModels)
        } label: {
            HStack(spacing: Spacing.xxs) {
                Text(displayModel)
                    .font(Typography.term2xs)
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Colors.textQuaternary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help(modelName.isEmpty ? "Switch model" : modelName)
        .accessibilityLabel("Model: \(displayModel)")
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
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var catalog = ModelCatalog()
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
