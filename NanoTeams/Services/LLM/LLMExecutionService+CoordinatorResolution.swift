import Foundation

extension LLMExecutionService {

    /// Returns the *designated* meeting coordinator role from
    /// `team.settings.meetingCoordinatorRoleID`. Returns `nil` for Auto mode
    /// (no designated coordinator), for an orphaned ID that references a
    /// removed role (silent self-heal), or when the team is `nil`.
    ///
    /// This is the raw user choice. Use `effectiveCoordinator(team:initiator:)`
    /// to get the coordinator *of a specific meeting* — that one is never
    /// `nil` because Auto mode promotes the initiating role to coordinator of
    /// each meeting it starts.
    ///
    /// Normalization (orphan / nil / empty) is delegated to
    /// `DesignatedCoordinatorResolver.normalize` so the runtime ID-resolution
    /// uses the exact same orphan-tolerance rule the picker, predicate, and
    /// schema-build paths use. Single source of truth — no DRY drift.
    func resolveCoordinatorRole(team: Team?) -> Role? {
        guard let team,
              let id = DesignatedCoordinatorResolver.normalize(
                  storedID: team.settings.meetingCoordinatorRoleID,
                  // Filter out Supervisor — Supervisor can never be a meeting
                  // coordinator (Supervisor is the user, not an LLM). Stored
                  // Supervisor IDs (hand-edited JSON / data corruption) get
                  // rejected here and self-heal to Auto. Symmetric with the
                  // picker which only lists non-Supervisor roles.
                  availableIDs: team.roles.filter { !$0.isSupervisor }.map(\.id)
              ),
              let def = team.roles.first(where: { $0.id == id }) else { return nil }
        if let systemRoleID = def.systemRoleID,
           let builtIn = Role.builtInRole(for: systemRoleID) {
            return builtIn
        }
        return .custom(id: id)
    }

    /// Returns the **effective** coordinator for a meeting initiated by
    /// `initiator`: the team's designated coordinator if set, otherwise the
    /// initiator (Auto mode = initiator-as-coordinator of each meeting they
    /// start). Always non-optional so the meeting runtime never branches on
    /// the existence of a coordinator.
    ///
    /// Shared by `LLMExecutionService+TeamMeeting` (sets `MeetingContext`
    /// + auto-conclusion attribution) and `LLMExecutionService+ToolResultDispatching`
    /// (meeting-result attribution in `step.llmConversation`).
    func effectiveCoordinator(team: Team?, initiator: Role) -> Role {
        resolveCoordinatorRole(team: team) ?? initiator
    }

    /// Surfaces a one-shot `lastInfoMessage` when the team's stored designated
    /// coordinator references a role that no longer exists. The Supervisor
    /// explicitly chose this role; without this signal, runtime self-heal
    /// silently substitutes the meeting initiator (via `effectiveCoordinator`)
    /// and the picker shows "Auto" — leaving the user with no signal that
    /// their explicit pick was dropped.
    ///
    /// Throttled per team via `orphanCoordinatorReportedTeams` — fires once
    /// per orphan, then **re-arms** when the orphan is resolved (live coord
    /// designated, or designation cleared to Auto). A subsequent new orphan
    /// (a different role gets deleted) fires a fresh notification.
    func reportOrphanCoordinatorIfNeeded(team: Team?) {
        guard let team else { return }
        // Re-arm: orphan resolved (designation is now nil or points to a live
        // role) → clear the team's throttle entry so the next new orphan
        // re-fires the banner.
        let isOrphan = team.settings.meetingCoordinatorRoleID != nil
            && resolveCoordinatorRole(team: team) == nil
        if !isOrphan {
            orphanCoordinatorReportedTeams.remove(team.id)
            return
        }
        guard !orphanCoordinatorReportedTeams.contains(team.id) else { return }
        orphanCoordinatorReportedTeams.insert(team.id)
        delegate?.setLastInfoMessageForUI(
            "Meeting coordinator role no longer exists in '\(team.name)' — meetings are running in Auto mode (initiator becomes coordinator). Update Team Settings → Collaboration to pick another role."
        )
    }
}
