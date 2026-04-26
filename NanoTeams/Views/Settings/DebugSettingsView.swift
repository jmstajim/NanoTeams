import SwiftUI

// MARK: - Debug Settings View

struct DebugSettingsView: View {
    @Environment(StoreConfiguration.self) var config

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                debugCard
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
    }

    private var debugCard: some View {
        @Bindable var config = config
        return SettingsCard(
            header: "Debug",
            systemImage: "ladybug"
        ) {
            VStack(spacing: 0) {
                SettingsToggleRow(title: "Debug mode", icon: "ladybug", isOn: $config.debugModeEnabled)

                Text("Shows model input messages and artifacts in Team Activity view.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SettingsLayout.toggleIconSize + Spacing.m)
                    .padding(.bottom, Spacing.s)

                SettingsToggleRow(title: "Network logs", icon: "doc.text", isOn: $config.loggingEnabled)

                Text("Saves request and tool call logs locally for debugging. Logs are never sent anywhere — share them manually if needed.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SettingsLayout.toggleIconSize + Spacing.m)
                    .padding(.bottom, Spacing.s)
            }
        }
    }
}

// MARK: - Preview

#Preview("Debug Settings") {
    @Previewable @State var config = StoreConfiguration()
    DebugSettingsView()
        .environment(config)
        .frame(width: 500, height: 400)
}
