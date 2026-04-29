import SwiftUI

// MARK: - LLM Tab

/// Per-role LLM override tab. Reads the model list from the shared
/// `ModelCatalog`, so opening the editor on the same server as the
/// global LLM card is a cache hit.
///
/// All fields are always visible. Empty fields fall back to the global
/// LLM config — placeholders surface the live default (URL / model
/// name) so the user sees what would be used. The role's stored
/// `llmOverride` is computed at save time from whatever the user typed:
/// non-empty fields → non-nil override, all empty → nil.
struct RoleEditorLLMTab: View {
    @Environment(StoreConfiguration.self) private var config
    @Environment(ModelCatalog.self) private var modelCatalog
    @Binding var editorState: RoleEditorState
    let llmProvider: LLMProvider
    /// Optional callback so the parent role-editor sheet can surface Keychain
    /// write failures via the app-wide error banner.
    var onTokenSaveError: ((Error) -> Void)? = nil
    /// Optional callback for Keychain READ failures (locked, ACL denied,
    /// corrupt entry).
    var onTokenLoadError: ((Error) -> Void)? = nil

    @State private var apiToken: String = ""

    private var inheritedURLPrompt: String {
        let global = config.llmBaseURLString.trimmingCharacters(in: .whitespaces)
        return global.isEmpty ? "http://127.0.0.1:1234" : global
    }

    private var emptyModelLabel: String {
        let global = config.llmModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return global.isEmpty ? "Use global model" : "Use global: \(global)"
    }

    /// URL the picker reads from — override URL when typed, otherwise the
    /// global LLM URL (matches the runtime fallback in
    /// `buildEffectiveConfig`).
    private var effectiveFetchURL: String {
        let custom = editorState.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return config.llmBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                LLMEndpointEditor(
                    baseURL: $editorState.llmBaseURL,
                    modelName: $editorState.llmModelName,
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

                Text("Override the global LLM settings for this specific role. Empty fields fall back to the global configuration.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
            .padding(Spacing.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Colors.surfacePrimary)
        .task {
            // First-appear load only. URL edits don't re-trigger — the URL
            // field's onCommit fires loadIfNeeded when the user actually
            // commits a new URL (Enter or focus loss). Refresh button
            // forces a re-fetch.
            await modelCatalog.loadIfNeeded(url: effectiveFetchURL)
        }
    }
}

#Preview("LLM Override") {
    @Previewable @State var editorState: RoleEditorState = {
        var s = RoleEditorState()
        s.llmBaseURL = "http://127.0.0.1:1234"
        s.llmModelName = "qwen2.5-coder-32b"
        return s
    }()

    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var catalog = ModelCatalog()

    RoleEditorLLMTab(
        editorState: $editorState,
        llmProvider: .lmStudio
    )
    .environment(config)
    .environment(catalog)
    .frame(width: 500)
    .fixedSize(horizontal: false, vertical: true)
    .background(Colors.surfacePrimary)
}
