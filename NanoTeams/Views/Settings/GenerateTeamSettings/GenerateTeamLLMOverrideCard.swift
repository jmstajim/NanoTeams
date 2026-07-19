import SwiftUI

/// LLM override card for team generation. Reads model lists from the
/// shared `ModelCatalog`, so opening this card on the same server as the
/// global LLM card is a cache hit.
///
/// All fields are always visible. Empty fields fall back to the global
/// configuration — placeholders surface the live defaults so the user
/// sees what would be used. The override struct is automatically
/// created when any field is non-default and cleared back to `nil` once
/// every field is at its default.
struct GenerateTeamLLMOverrideCard: View {
    @Bindable var config: StoreConfiguration
    var onTokenSaveError: ((Error) -> Void)? = nil
    var onTokenLoadError: ((Error) -> Void)? = nil

    var body: some View {
        SettingsCard(
            header: "LLM Override",
            systemImage: "brain",
            footer: "Use a different LLM only for Generate Team. Empty fields fall back to the global configuration."
        ) {
            LLMOverrideEditor(
                config: config,
                keyPath: \.teamGenLLMOverride,
                onTokenSaveError: onTokenSaveError,
                onTokenLoadError: onTokenLoadError)
        }
    }
}

#Preview("LLM Override – disabled") {
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var catalog = ModelCatalog()
    ScrollView {
        GenerateTeamLLMOverrideCard(config: config)
            .padding()
    }
    .background(Colors.surfacePrimary)
    .environment(catalog)
}
