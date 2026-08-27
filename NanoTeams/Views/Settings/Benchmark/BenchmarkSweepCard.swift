import SwiftUI

/// Measure every model on every server, one after another.
///
/// Reads nothing from the environment: every input is a parameter, so the card is a pure function
/// of its inputs and its presentation helpers are unit-testable without SwiftUI — the same rule
/// `BenchmarkRunCard` follows.
///
/// The server list is on screen BEFORE anything is measured, and that placement is the feature's
/// licence to touch a provider the app was never configured with. A sweep clears every server it
/// measures against, so the addresses it will send commands to have to be readable, editable and
/// switchable off first (`DEBTS.md` D-B1 §2).
struct BenchmarkSweepCard: View {

    /// Typed-but-not-yet-committed API tokens, keyed by row.
    ///
    /// Only what the field needs to render. The value is NOT what authorises the requests — every
    /// client resolves the token from the Keychain by URL at send time — so nothing here is a
    /// second home for a secret, and nothing persists it (`LLMTokenField` owns that side, writing
    /// to the Keychain and to nowhere else).
    @State private var tokens: [String: String] = [:]

    let servers: [BenchmarkSweepServer]
    let entries: [BenchmarkSweepEntry]
    let phase: BenchmarkSweepRunner.Phase
    /// The per-sample detail of whichever entry is being measured. Shown beside the entry rather
    /// than copied into it — one fact, one home (CLAUDE.md #91).
    let targetPhase: GenerationBenchmarkRunner.Phase
    let isMeasuring: Bool
    let isScanning: Bool
    /// A stopped sweep still has models nobody has measured.
    let canResume: Bool
    /// Why measuring is impossible right now, or nil when it is not.
    let blockReason: BenchmarkBlockReason?
    /// What is known about each planned model, keyed by entry id — which is the leaderboard's own
    /// group key, so this map and the sweep's entries agree by construction. Assembled by the
    /// screen, which is the only place that can see both the live catalog and the run history.
    var badges: [String: LLMModelInfo] = [:]
    /// The sweep sends the same workload as a single run, so it shows the same two controls.
    @Binding var repeats: Int
    let wireConfig: LLMConfig
    let onSetIncluded: (LLMProvider, Bool) -> Void
    let onSetEndpoint: (LLMProvider, String) -> Void
    let onSetSelected: (String, Bool) -> Void
    let onSetAllSelected: (Bool) -> Void
    let onRescan: () -> Void
    let onRunAll: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    /// The screen's Run / All models switch, rendered as this card's first row. See the twin
    /// parameter on `BenchmarkRunCard`.
    var modePicker: AnyView?

    var body: some View {
        SettingsCard(
            header: "All models",
            systemImage: "square.stack.3d.up",
            footer: Self.footer(blockedBy: blockReason)
        ) {
            if let modePicker { modePicker }
            ForEach(servers) { server in
                serverRow(server)
            }
            TerminalDivider()
            // The same two rows the single-model tab shows, because they describe the WORKLOAD and
            // a sweep sends exactly that workload once per model. Putting them only on the other
            // tab would hide the settings that decide how long a sweep takes on the screen the user
            // leaves in order to start one.
            BenchmarkWorkloadSection(repeats: $repeats, wireConfig: wireConfig)
            TerminalDivider()
            statusRow
            if !entries.isEmpty {
                TerminalDivider()
                progressList
            }
        }
    }

    // MARK: - Server rows

    @ViewBuilder
    private func serverRow(_ server: BenchmarkSweepServer) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Toggle(isOn: Binding(
                    get: { server.isIncluded },
                    set: { onSetIncluded(server.provider, $0) })
                ) {
                    Text(server.provider.displayName)
                        .font(Typography.subheadlineMedium)
                        .foregroundStyle(Colors.textPrimary)
                }
                .toggleStyle(.terminal)
                .disabled(isMeasuring)

                Spacer()

