import SwiftUI

/// LLM settings with card layout.
///
/// Owns Test-Connection state. Model lists come from the shared
/// `ModelCatalog`, so opening multiple settings tabs against the same
/// server doesn't re-issue `/api/v1/models`.
struct LLMSettingsView: View {
    @Environment(StoreConfiguration.self) var config
    @Environment(NTMSOrchestrator.self) var store
    @Environment(ModelCatalog.self) var modelCatalog
    /// Optional on purpose: this view's `#Preview` injects no monitor, and a
    /// missing `@Observable` environment value is a runtime trap rather than nil.
    @Environment(LLMStatusMonitor.self) private var statusMonitor: LLMStatusMonitor?

    @State private var connectionStatus: LLMConnectionStatus = .idle
    @State private var statusMessage: String = ""

    /// In-memory mirror of the LM Studio bearer token for the currently-typed
    /// URL. `LLMTokenField` (inside `LLMEndpointEditor`) owns the
    /// load-on-appear / save-on-change Keychain lifecycle — this view only
    /// holds the binding so it can pass the live value to Test Connection.
    @State private var apiToken: String = ""

    private var availableModels: [String] {
        modelCatalog.models(for: config.llmBaseURLString, provider: config.llmProvider)
    }

    private var isFetchingModels: Bool {
        modelCatalog.isFetching(config.llmBaseURLString, provider: config.llmProvider)
    }

    private var modelFetchError: String? {
        modelCatalog.error(for: config.llmBaseURLString, provider: config.llmProvider)
    }

    var body: some View {
        @Bindable var config = config

        ScrollView {
            VStack(spacing: Spacing.xl) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Colors.info)
                    Text(providerRequirementNote)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                LLMServerConfigCard(
                    config: config,
                    apiToken: $apiToken,
                    connectionStatus: connectionStatus,
                    statusMessage: statusMessage,
                    availableModels: availableModels,
                    isFetchingModels: isFetchingModels,
                    modelFetchError: modelFetchError,
                    onTestConnection: { Task { await testConnection() } },
                    onRefreshModels: { Task { await modelCatalog.refresh(url: config.llmBaseURLString, provider: config.llmProvider) } },
                    onTokenSaveError: { error in
                        store.lastErrorMessage = "Could not save API token: \(error.localizedDescription)"
                    },
                    onTokenLoadError: { error in
                        store.lastErrorMessage = "Could not read saved API token: \(error.localizedDescription)"
                    },
                    onURLCommit: {
                        // The commit boundary endpoint-keyed views watch. Bumped
                        // here rather than from `llmBaseURLString`'s setter, which
                        // fires on every keystroke.
                        config.noteLLMEndpointCommitted()
                        Task { await testConnection() }
                        // Reconcile from the COMMIT boundary, never from the
                        // live binding: the URL field writes on every
                        // keystroke, so a fingerprint-driven reconcile would
                        // compare a half-typed URL against the owned
                        // instance's base and unload a resident model because
                        // the user was editing a port number.
                        Task { await store.reconcileAndReportResidency() }
                    }
                )

                LLMModelDetailsCard(config: config)

                DownloadedModelsCard()

                LLMErrorHandlingCard(config: config)
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
        // NOTE: the model-switch (unload old / load new) hook is NOT here — it
        // lives in MainLayoutView so the status-bar quick picker is covered too.
        .task {
            // First-appear load only. URL edits do NOT re-trigger fetches
            // here — that would ping the server on every keystroke. The
            // URL field's onCommit (focus loss / Enter) runs Test Connection
            // which refreshes on success; the Refresh button forces a
            // re-fetch independently.
            await modelCatalog.loadIfNeeded(url: config.llmBaseURLString, provider: config.llmProvider)
        }
    }

    private var providerRequirementNote: String {
        switch config.llmProvider {
        case .lmStudio: "Requires LM Studio 0.4.0 or later."
        case .ollama: "Requires Ollama 0.9 or later."
        }
    }

    // MARK: - Actions

    private func testConnection() async {
        connectionStatus = .checking
        statusMessage = ""

        let result = await LLMConnectionChecker.checkWithMessage(
            baseURL: config.llmBaseURLString,
            provider: config.llmProvider,
            bearerToken: apiToken)
        connectionStatus = result.isReachable ? .success : .failure
        statusMessage = result.message
        // Feed the shared monitor so the status strip agrees with what this card
        // just reported, instead of holding the stale verdict until the next poll
        // tick. Success publishes directly; failure triggers the monitor's own
        // probe rather than publishing red — this probe's token may differ from
        // the Keychain-resolved one the monitor uses, so a failure here is
        // evidence, not a verdict.
        await statusMonitor?.noteProbeOutcome(reachable: result.isReachable)
        if result.isReachable {
            await modelCatalog.refresh(url: config.llmBaseURLString, provider: config.llmProvider)
        }
    }
}

#Preview {
    @Previewable @State var store = PreviewStore.make()
    @Previewable @State var catalog = PreviewStore.catalog()
    LLMSettingsView()
        .environment(store)
        .environment(store.configuration)
        .environment(catalog)
}
