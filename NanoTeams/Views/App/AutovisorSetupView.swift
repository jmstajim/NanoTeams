import SwiftUI

/// First-time setup pane for the Autovisor in a work folder where it has never
/// been enabled. Shown by `MainLayoutView.autovisorDetail` when the navigation
/// destination is `.autovisor` but `autovisorTaskID == nil`.
///
/// Flow: the user edits the goal (pre-seeded with `AutovisorConstants.defaultGoal`
/// so the field is never blank — the default is a "explore & wait" directive that
/// keeps the manager safe until a real goal is set), then taps **Enable**:
///
/// 1. `updateAutovisorGoal` persists the edited goal.
/// 2. `setAutovisorEnabled(true)` flips the settings flag and `ensureAutovisorTask`
///    lazily creates the manager team-then-task — populating `autovisorTaskID`.
/// 3. The parent `autovisorDetail` re-evaluates: `autovisorTaskID` is now non-nil
///    → routes to the loader/`switchTask` branch → lands on the chat view.
///
/// No explicit navigation push needed — the body re-render IS the route.
struct AutovisorSetupView: View {
    @Environment(NTMSOrchestrator.self) private var store

    @State private var goalDraft: String = ""
    @State private var isEnabling = false
    @FocusState private var goalFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
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

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            MonoLabel(text: "Goal", marker: true)
            // Plain TextField in vertical-axis mode — this is a one-shot setup
            // surface, not a sustained editor (CLAUDE.md #32's bounded-height
            // critique doesn't apply: we let the field grow with content).
            TextField(
                "What should the Autovisor pursue in this folder?",
                text: $goalDraft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(Typography.termBase)
            .lineLimit(4...10)
            .focused($goalFocused)
            .padding(Spacing.s)
            .background(Colors.surfaceCard)
            .overlay {
                RoundedRectangle.squircle(CornerRadius.small)
                    .strokeBorder(
                        goalFocused ? Colors.accent : Colors.borderSubtle,
                        lineWidth: 1
                    )
            }

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
            .disabled(isEnabling)
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
        goalFocused = true
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
        .frame(width: 800, height: 600)
}
