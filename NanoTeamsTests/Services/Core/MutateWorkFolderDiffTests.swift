import XCTest
@testable import NanoTeams

/// Tests for `NTMSOrchestrator.mutateWorkFolder` — the diff-driven writer that
/// decides which of `workfolder.json` / `settings.json` / `teams.json` to
/// persist based on whether the closure changed the corresponding sub-component.
///
/// These tests defend the orchestrator-level behavior that `WorkFolderFileSplitTests`
/// cannot: the repository-layer tests exercise the narrow writers directly, so
/// they never touch the closure-diff logic, and in particular cannot catch a
/// regression where `Team.==` identity shortcut re-introduces silent data loss
/// (CLAUDE.md pitfall #45).
@MainActor
final class MutateWorkFolderDiffTests: NTMSOrchestratorTestBase {

    private var paths: NTMSPaths { NTMSPaths(workFolderRoot: tempDir) }

    /// Snapshots raw content of the three split files. Content comparison is
    /// used instead of mtime because mtimes are flaky on CI.
    private struct ContentSnapshot: Equatable {
        var wf: Data?
        var settings: Data?
        var teams: Data?
    }

    private func snapshotHashes() -> ContentSnapshot {
        ContentSnapshot(
            wf: try? Data(contentsOf: paths.workFolderJSON),
            settings: try? Data(contentsOf: paths.settingsJSON),
            teams: try? Data(contentsOf: paths.teamsJSON)
        )
    }

    // MARK: - Pitfall #45 regression

    /// This is THE critical regression test for the entire refactor: mutating a
    /// team's roles structurally WITHOUT bumping `team.updatedAt` must still
    /// persist to `teams.json`. If someone reverts the JSON-diff workaround in
    /// `mutateWorkFolder` to a plain `!=`, `Team.==` will report the teams as
    /// equal (it only compares id+updatedAt) and the mutation will silently
    /// vanish on the next app launch.
    func testMutateWorkFolder_teamStructuralChangeWithoutUpdatedAtBump_writesTeamsFile() async {
        await sut.openWorkFolder(tempDir)

        guard let before = try? Data(contentsOf: paths.teamsJSON) else {
            return XCTFail("teams.json should exist after bootstrap")
        }

        await sut.mutateWorkFolder { proj in
            guard !proj.teams.isEmpty else { return }
            // Structural mutation: change a role's prompt without touching
            // team.updatedAt. This is exactly what `Team.==` fails to detect.
            guard !proj.teams[0].roles.isEmpty else { return }
            proj.teams[0].roles[0].prompt = "REGRESSION TEST MARKER \(UUID().uuidString)"
            // Deliberately do NOT bump proj.teams[0].updatedAt.
        }

        let after = try? Data(contentsOf: paths.teamsJSON)
        XCTAssertNotNil(after)
        XCTAssertNotEqual(before, after,
            "teams.json MUST be rewritten when a role prompt changes, even if Team.updatedAt was not bumped")

        // Verify the marker actually landed on disk (not just a touched file).
        if let after,
           let decoded = try? JSONCoderFactory.makeDateDecoder().decode(TeamsFile.self, from: after) {
            XCTAssertTrue(
                decoded.teams[0].roles[0].prompt.contains("REGRESSION TEST MARKER"),
                "Mutation must be persisted to disk"
            )
        } else {
            XCTFail("teams.json should decode after mutation")
        }
    }

    // MARK: - No-op and single-file writes

    func testMutateWorkFolder_noOpClosure_writesNoFiles() async {
        await sut.openWorkFolder(tempDir)
        let before = snapshotHashes()

        await sut.mutateWorkFolder { _ in
            // Intentionally empty — closure makes no changes.
        }

        let after = snapshotHashes()
        XCTAssertEqual(before, after,
            "A no-op closure must not rewrite any file")
    }

    func testMutateWorkFolder_onlyDescriptionChange_writesOnlySettingsFile() async {
        await sut.openWorkFolder(tempDir)
        let before = snapshotHashes()

        await sut.mutateWorkFolder { proj in
            proj.settings.description = "new description \(UUID().uuidString)"
        }

        let after = snapshotHashes()
        XCTAssertEqual(before.wf, after.wf, "workfolder.json must not change")
        XCTAssertNotEqual(before.settings, after.settings, "settings.json must change")
        XCTAssertEqual(before.teams, after.teams, "teams.json must not change")
    }

    func testMutateWorkFolder_onlyActiveTeamChange_writesOnlyWorkFolderFile() async {
        await sut.openWorkFolder(tempDir)
        guard let wf = sut.workFolder, wf.teams.count >= 2 else {
            return XCTFail("Need at least 2 teams for this test")
        }
        let targetID = wf.teams[1].id

        let before = snapshotHashes()

        await sut.mutateWorkFolder { proj in
            proj.setActiveTeam(targetID)
        }

        let after = snapshotHashes()
        XCTAssertNotEqual(before.wf, after.wf, "workfolder.json must change on active team switch")
        XCTAssertEqual(before.settings, after.settings, "settings.json must not change")
        XCTAssertEqual(before.teams, after.teams, "teams.json must not change")
    }

    func testMutateWorkFolder_multipleSubcomponents_writesExactlyThose() async {
        await sut.openWorkFolder(tempDir)
        guard let wf = sut.workFolder, !wf.teams.isEmpty else {
            return XCTFail("Need bootstrapped teams")
        }

        let before = snapshotHashes()

        await sut.mutateWorkFolder { proj in
            proj.settings.description = "dual change \(UUID().uuidString)"
            proj.teams[0].name = "Renamed \(UUID().uuidString)"
        }

        let after = snapshotHashes()
        XCTAssertEqual(before.wf, after.wf,
            "workfolder.json must not change when only settings + teams were touched")
        XCTAssertNotEqual(before.settings, after.settings)
        XCTAssertNotEqual(before.teams, after.teams)
    }

    func testMutateWorkFolder_allThreeChanged_writesAllThreeFiles() async {
        await sut.openWorkFolder(tempDir)
        guard let wf = sut.workFolder, wf.teams.count >= 2 else {
            return XCTFail("Need at least 2 teams")
        }
        let targetID = wf.teams[1].id

        let before = snapshotHashes()

        await sut.mutateWorkFolder { proj in
            proj.state.activeTeamID = targetID
            proj.settings.description = "triple \(UUID().uuidString)"
            proj.teams[0].name = "Triple \(UUID().uuidString)"
        }

        let after = snapshotHashes()
        XCTAssertNotEqual(before.wf, after.wf)
        XCTAssertNotEqual(before.settings, after.settings)
        XCTAssertNotEqual(before.teams, after.teams)
    }

    // MARK: - In-memory projection

    func testMutateWorkFolder_persistsToMemoryProjection() async {
        await sut.openWorkFolder(tempDir)

        await sut.mutateWorkFolder { proj in
            proj.settings.description = "in-memory check"
        }

        XCTAssertEqual(sut.workFolder?.settings.description, "in-memory check",
            "After mutateWorkFolder, the in-memory projection must reflect the change")
    }
}
