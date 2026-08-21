import SwiftUI

/// The run controls and the result of the last run.
///
/// Reads nothing from the environment: every input is a parameter, so the whole card is a pure
/// function of its inputs and its presentation helpers are unit-testable without SwiftUI.
struct BenchmarkRunCard: View {
    /// The typed-but-not-yet-committed API token for this target's endpoint. What authorises a
    /// request is the Keychain entry `LLMTokenField` writes, keyed by URL — this holds only what
    /// the field is currently showing.
    @State private var apiToken = ""

    /// The screen's OWN target. Editing it here never touches the app's active LLM settings —
    /// measuring model B must not switch the workspace onto model B.
    @Binding var target: BenchmarkTarget
    @Binding var repeats: Int
    let availableModels: [String]
    /// What the server says about the model currently selected, when it has been asked. Nil is the
    /// ordinary case before a fetch — and renders as nothing, never as a placeholder.
    var selectedModelInfo: LLMModelInfo?
    let isFetchingModels: Bool
    let onRefreshModels: () -> Void
    /// Copies the app's current LLM settings over the local target, for the common case of
    /// "measure what I am actually using".
    let onUseAppSettings: () -> Void
    /// The exact config `start()` would send, so "View prompt" can show the body this screen
    /// posts rather than a reconstruction of it.
    let wireConfig: LLMConfig
    let phase: GenerationBenchmarkRunner.Phase
    let summary: BenchmarkMetricsPolicy.RunSummary?
    /// Why measuring is impossible right now, or nil when it is not.
    let blockReason: BenchmarkBlockReason?
    /// The screen's Run / All models switch, rendered as this card's first row.
    ///
    /// Injected rather than owned because the choice is the SCREEN's, not the card's — the card
    /// that is not on screen cannot host the control that would bring it back. A `var` so the
    /// implicit `nil` keeps previews and tests building the card without one.
    var modePicker: AnyView?
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        SettingsCard(
            header: "Run",
            systemImage: "speedometer",
            footer: Self.footer(blockedBy: blockReason)
        ) {
            if let modePicker { modePicker }
            providerRow
            endpointRow
            LLMModelPickerSection(
                modelName: $target.modelName,
                availableModels: availableModels,
                isFetching: isFetchingModels,
                accessory: AnyView(ModelChipsRow(selectedModelInfo)),
                onRefresh: onRefreshModels)
            useAppSettingsRow
            TerminalDivider()
            BenchmarkWorkloadSection(repeats: $repeats, wireConfig: wireConfig)
            TerminalDivider()
            statusRow
            if let summary { BenchmarkSummaryRows(summary: summary) }
        }
    }

    // MARK: - Rows

    private var providerRow: some View {
        HStack(spacing: Spacing.s) {
            Text("Provider")
                .font(Typography.subheadline)
                .foregroundStyle(Colors.textSecondary)
            TerminalPicker(
                selection: $target.provider,
                options: LLMProvider.allCases.map { ($0, $0.displayName) })
            Spacer()
        }
        // Switching provider carries the old provider's endpoint and model, which belong to a
        // server that is not there. Both are reset to the new provider's defaults so the row can
        // never describe a target that cannot exist.
        .onChange(of: target.provider) { _, provider in
            target.baseURLString = provider.defaultBaseURL
            target.modelName = ""
        }
    }

    private var endpointRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            LLMElevatedTextField(
                "Endpoint",
                text: $target.baseURLString,
                prompt: target.provider.defaultBaseURL,
                defaultValue: target.provider.defaultBaseURL)
            // The benchmark owns its endpoint, so it needs its own way to authenticate to it: a
            // target pointed at a password-protected LM Studio had no field to carry the token,
            // and every request from this screen came back 401. Keyed by URL like every other
            // token field, so a target that happens to match the app's main server simply finds
            // the token already there.
            LLMTokenField(baseURL: target.baseURLString, token: $apiToken)
        }
    }

    private var useAppSettingsRow: some View {
        HStack {
            Text(Self.targetLabel(
                provider: target.provider,
                endpoint: target.baseURLString,
                modelName: target.modelName))
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            SettingsPillButton(
                title: "Use app settings", icon: "arrow.down.doc", action: onUseAppSettings)
        }
    }

    private var statusRow: some View {
        HStack(spacing: Spacing.s) {
            if Self.showsSpinner(for: phase) {
                NTMSLoader(font: Typography.subheadline, color: Colors.accent)
            }
            Text(Self.statusText(for: phase))
                .font(Typography.subheadline)
                .foregroundStyle(Self.statusTint(for: phase))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if Self.isRunning(phase) {
                SettingsPillButton(title: "Cancel", icon: "stop.fill", action: onCancel)
            } else {
                SettingsPillButton(title: "Run", icon: "play.fill", action: onRun)
                    .disabled(blockReason != nil || !target.isRunnable)
            }
        }
    }

    // MARK: - Pure presentation (unit-tested)

    static func targetLabel(provider: LLMProvider, endpoint: String, modelName: String) -> String {
        let host = endpoint.endpointHostLabel
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(provider.displayName) · \(host) · \(model.isEmpty ? "—" : model)"
    }

    static func isRunning(_ phase: GenerationBenchmarkRunner.Phase) -> Bool {
        switch phase {
        case .idle, .finished, .failed: false
        case .preparing, .warmingUp, .measuring: true
        }
    }

    static func showsSpinner(for phase: GenerationBenchmarkRunner.Phase) -> Bool {
        isRunning(phase)
    }

    static func statusText(for phase: GenerationBenchmarkRunner.Phase) -> String {
        switch phase {
        case .idle: "Ready"
        case .preparing: "Reading model details…"
        // Named rather than hidden: a warm-up that looks like a measured sample makes the run
        // appear to take one extra step for no stated reason.
        case .warmingUp: "Warming up the model…"
        case .measuring(let sample, let total): "Sample \(sample) of \(total)…"
        case .finished: "Done"
        case .failed(let message): message
        }
    }

    static func statusTint(for phase: GenerationBenchmarkRunner.Phase) -> Color {
        switch phase {
        case .failed: Colors.error
        case .finished: Colors.textPrimary
        default: Colors.textSecondary
        }
    }

    /// The `~` rides the VALUE, not the column heading: within one column some rows can be exact
    /// (a server that measured its own prefill) and others approximate, and one heading cannot
    /// say both.
    static func decorate(value: String, unit: String, approximate: Bool) -> String {
        // An absent figure gets neither marker nor unit: "~— tok/s" claims an approximate
        // measurement, and "— tok/s" reads as a measurement of nothing per second.
        guard value != BenchmarkMetricsPolicy.noValue else { return value }
        let marker = approximate ? "~" : ""
        let suffix = unit.isEmpty ? "" : " \(unit)"
        return "\(marker)\(value)\(suffix)"
    }

    /// Percent with no decimals: the share answers "roughly how much of this was thinking", and a
    /// tenth of a percent would imply a precision the token counts do not carry.
    static func formatShare(_ share: Double) -> String {
        guard share.isFinite, share >= 0 else { return BenchmarkMetricsPolicy.noValue }
        return "\(Int((min(share, 1) * 100).rounded()))%"
    }

    static func generationTip(for source: GenerationRateSource?) -> String {
        switch source {
        case .serverDecodeWindow:
            return "Exact: the server reported how long it spent decoding, and the tokens were "
                + "divided by that. No clock of ours is in the number."
        case .serverReportedRate:
            return "Exact: the server reported this rate itself, measured over its own decoding "
                + "window. No clock of ours is in the number."
        case .clientWindow, .none:
            return "Approximate. This server reported no generation timing, so the app timed the "
                + "window from the first chunk to the last. That also contains network and "
                + "scheduling overhead, so the figure reads a little low. Compare it only with "
                + "rows from the same source."
        }
    }

    static func prefillTip(for source: PrefillSource?) -> String {
        switch source {
        case .serverPromptEval:
            return "Exact: the server measured the prompt-processing time itself and reported it, "
                + "with decoding excluded."
        case .promptProcessingFrames:
            return "Close: the server announced when prompt processing started and finished, and "
                + "the app timed that window. Waiting in a queue happens before the start, so it "
                + "is outside the measurement."
        case .timeToFirstToken, .none:
            return "Approximate. This server did not report how long it spent reading the prompt, "
                + "so the time to the first token was used instead — that also contains waiting "
                + "in a queue and loading the model. The figure is therefore too low, and the "
                + "colder the request the more so. Compare it only with rows from the same "
                + "source, not with exact ones."
        }
    }

    static func voidedNote(_ count: Int) -> String {
        count == 1
            ? "1 sample could not be used and was excluded from the medians."
            : "\(count) samples could not be used and were excluded from the medians."
    }

    /// Names EVERY server the run clears, not just the target's.
    ///
    /// It used to say "every other model on the server", which stopped being true the day the
    /// residency pass started clearing the other provider's machine too (`DEBTS.md` D-B1 §2). A
    /// sentence that under-states what a measurement tool does to the user's machine is worse than
    /// no sentence: it is the one they would have read to find out.
    static func footer(blockedBy reason: BenchmarkBlockReason?) -> String {
        if let reason { return reason.explanation }
        return "These settings are the benchmark's own — the app's model is unaffected. Every "
            + "other model is unloaded first, on every server this app knows, since both providers "
            + "draw on the same memory. The warm-up request pays for loading; only the samples "
            + "after it are measured."
    }
}
