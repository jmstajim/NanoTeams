import XCTest
import UniformTypeIdentifiers
@testable import NanoTeams

// MARK: - TempDirTestCase (shared setUp/tearDown)

class TempDirTestCase: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    func makeFile(name: String, content: String = "test") -> URL {
        let url = tempDir.appendingPathComponent(name, isDirectory: false)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func makeAttachment(name: String, content: String = "test") throws -> StagedAttachment {
        let url = makeFile(name: name, content: content)
        return try StagedAttachment(url: url, stagedRelativePath: "draft/\(name)")
    }
}

// MARK: - StagedAttachmentTests

final class StagedAttachmentTests: TempDirTestCase {

    // MARK: - Init & Properties

    func testFileName_extractedFromURL() throws {
        let url = makeFile(name: "design.png")
        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/design.png")
        XCTAssertEqual(sut.fileName, "design.png")
    }

    func testFileType_png() throws {
        let url = makeFile(name: "screenshot.png")
        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/screenshot.png")
        XCTAssertEqual(sut.fileType, UTType.png)
    }

    func testFileType_pdf() throws {
        let url = makeFile(name: "spec.pdf")
        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/spec.pdf")
        XCTAssertEqual(sut.fileType, UTType.pdf)
    }

    func testFileType_unknownExtension_notImage() throws {
        let url = makeFile(name: "data.xyzzy123")
        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/data.xyzzy123")
        // UTType may return a dynamic type for unknown extensions, but it should not be an image
        XCTAssertFalse(sut.isImage)
    }

    func testIsImage_trueForPNG() throws {
        let url = makeFile(name: "photo.png")
        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/photo.png")
        XCTAssertTrue(sut.isImage)
    }

    func testIsImage_falseForTXT() throws {
        let url = makeFile(name: "notes.txt")
        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/notes.txt")
        XCTAssertFalse(sut.isImage)
    }

    func testIsImage_falseWhenFileTypeNil() throws {
        let url = makeFile(name: "blob.xyzzy123")
        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/blob.xyzzy123")
        XCTAssertFalse(sut.isImage)
    }

    func testDisplaySize_nonEmpty() throws {
        let url = makeFile(name: "file.txt", content: "hello world")
        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/file.txt")
        XCTAssertFalse(sut.displaySize.isEmpty)
    }

    func testFileSize_matchesActualBytes() throws {
        let content = "exactly 20 bytes!!!!" // 20 bytes
        let url = makeFile(name: "sized.txt", content: content)
        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/sized.txt")
        let expectedSize = Int64(content.utf8.count)
        XCTAssertEqual(sut.fileSize, expectedSize)
    }

    func testInit_nonexistentFile_throws() {
        let url = tempDir.appendingPathComponent("nonexistent.txt", isDirectory: false)
        XCTAssertThrowsError(try StagedAttachment(url: url, stagedRelativePath: "draft/nonexistent.txt"))
    }

    // MARK: - Equality & Hashing

    func testEquality_byStagedRelativePathOnly() throws {
        let url1 = makeFile(name: "a.txt")
        let url2 = makeFile(name: "b.txt")
        let a = try StagedAttachment(url: url1, stagedRelativePath: "same/path.txt")
        let b = try StagedAttachment(url: url2, stagedRelativePath: "same/path.txt")
        XCTAssertEqual(a, b)
    }

    func testEquality_differentPaths() throws {
        let url = makeFile(name: "file.txt")
        let a = try StagedAttachment(url: url, stagedRelativePath: "draft1/file.txt")
        let b = try StagedAttachment(url: url, stagedRelativePath: "draft2/file.txt")
        XCTAssertNotEqual(a, b)
    }

    func testHashing_samePathCollapsesInSet() throws {
        let url1 = makeFile(name: "x.txt")
        let url2 = makeFile(name: "y.txt")
        let a = try StagedAttachment(url: url1, stagedRelativePath: "shared/path.txt")
        let b = try StagedAttachment(url: url2, stagedRelativePath: "shared/path.txt")
        let set: Set<StagedAttachment> = [a, b]
        XCTAssertEqual(set.count, 1)
    }

    func testID_equalsStagedRelativePath() throws {
        let url = makeFile(name: "doc.md")
        let path = "draft/doc.md"
        let sut = try StagedAttachment(url: url, stagedRelativePath: path)
        XCTAssertEqual(sut.id, path)
    }
}

// MARK: - AttachmentItemTests

final class AttachmentItemTests: TempDirTestCase {

    // MARK: - ID generation

    func testFileItemID_prefixedWithFile() throws {
        let attachment = try makeAttachment(name: "doc.txt")
        let item = AttachmentItem.file(attachment)
        XCTAssertTrue(item.id.hasPrefix("file-"))
        XCTAssertTrue(item.id.contains(attachment.id))
    }

