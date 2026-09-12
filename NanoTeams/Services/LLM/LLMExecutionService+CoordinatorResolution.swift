import Foundation

extension LLMExecutionService {

    /// Who chairs a meeting — and, for a vote, whether anybody CAN.
    enum MeetingChair: Equatable {
        case chair(Role)
        /// A `request_changes` vote whose team has no non-Supervisor role other than the
        /// requester and the target. Nobody is left to hold the gavel impartially, so the
        /// vote does not run.
        case noImpartialChair
    }

    /// The team's meeting coordinator as a runtime `Role`, resolved through
    /// `Team.meetingCoordinatorID` — the one rule the picker, the tool badge and
    /// validation also read, so the runtime can never name a different role than the
    /// UI shows. `nil` only when there is no team or the team has no non-Supervisor
    /// role; there is no "Auto" mode.
    ///
    /// Built with `Role.fromDefinition`, the SAME constructor
    /// `MeetingParticipantResolver.filterParticipants` uses. Until 2026-09-11 this said
    /// `.custom(id: def.id)` while participants said `.custom(id: definition.name)`. For a
    /// built-in role the two agree; for a CUSTOM one they do not, so a coordinator already
    /// seated among the participants failed the `contains` check in `handleTeamMeeting`,
    /// was appended a second time, spoke twice per round (once without `conclude_meeting`,
    /// once with it) and counted as two voters — on exactly the user-authored teams the
    /// runtime rule below exists to protect.
    func resolveCoordinatorRole(team: Team?) -> Role? {
        guard let def = team?.meetingCoordinator else { return nil }
        return Role.fromDefinition(def)
    }

    /// The chair of a meeting started by `initiator`.
    ///
    /// `seat` and its target are REQUIRED, with no defaults, because the rule differs by
    /// seat and a default would silently hand a vote the discussion rule:
    ///
    /// - `.speaks` (`request_team_meeting`) — the team's coordinator. The initiator stands
    ///   in only when there is no team to resolve against, a fixture shape.
    /// - `.presentsOnly` (a `request_changes` vote) — the team's coordinator ONLY if it is
    ///   neither the requester nor the target; otherwise a stand-in chosen by
    ///   `TeamSettings.defaultCoordinatorID(among:)` over the pool with both removed.
    ///
    /// The substitution is not hypothetical. `handleChangeRequest` seats the requester
    /// `.presentsOnly` — not a participant, never speaks — and then `handleTeamMeeting`
    /// appends the coordinator UNCONDITIONALLY, without consulting the seat. A requester
    /// that was also the coordinator therefore re-entered through the coordinator's door,
    /// and not as a rank-and-file voter: it opened the meeting, closed every round,
    /// concluded, and was the only holder of `conclude_meeting`. That shipped in FAANG and
    /// Engineering, whose coordinator is the TPM and whose TPM holds `request_changes`;
    /// both run `.autonomous`, so no human was in the loop to notice. The target is the
    /// same defect one seat over: `validateChangeRequest` accepts any `.done` non-Supervisor
    /// role, and the target IS a participant in its own vote.
    ///
    /// The fix lives here rather than in the templates because the coordinator is a picker
    /// in Team Settings and `request_changes` is a checkbox in the role editor — a template
    /// change would protect three bundled teams and no user-authored one.
    ///
    /// `requesterRoleID` is the initiator's DEFINITION id — the step id at both call sites
    /// (`StepExecution.id` is the role-definition id) — and is what disqualifies the
    /// requester, not `initiator.baseID`: `Role.fromDefinition` collapses every definition
    /// sharing a `systemRoleID` (an editor duplicate) or a display name into one `Role`, and
    /// `findRole(byIdentifier:)` answers with the FIRST such twin. Round-tripping the
    /// requester through that pair disqualified whichever twin was stored first. The
    /// coordinator is likewise read as `Team.meetingCoordinatorID`, which already IS a
    /// definition id — round-tripping ITS `Role` through the same pair disqualified an
    /// uninvolved coordinator whenever its twin was the requester, and handed the chair to
    /// a stand-in for no reason. (The meeting itself is still `Role`-keyed, so two twins
    /// remain one participant to it — DEBTS D-B13; this keeps the chair rule exact.)
    func effectiveCoordinator(
        team: Team?,
        initiator: Role,
        requesterRoleID: String,
        seat: TeamMeetingService.InitiatorSeat,
        targetRoleID: String?
    ) -> MeetingChair {
        guard let team else { return .chair(resolveCoordinatorRole(team: team) ?? initiator) }

        // Identity is compared through definition ids, never by `Role` equality: a custom
        // role reaches here as `.custom(id: name)` from one constructor and could be
        // addressed by uuid, systemRoleID or name from the other. The target may still be
        // spelled any of those ways by the tool call, so it takes the `findRole` trip.
        let canonical: (String?) -> String? = { identifier in
            identifier.flatMap { team.findRole(byIdentifier: $0)?.id }
        }
        // The seat, translated into the one thing the rule reads. `.speaks` disqualifies
        // nobody — the coordinator chairs a discussion unconditionally.
        let disqualified: Set<String>
        if case .presentsOnly = seat {
            disqualified = Set([requesterRoleID, canonical(targetRoleID)].compactMap { $0 })
        } else {
            disqualified = []
        }

        // The rule itself lives in `Domain/MeetingChairPolicy` so the Team editor can ask it
        // about a team it is editing; this method is the seat-shaped wrapper, and the single
        // `Role.fromDefinition` collapse happens HERE rather than inside the rule (DEBTS
        // D-B12; the twin-collapse reasoning is the paragraph above).
        switch MeetingChairPolicy.chair(in: team, disqualified: disqualified) {
        case .chair(let definition):
            return .chair(Role.fromDefinition(definition))
        case .noImpartialChair:
            // A fixture shape for a discussion — a team with no non-Supervisor role at all —
            // still seats the initiator, as it always has.
            return disqualified.isEmpty ? .chair(initiator) : .noImpartialChair
        }
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
