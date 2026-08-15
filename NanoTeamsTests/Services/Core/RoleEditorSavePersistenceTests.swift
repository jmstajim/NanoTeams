import XCTest
@testable import NanoTeams

/// Persistence smoke tests for the Role Editor Save flow against a real
/// `NTMSOrchestrator` + temp work folder. Scope: from the orchestrator's
/// `mutateWorkFolder` boundary down through disk and back, NOT the
/// SwiftUI observer chain above it. They GREEN on both the buggy and
/// fixed code for the user-reported "uncheck in same session" symptom
/// (the bug was a SwiftUI ForEach diff problem upstream of
/// `mutateWorkFolder`, and `mutateWorkFolder` itself uses a JSON-encoded
/// teams diff that bypasses `Team.==`). The observer-chain regression
/// is pinned separately at the pure-helper level by
/// `RoleEditorMutationsTests.testApplyEdit_bumpsTeamUpdatedAt_…`.
///
/// What these tests DO catch: a regression where the in-memory snapshot
/// goes out of sync with disk, or where a load-time normalizer silently
/// restores a removed whitelist entry. Plus the
/// `testStaleRoleReference_lookupByID_returnsPostSaveRole` case, which
/// pins the id-only equality property the UI fix depends on.
@MainActor
final class RoleEditorSavePersistenceTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    /// Simulates the full Delegation-tab Save flow against the real
    /// orchestrator:
    ///  1. Open a work folder, locate the seeded Coding Agent role.
    ///  2. Build a fresh `editorState`, `load(from: role)`, then drop one
    ///     team from `selectedDelegationTeamIDs`.
    ///  3. Read the current team out of the orchestrator (mirrors
    ///     `RoleEditorSheet`'s `var newTeam = team`), apply the edit through
    ///     the pure helper, persist via `mutateWorkFolder` (mirrors the
    ///     captured-getter-binding setter in `TeamEditorView.binding(for:)`).
    ///  4. Re-read the team and assert the whitelist shrunk by exactly one.
    func testUncheckTeamFromWhitelist_persistsThroughMutateWorkFolder() async {
        await sut.openWorkFolder(tempDir)

        // Find the Coding Agent team + its delegating role.
        guard let (teamIdx, roleIdx, originalRole) = locateCodingAgentRole() else {
            XCTFail("Could not locate the seeded Coding Agent role in the default work folder.")
            return
        }
        XCTAssertGreaterThanOrEqual(
            originalRole.allowedDelegationTeamIDs.count, 2,
            "Coding Agent must ship with ≥ 2 whitelisted teams for this test to be meaningful."
        )
        let firstID = originalRole.allowedDelegationTeamIDs[0]
        let secondID = originalRole.allowedDelegationTeamIDs[1]

        // Simulate the editor: load state, then drop `secondID` from the whitelist.
        var editorState = RoleEditorState()
        editorState.load(from: originalRole)
        editorState.selectedDelegationTeamIDs.remove(secondID)

        // Simulate saveRole: read team, apply edit on a local copy, persist.
        guard let team = sut.snapshot?.projection.teams[teamIdx] else {
            XCTFail("Snapshot disappeared mid-test.")
            return
        }
        var newTeam = team
        let didApply = RoleEditorMutations.applyEdit(
            to: &newTeam,
            editorState: editorState,
            existingRoleID: originalRole.id
        )
        XCTAssertTrue(didApply)

        await sut.mutateWorkFolder { projection in
            if let idx = projection.teams.firstIndex(where: { $0.id == newTeam.id }) {
                projection.teams[idx] = newTeam
            }
        }

        // Re-read from the orchestrator's snapshot.
        let savedRole = sut.snapshot!.projection.teams[teamIdx].roles[roleIdx]
        XCTAssertEqual(
            savedRole.allowedDelegationTeamIDs, [firstID],
            "Whitelist must shrink to just the first ID after uncheck + save."
        )
    }

    /// Same end-to-end flow, but verifies the change survives a work-folder
    /// **close + reopen** — i.e., that the write reached `teams.json` on
    /// disk, not just the in-memory snapshot. If a normalize-on-load pass
    /// silently restored the whitelist, this would catch it.
    func testUncheckTeamFromWhitelist_survivesWorkFolderReopen() async {
        await sut.openWorkFolder(tempDir)
        guard let (teamIdx, roleIdx, originalRole) = locateCodingAgentRole() else {
            XCTFail("Could not locate the seeded Coding Agent role.")
            return
        }
        XCTAssertGreaterThanOrEqual(originalRole.allowedDelegationTeamIDs.count, 2)
        let firstID = originalRole.allowedDelegationTeamIDs[0]
        let secondID = originalRole.allowedDelegationTeamIDs[1]

        var editorState = RoleEditorState()
        editorState.load(from: originalRole)
        editorState.selectedDelegationTeamIDs.remove(secondID)

        var newTeam = sut.snapshot!.projection.teams[teamIdx]
        _ = RoleEditorMutations.applyEdit(
            to: &newTeam,
            editorState: editorState,
            existingRoleID: originalRole.id
        )
        await sut.mutateWorkFolder { projection in
            if let idx = projection.teams.firstIndex(where: { $0.id == newTeam.id }) {
                projection.teams[idx] = newTeam
            }
        }

        // Close, then reopen the same work folder. Forces a disk round-trip.
        await sut.closeProject()
        await sut.openWorkFolder(tempDir)

        let reloaded = sut.snapshot!.projection.teams[teamIdx].roles[roleIdx]
        XCTAssertEqual(
            reloaded.allowedDelegationTeamIDs, [firstID],
            "Whitelist removal must survive disk round-trip (no load-time normalizer should restore it)."
        )
    }

    /// Core regression for the in-session "reopen shows stale" symptom.
    ///
    /// `TeamRoleDefinition.==` is id-only (`hash == id`, `lhs.id == rhs.id`).
    /// SwiftUI `ForEach` over `team.roles` uses that equality to diff old
    /// vs new — when the user mutates the whitelist, the role's id stays
    /// the same, so SwiftUI considers the role "unchanged" and keeps the
    /// OLD value inside the row's closure captures. The tap handler
    /// `showingEditRole = role` then stamps the OLD role into state, and
    /// the reopened sheet renders the pre-save whitelist.
    ///
    /// The fix is to never trust a ForEach iteration value for actions
    /// that fire later — always re-resolve by id from the current team.
    /// This test pins the invariant the fix relies on: after a save lands
    /// in `mutateWorkFolder`, an id-based lookup in `team.roles` returns
    /// the POST-save role, even when the caller still holds a copy of the
    /// PRE-save role value.
    func testStaleRoleReference_lookupByID_returnsPostSaveRole() async {
        await sut.openWorkFolder(tempDir)
        guard let (teamIdx, roleIdx, originalRole) = locateCodingAgentRole() else {
            XCTFail("Could not locate the seeded Coding Agent role.")
            return
        }
        XCTAssertGreaterThanOrEqual(originalRole.allowedDelegationTeamIDs.count, 2)
        let firstID = originalRole.allowedDelegationTeamIDs[0]
        let secondID = originalRole.allowedDelegationTeamIDs[1]

        // Simulate "ForEach captured the role value at first render" — this
        // is the variable the SwiftUI row closure binds to in production.
        let staleRoleReference = originalRole

        // User flow: uncheck secondID and save.
        var editorState = RoleEditorState()
        editorState.load(from: originalRole)
        editorState.selectedDelegationTeamIDs.remove(secondID)

        var newTeam = sut.snapshot!.projection.teams[teamIdx]
        _ = RoleEditorMutations.applyEdit(
            to: &newTeam,
            editorState: editorState,
            existingRoleID: originalRole.id
        )
        await sut.mutateWorkFolder { projection in
            if let idx = projection.teams.firstIndex(where: { $0.id == newTeam.id }) {
                projection.teams[idx] = newTeam
            }
        }

        // Sanity: structurally, the stale reference and the persisted role
        // are equal per the id-only `==`. This is the trap the fix avoids.
        let postSaveRole = sut.snapshot!.projection.teams[teamIdx].roles[roleIdx]
        XCTAssertEqual(
            staleRoleReference, postSaveRole,
            "Pre-condition: id-only equality treats stale and post-save roles as equal."
        )

        // The fix's invariant: looking up the role by id in the CURRENT
        // team yields the post-save data even when the caller is holding
        // a stale value.
        let resolved = sut.snapshot!.projection.teams[teamIdx]
            .roles.first(where: { $0.id == staleRoleReference.id })

        XCTAssertEqual(
            resolved?.allowedDelegationTeamIDs, [firstID],
            "Lookup by id in the current team must return the post-save whitelist."
        )
    }

    /// Re-checking a previously-unchecked team must also persist. Twin of
    /// the uncheck case to catch any asymmetric bug.
    func testCheckTeamIntoWhitelist_persistsThroughMutateWorkFolder() async {
        await sut.openWorkFolder(tempDir)
        guard let (teamIdx, roleIdx, originalRole) = locateCodingAgentRole() else {
            XCTFail("Could not locate the seeded Coding Agent role.")
            return
        }
        XCTAssertGreaterThanOrEqual(originalRole.allowedDelegationTeamIDs.count, 2)

        // First, uncheck everything to set a known empty baseline.
        var prep = originalRole
        prep.allowedDelegationTeamIDs = []
        await sut.mutateWorkFolder { projection in
            projection.teams[teamIdx].roles[roleIdx] = prep
        }

        // Now simulate the user adding the first team back.
        let toAdd = originalRole.allowedDelegationTeamIDs[0]
        var editorState = RoleEditorState()
        editorState.load(from: sut.snapshot!.projection.teams[teamIdx].roles[roleIdx])
        editorState.selectedDelegationTeamIDs.insert(toAdd)

        var newTeam = sut.snapshot!.projection.teams[teamIdx]
        _ = RoleEditorMutations.applyEdit(
            to: &newTeam,
            editorState: editorState,
            existingRoleID: originalRole.id
        )
        await sut.mutateWorkFolder { projection in
            if let idx = projection.teams.firstIndex(where: { $0.id == newTeam.id }) {
                projection.teams[idx] = newTeam
            }
        }

        let savedRole = sut.snapshot!.projection.teams[teamIdx].roles[roleIdx]
        XCTAssertEqual(
            savedRole.allowedDelegationTeamIDs, [toAdd],
            "Re-checking a previously-unchecked team must land in the persisted whitelist."
        )
    }

    // MARK: - Helpers

    /// Locate the seeded Coding Agent role (delegating, whitelist ≥ 2 teams).
    /// Returns the team index, role index, and the role definition.
    private func locateCodingAgentRole() -> (teamIdx: Int, roleIdx: Int, role: TeamRoleDefinition)? {
        guard let projection = sut.snapshot?.projection else { return nil }
        for (tIdx, team) in projection.teams.enumerated() {
            for (rIdx, role) in team.roles.enumerated()
                where !role.allowedDelegationTeamIDs.isEmpty
            {
                return (tIdx, rIdx, role)
            }
        }
        return nil
    }
}
