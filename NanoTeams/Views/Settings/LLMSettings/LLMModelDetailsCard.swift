import SwiftUI

/// Read-only card showing the parameters the selected chat model is loaded
/// with, per the provider's metadata endpoints — LM Studio `/api/v0/models`
/// (state, loaded vs max context, quantization, arch) or Ollama `/api/show` +
/// `/api/ps` (modelfile parameters, quantization, VRAM, keep-alive expiry).
/// Purely informational; refreshes when the model / server / provider
/// selection changes and via the Refresh button.
struct LLMModelDetailsCard: View {
    @Bindable var config: StoreConfiguration

    /// The probe and its result live in the catalog, which owns the client seam. This card
    /// built `LLMClientRouter()` inline until 2026-08-24, with no seam at all — so the
    /// `#Preview` of the sheet that hosts it probed a real server on appear.
    ///
    /// The generation counter that stood here (CLAUDE.md #38) went with it: the catalog keys
    /// its results by `(url, provider, model)`, so a slow probe from a previous selection
    /// lands in its own slot instead of racing for a single shared one.
    @Environment(ModelCatalog.self) private var modelCatalog

    private var details: ModelLoadDetails? {
        modelCatalog.details(for: config.globalLLMConfig)
    }

    private var isLoading: Bool {
        modelCatalog.isLoadingDetails(for: config.globalLLMConfig)
    }

    /// Keyed on the endpoint COMMIT generation, not the live URL: the Settings URL
    /// field writes `llmBaseURLString` on every keystroke, so a URL-keyed task
    /// re-fires per typed character and probes half-typed hosts.
    private var fetchKey: String {
        "\(config.llmProvider.rawValue)|\(config.llmEndpointGeneration)|\(config.llmModelName)"
    }

    private var footerText: String? {
        switch config.llmProvider {
        case .lmStudio:
            "Sampling parameters live in LM Studio's per-model config and are not reported over its REST API."
        case .ollama:
            nil
        }
    }

    var body: some View {
        SettingsCard(
            header: "Model Details",
            systemImage: "cpu",
            footer: footerText
        ) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                content

                HStack {
                    SettingsPillButton(
                        title: "Refresh",
                        icon: "arrow.clockwise",
                        isLoading: isLoading,
                        action: { Task { await refresh() } }
                    )
                    .disabled(isLoading || trimmedModelName.isEmpty)
                    Spacer()
                }
            }
        }
        .task(id: fetchKey) {
            await refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        if trimmedModelName.isEmpty {
            emptyRow("Pick a model above to see its load parameters.")
        } else if let details {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(details.fields) { field in
                    detailRow(field)
                }
            }
        } else if isLoading {
            emptyRow("Loading…")
        } else {
            emptyRow("No details available — check that the server is reachable and the model exists there.")
        }
    }

    private func detailRow(_ field: ModelLoadDetails.Field) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Text(field.label)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .frame(width: 160, alignment: .leading)
            Text(field.value)
                .font(Typography.termXs)
                .foregroundStyle(Colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Colors.textTertiary)
    }

    private var trimmedModelName: String {
        config.llmModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refresh() async {
        await modelCatalog.loadDetails(for: config.globalLLMConfig)
    }
}
