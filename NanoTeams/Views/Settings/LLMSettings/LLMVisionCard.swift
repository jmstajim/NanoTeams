import SwiftUI

/// Vision (image analysis) configuration card.
///
/// Reads the model list from the shared `ModelCatalog` (keyed by URL), so
/// opening this card on the same server as the global LLM card is a
/// cache hit — no extra `/api/v1/models` request. Refresh button always
/// force-refreshes.
///
/// All fields are always editable when "Enable Vision Model" is on.
/// Empty fields fall back to the main LLM configuration — placeholders
/// surface the live defaults so the user sees what would be used. A
/// "Reset to Defaults" button clears the override fields without
/// disabling vision.
struct LLMVisionCard: View {
    @Bindable var config: StoreConfiguration
    @Binding var apiToken: String
    var onTokenSaveError: ((Error) -> Void)? = nil
    var onTokenLoadError: ((Error) -> Void)? = nil

    @Environment(ModelCatalog.self) private var modelCatalog

    private var inheritedURLPrompt: String {
        let global = config.llmBaseURLString.trimmingCharacters(in: .whitespaces)
        return global.isEmpty ? "http://127.0.0.1:1234" : global
    }

    private var emptyModelLabel: String {
        let global = config.llmModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return global.isEmpty ? "Use global model" : "Use global: \(global)"
    }

    /// URL the picker reads from — override URL when typed, otherwise
    /// the global LLM URL. Mirrors the runtime fallback in
    /// `buildEffectiveConfig`.
    private var effectiveFetchURL: String {
        let custom = config.visionBaseURLString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return config.llmBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsCard(
            header: "Image Analysis (Vision)",
            systemImage: "eye",
            footer: "Enables image analysis for roles via analyze_image. "
                + "Empty fields fall back to the main LLM configuration."
        ) {
            Toggle(isOn: Binding(
                get: { config.visionEnabled },
                set: { newValue in
                    config.visionEnabled = newValue
                    if newValue {
                        // Adopt the main LLM model as the default vision model
                        // — most setups run a single multimodal model for both,
                        // so this just works out of the box. User can pick a
                        // different one if needed.
                        if config.visionModelName.isEmpty {
                            config.visionModelName = config.llmModelName
                        }
                    } else {
                        config.visionModelName = ""
                        config.visionBaseURLString = ""
                        // Don't touch `apiToken` here — `LLMTokenField` is
                        // removed from the tree when `visionEnabled = false`,
                        // and clearing the binding could race the field's
                        // own onChange handlers and delete the shared
                        // Keychain entry that the main LLM card depends on
                        // (single-server setups share one entry per
                        // CLAUDE.md "Per-URL keying").
                    }
                }
            )) {
                Text("Enable Vision Model")
                    .font(Typography.subheadline)
            }
            .toggleStyle(.terminal)

            if config.visionEnabled {
                LLMEndpointEditor(
                    baseURL: $config.visionBaseURLString,
                    modelName: $config.visionModelName,
                    apiToken: $apiToken,
                    urlPrompt: inheritedURLPrompt,
                    emptyModelLabel: emptyModelLabel,
                    onTokenSaveError: onTokenSaveError,
                    onTokenLoadError: onTokenLoadError,
                    onURLCommit: {
                        Task { await modelCatalog.loadIfNeeded(url: effectiveFetchURL, visionOnly: true) }
                    },
                    availableModels: modelCatalog.models(for: effectiveFetchURL, visionOnly: true),
                    isFetchingModels: modelCatalog.isFetching(effectiveFetchURL, visionOnly: true),
                    status: EndpointStatus.resolve(
                        fetchError: modelCatalog.error(for: effectiveFetchURL, visionOnly: true),
                        isFetching: modelCatalog.isFetching(effectiveFetchURL, visionOnly: true)
                    ),
                    onRefreshModels: {
                        Task { await modelCatalog.refresh(url: effectiveFetchURL, visionOnly: true) }
                    }
                )

                LLMStepperSettingsRow(
                    title: "Response Limit",
                    value: $config.visionMaxTokens,
                    range: 0...128_000,
                    step: 1024,
                    caption: "Maximum tokens per vision response."
                )
            }
        }
        .task(id: config.visionEnabled) {
            // Populate on first appear / when the feature is toggled on.
            // URL changes do NOT re-trigger here — that would fetch on every
            // keystroke. The Refresh button + URL field's onCommit are the
            // user-driven re-fetch paths.
            guard config.visionEnabled else { return }
            await modelCatalog.loadIfNeeded(url: effectiveFetchURL, visionOnly: true)
        }
    }
}
