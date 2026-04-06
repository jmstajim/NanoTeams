import SwiftUI

// MARK: - General Settings View

struct GeneralSettingsView: View {
    @AppStorage(UserDefaultsKeys.appAppearance) private var appAppearance: AppAppearance = .system
    @Environment(NTMSOrchestrator.self) var store
    @Environment(StoreConfiguration.self) var config
    @State private var isShowingResetAppConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                themeCard
                activityFeedCard
                inputCard
                advancedCard
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
                    appAppearance = .system
                    await store.resetAllData()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all settings, close the work folder, and restore the application to its initial state. Data in work folders is preserved. This action cannot be undone.")
        }
    }

    // MARK: - Theme Card

    private var themeCard: some View {
        SettingsCard(
            header: "Theme",
            systemImage: "paintbrush.pointed",
            footer: "Choose how NanoTeams looks on your device. System follows your macOS appearance setting."
        ) {
            HStack(spacing: Spacing.l) {
                ForEach(AppAppearance.allCases) { appearance in
                    ThemeButton(
                        appearance: appearance,
                        isSelected: appAppearance == appearance
                    ) {
                        withAnimation(Animations.quick) {
                            appAppearance = appearance
                        }
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: - Activity Feed Card

    private var activityFeedCard: some View {
        @Bindable var config = config
        return SettingsCard(
            header: "Activity Feed",
            systemImage: "list.bullet",
            footer: "Configure how conversations are displayed in the activity feed."
        ) {
            VStack(spacing: 0) {
                Text("Expand by default")
                    .font(Typography.captionSemibold)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, Spacing.xs)

                settingsToggleRow("Thinking sections", icon: "brain", isOn: $config.thinkingExpandedByDefault)
                settingsToggleRow("Tool calls", icon: "wrench.and.screwdriver", isOn: $config.toolCallsExpandedByDefault)
                settingsToggleRow("Artifacts", icon: "doc.text", isOn: $config.artifactsExpandedByDefault)
            }
        }
    }

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

    // MARK: - Advanced Card

    private var advancedCard: some View {
        @Bindable var config = config
        return SettingsCard(
            header: "Advanced",
            systemImage: "gearshape.2"
        ) {
            VStack(spacing: 0) {
                settingsToggleRow("Debug mode", icon: "ladybug", isOn: $config.debugModeEnabled)

                Text("Shows model input messages and artifacts in Team Activity view.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SettingsLayout.toggleIconSize + Spacing.m)
                    .padding(.bottom, Spacing.s)

                settingsToggleRow("Network logs", icon: "doc.text", isOn: $config.loggingEnabled)

                Text("Saves request and tool call logs locally for debugging. Logs are never sent anywhere — share them manually if needed.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SettingsLayout.toggleIconSize + Spacing.m)
                    .padding(.bottom, Spacing.s)
            }
        }
    }

    // MARK: - Danger Zone Card

    private var dangerZoneCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Colors.error)
                Text("Danger Zone")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Colors.error)
            }

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
                        Capsule(style: .continuous)
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

private struct SettingsToggleRow: View {
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                )
            Text(title)
                .font(Typography.subheadline)
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
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

// MARK: - Theme Button

struct ThemeButton: View {
    let appearance: AppAppearance
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @ScaledMetric(relativeTo: .body) private var previewWidth: CGFloat = 80
    @ScaledMetric(relativeTo: .body) private var previewHeight: CGFloat = 50

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.s) {
                ZStack {
                    // Background fill (for light/dark) or split view (for system)
                    if appearance == .system {
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Color.white)
                            Rectangle()
                                .fill(Color(white: 0.15))
                        }
                        .frame(width: previewWidth, height: previewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                            .fill(themePreviewColor)
                            .frame(width: previewWidth, height: previewHeight)
                    }

                    // Border on top
                    RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                        .strokeBorder(
                            isSelected ? Colors.accent : Color.primary.opacity(isHovered ? DynamicTintOpacity.stroke : DynamicTintOpacity.badge),
                            lineWidth: isSelected ? 2 : 1
                        )
                        .frame(width: previewWidth, height: previewHeight)
                }
                .shadow(.ui)

                Text(appearance.displayName)
                    .font(isSelected ? Typography.captionSemibold : Typography.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .trackHover($isHovered)
        .animation(Animations.quick, value: isSelected)
        .animation(Animations.quick, value: isHovered)
    }

    private static let previewColorMap: [AppAppearance: Color] = [
        .light: .white,
        .dark: Color(white: 0.15),
        .system: .clear,
    ]

    private var themePreviewColor: Color { Self.previewColorMap[appearance] ?? .clear }
}

// MARK: - Previews

#Preview("General Settings") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    GeneralSettingsView()
        .environment(store)
        .environment(config)
        .frame(width: 500, height: 600)
}

#Preview("Theme Buttons") {
    HStack(spacing: Spacing.l) {
        ThemeButton(appearance: .light, isSelected: false, action: {})
        ThemeButton(appearance: .dark, isSelected: true, action: {})
        ThemeButton(appearance: .system, isSelected: false, action: {})
    }
    .padding()
    .background(Colors.surfacePrimary)
}
