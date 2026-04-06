import SwiftUI

/// Error-handling card: retry count stepper.
struct LLMErrorHandlingCard: View {
    @Bindable var config: StoreConfiguration

    var body: some View {
        SettingsCard(
            header: "Error Handling",
            systemImage: "arrow.counterclockwise",
            footer: "How many times to retry when the server returns an error."
        ) {
            LLMStepperSettingsRow(
                title: "Error Retries",
                value: $config.maxLLMRetries,
                range: 0...1000
            )
        }
    }
}
