import SwiftUI

/// Limits settings section extracted from TeamSettingsDetailView (SRP).
/// Configures consultation, meeting, and change request limits.
struct TeamSettingsLimitsSection: View {
    @Binding var limits: TeamLimits

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var consultationExpanded = false
    @State private var changeRequestsExpanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $consultationExpanded) {
                limitsRow("Consultations per step", subtitle: "How many times a role can ask teammates",
                          value: $limits.maxConsultationsPerStep, range: 1...20)
                limitsRow("Same teammate asks", subtitle: "Maximum questions to one teammate per step",
                          value: $limits.maxSameTeammateAsks, range: 1...10)
                limitsRow("Meetings per run", subtitle: "Maximum team meetings in a single task run",
                          value: $limits.maxMeetingsPerRun, range: 1...20)
                limitsRow("Meeting turns", subtitle: "Maximum discussion turns per meeting",
                          value: $limits.maxMeetingTurns, range: 5...50)
                limitsRow("Meeting tool iterations", subtitle: "Tool calls per meeting turn",
                          value: $limits.maxMeetingToolIterationsPerTurn, range: 1...10)
            } label: {
                Button {
                    withAnimation(reduceMotion ? .none : Animations.quick) { consultationExpanded.toggle() }
                } label: {
                    Text("Consultation & Meetings")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }

            DisclosureGroup(isExpanded: $changeRequestsExpanded) {
                limitsRow("Change requests per run",
                          subtitle: limits.maxChangeRequestsPerRun == 0 ? "Disabled" : "Peer revision requests per task run",
                          value: $limits.maxChangeRequestsPerRun, range: 0...10,
                          zeroLabel: "Off")
                limitsRow("Amendments per step",
                          subtitle: limits.maxAmendmentsPerStep == 0 ? "Disabled" : "Maximum revisions a step can receive",
                          value: $limits.maxAmendmentsPerStep, range: 0...10,
                          zeroLabel: "Off")
            } label: {
                Button {
                    withAnimation(reduceMotion ? .none : Animations.quick) { changeRequestsExpanded.toggle() }
                } label: {
                    Text("Change Requests")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Limits")
        } footer: {
            Text("Limits prevent runaway collaboration costs. Adjust based on team complexity.")
        }
    }

    // MARK: - Helper

    @ViewBuilder
    private func limitsRow(_ title: String, subtitle: String, value: Binding<Int>, range: ClosedRange<Int>, zeroLabel: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(title)
                Spacer()
                HStack(spacing: Spacing.xs) {
                    if let zeroLabel, value.wrappedValue == 0 {
                        Text(zeroLabel).monospacedDigit()
                    } else {
                        Text("\(value.wrappedValue)").monospacedDigit()
                    }
                    Stepper("", value: value, in: range)
                        .labelsHidden()
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Team Limits") {
    @Previewable @State var limits = TeamLimits.default

    Form {
        TeamSettingsLimitsSection(limits: $limits)
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
    .background(Colors.surfacePrimary)
}
