import XCTest

@testable import NanoTeams

/// `TeamSettings.remappingRoleIDs` — the rewrite that runs when a team is imported or duplicated
/// and every role gets a fresh id.
///
/// Four separate places hold role ids (the `reportsTo` graph on BOTH sides of each edge, the
/// meeting coordinator, the invitable set, the acceptance checkpoints), and a miss in any one of
/// them is silent: the team loads, the graph draws, and then a role escalates to a supervisor
/// that no longer exists, or an acceptance checkpoint stops firing. Nothing errors.
final class TeamSettingsRemapTests: XCTestCase {

    private func settings(
        reportsTo: [String: String] = [:],
        coordinator: String? = nil,
        invitable: Set<String> = [],
        checkpoints: Set<String> = []
    ) -> TeamSettings {
        TeamSettings(
            hierarchy: TeamHierarchy(reportsTo: reportsTo),
            meetingCoordinatorRoleID: coordinator,
            invitableRoles: invitable,
            acceptanceCheckpoints: checkpoints)
    }

    // MARK: - Every id-bearing field is rewritten

    /// `reportsTo` is a graph, so BOTH ends of each edge carry a role id. Remapping only the keys
    /// leaves every role reporting to a supervisor that no longer exists — and since escalation
    /// resolves lazily, the team looks fine until someone calls `ask_supervisor`.
    func testReportsTo_remapsBothChildAndParent() {
        let result = settings(reportsTo: ["eng": "lead"])
            .remappingRoleIDs(["eng": "eng2", "lead": "lead2"])

        XCTAssertEqual(result.hierarchy.reportsTo, ["eng2": "lead2"])
    }

    func testCoordinator_isRemapped() {
        let result = settings(coordinator: "lead").remappingRoleIDs(["lead": "lead2"])

        XCTAssertEqual(result.meetingCoordinatorRoleID, "lead2")
    }

    func testInvitableRolesAndCheckpoints_areRemapped() {
        let result = settings(invitable: ["a", "b"], checkpoints: ["b"])
            .remappingRoleIDs(["a": "a2", "b": "b2"])

        XCTAssertEqual(result.invitableRoles, ["a2", "b2"])
        XCTAssertEqual(result.acceptanceCheckpoints, ["b2"])
    }

    /// One call must rewrite all four at once — a partial remap is the failure mode this method
    /// exists to prevent.
    func testAllFourFields_areRewrittenByASingleCall() {
        let result = settings(
            reportsTo: ["eng": "lead"], coordinator: "lead",
            invitable: ["eng", "lead"], checkpoints: ["eng"]
        ).remappingRoleIDs(["eng": "eng2", "lead": "lead2"])

        XCTAssertEqual(result.hierarchy.reportsTo, ["eng2": "lead2"])
        XCTAssertEqual(result.meetingCoordinatorRoleID, "lead2")
        XCTAssertEqual(result.invitableRoles, ["eng2", "lead2"])
        XCTAssertEqual(result.acceptanceCheckpoints, ["eng2"])
    }

    // MARK: - Partial mappings

    /// Unmapped ids pass through. Import maps only the roles it actually renamed, so dropping the
    /// rest would silently sever half the hierarchy.
    func testUnmappedIDs_passThroughUnchanged() {
        let result = settings(
            reportsTo: ["eng": "lead"], coordinator: "pm",
            invitable: ["eng", "qa"], checkpoints: ["qa"]
        ).remappingRoleIDs(["eng": "eng2"])

        XCTAssertEqual(result.hierarchy.reportsTo, ["eng2": "lead"])
        XCTAssertEqual(result.meetingCoordinatorRoleID, "pm")
        XCTAssertEqual(result.invitableRoles, ["eng2", "qa"])
        XCTAssertEqual(result.acceptanceCheckpoints, ["qa"])
    }

    func testEmptyMapping_returnsSelfUntouched() {
        let original = settings(
            reportsTo: ["eng": "lead"], coordinator: "lead",
            invitable: ["eng"], checkpoints: ["eng"])

        XCTAssertEqual(original.remappingRoleIDs([:]), original)
    }

