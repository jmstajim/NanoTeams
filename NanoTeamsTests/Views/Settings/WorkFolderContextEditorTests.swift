import XCTest
@testable import NanoTeams

/// The Work Folder Context editor's draft for the app session (`WorkFolderContextEditor`): the
/// page shows and edits it; it outlives the page, so a choice the person has not made yet
/// survives a tab switch and a closed Settings window (review, 2026-11-13: held in the page's
/// `@State`, the edits behind the "replaced while you were editing" banner were dropped the
/// moment the person went to turn the agent's switch off). Its autosave sends the revision of the
/// text it knows is stored, so it never overwrites a write it has not seen, the page open or not.
@MainActor
final class WorkFolderContextEditorTests: XCTestCase {

    /// The store's side: per-folder stored texts, the open folder, and the writer's own
    /// revision check — what `NTMSOrchestrator.updateWorkFolderContext` does.
    private final class FakeStore {
        var stored: [UUID: String] = [:]
        var openFolder: UUID?
        var saves: [(text: String, expectedRevision: String?)] = []
        var failNextSave = false

        func save(_ text: String, expectedRevision: String?) -> NTMSOrchestrator.WorkFolderContextWrite {
            saves.append((text, expectedRevision))
            guard let folder = openFolder else { return .noFolder }
            if failNextSave {
                failNextSave = false
                return .failed(reason: "settings.json could not be written")
            }
            if let expectedRevision,
               ProjectSettings.contextRevision(of: stored[folder] ?? "") != expectedRevision {
                return .changedSinceRead
            }
            stored[folder] = text
            return .written
        }
    }

    private var store: FakeStore!
    private var sut: WorkFolderContextEditor!
    private var folderA: UUID!
    private var folderB: UUID!

    override func setUp() async throws {
        try await super.setUp()
        store = FakeStore()
        folderA = UUID()
        folderB = UUID()
        let store = store!
        sut = WorkFolderContextEditor(
            save: { text, revision in store.save(text, expectedRevision: revision) },
            openFolder: { store.openFolder.map { ($0, store.stored[$0] ?? "") } },
            debounce: .zero)
    }

    override func tearDown() async throws {
        sut = nil
        store = nil
        folderA = nil
        folderB = nil
        try await super.tearDown()
    }

    /// Folder `id` open with `text` stored, and the page showing it.
    private func open(_ id: UUID, stored text: String) {
        store.openFolder = id
        store.stored[id] = text
        sut.show(folderID: id, stored: text)
    }

    private func settle() async {
        await sut.pendingSave?.value
    }

    // MARK: - The autosave

    func testAnEdit_isSaved_withTheRevisionOfTheTextItKnewWasStored() async {
        open(folderA, stored: "Stored.")

        sut.edit("Mine. ")
        await settle()

        XCTAssertEqual(store.saves.map(\.text), ["Mine."])
        XCTAssertEqual(store.saves.first?.expectedRevision, ProjectSettings.contextRevision(of: "Stored."))
        XCTAssertEqual(store.stored[folderA], "Mine.")
        XCTAssertFalse(sut.sync.hasUnsavedEdits)
        XCTAssertEqual(sut.sync.draft, "Mine. ", "the whitespace under the caret stays")
    }

    func testTheEchoOfItsOwnSave_isNoNews() async {
        open(folderA, stored: "Stored.")
        sut.edit("Mine.")
        await settle()

        sut.show(folderID: folderA, stored: "Mine.")

        XCTAssertNil(sut.sync.replacement)
        XCTAssertNil(sut.sync.textToSave)
    }

    func testAFailedSave_leavesTheEditsUnsaved() async {
        open(folderA, stored: "Stored.")
        store.failNextSave = true

        sut.edit("Mine.")
        await settle()

        XCTAssertEqual(store.stored[folderA], "Stored.")
        XCTAssertTrue(sut.sync.hasUnsavedEdits)
    }

    func testWithNoFolderShown_nothingIsSaved() async {
        sut.show(folderID: nil, stored: "")

        sut.edit("Mine.")
        await settle()

        XCTAssertTrue(store.saves.isEmpty)
    }

