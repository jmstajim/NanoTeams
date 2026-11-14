import SwiftUI
import XCTest
@testable import NanoTeams

/// The Artifact Editor's two ways out, made the Role Editor's (2026-11-08 review):
/// - **Save** closes — and tells its caller which artifact is stored — only once the write
///   landed, and stays open with the reason when it did not;
/// - **Cancel / Escape** closes at once only when nothing would be lost, and asks otherwise.
///
/// The hole the review named: an artifact created from the Role Editor's Dependencies tab went
/// into the role's draft (`onSave` → `autoAssignNewArtifact`) the moment the sheet closed, before
/// its write — so a refused write left the role saved depending on an artifact that was never
/// stored. `onSave` now hears only `ArtifactEditorSheet.save`'s `.saved`, pinned on the source in
/// `ArtifactEditorSheetInvariantTests`; the outcomes are pinned here, as values.
@MainActor
final class ArtifactEditorSaveAndCloseTests: XCTestCase, @unchecked Sendable {

    private var writer: HeldTeamWriter!
    private var queue: TeamEditCommitQueue!
    /// What the `Task` running a Save answered — `nil` while it still waits.
    private var saveResult: ArtifactEditorSheet.SaveOutcome?

    private static let folder = WorkFolderLifecycle(generation: 1)

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        let writer = HeldTeamWriter()
        self.writer = writer
        queue = TeamEditCommitQueue(folder: writer)
        saveResult = nil
    }

    override func tearDown() async throws {
        writer?.releaseAll()
        queue = nil
        writer = nil
        try await super.tearDown()
    }

    // MARK: - Save waits for its write

    /// A new artifact's Save does not come back — so the sheet does not close and the role's draft
    /// does not name it — while its write is in flight.
    ///
    /// RED: answer `.saved` from `ArtifactEditorSheet.save` right after staging (the pre-fix
    /// `team = newTeam; onSave(saved)`) → `saveResult` is set while the writer still holds it.
    func testSave_ofANewArtifact_answersOnlyOnceTheWriteLanded() async throws {
        writer.isHolding = true
        let team = Self.team()
        let draft = Self.draft(name: "Threat Model")

        let save = Task {
            self.saveResult = await ArtifactEditorSheet.save(
                draft, mode: .create, session: Self.session(team), onto: team, through: self.queue)
        }
        await waitUntil("the write is in flight") { self.writer.calls.count == 1 }
        for _ in 0..<200 { await Task.yield() }
        XCTAssertNil(saveResult, "the Save came back — and the role's draft would have named it — before the write landed")

        writer.releaseAll()
        await save.value
        guard case .saved(let artifact) = saveResult else {
            return XCTFail("a landed write is a stored artifact, got \(String(describing: saveResult))")
        }
        XCTAssertEqual(artifact.name, "Threat Model")
        XCTAssertTrue(writer.calls.last?.team.artifacts.contains { $0.name == "Threat Model" } == true)
    }

    /// An edit is written the same way: description, icon and MIME type in ONE value.
    func testSave_ofAnEdit_writesEveryFieldInOneValue() async throws {
        var team = Self.team()
        let existing = try XCTUnwrap(ArtifactEditorMutations.applyCreate(to: &team, draft: Self.draft(name: "Notes")))
        var draft = ArtifactEditorMutations.Draft(existing)
        draft.description = "What changed and why."
        draft.icon = "star"
        draft.mimeType = "text/plain"

        let outcome = await ArtifactEditorSheet.save(
            draft, mode: .edit(existing), session: Self.session(team), onto: team, through: queue)

        guard case .saved = outcome else { return XCTFail("expected a stored edit, got \(outcome)") }
        XCTAssertEqual(writer.calls.count, 1, "one Save, one write")
        let written = try XCTUnwrap(writer.calls.last?.team.artifacts.first { $0.id == existing.id })
        XCTAssertEqual(written.description, "What changed and why.")
        XCTAssertEqual(written.icon, "star")
        XCTAssertEqual(written.mimeType, "text/plain")
    }

    // MARK: - Refusals stay in the sheet

    /// The Dependencies-tab hole: the write is refused, so the outcome is the reason — never
    /// `.saved` — and the caller has no artifact to put in the role's draft.
    func testSave_aRefusedWrite_answersWithTheReason_andNoArtifact() async {
        writer.outcomes = [.failed(reason: "Failed to persist work folder changes (teams.json): disk full")]
        let team = Self.team()

        let outcome = await ArtifactEditorSheet.save(
            Self.draft(name: "Threat Model"), mode: .create, session: Self.session(team), onto: team, through: queue)

        XCTAssertEqual(outcome, .refused("Failed to persist work folder changes (teams.json): disk full"))
    }

    /// The artifact was deleted elsewhere while the sheet was open: nothing is written.
    func testSave_ofAnArtifactThatIsGone_writesNothingAndSaysWhy() async throws {
        var team = Self.team()
        let gone = try XCTUnwrap(ArtifactEditorMutations.applyCreate(to: &team, draft: Self.draft(name: "Notes")))
        team.removeArtifact(gone.id)

        let outcome = await ArtifactEditorSheet.save(
            ArtifactEditorMutations.Draft(gone), mode: .edit(gone), session: Self.session(team), onto: team,
            through: queue)

        guard case .refused = outcome else { return XCTFail("expected a refusal, got \(outcome)") }
        XCTAssertTrue(writer.calls.isEmpty)
    }

    /// The sheet opened on one team; the editor shows another now. The artifact goes into
    /// neither, and the reason names the one the sheet opened on.
    func testSave_afterTheEditedTeamChanged_writesNothing() async {
        let opened = Self.team()
        let other = TeamTemplateFactory.empty(name: "Another Team")

        let outcome = await ArtifactEditorSheet.save(
            Self.draft(name: "Threat Model"), mode: .create, session: Self.session(opened), onto: other, through: queue)

        XCTAssertEqual(outcome, .refused(TeamEditCommitQueue.otherTeamReason(opened: Self.session(opened))))
        XCTAssertTrue(writer.calls.isEmpty)
    }

    /// The sheet opened in a folder a later open has ended.
    func testSave_afterAnotherFolderOpened_writesNothing() async {
        let team = Self.team()
        writer.endedLifecycles = [Self.folder]

        let outcome = await ArtifactEditorSheet.save(
            Self.draft(name: "Threat Model"), mode: .create, session: Self.session(team), onto: team, through: queue)

        XCTAssertEqual(outcome, .refused(TeamEditCommitQueue.folderChangedReason(teamName: team.name)))
        XCTAssertTrue(writer.calls.isEmpty)
    }

    // MARK: - Cancel / Escape

    func testAnUntouchedEdit_andAnUntouchedNewArtifact_closeWithoutAsking() throws {
        var team = Self.team()
        let existing = try XCTUnwrap(ArtifactEditorMutations.applyCreate(to: &team, draft: Self.draft(name: "Notes")))

        XCTAssertFalse(ArtifactEditorMutations.hasUnsavedChanges(ArtifactEditorMutations.Draft(existing), mode: .edit(existing)))
        XCTAssertFalse(ArtifactEditorMutations.hasUnsavedChanges(.new, mode: .create))
        XCTAssertEqual(ArtifactEditorMutations.openingDraft(for: .create), .new)
        XCTAssertEqual(ArtifactEditorMutations.openingDraft(for: .edit(existing)), ArtifactEditorMutations.Draft(existing))
    }

    /// A typed description, Escape → the sheet asks; the same through the shared policy.
    func testEscape_afterTypingADescription_asks() throws {
        var team = Self.team()
        let existing = try XCTUnwrap(ArtifactEditorMutations.applyCreate(to: &team, draft: Self.draft(name: "Notes")))
        var draft = ArtifactEditorMutations.Draft(existing)
        draft.description += " More."

        let dirty = ArtifactEditorMutations.hasUnsavedChanges(draft, mode: .edit(existing))
        XCTAssertTrue(dirty)
        XCTAssertEqual(EditorSheetClosePolicy.onCancel(hasUnsavedChanges: dirty, isSaving: false), .confirmDiscard)
    }

    /// Save trims the name, so trailing spaces alone would save nothing — and ask nothing.
    func testWhitespaceAroundTheName_isNoChange() throws {
        var team = Self.team()
        let existing = try XCTUnwrap(ArtifactEditorMutations.applyCreate(to: &team, draft: Self.draft(name: "Notes")))
        var draft = ArtifactEditorMutations.Draft(existing)
        draft.name = "  Notes \n"

        XCTAssertFalse(ArtifactEditorMutations.hasUnsavedChanges(draft, mode: .edit(existing)))
        draft.name = "   "
        XCTAssertFalse(ArtifactEditorMutations.hasUnsavedChanges(draft, mode: .create), "a blank name is the empty form")
    }

    /// Each field Save stores, changed alone, asks.
    ///
    /// RED: drop any one field from the comparison → its row fails here.
    func testEveryField_changedAlone_isAnUnsavedChange() throws {
        var team = Self.team()
        let existing = try XCTUnwrap(ArtifactEditorMutations.applyCreate(to: &team, draft: Self.draft(name: "Notes")))
        for (field, change) in Self.fieldChanges {
            var draft = ArtifactEditorMutations.Draft(existing)
            change(&draft)
            XCTAssertTrue(ArtifactEditorMutations.hasUnsavedChanges(draft, mode: .edit(existing)),
                          "a change to `\(field)` went unnoticed")
        }
    }

    /// The table above covers every property of the draft: a field added to it fails here until
    /// it gets a row — the decision the comparison would otherwise miss in silence.
    func testEveryPropertyOfTheDraft_isClassified() {
        let labels = Set(Mirror(reflecting: ArtifactEditorMutations.Draft.new).children.compactMap(\.label))
        XCTAssertEqual(labels, Set(Self.fieldChanges.map(\.field)))
    }

    // MARK: - Fixtures

    private static var fieldChanges: [(field: String, change: (inout ArtifactEditorMutations.Draft) -> Void)] { [
        ("name", { $0.name += " II" }),
        ("description", { $0.description += " More." }),
        ("icon", { $0.icon = "star" }),
        ("mimeType", { $0.mimeType = "text/plain" }),
    ] }

    private static func team() -> Team {
        TeamTemplateFactory.empty(name: "Artifact Save")
    }

    private static func draft(name: String) -> ArtifactEditorMutations.Draft {
        var draft = ArtifactEditorMutations.Draft.new
        draft.name = name
        return draft
    }

    /// What a sheet opened on `team` in `folder` captured.
    private static func session(_ team: Team) -> TeamEditCommitQueue.Session {
        TeamEditCommitQueue.Session(team: team, lifecycle: folder)
    }
}
