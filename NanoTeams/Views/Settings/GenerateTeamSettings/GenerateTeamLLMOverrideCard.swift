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
    @Environment(ModelCatalog.self) private var modelCatalog
    var onTokenSaveError: ((Error) -> Void)? = nil
    var onTokenLoadError: ((Error) -> Void)? = nil

    /// Per-server bearer token. `LLMTokenField` (inside `LLMEndpointEditor`)
    /// owns the load/save lifecycle keyed by the override URL.
    @State private var apiToken: String = ""

    private var inheritedURLPrompt: String {
        let global = config.llmBaseURLString.trimmingCharacters(in: .whitespaces)
        return global.isEmpty ? "http://127.0.0.1:1234" : global
    }

    private var emptyModelLabel: String {
        let global = config.llmModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return global.isEmpty ? "Use global model" : "Use global: \(global)"
    }

    /// URL the picker reads from — override URL when typed, otherwise
    /// the global LLM URL.
    private var effectiveFetchURL: String {
        let custom = (config.teamGenLLMOverride?.baseURLString ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return config.llmBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsCard(
            header: "LLM Override",
            systemImage: "brain",
            footer: "Use a different LLM only for Generate Team. Empty fields fall back to the global configuration."
        ) {
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

            LLMStepperSettingsRow(
                title: "Response Limit",
                value: maxTokensBinding,
                range: 0...128_000,
                step: 1024,
                caption: "Maximum tokens per response. 0 inherits the global setting."
            )

            temperatureRow
        }
        .task {
            // First-appear load only. URL edits don't re-trigger — onCommit
            // fires loadIfNeeded on Enter / focus loss; Refresh button
            // forces a re-fetch.
            await modelCatalog.loadIfNeeded(url: effectiveFetchURL)
        }
    }

    // MARK: - Temperature row (mirrors LLMGenerationCard)

    @ViewBuilder
    private var temperatureRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Temperature")
                    .font(Typography.subheadline)

                Spacer()

                if let current = config.teamGenLLMOverride?.temperature {
                    Slider(
                        value: Binding(
                            get: { current },
                            set: { setTemperature($0) }
                        ),
                        in: 0...2,
                        step: 0.1
                    )
                    .frame(maxWidth: 160)

                    Text(String(format: "%.1f", current))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 30, alignment: .trailing)

                    SettingsPillButton(title: "Auto", icon: "slider.horizontal.3") {
                        setTemperature(nil)
                    }
                    .help("Inherit from global")
                } else {
                    SettingsPillButton(title: "Auto", icon: "slider.horizontal.3") {
                        setTemperature(0.7)
                    }
                }
            }

            Text("Lower = focused, higher = creative. Auto inherits the global setting.")
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
        }
    }

    // MARK: - Field Bindings

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { config.teamGenLLMOverride?.baseURLString ?? "" },
            set: { setOverride(\.baseURLString, $0.isEmpty ? nil : $0) }
        )
    }

    private var modelNameBinding: Binding<String> {
        Binding(
            get: { config.teamGenLLMOverride?.modelName ?? "" },
            set: { setOverride(\.modelName, $0.isEmpty ? nil : $0) }
        )
    }

    private var maxTokensBinding: Binding<Int> {
        Binding(
            get: { config.teamGenLLMOverride?.maxTokens ?? 0 },
            set: { setOverride(\.maxTokens, $0 == 0 ? nil : $0) }
        )
    }

    private func setTemperature(_ value: Double?) {
        setOverride(\.temperature, value)
    }

    /// Writes one override field. Auto-clears `teamGenLLMOverride` to
    /// `nil` once all fields are at their defaults — keeps persistence
    /// in sync with the "no override" UX.
    private func setOverride<V>(_ keyPath: WritableKeyPath<LLMOverride, V>, _ value: V) {
        var override = config.teamGenLLMOverride ?? LLMOverride()
        override[keyPath: keyPath] = value
        config.teamGenLLMOverride = override.isEmpty ? nil : override
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
