import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for **Quick Capture attachment lifecycle** —
/// user drops a file onto the overlay, then either submits the task (file
/// persists as an attachment) or cancels (staged file is discarded).
///
/// Covered scenarios:
/// 1. Stage a file → it lands in `.nanoteams/internal/staged/{draftID}/`.
/// 2. Submit form with attachment → file moves to
///    `.nanoteams/tasks/{taskID}/attachments/` and `task.attachmentPaths`
///    references it.
/// 3. Cancel (discardStagedDraft) → draft dir is gone, task unaffected.
/// 4. Stage → remove individual attachment → file gone from staging.
/// 5. Name collision when two files share a name in the same draft.
/// 6. Submit with multiple attachments → all finalized, no overlap.
/// 7. Two draft directories coexist (user opens Quick Capture twice).
/// 8. In-project reference attachments are NOT copied (stay in place).
/// 9. Submit fails on finalization error → task removed (cleanup).
@MainActor
final class EndToEndQuickCaptureAttachmentLifecycleTests: NTMSOrchestratorTestBase {

    // MARK: - Helpers

    /// Creates a file outside the project root to simulate dropping from
    /// Finder / another app. Returns its URL.
    private func makeExternalFile(name: String, content: String = "hi") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    private func pathExists(_ relative: String) -> Bool {
        FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent(relative).path
        )
    }

    // MARK: - Scenario 1: Stage lands in draft dir

    func testStageAttachment_landsInStagingDraftDir() async throws {
        await sut.openWorkFolder(tempDir)
        let draftID = UUID()
        let source = try makeExternalFile(name: "notes.txt", content: "hello")

        let staged = sut.stageAttachment(url: source, draftID: draftID)
        XCTAssertNotNil(staged)
        XCTAssertFalse(staged?.isProjectReference ?? true)

        let expectedPath = ".nanoteams/internal/staged/\(draftID.uuidString)/notes.txt"
        XCTAssertTrue(pathExists(expectedPath),
                      "Staged file must land in the draft-specific staging dir")

        // Clean up external source
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    // MARK: - Scenario 2: Submit form finalizes attachments to task dir

    func testSubmitForm_withAttachment_finalizesToTaskAttachmentsDir() async throws {
        await sut.openWorkFolder(tempDir)
        let draftID = UUID()
        let source = try makeExternalFile(name: "design.png", content: "pngdata")

        guard let staged = sut.stageAttachment(url: source, draftID: draftID) else {
            return XCTFail("Staging failed")
        }

        let taskID = await sut.submitQuickCaptureForm(
            title: "My Task",
            supervisorTask: "Analyze this screenshot",
            teamID: nil,
            clippedTexts: [],
            attachments: [staged],
            draftID: draftID
        )
        XCTAssertNotNil(taskID, "Form must return new task ID")

        let attachmentPaths = sut.loadedTask(taskID!)?.attachmentPaths ?? []
        XCTAssertEqual(attachmentPaths.count, 1,
                       "Single attachment must be recorded on the task")
        XCTAssertTrue(attachmentPaths[0].contains(".nanoteams/tasks/\(taskID!)/attachments/"),
                      "Attachment path must live under the task's attachments dir")
        XCTAssertTrue(pathExists(attachmentPaths[0]),
                      "File must physically exist at the recorded path")

        // Clean up external source
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    func testSubmitForm_withAttachment_draftDirIsCleanedUp() async throws {
        await sut.openWorkFolder(tempDir)
        let draftID = UUID()
        let source = try makeExternalFile(name: "draft.txt", content: "x")
        guard let staged = sut.stageAttachment(url: source, draftID: draftID) else {
            return XCTFail("Staging failed")
        }

        let draftDirPath = ".nanoteams/internal/staged/\(draftID.uuidString)"
        XCTAssertTrue(pathExists(draftDirPath), "Precondition: draft dir exists")

        _ = await sut.submitQuickCaptureForm(
            title: "T", supervisorTask: "x", teamID: nil,
            clippedTexts: [], attachments: [staged], draftID: draftID
        )

        XCTAssertFalse(pathExists(draftDirPath),
                       "After successful submit, draft dir must be cleaned up")

        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    // MARK: - Scenario 3: Cancel / discardStagedDraft

    func testDiscardStagedDraft_removesDraftDir() async throws {
        await sut.openWorkFolder(tempDir)
        let draftID = UUID()
        let source = try makeExternalFile(name: "abandoned.txt")
        _ = sut.stageAttachment(url: source, draftID: draftID)

        let draftDirPath = ".nanoteams/internal/staged/\(draftID.uuidString)"
        XCTAssertTrue(pathExists(draftDirPath))

        sut.discardStagedDraft(draftID: draftID)

        XCTAssertFalse(pathExists(draftDirPath),
                       "discardStagedDraft must wipe the draft dir")

        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    func testDiscardStagedDraft_unknownDraftID_noError() async {
        await sut.openWorkFolder(tempDir)
        let unknown = UUID()

        sut.discardStagedDraft(draftID: unknown)

        XCTAssertNil(sut.lastErrorMessage,
                     "Discarding a non-existent draft must be a silent no-op")
    }

    // MARK: - Scenario 4: Remove individual attachment

    func testRemoveStagedAttachment_copiedFile_removesFromStaging() async throws {
        await sut.openWorkFolder(tempDir)
        let draftID = UUID()
        let source = try makeExternalFile(name: "x.txt")
        guard let staged = sut.stageAttachment(url: source, draftID: draftID) else {
            return XCTFail("Staging failed")
        }

        let stagedPath = staged.stagedRelativePath
        XCTAssertTrue(pathExists(stagedPath), "Staged file should exist before removal")

        sut.removeStagedAttachment(staged)

        XCTAssertFalse(pathExists(stagedPath),
                       "After removeStagedAttachment, file must be gone from staging")
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    /// Project references are not copies — `removeStagedAttachment` MUST
    /// skip deletion so the user's real file isn't wiped.
    func testRemoveStagedAttachment_projectReference_doesNotDeleteOriginal() async throws {
        await sut.openWorkFolder(tempDir)
        let inProject = tempDir
            .appendingPathComponent("README.md")
        try "keep me".data(using: .utf8)!.write(to: inProject)

        let draftID = UUID()
        guard let staged = sut.stageAttachment(url: inProject, draftID: draftID) else {
            return XCTFail("Staging failed")
        }
        XCTAssertTrue(staged.isProjectReference,
                      "A file inside the project root should be staged as a reference")

        sut.removeStagedAttachment(staged)

        XCTAssertTrue(FileManager.default.fileExists(atPath: inProject.path),
                      "Removing a project-reference attachment must NOT touch the original file")
    }

    // MARK: - Scenario 5: Name collision in same draft

    func testStageAttachment_sameNameTwice_addsSuffix() async throws {
        await sut.openWorkFolder(tempDir)
        let draftID = UUID()
        let s1 = try makeExternalFile(name: "dup.txt", content: "one")
        let s2 = try makeExternalFile(name: "dup.txt", content: "two")

        let first = sut.stageAttachment(url: s1, draftID: draftID)
        let second = sut.stageAttachment(url: s2, draftID: draftID)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.stagedRelativePath, second?.stagedRelativePath,
                          "Name collision in same draft must produce a suffixed filename")

        try? FileManager.default.removeItem(at: s1.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: s2.deletingLastPathComponent())
    }

    // MARK: - Scenario 6: Multiple attachments finalized independently

    func testSubmitForm_multipleAttachments_allFinalizedWithUniquePaths() async throws {
        await sut.openWorkFolder(tempDir)
        let draftID = UUID()
        let s1 = try makeExternalFile(name: "a.txt")
        let s2 = try makeExternalFile(name: "b.txt")
        let s3 = try makeExternalFile(name: "c.txt")

        guard
            let st1 = sut.stageAttachment(url: s1, draftID: draftID),
            let st2 = sut.stageAttachment(url: s2, draftID: draftID),
            let st3 = sut.stageAttachment(url: s3, draftID: draftID)
        else {
            return XCTFail("Staging failed")
        }

        let taskID = await sut.submitQuickCaptureForm(
            title: "Multi", supervisorTask: "x", teamID: nil,
            clippedTexts: [], attachments: [st1, st2, st3], draftID: draftID
        )

        let finalPaths = sut.loadedTask(taskID!)?.attachmentPaths ?? []
        XCTAssertEqual(finalPaths.count, 3)
        XCTAssertEqual(Set(finalPaths).count, 3,
                       "Finalized paths must be unique")

        for p in finalPaths {
            XCTAssertTrue(pathExists(p),
                          "All finalized files must physically exist")
        }

        for s in [s1, s2, s3] {
            try? FileManager.default.removeItem(at: s.deletingLastPathComponent())
        }
    }

    // MARK: - Scenario 7: Parallel drafts don't collide

    func testStageAttachment_twoDrafts_independent() async throws {
        await sut.openWorkFolder(tempDir)
        let draftA = UUID()
        let draftB = UUID()
        let fileA = try makeExternalFile(name: "a.txt")
        let fileB = try makeExternalFile(name: "b.txt")

        _ = sut.stageAttachment(url: fileA, draftID: draftA)
        _ = sut.stageAttachment(url: fileB, draftID: draftB)

        XCTAssertTrue(pathExists(".nanoteams/internal/staged/\(draftA.uuidString)/a.txt"))
        XCTAssertTrue(pathExists(".nanoteams/internal/staged/\(draftB.uuidString)/b.txt"))

        // Discarding one draft must not touch the other
        sut.discardStagedDraft(draftID: draftA)
        XCTAssertFalse(pathExists(".nanoteams/internal/staged/\(draftA.uuidString)"))
        XCTAssertTrue(pathExists(".nanoteams/internal/staged/\(draftB.uuidString)/b.txt"),
                      "Discarding draft A must not affect draft B's files")

        try? FileManager.default.removeItem(at: fileA.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: fileB.deletingLastPathComponent())
    }

    // MARK: - Scenario 8: In-project reference is not copied

    func testStageAttachment_inProjectFile_isReferenceNotCopy() async throws {
        await sut.openWorkFolder(tempDir)
        let inProject = tempDir
            .appendingPathComponent("Sources/Main.swift")
        try FileManager.default.createDirectory(
            at: inProject.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "print(\"hello\")".data(using: .utf8)!.write(to: inProject)

        let draftID = UUID()
        let staged = sut.stageAttachment(url: inProject, draftID: draftID)

        XCTAssertEqual(staged?.isProjectReference, true,
                       "File inside project root must be staged as reference (no copy)")
        XCTAssertFalse(
            pathExists(".nanoteams/internal/staged/\(draftID.uuidString)/Main.swift"),
            "Reference-style staging must NOT copy the file into the staging dir"
        )
    }
}
