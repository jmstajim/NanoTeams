import SwiftUI

/// Generation parameters card: response limit stepper + temperature slider with Auto toggle.
struct LLMGenerationCard: View {
    @Bindable var config: StoreConfiguration

    var body: some View {
        SettingsCard(header: "Generation", systemImage: "text.quote") {
            LLMStepperSettingsRow(
                title: "Response Limit",
                value: $config.llmMaxTokens,
                range: 0...128_000,
                step: 1024,
                caption: "Maximum tokens per response."
            )

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text("Temperature")
                        .font(Typography.subheadline)

                    Spacer()

                    if config.llmTemperature != nil {
                        Slider(
                            value: Binding(
                                get: { config.llmTemperature ?? 0.7 },
                                set: { config.llmTemperature = $0 }
                            ),
                            in: 0...2,
                            step: 0.1
                        )
                        .frame(maxWidth: 160)

                        Text(String(format: "%.1f", config.llmTemperature ?? 0.7))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 30, alignment: .trailing)

                        SettingsPillButton(title: "Auto", icon: "slider.horizontal.3") {
                            config.llmTemperature = nil
                        }
                        .help("Reset to server default")
                    } else {
                        SettingsPillButton(title: "Auto", icon: "slider.horizontal.3") {
                            config.llmTemperature = 0.7
                        }
                    }
                }

                Text("Lower = focused, higher = creative")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
        }
    }
}
