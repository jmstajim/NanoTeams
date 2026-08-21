import SwiftUI

/// The metric rows describing one run's summary.
///
/// Extracted from `BenchmarkRunCard` so the same rows can describe the last run on the settings
/// screen AND any run reopened from the Runs table. The alternative was a second hand-written set,
/// which is how the `~` marker came to be honoured on one surface out of four (CLAUDE.md #51).
///
/// The pure helpers it calls — `decorate`, `generationTip`, `prefillTip`, `formatShare`,
/// `voidedNote` — deliberately stay on `BenchmarkRunCard`. Eight tests pin them there by name, and
/// moving a symbol a pin names turns that pin red by its own logic without anything having
/// regressed (CLAUDE.md #104). Three surfaces already call them across type boundaries.
struct BenchmarkSummaryRows: View {
    let summary: BenchmarkMetricsPolicy.RunSummary

    @ViewBuilder
    var body: some View {
        metricRow(
            label: "Generation",
            value: BenchmarkMetricsPolicy.formatRate(summary.generationTokensPerSecond),
            unit: "tok/s",
            count: summary.usableCount,
            approximate: summary.generationRateIsApproximate,
            tip: BenchmarkRunCard.generationTip(for: summary.generationRateSource))
        // Shown only when it is a genuine second opinion — with no server figure the headline IS
        // this number, and repeating it would read as agreement between two measurements.
        if summary.generationRateSource?.isApproximate == false,
           let client = summary.clientGenerationTokensPerSecond {
            metricRow(
                label: "…as the app timed it",
                value: BenchmarkMetricsPolicy.formatRate(client),
                unit: "tok/s",
                count: summary.usableCount,
                approximate: true,
                tip: "The same generation measured by this app's own clock, from the first "
                    + "chunk to the last. It carries network and scheduling overhead the "
                    + "server's own figure does not, so it reads slightly lower — a large gap "
                    + "means the machine, not the model, was the bottleneck.")
        }
        if let share = summary.reasoningTokenShare {
            metricRow(
                label: "Of that, thinking",
                value: BenchmarkRunCard.formatShare(share),
                unit: "",
                count: summary.usableCount,
                approximate: false,
                tip: "How much of the output the model spent reasoning before answering. A high "
                    + "share is why a model can feel slow while generating at full speed — the "
                    + "tokens are real, they are just not the answer.")
        }
        metricRow(
            label: "Time to first token (TTFT)",
            value: BenchmarkMetricsPolicy.formatDuration(summary.timeToFirstTokenMs),
            unit: "",
            count: summary.usableCount,
            approximate: false,
            tip: "Measured from the moment the request is sent, so it includes waiting in a "
                + "queue and loading the model. That is the point — it is what "
                + "\"it feels stuck\" actually measures.")
        metricRow(
            label: "Prompt prefill",
            value: BenchmarkMetricsPolicy.formatRate(summary.prefillTokensPerSecond),
            unit: "tok/s",
            count: summary.usableCount,
            approximate: summary.prefillIsApproximate,
            tip: BenchmarkRunCard.prefillTip(for: summary.prefillSource))
        if summary.voidedCount > 0 {
            Text(BenchmarkRunCard.voidedNote(summary.voidedCount))
                .font(Typography.caption)
                .foregroundStyle(Colors.warning)
        }
    }

    private func metricRow(
        label: String, value: String, unit: String, count: Int,
        approximate: Bool, tip: String?
    ) -> some View {
        HStack(spacing: Spacing.s) {
            Text(label)
                .font(Typography.subheadline)
                .foregroundStyle(Colors.textSecondary)
            Spacer()
            Text(BenchmarkRunCard.decorate(value: value, unit: unit, approximate: approximate))
                .font(Typography.subheadlineMedium)
                .monospacedDigit()
                .foregroundStyle(Colors.textPrimary)
            Text("n=\(count)")
                .font(Typography.caption)
                .monospacedDigit()
                .foregroundStyle(Colors.textTertiary)
            if let tip { InfoTip(tip) }
        }
    }
}
