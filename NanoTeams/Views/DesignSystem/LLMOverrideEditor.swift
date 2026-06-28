import SwiftUI

/// Shared URL + token + model override editor, bound to any
/// `LLMOverride?` slot on `StoreConfiguration` via a key path. Wraps
/// `LLMEndpointEditor` with the inherited-URL placeholder, the "Use global: …"
/// empty-model label, the effective-fetch-URL resolution, and the
/// auto-clear-to-nil write-back that every override surface needs — so a fix to
/// any of that lands in one place instead of being copy-pasted per card.
///
/// Cards that need extra rows (e.g. Generate Team's Response-Limit / Temperature)
/// embed this editor and add their own rows around it, routing writes through the
/// same `config.writeOverride(...)` helper.
struct LLMOverrideEditor: View {
    @Bindable var config: StoreConfiguration
    let keyPath: ReferenceWritableKeyPath<StoreConfiguration, LLMOverride?>
    var onTokenSaveError: ((Error) -> Void)? = nil
    var onTokenLoadError: ((Error) -> Void)? = nil

    @Environment(ModelCatalog.self) private var modelCatalog
    @State private var apiToken: String = ""

    private var inheritedURLPrompt: String {
        let global = config.llmBaseURLString.trimmingCharacters(in: .whitespaces)
        return global.isEmpty ? "http://127.0.0.1:1234" : global
    }

    private var emptyModelLabel: String {
        let global = config.llmModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return global.isEmpty ? "Use global model" : "Use global: \(global)"
    }

    /// The URL the picker reads from — the override URL when typed, otherwise the
    /// global LLM URL.
    private var effectiveFetchURL: String {
        let custom = (config[keyPath: keyPath]?.baseURLString ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return config.llmBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        LLMEndpointEditor(
            baseURL: baseURLBinding,
            modelName: modelNameBinding,
            apiToken: $apiToken,
            urlPrompt: inheritedURLPrompt,
            emptyModelLabel: emptyModelLabel,
            onTokenSaveError: onTokenSaveError,
            onTokenLoadError: onTokenLoadError,
            onURLCommit: {
                Task { await modelCatalog.loadIfNeeded(url: effectiveFetchURL) }
            },
            availableModels: modelCatalog.models(for: effectiveFetchURL),
            isFetchingModels: modelCatalog.isFetching(effectiveFetchURL),
            status: EndpointStatus.resolve(
                fetchError: modelCatalog.error(for: effectiveFetchURL),
                isFetching: modelCatalog.isFetching(effectiveFetchURL)
            ),
            onRefreshModels: {
                Task { await modelCatalog.refresh(url: effectiveFetchURL) }
            }
        )
        .task {
            // First-appear load only. URL edits re-trigger via onURLCommit; the
            // Refresh button forces a re-fetch.
            await modelCatalog.loadIfNeeded(url: effectiveFetchURL)
        }
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { config[keyPath: keyPath]?.baseURLString ?? "" },
            set: { config.writeOverride(keyPath, \.baseURLString, $0.isEmpty ? nil : $0) }
        )
    }

    private var modelNameBinding: Binding<String> {
        Binding(
            get: { config[keyPath: keyPath]?.modelName ?? "" },
            set: { config.writeOverride(keyPath, \.modelName, $0.isEmpty ? nil : $0) }
        )
    }
}

extension StoreConfiguration {
    /// Writes one field of an `LLMOverride?` slot, auto-clearing the whole slot to
    /// `nil` once every field is back at its default — the single source of truth
    /// for the "no override" persistence semantics shared by every override card.
    func writeOverride<V>(
        _ keyPath: ReferenceWritableKeyPath<StoreConfiguration, LLMOverride?>,
        _ field: WritableKeyPath<LLMOverride, V>,
        _ value: V
    ) {
        var override = self[keyPath: keyPath] ?? LLMOverride()
        override[keyPath: field] = value
        self[keyPath: keyPath] = override.isEmpty ? nil : override
    }
}
