import XCTest

@testable import NanoTeams

/// Every transition of the Work Folder Context editor's draft against the stored text
/// (`WorkFolderContextDraftSync`, 2026-11-13): typing, the page's own save, another writer's,
/// and the choice offered when the two collide.
final class WorkFolderContextDraftSyncTests: XCTestCase {

    // MARK: - Loading and typing

    func testANewSync_showsTheStoredText_andHasNothingToSave() {
        let sync = WorkFolderContextDraftSync(stored: "A Swift app.")
        XCTAssertEqual(sync.draft, "A Swift app.")
        XCTAssertEqual(sync.stored, "A Swift app.")
        XCTAssertFalse(sync.hasUnsavedEdits)
        XCTAssertNil(sync.textToSave)
        XCTAssertNil(sync.replacement)
    }

    func testAnEdit_isSavedTrimmed_asTheWriterStoresIt() {
        var sync = WorkFolderContextDraftSync(stored: "A")
        sync.edit("  A Swift app.\n")
        XCTAssertTrue(sync.hasUnsavedEdits)
        XCTAssertEqual(sync.textToSave, "A Swift app.")
    }

    func testWhitespaceAroundTheText_isNoEditToSave() {
        var sync = WorkFolderContextDraftSync(stored: "A Swift app.")
        sync.edit("A Swift app. ")
        XCTAssertFalse(sync.hasUnsavedEdits, "a trailing space not yet followed by more")
        XCTAssertNil(sync.textToSave)
        sync.edit("\n  A Swift app.\n\n")
        XCTAssertFalse(sync.hasUnsavedEdits)
    }

    func testAnEditUndoneBeforeTheDebounce_savesNothing() {
        var sync = WorkFolderContextDraftSync(stored: "abc")
        sync.edit("abcd")
        sync.edit("abc")
        XCTAssertNil(sync.textToSave)
    }

    func testClearingTheText_isAnEditToSave() {
        var sync = WorkFolderContextDraftSync(stored: "A Swift app.")
        sync.edit(" \n")
        XCTAssertEqual(sync.textToSave, "", "an emptied context is the person's to save")
    }

    // MARK: - The page's own save

    func testASave_isRecorded_andItsChangeIsNoNews() throws {
        var sync = WorkFolderContextDraftSync(stored: "abc")
        sync.edit("abcd")
        let text = try XCTUnwrap(sync.textToSave)
        sync.saved(text)
        XCTAssertEqual(sync.stored, "abcd")
        XCTAssertFalse(sync.hasUnsavedEdits)

        sync.storedTextChanged(to: "abcd")
        XCTAssertEqual(sync.draft, "abcd")
        XCTAssertNil(sync.replacement, "the page's own save is not another writer")
    }

    func testASave_keepsWhatWasTypedSince_andTheWhitespaceUnderTheCaret() throws {
        var sync = WorkFolderContextDraftSync(stored: "abc")
        sync.edit("abcd ")
        sync.saved(try XCTUnwrap(sync.textToSave))
        XCTAssertEqual(sync.draft, "abcd ", "the trimmed save does not take the space just typed")
        XCTAssertFalse(sync.hasUnsavedEdits, "and the indicator settles")

        sync.edit("abcd e")
        sync.storedTextChanged(to: "abcd")
        XCTAssertEqual(sync.draft, "abcd e", "the change of the save does not replace what was typed since")
        XCTAssertEqual(sync.textToSave, "abcd e", "which is saved next")
    }

    /// The save is recorded when the write returns, not recognised when it comes back. RED before
    /// 2026-11-13: the page compared every change with the last text it had saved, for good, so a
    /// later outside write of that same text was ignored and the draft stayed apart from it.
    func testAnOutsideWriteEqualToAnEarlierSave_isAdopted() throws {
        var sync = WorkFolderContextDraftSync(stored: "v1")
        sync.edit("v2")
        sync.saved(try XCTUnwrap(sync.textToSave))
        sync.storedTextChanged(to: "v2")
        sync.storedTextChanged(to: "v3")
        XCTAssertEqual(sync.draft, "v3", "another writer, with nothing unsaved: adopted")
        sync.storedTextChanged(to: "v2")
        XCTAssertEqual(sync.draft, "v2", "another writer writing the earlier text: adopted too")
        XCTAssertFalse(sync.hasUnsavedEdits)
    }

    /// The save and another writer's land in one view update, the other last: only theirs is seen.
    /// The person's text was stored and then replaced, and nothing was unsaved, so theirs is adopted.
    func testAnOutsideWriteLandingRightAfterTheSave_isAdopted() throws {
        var sync = WorkFolderContextDraftSync(stored: "old")
        sync.edit("mine")
        sync.saved(try XCTUnwrap(sync.textToSave))
        sync.storedTextChanged(to: "theirs")
        XCTAssertEqual(sync.draft, "theirs")
        XCTAssertNil(sync.replacement)
    }

    // MARK: - Another writer

