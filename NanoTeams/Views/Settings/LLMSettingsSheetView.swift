import SwiftUI

/// LLM settings with card layout.
///
/// Holds shared state (connection status, fetched model lists) and dispatches to
/// focused card sub-views in `Views/Settings/LLMSettings/`.
struct LLMSettingsView: View {
    @Environment(StoreConfiguration.self) var config

    @State private var connectionStatus: LLMConnectionStatus = .idle
    @State private var statusMessage: String = ""
    @State private var availableModels: [String] = []
    @State private var isFetchingModels: Bool = false
    @State private var modelFetchError: String?
    @State private var visionEnabled: Bool = false
    @State private var visionAvailableModels: [String] = []
    @State private var isFetchingVisionModels: Bool = false
    @State private var visionModelFetchError: String?

    var body: some View {
        @Bindable var config = config

        ScrollView {
            VStack(spacing: Spacing.xl) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Colors.info)
                    Text("Requires LM Studio 0.4.0 or later.")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                LLMServerConfigCard(
                    config: config,
                    connectionStatus: connectionStatus,
                    statusMessage: statusMessage,
                    availableModels: availableModels,
                    isFetchingModels: isFetchingModels,
                    modelFetchError: modelFetchError,
                    onTestConnection: { Task { await testConnection() } },
                    onFetchModels: { Task { await fetchModels() } }
                )

                LLMGenerationCard(config: config)

                LLMErrorHandlingCard(config: config)

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
        .onAppear {
            visionEnabled = config.isVisionConfigured
        }
    }

    // MARK: - Actions

    private func testConnection() async {
        connectionStatus = .checking
        statusMessage = ""

        let result = await LLMConnectionChecker.checkWithMessage(baseURL: config.llmBaseURLString)
        connectionStatus = result.isReachable ? .success : .failure
        statusMessage = result.message
        if result.isReachable {
            await fetchModels()
        }
    }

    private func fetchModels() async {
        guard config.llmProvider.supportsModelFetching else {
            availableModels = []
            return
        }

        isFetchingModels = true
        modelFetchError = nil
        defer { isFetchingModels = false }

        do {
            availableModels = try await LLMConnectionChecker.fetchAvailableModels(config: config)
        } catch {
            modelFetchError = error.localizedDescription
        }
    }

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
        } catch {
            visionModelFetchError = error.localizedDescription
        }
    }
}

#Preview {
    LLMSettingsView()
        .environment(StoreConfiguration())
}
