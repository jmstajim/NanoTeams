import XCTest
@testable import NanoTeams

/// Pins `TeamResolution.resolveTeamID` against `TeamResolution.resolve`.
///
/// The two share a private `pin(task:teamProvider:activeTeam:)` precisely so
/// they cannot drift. They previously did not exist as a pair: the reconcile's
/// running-role scan hand-rolled `generatedTeam ?? preferredTeamID`, which
/// disagrees with the run pin the engine, the LLM services and the team-deletion
/// guard all honour. That disagreement deferred the wrong team (freezing its
/// bundled updates) while leaving the genuinely-running team's `toolIDs` free to
/// be rewritten mid-flight — the exact hazard deferral exists to prevent.
///
/// A comment saying "keep these in sync" is what produced that bug, so the
/// relation is asserted instead.
final class TeamResolutionOrderEquivalenceTests: XCTestCase {

    private var teamA: Team!
    private var teamB: Team!
    private var active: Team!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        teamA = Self.makeTeam(id: "team_a", name: "A")
        teamB = Self.makeTeam(id: "team_b", name: "B")
        active = Self.makeTeam(id: "team_active", name: "Active")
    }

    /// Minimal team — resolution only ever reads `id`, so the roster is inert.
    private static func makeTeam(id: NTMSID, name: String) -> Team {
        Team(
            id: id,
            name: name,
            roles: [],
            artifacts: [],
            settings: TeamSettings.default,
            graphLayout: TeamGraphLayout()
        )
    }

    override func tearDown() {
        teamA = nil
        teamB = nil
        active = nil
        super.tearDown()
    }

    private func provider(_ teams: [Team]) -> (NTMSID) -> Team? {
        { id in teams.first { $0.id == id } }
    }

    private func makeTask(
        generated: Team? = nil,
        runTeamID: NTMSID?? = .none,
        preferredTeamID: NTMSID? = nil,
        parentTaskID: Int? = nil
    ) -> NTMSTask {
        // `.none` for runTeamID means "no run at all"; `.some(nil)` means a
        // legacy run whose teamID never decoded.
        let runs: [Run]
        switch runTeamID {
        case .none: runs = []
        case .some(let id): runs = [Run(id: 0, steps: [], roleStatuses: [:], teamID: id)]
        }
        return NTMSTask(
            id: 7,
            title: "t",
            supervisorTask: "t",
            runs: runs,
            preferredTeamID: preferredTeamID,
            generatedTeam: generated,
            // `TaskLineage` enforces (parent == nil) ↔ (role == nil) ↔ (depth == 0),
            // so a bare `parentTaskID` collapses back to `.root` and the task
            // would not read as a child at all.
            parentTaskID: parentTaskID,
            parentRoleID: parentTaskID.map { _ in "parent_role" },
            delegationDepth: parentTaskID == nil ? 0 : 1
        )
    }

    /// Every branch of the order, asserted as a table.
    func testResolveTeamID_agreesWithResolve_acrossEveryBranch() {
        let all = [teamA!, teamB!, active!]

        let cases: [(name: String, task: NTMSTask, teams: [Team], activeTeam: Team?, expected: NTMSID?)] = [
            ("1. generated wins over everything",
             makeTask(generated: teamB, runTeamID: .some("team_a"), preferredTeamID: "team_a"),
             all, active, "team_b"),

            ("2. run pin beats preferredTeamID",
             makeTask(runTeamID: .some("team_a"), preferredTeamID: "team_b"),
             all, active, "team_a"),

            ("2b. dangling run pin is still the task's claim (resolve → .failed)",
             makeTask(runTeamID: .some("gone"), preferredTeamID: "team_b"),
             all, active, "gone"),

            ("3. legacy run with nil teamID falls to preferredTeamID",
             makeTask(runTeamID: .some(nil), preferredTeamID: "team_b"),
             all, active, "team_b"),

            ("3b. no run at all falls to preferredTeamID",
             makeTask(preferredTeamID: "team_a"),
             all, active, "team_a"),

            ("4. child task never inherits activeTeam",
             makeTask(preferredTeamID: "gone", parentTaskID: 1),
             all, active, nil),

            ("5. root falls back to activeTeam",
             makeTask(preferredTeamID: "gone"),
             all, active, "team_active"),

            ("5b. root with no activeTeam resolves to nothing",
             makeTask(preferredTeamID: "gone"),
             all, nil, nil)
        ]

        for c in cases {
            let id = TeamResolution.resolveTeamID(
                task: c.task, teamProvider: provider(c.teams), activeTeam: c.activeTeam
            )
            XCTAssertEqual(id, c.expected, c.name)

            // And the id must match whatever `resolve` landed on, wherever
            // `resolve` produced a team at all.
            switch TeamResolution.resolve(
                task: c.task, teamProvider: provider(c.teams), activeTeam: c.activeTeam
            ) {
            case .resolved(let team):
                XCTAssertEqual(id, team.id, "\(c.name) — resolve/resolveTeamID disagree")
            case .failed, .noTeam:
                break   // covered by the explicit expectations above
            }
        }
    }

    /// The specific divergence that motivated the extraction: a task whose
    /// `preferredTeamID` names a team deleted before its first run, so the run
    /// was pinned to the folder's active team instead. Deletion is guarded on
    /// `pinnedTeamID`, which is nil until a run exists — so this is reachable
    /// without any legacy file.
    func testStalePreferredTeamID_resolvesToTheRunPin() {
        let task = makeTask(runTeamID: .some("team_active"), preferredTeamID: "deleted_team")

        XCTAssertEqual(
            TeamResolution.resolveTeamID(
                task: task, teamProvider: provider([teamA, active]), activeTeam: active
            ),
            "team_active",
            "the run pin is authoritative; the stale preferredTeamID must not win"
        )
    }
}
