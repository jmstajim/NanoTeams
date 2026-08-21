import SwiftUI

/// Server-address card: URL input, API token, Test Connection button, status pill, model picker.
struct LLMServerConfigCard: View {
    @Bindable var config: StoreConfiguration
    @Binding var apiToken: String
    let connectionStatus: LLMConnectionStatus
    let statusMessage: String
    let availableModels: [String]
    let isFetchingModels: Bool
    let modelFetchError: String?
    var onTestConnection: () -> Void
    var onRefreshModels: () -> Void
    var onTokenSaveError: ((Error) -> Void)? = nil
    var onTokenLoadError: ((Error) -> Void)? = nil
    /// Auto-fired when the URL field loses focus or the user presses
    /// Return — same effect as clicking Test Connection but without the
    /// extra click. Wired by the parent settings view.
    var onURLCommit: (() -> Void)? = nil

    var body: some View {
        SettingsCard(
            header: "Server",
            systemImage: "server.rack",
            footer: "Requires a running \(config.llmProvider.displayName) server."
        ) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                // Provider selection. Switching resets URL + model to the new
                // provider's defaults (StoreConfiguration.llmProvider.didSet),
                // which also drives the residency hook: the orphaned LM Studio
                // instance is reconciled away, and no explicit load is
                // attempted against a provider that manages its own residency.
                HStack(spacing: Spacing.s) {
                    Text("Provider")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                    TerminalSegmentedPicker(
                        selection: $config.llmProvider,
                        options: LLMProvider.allCases.map { ($0, $0.displayName) }
                    )
                    .frame(maxWidth: 320)
                    Spacer(minLength: 0)
                }

                LLMEndpointEditor(
                    baseURL: $config.llmBaseURLString,
                    modelName: $config.llmModelName,
                    apiToken: $apiToken,
                    urlPrompt: config.llmProvider.defaultBaseURL,
                    urlDefaultValue: config.llmProvider.defaultBaseURL,
                    emptyModelLabel: "Choose a model",
                    tokenInheritedHint: "Set a server address to enable the token field",
                    onTokenSaveError: onTokenSaveError,
                    onTokenLoadError: onTokenLoadError,
                    onURLCommit: onURLCommit,
                    availableModels: availableModels,
                    isFetchingModels: isFetchingModels,
                    status: nil,
                    onRefreshModels: onRefreshModels
                ) {
                    testConnectionRow
                }
            }
        }
    }

    /// When the user hasn't run Test Connection yet but the auto-fetch already
    /// failed (server unreachable on appear), surface that as a synthetic
    /// `.failure` pill in the test row — same vertical slot as a real Test
    /// Connection result. Avoids a second warning showing above the picker.
    private var effectiveStatus: LLMConnectionStatus {
        if connectionStatus == .idle, modelFetchError != nil {
            return .failure
        }
        return connectionStatus
    }

    private var effectiveMessage: String {
        if connectionStatus == .idle, let err = modelFetchError {
            return err
        }
        return statusMessage
    }

    @ViewBuilder
    private var testConnectionRow: some View {
        HStack {
            SettingsPillButton(
                title: "Test Connection",
                icon: "bolt",
                isLoading: connectionStatus == .checking,
                action: onTestConnection
            )
            .disabled(connectionStatus == .checking)

            LLMConnectionStatusPill(status: effectiveStatus)

            if !effectiveMessage.isEmpty {
                HStack(spacing: Spacing.xs) {
                    StatusGlyph(
                        glyph: effectiveStatus == .failure ? TerminalGlyph.failed : TerminalGlyph.bullet,
                        color: effectiveStatus == .failure ? Colors.error : Colors.textSecondary,
                        font: Typography.caption
                    )
                    Text(effectiveMessage)
                        .font(Typography.caption)
                }
                .foregroundStyle(effectiveStatus == .failure
                    ? Colors.error
                    : Colors.textSecondary)
                .lineLimit(2)
            }

            Spacer()
        }
    }
}
