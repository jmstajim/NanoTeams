import SwiftUI

/// Everything one benchmark run recorded, including the parts no table can hold.
///
/// The two tables answer "how fast" and refuse to answer anything else — deliberately, because a
/// column of identical values states nothing and the settings pane has no width to spare. But the
/// run record has always carried far more than they show: every sample including the ones the
/// medians excluded and the reason each was excluded, the machine's thermal state, what this app
/// did to the model's residency, and the whole `serverFields` dictionary — VRAM, context lengths,
/// engine build, the output cap. Until this sheet, all of it existed only as JSON on disk.
///
/// A sheet rather than a row that expands inside the `Grid`, and the reason is width. A cell
/// spanning the table's columns takes part in solving their widths, so one verbatim `serverFields`
/// value — "Unloaded for this run: qwen/qwen3-coder-30b, mistral-small-3.2, gpt-oss-20b" — would
/// widen five columns for every row in the table. That dictionary is unbounded by design, so the
/// hazard would be standing rather than one-time, and nothing in this suite can pin a layout
/// regression. Chrome mirrors `BenchmarkPromptSheet`, the other sheet on this screen.
struct BenchmarkRunDetailSheet: View {
    let run: GenerationBenchmarkRun
    let samples: [GenerationBenchmarkSample]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                MonoLabel(text: "Run Detail", marker: true)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.terminalSecondary)
                    .controlSize(.small)
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.m)

            TerminalDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    identity
                    section("Rates", help: Self.ratesHelp) {
                        BenchmarkSummaryRows(summary: summary)
                    }
                    section("Samples", help: Self.samplesHelp) { sampleTable }
                    section("Conditions", help: Self.conditionsHelp) {
                        rows(Self.conditionRows(for: run))
                    }
                    section("What the server said", help: Self.serverFieldsHelp) {
                        if run.serverFields.isEmpty {
                            note(Self.noServerFields)
                        } else {
                            rows(Self.serverFieldRows(for: run))
                        }
                    }
                    section("Sampling parameters", help: Self.samplingHelp) {
                        if run.samplingParameters.isEmpty {
                            note(Self.noSamplingParameters(provider: run.provider))
                        } else {
                            rows(Self.samplingParameterRows(for: run))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.standard)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    /// Summarised here rather than passed in: the caller holds the same samples, and a summary
    /// computed twice from one input cannot disagree with itself, while a summary threaded through
    /// a second parameter can arrive stale.
    private var summary: BenchmarkMetricsPolicy.RunSummary {
        BenchmarkMetricsPolicy.summarize(samples)
    }

    // MARK: - Blocks

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs) {
                Text(run.modelName)
                    .font(Typography.subheadlineSemibold)
                    .textSelection(.enabled)
                if run.wasThrottled {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.warning)
                        .help(BenchmarkResultsCard.throttledTooltip(everyContributingRun: false))
                }
            }
            Text(Self.subtitle(for: run))
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func section(
        _ title: String, help: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                MonoLabel(text: title.uppercased(), marker: false)
                InfoTip(help, font: Typography.caption)
            }
            content()
        }
    }

    private func rows(_ rows: [DetailRow]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: Spacing.s) {
                    Text(row.label)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                        .frame(width: 190, alignment: .leading)
                    Text(row.value)
                        .font(Typography.termXs)
                        .foregroundStyle(Colors.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var sampleTable: some View {
        Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.xs) {
            GridRow {
                ForEach(Self.sampleColumnTitles, id: \.self) { title in
                    Text(title)
                        .font(Typography.caption2)
                        .foregroundStyle(Colors.textTertiary)
                }
            }
            ForEach(Self.sampleRows(for: samples)) { row in
                GridRow {
                    Text(row.index)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                    cell(row.promptTokens, dim: row.isVoid)
                    cell(row.outputTokens, dim: row.isVoid)
                    cell(row.ttft, dim: row.isVoid)
                    cell(row.prefill, dim: row.isVoid)
                    cell(row.generation, dim: row.isVoid)
                    cell(row.load, dim: row.isVoid)
                    cell(row.total, dim: row.isVoid)
                    cell(row.stop, dim: row.isVoid)
                    Text(row.outcome)
                        .font(Typography.caption)
                        .foregroundStyle(row.isVoid ? Colors.warning : Colors.textTertiary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// A voided sample's numbers are dimmed rather than hidden: they are what the run actually
    /// produced before it was discarded, and a blank row cannot be told from a rendering fault.
    private func cell(_ text: String, dim: Bool) -> some View {
        Text(text)
            .font(Typography.termXs)
            .monospacedDigit()
            .foregroundStyle(dim ? Colors.textTertiary : Colors.textPrimary)
    }
}
