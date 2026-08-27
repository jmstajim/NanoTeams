import SwiftUI

// MARK: - General Settings View

struct GeneralSettingsView: View {
    @AppStorage(UserDefaultsKeys.activeTheme) private var activeThemeRaw: String = Theme.defaultTheme.rawValue
    @AppStorage(UserDefaultsKeys.spinnerGlitchEnabled) private var spinnerGlitchEnabled: Bool = true
    @Environment(NTMSOrchestrator.self) var store
    @Environment(StoreConfiguration.self) var config
    @State private var isShowingResetAppConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                inputCard
                globalContextCard
                dangerZoneCard
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
        .confirmationDialog(
            "Reset All Application Settings?",
            isPresented: $isShowingResetAppConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Everything", role: .destructive) {
                Task {
                    config.resetToDefaults()
                    activeThemeRaw = Theme.defaultTheme.rawValue
                    spinnerGlitchEnabled = true
                    await store.resetAllData()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all settings, close the work folder, and restore the application to its initial state. Data in work folders is preserved. This action cannot be undone.")
        }
    }

    // Theme picker moved to the dedicated `ThemeSettingsView` tab (Settings → Theme).

    // MARK: - Input Card

    private var inputCard: some View {
        @Bindable var config = config
        return SettingsCard(
            header: "Input",
            systemImage: "keyboard"
        ) {
            VStack(spacing: 0) {
                settingsToggleRow("Enter sends message", icon: "return", isOn: $config.enterSendsMessage)

                Text("When enabled, Enter sends the message. Use Shift+Enter for a new line.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SettingsLayout.toggleIconSize + Spacing.m)
                    .padding(.bottom, Spacing.s)
            }
        }
    }

    // MARK: - Global Context Card

    private var globalContextCard: some View {
        @Bindable var config = config
        return GlobalContextCard(config: config)
    }

    // MARK: - Danger Zone Card

    private var dangerZoneCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            MonoLabel(text: "Danger Zone", rule: true)

            VStack(alignment: .leading, spacing: Spacing.m) {
                Button {
                    isShowingResetAppConfirmation = true
                } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "trash")
                        Text("Reset All Application Settings")
                    }
                    .font(Typography.captionSemibold)
                    .foregroundStyle(Colors.error)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(
                        RoundedRectangle.squircle(CornerRadius.small)
                            .fill(Colors.errorTint)
                    )
                }
                .buttonStyle(.plain)

                Text("Removes all settings, closes the work folder, and restores the application to its initial state. Data in work folders is preserved.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle.squircle(CornerRadius.medium)
                    .fill(Colors.errorTint)
            )
        }
    }

    // MARK: - Helpers

    private func settingsToggleRow(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        SettingsToggleRow(title: title, icon: icon, isOn: isOn)
    }

}

// MARK: - Settings Toggle Row

struct SettingsToggleRow: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceElevated)
                .frame(width: SettingsLayout.toggleIconSize, height: SettingsLayout.toggleIconSize)
                .overlay(
                    Image(systemName: icon)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                )
            Text(title)
                .font(Typography.subheadline)
            Spacer()
            // Terminal toggle propagates through the environment, but a leftover
            // `.toggleStyle(.switch)` here would override that and re-introduce
            // the AppKit sliding capsule. Pin `.terminal` explicitly so this
            // shared settings row never regresses.
            Toggle("", isOn: $isOn)
                .toggleStyle(.terminal)
                .labelsHidden()
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(isHovered ? Colors.surfaceHover : .clear)
        )
        .trackHover($isHovered)
        .animation(Animations.quick, value: isHovered)
    }
}

// MARK: - Previews

#Preview("General Settings") {
    @Previewable @State var store = PreviewStore.make()
    @Previewable @State var config = StoreConfiguration()
    GeneralSettingsView()
        .environment(store)
        .environment(config)
        .frame(width: 500, height: 600)
}
