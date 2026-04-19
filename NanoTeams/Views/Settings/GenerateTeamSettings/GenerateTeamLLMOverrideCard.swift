import SwiftUI

/// LLM override card for team generation. Toggle gates a sub-block of URL / model /
/// max-tokens / temperature inputs. When the toggle is ON, fields are seeded from
/// the global provider defaults so `LLMOverride.isEmpty == false` and the override
/// persists across settings reopens.
struct GenerateTeamLLMOverrideCard: View {
    @Bindable var config: StoreConfiguration
    let availableModels: [String]
    let isFetchingModels: Bool
    let modelFetchError: String?
    var onFetchModels: () -> Void

    private var isEnabled: Bool { config.teamGenLLMOverride != nil }

    var body: some View {
        SettingsCard(
            header: "LLM Override",
            systemImage: "brain",
            footer: "Use a different LLM only for Generate Team. Empty fields fall back to the global configuration."
        ) {
            Toggle(isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    if newValue {
                        // Seed from provider defaults so the override is non-empty and
                        // persists across settings reopens.
                        let provider = LLMProvider.lmStudio
                        config.teamGenLLMOverride = LLMOverride(
                            baseURLString: provider.defaultBaseURL,
                            modelName: provider.defaultModel,
                            maxTokens: provider.defaultMaxTokens
                        )
                        onFetchModels()
                    } else {
                        config.teamGenLLMOverride = nil
                    }
                }
            )) {
                Text("Use custom LLM for team generation")
                    .font(Typography.subheadline)
            }

            if isEnabled {
                LLMElevatedTextField(
                    "Server Address",
                    text: baseURLBinding,
                    prompt: config.llmBaseURLString
                )

                LLMModelPickerSection(
                    modelName: modelNameBinding,
                    availableModels: availableModels,
                    fetchError: modelFetchError,
                    isFetching: isFetchingModels,
                    emptyLabel: "Connect to load models",
                    onFetch: onFetchModels
                )

                LLMStepperSettingsRow(
                    title: "Response Limit",
                    value: maxTokensBinding,
                    range: 0...128_000,
                    step: 1024,
                    caption: "Maximum tokens per response."
                )

                temperatureRow
            }
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

    private func setOverride<V>(_ keyPath: WritableKeyPath<LLMOverride, V>, _ value: V) {
        var override = config.teamGenLLMOverride ?? LLMOverride()
        override[keyPath: keyPath] = value
        config.teamGenLLMOverride = override
    }
}

#Preview("LLM Override – disabled") {
    ScrollView {
        GenerateTeamLLMOverrideCard(
            config: StoreConfiguration(),
            availableModels: [],
            isFetchingModels: false,
            modelFetchError: nil,
            onFetchModels: {}
        )
        .padding()
    }
    .background(Colors.surfacePrimary)
}
