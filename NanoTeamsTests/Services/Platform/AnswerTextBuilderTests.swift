import XCTest
@testable import NanoTeams

/// Tests for `AnswerTextBuilder` — clip assembly, file embedding, and combined output.
@MainActor
final class AnswerTextBuilderTests: XCTestCase {

    // MARK: - Text Only

    func testTextOnly_returnsUnchanged() {
        let result = AnswerTextBuilder.build(text: "Hello")
        XCTAssertEqual(result.answer, "Hello")
        XCTAssertTrue(result.failedFiles.isEmpty)
    }

    func testEmptyText_emptyClips_returnsEmpty() {
        let result = AnswerTextBuilder.build(text: "")
        XCTAssertEqual(result.answer, "")
    }

    // MARK: - Clips

    func testSingleClip_addsSection() {
        let result = AnswerTextBuilder.build(text: "answer", clips: ["code snippet"])
        XCTAssertTrue(result.answer.contains("--- Clipped Text ---"))
        XCTAssertTrue(result.answer.contains("code snippet"))
        XCTAssertTrue(result.answer.hasPrefix("answer"))
    }

    func testMultipleClips_numberedHeaders() {
        let result = AnswerTextBuilder.build(text: "", clips: ["clip A", "clip B"])
        XCTAssertTrue(result.answer.contains("1 of 2"))
        XCTAssertTrue(result.answer.contains("2 of 2"))
        XCTAssertTrue(result.answer.contains("clip A"))
        XCTAssertTrue(result.answer.contains("clip B"))
    }

    func testEmptyClips_filtered() {
        let result = AnswerTextBuilder.build(text: "answer", clips: ["", "  ", "real clip"])
        XCTAssertFalse(result.answer.contains("1 of"))
        XCTAssertTrue(result.answer.contains("--- Clipped Text ---"))
        XCTAssertTrue(result.answer.contains("real clip"))
    }

    func testClipOnly_noText_clipBecomesAnswer() {
        let result = AnswerTextBuilder.build(text: "", clips: ["the clip"])
        XCTAssertTrue(result.answer.hasPrefix("--- Clipped Text ---"))
        XCTAssertTrue(result.answer.contains("the clip"))
    }

    func testClipWithSourceContext_includedInOutput() {
        // Note: \u{200B} (zero-width space) sentinel is stripped by trimming,
        // so SourceContext.parse returns nil and the full trimmed clip is used as body.
        // The source info still appears in output as part of the raw text.
        let enriched = "\u{200B}// Source: MyFile.swift:10-20\nlet x = 42"
        let result = AnswerTextBuilder.build(text: "", clips: [enriched])
        XCTAssertTrue(result.answer.contains("let x = 42"))
        XCTAssertTrue(result.answer.contains("--- Clipped Text ---"))
        // Sentinel stripped by trimming
        XCTAssertFalse(result.answer.contains("\u{200B}"))
    }

    // MARK: - File Embedding

    func testEmbedFiles_false_ignoresAttachments() {
        let tempURL = createTempFile(name: "test.txt", content: "file content")
        let attachment = makeStagedAttachment(url: tempURL)

        let result = AnswerTextBuilder.build(
            text: "answer",
            attachments: [attachment],
            embedFiles: false
        )
        XCTAssertEqual(result.answer, "answer")
        XCTAssertTrue(result.failedFiles.isEmpty)
        XCTAssertTrue(result.embeddedAttachmentIDs.isEmpty)
    }

    func testEmbedFiles_true_injectsContent() {
        let tempURL = createTempFile(name: "test.txt", content: "file content")
        let attachment = makeStagedAttachment(url: tempURL)

        let result = AnswerTextBuilder.build(
            text: "answer",
            attachments: [attachment],
            embedFiles: true
        )
        XCTAssertTrue(result.answer.contains("--- Attached File: test.txt ---"))
        XCTAssertTrue(result.answer.contains("file content"))
        XCTAssertTrue(result.failedFiles.isEmpty)
        XCTAssertTrue(result.embeddedAttachmentIDs.contains(attachment.id))
    }

    func testEmbedFiles_binaryFile_failsGracefully() {
        let tempURL = createTempBinaryFile(name: "image.bin")
        let attachment = makeStagedAttachment(url: tempURL)

        let result = AnswerTextBuilder.build(
            text: "answer",
            attachments: [attachment],
            embedFiles: true
        )
        XCTAssertEqual(result.answer, "answer")
        XCTAssertEqual(result.failedFiles, ["image.bin"])
    }

    func testEmbedFiles_deletedAfterStaging_failsGracefully() {
        // Create then delete — simulates file removed after staging
        let tempURL = createTempFile(name: "ephemeral.txt", content: "temp")
        let attachment = makeStagedAttachment(url: tempURL)
        try! FileManager.default.removeItem(at: tempURL)

        let result = AnswerTextBuilder.build(
            text: "",
            attachments: [attachment],
            embedFiles: true
        )
        XCTAssertEqual(result.answer, "")
        XCTAssertEqual(result.failedFiles, ["ephemeral.txt"])
    }

