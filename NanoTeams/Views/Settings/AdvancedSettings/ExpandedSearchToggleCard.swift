import SwiftUI

struct ExpandedSearchToggleCard: View {
    @Bindable var config: StoreConfiguration
    var onChanged: () -> Void

    var body: some View {
        SettingsCard(
            header: "Expanded Search",
            systemImage: "magnifyingglass.circle",
            footer: "When ON, the `search` tool can broaden your query with synonyms, translations, and camelCase/snake_case variants via a local vocabulary vector index of all tokens in the work folder. Costs one local embedding call per expanded search."
        ) {
            Toggle(isOn: Binding(
                get: { config.expandedSearchEnabled },
                set: { newValue in
                    config.expandedSearchEnabled = newValue
                    onChanged()
                }
            )) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Enable expanded search")
                        .font(Typography.subheadline)
                    Text("Indexes the work folder in `.nanoteams/internal/search_index.json` and updates on file changes.")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                }
            }
        }
    }
}

#Preview("Expanded Search toggle") {
    ScrollView {
        ExpandedSearchToggleCard(config: StoreConfiguration(), onChanged: {})
            .padding()
    }
    .background(Colors.surfacePrimary)
}
