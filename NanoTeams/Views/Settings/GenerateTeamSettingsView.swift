import SwiftUI

/// Settings page for Generate Team flow. Delegates rendering to focused
/// cards under `GenerateTeamSettings/`. The LLM-override card reads its
/// model list from the shared `ModelCatalog`, so this parent doesn't
/// need any fetch state of its own.
struct GenerateTeamSettingsView: View {
    @Environment(StoreConfiguration.self) var config
    @Environment(NTMSOrchestrator.self) var store

    var body: some View {
        @Bindable var config = config

        ScrollView {
            VStack(spacing: Spacing.xl) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Colors.info)
                    Text("All settings are optional. Empty fields fall back to the global LLM config and built-in prompt.")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                GenerateTeamLLMOverrideCard(
                    config: config,
                    onTokenSaveError: { error in
                        store.lastErrorMessage = "Could not save API token: \(error.localizedDescription)"
                    },
                    onTokenLoadError: { error in
                        store.lastErrorMessage = "Could not read saved API token: \(error.localizedDescription)"
                    }
                )

                GenerateTeamSystemPromptCard(config: config)

                GenerateTeamDefaultsCard(config: config)
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
    }
}

#Preview("Generate Team Settings") {
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var catalog = ModelCatalog()
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    GenerateTeamSettingsView()
        .environment(config)
        .environment(catalog)
        .environment(store)
        .frame(width: 720, height: 800)
}
