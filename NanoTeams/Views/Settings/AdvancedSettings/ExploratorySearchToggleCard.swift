import SwiftUI

struct ExploratorySearchToggleCard: View {
    @Bindable var config: StoreConfiguration
    var onChanged: () -> Void

    var body: some View {
        SettingsCard(
            header: "Exploratory Search",
            systemImage: "magnifyingglass.circle",
            footer: "When ON, the `search` tool can broaden your query with synonyms, translations, and camelCase/snake_case variants via a local vocabulary vector index of all tokens in the work folder. Costs one local embedding call per exploratory search."
        ) {
            VStack(alignment: .leading, spacing: Spacing.standard) {
                Toggle(isOn: Binding(
                    get: { config.exploratorySearchEnabled },
                    set: { newValue in
                        config.exploratorySearchEnabled = newValue
                        onChanged()
                    }
                )) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Enable exploratory search")
                            .font(Typography.subheadline)
                        Text("Indexes the work folder in `.nanoteams/internal/search_index.json` and updates on file changes.")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textTertiary)
                    }
                }

                Toggle(isOn: $config.searchExploratoryByDefault) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Default `search` calls to exploratory")
                            .font(Typography.subheadline)
                        Text("When ON, `search(...)` calls without an explicit `exploratory` argument run in exploratory mode. OFF by default — the LLM has to opt in per call.")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textTertiary)
                    }
                }
                .disabled(!config.exploratorySearchEnabled)
            }
        }
    }
}

#Preview("Exploratory Search toggle") {
    ScrollView {
        ExploratorySearchToggleCard(config: StoreConfiguration(), onChanged: {})
            .padding()
    }
    .background(Colors.surfacePrimary)
}
