import SwiftUI

/// Vision (image analysis) configuration card: enable toggle + conditional server/model fields.
struct LLMVisionCard: View {
    @Bindable var config: StoreConfiguration
    @Binding var visionEnabled: Bool
    let visionAvailableModels: [String]
    let isFetchingVisionModels: Bool
    let visionModelFetchError: String?
    var onFetchVisionModels: () -> Void

    var body: some View {
        SettingsCard(
            header: "Image Analysis (Vision)",
            systemImage: "eye",
            footer: "Enables image analysis for roles via analyze_image. Defaults to the main server."
        ) {
            Toggle(isOn: Binding(
                get: { config.isVisionConfigured || visionEnabled },
                set: { newValue in
                    visionEnabled = newValue
                    if !newValue { config.visionModelName = "" }
                }
            )) {
                Text("Enable Vision Model")
                    .font(Typography.subheadline)
            }

            if visionEnabled || config.isVisionConfigured {
                LLMElevatedTextField(
                    "Server Address",
                    text: $config.visionBaseURLString,
                    prompt: config.llmBaseURLString
                )

                LLMModelPickerSection(
                    modelName: $config.visionModelName,
                    availableModels: visionAvailableModels,
                    fetchError: visionModelFetchError,
                    isFetching: isFetchingVisionModels,
                    onFetch: onFetchVisionModels
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
    }
}
