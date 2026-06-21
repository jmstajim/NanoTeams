import SwiftUI

/// Vision (image analysis) configuration as a top-level Settings tab.
///
/// Owns the `LLMVisionCard`. The card binds its enable toggle directly to
/// `StoreConfiguration.visionEnabled` (persisted), so the state survives
/// tab switches and app restarts. The card itself owns its model-fetch
/// loop so it can gate fetches on the override fields.
struct VisionSettingsView: View {
    @Environment(StoreConfiguration.self) var config
    @Environment(NTMSOrchestrator.self) var store

    /// Per-vision-server bearer token. `LLMTokenField` (inside
    /// `LLMEndpointEditor`) owns the load/save lifecycle keyed by the live
    /// vision URL — when the vision URL is empty the field lookup falls back
    /// to the main LLM URL via inheritance handled at the resolver layer.
    @State private var apiToken: String = ""

    var body: some View {
        @Bindable var config = config

        ScrollView {
            VStack(spacing: Spacing.xl) {
                LLMVisionCard(
                    config: config,
                    apiToken: $apiToken,
                    onTokenSaveError: { error in
                        store.lastErrorMessage = "Could not save API token: \(error.localizedDescription)"
                    },
                    onTokenLoadError: { error in
                        store.lastErrorMessage = "Could not read saved API token: \(error.localizedDescription)"
                    }
                )
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
    }
}

#Preview {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var catalog = ModelCatalog()
    VisionSettingsView()
        .environment(store)
        .environment(store.configuration)
        .environment(catalog)
}