    /// A mapping naming only ids this team doesn't have is a no-op, not a wipe.
    func testMappingWithNoOverlap_changesNothing() {
        let original = settings(reportsTo: ["eng": "lead"], invitable: ["eng"])

        XCTAssertEqual(original.remappingRoleIDs(["other": "other2"]), original)
    }

    // MARK: - Non-id fields are preserved

    /// The remap must not reset settings that have nothing to do with ids — an import that
    /// silently flipped a team from `.autonomous` back to `.manual` would wedge every
    /// `ask_supervisor` behind a human who isn't watching.
    func testNonIDSettings_survive() {
        let original = TeamSettings(
            hierarchy: TeamHierarchy(reportsTo: ["eng": "lead"]),
            meetingCoordinatorRoleID: "lead",
            invitableRoles: ["eng"],
            supervisorCanBeInvited: true,
            limits: TeamLimits(maxConsultationsPerStep: 7),
            defaultAcceptanceMode: .finalOnly,
            acceptanceCheckpoints: ["eng"],
            supervisorMode: .autonomous)

        let result = original.remappingRoleIDs(["eng": "eng2", "lead": "lead2"])

        XCTAssertTrue(result.supervisorCanBeInvited)
        XCTAssertEqual(result.limits.maxConsultationsPerStep, 7)
        XCTAssertEqual(result.defaultAcceptanceMode, .finalOnly)
        XCTAssertEqual(result.supervisorMode, .autonomous)
    }

    func testNilCoordinator_staysNil() {
        let result = settings(coordinator: nil).remappingRoleIDs(["a": "b"])

        XCTAssertNil(result.meetingCoordinatorRoleID,
                     "nil is Auto mode — the remap must not invent a coordinator")
    }

    // MARK: - Degenerate mappings

    /// Identity entries are legal and must be inert.
    func testIdentityMapping_isInert() {
        let original = settings(reportsTo: ["eng": "lead"], invitable: ["eng"])

        XCTAssertEqual(original.remappingRoleIDs(["eng": "eng", "lead": "lead"]), original)
    }

    /// A swap has to be simultaneous. Applying entries in sequence over a mutating dictionary
    /// would map `a→b` and then `b→a` right back, collapsing the swap to a no-op.
    func testSwappingTwoIDs_isSimultaneousNotSequential() {
        let result = settings(reportsTo: ["a": "b"], invitable: ["a", "b"])
            .remappingRoleIDs(["a": "b", "b": "a"])

        XCTAssertEqual(result.hierarchy.reportsTo, ["b": "a"])
        XCTAssertEqual(result.invitableRoles, ["a", "b"])
    }

    /// Characterization, not endorsement: `reportsTo` is a dictionary, so two children collapsing
    /// onto one new id silently drops an edge (whereas the two Sets merely dedupe, which is
    /// harmless). Callers build the mapping from fresh UUIDs, so collisions don't arise in
    /// practice — this records what would happen if one ever did, rather than leaving it
    /// undiscovered.
    func testCollidingMapping_collapsesHierarchyEdges() {
        let result = settings(reportsTo: ["a": "lead", "b": "lead"], invitable: ["a", "b"])
            .remappingRoleIDs(["a": "same", "b": "same"])

        XCTAssertEqual(result.hierarchy.reportsTo.count, 1, "one edge is lost to the collision")
        XCTAssertEqual(result.invitableRoles, ["same"], "the set merely dedupes")
    }

    // MARK: - Round-trip

    /// Remap-then-remap-back returns the original, which is the property import/export relies on.
    func testRemappingBack_restoresTheOriginal() {
        let original = settings(
            reportsTo: ["eng": "lead"], coordinator: "lead",
            invitable: ["eng", "lead"], checkpoints: ["eng"])

        let round = original
            .remappingRoleIDs(["eng": "eng2", "lead": "lead2"])
            .remappingRoleIDs(["eng2": "eng", "lead2": "lead"])

        XCTAssertEqual(round, original)
    }
}