    func testAnOutsideWrite_withNoUnsavedEdits_isAdopted() {
        var sync = WorkFolderContextDraftSync(stored: "old")
        sync.storedTextChanged(to: "new")
        XCTAssertEqual(sync.draft, "new")
        XCTAssertEqual(sync.stored, "new")
        XCTAssertNil(sync.replacement)
        XCTAssertFalse(sync.hasUnsavedEdits)
    }

    func testAnOutsideWrite_withOnlyWhitespaceTyped_isAdopted() {
        var sync = WorkFolderContextDraftSync(stored: "old")
        sync.edit("old ")
        sync.storedTextChanged(to: "new")
        XCTAssertEqual(sync.draft, "new", "a trailing space is no edit to protect")
        XCTAssertNil(sync.replacement)
    }

    /// RED before 2026-11-13: the outside write replaced the text under the caret and cancelled the
    /// save of what had been typed since the last one.
    func testAnOutsideWrite_whileEditsAreUnsaved_isOffered_andTheAutosaveWaits() {
        var sync = WorkFolderContextDraftSync(stored: "old")
        sync.edit("mine")
        sync.storedTextChanged(to: "theirs")
        XCTAssertEqual(sync.draft, "mine")
        XCTAssertEqual(sync.replacement, "theirs")
        XCTAssertEqual(sync.stored, "theirs")
        XCTAssertNil(sync.textToSave, "the autosave waits for the person's choice")
        sync.edit("mine, more")
        XCTAssertNil(sync.textToSave, "typing on does not save over the replacement either")
        XCTAssertEqual(sync.replacement, "theirs")
    }

    func testAnOutsideWriteOfTheDraftsOwnText_offersNothing() {
        var sync = WorkFolderContextDraftSync(stored: "old")
        sync.edit("same ")
        sync.storedTextChanged(to: "same")
        XCTAssertNil(sync.replacement, "the store now holds what the editor holds")
        XCTAssertEqual(sync.draft, "same ", "the draft is not touched")
        XCTAssertFalse(sync.hasUnsavedEdits)
    }

    func testANewerOutsideWrite_replacesTheOffer() {
        var sync = WorkFolderContextDraftSync(stored: "old")
        sync.edit("mine")
        sync.storedTextChanged(to: "theirs 1")
        sync.storedTextChanged(to: "theirs 2")
        XCTAssertEqual(sync.replacement, "theirs 2", "the offer is the text stored now")
        sync.takeReplacement()
        XCTAssertEqual(sync.draft, "theirs 2")
        XCTAssertNil(sync.textToSave)
    }

    func testAnOutsideWriteMatchingTheDraft_whileAnOfferWaits_withdrawsTheOffer() {
        var sync = WorkFolderContextDraftSync(stored: "old")
        sync.edit("mine")
        sync.storedTextChanged(to: "theirs")
        sync.storedTextChanged(to: "mine")
        XCTAssertNil(sync.replacement, "what the person has is stored; there is nothing to choose")
        XCTAssertEqual(sync.draft, "mine")
        XCTAssertNil(sync.textToSave)
    }

    // MARK: - The choice

    func testTakingTheReplacement_showsIt_andLeavesNothingToSave() {
        var sync = WorkFolderContextDraftSync(stored: "old")
        sync.edit("mine")
        sync.storedTextChanged(to: "theirs")
        sync.takeReplacement()
        XCTAssertEqual(sync.draft, "theirs")
        XCTAssertNil(sync.replacement)
        XCTAssertFalse(sync.hasUnsavedEdits)
        XCTAssertNil(sync.textToSave)
    }

    func testKeepingTheDraft_savesItOverTheReplacement() {
        var sync = WorkFolderContextDraftSync(stored: "old")
        sync.edit("mine")
        sync.storedTextChanged(to: "theirs")
        sync.keepDraft()
        XCTAssertNil(sync.replacement)
        XCTAssertEqual(sync.textToSave, "mine")
        sync.saved("mine")
        sync.storedTextChanged(to: "mine")
        XCTAssertEqual(sync.draft, "mine")
        XCTAssertFalse(sync.hasUnsavedEdits)
    }

    func testTakingWithNoOfferWaiting_changesNothing() {
        var sync = WorkFolderContextDraftSync(stored: "old")
        sync.edit("mine")
        let before = sync
        sync.takeReplacement()
        XCTAssertEqual(sync, before)
        sync.keepDraft()
        XCTAssertEqual(sync, before)
    }

    /// A failed write is not recorded (`updateWorkFolderContext` answers `.failed`): the edits stay
    /// unsaved, the next debounce writes them again, and an outside write is offered, not adopted.
    func testAnUnrecordedSave_leavesTheEditsUnsaved() {
        var sync = WorkFolderContextDraftSync(stored: "old")
        sync.edit("mine")
        XCTAssertEqual(sync.textToSave, "mine")
        XCTAssertTrue(sync.hasUnsavedEdits)
        XCTAssertEqual(sync.textToSave, "mine", "asking again asks for the same text")
        sync.storedTextChanged(to: "theirs")
        XCTAssertEqual(sync.replacement, "theirs")
        XCTAssertEqual(sync.draft, "mine")
    }
}