    func testClipItemID_usesClipPrefix() {
        let item = AttachmentItem.clip(index: 3, text: "hello")
        XCTAssertEqual(item.id, "clip-3-hello")
    }

    func testClipItemIDs_uniqueForDifferentIndices() {
        let a = AttachmentItem.clip(index: 0, text: "same")
        let b = AttachmentItem.clip(index: 1, text: "same")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testClipItemIDs_uniqueForSameIndexDifferentText() {
        let a = AttachmentItem.clip(index: 0, text: "alpha")
        let b = AttachmentItem.clip(index: 0, text: "beta")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testClipItemID_truncatesLongText() {
        let longText = String(repeating: "a", count: 100)
        let item = AttachmentItem.clip(index: 0, text: longText)
        XCTAssertEqual(item.id, "clip-0-\(String(repeating: "a", count: 40))")
    }

    func testClipItemID_deterministicAcrossCalls() {
        let item1 = AttachmentItem.clip(index: 0, text: "hello")
        let item2 = AttachmentItem.clip(index: 0, text: "hello")
        XCTAssertEqual(item1.id, item2.id, "Same input must produce same ID")
    }

    func testFileItemID_noCollisionWithClipID() throws {
        let attachment = try makeAttachment(name: "clip-0-hello")
        let fileItem = AttachmentItem.file(attachment)
        let clipItem = AttachmentItem.clip(index: 0, text: "hello")
        XCTAssertNotEqual(fileItem.id, clipItem.id, "File and clip IDs must never collide")
    }

    // MARK: - Duplicate clips

    func testMerge_duplicateClips_getUniqueIDs() {
        let items = AttachmentItem.merge(clips: ["same", "same", "same"], files: [])
        XCTAssertEqual(items.count, 3)
        let ids = items.map(\.id)
        XCTAssertEqual(Set(ids).count, 3, "Duplicate clip texts must have unique IDs via index")
    }

    // MARK: - Merge

    func testMerge_emptyInputs() {
        let items = AttachmentItem.merge(clips: [], files: [])
        XCTAssertTrue(items.isEmpty)
    }

    func testMerge_clipsOnly() {
        let items = AttachmentItem.merge(clips: ["clip1", "clip2"], files: [])
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].id.hasPrefix("clip-0-"))
        XCTAssertTrue(items[1].id.hasPrefix("clip-1-"))
    }

    func testMerge_filesOnly() throws {
        let a = try makeAttachment(name: "a.txt")
        let b = try makeAttachment(name: "b.txt")
        let items = AttachmentItem.merge(clips: [], files: [a, b])
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].id.contains(a.id))
        XCTAssertTrue(items[1].id.contains(b.id))
    }

    func testMerge_clipsAppearBeforeFiles() throws {
        let file = try makeAttachment(name: "file.txt")
        let items = AttachmentItem.merge(clips: ["clip"], files: [file])
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].id.hasPrefix("clip-"))
        XCTAssertTrue(items[1].id.hasPrefix("file-"))
    }

    func testMerge_preservesClipOrder() {
        let items = AttachmentItem.merge(clips: ["first", "second", "third"], files: [])
        XCTAssertTrue(items[0].id.hasPrefix("clip-0-"))
        XCTAssertTrue(items[1].id.hasPrefix("clip-1-"))
        XCTAssertTrue(items[2].id.hasPrefix("clip-2-"))
    }

    func testMerge_preservesFileOrder() throws {
        let a = try makeAttachment(name: "a.txt")
        let b = try makeAttachment(name: "b.txt")
        let c = try makeAttachment(name: "c.txt")
        let items = AttachmentItem.merge(clips: [], files: [a, b, c])
        XCTAssertTrue(items[0].id.contains(a.id))
        XCTAssertTrue(items[1].id.contains(b.id))
        XCTAssertTrue(items[2].id.contains(c.id))
    }

    func testMerge_mixedContent_correctCount() throws {
        let files = [try makeAttachment(name: "x.txt"), try makeAttachment(name: "y.txt")]
        let items = AttachmentItem.merge(clips: ["a", "b", "c"], files: files)
        XCTAssertEqual(items.count, 5)
    }
}

// MARK: - StagedAttachmentThumbnailTests

final class StagedAttachmentThumbnailTests: TempDirTestCase {

    func testThumbnail_textFile_returnsSystemIcon() throws {
        let url = tempDir.appendingPathComponent("readme.txt", isDirectory: false)
        try? "hello".write(to: url, atomically: true, encoding: .utf8)
        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/readme.txt")

        let thumb = sut.thumbnail(size: 60)
        XCTAssertGreaterThan(thumb.size.width, 0)
        XCTAssertGreaterThan(thumb.size.height, 0)
    }

