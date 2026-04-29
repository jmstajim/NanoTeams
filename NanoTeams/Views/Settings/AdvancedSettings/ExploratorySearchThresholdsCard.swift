import SwiftUI

/// Cosine-similarity thresholds used by the semantic-expansion query
/// pipeline. Split out of `ExploratorySearchEmbeddingsCard` so the
/// embeddings card stays focused on server / model config (Vision-card
/// shape: URL + token + model picker).
struct ExploratorySearchThresholdsCard: View {
    @Bindable var config: StoreConfiguration

    var body: some View {
        SettingsCard(
            header: "Query Thresholds",
            systemImage: "slider.horizontal.3",
            footer: "Higher thresholds keep semantic expansion stricter — only very close neighbors surface. Lower thresholds widen the net at the cost of noise."
        ) {
            thresholdSlider(
                title: "Per-token threshold",
                caption: "Cosine similarity threshold for nearest-neighbor lookup in the vocabulary index.",
                value: $config.exploratorySearchPerTokenThreshold,
                range: 0.5...0.95
            )
            thresholdSlider(
                title: "Out-of-vocabulary threshold",
                caption: "Cosine similarity threshold for queries that require a fresh embedding (multi-word phrases or out-of-vocab tokens).",
                value: $config.exploratorySearchPhraseThreshold,
                range: 0.4...0.9
            )
        }
    }

    private func thresholdSlider(
        title: String,
        caption: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(title).font(Typography.subheadline)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(Typography.subheadlineMedium)
                    .monospacedDigit()
                    .foregroundStyle(Colors.textPrimary)
            }
            Slider(value: value, in: range, step: 0.01)
            Text(caption)
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
        }
    }
}

#Preview {
    ExploratorySearchThresholdsCard(config: StoreConfiguration())
        .padding()
        .background(Colors.surfacePrimary)
}
