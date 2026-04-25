import SwiftUI

/// Settings page for advanced / experimental features. Currently hosts the
/// broad-search toggle, index status, and semantic-embedding card.
/// Owns shared state and delegates rendering to the cards under
/// `AdvancedSettings/`.
struct AdvancedSettingsView: View {
    @Environment(NTMSOrchestrator.self) var store
    @Environment(StoreConfiguration.self) var config

    var body: some View {
        @Bindable var config = config

        ScrollView {
            VStack(spacing: Spacing.xl) {
                ExpandedSearchToggleCard(
                    config: config,
                    onChanged: {
                        Task { await store.onExpandedSearchSettingChanged() }
                    }
                )

                ExpandedSearchIndexStatusCard(
                    coordinator: store.searchIndexCoordinator,
                    onRebuild: {
                        Task { await store.searchIndexCoordinator?.rebuild() }
                    }
                )

                ExpandedSearchEmbeddingsCard(
                    config: config,
                    coordinator: store.searchIndexCoordinator,
                    onRebuild: {
                        Task { await store.searchIndexCoordinator?.rebuildVectorIndex() }
                    },
                    onForceFullRebuild: {
                        Task { await store.searchIndexCoordinator?.rebuildVectorIndexFull() }
                    }
                )
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
    }
}

#Preview("Advanced Settings") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    AdvancedSettingsView()
        .environment(store)
        .environment(store.configuration)
        .frame(width: 720, height: 800)
}
