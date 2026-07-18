import SwiftUI

/// Grid of curated Autovisor goal presets (`AutovisorGoalPresets.all`), shared
/// by the first-time Setup pane and Settings → Autovisor. Tapping a card fills
/// the bound goal text — persistence stays with the host (Setup persists on
/// Enable; Settings keeps its debounced autosave), exactly like typing.
///
/// Selection highlight is DERIVED, never stored: the card whose `goalText`
/// exactly equals the (trimmed) current goal is highlighted, and any edit to
/// the text drops the highlight. Replacing a hand-written goal asks for
/// confirmation first (`AutovisorGoalPresets.applyAction`); an unset goal
/// (empty / the seeded placeholder) or another preset's untouched text is
/// replaced silently.
struct AutovisorGoalPresetPicker: View {
    @Binding var goalText: String
    /// Hosts pass `isImprovingGoal` so a preset tap can never race the improve
    /// stream's draft mutations.
    var isDisabled: Bool = false

    @State private var pendingPreset: AutovisorGoalPresets.Preset?

    var body: some View {
        // Hoisted: `matching` compares against every multi-KB goal text — once
        // per body eval, not once per card.
        let selectedID = AutovisorGoalPresets.matching(goalText)?.id

        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: Spacing.m),
            GridItem(.flexible(), spacing: Spacing.m)
        ], spacing: Spacing.m) {
            ForEach(AutovisorGoalPresets.all) { preset in
                TemplateCard(
                    name: preset.name,
                    icon: preset.icon,
                    description: preset.description,
                    isSelected: selectedID == preset.id
                ) {
                    handleTap(preset)
                }
            }
        }
        .disabled(isDisabled)
        .confirmationDialog(
            "Replace the current goal?",
            isPresented: isConfirmingReplace,
            titleVisibility: .visible,
            presenting: pendingPreset
        ) { preset in
            Button("Replace Goal", role: .destructive) {
                goalText = preset.goalText
            }
            Button("Cancel", role: .cancel) {}
        } message: { preset in
            Text("Your current goal text will be replaced with the \(preset.name) preset.")
        }
    }

    private var isConfirmingReplace: Binding<Bool> {
        Binding(
            get: { pendingPreset != nil },
            set: { if !$0 { pendingPreset = nil } }
        )
    }

    private func handleTap(_ preset: AutovisorGoalPresets.Preset) {
        switch AutovisorGoalPresets.applyAction(current: goalText, tapped: preset) {
        case .apply:
            goalText = preset.goalText
        case .confirmReplace:
            pendingPreset = preset
        case .noop:
            break
        }
    }
}

#Preview("Goal Preset Picker") {
    @Previewable @State var goal = AutovisorGoalPresets.all[0].goalText
    AutovisorGoalPresetPicker(goalText: $goal)
        .padding(Spacing.xl)
        .frame(width: 520)
        .background(Colors.surfacePrimary)
}
