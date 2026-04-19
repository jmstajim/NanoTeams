import SwiftUI

/// Network & error-handling card: request timeout + retry count.
struct LLMErrorHandlingCard: View {
    @Bindable var config: StoreConfiguration

    var body: some View {
        SettingsCard(
            header: "Network & Error Handling",
            systemImage: "arrow.counterclockwise"
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                LLMStepperSettingsRow(
                    title: "Request Timeout (s)",
                    value: $config.llmRequestTimeoutSeconds,
                    range: 0...86_400,
                    step: timeoutStep(for: config.llmRequestTimeoutSeconds),
                    caption: "0 = no timeout (wait indefinitely). Increase for reasoning/MoE models with long first-token latency."
                )

                LLMStepperSettingsRow(
                    title: "Error Retries",
                    value: $config.maxLLMRetries,
                    range: 0...1000,
                    caption: "Retries re-issue the call on server errors. 0 = unlimited."
                )
            }
        }
    }

    /// Coarser stepper steps at larger values so users can move from 60 → 300 → 1800 without many clicks.
    private func timeoutStep(for current: Int) -> Int {
        switch current {
        case 0..<10: 1
        case 10..<60: 5
        case 60..<300: 30
        case 300..<1800: 60
        default: 300
        }
    }
}
