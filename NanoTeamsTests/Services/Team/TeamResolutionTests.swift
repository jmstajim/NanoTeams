import XCTest
@testable import NanoTeams

/// Pins the resolution order of `TeamResolution.resolve(task:teamProvider:activeTeam:)`
/// — the PURE single source of truth (Fix A) for "which `Team` does this task run against".
///
/// `TeamResolution.resolve` is `nonisolated` and side-effect-free — it returns a
/// 3-case `Outcome` (`.resolved` / `.failed(reason:)` / `.noTeam`). These tests are
/// plain synchronous `XCTestCase` methods that build `NTMSTask` / `Team` / `Run`
/// values directly. No orchestrator, no `@MainActor`, no work folder. The `Harness`
/// maps the `Outcome` back to a `(Team?, errors)` shape so each test reads naturally:
/// `.resolved(t)` → `t` + no error; `.failed(r)` → `nil` + one error; `.noTeam` →
/// `nil` + no error.
///
/// Resolution order under test (from `TeamResolution.swift`):
///   1. `task.generatedTeam` — delegated/generated children own their team.
///   2. PIN: the LATEST run's `teamID` (`task.runs.last?.teamID`). If set but the
///      `teamProvider` can't resolve it → `.failed`; it must NEVER fall through to a
///      different team mid-run (root OR child).
///   3. Legacy / no-run path: `task.preferredTeamID` via `teamProvider`.
///   4. Child-task fail-fast: a child (`parentTaskID != nil`) that reaches here
///      → `.failed` (Coding Agent self-recursion guard).
///   5. Root fallback: `activeTeam` (`.resolved` if present, else `.noTeam` — NOT a failure).
final class TeamResolutionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - 1. generatedTeam precedence

    func testGeneratedTeam_winsWhenNoRunsExist() {
        var harness = Harness()
        let generated = makeTeam(named: "Generated Worker")
        var task = makeRootTask(id: 1)
        task.adoptGeneratedTeam(generated)
        // No runs at all.

        let resolved = harness.resolve(task: task, activeTeam: makeTeam(named: "Active"))

        XCTAssertEqual(resolved?.id, generated.id,
                       "generatedTeam must win when no runs exist — it is the first branch in the resolution order")
        XCTAssertTrue(harness.errors.isEmpty,
                      "generatedTeam resolution is a clean success — onError must not be called")
    }

    func testGeneratedTeam_winsOverConflictingPinnedRunTeamID() {
        var harness = Harness()
        let generated = makeTeam(named: "Generated Worker")
        let pinnedTeam = makeTeam(named: "Pinned Run Team")
        harness.register(pinnedTeam) // even though it IS resolvable, generated wins.

        var task = makeRootTask(id: 2)
        task.adoptGeneratedTeam(generated)
        task.runs = [makeRun(id: 0, teamID: pinnedTeam.id)]

        let resolved = harness.resolve(task: task, activeTeam: nil)

        XCTAssertEqual(resolved?.id, generated.id,
                       "generatedTeam takes precedence over a pinned (and otherwise resolvable) run.teamID — it is checked first")
        XCTAssertTrue(harness.errors.isEmpty,
                      "no failure occurred — onError must not be called")
    }

    // MARK: - 2. Pinned run.teamID

    func testPinnedRunTeamID_resolves_returnsThatTeam_noError() {
        var harness = Harness()
        let pinnedTeam = makeTeam(named: "Pinned Team")
        harness.register(pinnedTeam)

        var task = makeRootTask(id: 3, preferredTeamID: NTMSID.from(name: "SomeOtherPreferred"))
        task.runs = [makeRun(id: 0, teamID: pinnedTeam.id)]

        let resolved = harness.resolve(task: task, activeTeam: makeTeam(named: "Active"))

        XCTAssertEqual(resolved?.id, pinnedTeam.id,
                       "a resolvable pinned run.teamID must be returned directly, overriding preferredTeamID and activeTeam")
        XCTAssertTrue(harness.errors.isEmpty,
                      "successful pin resolution must NOT call onError")
    }

    func testPinnedRunTeamID_usesLatestRun_notFirst() {
        var harness = Harness()
        let teamA = makeTeam(named: "Team A (latest)")
        let teamB = makeTeam(named: "Team B (first)")
        harness.register(teamA)
        harness.register(teamB)

        var task = makeRootTask(id: 4)
        // runs.first pins B, runs.last pins A — the pin must read runs.last.
        task.runs = [
            makeRun(id: 0, teamID: teamB.id),
            makeRun(id: 1, teamID: teamA.id),
        ]

        let resolved = harness.resolve(task: task, activeTeam: nil)

        XCTAssertEqual(resolved?.id, teamA.id,
                       "the pin must come from runs.last (the active run), not runs.first")
        XCTAssertTrue(harness.errors.isEmpty,
                      "successful pin resolution must NOT call onError")
    }

    func testPinnedTeamID_unresolvable_rootTask_returnsNil_loudFailure() {
        var harness = Harness()
        let missingID = NTMSID.from(name: "Deleted Team")
        // Deliberately do NOT register missingID with the provider.

        var task = makeRootTask(id: 42)
        task.runs = [makeRun(id: 7, teamID: missingID)]

        let resolved = harness.resolve(task: task, activeTeam: makeTeam(named: "Active Fallback"))

        XCTAssertNil(resolved,
                     "an unresolvable pinned run.teamID must yield nil for a root task — NO fallback to activeTeam (would commingle rosters mid-run)")
        XCTAssertEqual(harness.errors.count, 1,
                       "exactly one onError must fire for the pin failure")
        let message = harness.errors.first ?? ""
        XCTAssertTrue(message.contains(missingID),
                      "pin-failure message must name the pinned team id; got: \(message)")
        XCTAssertTrue(message.contains("7"),
                      "pin-failure message must name the run id (7); got: \(message)")
        XCTAssertTrue(message.contains("42"),
                      "pin-failure message must name the task id (42); got: \(message)")
    }

    func testPinnedTeamID_unresolvable_childTask_returnsNil_pinMessage_notChildMessage() {
        var harness = Harness()
        let missingID = NTMSID.from(name: "Deleted Team")
        // Not registered → unresolvable pin.

        var task = makeChildTask(id: 99)
        task.runs = [makeRun(id: 3, teamID: missingID)]

        let resolved = harness.resolve(task: task, activeTeam: makeTeam(named: "Parent Active"))

        XCTAssertNil(resolved,
                     "an unresolvable pinned run.teamID must yield nil for a child task too — the pin failure is loud and short-circuits before the child branch")
        XCTAssertEqual(harness.errors.count, 1,
                       "exactly one onError must fire — the pin branch, not the child branch")
        let message = harness.errors.first ?? ""
        XCTAssertTrue(message.contains("pinned"),
                      "for a child with an unresolvable PIN, the message must be the pin-failure ('pinned'), proving it short-circuited before the child fail-fast; got: \(message)")
        XCTAssertFalse(message.contains("self-recursion"),
                       "the pin failure must NOT reach the child 'self-recursion' branch; got: \(message)")
    }

    // MARK: - 3. Legacy preferredTeamID

    func testLegacy_runTeamIDNil_preferredResolves_returnsPreferred_noError() {
        var harness = Harness()
        let preferred = makeTeam(named: "Preferred Team")
        harness.register(preferred)

        var task = makeRootTask(id: 5, preferredTeamID: preferred.id)
        // A run exists but its teamID is nil (legacy run, no pin).
        task.runs = [makeRun(id: 0, teamID: nil)]

        let resolved = harness.resolve(task: task, activeTeam: makeTeam(named: "Active"))

        XCTAssertEqual(resolved?.id, preferred.id,
                       "with no pin (run.teamID == nil), a resolvable preferredTeamID must win over activeTeam")
        XCTAssertTrue(harness.errors.isEmpty,
                      "legacy preferredTeamID resolution is a clean success — onError must not be called")
    }

    func testLegacy_runTeamIDNil_preferredUnresolvable_rootTask_fallsBackToActiveTeam_noError() {
        var harness = Harness()
        let active = makeTeam(named: "Active Team")
        let unresolvableID = NTMSID.from(name: "Unknown Preferred")
        // unresolvableID is NOT registered; active IS the activeTeam param (not via provider).

        var task = makeRootTask(id: 6, preferredTeamID: unresolvableID)
        task.runs = [makeRun(id: 0, teamID: nil)]

        let resolved = harness.resolve(task: task, activeTeam: active)

        XCTAssertEqual(resolved?.id, active.id,
                       "a root task with an unresolvable preferredTeamID and no pin falls back to activeTeam")
        XCTAssertTrue(harness.errors.isEmpty,
                      "root fallback to activeTeam is legitimate — onError must NOT be called")
    }

    func testLegacy_runTeamIDNil_preferredUnresolvable_childTask_returnsNil_selfRecursionMessage() {
        var harness = Harness()
        let unresolvableID = NTMSID.from(name: "Unknown Preferred")
        // unresolvableID not registered.

        var task = makeChildTask(id: 77, preferredTeamID: unresolvableID)
        task.runs = [makeRun(id: 0, teamID: nil)]

        let resolved = harness.resolve(task: task, activeTeam: makeTeam(named: "Parent Active"))

        XCTAssertNil(resolved,
                     "a child task with an unresolvable preferredTeamID and no pin must fail-fast to nil — it must NOT inherit the parent's active team")
        XCTAssertEqual(harness.errors.count, 1,
                       "exactly one onError must fire — the child fail-fast branch")
        let message = harness.errors.first ?? ""
        XCTAssertTrue(message.contains("77"),
                      "child fail-fast message must name the task id (77); got: \(message)")
        XCTAssertTrue(message.contains("self-recursion"),
                      "child fail-fast message must mention 'self-recursion' (Coding Agent guard); got: \(message)")
    }

    // MARK: - 5. Root fallback edge cases

    func testNoRuns_noPreferred_rootTask_activeTeamNonNil_returnsActiveTeam_noError() {
        var harness = Harness()
        let active = makeTeam(named: "Active Team")

        let task = makeRootTask(id: 8) // preferredTeamID nil, no runs.

        let resolved = harness.resolve(task: task, activeTeam: active)

        XCTAssertEqual(resolved?.id, active.id,
                       "a root task with no runs and no preferredTeamID falls back to the non-nil activeTeam")
        XCTAssertTrue(harness.errors.isEmpty,
                      "root fallback to a present activeTeam is legitimate — onError must NOT be called")
    }

    func testNoRuns_noPreferred_rootTask_activeTeamNil_returnsNil_noError() {
        var harness = Harness()

        let task = makeRootTask(id: 9) // preferredTeamID nil, no runs.

        let resolved = harness.resolve(task: task, activeTeam: nil)

        XCTAssertNil(resolved,
                     "a root task with no runs, no preferredTeamID, and nil activeTeam resolves to nil")
        XCTAssertTrue(harness.errors.isEmpty,
                      "nil activeTeam for a root task is a legitimate 'no team selected' state — NOT an error, onError must not be called")
    }

    func testNoRuns_noPreferred_childTask_returnsNil_childFailFast() {
        var harness = Harness()

        let task = makeChildTask(id: 55) // preferredTeamID nil, no runs.

        let resolved = harness.resolve(task: task, activeTeam: makeTeam(named: "Parent Active"))

        XCTAssertNil(resolved,
                     "a child task with no runs and no preferredTeamID must fail-fast to nil, never inheriting the parent's active team")
        XCTAssertEqual(harness.errors.count, 1,
                       "exactly one onError must fire — the child fail-fast branch")
        XCTAssertTrue((harness.errors.first ?? "").contains("self-recursion"),
                      "child fail-fast message must mention 'self-recursion'; got: \(harness.errors.first ?? "")")
    }

    // MARK: - onError call-count guard

    func testOnError_calledAtMostOnce_acrossSingleResolve() {
        // Drive the loudest path (unresolvable pin on a child) and assert the
        // sink is never invoked more than once in a single resolve() call —
        // resolve() returns immediately after the first onError in every branch.
        var harness = Harness()
        let missingID = NTMSID.from(name: "Deleted Team")

        var task = makeChildTask(id: 1234)
        task.runs = [makeRun(id: 0, teamID: missingID)]

        _ = harness.resolve(task: task, activeTeam: makeTeam(named: "Active"))

        XCTAssertLessThanOrEqual(harness.errors.count, 1,
                                 "a single resolve() must call onError at most once — every failing branch returns immediately after the sink")
    }

    // MARK: - Outcome enum distinguishes failure from no-team

    /// The whole point of the `Outcome` enum (vs an overloaded `Team?`) is that a
    /// LOUD failure and the legitimate "no team selected" are distinct cases — a
    /// caller can surface one and silently coalesce the other. Assert the three
    /// cases directly against `TeamResolution.resolve`, not through the Harness map.
    func testOutcome_distinguishesResolved_failed_noTeam() {
        let teamA = makeTeam(named: "A")
        let registry = [teamA.id: teamA]

        // resolved
        var root = makeRootTask(id: 1, preferredTeamID: teamA.id)
        root.runs = [makeRun(id: 0, teamID: teamA.id)]
        guard case .resolved(let t) = TeamResolution.resolve(
            task: root, teamProvider: { registry[$0] }, activeTeam: nil
        ), t.id == teamA.id else {
            return XCTFail("expected .resolved(teamA)")
        }

        // failed (deleted pinned team)
        var pinFail = makeRootTask(id: 2)
        pinFail.runs = [makeRun(id: 0, teamID: NTMSID.from(name: "gone"))]
        guard case .failed = TeamResolution.resolve(
            task: pinFail, teamProvider: { registry[$0] }, activeTeam: teamA
        ) else {
            return XCTFail("expected .failed for a deleted pinned team — NOT .resolved(activeTeam)")
        }

        // noTeam (root, nothing selected, nil activeTeam)
        let bare = makeRootTask(id: 3)
        guard case .noTeam = TeamResolution.resolve(
            task: bare, teamProvider: { registry[$0] }, activeTeam: nil
        ) else {
            return XCTFail("expected .noTeam for a root task with no pin/preferred and nil activeTeam")
        }
    }

    // MARK: - Test Harness

    /// Captures onError messages and backs `teamProvider` with an in-memory dict.
    private struct Harness {
        var errors: [String] = []
        private var teams: [NTMSID: Team] = [:]

        mutating func register(_ team: Team) {
            teams[team.id] = team
        }

        mutating func resolve(task: NTMSTask, activeTeam: Team?) -> Team? {
            // Snapshot the registry so the provider closure doesn't capture a
            // mutating `self` (Swift forbids it). Map the 3-case Outcome back to
            // the (Team?, errors) shape the tests assert on.
            let registry = teams
            switch TeamResolution.resolve(
                task: task,
                teamProvider: { id in registry[id] },
                activeTeam: activeTeam
            ) {
            case .resolved(let team):
                return team
            case .failed(let reason):
                errors.append(reason)
                return nil
            case .noTeam:
                return nil
            }
        }
    }

    // MARK: - Builders

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
