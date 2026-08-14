import SwiftUI

/// Settings page for the Exploratory Search feature — toggle, index status, and
/// semantic-embedding configuration. Owns shared state and delegates rendering
/// to the cards under `AdvancedSettings/`.
struct ExploratorySearchSettingsView: View {
    @Environment(NTMSOrchestrator.self) var store
    @Environment(StoreConfiguration.self) var config

    var body: some View {
        @Bindable var config = config

        ScrollView {
            VStack(spacing: Spacing.xl) {
                ExploratorySearchToggleCard(
                    config: config,
                    onChanged: {
                        Task { await store.onExploratorySearchSettingChanged() }
                    }
                )

                ExploratorySearchIndexStatusCard(
                    coordinator: store.searchIndexCoordinator,
                    clearFailure: store.searchIndexClearFailure,
                    onRebuild: {
                        Task { await store.searchIndexCoordinator?.rebuild() }
                    }
                )

                ExploratorySearchWatcherDebounceCard(config: config)

                ExploratorySearchEmbeddingsCard(
                    config: config,
                    coordinator: store.searchIndexCoordinator,
                    onRebuild: {
                        Task { await store.searchIndexCoordinator?.rebuildVectorIndex() }
                    },
                    onForceFullRebuild: {
                        Task { await store.searchIndexCoordinator?.rebuildVectorIndexFull() }
                    },
                    onConfigChanged: {
                        Task { await store.onExploratorySearchEmbeddingConfigChanged() }
                    },
                    onTokenSaveError: { error in
                        store.lastErrorMessage = "Could not save API token: \(error.localizedDescription)"
                    },
                    onTokenLoadError: { error in
                        store.lastErrorMessage = "Could not read saved API token: \(error.localizedDescription)"
                    }
                )

                ExploratorySearchThresholdsCard(config: config)
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
    }
}

#Preview("Exploratory Search Settings") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    ExploratorySearchSettingsView()
        .environment(store)
        .environment(store.configuration)
        .frame(width: 720, height: 800)
}
