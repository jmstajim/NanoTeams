import SwiftUI

// MARK: - Computer Use Settings View

/// Settings for the computer-use tools (screenshot + mouse/keyboard control of the desktop).
/// Manual approval by default; the mode decides who approves each action. Advanced knobs
/// (allowlist, blocked patterns) sit behind a disclosure so the default surface stays short.
struct ComputerUseSettingsView: View {
    @Environment(StoreConfiguration.self) var config

    @State private var showAdvanced = false

    private var mode: ComputerUseMode { config.computerUseMode }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                introCard
                executionCard
                if config.isComputerUseEnabled {
                    safetyCard
                    advancedCard
                }
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
    }

    // MARK: - Intro

    private var introCard: some View {
        SettingsCard(header: "Screen control", systemImage: "cursorarrow.rays") {
            Text("These tools let a role take a screenshot and then click, type, and scroll to operate other apps. The **Assistant, Coding Assistant, and Autovisor** roles have them by default; grant other roles in the Team Editor (Tools → Computer Use). By default every action asks for **your approval**. The app detects whether your main model can see screenshots — when it can't, the **Vision model** (Settings → Vision) describes them instead. macOS will ask for Screen Recording and Accessibility permission the first time.")
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Spacing.xs)
        }
    }

    // MARK: - Execution

    private var executionCard: some View {
        @Bindable var config = config
        return SettingsCard(header: "Approval", systemImage: "hand.raised") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                TerminalSegmentedPicker(
                    selection: $config.computerUseMode,
                    options: ComputerUseMode.allCases.map { ($0, $0.displayName) })

                Text(config.computerUseMode.settingDescription)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Safety

    private var safetyCard: some View {
        @Bindable var config = config
        return SettingsCard(header: "Safety", systemImage: "shield.lefthalf.filled") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if mode == .auto {
                    TerminalSegmentedPicker(
                        selection: $config.computerUseRestrictionLevel,
                        options: ComputerUseRestrictionLevel.allCases.map { ($0, $0.displayName) })
                    // "Off" removes the only review layer of Auto mode — surface
                    // that in warning color so disabling the judge is a visible act.
                    Text(config.computerUseRestrictionLevel.settingDescription)
                        .font(Typography.caption)
                        .foregroundStyle(
                            config.computerUseRestrictionLevel == .off
                                ? Colors.warning : Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider().background(Colors.borderSubtle)
                }

                SettingsToggleRow(
                    title: "Raise the target window before acting",
                    icon: "macwindow.on.rectangle",
                    isOn: $config.computerUseRaiseTargetWindowBeforeClick)

                SettingsToggleRow(
                    title: "Only ask before the first screenshot each run",
                    icon: "camera.viewfinder",
                    isOn: $config.computerUseGateFirstCaptureOnly)
            }
        }
    }

    // MARK: - Advanced

    private var advancedCard: some View {
        SettingsCard(header: "Restrictions", systemImage: "slider.horizontal.3") {
            SettingsDisclosureRow(title: "Advanced restrictions", icon: "hand.raised", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    listField(
                        title: "Allowed apps",
                        hint: "App names or bundle ids the tools may target. Empty = any app.",
                        keyPath: \.computerUseTargetAppAllowlist)
                    listField(
                        title: "Blocked typed text",
                        hint: "Deny typing text matching any of these (regex or substring).",
                        keyPath: \.computerUseBlockedTypingPatterns)
                    listField(
                        title: "Blocked key combos",
                        hint: "Deny these key combos, e.g. cmd+q (regex or substring).",
                        keyPath: \.computerUseBlockedKeyCombos)
                }
                .padding(.top, Spacing.s)
            }
        }
    }

    private func listField(
        title: String, hint: String,
        keyPath: ReferenceWritableKeyPath<StoreConfiguration, [String]>
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
            TextField("", text: csvBinding(keyPath), prompt: Text("comma-separated"))
                .textFieldStyle(.plain)
                .terminalField()
            Text(hint)
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
        }
    }

    private func csvBinding(_ keyPath: ReferenceWritableKeyPath<StoreConfiguration, [String]>) -> Binding<String> {
        Binding(
            get: { config[keyPath: keyPath].joined(separator: ", ") },
            set: {
                config[keyPath: keyPath] = $0
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            })
    }
}
