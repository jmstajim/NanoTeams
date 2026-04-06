import SwiftUI

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
        Section {
            Toggle("Supervisor can join meetings", isOn: $supervisorCanBeInvited)

            Picker("Meeting Coordinator", selection: Binding(
                get: { team.settings.meetingCoordinatorRoleID ?? nonSupervisorRoles.first?.id ?? "" },
                set: { newRoleID in
                    team.settings.meetingCoordinatorRoleID = newRoleID
                    onSave()
                }
            )) {
                ForEach(nonSupervisorRoles) { role in
                    Text(role.name).tag(role.id)
                }
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
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Button {
                    withAnimation(reduceMotion ? .none : Animations.quick) { invitableRolesExpanded.toggle() }
                } label: {
                    Text("Invitable Roles")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }

        } header: {
            Text("Collaboration")
        } footer: {
            Text("Configure how team members interact during meetings.")
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

    Form {
        TeamSettingsCollaborationSection(
            team: $team,
            supervisorCanBeInvited: $supervisorCanBeInvited,
            nonSupervisorRoles: nonSupervisorRoles,
            onSave: {}
        )
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
    .background(Colors.surfacePrimary)
}
