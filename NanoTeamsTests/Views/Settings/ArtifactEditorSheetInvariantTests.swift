import XCTest

@testable import NanoTeams

/// Structural pin on `ArtifactEditorSheet`'s save path.
///
/// Why a SOURCE SCAN rather than a behavioural test: the sheet's actions are
/// `private` on a `View` struct with no test seam, and the defect the first two
/// pins guard was a SwiftUI `Binding` race — five consecutive
/// `team.artifacts[i].X = …` writes through `TeamEditorView.binding(for:)`, whose
/// getter then returned a captured snapshot and whose setter was an unawaited
/// `Task`. Each write re-read the same pre-edit snapshot and replaced the whole
/// team, so only the last one survived and it carried nothing but `updatedAt`.
/// Nothing reachable from a unit test could observe that, which is exactly how it
/// shipped. (The binding now stages into `TeamEditCommitQueue` and reads the staged
/// value back; the compose-once shape stays, because one Save is one commit.)
///
/// `ArtifactEditorMutationsTests` pins the SEMANTICS of the replacement and
/// `ArtifactEditorSaveAndCloseTests` the awaited Save; this file pins the SHAPE,
/// so the next editor sheet cannot quietly reintroduce the class. Same technique
/// and rationale as `TeamActivityFeedContainerInvariantTests`.
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
            ArtifactEditorSheet must not write through `team.artifacts[...]`: a Save is ONE \
            value committed as the sheet's session, and per-field writes through the binding \
            are as many staged values — the race this pin was written for. Compose on a local \
            `var newTeam = team` via `ArtifactEditorMutations` and commit once. See \
            RoleEditorMutations' doc comment.
            """
        )
    }

    /// The positive half — the compose-locally convention is actually in use,
    /// so the negative assertion above can't be satisfied by deleting the save.
    func testSaveArtifact_composesOnALocalCopy() throws {
        let source = try artifactEditorSheetSource()
        XCTAssertTrue(
            source.contains("var newTeam = team"),
            "ArtifactEditorSheet's Save must compose mutations on a local copy before a single commit."
        )
        XCTAssertTrue(
            source.contains("ArtifactEditorMutations."),
            "ArtifactEditorSheet must delegate its mutations to ArtifactEditorMutations so create/edit rules cannot drift."
        )
    }

    /// A failed save must keep the sheet open, mirroring `RoleEditorSheet`. The
    /// first version dismissed unconditionally AND still called `onSave()`, so an
    /// edit against a deleted artifact looked exactly like a successful one; the
    /// second (`if saveArtifact() { dismiss() }`) gated on the Binding assignment,
    /// which only started the write — a refused write closed the sheet anyway and
    /// told `onSave` about an artifact that was never stored.
    ///
    /// RED: restore `Button("Save") { if saveArtifact() { dismiss() } }`, or call
    /// `onSave` before the awaited Save answered → an assertion below fails.
    func testSaveButton_dismissesOnlyAfterTheAwaitedSaveStoredTheArtifact() throws {
        let source = RatchetSourceScan.strippingLineComments(try artifactEditorSheetSource())
        let button = try XCTUnwrap(RatchetSourceScan.functionBody(after: "Button(\"Save\")", in: source))
        XCTAssertFalse(button.contains("dismiss()"), "the Save button must not dismiss on its own")
        XCTAssertTrue(button.contains("await save()"), "the Save button must run the awaited Save")
        let save = try XCTUnwrap(RatchetSourceScan.functionBody(after: "private func save() async", in: source))
        let awaited = try XCTUnwrap(save.range(of: "await Self.save("))
        let stored = try XCTUnwrap(save.range(of: "case .saved(let artifact)"))
        let told = try XCTUnwrap(save.range(of: "onSave(artifact)"))
        let dismissed = try XCTUnwrap(save.range(of: "dismiss()"))
        XCTAssertLessThan(awaited.lowerBound, stored.lowerBound)
        XCTAssertLessThan(stored.lowerBound, told.lowerBound, "onSave must hear only of a stored artifact")
        XCTAssertLessThan(told.lowerBound, dismissed.lowerBound)
        XCTAssertEqual(save.components(separatedBy: "onSave(").count, 2, "onSave is called once, on `.saved`")
    }

    /// Escape reaches the sheet as its `.cancelAction` button — which must ask the shared close
    /// policy, not dismiss.
    ///
    /// RED: restore `Button("Cancel") { dismiss() }` → the first assertion fails.
    func testTheCancelButton_andWithItEscape_goThroughTheClosePolicy() throws {
        let source = RatchetSourceScan.strippingLineComments(try artifactEditorSheetSource())
        let cancel = try XCTUnwrap(RatchetSourceScan.functionBody(after: "Button(\"Cancel\")", in: source))
        XCTAssertTrue(cancel.contains("requestClose()"), "Cancel must ask before closing")
        XCTAssertFalse(cancel.contains("dismiss()"), "Cancel must not dismiss on its own")
        let header = try XCTUnwrap(RatchetSourceScan.functionBody(after: "private var headerBar", in: source))
        XCTAssertTrue(header.contains(".keyboardShortcut(.cancelAction)"), "Escape must stay on Cancel")
        let requestClose = try XCTUnwrap(RatchetSourceScan.functionBody(after: "func requestClose()", in: source))
        XCTAssertTrue(requestClose.contains("EditorSheetClosePolicy.onCancel("))
    }

    /// `RoleEditorDependenciesTab` discovered the created artifact by diffing
    /// `team.artifactNames` against a pre-sheet snapshot. That could never fire:
    /// `onSave` ran in the same synchronous turn as the then-async Binding write,
    /// so the diff was always empty.
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
