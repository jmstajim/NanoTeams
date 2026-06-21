import SwiftUI

/// Forced generation defaults card. Each row lets the user pin `supervisor_mode` or
/// `acceptance_mode` to a specific value, overriding whatever the LLM chose. `Auto`
/// (the `nil` case) keeps the LLM's decision.
struct GenerateTeamDefaultsCard: View {
    @Bindable var config: StoreConfiguration

    private static let acceptanceModes: [AcceptanceMode] = AcceptanceMode.allCases
        .filter { $0 != .customCheckpoints }

    var body: some View {
        SettingsCard(
            header: "Generation Defaults",
            systemImage: "slider.horizontal.3",
            footer: "Auto = keep whatever the LLM chose for this team."
        ) {
            HStack {
                Text("Supervisor Mode")
                    .font(Typography.subheadline)
                Spacer()
                TerminalPicker(
                    selection: $config.teamGenForcedSupervisorMode,
                    options: [(Optional<SupervisorMode>.none, "Auto (LLM decides)")]
                        + SupervisorMode.allCases.map { (Optional<SupervisorMode>.some($0), $0.displayName) }
                )
                .frame(maxWidth: 220)
            }

            HStack {
                Text("Acceptance Mode")
                    .font(Typography.subheadline)
                Spacer()
                TerminalPicker(
                    selection: $config.teamGenForcedAcceptanceMode,
                    options: [(Optional<AcceptanceMode>.none, "Auto (LLM decides)")]
                        + Self.acceptanceModes.map { (Optional<AcceptanceMode>.some($0), $0.displayName) }
                )
                .frame(maxWidth: 220)
            }
        }
    }
}

#Preview("Defaults") {
    ScrollView {
        GenerateTeamDefaultsCard(config: StoreConfiguration())
            .padding()
    }
    .background(Colors.surfacePrimary)
}
