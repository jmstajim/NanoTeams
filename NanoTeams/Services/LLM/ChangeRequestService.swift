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

    /// A single speaker's ballot, after collapsing its turns.
    private enum Ballot { case approve, reject }

    /// Tallies APPROVE/REJECT votes from meeting messages: **one ballot per ROLE**, with the
    /// chair's ballot counted only to break a tie among the others.
    ///
    /// **One ballot per role, not per message.** This counted MESSAGES until 2026-09-11, and
    /// the rotation does not hand out turns evenly: in a three-seat vote
    /// (`MeetingStreamingService.determineNextSpeaker` rotates over the participants MINUS
    /// the chair, and the chair also opens, closes each round and concludes) the chair speaks
    /// 6 turns out of 10. Six ballots for one voter decided every close vote by seating
    /// order. A role's LAST message carrying a token is its ballot — a later turn is a
    /// revised position, and the concluding turn, which carries no token (its content is
    /// `conclusion.decision`), does not erase the vote cast before it.
    ///
    /// **The chair is an arbiter, not a voter.** `MeetingCoordinator.turnDirective` appends
    /// `voteInstruction` to the chair's directives too, so the chair does vote — but weight
    /// is a property of the count, not of the prompt, and a chair that votes like everyone
    /// else while speaking more than everyone else is simply the loudest voter. The chair's
    /// ballot counts only when the electorate is even — which includes an electorate that
    /// is EMPTY, see below — and never overturns a majority.
    ///
    /// **The target is the defendant, and a defendant does not sit on its own jury.** The
    /// target IS a participant — `handleChangeRequest` seats it first, so its defence is on
    /// the record and the chair hears it — but its ballot is not counted. Until 2026-09-11
    /// (the evening pass) it was, and the arithmetic of a vote room made that decisive: the
    /// room is the target plus the consumers of its artifact minus the requester, and on
    /// six bundled edges the requester is the target's ONLY consumer (Engineering Code
    /// Reviewer → Software Engineer, FAANG TPM → Code Reviewer / SRE, Engineering TPM →
    /// Code Reviewer, Ultra Change Verifier → Diff Reviewer, Quest Party Rules Arbiter →
    /// Encounter Architect). There the electorate was the target alone, one ballot can
    /// never tie, and the chair's tie-break branch was unreachable: the defendant rejected
    /// its own repair, unopposed, on every checker's request. The electorate is therefore
    /// the room minus the chair minus the target; when that leaves nobody, the chair — the
    /// impartial third party the same day's chair rule introduced — decides alone. The
    /// target's directive says so (`targetInstruction`), so it is not asked for a ballot
    /// that would be dropped.
    ///
    /// **0-0 is `.noVotes`, not `.tied`.** A 1-1 deadlock is a real disagreement, and V1's
    /// documented policy of auto-approving it is a defensible coin flip: both answers were
    /// argued for. Nobody voting is not a disagreement — it is the absence of a decision, and
    /// it is routinely reachable with a meeting that ran perfectly well: participants answer in
    /// prose ("Let me think about it..."), the `VOTE:` token never appears, and the tally is 0-0.
    /// Folding that into `.tied` made "the team never voted" mean "the team said yes", which
    /// resets the target role and cascades a revision through every started downstream role
    /// (`propagateAmendmentDownstream`) — destroying work on the strength of no vote at all.
    /// With an arbiter in the chair `.tied` now needs the chair to have abstained too, and
    /// `.noVotes` means no ballot from ANYONE, the chair included: a chair that heard the
    /// whole discussion and cast the only ballot has decided, which is the arbiter's job.
    ///
    /// A sibling of this defect was already fixed once at the caller (`meetingReply.succeeded`,
    /// see `ChangeRequestVotingFailureTests`), which closed the case where the meeting never
    /// ran. This closes the case where it ran and decided nothing.
    ///
    /// `coordinator` and `target` are compared by `Role` equality, which is sound because
    /// `resolveCoordinatorRole`, `handleChangeRequest` and `MeetingParticipantResolver` all
    /// build roles through the SAME `Role.fromDefinition`. Pass `nil` for a meeting with no
    /// chair to weight, or no target to exclude — a discussion meeting has neither.
    static func tallyVotes(
        meetingMessages: [TeamMessage], coordinator: Role?, target: Role?
    ) -> VoteResult {
        var ballots: [Role: Ballot] = [:]
        for msg in meetingMessages {
            let upper = msg.content.uppercased()
            if upper.contains("VOTE: APPROVE") || upper.contains("VOTE:APPROVE") {
                ballots[msg.role] = .approve
            } else if upper.contains("VOTE: REJECT") || upper.contains("VOTE:REJECT") {
                ballots[msg.role] = .reject
            }
        }

        let chairBallot = coordinator.flatMap { ballots[$0] }
        let electorate = ballots.filter { role, _ in role != coordinator && role != target }.values
        let approves = electorate.count { $0 == .approve }
        let rejects = electorate.count { $0 == .reject }

        if approves > rejects { return .approved }
        if rejects > approves { return .rejected }
        // Even among the electorate, or no electorate at all — the arbiter's moment.
        switch chairBallot {
        case .approve: return .approved
        case .reject: return .rejected
        case nil: return approves == 0 ? .noVotes : .tied
        }
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
        requestingRole: Role,
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

        // The target must be a DIRECT SUPPLIER of the requester: one of the artifacts it
        // produces is one the requester requires.
        //
        // Without this any `.done` non-Supervisor role was a legal target, and the cost is
        // not theoretical. A vote convenes the CONSUMERS of the target's artifact, and an
        // approval propagates transitively (`propagateAmendmentDownstream`) — so a checker
        // naming the pipeline's ROOT document as its target summons every role that reads
        // it, resets the roles between, and restarts the one holder of `ask_supervisor`,
        // interrupting the human a second time in a pipeline whose contract is one
        // interruption. Requiring a direct supply edge confines a repair to the document the
        // requester actually read, which is also the only one it can judge.
        //
        // Derived from the dependency graph rather than a new field: the edge already exists
        // and is already what the engine schedules on.
        let requesterDef = team?.findRole(byIdentifier: requestingRole.baseID)
        if let requesterDef {
            let supplies = Set(targetRoleDef.dependencies.producesArtifacts)
            let needs = Set(requesterDef.dependencies.requiredArtifacts)
            if supplies.isDisjoint(with: needs) {
                let allowed = (team?.roles ?? [])
                    .filter { !$0.isSupervisor
                        && !Set($0.dependencies.producesArtifacts).isDisjoint(with: needs) }
                    .map(\.name)
                    .sorted()
                let suffix = allowed.isEmpty
                    ? " You have no upstream role to ask; record the problem in your own output instead."
                    : " You can only ask a role whose work you read: \(allowed.joined(separator: ", "))."
                return (
                    "'\(targetRoleDef.name)' does not produce any artifact you require, so it is "
                        + "not yours to send back.\(suffix)",
                    nil)
            }
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

    /// The vote contract, worded once. `MeetingCoordinator.turnDirective` appends it to
    /// EVERY turn of a `.changeRequestVote` meeting — the recency slot, so the rule the
    /// tally depends on is the last thing each speaker reads (playbook R1.1.3, R1.4.1).
    /// The two literals are what `tallyVotes` matches.
    nonisolated static let voteInstruction =
        "End your reply with exactly one line: `VOTE: APPROVE` or `VOTE: REJECT`."

    /// What the TARGET reads instead of `voteInstruction`: its ballot is not counted
    /// (`tallyVotes`), so asking it for one would be asking for a token the tally drops.
    /// Its contribution is the defence — which is what the chair and the electorate weigh.
    nonisolated static let targetInstruction =
        "This request is about your own work, so you do not vote on it: answer it on the "
            + "merits — what stands, what you would change and why — and leave the ballot to the "
            + "other participants and the chair."

    /// Builds the topic and context strings for a change request voting meeting.
    ///
    /// The context is the meeting's `### Context` body under `## Team meeting`: lowercase
    /// prose in the `## `/`### ` family every other block of the wire uses. Until
    /// 2026-09-07 it opened with `CHANGE REQUEST DETAILS:` and
    /// `INSTRUCTIONS FOR ALL PARTICIPANTS:` — bare ALL-CAPS colon labels, a second marker
    /// family in one payload (playbook R1.3.2 / R1.5.1 / R4.3.2) — and was the ONLY carrier
    /// of the vote contract, a standing rule in a mid-conversation user turn that sank
    /// behind the transcript (R1.1.3). The contract now rides `voteInstruction`.
    nonisolated static func buildVotingContext(
        requestingRole: Role,
        targetRoleDef: TeamRoleDefinition,
        changes: String,
        reasoning: String
    ) -> (topic: String, context: String) {
        let topic = "Change Request: \(requestingRole.displayName) requests changes to \(targetRoleDef.name)'s work"
        let context = """
        \(requestingRole.displayName) requests changes to \(targetRoleDef.name)'s work.
        Changes requested: \(changes)
        Reasoning: \(reasoning)
        Discuss whether these changes should be made, weighing the impact on your own work.
        """
        return (topic, context)
    }
}