    func testThumbnail_pngImage_returnsSizedPreview() throws {
        // Create a minimal 10x10 red PNG
        let url = tempDir.appendingPathComponent("test.png", isDirectory: false)
        let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 10, pixelsHigh: 10,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        let pngData = bitmapRep.representation(using: .png, properties: [:])!
        try? pngData.write(to: url)

        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/test.png")
        XCTAssertTrue(sut.isImage)

        let thumb = sut.thumbnail(size: 60)
        XCTAssertLessThanOrEqual(thumb.size.width, 60)
        XCTAssertLessThanOrEqual(thumb.size.height, 60)
    }

    func testThumbnail_customSize_respectsMaxDimension() throws {
        let url = tempDir.appendingPathComponent("icon.png", isDirectory: false)
        let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 200, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        let pngData = bitmapRep.representation(using: .png, properties: [:])!
        try? pngData.write(to: url)

        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/icon.png")
        let thumb = sut.thumbnail(size: 40)
        // Landscape image: width=40, height=20 (aspect preserved)
        XCTAssertEqual(thumb.size.width, 40, accuracy: 1)
        XCTAssertEqual(thumb.size.height, 20, accuracy: 1)
    }

    func testThumbnail_portraitImage_heightMatchesSize() throws {
        let url = tempDir.appendingPathComponent("tall.png", isDirectory: false)
        let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 50, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        let pngData = bitmapRep.representation(using: .png, properties: [:])!
        try? pngData.write(to: url)

        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/tall.png")
        let thumb = sut.thumbnail(size: 60)
        // Portrait: width=30, height=60
        XCTAssertEqual(thumb.size.height, 60, accuracy: 1)
        XCTAssertEqual(thumb.size.width, 30, accuracy: 1)
    }

    func testThumbnail_defaultSize_is60() throws {
        let url = tempDir.appendingPathComponent("square.png", isDirectory: false)
        let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        let pngData = bitmapRep.representation(using: .png, properties: [:])!
        try? pngData.write(to: url)

        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/square.png")
        let thumb = sut.thumbnail()
        XCTAssertEqual(thumb.size.width, 60, accuracy: 1)
        XCTAssertEqual(thumb.size.height, 60, accuracy: 1)
    }

    func testThumbnail_corruptedImageFile_fallsBackToSystemIcon() throws {
        let url = tempDir.appendingPathComponent("broken.png", isDirectory: false)
        try? "not a real png".write(to: url, atomically: true, encoding: .utf8)
        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/broken.png")
        XCTAssertTrue(sut.isImage, "Extension says image but content is garbage")

        let thumb = sut.thumbnail(size: 60)
        // Should not crash — falls back to system icon
        XCTAssertGreaterThan(thumb.size.width, 0)
        XCTAssertGreaterThan(thumb.size.height, 0)
    }

    func testURL_preservedForQuickLook() throws {
        let url = tempDir.appendingPathComponent("doc.pdf", isDirectory: false)
        try? "pdf content".write(to: url, atomically: true, encoding: .utf8)
        let sut = try StagedAttachment(url: url, stagedRelativePath: "draft/doc.pdf")
        XCTAssertEqual(sut.url, url, "URL must be preserved for Quick Look preview")
    }
}

// MARK: - TaskManagementStateTests

@MainActor
final class TaskManagementStateTests: XCTestCase {

    var sut: TaskManagementState!

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        sut = TaskManagementState()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - sheetFormState.hasTaskDraftContent

    func testSheetFormState_hasTaskDraftContent_falseWhenEmpty() {
        XCTAssertFalse(sut.sheetFormState.hasTaskDraftContent)
    }

    func testSheetFormState_hasTaskDraftContent_falseWhenWhitespaceOnly() {
        sut.sheetFormState.title = "   "
        sut.sheetFormState.supervisorTask = "\n\t"
        XCTAssertFalse(sut.sheetFormState.hasTaskDraftContent)
    }

    func testSheetFormState_hasTaskDraftContent_trueWithTitle() {
        sut.sheetFormState.title = "Feature X"
        XCTAssertTrue(sut.sheetFormState.hasTaskDraftContent)
    }

    func testSheetFormState_hasTaskDraftContent_trueWithGoal() {
        sut.sheetFormState.supervisorTask = "Build it"
        XCTAssertTrue(sut.sheetFormState.hasTaskDraftContent)
    }

    func testSheetFormState_hasTaskDraftContent_trueWithClippedText() {
        sut.sheetFormState.clippedTexts = ["copied text"]
        XCTAssertTrue(sut.sheetFormState.hasTaskDraftContent)
    }