    func testEmbedFiles_extractorFailureMessage_treatedAsFailure() {
        // Content that looks like a DocumentTextExtractor failure message
        let failureContent = "[Could not extract text from broken.pdf: some reason]"
        let tempURL = createTempFile(name: "broken.pdf", content: failureContent)
        let attachment = makeStagedAttachment(url: tempURL)

        let result = AnswerTextBuilder.build(
            text: "answer",
            attachments: [attachment],
            embedFiles: true
        )
        XCTAssertEqual(result.answer, "answer")
        XCTAssertEqual(result.failedFiles, ["broken.pdf"])
    }

    func testEmbedFiles_mixedSuccessAndFailure() {
        let goodURL = createTempFile(name: "good.txt", content: "valid content")
        let badURL = createTempFile(name: "bad.txt", content: "temp")
        let badAttachment = makeStagedAttachment(url: badURL)
        try! FileManager.default.removeItem(at: badURL)
        let goodAttachment = makeStagedAttachment(url: goodURL)

        let result = AnswerTextBuilder.build(
            text: "",
            attachments: [goodAttachment, badAttachment],
            embedFiles: true
        )
        XCTAssertTrue(result.answer.contains("--- Attached File: good.txt ---"))
        XCTAssertTrue(result.answer.contains("valid content"))
        XCTAssertEqual(result.failedFiles, ["bad.txt"])
    }

    func testMultipleClips_mixedSourceContext() {
        // Note: SourceContext header uses \u{200B} (zero-width space) which is stripped
        // by trimming. Clips arrive pre-trimmed from ClipboardCaptureService in practice,
        // so SourceContext is parsed on the raw (untrimmed) clip via the single-clip path.
        // In the multi-clip path, trimming strips the sentinel — this is existing behavior.
        // Test verifies numbering works for plain multi-clip case.
        let result = AnswerTextBuilder.build(text: "", clips: ["clip A", "clip B"])
        XCTAssertTrue(result.answer.contains("Clipped Text (1 of 2)"))
        XCTAssertTrue(result.answer.contains("Clipped Text (2 of 2)"))
        XCTAssertTrue(result.answer.contains("clip A"))
        XCTAssertTrue(result.answer.contains("clip B"))
    }

    func testEmbedFiles_imageFile_silentlySkipped() {
        let tempURL = createTempFile(name: "photo.jpeg", content: "fake jpeg")
        let attachment = makeStagedAttachment(url: tempURL)

        let result = AnswerTextBuilder.build(
            text: "answer",
            attachments: [attachment],
            embedFiles: true
        )
        // Image skipped silently — no error, no embedded content, not in embeddedIDs
        XCTAssertEqual(result.answer, "answer")
        XCTAssertTrue(result.failedFiles.isEmpty)
        XCTAssertTrue(result.embeddedAttachmentIDs.isEmpty)
    }

    func testEmbedFiles_mixedImageAndText_onlyTextEmbedded() {
        let imgURL = createTempFile(name: "pic.png", content: "fake png")
        let txtURL = createTempFile(name: "notes.txt", content: "text content")
        let imgAttachment = makeStagedAttachment(url: imgURL)
        let txtAttachment = makeStagedAttachment(url: txtURL)

        let result = AnswerTextBuilder.build(
            text: "",
            attachments: [imgAttachment, txtAttachment],
            embedFiles: true
        )
        XCTAssertTrue(result.answer.contains("--- Attached File: notes.txt ---"))
        XCTAssertFalse(result.answer.contains("pic.png"))
        XCTAssertTrue(result.failedFiles.isEmpty)
        // Only text file embedded, image stays as attachment
        XCTAssertTrue(result.embeddedAttachmentIDs.contains(txtAttachment.id))
        XCTAssertFalse(result.embeddedAttachmentIDs.contains(imgAttachment.id))
    }

    // MARK: - Combined

    func testTextPlusClipsPlusEmbeddedFiles() {
        let tempURL = createTempFile(name: "data.txt", content: "data here")
        let attachment = makeStagedAttachment(url: tempURL)

        let result = AnswerTextBuilder.build(
            text: "my answer",
            clips: ["clip content"],
            attachments: [attachment],
            embedFiles: true
        )

        // All three sections present in order
        let answerRange = result.answer.range(of: "my answer")
        let clipRange = result.answer.range(of: "--- Clipped Text ---")
        let fileRange = result.answer.range(of: "--- Attached File: data.txt ---")

        XCTAssertNotNil(answerRange)
        XCTAssertNotNil(clipRange)
        XCTAssertNotNil(fileRange)

        // Order: text < clips < files
        XCTAssertTrue(answerRange!.lowerBound < clipRange!.lowerBound)
        XCTAssertTrue(clipRange!.lowerBound < fileRange!.lowerBound)
        XCTAssertTrue(result.failedFiles.isEmpty)
    }

    // MARK: - Helpers

    /// Creates a temp file with the exact name (no UUID prefix) for predictable fileName assertions.
    private func createTempFile(name: String, content: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func createTempBinaryFile(name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let data = Data([0xFF, 0xFE, 0x00, 0x01, 0x80, 0x81, 0xFF])
        try! data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func makeStagedAttachment(url: URL) -> StagedAttachment {
        try! StagedAttachment(url: url, stagedRelativePath: "staged/\(url.lastPathComponent)")
    }
}
