import SwiftUI

/// Settings card for the embedding server / model used by Exploratory
/// Search. Mirrors `LLMVisionCard` visually: the body is just the
/// `LLMEndpointEditor` (URL + token + model picker), with build status
/// and Rebuild actions surfaced when the feature is enabled.
///
/// Thresholds live in `ExploratorySearchThresholdsCard` so this card
/// stays focused on server / model config.
struct ExploratorySearchEmbeddingsCard: View {
    @Bindable var config: StoreConfiguration
    var coordinator: SearchIndexCoordinator?
    var onRebuild: () -> Void
    var onForceFullRebuild: () -> Void
    /// Fired after the embed-model URL / name has been written to
    /// `StoreConfiguration`. Wired by `AdvancedSettingsView` to the
    /// orchestrator's `onExploratorySearchEmbeddingConfigChanged` hook so the
    /// LM Studio embed model is auto unloaded-then-reloaded.
    var onConfigChanged: () -> Void = {}
    /// Surfaced by the parent view so Keychain write failures land in the
    /// app-wide error banner instead of disappearing silently.
    var onTokenSaveError: ((Error) -> Void)? = nil
    /// Surfaced by the parent view so Keychain READ failures (locked,
    /// ACL denied, corrupt) land in the app-wide error banner — without
    /// this wired the user just sees an empty field and a 401 loop.
    var onTokenLoadError: ((Error) -> Void)? = nil
    /// Injected for testability. Defaults to the real router.
    var client: any LLMClient = LLMClientRouter()

    @State private var availableEmbeddingModels: [String] = []
    @State private var isFetchingEmbeddingModels = false
    @State private var fetchEmbeddingModelsError: String?

    /// Per-embedding-server bearer token. `LLMTokenField` (inside
    /// `LLMEndpointEditor`) owns the load/save lifecycle keyed by the
    /// embedding URL.
    @State private var apiToken: String = ""

    private var inheritedURLPrompt: String {
        let global = config.llmBaseURLString.trimmingCharacters(in: .whitespaces)
        return global.isEmpty ? "http://127.0.0.1:1234" : global
    }

    private var emptyModelLabel: String {
        "Use default: \(EmbeddingConfig.defaultNomicLMStudio.modelName)"
    }

    /// Suppress the override editor's status row when the build status
    /// already explains the same connection failure (`.modelUnavailable`).
    private var statusAlreadyShowsConnectionFailure: Bool {
        guard let coordinator else { return false }
        if case .modelUnavailable = coordinator.vectorIndexState { return true }
        return false
    }

