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
    var onTokenSaveError: ((Error) -> Void)? = nil
    var onTokenLoadError: ((Error) -> Void)? = nil

    var body: some View {
        SettingsCard(
            header: "LLM Override",
            systemImage: "brain",
            footer: "Use a different LLM only for Generate Team. Empty fields fall back to the global configuration."
        ) {
            LLMOverrideEditor(
                config: config,
                keyPath: \.teamGenLLMOverride,
                onTokenSaveError: onTokenSaveError,
                onTokenLoadError: onTokenLoadError)

            LLMStepperSettingsRow(
                title: "Response Limit",
                value: maxTokensBinding,
                range: 0...128_000,
                step: 1024,
                caption: "Maximum tokens per response. 0 inherits the global setting."
            )

            temperatureRow
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
                    TerminalSlider(
                        value: Binding(
                            get: { current },
                            set: { setTemperature($0) }
                        ),
                        range: 0...2,
                        step: 0.1
                    )
                    .frame(maxWidth: 160)

                    Text(String(format: "%.1f", current))
                        .monospacedDigit()
                        .foregroundStyle(Colors.textSecondary)
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

    // MARK: - Field Bindings (URL + token + model live in LLMOverrideEditor)

    private var maxTokensBinding: Binding<Int> {
        Binding(
            get: { config.teamGenLLMOverride?.maxTokens ?? 0 },
            set: { config.writeOverride(\.teamGenLLMOverride, \.maxTokens, $0 == 0 ? nil : $0) }
        )
    }

    private func setTemperature(_ value: Double?) {
        config.writeOverride(\.teamGenLLMOverride, \.temperature, value)
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
