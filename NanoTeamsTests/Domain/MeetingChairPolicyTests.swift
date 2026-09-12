import XCTest
@testable import NanoTeams

/// The seat rule, at the boundaries that decide it.
///
/// `VoteChairSurfaceParityTests` next door pins that the EDITOR and the RUNTIME agree; this
/// pins what they agree ABOUT. The rule moved into `Domain/` on 2026-09-13 so the Team editor
/// could ask it about a team it is editing — until then it lived inside
/// `LLMExecutionService.effectiveCoordinator` and the editor read `Team.meetingCoordinatorID`
/// instead, which since 1.9.18 is a different answer for a vote (DEBTS D-B12).
final class MeetingChairPolicyTests: XCTestCase {

    private func role(
        _ id: String, tools: [String] = [], requires: [String] = [], produces: [String] = [],
        isSupervisor: Bool = false
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: id.capitalized,
            prompt: "p",
            toolIDs: tools,
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: requires, producesArtifacts: produces),
            systemRoleID: isSupervisor ? "supervisor" : nil)
    }

    /// Supervisor + three workers in a line: `a` produces what `b` requires, `b` what `c`
    /// requires, and both `b` and `c` hold `request_changes`.
    private func makeTeam(coordinator: String?) -> Team {
        Team(
            id: NTMSID.from(name: "Chair Fixture"),
            name: "Chair Fixture",
            roles: [
                role("sup", isSupervisor: true),
                role("a", produces: ["doc"]),
                role("b", tools: [ToolNames.requestChanges], requires: ["doc"], produces: ["plan"]),
                role("c", tools: [ToolNames.requestChanges], requires: ["plan"]),
            ],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: coordinator),
            graphLayout: TeamGraphLayout())
    }

    private func chairID(_ team: Team, disqualified: Set<String>) -> String? {
        guard case .chair(let def) = MeetingChairPolicy.chair(in: team, disqualified: disqualified)
        else { return nil }
        return def.id
    }

    /// RED: read `team.meetingCoordinatorID` without consulting `disqualified` → the requester
    /// chairs its own case, which is what shipped in FAANG and Engineering until 1.9.18.
    func testCoordinatorIsTheRequester_aStandInTakesTheChair() {
        let team = makeTeam(coordinator: "b")
        XCTAssertEqual(chairID(team, disqualified: []), "b", "a discussion disqualifies nobody")
        XCTAssertNotEqual(chairID(team, disqualified: ["b", "a"]), "b")
        XCTAssertEqual(chairID(team, disqualified: ["b", "a"]), "c")
    }

    /// The target defends its own work; it is a participant in its own vote and never the chair.
    func testCoordinatorIsTheTarget_aStandInTakesTheChair() {
        let team = makeTeam(coordinator: "a")
        XCTAssertEqual(chairID(team, disqualified: ["b", "a"]), "c")
    }

    /// RED: build the disqualification as a two-element ARRAY → the pool loses two entries for
    /// one role and the wrong stand-in is seated.
    func testCoordinatorIsBothRequesterAndTarget_thePoolLosesOneRole() {
        let team = makeTeam(coordinator: "b")
        // A Set, so "b twice" removes one role, not two.
        XCTAssertEqual(chairID(team, disqualified: ["b"]), "a")
    }

    /// Exactly two non-Supervisor roles, both party to the vote: nobody impartial is left.
    func testTwoRolesOnly_leavesNobodyImpartial() {
        let team = Team(
            id: NTMSID.from(name: "Pair"),
            name: "Pair",
            roles: [
                role("sup", isSupervisor: true),
                role("a", produces: ["doc"]),
                role("b", tools: [ToolNames.requestChanges], requires: ["doc"]),
            ],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "b"),
            graphLayout: TeamGraphLayout())
        XCTAssertEqual(
            MeetingChairPolicy.chair(in: team, disqualified: ["b", "a"]), .noImpartialChair)
    }

    /// A stored `nil`, an orphan and the Supervisor must all answer as the healed team does —
    /// `Team.meetingCoordinatorID` owns the healing, and the policy consumes it rather than
    /// implementing a second copy.
    func testUnresolvableStoredCoordinators_answerAsTheHealedTeamDoes() {
        let healed = chairID(makeTeam(coordinator: "a"), disqualified: [])
        for stored in [nil, "ghost", "sup", ""] {
            XCTAssertEqual(
                chairID(makeTeam(coordinator: stored), disqualified: []),
                healed,
                "stored id \(stored.map { "'\($0)'" } ?? "nil") must heal to the default rule")
        }
    }

    // MARK: - What the editor can know without a vote in hand

    /// RED: drop the supply-edge condition from `legalVotePairs` → every `.done` non-Supervisor
    /// role becomes a target and the count jumps, which is the pre-1.9.18 rule
    /// `validateChangeRequest` no longer allows.
    func testLegalVotePairs_readTheSameSupplyEdgeTheValidatorEnforces() {
        let pairs = MeetingChairPolicy.legalVotePairs(in: makeTeam(coordinator: "b"))
        let described = Set(pairs.map { "\($0.requesterID)->\($0.targetID)" })
        XCTAssertEqual(described, ["b->a", "c->b"],
                       "only a DIRECT supplier of the requester is a legal target")
    }

    /// A role holding `request_changes` but requiring nothing has nobody to send back to.
    func testRequesterWithNoInputs_formsNoPair() {
        let team = Team(
            id: NTMSID.from(name: "Rootless"),
            name: "Rootless",
            roles: [
                role("sup", isSupervisor: true),
                role("a", tools: [ToolNames.requestChanges], produces: ["doc"]),
                role("b", requires: ["doc"]),
            ],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "a"),
            graphLayout: TeamGraphLayout())
        XCTAssertTrue(MeetingChairPolicy.legalVotePairs(in: team).isEmpty)
    }

    /// A roster where every legal vote leaves nobody impartial: the editor must say so, and to
    /// EVERY non-Supervisor role, not only to the ones that already earned a standing — a role
    /// that can never chair still needs to know the team holds votes it cannot run.
    ///
    /// RED: drop the second loop in `voteChairSurvey`'s `unchairable` arm → the role that
    /// acquired no standing of its own comes back silent about it.
    func testTwoRolesOnly_everyRoleIsToldTheVoteCannotRun() {
        let team = Team(
            id: NTMSID.from(name: "Pair"),
            name: "Pair",
            roles: [
                role("sup", isSupervisor: true),
                role("a", produces: ["doc"]),
                role("b", tools: [ToolNames.requestChanges], requires: ["doc"]),
            ],
            artifacts: [],
            settings: TeamSettings(meetingCoordinatorRoleID: "b"),
            graphLayout: TeamGraphLayout())

        // The pair is legal — `b` holds the tool and `a` supplies what it requires — so the
        // branch is reachable, which is what makes this test about behaviour and not a fixture.
        XCTAssertEqual(MeetingChairPolicy.legalVotePairs(in: team).count, 1)

        let survey = MeetingChairPolicy.voteChairSurvey(in: team)
        for id in ["a", "b"] {
            XCTAssertTrue(survey.standing(of: id).teamHasUnchairableVotes,
                          "\(id) must be told this roster holds a vote nobody can chair")
            XCTAssertFalse(survey.standing(of: id).canChairSomeVote, id)
        }
        XCTAssertTrue(survey.standing(of: "b").chairsMeetings,
                      "it still chairs plain MEETINGS — only the vote has nobody impartial")
        XCTAssertFalse(survey.standing(of: "sup").teamHasUnchairableVotes,
                       "the Supervisor is not a meeting participant and gets no standing")
    }

    /// RED: report `canChairSomeVote` for the coordinator unconditionally → the stand-in's own
    /// standing stays false and the editor still cannot name it.
    func testSurvey_namesBothTheDisplacedCoordinatorAndItsStandIn() {
        let survey = MeetingChairPolicy.voteChairSurvey(in: makeTeam(coordinator: "b"))
        let coordinator = survey.standing(of: "b")
        XCTAssertTrue(coordinator.chairsMeetings)
        XCTAssertTrue(coordinator.displacedOnSomeVote)
        XCTAssertTrue(coordinator.standInIDs.contains("c"))
        XCTAssertTrue(survey.standing(of: "c").canChairSomeVote)
        XCTAssertFalse(survey.standing(of: "c").chairsMeetings)
    }
}
