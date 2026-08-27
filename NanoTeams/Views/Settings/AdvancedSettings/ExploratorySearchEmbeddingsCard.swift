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

    /// The model list, its in-flight flag and its last error — owned by the catalog, not by
    /// this card. The card held them, and its own client, until 2026-08-24; the client's
    /// default resolved outward to a live `LLMClientRouter`, so the `#Preview` below fetched
    /// against a real server on appear.
    @Environment(EmbeddingModelCatalog.self) private var embeddingCatalog

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
                onURLCommit: { Task { await refreshEmbeddingModels() } },
                availableModels: embeddingCatalog.models(for: fetchURL),
                isFetchingModels: embeddingCatalog.isFetching(fetchURL),
                status: statusAlreadyShowsConnectionFailure
                    ? nil
                    : EndpointStatus.resolve(
                        fetchError: embeddingCatalog.error(for: fetchURL),
                        isFetching: embeddingCatalog.isFetching(fetchURL)
                    ),
                onRefreshModels: { Task { await refreshEmbeddingModels() } }
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
            // re-fetch paths. `loadIfNeeded` also dedupes across appearances,
            // which the card's own `isEmpty` guard could not.
            await embeddingCatalog.loadIfNeeded(url: fetchURL, tokenOverride: apiToken)
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
            TerminalProgressBar(
                value: Double(progress.processed) / Double(max(progress.total, 1)))
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
                    .contentShape(RoundedRectangle.squircle(CornerRadius.small))
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

    /// The server this card's picker is about — the effective embedding endpoint, which is
    /// the override when one is set and the canonical default otherwise.
    private var fetchURL: String {
        config.effectiveEmbeddingConfig.baseURLString
    }

    /// User-initiated re-fetch (Refresh button, URL commit). The token rides along because
    /// `LLMTokenField` holds it before it reaches the Keychain, and a fetch issued while the
    /// user is still typing one must authenticate with what is on screen.
    private func refreshEmbeddingModels() async {
        await embeddingCatalog.refresh(url: fetchURL, tokenOverride: apiToken)
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
    // Inert, not live: the card fetches on appear, so a real catalog here issues a request
    // against whatever embedding server the developer has running the moment the canvas opens.
    @Previewable @State var embeddingCatalog = PreviewStore.embeddingCatalog()
    ExploratorySearchEmbeddingsCard(
        config: config,
        coordinator: nil,
        onRebuild: {},
        onForceFullRebuild: {}
    )
    .environment(embeddingCatalog)
    .padding()
    .background(Colors.surfacePrimary)
}
