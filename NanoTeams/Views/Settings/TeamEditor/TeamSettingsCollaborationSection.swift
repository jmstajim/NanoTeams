import SwiftUI

/// Pure-logic backing for the Meeting Coordinator Picker — orphan tolerance
/// + set-side sanitization. Kept on a nonisolated namespace so it can be
/// unit-tested without a SwiftUI host. Get-binding delegates to
/// `DesignatedCoordinatorResolver` so the picker shares the orphan-self-heal
/// contract with the runtime schema-build path (single source of truth).
enum MeetingCoordinatorPickerLogic {

    /// Normalizes the stored `meetingCoordinatorRoleID` for the picker's
    /// `get` binding: returns `nil` (= visually "Auto") when stored is nil,
    /// empty, or references a role that no longer exists in `availableIDs`.
    static func normalizedSelection(
        stored: String?,
        availableIDs: [String]
    ) -> String? {
        DesignatedCoordinatorResolver.normalize(storedID: stored, availableIDs: availableIDs)
    }

    /// Sanitizes the picker's `set` action: collapses empty strings to `nil`
    /// so the model never persists `""` as a coordinator id.
    static func sanitizedSelection(_ inbound: String?) -> String? {
        guard let id = inbound, !id.isEmpty else { return nil }
        return id
    }
}

/// Collaboration settings section extracted from TeamSettingsDetailView (SRP).
/// Configures Supervisor meeting access, coordinator role, and invitable roles.
struct TeamSettingsCollaborationSection: View {
    @Binding var team: Team
    @Binding var supervisorCanBeInvited: Bool
    let nonSupervisorRoles: [TeamRoleDefinition]
    let onSave: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var invitableRolesExpanded = false

    var body: some View {
        SettingsCard(
            header: "Collaboration",
            systemImage: "person.2",
            footer: "Configure how team members interact during meetings."
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
            Toggle("Supervisor can join meetings", isOn: $supervisorCanBeInvited)
                .toggleStyle(.terminal)

            // Auto (= `meetingCoordinatorRoleID == nil`) means: no designated
            // coordinator — the initiator of each meeting becomes its
            // effective coordinator. See `TeamSettings`.
            //
            // `normalizedSelection` collapses orphan stored IDs (referenced
            // role removed) to nil so the picker shows "Auto" instead of a
            // blank selection, matching the runtime's silent self-heal in
            // `LLMExecutionService.resolveCoordinatorRole`.
            HStack {
                Text("Meeting Coordinator")
                Spacer()
                TerminalPicker(
                    selection: Binding<String?>(
                        get: {
                            MeetingCoordinatorPickerLogic.normalizedSelection(
                                stored: team.settings.meetingCoordinatorRoleID,
                                availableIDs: nonSupervisorRoles.map(\.id)
                            )
                        },
                        set: { newRoleID in
                            team.settings.meetingCoordinatorRoleID =
                                MeetingCoordinatorPickerLogic.sanitizedSelection(newRoleID)
                            onSave()
                        }
                    ),
                    options: [(value: String?.none, label: "Auto")]
                        + nonSupervisorRoles.map { (value: String?.some($0.id), label: $0.name) }
                )
            }

            DisclosureGroup(isExpanded: $invitableRolesExpanded) {
                VStack(alignment: .leading) {
                    ForEach(nonSupervisorRoles) { role in
                        Toggle(role.name, isOn: Binding(
                            get: { team.settings.invitableRoles.contains(role.id) },
                            set: { isOn in
                                if isOn {
                                    team.settings.invitableRoles.insert(role.id)
                                } else {
                                    team.settings.invitableRoles.remove(role.id)
                                }
                                onSave()
                            }
                        ))
                        .toggleStyle(.terminal)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Button {
                    withAnimation(reduceMotion ? .none : Animations.quick) { invitableRolesExpanded.toggle() }
                } label: {
                    Text("Invitable Roles")
                        .foregroundStyle(Colors.textPrimary)
                }
                .buttonStyle(.plain)
            }
            }
        }
    }
}

#Preview("Collaboration Settings") {
    @Previewable @State var team: Team = {
        var t = Team(name: "Preview Team")
        t.roles = [
            TeamRoleDefinition(id: "pm", name: "Product Manager", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies()),
            TeamRoleDefinition(id: "swe", name: "Software Engineer", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies()),
            TeamRoleDefinition(id: "cr", name: "Code Reviewer", prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies()),
        ]
        t.settings.invitableRoles = Set(["pm", "swe", "cr"])
        return t
    }()
    @Previewable @State var supervisorCanBeInvited = true

    let nonSupervisorRoles = team.roles

    ScrollView {
        VStack {
            TeamSettingsCollaborationSection(
                team: $team,
                supervisorCanBeInvited: $supervisorCanBeInvited,
                nonSupervisorRoles: nonSupervisorRoles,
                onSave: {}
            )
        }
        .padding(Spacing.xl)
    }
    .frame(width: 480)
    .background(Colors.surfacePrimary)
}