                Text(Self.statusText(for: server))
                    .font(Typography.caption)
                    .foregroundStyle(Self.statusTint(for: server))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if server.isIncluded {
                LLMElevatedTextField(
                    "Endpoint",
                    text: Binding(
                        get: { server.baseURLString },
                        set: { onSetEndpoint(server.provider, $0) }),
                    prompt: server.provider.defaultBaseURL,
                    defaultValue: server.provider.defaultBaseURL)
                    .disabled(isMeasuring)
                // Keyed by the row's own address, so a server behind LM Studio's "Require
                // Authentication" can be scanned, measured and cleared like any other. Without it
                // this screen was the one place that addresses a server it has no way to
                // authenticate to, and the row read "no answer" about a machine that was answering
                // 401 all along.
                LLMTokenField(
                    baseURL: server.baseURLString,
                    token: Binding(
                        get: { tokens[server.id] ?? "" },
                        set: { tokens[server.id] = $0 }),
                    isEnabled: !isMeasuring)
                if let note = Self.addressNote(for: server) {
                    Text(note)
                        .font(Typography.caption2)
                        .foregroundStyle(Colors.textTertiary)
                }
            }
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(spacing: Spacing.s) {
            if isScanning || isMeasuring {
                NTMSLoader(font: Typography.subheadline, color: Colors.accent)
            }
            Text(Self.statusText(phase: phase, entries: entries, isScanning: isScanning))
                .font(Typography.subheadline)
                .foregroundStyle(Self.statusTint(phase: phase))
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            if isMeasuring {
                SettingsPillButton(title: "Cancel", icon: "stop.fill", action: onCancel)
            } else {
                SettingsPillButton(
                    title: "Rescan", icon: "arrow.clockwise",
                    isLoading: isScanning, action: onRescan)
                    .disabled(isScanning)
                if canResume {
                    SettingsPillButton(
                        title: "Resume", icon: "playpause.fill", action: onResume)
                        .disabled(blockReason != nil)
                }
                SettingsPillButton(
                    title: Self.runTitle(entries: entries), icon: "play.fill", action: onRunAll)
                    .disabled(blockReason != nil || !Self.canRun(entries: entries) || isScanning)
            }
        }
    }

    // MARK: - Progress

    private var progressList: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if !isMeasuring {
                HStack {
                    Text(Self.selectionLabel(entries: entries))
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                    Spacer()
                    SettingsPillButton(
                        title: Self.selectAllTitle(entries: entries),
                        icon: Self.allSelected(entries) ? "circle" : "checkmark.circle",
                        action: { onSetAllSelected(!Self.allSelected(entries)) })
                }
            }
            ForEach(entries) { entry in
                entryRow(entry)
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: BenchmarkSweepEntry) -> some View {
        HStack(spacing: Spacing.s) {
            // The tick and the outcome share a column: before a run it is the choice, during and
            // after it is what happened. One row, one leading glyph, and never both competing for
            // the same eye.
            if isMeasuring || entry.state.isSettled {
                Image(systemName: Self.icon(for: entry.state))
                    .font(Typography.caption)
                    .foregroundStyle(Self.tint(for: entry.state))
                    .frame(width: SettingsLayout.toggleIconSize / 2)
            } else {
                Button {
                    onSetSelected(entry.id, !entry.isSelected)
                } label: {
                    Image(systemName: entry.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(Typography.caption)
                        .foregroundStyle(entry.isSelected ? Colors.accent : Colors.textTertiary)
                        .frame(width: SettingsLayout.toggleIconSize / 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.target.modelName)
                .accessibilityAddTraits(entry.isSelected ? [.isSelected] : [])
            }

            Text(entry.target.modelName)
                .font(Typography.caption)
                .foregroundStyle(entry.isSelected ? Colors.textPrimary : Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(entry.target.provider.displayName)
                .font(Typography.caption2)
                .foregroundStyle(Colors.textTertiary)

            // What this exact server says about this exact model, RIGHT NOW — the scan that built
            // this list already carried its format and quantization, so these cost nothing beyond
            // the request that found the model in the first place. Absent only when the server
            // reported neither, never as a placeholder.
            ModelChipsRow(badges[entry.id])

            Spacer()
            Text(Self.detail(for: entry.state, targetPhase: targetPhase))
                .font(Typography.caption)
                .monospacedDigit()
                .foregroundStyle(Self.tint(for: entry.state))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: - Pure presentation (unit-tested)

    /// What is known about each planned model, keyed by the entry id (`BenchmarkLeaderboard.groupKey`).
    ///
    /// Two sources, in this order:
    ///
    /// 1. **What a past run recorded**, so a model on a server that has since stopped answering
    ///    still shows what it was measured as. Runs are walked oldest-first, so the newest
    ///    measurement wins within this layer.
    /// 2. **What the server says now**, which OVERWRITES the historical answer. `fetchModels`
    ///    returns each model's format and quantization alongside its name — in the one response the
    ///    sweep's own scan already makes — so every listed model is labelled before anything has
    ///    been measured, at no additional request.
    ///
    /// The live answer wins because this is a list of models about to be LOADED: a model
    /// re-downloaded in another format keeps its old format in every row measured before the swap,
    /// and repeating that here would describe the wrong file. The leaderboard keeps saying what was
    /// measured, which is the truth about the measurement. Two questions, two answers, neither
    /// overwriting the other.
    ///
    /// `infos` is a closure rather than a catalog so this stays a pure function of its inputs —
    /// the same rule the rest of this card's presentation follows.
    static func badges(
        runs: [GenerationBenchmarkRun],
        servers: [BenchmarkSweepServer],
        infos: (BenchmarkSweepServer) -> [LLMModelInfo]
    ) -> [String: LLMModelInfo] {
        var out: [String: LLMModelInfo] = [:]

        // Typed fields, not `serverFields["Format"]` — decode promotes legacy rows into them, so
        // the string literals would be a second home for a fact that has a typed one (CLAUDE.md #91).
        for run in runs.sorted(by: { $0.startedAt < $1.startedAt }) {
            let key = BenchmarkLeaderboard.groupKey(
                provider: run.provider,
                baseURLString: run.baseURLString,
                modelName: run.modelName)
            out[key] = LLMModelInfo(
                name: run.modelName, format: run.modelFormat, quantization: run.quantization)
        }

        // Excluded servers are skipped: untoggling a provider means the sweep will not touch it,
        // and its models leave the list — labelling rows that are not there would be labelling
        // nothing.
        for server in servers where server.isIncluded {
            for info in infos(server) {
                let key = BenchmarkLeaderboard.groupKey(
                    provider: server.provider,
                    baseURLString: server.baseURLString,
                    modelName: info.name)
                out[key] = info
            }
        }
        return out
    }

    /// What one server answered.
    ///
    /// "no chat models" and "no answer" are deliberately different sentences: the first is a fact
    /// the server stated about itself, the second is the absence of one. And neither is ever
    /// worded "offline" — a server that refuses an unauthorized request is running perfectly well.
    static func statusText(for server: BenchmarkSweepServer) -> String {
        guard server.isIncluded else { return "skipped" }
        switch server.outcome {
        case .none: return "not scanned"
        case .answered(let models):
            guard !models.isEmpty else { return "answered — no chat models" }
            return models.count == 1 ? "1 model" : "\(models.count) models"
        case .noAnswer(let detail):
            guard let detail, !detail.isEmpty else { return "no answer" }
            return "no answer — \(detail)"
        case .undetermined:
            return "a lookup was already in progress — rescan"
        }
    }

    /// Says when an address is the app's suggestion rather than the user's.
    ///
    /// The distinction earns a line of its own because this screen is where a proposed address can
    /// become a server the app sends unload commands to. Nil once the user has typed anything —
    /// there is nothing left to disclose.
    static func addressNote(for server: BenchmarkSweepServer) -> String? {
        guard server.isProposedAddress else { return nil }
        return "You have not configured \(server.provider.displayName). "
            + "This is its usual address — edit it, or switch the provider off."
    }

    static func statusTint(for server: BenchmarkSweepServer) -> Color {
        guard server.isIncluded else { return Colors.textTertiary }
        switch server.outcome {
        case .answered(let models): return models.isEmpty ? Colors.textTertiary : Colors.success
        case .noAnswer: return Colors.warning
        case .undetermined, .none: return Colors.textTertiary
        }
    }

    /// The one-line state of the whole sweep.
    ///
    /// Scanning is a separate input rather than a phase, and it wins over `.idle` only: a scan
    /// that overlapped a finished sweep must not erase what that sweep reported.
    static func statusText(
        phase: BenchmarkSweepRunner.Phase, entries: [BenchmarkSweepEntry], isScanning: Bool = false
    ) -> String {
        if isScanning, phase == .idle { return "Asking each server what it has…" }
        switch phase {
        case .idle:
            guard !entries.isEmpty else {
                return "No models found. Check the endpoints above, then rescan."
            }
            let selected = entries.count(where: \.isSelected)
            guard selected > 0 else { return "Nothing selected." }
            return "\(count(selected)) ready to measure."
        case .measuring(let index, let total):
            return "Measuring \(index) of \(total)…"
        case .finished(let measured, let failed, let skipped):
            var parts = ["\(count(measured)) measured"]
            if failed > 0 { parts.append("\(failed) failed") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            return parts.joined(separator: ", ") + "."
        case .stopped(let reason, let measured):
            switch reason {
            case .cancelled:
                return "Stopped after \(count(measured)). "
                    + "What was measured is recorded."
            case .taskStartedRunning:
                return "Stopped after \(count(measured)) — a task started running, and every "
                    + "sample from here on would have measured it too."
            }
        }
    }

    static func statusTint(phase: BenchmarkSweepRunner.Phase) -> Color {
        switch phase {
        case .stopped: Colors.warning
        case .finished: Colors.textPrimary
        default: Colors.textSecondary
        }
    }

    /// Names the count on the button, so an hour of work cannot start from a button that only
    /// says "Run".
    ///
    /// Counts the SELECTED models, not the listed ones: after ticking eight of twelve off, a
    /// button still offering "Run 12 models" would be describing a run that is not going to happen.
    /// With nothing selected it reads plain "Run" and is disabled — "Run all" beside twelve empty
    /// circles promised the opposite of what pressing it would do.
    static func runTitle(entries: [BenchmarkSweepEntry]) -> String {
        let selected = entries.count(where: \.isSelected)
        return selected == 0 ? "Run" : "Run \(count(selected))"
    }

    /// Whether there is anything for Run to do. Nothing selected is a different reason from
    /// nothing found, and both disable the button.
    static func canRun(entries: [BenchmarkSweepEntry]) -> Bool {
        entries.contains(where: \.isSelected)
    }

    static func allSelected(_ entries: [BenchmarkSweepEntry]) -> Bool {
        !entries.isEmpty && entries.allSatisfy(\.isSelected)
    }

    /// "12 of 12 selected" — always both numbers, so the row reads the same whether or not
    /// anything has been ticked off, and a partial selection cannot be mistaken for the whole list.
    static func selectionLabel(entries: [BenchmarkSweepEntry]) -> String {
        "\(entries.count(where: \.isSelected)) of \(entries.count) selected"
    }

    static func selectAllTitle(entries: [BenchmarkSweepEntry]) -> String {
        allSelected(entries) ? "Select none" : "Select all"
    }

    static func icon(for state: BenchmarkSweepEntry.State) -> String {
        switch state {
        case .pending: "circle"
        case .measuring: "record.circle"
        case .measured: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .skipped: "minus.circle"
        }
    }

    static func tint(for state: BenchmarkSweepEntry.State) -> Color {
        switch state {
        case .pending, .skipped: Colors.textTertiary
        case .measuring: Colors.accent
        case .measured: Colors.textPrimary
        case .failed: Colors.warning
        }
    }

    /// The right-hand column of a progress row.
    ///
    /// A measured row shows its figure; the row being measured borrows the runner's own per-sample
    /// sentence rather than keeping a second copy of it.
    static func detail(
        for state: BenchmarkSweepEntry.State, targetPhase: GenerationBenchmarkRunner.Phase
    ) -> String {
        switch state {
        case .pending: ""
        case .measuring: BenchmarkRunCard.statusText(for: targetPhase)
        case .measured(let summary):
            // `approximate:` was a literal `false` here, on the one screen that measures a dozen
            // unfamiliar models back to back — so a rate the app had timed itself shipped looking
            // exactly like one the server measured. The summary says which it is, and an unknown
            // source reads as approximate, the same rule the tables use.
            BenchmarkRunCard.decorate(
                value: BenchmarkMetricsPolicy.formatRate(summary.generationTokensPerSecond),
                unit: "tok/s",
                approximate: summary.generationRateIsApproximate)
        case .failed(let message): message
        case .skipped: "not measured"
        }
    }

    private static func count(_ n: Int) -> String {
        n == 1 ? "1 model" : "\(n) models"
    }

    static func footer(blockedBy reason: BenchmarkBlockReason?) -> String {
        if let reason { return reason.explanation }
        return "Everything is unloaded on every server listed here — both providers draw on the "
            + "same memory — then each model is loaded, warmed up and sampled alone: minutes per "
            + "model, and your loaded models will be gone. Switch a server off to leave it "
            + "untouched."
    }
}
