import Foundation

/// Stateless validation and resolution of team meeting participants.
///
/// The Supervisor is the human. It is never a meeting participant and never an
/// `ask_teammate` target: an LLM turn "as the Supervisor" would be the model speaking for
/// the user, and the role has no prompt to speak from. Until 2026-09-07 a
/// `supervisorCanBeInvited` seat allowed exactly that on every single-role bundled team.
/// The rejection below and the omission from `availableTeammatesList` are unconditional.
enum MeetingParticipantResolver {

    // MARK: - Participant Filtering

    /// Filters and resolves requested participant IDs for a team meeting.
    /// Returns valid Role values and rejection reasons for invalid participants.
    static func filterParticipants(
        participantIDs: [String],
        initiatingRole: Role,
        team: Team?,
        teamSettings: TeamSettings
    ) -> (participants: [Role], rejectedReasons: [String]) {
        var participants: [Role] = []
        var rejectedReasons: [String] = []

        for participantID in participantIDs {
            // Resolve role — try built-in ID first, then team lookup by any identifier
            let role: Role
            if let builtIn = Role.builtInRole(for: participantID) {
                role = builtIn
            } else if let teamRole = team?.findRole(byIdentifier: participantID) {
                role = Role.fromDefinition(teamRole)
            } else {
                rejectedReasons.append("\(participantID) (unknown role)")
                continue
            }

            // The initiator is seated by `handleTeamMeeting` itself (`InitiatorSeat`), so
            // an invitation to oneself is redundant rather than wrong — the reason says so.
            if role.baseID == initiatingRole.baseID {
                rejectedReasons.append("\(role.displayName) (you — already a participant)")
                continue
            }

            // Resolve team membership using findRole (matches by id, systemRoleID, or name)
            if let team, team.findRole(byIdentifier: participantID) == nil {
                rejectedReasons.append("\(role.displayName) (not a team member)")
                continue
            }

            let resolvedTeamRoleID = team?.findRole(byIdentifier: participantID)?.id ?? participantID

            if role == .supervisor || team?.findRole(byIdentifier: participantID)?.isSupervisor == true {
                rejectedReasons.append("\(role.displayName) (the Supervisor — not a meeting participant)")
                continue
            }

            if !teamSettings.invitableRoles.isEmpty && !teamSettings.invitableRoles.contains(resolvedTeamRoleID) {
                rejectedReasons.append("\(role.displayName) (not in invitable roles)")
                continue
            }

            participants.append(role)
        }

        return (participants, rejectedReasons)
    }

    // MARK: - Available Teammates List

    /// Returns a comma-separated string of available teammate identifiers,
    /// excluding the specified role and respecting team settings.
    static func availableTeammatesList(
        team: Team?,
        teamSettings: TeamSettings,
        excludeRoleID: String
    ) -> String {
        if let team {
            // Filter team roles and return usable identifiers (systemRoleID for built-in, id for custom)
            let filtered = team.roles.filter { role in
                let roleID = role.id
                // Exclude the requesting role (by id or systemRoleID)
                if roleID == excludeRoleID || role.systemRoleID == excludeRoleID { return false }
                if role.isSupervisor { return false }
                if !teamSettings.invitableRoles.isEmpty && !teamSettings.invitableRoles.contains(roleID) { return false }
                return true
            }
            let descriptions = filtered.map { role in
                role.systemRoleID ?? role.id
            }.sorted()
            return descriptions.isEmpty ? "none" : descriptions.joined(separator: ", ")
        } else {
            let filteredIDs = Role.allBuiltInIDs.filter { roleID in
                if roleID == excludeRoleID { return false }
                if roleID == Role.builtInID(.supervisor) { return false }
                return true
            }
            return filteredIDs.isEmpty ? "none" : filteredIDs.sorted().joined(separator: ", ")
        }
    }
}
