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
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
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
}

#Preview {
    LLMSettingsView()
        .environment(StoreConfiguration())
}
