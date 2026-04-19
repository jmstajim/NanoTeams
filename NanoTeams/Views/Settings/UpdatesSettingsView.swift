import SwiftUI

// MARK: - Updates Settings View

/// Dedicated tab for app-update status + cadence configuration. Always shows
/// the latest fetched release (regardless of skip status) so the user can
/// install even after dismissing the Watchtower banner.
struct UpdatesSettingsView: View {
    @Environment(AppUpdateState.self) private var appUpdateState
    @Environment(StoreConfiguration.self) private var config

    var body: some View {
        @Bindable var bindableConfig = config

        Form {
            Section("Status") {
                LabeledContent("Installed") {
                    Text(AppVersion.current)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Latest") {
                    if let latest = appUpdateState.latestRelease {
                        Text(latest.tag)
                            .foregroundStyle(.secondary)
                    } else if appUpdateState.lastCheckedAt == nil {
                        Text("Not checked yet")
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Unknown")
                            .foregroundStyle(.tertiary)
                    }
                }
                if let last = appUpdateState.lastCheckedAt {
                    LabeledContent("Last checked") {
                        Text(last.formatted(.relative(presentation: .named)))
                            .foregroundStyle(.secondary)
                    }
                }

                statusLine

                actionRow
            }

            Section {
                Picker("Check automatically", selection: $bindableConfig.appUpdateCheckInterval) {
                    ForEach(AppUpdateCheckInterval.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Background Check")
            } footer: {
                Text("The user-initiated \"Check for Updates\" button always queries GitHub regardless of this setting.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let failure = appUpdateState.lastCheckFailure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Colors.error)
        } else if appUpdateState.hasNewerRelease, let latest = appUpdateState.latestRelease {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Label("New version \(latest.tag) is available.", systemImage: "sparkles")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Colors.accent)
                if appUpdateState.isLatestSkipped {
                    Text("Previously dismissed in the Watchtower banner.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if appUpdateState.lastCheckedAt != nil, !appUpdateState.isChecking {
            Label("You're on the latest version.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(Colors.success)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: Spacing.s) {
            if let latest = appUpdateState.latestRelease, appUpdateState.hasNewerRelease {
                Button("Update Now") {
                    NSWorkspace.shared.open(latest.htmlURL)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                if appUpdateState.isLatestSkipped {
                    Button("Show in Watchtower") {
                        appUpdateState.unskip(latest.tag)
                    }
                    .controlSize(.regular)
                }
            }

            Spacer()

            Button {
                Task { await appUpdateState.refresh(force: true) }
            } label: {
                if appUpdateState.isChecking {
                    HStack(spacing: Spacing.xxs) {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                    }
                } else {
                    Text("Check for Updates")
                }
            }
            .disabled(appUpdateState.isChecking)
        }
    }
}

#Preview {
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var appUpdateState = AppUpdateState(config: StoreConfiguration())
    UpdatesSettingsView()
        .environment(appUpdateState)
        .environment(config)
        .frame(width: 500, height: 500)
}
