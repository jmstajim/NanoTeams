import SwiftUI

// MARK: - Bash Settings View

/// Settings for the `bash` shell-command tool. Organized around one idea: the
/// **judge is an advisor, the mode decides who acts on it**, and the **sandbox is a
/// separate, orthogonal containment layer**. Controls that can't bite in the
/// current mode are hidden (the judge block + sandbox + rules collapse entirely in
/// `Off`; the no-human sub-choice is `Manual`-only), and power-user knobs (custom
/// rules, unsandboxed fallback, dedicated judge model) sit behind disclosures so
/// the default surface stays short. `BashSettingsVisibility` owns the gating.
struct BashSettingsView: View {
    @Environment(StoreConfiguration.self) var config
    @Environment(NTMSOrchestrator.self) private var store

    @State private var showJudgePreview = false
    @State private var showCustomRules = false
    @State private var showSandboxAdvanced = false

    private var mode: BashExecutionMode { config.bashMode }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                introCard
                executionCard
                if BashSettingsVisibility.showsPolicySections(mode: mode) {
                    judgeSandboxCard
                    rulesCard
                }
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
        .sheet(isPresented: $showJudgePreview) {
            BashJudgePreviewSheet()
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Intro

    private var introCard: some View {
        SettingsCard(header: "Shell command execution", systemImage: "terminal") {
            Text("The `bash` tool lets a role run shell commands through your login shell. It is **off for every role by default** — grant it per-role in the Team Editor (Tools → Shell). Every command is then checked against the policy below before it runs.")
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Spacing.xs)
        }
    }

    // MARK: - Execution

    private var executionCard: some View {
        @Bindable var config = config
        return SettingsCard(header: "Execution", systemImage: "play.circle") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                TerminalSegmentedPicker(
                    selection: $config.bashMode,
                    options: BashExecutionMode.allCases.map { ($0, $0.displayName) })

                Text(config.bashMode.settingDescription)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Judge

    /// Merged Judge + Sandbox card. The judge's strictness sits above one shared
    /// Folder × {Read, Write} access table — the SAME `BashSandboxPermissions` the
    /// Seatbelt sandbox enforces and the judge evaluates against, so the rules live
    /// in exactly one place for both.
    private var judgeSandboxCard: some View {
        @Bindable var config = config
        return SettingsCard(header: "Judge & Sandbox", systemImage: "shield.lefthalf.filled") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                // — Judge strictness —
                TerminalSegmentedPicker(
                    selection: $config.bashRestrictionLevel,
                    options: BashRestrictionLevel.allCases.map { ($0, $0.displayName) })

                Text(config.bashRestrictionLevel.settingDescription)
                    .font(Typography.caption)
                    // "Off" removes the only review layer of Auto mode — surface that
                    // in warning color so disabling the judge is a visible act.
                    .foregroundStyle(config.bashRestrictionLevel == .off ? Colors.warning : Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Applies to Auto verdicts and the on-demand “Ask AI” advice while you approve a command.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                SettingsPillButton(title: "View judge prompt", icon: "doc.text.magnifyingglass") {
                    showJudgePreview = true
                }

                Divider().background(Colors.borderSubtle)

                // — Sandbox confinement: whether to ENFORCE the access rules at runtime —
                SettingsToggleRow(
                    title: "Confine commands in a sandbox",
                    icon: "shield",
                    isOn: $config.bashSandboxEnabled)

                Text(config.bashSandboxEnabled
                    ? "Wraps each command in a macOS Seatbelt profile that enforces the folder access rules below. Reads, process spawning, and network stay available."
                    : "Commands run without Seatbelt confinement — the folder access rules below aren't enforced at runtime, but the judge still applies them.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SettingsLayout.toggleIconSize + Spacing.m)

                Divider().background(Colors.borderSubtle)

                // — Folder access: the shared read/write policy. Independent of the
                //   sandbox toggle — the sandbox ENFORCES it when on, and the judge
                //   WEIGHS every command against it either way — so it's its own peer
                //   section with its own header, not a child of the toggle above.
                SettingsItemHeader(
                    icon: "folder",
                    title: "Folder access",
                    subtitle: "Shared by the sandbox and the judge")

                BashAccessRulesTable(permissions: $config.bashSandboxPermissions)

                Text("Credential writes are always blocked; turning a read off can stop most commands — the shell needs broad reads.")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // — Advanced (judge model override + unsandboxed fallback) —
                SettingsDisclosureRow(title: "Advanced", icon: "gearshape.2", isExpanded: $showSandboxAdvanced) {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        SettingsToggleRow(
                            title: "Allow unsandboxed fallback",
                            icon: "exclamationmark.shield",
                            isOn: $config.bashAllowUnsandboxedFallback)

                        Text("If the sandbox wrapper fails to launch, run the command without confinement instead of denying it. Off by default — a sandbox failure should fail safe.")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, SettingsLayout.toggleIconSize + Spacing.m)

                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Judge model override")
                                .font(Typography.caption.weight(.medium))
                                .foregroundStyle(Colors.textSecondary)
                            Text("Use a different model only for the command judge. Empty fields fall back to the global LLM configuration.")
                                .font(Typography.caption)
                                .foregroundStyle(Colors.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            LLMOverrideEditor(
                                config: config,
                                keyPath: \.bashJudgeLLMOverride,
                                onTokenSaveError: { store.lastErrorMessage = describe($0) },
                                onTokenLoadError: { store.lastErrorMessage = describe($0) })
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rules

    private var rulesCard: some View {
        @Bindable var config = config
        return SettingsCard(header: "Rules", systemImage: "list.bullet.rectangle") {
            SettingsDisclosureRow(title: "Custom command rules", icon: "slider.horizontal.3", isExpanded: $showCustomRules) {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("Each rule is a command pattern and what to do with it. A bare word matches a command's program (`rm` matches `rm -rf x`, not `rmdir`); add `*` for a prefix glob (`git push*`); include a space for a literal phrase (`npm run build`). Precedence: **deny → ask → allow**.")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    BashRulesTable(
                        denyRules: $config.bashDenyRules,
                        askRules: $config.bashAskRules,
                        allowRules: $config.bashAllowRules)
                }
                .padding(.top, Spacing.xs)
            }
        }
    }

}

// MARK: - Preview

#Preview("Bash Settings") {
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var catalog = PreviewStore.catalog()
    @Previewable @State var previewStore = PreviewStore.make()
    BashSettingsView()
        .environment(config)
        .environment(catalog)
        .environment(previewStore)
        .frame(width: 560, height: 800)
}