    func testSheetFormState_hasTaskDraftContent_trueWithAttachments() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake.txt")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let attachment = try StagedAttachment(url: url, stagedRelativePath: "draft/fake.txt")
        sut.sheetFormState.attachments = [attachment]
        XCTAssertTrue(sut.sheetFormState.hasTaskDraftContent)
    }

    func testSheetFormState_hasTaskDraftContent_falseWithWhitespaceClip() {
        sut.sheetFormState.clippedTexts = ["   "]
        XCTAssertFalse(sut.sheetFormState.hasTaskDraftContent)
    }

    // MARK: - sheetFormState.clearTaskDraft

    func testSheetFormState_clearTaskDraft_resetsAllFields() throws {
        sut.sheetFormState.title = "Title"
        sut.sheetFormState.supervisorTask = "Goal"
        sut.sheetFormState.selectedTeamID = "test_team"
        sut.sheetFormState.clippedTexts = ["clip"]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("f.txt")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        sut.sheetFormState.attachments = [try StagedAttachment(url: url, stagedRelativePath: "d/f.txt")]
        let oldDraftID = sut.sheetFormState.draftID

        sut.sheetFormState.clearTaskDraft()

        XCTAssertTrue(sut.sheetFormState.title.isEmpty)
        XCTAssertTrue(sut.sheetFormState.supervisorTask.isEmpty)
        XCTAssertNil(sut.sheetFormState.selectedTeamID)
        XCTAssertTrue(sut.sheetFormState.clippedTexts.isEmpty)
        XCTAssertTrue(sut.sheetFormState.attachments.isEmpty)
        XCTAssertNotEqual(sut.sheetFormState.draftID, oldDraftID, "clearTaskDraft should generate a new draftID")
    }

    // MARK: - filteredTasks

    private func makeTasks() -> [SidebarTaskItem] {
        let now = Date()
        return [
            SidebarTaskItem(id: 0, title: "Login Feature", status: .running, updatedAt: now.addingTimeInterval(-300)),
            SidebarTaskItem(id: 1, title: "Signup Flow", status: .done, updatedAt: now.addingTimeInterval(-100)),
            SidebarTaskItem(id: 2, title: "Login Bug Fix", status: .paused, updatedAt: now),
        ]
    }

    func testFilteredTasks_allFilter() {
        sut.taskFilter = .all
        let result = sut.filteredTasks(from: makeTasks())
        XCTAssertEqual(result.count, 3)
    }

    func testFilteredTasks_runningFilter() {
        sut.taskFilter = .running
        let result = sut.filteredTasks(from: makeTasks())
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.status != .done })
    }

    func testFilteredTasks_doneFilter() {
        sut.taskFilter = .done
        let result = sut.filteredTasks(from: makeTasks())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Signup Flow")
    }

    func testFilteredTasks_searchText() {
        sut.taskFilter = .all
        sut.taskSearchText = "Login"
        let result = sut.filteredTasks(from: makeTasks())
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.title.contains("Login") })
    }

    func testFilteredTasks_caseInsensitiveSearch() {
        sut.taskFilter = .all
        sut.taskSearchText = "LOGIN"
        let result = sut.filteredTasks(from: makeTasks())
        XCTAssertEqual(result.count, 2)
    }

    func testFilteredTasks_sortedByUpdatedAtDesc() {
        sut.taskFilter = .all
        let result = sut.filteredTasks(from: makeTasks())
        for i in 0..<(result.count - 1) {
            XCTAssertGreaterThanOrEqual(result[i].updatedAt, result[i + 1].updatedAt)
        }
    }

    func testFilteredTasks_emptyInput() {
        sut.taskFilter = .all
        let result = sut.filteredTasks(from: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - requestDelete / requestRename / cancelRename

    func testRequestDelete_setsStateCorrectly() {
        let id = 0
        sut.requestDelete(taskID: id)

        XCTAssertEqual(sut.taskToDelete, id)
        XCTAssertTrue(sut.isShowingDeleteConfirmation)
    }

    func testRequestRename_setsStateCorrectly() {
        let id = 0
        sut.requestRename(taskID: id, currentName: "Old Name")

        XCTAssertEqual(sut.taskToRename, id)
        XCTAssertEqual(sut.renameText, "Old Name")
    }

    func testCancelRename_clearsState() {
        sut.requestRename(taskID: Int(), currentName: "Something")
        sut.cancelRename()

        XCTAssertNil(sut.taskToRename)
        XCTAssertTrue(sut.renameText.isEmpty)
    }

    // MARK: - Combined filter + search

    func testFilteredTasks_searchIgnoresFilter() {
        let now = Date()
        let tasks = [
            SidebarTaskItem(id: 0, title: "Login Feature", status: .running, updatedAt: now),
            SidebarTaskItem(id: 0, title: "Login Bug", status: .done, updatedAt: now),
            SidebarTaskItem(id: 0, title: "Signup Flow", status: .paused, updatedAt: now),
        ]

        sut.taskFilter = .running
        sut.taskSearchText = "Login"

        // Search spans ALL tasks regardless of active filter
        let result = sut.filteredTasks(from: tasks)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.title.contains("Login") })
    }
}
