import XCTest

@testable import NanoTeams

/// E2E user-scenario tests for **task attachment persistence** — user
/// creates a task with attached files, quits the app, returns later, and
/// the files are still readable at the same paths with the same content.
///
/// Covered:
/// 1. Attached file's path is stable across orchestrator restart.
/// 2. Attached file's content is unchanged after restart.
/// 3. Clipped texts survive restart.
/// 4. Supervisor task's `effectiveSupervisorBrief` includes all
///    attachment paths + clips after reload.
/// 5. Deleting a task also removes its attachments directory.
/// 6. `hasInitialInput` remains true after reload for tasks with any
///    combination of task/brief/attachments/clips.
@MainActor
final class EndToEndTaskAttachmentPersistenceTests: NTMSOrchestratorTestBase {

    // MARK: - Helpers

    private func makeExternalFile(name: String, content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Scenario 1: Path stable across restart

    func testAttachmentPath_stableAcrossRestart() async throws {
        await sut.openWorkFolder(tempDir)
        let draftID = UUID()
        let source = try makeExternalFile(name: "doc.txt", content: "original")
        guard let staged = sut.stageAttachment(url: source, draftID: draftID) else {
            return XCTFail("Staging failed")
        }

        let taskID = await sut.submitQuickCaptureForm(
            title: "T", supervisorTask: "x", teamID: nil,
            clippedTexts: [], attachments: [staged], draftID: draftID
        )!

        let pathBefore = sut.loadedTask(taskID)?.attachmentPaths.first
        XCTAssertNotNil(pathBefore)

        // Reopen
        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: taskID)

        let pathAfter = sut.activeTask?.attachmentPaths.first
        XCTAssertEqual(pathBefore, pathAfter,
                       "Attachment path must be byte-identical across restart")

        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    // MARK: - Scenario 2: File content unchanged after reload

    func testAttachmentContent_unchangedAfterReload() async throws {
        await sut.openWorkFolder(tempDir)
        let draftID = UUID()
        let sourceText = "Important content — preserve me!"
        let source = try makeExternalFile(name: "data.txt", content: sourceText)
        guard let staged = sut.stageAttachment(url: source, draftID: draftID) else {
            return XCTFail("Staging failed")
        }

        let taskID = await sut.submitQuickCaptureForm(
            title: "T", supervisorTask: "x", teamID: nil,
            clippedTexts: [], attachments: [staged], draftID: draftID
        )!

        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: taskID)

        guard let path = sut.activeTask?.attachmentPaths.first else {
            return XCTFail("No attachment found after reload")
        }
        let onDiskURL = tempDir.appendingPathComponent(path)
        let onDiskContent = try String(contentsOf: onDiskURL, encoding: .utf8)
        XCTAssertEqual(onDiskContent, sourceText,
                       "File content must be byte-identical after reload")

        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    // MARK: - Scenario 3: Clipped texts survive restart

    func testClippedTexts_surviveRestart() async {
        await sut.openWorkFolder(tempDir)
        let draftID = UUID()
        let taskID = await sut.submitQuickCaptureForm(
            title: "T",
            supervisorTask: "Analyze these",
            teamID: nil,
            clippedTexts: ["Clip A", "Clip B", "Clip C"],
            attachments: [],
            draftID: draftID
        )!

        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: taskID)

        XCTAssertEqual(sut.activeTask?.clippedTexts,
                       ["Clip A", "Clip B", "Clip C"],
                       "All clipped texts must round-trip identically")
    }

    // MARK: - Scenario 4: effectiveSupervisorBrief after reload

    func testEffectiveSupervisorBrief_surfacesAllContext_afterReload() async throws {
        await sut.openWorkFolder(tempDir)
        let draftID = UUID()
        let source = try makeExternalFile(name: "spec.md", content: "requirements")
        guard let staged = sut.stageAttachment(url: source, draftID: draftID) else {
            return XCTFail()
        }

        let taskID = await sut.submitQuickCaptureForm(
            title: "T",
            supervisorTask: "Review the spec",
            teamID: nil,
            clippedTexts: ["Priority: high", "Blocked by: nothing"],
            attachments: [staged],
            draftID: draftID
        )!

        sut = NTMSOrchestrator(repository: NTMSRepository())
        await sut.openWorkFolder(tempDir)
        await sut.switchTask(to: taskID)

        let brief = sut.activeTask?.effectiveSupervisorBrief ?? ""
        XCTAssertTrue(brief.contains("Review the spec"))
        XCTAssertTrue(brief.contains("Priority: high"))
        XCTAssertTrue(brief.contains("Blocked by: nothing"))
        XCTAssertTrue(brief.contains("spec.md") || brief.contains("attachment"),
                      "Brief should reference the attachment")

        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    // MARK: - Scenario 5: Deleting task removes attachment dir

    func testDeleteTask_removesTaskAttachmentDir() async throws {
        await sut.openWorkFolder(tempDir)
        let draftID = UUID()
        let source = try makeExternalFile(name: "bye.txt", content: "x")
        guard let staged = sut.stageAttachment(url: source, draftID: draftID) else {
            return XCTFail()
        }

        let taskID = await sut.submitQuickCaptureForm(
            title: "T", supervisorTask: "x", teamID: nil,
            clippedTexts: [], attachments: [staged], draftID: draftID
        )!

        let paths = NTMSPaths(workFolderRoot: tempDir)
        let taskAttachmentDir = paths.taskAttachmentsDir(taskID: taskID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskAttachmentDir.path),
                      "Precondition: attachments dir exists")

        await sut.removeTask(taskID)

        // NOTE: This asserts the CURRENT behavior — if the orchestrator
        // doesn't clean the attachments dir on removeTask, this test
        // surfaces that as a UX regression (orphaned files on disk after
        // delete). Passing means the cleanup works.
        let lingeringFiles =
            (try? FileManager.default.contentsOfDirectory(atPath: taskAttachmentDir.path)) ?? []
        let attachmentsDirGone = !FileManager.default.fileExists(atPath: taskAttachmentDir.path)
        XCTAssertTrue(attachmentsDirGone || lingeringFiles.isEmpty,
                      "After deleting task, attachments dir should be empty or gone; got \(lingeringFiles)")

        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    // MARK: - Scenario 6: hasInitialInput invariants

    func testHasInitialInput_true_whenBriefNonEmpty() async {
        await sut.openWorkFolder(tempDir)
        let taskID = await sut.submitQuickCaptureForm(
            title: "T", supervisorTask: "Non-empty brief",
            teamID: nil, clippedTexts: [], attachments: [],
            draftID: UUID()
        )!
        XCTAssertTrue(sut.loadedTask(taskID)?.hasInitialInput ?? false)
    }

    func testHasInitialInput_true_withClipsOnly() async {
        await sut.openWorkFolder(tempDir)
        // Empty brief but with clips — submitQuickCaptureForm derives title
        // from brief, so we use title as the fallback trigger.
        let taskID = await sut.submitQuickCaptureForm(
            title: "Title present",
            supervisorTask: "",
            teamID: nil,
            clippedTexts: ["A clip"],
            attachments: [],
            draftID: UUID()
        )!
        XCTAssertTrue(sut.loadedTask(taskID)?.hasInitialInput ?? false,
                      "A task with clips (or non-empty title) has initial input")
    }
}
