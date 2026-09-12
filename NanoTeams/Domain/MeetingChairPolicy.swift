import Foundation

// MARK: - Meeting chair policy

/// Who holds the gavel — the ONE seat rule, in a form the editor can ask about a team it is
/// editing and the runtime can ask about a vote it is running.
///
/// It lived inside `LLMExecutionService.effectiveCoordinator` until 2026-09-13, which made it
/// unreachable from the Team editor: the tool badge and the wire preview both read
/// `Team.meetingCoordinatorID` directly and so both claimed, unconditionally, that the
/// coordinator closes every meeting. Since 1.9.18 that is false for a `request_changes` VOTE
/// whose coordinator is the requester or the target — a stand-in chairs — and a team with
/// nobody left holds no vote at all (DEBTS D-B12).
///
/// The policy takes a DISQUALIFICATION SET rather than `TeamMeetingService.InitiatorSeat`:
/// the seat is a `Services/LLM` type and the set is the thing the rule actually reads, so the
/// rule can live in `Domain/` (Foundation only) and the service keeps its seat-shaped
/// signature as a thin wrapper.
///
/// It answers in `TeamRoleDefinition`, never `Role`. `Role.fromDefinition` collapses every
/// definition sharing a `systemRoleID` or a display name into one case, and keeping that
/// collapse OUT of the rule is what `effectiveCoordinator`'s own doc comment earned in a
/// paragraph. The single collapse stays at the service boundary. (Everything below the chair
/// is still `Role`-keyed — DEBTS D-B13; this keeps the chair exact and changes nothing else.)
nonisolated enum MeetingChairPolicy {

    enum Outcome: Equatable, Sendable {
        case chair(TeamRoleDefinition)
        /// A vote whose team has no non-Supervisor role other than the requester and the
        /// target. Nobody is left to hold the gavel impartially, so the vote does not run.
        case noImpartialChair
    }

    /// - Parameter disqualified: empty for a discussion; `{requesterID, targetID}` for a
    ///   `request_changes` vote. Definition ids, never `Role` identities.
    static func chair(in team: Team, disqualified: Set<String>) -> Outcome {
        if let id = team.meetingCoordinatorID, !disqualified.contains(id),
           let coordinator = team.roles.first(where: { $0.id == id }) {
            return .chair(coordinator)
        }
        let pool = team.roles.filter { !$0.isSupervisor && !disqualified.contains($0.id) }
        guard let standIn = TeamSettings.defaultCoordinator(among: pool) else {
            return .noImpartialChair
        }
        return .chair(standIn)
    }

    // MARK: - What the editor can know without a vote in hand

    /// Every `(requester, target)` a `request_changes` call could legally form on this roster.
    ///
    /// Derived from the same two conditions `ChangeRequestService.validateChangeRequest`
    /// enforces — the requester holds the tool, and the target produces an artifact the
    /// requester requires — because that pair set is a static property of the team GRAPH, and
    /// the graph is what the editor is editing. Restating the rule would be a second spelling;
    /// this reads the same fields the validator reads.
    ///
    /// The `.done` status the validator also demands is a RUN fact and deliberately absent: it
    /// can only narrow the set, so a pair listed here is one the editor cannot rule out.
    static func legalVotePairs(in team: Team) -> [(requesterID: String, targetID: String)] {
        let requesters = team.roles.filter {
            !$0.isSupervisor && $0.toolIDs.contains(ToolNames.requestChanges)
        }
        var pairs: [(requesterID: String, targetID: String)] = []
        for requester in requesters {
            let needs = Set(requester.dependencies.requiredArtifacts)
            guard !needs.isEmpty else { continue }
            for target in team.roles
                where !target.isSupervisor && target.id != requester.id
                && !Set(target.dependencies.producesArtifacts).isDisjoint(with: needs) {
                pairs.append((requesterID: requester.id, targetID: target.id))
            }
        }
        return pairs
    }

    /// What a role can truthfully be told about the gavel, computed over every legal pair.
    struct Standing: Equatable, Sendable {
        /// It is the coordinator, and the team can meet at all.
        var chairsMeetings = false
        /// It holds the gavel in at least one legal vote — as coordinator, or as a stand-in.
        var canChairSomeVote = false
        /// It is the coordinator AND some legal pair displaces it.
        var displacedOnSomeVote = false
        /// Some legal pair on this roster leaves nobody impartial, so that vote cannot run.
        var teamHasUnchairableVotes = false
        /// Roles that take the chair when this one is displaced, by definition id.
        var standInIDs: Set<String> = []
    }

    /// One walk over `legalVotePairs`, indexed per role. The editor asks it once per badge
    /// model; the cost is `O(pairs × roles)` pure comparisons, noise beside `EffectiveToolset`.
    struct Survey: Equatable, Sendable {
        fileprivate var byRole: [String: Standing]
        fileprivate var fallback = Standing()
        func standing(of roleID: String) -> Standing { byRole[roleID] ?? fallback }
    }

    static func voteChairSurvey(in team: Team) -> Survey {
        var byRole: [String: Standing] = [:]
        // `canHoldMeetings` is read HERE, not restated by the badge: a team with meetings off
        // or with nobody to invite holds neither meeting nor vote, and every standing is empty.
        guard team.canHoldMeetings else { return Survey(byRole: byRole) }

        let coordinatorID = team.meetingCoordinatorID
        if let coordinatorID {
            byRole[coordinatorID, default: Standing()].chairsMeetings = true
        }
        var unchairable = false
        for pair in legalVotePairs(in: team) {
            switch chair(in: team, disqualified: [pair.requesterID, pair.targetID]) {
            case .chair(let seated):
                byRole[seated.id, default: Standing()].canChairSomeVote = true
                if let coordinatorID, seated.id != coordinatorID {
                    byRole[coordinatorID, default: Standing()].displacedOnSomeVote = true
                    byRole[coordinatorID, default: Standing()].standInIDs.insert(seated.id)
                }
            case .noImpartialChair:
                unchairable = true
            }
        }
        if unchairable {
            for key in byRole.keys { byRole[key]?.teamHasUnchairableVotes = true }
            for role in team.roles where !role.isSupervisor {
                byRole[role.id, default: Standing()].teamHasUnchairableVotes = true
            }
        }
        return Survey(byRole: byRole)
    }
}
