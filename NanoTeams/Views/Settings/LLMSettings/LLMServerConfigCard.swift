import SwiftUI

/// Server-address card: URL input, Test Connection button, status pill, model picker.
struct LLMServerConfigCard: View {
    @Bindable var config: StoreConfiguration
    let connectionStatus: LLMConnectionStatus
    let statusMessage: String
    let availableModels: [String]
    let isFetchingModels: Bool
    let modelFetchError: String?
    var onTestConnection: () -> Void
    var onFetchModels: () -> Void

    var body: some View {
        SettingsCard(
            header: "Server",
            systemImage: "server.rack",
            footer: "Requires a running LM Studio server."
        ) {
            LLMElevatedTextField("Server Address", text: $config.llmBaseURLString)

            HStack {
                SettingsPillButton(
                    title: "Test Connection",
                    icon: "bolt.fill",
                    isLoading: connectionStatus == .checking,
                    action: onTestConnection
                )
                .disabled(connectionStatus == .checking)

                LLMConnectionStatusPill(status: connectionStatus)

                if !statusMessage.isEmpty {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: connectionStatus == .failure ? "exclamationmark.circle" : "info.circle")
                            .font(Typography.caption)
                        Text(statusMessage)
                            .font(Typography.caption)
                    }
                    .foregroundStyle(connectionStatus == .failure ? Colors.error : Colors.textSecondary)
                    .lineLimit(1)
                }

                Spacer()
            }

            LLMModelPickerSection(
                modelName: $config.llmModelName,
                availableModels: availableModels,
                fetchError: modelFetchError,
                isFetching: isFetchingModels,
                emptyLabel: "Connect to load models",
                onFetch: onFetchModels
            )
        }
    }
}
