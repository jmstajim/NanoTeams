import SwiftUI

/// Vision (image analysis) configuration as a top-level Settings tab.
///
/// Owns the `LLMVisionCard` previously embedded in the LLM Settings sheet,
/// plus auto-default behavior: if no vision model is chosen, adopt the main
/// LLM model when it appears in the vision-capable list.
struct VisionSettingsView: View {
    @Environment(StoreConfiguration.self) var config

    @State private var visionEnabled: Bool = false
    @State private var visionAvailableModels: [String] = []
    @State private var isFetchingVisionModels: Bool = false
    @State private var visionModelFetchError: String?

    var body: some View {
        @Bindable var config = config

        ScrollView {
            VStack(spacing: Spacing.xl) {
                LLMVisionCard(
                    config: config,
                    visionEnabled: $visionEnabled,
                    visionAvailableModels: visionAvailableModels,
                    isFetchingVisionModels: isFetchingVisionModels,
                    visionModelFetchError: visionModelFetchError,
                    onFetchVisionModels: { Task { await fetchVisionModels() } }
                )
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
        .task {
            visionEnabled = config.isVisionConfigured
            if visionEnabled {
                await fetchVisionModels()
            }
        }
        .onChange(of: visionEnabled) { oldValue, newValue in
            if !oldValue, newValue {
                Task { await fetchVisionModels() }
            }
        }
    }

    // MARK: - Actions

    private func fetchVisionModels() async {
        isFetchingVisionModels = true
        visionModelFetchError = nil
        defer { isFetchingVisionModels = false }

        do {
            let visionURL = config.visionBaseURLString.isEmpty ? config.llmBaseURLString : config.visionBaseURLString
            let fetchConfig = LLMConfig(
                provider: config.llmProvider,
                baseURLString: visionURL,
                modelName: config.visionModelName
            )
            visionAvailableModels = try await LLMClientRouter().fetchModels(config: fetchConfig, visionOnly: true)

            if config.visionModelName.isEmpty,
               visionAvailableModels.contains(config.llmModelName) {
                config.visionModelName = config.llmModelName
            }
        } catch {
            visionModelFetchError = error.localizedDescription
        }
    }
}

#Preview {
    VisionSettingsView()
        .environment(StoreConfiguration())
}
