import SwiftUI

// MARK: - Updates Settings View

/// Tab for app-update status + cadence configuration. Always surfaces the
/// latest fetched release regardless of skip status.
struct UpdatesSettingsView: View {
    @Environment(AppUpdateState.self) private var appUpdateState
    @Environment(StoreConfiguration.self) private var config
    @Environment(NTMSOrchestrator.self) private var store

    var body: some View {
        @Bindable var bindableConfig = config

        ScrollView {
            VStack(spacing: Spacing.xl) {
                StarOnGitHubBanner(size: .regular)

                versionStatusCard

                backgroundCheckCard(interval: $bindableConfig.appUpdateCheckInterval)
            }
            .padding(Spacing.l)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Version Status Card

    private var versionStatusCard: some View {
        SettingsCard(header: "Version", systemImage: "info.circle") {
            HStack {
                Text("Installed")
                    .font(Typography.subheadline)
                    .foregroundStyle(Colors.textSecondary)
                Spacer()
                Text(AppVersion.current)
                    .font(.callout.monospaced().weight(.medium))
                    .foregroundStyle(Colors.textPrimary)
            }

            HStack {
                Text("Latest")
                    .font(Typography.subheadline)
                    .foregroundStyle(Colors.textSecondary)
                Spacer()
                latestVersionLabel
            }

            if let last = appUpdateState.lastCheckedAt {
                HStack {
                    Text("Last checked")
                        .font(Typography.subheadline)
                        .foregroundStyle(Colors.textSecondary)
                    Spacer()
                    Text(last.formatted(.relative(presentation: .named)))
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                }
            }

            statusLine

            actionRow
        }
    }

    @ViewBuilder
    private var latestVersionLabel: some View {
        if let latest = appUpdateState.latestRelease {
            Text(latest.tag)
                .font(.callout.monospaced().weight(.medium))
                .foregroundStyle(appUpdateState.hasNewerRelease ? Colors.accent : Colors.textPrimary)
        } else if appUpdateState.lastCheckedAt == nil {
            Text("Not checked yet")
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
        } else {
            Text("Unknown")
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let failure = appUpdateState.lastCheckFailure {
            HStack(spacing: Spacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Colors.error)
                Text(failure)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.error)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.s)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.errorTint)
            )
        } else if appUpdateState.hasNewerRelease, let latest = appUpdateState.latestRelease {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Colors.accent)
                    Text("New version \(latest.tag) is available")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Colors.accent)
                }
                if appUpdateState.isLatestSkipped {
                    Text("Previously dismissed in the Watchtower banner.")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.s)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.accentTint)
            )
        } else if appUpdateState.lastCheckedAt != nil, !appUpdateState.isChecking {
            HStack(spacing: Spacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Colors.success)
                Text("You're on the latest version")
                    .font(Typography.subheadline)
                    .foregroundStyle(Colors.success)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.s)
            .background(
                RoundedRectangle.squircle(CornerRadius.small)
                    .fill(Colors.successTint)
            )
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: Spacing.s) {
            if let latest = appUpdateState.latestRelease, appUpdateState.hasNewerRelease {
                Button {
                    URLOpener.open(latest.htmlURL) { store.lastErrorMessage = $0 }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update Now")
                    }
                    .font(Typography.captionSemibold)
                    .foregroundStyle(Colors.textOnAccent)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(Capsule(style: .continuous).fill(Colors.accent))
                }
                .buttonStyle(.plain)

                if appUpdateState.isLatestSkipped {
                    SettingsPillButton(title: "Show in Watchtower", icon: "eye") {
                        appUpdateState.unskip(latest.tag)
                    }
                }
            }

            Spacer()

            SettingsPillButton(
                title: appUpdateState.isChecking ? "Checking…" : "Check for Updates",
                icon: "arrow.clockwise",
                isLoading: appUpdateState.isChecking
            ) {
                Task { await appUpdateState.refresh(force: true) }
            }
        }
    }

    // MARK: - Background Check Card

    private func backgroundCheckCard(interval: Binding<AppUpdateCheckInterval>) -> some View {
        SettingsCard(
            header: "Background Check",
            systemImage: "clock",
            footer: "The \"Check for Updates\" button always queries GitHub regardless of this setting."
        ) {
            Picker("Check automatically", selection: interval) {
                ForEach(AppUpdateCheckInterval.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
        }
    }
}

#Preview {
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var appUpdateState = AppUpdateState(config: StoreConfiguration())
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    UpdatesSettingsView()
        .environment(appUpdateState)
        .environment(config)
        .environment(store)
        .frame(width: 500, height: 600)
        .background(Colors.surfacePrimary)
}
