import SwiftUI
import XCTest
@testable import NanoTeams

/// The Role Editor's two ways out, after the 2026-11-08 field report (a ticked tool, Save, the
/// sheet closed, `teams.json` unchanged):
/// - **Save** closes only once the write landed, and stays open with the reason when it did not;
/// - **Cancel / Escape** closes at once only when nothing would be lost, and asks otherwise.
///
/// The decisions are tested as values (`RoleEditorSheet.save`, `EditorSheetClosePolicy`); that the
/// sheet's buttons are wired to them is pinned on the source, the way
/// `ArtifactEditorSheetInvariantTests` pins its sheet — a `View`'s private actions have no other
/// seam a unit test can reach.
@MainActor
final class RoleEditorSaveAndCloseTests: XCTestCase, @unchecked Sendable {

    private var writer: HeldTeamWriter!
    private var queue: TeamEditCommitQueue!
    /// What the `Task` running a Save answered — `nil` while it still waits.
    private var saveResult: String??

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

    /// The sheet's Save does not return — so the sheet does not close — while the write carrying
    /// the ticked tool is still in flight.
    ///
    /// RED: answer from `RoleEditorSheet.save` right after the binding assignment (the pre-fix
    /// `if saveRole() { dismiss() }`) → `saveResult` is set while the writer still holds it.
    func testSave_returnsOnlyOnceTheWriteLanded() async throws {
        writer.isHolding = true
        let team = Self.team()
        let engineer = try XCTUnwrap(team.roles.first { !$0.isSupervisor })
        var draft = RoleEditorState.loaded(from: engineer)
        draft.selectedTools.insert(ToolNames.gitStatus)
        let binding = queue.binding(for: team, editedIn: Self.folder)

        let save = Task {
            self.saveResult = await RoleEditorSheet.save(
                draft, mode: .edit(engineer), session: Self.session(team), onto: binding.wrappedValue,
                through: self.queue)
        }
        await waitUntil("the first write is in flight") { self.writer.calls.count == 1 }
        for _ in 0..<200 { await Task.yield() }
        XCTAssertTrue(saveResult == nil, "the Save came back — and the sheet would have closed — before the write landed")

        writer.releaseAll()
        await save.value
        XCTAssertEqual(saveResult, .some(nil), "a landed write is a Save the sheet may close on")
        let written = writer.calls.last?.team.roles.first { $0.id == engineer.id }
        XCTAssertTrue(written?.toolIDs.contains(ToolNames.gitStatus) == true)
    }

    /// A refused write comes back as the reason, for the sheet to show while it stays open.
    func testSave_aRefusedWrite_answersWithTheReason() async throws {
        writer.outcomes = [.failed(reason: "Failed to persist work folder changes (teams.json): disk full")]
        let team = Self.team()
        let engineer = try XCTUnwrap(team.roles.first { !$0.isSupervisor })
        var draft = RoleEditorState.loaded(from: engineer)
        draft.selectedTools.insert(ToolNames.gitStatus)

        let failure = await RoleEditorSheet.save(
            draft, mode: .edit(engineer), session: Self.session(team),
            onto: queue.binding(for: team, editedIn: Self.folder).wrappedValue, through: queue)

        XCTAssertEqual(failure, "Failed to persist work folder changes (teams.json): disk full")
    }

    /// The role was deleted elsewhere while the sheet was open: nothing is written, and the sheet
    /// says so instead of closing as if it had saved.
    func testSave_ofARoleThatIsGone_writesNothingAndSaysWhy() async throws {
        let team = Self.team()
        var ghost = try XCTUnwrap(team.roles.first { !$0.isSupervisor })
        ghost.id = "deleted-elsewhere"

        let failure = await RoleEditorSheet.save(
            RoleEditorState.loaded(from: ghost), mode: .edit(ghost), session: Self.session(team),
            onto: queue.binding(for: team, editedIn: Self.folder).wrappedValue, through: queue)

        XCTAssertNotNil(failure)
        XCTAssertTrue(writer.calls.isEmpty, "a Save of a role that is gone must write nothing")
    }

    /// A new role is added and written the same way — and its Save, too, does not come back
    /// while the write is in flight.
    ///
    /// RED: answer create mode from `RoleEditorSheet.save` without awaiting the commit →
    /// `saveResult` is set while the writer still holds the write.
    func testSave_ofANewRole_addsItAndWaitsForTheWrite() async throws {
        writer.isHolding = true
        let team = Self.team()
        var draft = RoleEditorState()
        draft.roleName = "Reviewer"
        draft.rolePrompt = "Review the change."
        let binding = queue.binding(for: team, editedIn: Self.folder)

        let save = Task {
            self.saveResult = await RoleEditorSheet.save(
                draft, mode: .create, session: Self.session(team), onto: binding.wrappedValue, through: self.queue)
        }
        await waitUntil("the write is in flight") { self.writer.calls.count == 1 }
        for _ in 0..<200 { await Task.yield() }
        XCTAssertTrue(saveResult == nil, "the Save of a new role came back before its write landed")

        writer.releaseAll()
        await save.value
        XCTAssertEqual(saveResult, .some(nil))
        XCTAssertTrue(writer.calls.last?.team.roles.contains { $0.name == "Reviewer" } == true)
    }

    // MARK: - applySave

    func testApplySave_edit_replacesTheRole() throws {
        var team = Self.team()
        let engineer = try XCTUnwrap(team.roles.first { !$0.isSupervisor })
        var draft = RoleEditorState.loaded(from: engineer)
        draft.rolePrompt = "Edited."

        XCTAssertTrue(RoleEditorMutations.applySave(to: &team, editorState: draft, mode: .edit(engineer)))
        XCTAssertEqual(team.roles.first { $0.id == engineer.id }?.prompt, "Edited.")
    }

