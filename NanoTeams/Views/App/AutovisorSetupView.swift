import SwiftUI

/// The Autovisor's start page — goal + **Enable**. Shown by
/// `MainLayoutView.autovisorDetail` whenever `autovisorShowsSetupPane` is true,
/// which covers BOTH entry points:
///
/// • **First run** — the manager was never created (`autovisorTaskID == nil`).
/// • **Re-enable** — it exists but is switched off. Disabling keeps the task, so
///   this pane replaces the chat for the whole off period; the conversation is
///   untouched and comes back on the next enable.
///
/// Flow: the user edits the goal (`seedGoalDraft` pre-fills the persisted one, or
/// `AutovisorConstants.defaultGoal` so the field is never blank — the default is an
/// "explore & wait" directive that keeps the manager safe until a real goal is set),
/// then taps **Enable**:
///
/// 1. `updateAutovisorGoal` persists the edited goal.
/// 2. `setAutovisorEnabled(true)` flips the settings flag and `ensureAutovisorTask`
///    creates the manager team-then-task on first run, or re-arms the review
///    recurrence for an existing one.
/// 3. The parent `autovisorDetail` re-evaluates: `autovisorShowsSetupPane` is now
///    false → routes to the loader/`switchTask` branch → lands on the chat view.
///
/// No explicit navigation push needed — the body re-render IS the route.
struct AutovisorSetupView: View {
    @Environment(NTMSOrchestrator.self) private var store

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
        .onAppear { seedGoalDraft() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            // Match the sidebar's leading glyph so the destination identity carries
            // across pane and nav row — same icon, same accent.
            HStack(spacing: Spacing.s) {
                Image(systemName: "bolt.badge.automatic")
                    .font(Typography.term2xl)
                    .foregroundStyle(Colors.accent)
                Text("autovisor")
                    .font(Typography.termXl)
                    .foregroundStyle(Colors.textPrimary)
            }
            Text("An automated Supervisor that watches this folder — creates and runs tasks, answers questions, and maintains its own memory between sessions.")
                .font(Typography.termBase)
                .foregroundStyle(Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

            Text("Injected into the manager's system prompt. You can edit this any time from the chat or Settings → Autovisor.")
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
            .help("Enable Autovisor and open its chat (⌘↩)")

            Spacer()
        }
    }

    // MARK: - Actions

    /// Seeds the draft from persisted settings if present, otherwise from the
    /// default goal so the field is never blank. The default is a safe "explore
    /// and wait" directive — letting the user enable without editing yields
    /// well-defined behavior, not an inert manager.
    private func seedGoalDraft() {
        guard goalDraft.isEmpty else { return }
        let persisted = store.workFolder?.settings.autovisorGoal ?? ""
        goalDraft = persisted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AutovisorConstants.defaultGoal
            : persisted
    }

    /// Persist the edited goal, then flip the enable flag. Ordering matters:
    /// `setAutovisorEnabled(true)` → `ensureAutovisorTask` reads the persisted
    /// goal when seeding the new manager's brief, so writing the goal FIRST
    /// guarantees the brief and the goal start in lock-step instead of the
    /// brief carrying the prior default until the next `updateAutovisorGoal`.
    private func enable() {
        isEnabling = true
        Task {
            await store.updateAutovisorGoal(goalDraft)
            await store.setAutovisorEnabled(true)
            isEnabling = false
        }
    }
}

// MARK: - Previews

#Preview("Autovisor Setup — Fresh") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    AutovisorSetupView()
        .environment(store)
        .environment(store.engineState)
        .environment(store.configuration)
        .environment(store.streamingPreviewManager)
        .environment(DictationService())
        .frame(width: 800, height: 600)
}
