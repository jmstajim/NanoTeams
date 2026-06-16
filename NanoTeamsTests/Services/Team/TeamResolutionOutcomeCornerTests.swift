import XCTest
@testable import NanoTeams

/// NET-NEW corner cases for `TeamResolution.resolve(task:teamProvider:activeTeam:)`
/// beyond `TeamResolutionTests`. Same shape as the reference suite: plain
/// synchronous `XCTestCase`, value-only SUT (no orchestrator / `@MainActor` /
/// work folder), and the three-case `Outcome` switched on directly.
///
/// Resolution order (from `TeamResolution.swift`):
///   1. `task.generatedTeam` — first branch, short-circuits everything below.
///   2. PIN: `task.runs.last?.teamID`. Set-but-unresolvable → `.failed`; never
///      falls through to a different team.
///   3. Legacy / no-run path: `task.preferredTeamID` via `teamProvider`.
///   4. Child fail-fast (`parentTaskID != nil`) → `.failed`.
///   5. Root fallback: `activeTeam` (`.resolved` if present, else `.noTeam`).
///
/// These corners exercise the PRECEDENCE boundaries the reference file does not:
/// generatedTeam winning over branches 2/4, the empty-string-but-non-nil pin,
/// `runs.last`-only pin reading across multiple runs, and pin-vs-preferred when
/// both resolve to DIFFERENT teams.
final class TeamResolutionOutcomeCornerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - generatedTeam precedence over later branches

    func testGeneratedTeam_winsOverChildFailFast_whenPreferredUnresolvable() {
        // Branch 1 must short-circuit before branch 4 (child fail-fast): a CHILD
        // with an unresolvable preferred would otherwise be `.failed`.
        let generated = makeTeam(named: "Generated Child Worker")
        let registry = makeRegistry() // preferred id deliberately absent.

        var task = makeChildTask(id: 100, preferredTeamID: NTMSID.from(name: "Unknown Preferred"))
        task.adoptGeneratedTeam(generated)
        // No runs → would otherwise reach the child fail-fast branch.

        let outcome = TeamResolution.resolve(
            task: task,
            teamProvider: { registry[$0] },
            activeTeam: makeTeam(named: "Parent Active")
        )

        guard case .resolved(let team) = outcome else {
            return XCTFail("generatedTeam on a child task must resolve, never reaching the child fail-fast branch; got \(outcome)")
        }
        XCTAssertEqual(team.id, generated.id,
                       "generatedTeam (branch 1) must win over the child fail-fast (branch 4)")
    }

    func testGeneratedTeam_winsOverUnresolvablePinnedRunTeamID() {
        // Branch 1 must short-circuit before branch 2 EVEN when the pin would be
        // a LOUD `.failed` (unresolvable pinned team).
        let generated = makeTeam(named: "Generated Worker")
        let missingPin = NTMSID.from(name: "Deleted Pinned Team")
        let registry = makeRegistry() // missingPin NOT registered → would be .failed.

        var task = makeRootTask(id: 101)
        task.adoptGeneratedTeam(generated)
        task.runs = [makeRun(id: 0, teamID: missingPin)]

        let outcome = TeamResolution.resolve(
            task: task,
            teamProvider: { registry[$0] },
            activeTeam: nil
        )

        guard case .resolved(let team) = outcome else {
            return XCTFail("generatedTeam must win over an unresolvable pin that would otherwise be .failed; got \(outcome)")
        }
        XCTAssertEqual(team.id, generated.id,
                       "generatedTeam (branch 1) takes precedence over a would-be .failed pin (branch 2)")
    }

    func testGeneratedTeam_winsOnChildWithNoRunsNoPreferred() {
        // generatedTeam short-circuits before the child fail-fast even with the
        // bare child shape (no runs, no preferred) — the path that is `.failed`
        // for a non-generated child.
        let generated = makeTeam(named: "Generated Bare Child")
        let registry = makeRegistry()

        var task = makeChildTask(id: 102) // no preferred, no runs.
        task.adoptGeneratedTeam(generated)

        let outcome = TeamResolution.resolve(
            task: task,
            teamProvider: { registry[$0] },
            activeTeam: makeTeam(named: "Parent Active")
        )

        guard case .resolved(let team) = outcome else {
            return XCTFail("a bare child with a generatedTeam must resolve to the generated team, not fail-fast; got \(outcome)")
        }
        XCTAssertEqual(team.id, generated.id,
                       "generatedTeam short-circuits before the child branch on a bare child task")
    }

    // MARK: - Empty-string pin is still a pin

    func testPinnedRunTeamID_emptyString_unresolvable_isLoudFailure_notFallThrough() {
        // teamID == "" is non-nil, so `if let pinned = run.teamID` binds it as a
        // PIN. teamProvider("") returns nil → `.failed`, NOT a fall-through to
        // preferred/activeTeam.
        let registry = makeRegistry() // provider("") will return nil.
        let emptyPin: NTMSID = ""

        var task = makeRootTask(id: 103, preferredTeamID: makeTeam(named: "Would-Be Preferred").id)
        task.runs = [makeRun(id: 5, teamID: emptyPin)]

        let outcome = TeamResolution.resolve(
            task: task,
            teamProvider: { registry[$0] },
            activeTeam: makeTeam(named: "Would-Be Active")
        )

        guard case .failed(let reason) = outcome else {
            return XCTFail("an empty-but-non-nil pinned run.teamID is still a pin — unresolvable must be .failed, never a fall-through; got \(outcome)")
        }
        XCTAssertTrue(reason.contains("pinned"),
                      "the empty-string pin failure must use the pin-failure message; got: \(reason)")
        XCTAssertTrue(reason.contains("103"),
                      "the pin-failure message must name the task id (103); got: \(reason)")
    }

    // MARK: - runs.last-only pin reading

    func testPin_readsRunsLastOnly_lastNilEarlierSet_fallsToPreferred() {
        // runs.last.teamID == nil → NO pin (the pin reads runs.last only, never an
        // earlier run). Must fall to a resolvable preferredTeamID — and must NOT
        // resolve the earlier run's (resolvable) team.
        let earlier = makeTeam(named: "Earlier Run Team")
        let preferred = makeTeam(named: "Preferred Team")
        let registry = makeRegistry(earlier, preferred) // both resolvable.

        var task = makeRootTask(id: 104, preferredTeamID: preferred.id)
        task.runs = [
            makeRun(id: 0, teamID: earlier.id),  // earlier run HAS a team
            makeRun(id: 1, teamID: nil),         // latest run has none → no pin
        ]

        let outcome = TeamResolution.resolve(
            task: task,
            teamProvider: { registry[$0] },
            activeTeam: makeTeam(named: "Active")
        )

        guard case .resolved(let team) = outcome else {
            return XCTFail("with runs.last.teamID == nil there is no pin; a resolvable preferred must win; got \(outcome)")
        }
        XCTAssertEqual(team.id, preferred.id,
                       "the pin reads runs.last only — it must resolve preferred, not the earlier run's team")
        XCTAssertNotEqual(team.id, earlier.id,
                          "the earlier run's teamID must NOT be consulted for the pin")
    }

    // MARK: - Pin wins over preferred when both resolve to DIFFERENT teams

    func testPinResolves_winsOverDifferentResolvablePreferred() {
        // Both the pin and preferred resolve, to DIFFERENT teams. The pin (branch 2)
        // must win over preferred (branch 3).
        let pinned = makeTeam(named: "Pinned Team")
        let preferred = makeTeam(named: "Preferred Team")
        let registry = makeRegistry(pinned, preferred)

        var task = makeRootTask(id: 105, preferredTeamID: preferred.id)
        task.runs = [makeRun(id: 0, teamID: pinned.id)]

        let outcome = TeamResolution.resolve(
            task: task,
            teamProvider: { registry[$0] },
            activeTeam: makeTeam(named: "Active")
        )

        guard case .resolved(let team) = outcome else {
            return XCTFail("a resolvable pin must resolve; got \(outcome)")
        }
        XCTAssertEqual(team.id, pinned.id,
                       "the pin (branch 2) must win over a different resolvable preferred (branch 3)")
        XCTAssertNotEqual(team.id, preferred.id,
                          "preferred must NOT be returned when the pin resolves to a different team")
    }

    // MARK: - Registry helper

    private func makeRegistry(_ teams: Team...) -> [NTMSID: Team] {
        var registry: [NTMSID: Team] = [:]
        for team in teams { registry[team.id] = team }
        return registry
    }

    // MARK: - Builders (mirrors TeamResolutionTests)

    private func makeTeam(named name: String) -> Team {
        Team(
            id: NTMSID.from(name: "\(name)_\(UUID().uuidString)"),
            name: name,
            description: "test team",
            roles: [
                TeamRoleDefinition(
                    id: "role_\(UUID().uuidString)",
                    name: "Worker",
                    prompt: "",
                    toolIDs: [],
                    usePlanningPhase: false,
                    dependencies: RoleDependencies()
                )
            ],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )
    }

    private func makeRun(id: Int, teamID: NTMSID?) -> Run {
        Run(id: id, teamID: teamID)
    }

    private func makeRootTask(id: Int, preferredTeamID: NTMSID? = nil) -> NTMSTask {
        NTMSTask(
            id: id,
            title: "Root \(id)",
            supervisorTask: "brief",
            preferredTeamID: preferredTeamID
        )
    }

    private func makeChildTask(id: Int, preferredTeamID: NTMSID? = nil) -> NTMSTask {
        NTMSTask(
            id: id,
            title: "Child \(id)",
            supervisorTask: "sub-brief",
            preferredTeamID: preferredTeamID,
            parentTaskID: id - 1,
            parentRoleID: "coding_agent",
            delegationDepth: 1
        )
    }
}
