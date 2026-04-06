import Foundation

/// Stateless service for change request validation, voting, and context building.
enum ChangeRequestService {

    // MARK: - Vote Result

    enum VoteResult: Equatable {
        case approved
        case rejected
        case tied
    }

    // MARK: - Vote Tallying

    /// Tallies APPROVE/REJECT votes from meeting messages.
    /// Returns `.tied` when votes are equal (including 0-0).
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
        return .tied
    }

    // MARK: - Validation

    /// Validates a change request. Returns an error message string on failure, `nil` on success.
    static func validateChangeRequest(
        targetRoleID: String,
        requestingRole: Role,
        team: Team?,
        teamSettings: TeamSettings,
        run: Run
    ) -> (error: String?, targetRoleDef: TeamRoleDefinition?) {
        guard let targetRoleDef = team?.findRole(byIdentifier: targetRoleID) else {
            return ("Target role '\(targetRoleID)' not found in the team.", nil)
        }
        guard !targetRoleDef.isSupervisor else {
            return ("Cannot request changes to Supervisor's work.", nil)
        }

        // Target step must be .done
        guard let targetStep = run.steps.first(where: {
            $0.id == targetRoleDef.id || $0.id == targetRoleDef.systemRoleID
        }) else {
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
