import SwiftUI

/// Settings card for the semantic vector index powering `expand`.
/// Three sections, top-to-bottom:
/// 1. Status — count, coverage, model name, failures.
/// 2. Model config — embedding server URL + model name.
/// 3. Thresholds — per-token and whole-phrase cosine cutoffs.
/// Plus a primary "Rebuild embeddings" button and an overflow-menu action
/// for a force-full rebuild.
struct ExpandedSearchEmbeddingsCard: View {
    @Bindable var config: StoreConfiguration
    var coordinator: SearchIndexCoordinator?
    var onRebuild: () -> Void
    var onForceFullRebuild: () -> Void
    /// Injected for testability. Defaults to the real router.
    var client: any LLMClient = LLMClientRouter()

    // MARK: - Picker state
    //
    // Scoped to this card (not persisted). Re-fetched on appear via the
    // picker's `onFetch` hook, and on Refresh click. `pickerModel` mirrors
    // `config.expandedSearchEmbeddingConfig?.modelName`; binding sync happens
    // inside `modelPickerBinding` so the Picker can show the stored value
    // even before the first fetch completes.
    @State private var availableEmbeddingModels: [String] = []
    @State private var isFetchingEmbeddingModels = false
    @State private var fetchEmbeddingModelsError: String?

    var body: some View {
        SettingsCard(
            header: "Semantic Expansion",
            systemImage: "sparkle.magnifyingglass",
            footer: "Embeddings let Expanded Search surface translations, synonyms, and related terms — computed once after index build, reused on every query."
        ) {
            if let coordinator {
                statusSection(coordinator: coordinator)
                Divider().padding(.vertical, Spacing.xs)
                modelSection()
                Divider().padding(.vertical, Spacing.xs)
                thresholdsSection()
                actionsRow(coordinator: coordinator)
            } else {
                Text("Expanded Search is disabled. Enable it above to build the embedding index.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private func statusSection(coordinator: SearchIndexCoordinator) -> some View {
        statusRow(
            label: "Status",
            value: statusLabel(state: coordinator.vectorIndexState,
                               building: coordinator.isBuildingVectorIndex),
            tint: statusTint(state: coordinator.vectorIndexState)
        )

        if let progress = coordinator.vectorIndexProgress {
            ProgressView(value: Double(progress.processed),
                         total: Double(max(progress.total, 1)))
                .progressViewStyle(.linear)
            HStack {
                Text("\(progress.processed) of \(progress.total)")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                if progress.failed > 0 {
                    Spacer()
                    Text("\(progress.failed) failed")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.warning)
                }
            }
        }

        if case .ready(let coverage, let failed, let vectorsCount) = coordinator.vectorIndexState {
            statusRow(
                label: "Vectors",
                value: "\(vectorsCount)"
            )
            statusRow(
                label: "Coverage",
                value: percentString(coverage)
            )
            if failed > 0 {
                statusRow(
                    label: "Failed",
                    value: "\(failed)",
                    tint: Colors.warning
                )
            }
        }

        if case .error(let message) = coordinator.vectorIndexState {
            Text(message)
                .font(Typography.caption)
                .foregroundStyle(Colors.error)
        }

        if case .modelUnavailable(let reason) = coordinator.vectorIndexState {
            Text(reason)
                .font(Typography.caption)
                .foregroundStyle(Colors.warning)
        }
    }

    // MARK: - Model config

    @ViewBuilder
    private func modelSection() -> some View {
        LLMElevatedTextField(
            "Server Address",
            text: baseURLBinding,
            prompt: EmbeddingConfig.defaultNomicLMStudio.baseURLString
        )
        LLMModelPickerSection(
            modelName: modelPickerBinding,
            availableModels: availableEmbeddingModels,
            fetchError: fetchEmbeddingModelsError,
            isFetching: isFetchingEmbeddingModels,
            emptyLabel: EmbeddingConfig.defaultNomicLMStudio.modelName,
            onFetch: { Task { await fetchEmbeddingModels() } }
        )
    }

    /// Fetches embedding-type models from the server. Filtered on the client
    /// side to LM Studio's `type == "embeddings"` — chat and vision models
    /// don't surface in this picker.
    private func fetchEmbeddingModels() async {
        isFetchingEmbeddingModels = true
        fetchEmbeddingModelsError = nil
        defer { isFetchingEmbeddingModels = false }
        do {
            availableEmbeddingModels = try await client.fetchEmbeddingModels(
                config: fetchConfig
            )
        } catch {
            fetchEmbeddingModelsError = "Failed to load embedding models: \(error.localizedDescription)"
        }
    }

    /// `LLMConfig` shaped for the fetch call. The picker only needs URL +
    /// a placeholder model (fetchEmbeddingModels ignores `modelName`).
    private var fetchConfig: LLMConfig {
        let cfg = config.effectiveEmbeddingConfig
        return LLMConfig(
            provider: .lmStudio,
            baseURLString: cfg.baseURLString,
            modelName: cfg.modelName,
            maxTokens: 0,
            temperature: 0.0
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { config.expandedSearchEmbeddingConfig?.baseURLString ?? "" },
            set: { updateConfig(\.baseURLString, $0.isEmpty ? nil : $0) }
        )
    }

    private var modelNameBinding: Binding<String> {
        Binding(
            get: { config.expandedSearchEmbeddingConfig?.modelName ?? "" },
            set: { updateConfig(\.modelName, $0.isEmpty ? nil : $0) }
        )
    }

    /// Binding the Picker reads / writes. Same storage as `modelNameBinding`
    /// but exists so the Picker's `Text(modelName).tag(modelName)` path can
    /// preserve a pre-selected value that isn't in the fetched list yet —
    /// e.g. on first open before `onFetch` completes.
    private var modelPickerBinding: Binding<String> {
        modelNameBinding
    }

    /// Writes `value` into the override without clobbering the other field. If
    /// both fields end up empty after the write, the whole override clears
    /// (back to `EmbeddingConfig.defaultNomicLMStudio`).
    private func updateConfig(_ keyPath: WritableKeyPath<OverrideFields, String?>, _ value: String?) {
        var fields = OverrideFields(from: config.expandedSearchEmbeddingConfig)
        fields[keyPath: keyPath] = value
        config.expandedSearchEmbeddingConfig = fields.build()
    }

    // MARK: - Thresholds

    @ViewBuilder
    private func thresholdsSection() -> some View {
        thresholdSlider(
            title: "Per-token threshold",
            caption: "Cosine cutoff when a query token is already in the vocab. Higher = stricter.",
            value: $config.expandedSearchPerTokenThreshold,
            range: 0.5...0.95
        )
        thresholdSlider(
            title: "Whole-phrase threshold",
            caption: "Cosine cutoff for multi-word / novel queries that fire a /v1/embeddings call.",
            value: $config.expandedSearchPhraseThreshold,
            range: 0.4...0.9
        )
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

    // MARK: - Actions

    @ViewBuilder
    private func actionsRow(coordinator: SearchIndexCoordinator) -> some View {
        HStack {
            Spacer()
            Menu {
                Button("Force Full Rebuild", systemImage: "arrow.counterclockwise") {
                    onForceFullRebuild()
                }
                .disabled(coordinator.isBuildingVectorIndex)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)

            SettingsPillButton(title: "Rebuild Embeddings", icon: "arrow.clockwise") {
                onRebuild()
            }
            .disabled(coordinator.isBuildingVectorIndex)
        }
    }

    // MARK: - Helpers

    private func statusRow(
        label: String,
        value: String,
        tint: Color? = nil
    ) -> some View {
        HStack {
            Text(label)
                .font(Typography.subheadline)
                .foregroundStyle(Colors.textSecondary)
            Spacer()
            Text(value)
                .font(Typography.subheadlineMedium)
                .monospacedDigit()
                .foregroundStyle(tint ?? Colors.textPrimary)
        }
    }

    private func statusLabel(
        state: VocabVectorIndexState,
        building: Bool
    ) -> String {
        if building { return "Building…" }
        switch state {
        case .missing: return "Not built"
        case .loading: return "Loading…"
        case .building: return "Building…"
        case .ready(let coverage, let failed, _):
            if failed > 0 {
                return "Ready — \(percentString(coverage)) coverage"
            }
            return "Ready"
        case .modelUnavailable: return "Model not loaded"
        case .error: return "Error"
        }
    }

    private func statusTint(state: VocabVectorIndexState) -> Color? {
        switch state {
        case .ready(_, let failed, _): return failed > 0 ? Colors.warning : Colors.success
        case .modelUnavailable: return Colors.warning
        case .error: return Colors.error
        default: return nil
        }
    }

    private func percentString(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: - OverrideFields helper

    /// Small value type to make it easy to mutate one field of the override
    /// without writing out both fields every time. Starts from the current
    /// persisted override (or empty if none); rebuilds an `EmbeddingConfig`
    /// when both fields are set, or returns `nil` when the user cleared them.
    private struct OverrideFields {
        var baseURLString: String?
        var modelName: String?

        init(from config: EmbeddingConfig?) {
            self.baseURLString = config?.baseURLString
            self.modelName = config?.modelName
        }

        func build() -> EmbeddingConfig? {
            let defaults = EmbeddingConfig.defaultNomicLMStudio
            let url = baseURLString ?? ""
            let model = modelName ?? ""
            // If both blank, clear the override (fall back to defaults).
            if url.isEmpty, model.isEmpty { return nil }
            // Use the failable validating init — a malformed URL the user
            // typed shouldn't precondition-crash the settings card.
            return EmbeddingConfig(
                validating: url.isEmpty ? defaults.baseURLString : url,
                modelName: model.isEmpty ? defaults.modelName : model,
                batchSize: defaults.batchSize,
                requestTimeout: defaults.requestTimeout
            )
        }
    }
}

#Preview("Semantic Expansion — disabled") {
    ExpandedSearchEmbeddingsCard(
        config: StoreConfiguration(),
        coordinator: nil,
        onRebuild: {},
        onForceFullRebuild: {}
    )
    .padding()
    .background(Colors.surfacePrimary)
}
