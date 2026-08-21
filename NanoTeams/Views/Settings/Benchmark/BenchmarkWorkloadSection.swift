import SwiftUI

/// The workload every measurement sends: how many samples it takes, and the prompt it sends.
///
/// Shared by both modes because it describes WHAT is measured, while the cards around it describe
/// WHICH models are measured. A sweep of twenty models sends this same prompt twenty times and
/// takes this same number of samples each time, so hiding these two rows behind the single-model
/// tab would put the settings that define a sweep on a screen the user left to start it.
///
/// It also keeps them from being written twice. The stepper is bound to one stored value and the
/// sheet renders one config, so two copies would not disagree — but they would be two places to
/// change the wording, and the version marker beside the prompt is exactly the sort of fact that
/// drifts in the copy nobody is looking at (CLAUDE.md #55).
struct BenchmarkWorkloadSection: View {

    @State private var showsPrompt = false

    @Binding var repeats: Int
    /// The exact config a run would send, so "View prompt" shows the body this screen posts rather
    /// than a reconstruction of it.
    let wireConfig: LLMConfig

    var body: some View {
        SettingsStepperRow(
            title: "Measured samples",
            icon: "number",
            value: $repeats,
            range: AppDefaults.benchmarkRepeatsRange,
            zeroLabel: nil)

        HStack {
            Text("Prompt")
                .font(Typography.subheadline)
                .foregroundStyle(Colors.textSecondary)
            Spacer()
            Text("\(BenchmarkPrompt.id) v\(BenchmarkPrompt.version)")
                .font(Typography.subheadlineMedium)
                .monospacedDigit()
                .foregroundStyle(Colors.textPrimary)
            InfoTip(Self.promptTip)
            SettingsPillButton(
                title: "View prompt",
                icon: "doc.text.magnifyingglass",
                action: { showsPrompt = true })
        }
        .sheet(isPresented: $showsPrompt) {
            BenchmarkPromptSheet(config: wireConfig)
        }
    }

    /// What `prose-en v4` means for the table below, and nothing about the prompt's own anatomy:
    /// the sheet shows the text, and a fact described in two places drifts in the copy that is not
    /// beside the thing it describes (CLAUDE.md #55).
    static let promptTip =
        "The fixed workload every run sends — press View prompt to read the exact text. The "
            + "version is recorded with each result: change the prompt and older results stop being "
            + "comparable, so they drop out of the leaderboard instead of being ranked beside new ones."
}
