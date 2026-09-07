import Foundation

extension LLMExecutionService {

    /// The team's meeting coordinator as a runtime `Role`, resolved through
    /// `Team.meetingCoordinatorID` — the one rule the picker, the tool badge and
    /// validation also read, so the runtime can never name a different role than the
    /// UI shows. `nil` only when there is no team or the team has no non-Supervisor
    /// role; there is no "Auto" mode.
    func resolveCoordinatorRole(team: Team?) -> Role? {
        guard let def = team?.meetingCoordinator else { return nil }
        if let systemRoleID = def.systemRoleID,
           let builtIn = Role.builtInRole(for: systemRoleID) {
            return builtIn
        }
        return .custom(id: def.id)
    }

    /// The coordinator of a meeting started by `initiator`: the team's coordinator.
    /// The initiator is the answer only when there is no team to resolve against or
    /// the team has no non-Supervisor role — a fixture shape, never a bundled team.
    /// Non-optional so the meeting runtime never branches on the coordinator's
    /// existence.
    ///
    /// Shared by `LLMExecutionService+TeamMeeting` (sets `MeetingContext`, joins the
    /// coordinator to the meeting, attributes the fallback conclusion) and
    /// `LLMExecutionService+ToolResultDispatching` (meeting-result attribution in
    /// `step.llmConversation`).
    func effectiveCoordinator(team: Team?, initiator: Role) -> Role {
        resolveCoordinatorRole(team: team) ?? initiator
    }

    /// Surfaces a one-shot `lastInfoMessage` when the team's STORED coordinator id no
    /// longer names a live role — the Supervisor picked it, and the default rule has
    /// quietly put another role in the chair. `bootstrapIfNeeded` heals the stored
    /// value on open, so this fires for an edit made since (a role deleted outside the
    /// editor) and names the role now coordinating. A stored `nil` is not an orphan:
    /// nobody's pick was dropped, the default rule simply applies (and the next write
    /// records it), so it is silent.
    ///
    /// Throttled per team via `orphanCoordinatorReportedTeams` — fires once per
    /// orphan, then **re-arms** when the stored id resolves again, so a later orphan
    /// (a different role deleted) fires a fresh notification.
    func reportOrphanCoordinatorIfNeeded(team: Team?) {
        guard let team else { return }
        guard team.settings.meetingCoordinatorRoleID != nil,
              team.meetingCoordinatorNeedsHealing,
              let healed = team.meetingCoordinator else {
            orphanCoordinatorReportedTeams.remove(team.id)
            return
        }
        guard !orphanCoordinatorReportedTeams.contains(team.id) else { return }
        orphanCoordinatorReportedTeams.insert(team.id)
        delegate?.setLastInfoMessageForUI(
            "Meeting coordinator role no longer exists in '\(team.name)' — \(healed.name) now coordinates meetings. Update Team Settings → Collaboration to pick another role."
        )
    }
}