    func testApplySave_create_addsTheRole() {
        var team = Self.team()
        let before = team.roles.count
        var draft = RoleEditorState()
        draft.roleName = "Reviewer"
        draft.rolePrompt = "Review."

        XCTAssertTrue(RoleEditorMutations.applySave(to: &team, editorState: draft, mode: .create))
        XCTAssertEqual(team.roles.count, before + 1)
    }

    func testApplySave_editOfAMissingRole_refusesAndLeavesTheTeamAlone() throws {
        var team = Self.team()
        var ghost = try XCTUnwrap(team.roles.first { !$0.isSupervisor })
        ghost.id = "gone"
        let before = try JSONCoderFactory.makePersistenceEncoder().encode(team)

        XCTAssertFalse(RoleEditorMutations.applySave(
            to: &team, editorState: RoleEditorState.loaded(from: ghost), mode: .edit(ghost)))
        XCTAssertEqual(try JSONCoderFactory.makePersistenceEncoder().encode(team), before)
    }

    // MARK: - Cancel / Escape

    func testCancel_onACleanEdit_closes() {
        XCTAssertEqual(EditorSheetClosePolicy.onCancel(hasUnsavedChanges: false, isSaving: false), .close)
    }

    func testCancel_onADirtyEdit_asksFirst() {
        XCTAssertEqual(EditorSheetClosePolicy.onCancel(hasUnsavedChanges: true, isSaving: false), .confirmDiscard)
    }

    /// While a Save waits for its write there is nothing to cancel: closing would hide the
    /// outcome the person pressed Save to learn.
    func testCancel_whileSaving_doesNothing() {
        XCTAssertEqual(EditorSheetClosePolicy.onCancel(hasUnsavedChanges: true, isSaving: true), .ignore)
        XCTAssertEqual(EditorSheetClosePolicy.onCancel(hasUnsavedChanges: false, isSaving: true), .ignore)
    }

    /// The field report end to end on values: tick a tool, press Escape → the sheet asks.
    func testEscape_afterTickingATool_asks_andAfterUndoingIt_closes() throws {
        let engineer = try XCTUnwrap(Self.team().roles.first { !$0.isSupervisor })
        var draft = RoleEditorState.loaded(from: engineer)

        draft.selectedTools.insert(ToolNames.gitStatus)
        XCTAssertEqual(EditorSheetClosePolicy.onCancel(
            hasUnsavedChanges: draft.hasUnsavedChanges(mode: .edit(engineer)), isSaving: false), .confirmDiscard)

        draft.selectedTools.remove(ToolNames.gitStatus)
        XCTAssertEqual(EditorSheetClosePolicy.onCancel(
            hasUnsavedChanges: draft.hasUnsavedChanges(mode: .edit(engineer)), isSaving: false), .close)
    }

    // MARK: - The sheet is wired to these

    /// Escape reaches the sheet as its `.cancelAction` button — which must ask the policy, not
    /// dismiss. RED: restore `Button("Cancel") { dismiss() }`.
    func testTheCancelButton_andWithItEscape_goThroughTheGuard() throws {
        let code = try Self.sheetSource()
        let cancel = try XCTUnwrap(RatchetSourceScan.functionBody(after: "Button(\"Cancel\")", in: code))
        XCTAssertTrue(cancel.contains("requestClose()"), "Cancel must ask before closing")
        XCTAssertFalse(cancel.contains("dismiss()"), "Cancel must not dismiss on its own")
        let header = try XCTUnwrap(RatchetSourceScan.functionBody(after: "private var headerBar", in: code))
        XCTAssertTrue(header.contains(".keyboardShortcut(.cancelAction)"), "Escape must stay on Cancel")
        let requestClose = try XCTUnwrap(RatchetSourceScan.functionBody(after: "func requestClose()", in: code))
        XCTAssertTrue(requestClose.contains("EditorSheetClosePolicy.onCancel("))
    }

    /// The Save button runs the awaited save; the sheet closes only after it answered with no
    /// failure. RED: restore `Button("Save") { if saveRole() { dismiss() } }`.
    func testTheSaveButton_closesOnlyAfterTheAwaitedSaveAnsweredWithNoFailure() throws {
        let code = try Self.sheetSource()
        let button = try XCTUnwrap(RatchetSourceScan.functionBody(after: "Button(\"Save\")", in: code))
        XCTAssertFalse(button.contains("dismiss()"), "the Save button must not dismiss on its own")
        let save = try XCTUnwrap(RatchetSourceScan.functionBody(after: "private func save() async", in: code))
        let awaited = try XCTUnwrap(save.range(of: "await Self.save("))
        let checked = try XCTUnwrap(save.range(of: "if let failure"))
        let dismissed = try XCTUnwrap(save.range(of: "dismiss()"))
        XCTAssertLessThan(awaited.lowerBound, checked.lowerBound)
        XCTAssertLessThan(checked.lowerBound, dismissed.lowerBound)
    }

    // MARK: - Helpers

    private static func team() -> Team {
        TeamTemplateFactory.empty(name: "Editor Save")
    }

    /// What a sheet opened on `team` in `folder` captured.
    private static func session(_ team: Team) -> TeamEditCommitQueue.Session {
        TeamEditCommitQueue.Session(team: team, lifecycle: folder)
    }

    private static func sheetSource() throws -> String {
        let url = RatchetSourceScan.repoRoot
            .appendingPathComponent("NanoTeams/Views/Settings/TeamEditor/RoleEditorSheet.swift")
        return RatchetSourceScan.strippingLineComments(try String(contentsOf: url, encoding: .utf8))
    }
}
