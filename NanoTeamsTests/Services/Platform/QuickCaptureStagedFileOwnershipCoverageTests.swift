import AppKit
import XCTest

@testable import NanoTeams

/// Wave 24 — which files a gesture is entitled to delete, and which file a cache key names.
///
/// `formState.draftID` names ONE `.nanoteams/staged/<id>/` directory that the task draft,
/// the answer draft, and every not-yet-handed-off queued message write into. Wave 23 gave
/// the queue its own directory at hand-off; the task draft and the answer still share one,
/// and `cancelDraft`'s answer fork deletes it wholesale.
@MainActor
final class QuickCaptureStagedFileOwnershipCoverageTests: XCTestCase {

    private var store: NTMSOrchestrator!
    private var controller: QuickCaptureController!
    private var workFolder: URL!
    private var outsideDir: URL!

    override func setUp() {
        super.setUp()
        QuickCaptureController.shared._testReset()
        workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-files-wf-\(UUID().uuidString)", isDirectory: true)
        outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-files-out-\(UUID().uuidString)", isDirectory: true)
        for dir in [workFolder!, outsideDir!] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        controller = nil
        store = nil
        for dir in [workFolder, outsideDir].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: dir)
        }
        workFolder = nil
        outsideDir = nil
        QuickCaptureController.shared._testReset()
        super.tearDown()
    }

    private func makeWired() async -> QuickCaptureController {
        let made = QuickCaptureController(formState: QuickCaptureFormState())
        store = await TestOrchestrator.make()
        await store.openWorkFolder(workFolder)
        made.store = store
        controller = made
        return made
    }

    /// A file OUTSIDE the work folder, so staging makes a real copy under
    /// `.nanoteams/staged/<draftID>/` rather than recording an in-folder reference.
    private func stageOutsideFile(_ name: String, draftID: UUID) throws -> StagedAttachment {
        let src = outsideDir.appendingPathComponent(name)
        try Data("payload".utf8).write(to: src)
        guard let staged = store.stageAttachment(url: src, draftID: draftID) else {
            throw XCTSkip("staging unavailable")
        }
        return staged
    }

    private func payload(taskID: Int) -> SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: "role_a", taskID: taskID, role: .softwareEngineer,
            roleDefinition: nil, question: "Which one?",
            messageContent: nil, thinking: nil, isChatMode: true)
    }

    // MARK: - Cancelling an answer

    /// The answer fork of `cancelDraft` deleted `.nanoteams/staged/<draftID>/` outright. That
    /// directory is not the answer's — the task draft the user is still composing writes into
    /// it too, and its `StagedAttachment` values (and the chips rendered from them) survive the
    /// delete untouched. So the panel goes on showing a file that is no longer on disk, and the
    /// first thing that notices is `finalizeAttachments`, at task-creation time, with nothing
    /// connecting the failure to the Escape key pressed minutes earlier.
    ///
    /// RED: restore `store?.discardStagedDraft(draftID: formState.draftID)` in the answer fork
    /// → the task draft's file is gone and this fails.
    func testCancellingAnAnswer_leavesTheTaskDraftsFilesOnDisk() async throws {
        let sut = await makeWired()
        let taskFile = try stageOutsideFile("brief.md", draftID: sut.formState.draftID)
        sut.formState.attachments = [taskFile]

        sut.formState.enterAnswerMode(payload: payload(taskID: 1))
        let answerFile = try stageOutsideFile("evidence.log", draftID: sut.formState.draftID)
        sut.formState.answerAttachments = [answerFile]
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskFile.url.path), "precondition")

        sut.cancelDraft()

        XCTAssertTrue(FileManager.default.fileExists(atPath: taskFile.url.path),
            "cancelling an answer is not a retraction of the task draft — its chip is still "
            + "on screen and it is still what a later submit will try to finalize")
        XCTAssertEqual(sut.formState.attachments, [taskFile],
            "unchanged: the fork never claimed to touch the task draft's list either")
    }

    /// Counter-test, so the fix cannot degenerate into "never delete anything": the answer's
    /// OWN staged copy is still discarded, because cancelling is what discards it.
    ///
    /// RED: drop the per-attachment removal → the answer's file survives and this fails.
    func testCancellingAnAnswer_stillDiscardsTheAnswersOwnFiles() async throws {
        let sut = await makeWired()
        sut.formState.enterAnswerMode(payload: payload(taskID: 1))
        let answerFile = try stageOutsideFile("evidence.log", draftID: sut.formState.draftID)
        sut.formState.answerAttachments = [answerFile]

        sut.cancelDraft()

        XCTAssertFalse(FileManager.default.fileExists(atPath: answerFile.url.path),
            "the cancelled answer's own staged copy has no other owner")
    }

    /// The sharper victim of the same delete: a saved answer draft for ANOTHER task. The user
    /// explicitly kept that content — `exitAnswerMode` snapshots it per task id — and its
    /// attachments live in the same shared directory, so cancelling an answer on task A took
    /// task B's files with it while B's draft entry stayed, still naming them.
    ///
    /// RED: restore the directory-wide delete → task B's file is gone and this fails.
    func testCancellingAnAnswer_leavesAnotherTasksSavedDraftIntact() async throws {
        let sut = await makeWired()

        sut.formState.enterAnswerMode(payload: payload(taskID: 7))
        let keptFile = try stageOutsideFile("for-task-7.png", draftID: sut.formState.draftID)
        sut.formState.answerText = "half-written answer"
        sut.formState.answerAttachments = [keptFile]
        sut.formState.exitAnswerMode()
        XCTAssertNotNil(sut.formState._testAnswerDrafts[7], "precondition: draft saved")

        sut.formState.enterAnswerMode(payload: payload(taskID: 8))
        sut.formState.answerAttachments = [try stageOutsideFile("for-task-8.log", draftID: sut.formState.draftID)]
        sut.cancelDraft()

        XCTAssertEqual(sut.formState._testAnswerDrafts[7]?.attachments, [keptFile],
            "precondition: the draft entry still names the file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFile.url.path),
            "a draft the user deliberately kept must not lose its files because a DIFFERENT "
            + "task's answer was cancelled")
    }

    /// An answer attachment that is an in-project file was never copied into staging — the
    /// `StagedAttachment` points at the user's own file. Removing it is `removeStagedAttachment`'s
    /// job to refuse, and the cancel path has to go through it rather than around it.
    ///
    /// RED: delete the user's file directly instead of routing through
    /// `store.removeStagedAttachment` → this fails.
    func testCancellingAnAnswer_neverDeletesAnInProjectFile() async throws {
        let sut = await makeWired()
        let real = workFolder.appendingPathComponent("notes.md")
        try Data("mine".utf8).write(to: real)
        guard let reference = store.stageAttachment(url: real, draftID: sut.formState.draftID) else {
            throw XCTSkip("staging unavailable")
        }
        XCTAssertTrue(reference.isProjectReference, "precondition: in-folder file is a reference")

        sut.formState.enterAnswerMode(payload: payload(taskID: 1))
        sut.formState.answerAttachments = [reference]
        sut.cancelDraft()

        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path),
            "this is the user's own file in their own project, not a staged copy")
    }

    // MARK: - The thumbnail cache key

    /// `thumbnail(size:)` caches process-wide by `stagedRelativePath`, which for an
    /// `isProjectReference` attachment is the path relative to the WORK FOLDER — so two
    /// projects that both keep `assets/icon.png` share one cache entry, and the second one
    /// attached renders the first one's picture. The relative path identifies a file only
    /// within the folder it is relative to; the cache outlives the folder.
    ///
    /// RED: key on `stagedRelativePath` again → both attachments return the first image and
    /// this fails.
    func testThumbnailCache_isKeyedByTheFileItNames_notItsFolderRelativePath() throws {
        let shared = "assets/icon-\(UUID().uuidString).png"
        let red = try writePNG(color: .red, named: "a.png")
        let blue = try writePNG(color: .blue, named: "b.png")
        let fromFolderA = try StagedAttachment(url: red, stagedRelativePath: shared, isProjectReference: true)
        let fromFolderB = try StagedAttachment(url: blue, stagedRelativePath: shared, isProjectReference: true)

        let first = fromFolderA.thumbnail(size: 24).tiffRepresentation
        let second = fromFolderB.thumbnail(size: 24).tiffRepresentation

        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second,
            "two different files, one relative path: the cache must not hand the second "
            + "attachment a picture of the first")
    }

    /// Counter-test: the cache still caches. Without this the fix could degenerate into a key
    /// that is unique per call, silently re-decoding from disk on every body evaluation —
    /// which is the cost the cache exists to avoid.
    ///
    /// RED: key on anything freshly generated per call (a UUID) → the two results are distinct
    /// instances and this fails.
    func testThumbnailCache_stillReturnsTheSameInstanceForTheSameFile() throws {
        let png = try writePNG(color: .green, named: "c.png")
        let attachment = try StagedAttachment(
            url: png, stagedRelativePath: "assets/c-\(UUID().uuidString).png", isProjectReference: true)

        let first = attachment.thumbnail(size: 24)
        let second = attachment.thumbnail(size: 24)

        XCTAssertTrue(first === second, "same file, same size — one decode")
    }

    private func writePNG(color: NSColor, named name: String) throws -> URL {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw XCTSkip("PNG encoding unavailable") }
        let url = outsideDir.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }
}
