import XCTest

@testable import NanoTeams

/// `RoleContextBanner`'s status/step resolution, extracted from the view body by the
/// 2026-08-25 hoist and unit-testable for the first time.
///
/// The hoist itself is pinned as WIRING by `Ratchet/BodyPassHoistPinTests` — a test that
/// calls these functions cannot see how many times the body calls them (CLAUDE.md #57).
/// What IS testable here is a behaviour change the hoist carried: the old fallback
/// iterated `run.roleStatuses` and scanned the roster for each key, so with two roles
/// sharing a `systemRoleID` it returned whichever match `Dictionary` iteration reached
/// first — a different answer on different launches from identical data. The rewrite
/// iterates the ROSTER, so roster order decides.
@MainActor
final class RoleContextBannerResolutionTests: XCTestCase {

    private func role(id: String, systemRoleID: String? = nil) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: id,
            prompt: "",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: []),
            systemRoleID: systemRoleID
        )
    }

    private func step(id: String, status: StepStatus = .running) -> StepExecution {
        var s = StepExecution.make(for: role(id: id))
        s.status = status
        return s
    }

    // MARK: - resolveStatus

    func testResolveStatus_directHit_winsWithoutTouchingTheFallback() {
        let def = role(id: "a", systemRoleID: "engineer")
        let run = Run(id: 0, roleStatuses: ["a": .working, "b": .failed])
        XCTAssertEqual(
            RoleContextBanner.resolveStatus(
                roleID: "a", run: run, roleDefinitions: [def], roleDef: def),
            .working)
    }

    func testResolveStatus_bridgesBySystemRoleID_whenTheIDMoved() {
        // The UUID-mismatch case the fallback exists for: the run's statuses are keyed by
        // a previous generation of role ids, and only `systemRoleID` still matches.
        let selected = role(id: "new-uuid", systemRoleID: "engineer")
        let stored = role(id: "old-uuid", systemRoleID: "engineer")
        let run = Run(id: 0, roleStatuses: ["old-uuid": .needsAcceptance])
        XCTAssertEqual(
            RoleContextBanner.resolveStatus(
                roleID: "new-uuid", run: run,
                roleDefinitions: [selected, stored], roleDef: selected),
            .needsAcceptance)
    }

    func testResolveStatus_isDeterministic_whenTwoRolesShareASystemRoleID() {
        // The defect the rewrite closed. Roles are name-derived, so two carrying one
        // `systemRoleID` is reachable — `RoleRosterIndex` and `Run.stepsByRoleBaseID`
        // both call out the same hazard. Roster ORDER must decide, every time.
        let selected = role(id: "sel", systemRoleID: "engineer")
        let first = role(id: "first", systemRoleID: "engineer")
        let second = role(id: "second", systemRoleID: "engineer")
        let run = Run(id: 0, roleStatuses: ["first": .working, "second": .failed])
        for _ in 0..<50 {
            XCTAssertEqual(
                RoleContextBanner.resolveStatus(
                    roleID: "sel", run: run,
                    roleDefinitions: [selected, first, second], roleDef: selected),
                .working,
                "roster order must decide; the pre-fix loop walked `roleStatuses` and "
                    + "returned whichever match Dictionary iteration reached first")
        }
    }

    func testResolveStatus_idleWhenNoRoleDefOrNoSystemRoleID() {
        let bare = role(id: "x")
        let run = Run(id: 0, roleStatuses: ["y": .working])
        XCTAssertEqual(
            RoleContextBanner.resolveStatus(
                roleID: "x", run: run, roleDefinitions: [bare], roleDef: bare),
            .idle)
        XCTAssertEqual(
            RoleContextBanner.resolveStatus(
                roleID: "x", run: run, roleDefinitions: [bare], roleDef: nil),
            .idle)
        XCTAssertEqual(
            RoleContextBanner.resolveStatus(
                roleID: "x", run: nil, roleDefinitions: [bare], roleDef: bare),
            .idle)
    }

    // MARK: - resolveStep

    func testResolveStep_prefersTheRolesOwnStep_thenBridgesByBaseID() {
        let def = role(id: "a", systemRoleID: "engineer")
        let own = step(id: "a")
        XCTAssertEqual(
            RoleContextBanner.resolveStep(
                roleID: "a", run: Run(id: 0, steps: [own]), roleDef: def)?.id,
            "a")
        // No step for `a`; the bridge finds the one whose `role.baseID` is the systemRoleID.
        let bridged = step(id: "engineer")
        XCTAssertEqual(
            RoleContextBanner.resolveStep(
                roleID: "a", run: Run(id: 0, steps: [bridged]), roleDef: def)?.id,
            "engineer")
        XCTAssertNil(
            RoleContextBanner.resolveStep(
                roleID: "a", run: Run(id: 0, steps: [bridged]), roleDef: role(id: "a")),
            "with no systemRoleID there is no bridge, and guessing would attach another "
                + "role's step to this banner")
    }

    func testResolveStep_takesTheLATESTMatchingStep() {
        let def = role(id: "a")
        let older = step(id: "a", status: .done)
        let newer = step(id: "a", status: .running)
        XCTAssertEqual(
            RoleContextBanner.resolveStep(
                roleID: "a", run: Run(id: 0, steps: [older, newer]), roleDef: def)?.status,
            .running)
    }

    // MARK: - hasSecondaryContent

    func testHasSecondaryContent_isTrueForAnyOfTheThree_andFalseForNone() {
        let none = RoleContextBanner.hasSecondaryContent(
            artifacts: [], consultations: [], scratchpad: nil)
        XCTAssertFalse(none)
        XCTAssertFalse(RoleContextBanner.hasSecondaryContent(
            artifacts: [], consultations: [], scratchpad: ""),
        "an EMPTY scratchpad is not content — the divider would render over nothing")
        XCTAssertTrue(RoleContextBanner.hasSecondaryContent(
            artifacts: [], consultations: [], scratchpad: "notes"))
        XCTAssertTrue(RoleContextBanner.hasSecondaryContent(
            artifacts: [Artifact(name: "Release Notes")],
            consultations: [], scratchpad: nil))
    }
}
