import SwiftUI

/// Pure-logic backing for the Meeting Coordinator Picker. Kept on a nonisolated
/// namespace so it can be unit-tested without a SwiftUI host. The `get` side reads
/// `Team.meetingCoordinatorID` — the same rule the meeting runtime, the tool badge and
/// validation read, so the picker cannot show a different role than the one that will
/// actually coordinate. There is no "Auto" option: every team with a role has a
/// coordinator.
nonisolated enum MeetingCoordinatorPickerLogic {

    /// The picker's `get`: the team's resolved coordinator. `nil` only for a team with
    /// no non-Supervisor role — which has no options to pick from either.
    static func selection(for team: Team) -> String? {
        team.meetingCoordinatorID
    }

    /// The picker's `set`: an empty inbound value is a control glitch, never a user pick,
    /// and leaves the stored id as it was — `nil` would have meant Auto, which no longer
    /// exists.
    static func sanitizedSelection(_ inbound: String?, current: String?) -> String? {
        guard let id = inbound, !id.isEmpty else { return current }
        return id
    }
}

/// The Collaboration card's read of `Team.meetingAvailability`: what the footer says,
/// what the master switch shows and whether it can be flipped. Pure so the three answers
/// are testable without a SwiftUI host and cannot drift from the enum they read.
nonisolated enum MeetingsSwitchPresentation {
    static func footer(for availability: MeetingAvailability) -> String {
        switch availability {
        case .available:
            return "Configure how team members interact during meetings. The coordinator opens every meeting and ends it with the group's decision."
        case .switchedOff:
            return "Meetings are off: no role can start one, and request_changes votes are unavailable."
        case .noPartner:
            return "Meetings need a second role in this team. Until one is added no role can start a meeting, request_changes votes are unavailable, and ask_teammate has nobody to reach."
        }
    }

    /// What the master switch SHOWS — a meeting the team cannot hold reads as Off even
    /// while the stored flag is on, so the card never claims a meeting nobody can start.
    static func isOn(for availability: MeetingAvailability) -> Bool {
        availability == .available
    }

    /// Whether the master switch can be flipped: with nobody to invite the flag has nothing
    /// to govern — the way to enable meetings is a second role, added in the Roles tab.
    static func isSwitchEnabled(for availability: MeetingAvailability) -> Bool {
        availability != .noPartner
    }
}

/// Collaboration settings section extracted from TeamSettingsDetailView (SRP).
/// Configures the meetings switch, the coordinator role and the invitable roles. There is
/// no Supervisor seat: the Supervisor is the human and never a meeting participant.
struct TeamSettingsCollaborationSection: View {
    @Binding var team: Team
    let nonSupervisorRoles: [TeamRoleDefinition]
    let onSave: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var invitableRolesExpanded = false

    var body: some View {
        SettingsCard(
            header: "Collaboration",
            systemImage: "person.2",
            footer: MeetingsSwitchPresentation.footer(for: availability)
        ) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                // The master switch. Off withholds `request_team_meeting` and
                // `request_changes` from every role's step schema (see
                // `TeamSettings.meetingsEnabled`); the rows below stay visible but
                // inert so the configuration is still readable.
                Toggle("Team meetings", isOn: Binding(
                    get: { MeetingsSwitchPresentation.isOn(for: availability) },
                    set: { isOn in
                        team.settings.meetingsEnabled = isOn
                        onSave()
                    }
                ))
                .toggleStyle(.terminal)
                .disabled(!MeetingsSwitchPresentation.isSwitchEnabled(for: availability))

                // Every team with a role has a coordinator — there is no "Auto"
                // (see `TeamSettings.meetingCoordinatorRoleID`). The `get` reads the
                // resolved id, so a stored orphan shows the role that will actually
                // coordinate rather than a blank selection.
                HStack {
                    Text("Meeting Coordinator")
                    Spacer()
                    TerminalPicker(
                        selection: Binding<String?>(
                            get: { MeetingCoordinatorPickerLogic.selection(for: team) },
                            set: { newRoleID in
                                team.settings.meetingCoordinatorRoleID =
                                    MeetingCoordinatorPickerLogic.sanitizedSelection(
                                        newRoleID, current: team.settings.meetingCoordinatorRoleID)
                                onSave()
                            }
                        ),
                        options: nonSupervisorRoles.map { (value: String?.some($0.id), label: $0.name) }
                    )
                }
                .disabled(!meetingsEnabled)

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
                .disabled(!meetingsEnabled)
            }
        }
    }

    private var availability: MeetingAvailability { team.meetingAvailability }
    private var meetingsEnabled: Bool { availability == .available }
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

    let nonSupervisorRoles = team.roles

    ScrollView {
        VStack {
            TeamSettingsCollaborationSection(
                team: $team,
                nonSupervisorRoles: nonSupervisorRoles,
                onSave: {}
            )
        }
        .padding(Spacing.xl)
    }
    .frame(width: 480)
    .background(Colors.surfacePrimary)
}
