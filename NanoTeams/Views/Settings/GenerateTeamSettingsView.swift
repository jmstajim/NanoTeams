import SwiftUI

/// Settings page for Generate Team flow. Owns shared state (model fetch) and
/// delegates rendering to focused cards under `GenerateTeamSettings/`.
struct GenerateTeamSettingsView: View {
    @Environment(StoreConfiguration.self) var config
    var client: any LLMClient = LLMClientRouter()

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
                    Text("All settings are optional. Empty fields fall back to the global LLM config and built-in prompt.")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                GenerateTeamLLMOverrideCard(
                    config: config,
                    availableModels: availableModels,
                    isFetchingModels: isFetchingModels,
                    modelFetchError: modelFetchError,
                    onFetchModels: { Task { await fetchModels() } }
                )

                GenerateTeamSystemPromptCard(config: config)

                GenerateTeamDefaultsCard(config: config)
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
        .onAppear {
            if config.teamGenLLMOverride != nil && availableModels.isEmpty && !isFetchingModels {
                Task { await fetchModels() }
            }
        }
    }

    // MARK: - Actions

    private func fetchModels() async {
        guard let override = config.teamGenLLMOverride else { return }
        isFetchingModels = true
        modelFetchError = nil
        defer { isFetchingModels = false }

        let fetchConfig = LLMConfig(
            provider: .lmStudio,
            baseURLString: override.baseURLString ?? config.llmBaseURLString,
            modelName: override.modelName
        )

        do {
            availableModels = try await client.fetchModels(config: fetchConfig, visionOnly: false)
        } catch {
            modelFetchError = error.localizedDescription
        }
    }
}

#Preview("Generate Team Settings") {
    GenerateTeamSettingsView()
        .environment(StoreConfiguration())
        .frame(width: 720, height: 800)
}