    var body: some View {
        SettingsCard(
            header: "Semantic Query Expansion",
            systemImage: "sparkle.magnifyingglass",
            footer: "Embeddings let Exploratory Search surface translations, synonyms, and related terms — computed once after index build, reused on every query."
        ) {
            LLMEndpointEditor(
                baseURL: baseURLBinding,
                modelName: modelNameBinding,
                apiToken: $apiToken,
                urlPrompt: inheritedURLPrompt,
                emptyModelLabel: emptyModelLabel,
                onTokenSaveError: onTokenSaveError,
                onTokenLoadError: onTokenLoadError,
                onURLCommit: { Task { await fetchEmbeddingModels() } },
                availableModels: availableEmbeddingModels,
                isFetchingModels: isFetchingEmbeddingModels,
                status: statusAlreadyShowsConnectionFailure
                    ? nil
                    : EndpointStatus.resolve(
                        fetchError: fetchEmbeddingModelsError,
                        isFetching: isFetchingEmbeddingModels
                    ),
                onRefreshModels: { Task { await fetchEmbeddingModels() } }
            )

            if let coordinator {
                buildStatusRow(coordinator: coordinator)
                actionsRow(coordinator: coordinator)
            } else {
                Text("Enable Exploratory Search above to build the embedding index using these settings.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
        }
        .task {
            // First-appear load only. URL edits don't re-trigger — onCommit
            // (Enter / focus loss) and the Refresh button are the user-driven
            // re-fetch paths.
            guard availableEmbeddingModels.isEmpty else { return }
            await fetchEmbeddingModels()
        }
    }

    // MARK: - Build status (compact one-row summary)

    @ViewBuilder
    private func buildStatusRow(coordinator: SearchIndexCoordinator) -> some View {
        HStack(spacing: Spacing.xs) {
            StatusGlyph(
                glyph: statusGlyph(state: coordinator.vectorIndexState,
                                   building: coordinator.isBuildingVectorIndex),
                color: statusTint(state: coordinator.vectorIndexState) ?? Colors.neutral,
                animatesWork: coordinator.isBuildingVectorIndex
            )
            Text(statusLabel(state: coordinator.vectorIndexState,
                             building: coordinator.isBuildingVectorIndex))
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
            Spacer(minLength: 0)
        }

        if let progress = coordinator.vectorIndexProgress {
            ProgressView(value: Double(progress.processed),
                         total: Double(max(progress.total, 1)))
                .progressViewStyle(.linear)
        }
    }

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

    // MARK: - Status helpers

    private func statusGlyph(state: VocabVectorIndexState, building: Bool) -> String {
        if building { return TerminalGlyph.working }
        switch state {
        case .ready: return TerminalGlyph.done
        case .modelUnavailable: return TerminalGlyph.failed
        case .error: return TerminalGlyph.failed
        case .missing, .loading, .building: return TerminalGlyph.idle
        }
    }

    private func statusLabel(state: VocabVectorIndexState, building: Bool) -> String {
        if building { return "Building embedding index…" }
        switch state {
        case .missing: return "Index not built — click Rebuild Embeddings."
        case .loading: return "Loading embedding index…"
        case .building: return "Building embedding index…"
        case .ready(let coverage, let failed, let vectorsCount):
            let pct = Int((coverage * 100).rounded())
            if failed > 0 {
                return "\(vectorsCount) embeddings · \(pct)% coverage · \(failed) failed"
            }
            return "\(vectorsCount) embeddings · \(pct)% coverage"
        case .modelUnavailable(let reason): return reason
        case .error(let message): return message
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

    // MARK: - Fetch loop

    /// Fetches embedding-type models from the server. Filtered on the client
    /// side to LM Studio's `type == "embeddings"` — chat and vision models
    /// don't surface in this picker.
    private func fetchEmbeddingModels() async {
        guard !isFetchingEmbeddingModels else { return }
        isFetchingEmbeddingModels = true
        fetchEmbeddingModelsError = nil
        defer { isFetchingEmbeddingModels = false }
        do {
            availableEmbeddingModels = try await effectiveClient.fetchEmbeddingModels(
                config: fetchConfig
            )
        } catch {
            fetchEmbeddingModelsError = "Failed to load embedding models: \(error.localizedDescription)"
        }
    }

    /// Returns either the injected client (test override) or a fresh router
    /// preconfigured with the typed-but-unsaved bearer token for this card's
    /// embedding URL.
    private var effectiveClient: any LLMClient {
        let url = config.effectiveEmbeddingConfig.baseURLString
        let trimmed = apiToken.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return client }
        return LLMClientRouter(tokenResolver: OverridingLLMTokenResolver(
            overrides: [url: trimmed]
        ))
    }

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

    // MARK: - Field bindings

    /// Canonical embedding default. Stored values matching this collapse to
    /// "no override" — the user sees the same visual state (empty field +
    /// placeholder, inherited token hint) whether they cleared the field or
    /// typed the canonical default.
    private static let canonicalDefaultURL: String =
        EmbeddingConfig.defaultNomicLMStudio.baseURLString
    private static let canonicalDefaultModel: String =
        EmbeddingConfig.defaultNomicLMStudio.modelName

    private var baseURLBinding: Binding<String> {
        Binding(
            get: {
                let stored = config.exploratorySearchEmbeddingConfig?.baseURLString ?? ""
                return stored == Self.canonicalDefaultURL ? "" : stored
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                let normalized: String? = (trimmed.isEmpty
                    || trimmed == Self.canonicalDefaultURL) ? nil : trimmed
                updateConfig(\.baseURLString, normalized)
            }
        )
    }

    private var modelNameBinding: Binding<String> {
        Binding(
            get: {
                let stored = config.exploratorySearchEmbeddingConfig?.modelName ?? ""
                return stored == Self.canonicalDefaultModel ? "" : stored
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized: String? = (trimmed.isEmpty
                    || trimmed == Self.canonicalDefaultModel) ? nil : trimmed
                updateConfig(\.modelName, normalized)
            }
        )
    }

    /// Writes `value` into the override without clobbering the other field.
    /// If both fields end up empty the whole override clears (back to
    /// `EmbeddingConfig.defaultNomicLMStudio`).
    private func updateConfig(_ keyPath: WritableKeyPath<OverrideFields, String?>, _ value: String?) {
        var fields = OverrideFields(from: config.exploratorySearchEmbeddingConfig)
        fields[keyPath: keyPath] = value
        let next = fields.build()
        guard next != config.exploratorySearchEmbeddingConfig else { return }
        config.exploratorySearchEmbeddingConfig = next
        onConfigChanged()
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
            if url.isEmpty, model.isEmpty { return nil }
            return EmbeddingConfig(
                validating: url.isEmpty ? defaults.baseURLString : url,
                modelName: model.isEmpty ? defaults.modelName : model,
                batchSize: defaults.batchSize,
                requestTimeout: defaults.requestTimeout
            )
        }
    }
}

#Preview("Semantic Query Expansion — disabled") {
    @Previewable @State var config = StoreConfiguration()
    ExploratorySearchEmbeddingsCard(
        config: config,
        coordinator: nil,
        onRebuild: {},
        onForceFullRebuild: {}
    )
    .padding()
    .background(Colors.surfacePrimary)
}
