import SwiftUI

/// What the Autovisor's start page draws: who drives, what that means, the goal and Enable.
/// Every fact comes in as `AutovisorSetupPresentation`, every action goes out through
/// `Actions`; the goal composer is the one part that reads the store itself (its attachments
/// and clips persist to the folder's goal store).
///
/// The driver sits above the goal because it decides what the goal is for: the built-in
/// manager's system prompt, or what an external agent reads from the folder's status.
struct AutovisorSetupContent: View {
    let presentation: AutovisorSetupPresentation
    let actions: Actions

    struct Actions {
        let selectDriver: @MainActor (AutovisorDriver) -> Void
        let openExternalAgents: @MainActor () -> Void
        /// Persists the goal, then turns the Autovisor on.
        let enable: @MainActor (String) async -> Void

        static let inert = Actions(selectDriver: { _ in }, openExternalAgents: {}, enable: { _ in })
    }

    @State private var goalDraft: String = ""
    @State private var isEnabling = false
    /// Mirrored from `AutovisorGoalComposer`'s improve stream — blocks Enable so a
    /// half-improved goal can't be persisted + activate the manager.
    @State private var isImprovingGoal = false
    /// Goal-preset disclosure — collapsed by default, same as Settings.
    @State private var showPresets = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                driverSection
                presetSection
                goalSection
                enableButton
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xl)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NTMSBackground())
        .navigationTitle("")
        .onAppear {
            guard goalDraft.isEmpty else { return }
            goalDraft = AutovisorSetupPresentation.initialGoalDraft(persisted: presentation.persistedGoal)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            // Match the sidebar's leading glyph so the destination identity carries
            // across pane and nav row — same icon, same accent.
            HStack(spacing: Spacing.s) {
                Image(systemName: AutovisorConstants.symbolName)
                    .font(Typography.term2xl)
                    .foregroundStyle(Colors.accent)
                Text("autovisor")
                    .font(Typography.termXl)
                    .foregroundStyle(Colors.textPrimary)
            }
            // Says what both drivers do; the driver's caption says what differs.
            Text("An automated Supervisor that watches this folder — creates and runs tasks, answers their questions and reviews the results.")
                .font(Typography.termBase)
                .foregroundStyle(Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var driverSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            MonoLabel(text: "Driver", marker: true)

            AutovisorDriverPicker(
                selection: presentation.driver,
                isDisabled: isEnabling || isImprovingGoal,
                onSelect: actions.selectDriver
            )

            Text(presentation.driverCaption)
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let line = presentation.externalAgents {
                externalAgentsRow(line)
            }
        }
    }

    /// Whether an agent can connect yet, and the way to Settings → External Agents, where agents
    /// are added and their tokens issued.
    private func externalAgentsRow(_ line: AutovisorSetupPresentation.ExternalAgentsLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            StatusGlyph(
                glyph: TerminalGlyph.bullet,
                color: line.isReady ? Colors.success : Colors.warning,
                font: Typography.term2xs)
            Text(line.text)
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            // Caption-sized, as on the agent's pane: a way out of the line, not a third driver
            // button — at the picker's size it squeezed the line onto two.
            Button(action: actions.openExternalAgents) {
                Text("External Agents…")
                    .font(Typography.caption)
            }
            .buttonStyle(.terminalSecondary)
        }
        .padding(.top, Spacing.xxs)
    }

    private var presetSection: some View {
        // Same collapsed control as Settings → Autovisor's goal card — the
        // grid stays out of the way until asked for.
        SettingsDisclosureRow(
            title: "Start from a preset",
            icon: "sparkles",
            isExpanded: $showPresets
        ) {
            // The seeded draft is the defaultGoal placeholder, so the common
            // first-run tap applies silently (goalIsUnset) — no dialog.
            AutovisorGoalPresetPicker(goalText: $goalDraft, isDisabled: isImprovingGoal)
                .padding(.top, Spacing.xs)
        }
    }

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            // The tip is a SIBLING of MonoLabel, never inside it — MonoLabel
            // combines its subtree for accessibility, which would drop the
            // button's action.
            HStack(spacing: Spacing.xs) {
                MonoLabel(text: "Goal", marker: true)
                AutovisorGoalLintTip(goal: goalDraft)
            }

            // Quick Capture-style composer (attach / skills / gear / improve /
            // dictate) minus the send button. Return inserts a newline, files
            // attach with cards, and `isImprovingGoal` still gates Enable.
            AutovisorGoalComposer(
                text: $goalDraft,
                isImproving: $isImprovingGoal,
                autofocus: true
            )

            Text(presentation.goalCaption)
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var enableButton: some View {
        HStack(spacing: Spacing.s) {
            Button(action: enable) {
                HStack(spacing: Spacing.xs) {
                    if isEnabling {
                        NTMSLoader(
                            font: Typography.subheadlineMedium,
                            color: Colors.textOnAccent
                        )
                    } else {
                        Image(systemName: "power")
                            .font(Typography.subheadlineMedium)
                    }
                    Text(isEnabling ? "Enabling…" : "Enable Autovisor")
                        .font(Typography.subheadlineMedium)
                }
                .foregroundStyle(Colors.textOnAccent)
                .padding(.horizontal, Spacing.standard)
                .padding(.vertical, Spacing.s)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small).fill(Colors.accent)
                )
            }
            .buttonStyle(.plain)
            .disabled(isEnabling || isImprovingGoal)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Enable Autovisor (⌘↩)")

            Spacer()
        }
    }

    // MARK: - Actions

    private func enable() {
        isEnabling = true
        Task {
            await actions.enable(goalDraft)
            isEnabling = false
        }
    }
}
