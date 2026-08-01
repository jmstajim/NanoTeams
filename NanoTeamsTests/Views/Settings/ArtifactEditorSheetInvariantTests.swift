import XCTest

@testable import NanoTeams

/// Structural pin on `ArtifactEditorSheet`'s save path.
///
/// Why a SOURCE SCAN rather than a behavioural test: `saveArtifact()` is
/// `private` on a `View` struct with no test seam, and the defect it guards is
/// a SwiftUI `Binding` race — five consecutive `team.artifacts[i].X = …` writes
/// through `TeamEditorView.binding(for:)`, whose getter returns a captured
/// snapshot and whose setter is async. Each write re-read the same pre-edit
/// snapshot and replaced the whole team, so only the last one survived and it
/// carried nothing but `updatedAt`. Nothing reachable from a unit test could
/// observe that, which is exactly how it shipped.
///
/// `ArtifactEditorMutationsTests` pins the SEMANTICS of the replacement; this
/// file pins the SHAPE, so the next editor sheet cannot quietly reintroduce the
/// class. Same technique and rationale as
/// `TeamActivityFeedContainerInvariantTests`.
final class ArtifactEditorSheetInvariantTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        // NanoTeamsTests/Views/Settings/<this file> → repo root → production file.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Settings/
            .deletingLastPathComponent()  // Views/
            .deletingLastPathComponent()  // NanoTeamsTests/
            .deletingLastPathComponent()  // repo root
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func artifactEditorSheetSource() throws -> String {
        try source("NanoTeams/Views/Settings/TeamEditor/ArtifactEditorSheet.swift")
    }

    /// The regression itself: subscript-assigning into `team.artifacts` is a
    /// read-modify-write through the Binding, and doing it more than once per
    /// user action loses every write but the last.
    func testSaveArtifact_doesNotSubscriptAssignThroughTheTeamBinding() throws {
        let source = try artifactEditorSheetSource()
        XCTAssertFalse(
            source.contains("team.artifacts["),
            """
            ArtifactEditorSheet must not write through `team.artifacts[...]`. \
            `TeamEditorView.binding(for:)` has a captured-snapshot getter and an async \
            setter, so consecutive read-modify-write cycles each start from the pre-edit \
            snapshot and the last write wins. Compose on a local `var newTeam = team` via \
            `ArtifactEditorMutations` and assign once. See RoleEditorMutations' doc comment.
            """
        )
    }

    /// The positive half — the compose-locally convention is actually in use,
    /// so the negative assertion above can't be satisfied by deleting the save.
    func testSaveArtifact_composesOnALocalCopy() throws {
        let source = try artifactEditorSheetSource()
        XCTAssertTrue(
            source.contains("var newTeam = team"),
            "ArtifactEditorSheet.saveArtifact must compose mutations on a local copy before a single Binding write."
        )
        XCTAssertTrue(
            source.contains("ArtifactEditorMutations."),
            "ArtifactEditorSheet must delegate its mutations to ArtifactEditorMutations so create/edit rules cannot drift."
        )
    }

    /// A failed save must keep the sheet open, mirroring `RoleEditorSheet`
    /// (`if saveRole() { dismiss() }`). The old code dismissed unconditionally
    /// AND still called `onSave()`, so an edit against a deleted artifact looked
    /// exactly like a successful one.
    func testSaveButton_dismissesOnlyOnSuccess() throws {
        let source = try artifactEditorSheetSource()
        XCTAssertTrue(
            source.contains("if saveArtifact() { dismiss() }"),
            "The Save button must gate dismissal on the save's result."
        )
    }

    /// `RoleEditorDependenciesTab` discovered the created artifact by diffing
    /// `team.artifactNames` against a pre-sheet snapshot. That could never fire:
    /// `onSave` runs in the same synchronous turn as the async Binding write, so
    /// the diff was always empty.
    func testRoleEditorDependenciesTab_doesNotDiffTheTeamToFindTheNewArtifact() throws {
        let source = try source(
            "NanoTeams/Views/Settings/TeamEditor/RoleEditorDependenciesTab.swift")
        XCTAssertFalse(
            source.contains("artifactNamesBefore"),
            """
            RoleEditorDependenciesTab must take the created artifact from the ArtifactEditorSheet \
            callback, not diff `team.artifactNames` against a pre-sheet snapshot — `onSave` fires \
            before the async Binding write lands, so the diff is always empty.
            """
        )
    }

    /// Team name / description used to bind straight to the same Binding, i.e.
    /// one full `teams.json` write per keystroke.
    func testTeamSettings_nameAndDescriptionUseLocalDrafts() throws {
        let source = try source("NanoTeams/Views/Settings/TeamEditor/TeamSettingsDetailView.swift")
        XCTAssertFalse(
            source.contains("text: $team.name"),
            "Team name must be edited through a local draft committed on submit/blur, not bound directly to the async team Binding (one teams.json write per keystroke)."
        )
        XCTAssertFalse(
            source.contains("text: $team.description"),
            "Team description must be edited through a local draft committed on blur."
        )
    }
}
