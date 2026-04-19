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
                Picker("", selection: $config.teamGenForcedSupervisorMode) {
                    Text("Auto (LLM decides)").tag(Optional<SupervisorMode>.none)
                    ForEach(SupervisorMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(Optional<SupervisorMode>.some(mode))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            HStack {
                Text("Acceptance Mode")
                    .font(Typography.subheadline)
                Spacer()
                Picker("", selection: $config.teamGenForcedAcceptanceMode) {
                    Text("Auto (LLM decides)").tag(Optional<AcceptanceMode>.none)
                    ForEach(Self.acceptanceModes, id: \.self) { mode in
                        Text(mode.displayName).tag(Optional<AcceptanceMode>.some(mode))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
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