    // MARK: - Another writer

    /// The page away, an agent's write landed, and the edits' debounce fired after it: the save
    /// is refused by the revision, and the agent's text is offered instead of being overwritten.
    func testAWriteTheEditorDidNotSee_isNeverOverwritten_andIsOfferedInstead() async {
        open(folderA, stored: "Stored.")
        sut.edit("Mine.")
        store.stored[folderA] = "The agent's text."

        await settle()

        XCTAssertEqual(store.stored[folderA], "The agent's text.")
        XCTAssertEqual(sut.sync.replacement, "The agent's text.")
        XCTAssertEqual(sut.sync.draft, "Mine.")
        XCTAssertNil(sut.sync.textToSave, "the autosave waits for the person's choice")
    }

    /// The review's case: a choice waits, the person goes to another tab (to turn the agent's
    /// switch off) or closes Settings, and comes back. The page is new; the draft and the offer
    /// are where they were.
    func testAWaitingChoice_survivesThePageLeavingAndComingBack() async {
        open(folderA, stored: "Stored.")
        sut.edit("Mine.")
        store.stored[folderA] = "The agent's text."
        sut.show(folderID: folderA, stored: "The agent's text.")
        XCTAssertEqual(sut.sync.replacement, "The agent's text.", "premise: the offer stands")

        // A new page appears and reports what is stored.
        sut.show(folderID: folderA, stored: "The agent's text.")
        await settle()

        XCTAssertEqual(sut.sync.draft, "Mine.")
        XCTAssertEqual(sut.sync.replacement, "The agent's text.")
        XCTAssertEqual(store.stored[folderA], "The agent's text.")
        XCTAssertTrue(store.saves.isEmpty, "nothing is saved until the person chooses")
    }

    func testKeepingMine_savesItOverTheReplacement_withTheReplacementsRevision() async {
        open(folderA, stored: "Stored.")
        sut.edit("Mine.")
        store.stored[folderA] = "The agent's text."
        sut.show(folderID: folderA, stored: "The agent's text.")

        sut.keepMine()
        await settle()

        XCTAssertEqual(store.stored[folderA], "Mine.")
        XCTAssertEqual(store.saves.last?.expectedRevision, ProjectSettings.contextRevision(of: "The agent's text."))
    }

    func testTakingTheNewText_dropsTheDraft_andSavesNothing() async {
        open(folderA, stored: "Stored.")
        sut.edit("Mine.")
        store.stored[folderA] = "The agent's text."
        sut.show(folderID: folderA, stored: "The agent's text.")

        sut.useReplacement()
        await settle()

        XCTAssertEqual(sut.sync.draft, "The agent's text.")
        XCTAssertNil(sut.sync.replacement)
        XCTAssertTrue(store.saves.isEmpty)
    }

    // MARK: - Another folder

    /// Edits not yet saved when the folder changes are never written into the folder opened
    /// next; they wait for their own folder and are saved when its page shows again.
    func testAFolderSwitch_neverSavesADraftIntoTheOtherFolder_andTheDraftWaitsForItsOwn() async {
        open(folderA, stored: "A.")
        sut.edit("Mine, for A.")
        open(folderB, stored: "B.")
        await settle()

        XCTAssertEqual(store.stored[folderB], "B.")
        XCTAssertEqual(sut.sync.draft, "B.")
        XCTAssertTrue(store.saves.isEmpty)

        open(folderA, stored: "A.")
        XCTAssertEqual(sut.sync.draft, "Mine, for A.")
        await settle()

        XCTAssertEqual(store.stored[folderA], "Mine, for A.")
        XCTAssertEqual(store.stored[folderB], "B.")
    }

    /// The page reports a folder the store no longer has open (a switch under a debounce): the
    /// save is not sent at all.
    func testASaveForAFolderNoLongerOpen_isNotSent() async {
        open(folderA, stored: "A.")
        sut.edit("Mine.")
        store.openFolder = folderB
        store.stored[folderB] = "A."

        await settle()

        XCTAssertTrue(store.saves.isEmpty, "the same text in the other folder would have passed the revision")
    }
}
