import Foundation

/// Stateless service for change request validation, voting, and context building.
enum ChangeRequestService {

    // MARK: - Vote Result

    enum VoteResult: Equatable {
        case approved
        case rejected
        /// Equal counts with at least one vote on each side — a genuine deadlock.
        case tied
        /// Nobody voted. NOT a tie: see `tallyVotes`.
        case noVotes
    }

    // MARK: - Vote Tallying

    /// Tallies APPROVE/REJECT votes from meeting messages.
    ///
    /// **0-0 is `.noVotes`, not `.tied`.** A 1-1 deadlock is a real disagreement, and V1's
    /// documented policy of auto-approving it is a defensible coin flip: both answers were
    /// argued for. Nobody voting is not a disagreement — it is the absence of a decision, and
    /// it is routinely reachable with a meeting that ran perfectly well: participants answer in
    /// prose ("Let me think about it..."), the `VOTE:` token never appears, and the tally is 0-0.
    /// Folding that into `.tied` made "the team never voted" mean "the team said yes", which
    /// resets the target role and cascades a revision through every started downstream role
    /// (`propagateAmendmentDownstream`) — destroying work on the strength of no vote at all.
    ///
    /// A sibling of this defect was already fixed once at the caller (`meetingReply.succeeded`,
    /// see `ChangeRequestVotingFailureTests`), which closed the case where the meeting never
    /// ran. This closes the case where it ran and decided nothing.
    static func tallyVotes(meetingMessages: [TeamMessage]) -> VoteResult {
        var approves = 0
        var rejects = 0

        for msg in meetingMessages {
            let upper = msg.content.uppercased()
            if upper.contains("VOTE: APPROVE") || upper.contains("VOTE:APPROVE") {
                approves += 1
            } else if upper.contains("VOTE: REJECT") || upper.contains("VOTE:REJECT") {
                rejects += 1
            }
        }

        if approves > rejects { return .approved }
        if rejects > approves { return .rejected }
        return approves == 0 ? .noVotes : .tied
    }

    // MARK: - Target Step Resolution

    /// The ONE rule for "which step in this run belongs to the target role".
    ///
    /// Tolerant of a step keyed by `systemRoleID`: `StepExecution.id` is normally the
    /// role-definition id, but the second disjunct exists because runs are reachable
    /// where it is the system id instead.
    ///
    /// Both halves of the change-request flow MUST use this. They did not: validation
    /// accepted either spelling while `executeAmendment` re-derived the lookup with only
    /// `roleDef.id`. A run in exactly the state the second disjunct exists for therefore
    /// passed validation, spent a full multi-turn voting meeting, persisted its
    /// `ChangeRequest` as `.approved` — and then amended nothing, while the reply to the
    /// model still said the change had carried.
    static func targetStep(in run: Run, for roleDef: TeamRoleDefinition) -> StepExecution? {
        run.steps.first { $0.id == roleDef.id || $0.id == roleDef.systemRoleID }
    }

    // MARK: - Validation

    /// Validates a change request. Returns an error message string on failure, `nil` on success.
    static func validateChangeRequest(
        targetRoleID: String,
        requestingRole _: Role,
        team: Team?,
        teamSettings: TeamSettings,
        run: Run
    ) -> (error: String?, targetRoleDef: TeamRoleDefinition?) {
        guard let targetRoleDef = team?.findRole(byIdentifier: targetRoleID) else {
            let available = (team?.roles ?? [])
                .filter { !$0.isSupervisor }
                .map(\.name)
                .sorted()
                .joined(separator: ", ")
            let suffix = available.isEmpty ? "" : " Available roles: \(available)."
            return ("Target role '\(targetRoleID)' not found in the team.\(suffix)", nil)
        }
        guard !targetRoleDef.isSupervisor else {
            return ("Cannot request changes to Supervisor's work.", nil)
        }

        // Target step must be .done
        guard let targetStep = targetStep(in: run, for: targetRoleDef) else {
            return ("Target role '\(targetRoleDef.name)' has no step in this run.", nil)
        }
        guard targetStep.status == .done else {
            return ("Target role '\(targetRoleDef.name)' has not completed their work yet (status: \(targetStep.status.rawValue)). Can only request changes to completed work.", nil)
        }

        // Limits
        let maxCR = teamSettings.limits.maxChangeRequestsPerRun
        if maxCR > 0, run.changeRequests.count >= maxCR {
            return ("Change request limit reached (\(maxCR) per run).", nil)
        }
        let maxAmend = teamSettings.limits.maxAmendmentsPerStep
        if maxAmend > 0, targetStep.amendments.count >= maxAmend {
            return ("Amendment limit reached for \(targetRoleDef.name) (\(maxAmend) per step).", nil)
        }

        return (nil, targetRoleDef)
    }

    // MARK: - Voting Context

    /// Builds the topic and context strings for a change request voting meeting.
    static func buildVotingContext(
        requestingRole: Role,
        targetRoleDef: TeamRoleDefinition,
        changes: String,
        reasoning: String
    ) -> (topic: String, context: String) {
        let topic = "Change Request: \(requestingRole.displayName) requests changes to \(targetRoleDef.name)'s work"
        let context = """
            CHANGE REQUEST DETAILS:
            Requested by: \(requestingRole.displayName)
            Target: \(targetRoleDef.name)
            Changes requested: \(changes)
            Reasoning: \(reasoning)

            INSTRUCTIONS FOR ALL PARTICIPANTS:
            Discuss whether these changes should be made. Consider impact on your own work.
            Each participant MUST end their final message with exactly one of:
            VOTE: APPROVE
            VOTE: REJECT
            """
        return (topic, context)
    }
}
