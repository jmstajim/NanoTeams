import XCTest

@testable import NanoTeams

/// Where a Context-Capture (⌃⌥⌘K) result is filed once `ClipboardStagingPolicy` has decided
/// *what* it is.
///
/// Answer mode and task mode keep entirely separate buckets — `answerAttachments` /
/// `answerClippedTexts` versus `attachments` / `clippedTexts` — because a clip captured while
/// answering a role's question belongs to that answer, not to a half-written new task. Routing to
/// the wrong bucket is invisible at capture time: the card appears, and the content simply shows
/// up attached to something the user never meant.
///
/// This whole file was at 0% coverage: its only production entry point calls
/// `ClipboardCaptureService.captureSelection`, which posts a real ⌘C. Nothing here does — the
/// captured result is constructed directly.
@MainActor
final class QuickCaptureClipboardStagingTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private var formState: QuickCaptureFormState!
    private var controller: QuickCaptureController!
    /// Files to be staged must live OUTSIDE the work folder, or `stageAttachment` treats them as
    /// in-project references and skips the copy — a different branch from the one under test.
    private var sourceDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-clip-src-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        formState = QuickCaptureFormState()
        controller = QuickCaptureController(formState: formState)
        controller.store = sut
    }

    override func tearDown() async throws {
        if let sourceDir { try? FileManager.default.removeItem(at: sourceDir) }
        sourceDir = nil
        controller = nil
        formState = nil
        try await super.tearDown()
    }

    /// A work folder is required for `stageAttachment` to have anywhere to copy to.
    private func openWorkFolder() async {
        await sut.openWorkFolder(tempDir)
    }

    private func makeFile(_ name: String = "note.txt") throws -> URL {
        let url = sourceDir.appendingPathComponent(name)
        try Data("hello".utf8).write(to: url)
        return url
    }

    /// A file INSIDE the work folder (and outside `.nanoteams/`), which `stageAttachment` records
    /// as a reference at its own relative path rather than copying — so capturing it twice yields
    /// two equal `StagedAttachment`s and exercises the dedup branch.
    ///
    /// The root is symlink-resolved because `SandboxPathResolver.isWithin` standardizes but does
    /// NOT resolve symlinks, and the temp dir really is `/var/folders/…` → `/private/var/…`.
    private func makeInProjectFile(_ name: String = "inproject.txt") throws -> URL {
        let url = tempDir.resolvingSymlinksInPath().appendingPathComponent(name)
        try Data("hello".utf8).write(to: url)
        return url
    }

    private func capture(text: String? = nil, files: [URL] = []) -> ClipboardCaptureResult {
        ClipboardCaptureResult(text: text, fileURLs: files)
    }

    // MARK: - Text routing

    func testTaskMode_clipLandsInTheTaskBucket() {
        controller.stageCapturedContent(capture(text: "let x = 1"), to: UUID(), answerMode: false)

        XCTAssertEqual(formState.clippedTexts, ["let x = 1"])
        XCTAssertTrue(formState.answerClippedTexts.isEmpty,
                      "a task-mode capture must not leak into the answer draft")
    }

    func testAnswerMode_clipLandsInTheAnswerBucket() {
        controller.stageCapturedContent(capture(text: "let x = 1"), to: UUID(), answerMode: true)

        XCTAssertEqual(formState.answerClippedTexts, ["let x = 1"])
        XCTAssertTrue(formState.clippedTexts.isEmpty,
                      "an answer-mode capture must not land in the new-task draft")
    }

    /// Repeated captures accumulate rather than replace: the user builds up context across
    /// several selections before submitting once.
    func testRepeatedCaptures_accumulateInOrder() {
        controller.stageCapturedContent(capture(text: "first"), to: UUID(), answerMode: false)
        controller.stageCapturedContent(capture(text: "second"), to: UUID(), answerMode: false)

        XCTAssertEqual(formState.clippedTexts, ["first", "second"])
    }

    /// The two buckets are genuinely independent — switching modes mid-session must not merge
    /// or reorder what was already captured.
    func testCapturesInBothModes_staySeparate() {
        controller.stageCapturedContent(capture(text: "task"), to: UUID(), answerMode: false)
        controller.stageCapturedContent(capture(text: "answer"), to: UUID(), answerMode: true)

        XCTAssertEqual(formState.clippedTexts, ["task"])
        XCTAssertEqual(formState.answerClippedTexts, ["answer"])
    }

    // MARK: - Degenerate captures

    /// ⌘C on an empty selection must add nothing. An empty clip renders as a blank card the user
    /// can't explain and can only remove.
    func testEmptyCapture_addsNothing() {
        controller.stageCapturedContent(capture(), to: UUID(), answerMode: false)
        controller.stageCapturedContent(capture(text: ""), to: UUID(), answerMode: true)

        XCTAssertTrue(formState.clippedTexts.isEmpty)
        XCTAssertTrue(formState.answerClippedTexts.isEmpty)
    }

    // MARK: - Files

    func testFileCapture_stagesIntoTheTaskAttachments() async throws {
        await openWorkFolder()
        let file = try makeFile()

        controller.stageCapturedContent(capture(files: [file]), to: UUID(), answerMode: false)

        XCTAssertEqual(formState.attachments.map(\.fileName), ["note.txt"])
        XCTAssertTrue(formState.answerAttachments.isEmpty)
    }

    func testFileCapture_inAnswerMode_stagesIntoTheAnswerAttachments() async throws {
        await openWorkFolder()
        let file = try makeFile()

        controller.stageCapturedContent(capture(files: [file]), to: UUID(), answerMode: true)

        XCTAssertEqual(formState.answerAttachments.map(\.fileName), ["note.txt"])
        XCTAssertTrue(formState.attachments.isEmpty)
    }

    /// The files-win rule, end to end. With a Finder selection macOS also puts the paths on the
    /// pasteboard as `.string`, so a fall-through would attach the file AND clip its raw path.
    func testCaptureCarryingBothFilesAndText_attachesOnlyTheFile() async throws {
        await openWorkFolder()
        let file = try makeFile()

        controller.stageCapturedContent(
            capture(text: file.path, files: [file]), to: UUID(), answerMode: false)

        XCTAssertEqual(formState.attachments.count, 1)
        XCTAssertTrue(formState.clippedTexts.isEmpty, "the path-string must not become a clip")
    }

    /// Re-capturing a file that is ALREADY attached must neither duplicate the card nor raise an
    /// error banner. The count used to be derived from how many items were appended, so a
    /// deduped file was indistinguishable from one that failed to stage and the user got
    /// "1 of 1 files could not be attached." for doing nothing wrong.
    ///
    /// The file has to be IN-PROJECT for this to be the duplicate case at all: an in-project
    /// capture is stored as a reference at its own deterministic relative path, so two captures
    /// of it produce equal `StagedAttachment`s. A file from outside the work folder is COPIED
    /// under a uniquified name each time (`uniqueFileURL`), so the second capture is a genuinely
    /// distinct attachment — which the test below pins so the two paths can't be conflated.
    func testRecapturingAnInProjectFile_neitherDuplicatesNorWarns() async throws {
        await openWorkFolder()
        let file = try makeInProjectFile()
        let draft = UUID()

        controller.stageCapturedContent(capture(files: [file]), to: draft, answerMode: false)
        sut.lastErrorMessage = nil
        controller.stageCapturedContent(capture(files: [file]), to: draft, answerMode: false)

        XCTAssertEqual(formState.attachments.count, 1)
        XCTAssertNil(sut.lastErrorMessage, "got: \(sut.lastErrorMessage ?? "nil")")
    }

    /// The counterpart, and the reason the test above has to be specific about WHERE the file
    /// lives: an external file is copied into the draft under a fresh name, so re-capturing it is
    /// a second real attachment rather than a duplicate. Neither capture may warn.
    func testRecapturingAnExternalFile_attachesASecondCopyWithoutWarning() async throws {
        await openWorkFolder()
        let file = try makeFile()
        let draft = UUID()

        controller.stageCapturedContent(capture(files: [file]), to: draft, answerMode: false)
        sut.lastErrorMessage = nil
        controller.stageCapturedContent(capture(files: [file]), to: draft, answerMode: false)

        XCTAssertEqual(formState.attachments.count, 2,
                       "the repository uniquifies the destination name, so these are distinct")
        XCTAssertNil(sut.lastErrorMessage, "got: \(sut.lastErrorMessage ?? "nil")")
    }

    /// A file that genuinely cannot be staged must still be reported — the fix above must not
    /// have silenced real failures along with the false ones.
    func testUnstageableFile_reportsAnError() async {
        await openWorkFolder()
        let missing = sourceDir.appendingPathComponent("gone.txt")

        controller.stageCapturedContent(capture(files: [missing]), to: UUID(), answerMode: false)

        XCTAssertTrue(formState.attachments.isEmpty)
        XCTAssertEqual(sut.lastErrorMessage, "1 of 1 files could not be attached.")
    }

    // MARK: - No orchestrator

    /// The controller outlives the orchestrator on a work-folder switch. With no store there is
    /// nothing to stage into, so a capture carrying files must fall back to the text rather than
    /// silently dropping the user's ⌃⌥⌘K.
    func testWithoutAStore_filesFallBackToTheText() async throws {
        await openWorkFolder()
        let file = try makeFile()
        controller.store = nil

        controller.stageCapturedContent(
            capture(text: "fallback", files: [file]), to: UUID(), answerMode: false)

        XCTAssertEqual(formState.clippedTexts, ["fallback"])
        XCTAssertTrue(formState.attachments.isEmpty)
    }

    func testWithoutAStore_aTextOnlyCaptureStillWorks() {
        controller.store = nil

        controller.stageCapturedContent(capture(text: "note"), to: UUID(), answerMode: true)

        XCTAssertEqual(formState.answerClippedTexts, ["note"])
    }
}
