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
        XCTAssertTrue(result.answer.contains("## Clipped Text"))
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
        XCTAssertTrue(result.answer.contains("## Clipped Text"))
        XCTAssertTrue(result.answer.contains("real clip"))
    }

    func testClipOnly_noText_clipBecomesAnswer() {
        let result = AnswerTextBuilder.build(text: "", clips: ["the clip"])
        XCTAssertTrue(result.answer.hasPrefix("## Clipped Text"))
        XCTAssertTrue(result.answer.contains("the clip"))
    }

    func testClipWithSourceContext_includedInOutput() {
        // Note: \u{200B} (zero-width space) sentinel is stripped by trimming,
        // so SourceContext.parse returns nil and the full trimmed clip is used as body.
        // The source info still appears in output as part of the raw text.
        let enriched = "\u{200B}// Source: MyFile.swift:10-20\nlet x = 42"
        let result = AnswerTextBuilder.build(text: "", clips: [enriched])
        XCTAssertTrue(result.answer.contains("let x = 42"))
        XCTAssertTrue(result.answer.contains("## Clipped Text"))
        // Sentinel stripped by trimming
        XCTAssertFalse(result.answer.contains("\u{200B}"))
    }

    // MARK: - Skills

    private func skillClip(_ name: String, agent: String? = "Claude Code", origin: AgentSkillOrigin? = .project, body: String) -> String {
        SkillClip(name: name, agentLabel: agent, origin: origin, body: body).encoded()
    }

    func testSkillClip_emitsSkillSection_withFullBody() {
        let clip = skillClip("code-review", body: "# Review\nCheck for bugs.")
        let result = AnswerTextBuilder.build(text: "please help", clips: [clip])
        XCTAssertTrue(result.answer.contains("## Skill: code-review"))
        XCTAssertTrue(result.answer.contains("# Review\nCheck for bugs."))
        XCTAssertFalse(result.answer.contains("## Clipped Text"))
        // Sentinel consumed by parse — never reaches the LLM.
        XCTAssertFalse(result.answer.contains("\u{200B}"))
        XCTAssertTrue(result.answer.hasPrefix("please help"))
    }

    func testSkills_emittedBeforeClips() {
        let skill = skillClip("review", body: "skill body")
        let result = AnswerTextBuilder.build(text: "", clips: [skill, "plain clip"])
        let skillIdx = result.answer.range(of: "## Skill: review")!.lowerBound
        let clipIdx = result.answer.range(of: "## Clipped Text")!.lowerBound
        XCTAssertLessThan(skillIdx, clipIdx)
    }

    func testClipNumbering_excludesSkills() {
        let skill = skillClip("review", body: "skill body")
        let result = AnswerTextBuilder.build(text: "", clips: [skill, "clip A", "clip B"])
        // Numbering counts only the two non-skill clips.
        XCTAssertTrue(result.answer.contains("1 of 2"))
        XCTAssertTrue(result.answer.contains("2 of 2"))
        XCTAssertFalse(result.answer.contains("1 of 3"))
        XCTAssertFalse(result.answer.contains("## Skill: review\u{2014}"))
    }

    func testSkillPlusClipPlusEmbeddedFile_sectionOrder() {
        let tempURL = createTempFile(name: "data.txt", content: "file body")
        let attachment = makeStagedAttachment(url: tempURL)
        let skill = skillClip("review", body: "skill body")
        let result = AnswerTextBuilder.build(
            text: "user text",
            clips: [skill, "a clip"],
            attachments: [attachment],
            embedFiles: true
        )
        let textIdx = result.answer.range(of: "user text")!.lowerBound
        let skillIdx = result.answer.range(of: "## Skill: review")!.lowerBound
        let clipIdx = result.answer.range(of: "## Clipped Text")!.lowerBound
        let fileIdx = result.answer.range(of: "## Attached File: data.txt")!.lowerBound
        XCTAssertLessThan(textIdx, skillIdx)
        XCTAssertLessThan(skillIdx, clipIdx)
        XCTAssertLessThan(clipIdx, fileIdx)
    }

    func testEmptySkillBody_dropped() {
        let emptyBodySkill = "\u{200B}// Skill: review\n   \n  "
        let result = AnswerTextBuilder.build(text: "hi", clips: [emptyBodySkill])
        XCTAssertFalse(result.answer.contains("## Skill:"))
        XCTAssertEqual(result.answer, "hi")
    }

    func testMultipleSkills_eachGetsSection() {
        let a = skillClip("alpha", body: "body a")
        let b = skillClip("beta", body: "body b")
        let result = AnswerTextBuilder.build(text: "", clips: [a, b])
        XCTAssertTrue(result.answer.contains("## Skill: alpha"))
        XCTAssertTrue(result.answer.contains("## Skill: beta"))
    }

    func testSkillPlusRawSourceContextClip_skillStaysSkill_sourceDegradesToPlain() {
        // A raw SourceContext clip's sentinel is stripped by the clip trim, so it
        // renders as a plain "## Clipped Text"; the skill keeps its own section.
        let skill = skillClip("review", body: "skill body")
        let sourceClip = "\u{200B}// Source: main.swift:1-2\nlet x = 1"
        let result = AnswerTextBuilder.build(text: "", clips: [skill, sourceClip]).answer
        XCTAssertTrue(result.contains("## Skill: review"))
        XCTAssertTrue(result.contains("## Clipped Text"))
        XCTAssertTrue(result.contains("let x = 1"))
        XCTAssertFalse(result.contains("\u{200B}"))
    }

    func testTwoSkillsPlusThreeClips_numberingOverClipsOnly() {
        let a = skillClip("alpha", body: "a")
        let b = skillClip("beta", body: "b")
        let result = AnswerTextBuilder.build(text: "", clips: [a, "c1", b, "c2", "c3"]).answer
        XCTAssertTrue(result.contains("## Skill: alpha"))
        XCTAssertTrue(result.contains("## Skill: beta"))
        XCTAssertTrue(result.contains("1 of 3"))
        XCTAssertTrue(result.contains("3 of 3"))
        XCTAssertFalse(result.contains("of 5"))
    }

    func testClipSections_skillOnly_returnsSingleSection() {
        let sections = AnswerTextBuilder.clipSections(from: [skillClip("x", body: "y")])
        XCTAssertEqual(sections.count, 1)
        XCTAssertTrue(sections[0].hasPrefix("## Skill: x"))
    }

    func testClipSections_empty_returnsEmpty() {
        XCTAssertTrue(AnswerTextBuilder.clipSections(from: ["", "   "]).isEmpty)
    }

    func testClipSections_parity_withEffectiveSupervisorBrief() {
        let skill = skillClip("review", body: "skill body")
        let clips = [skill, "plain clip"]
        let sections = AnswerTextBuilder.clipSections(from: clips)
        let task = NTMSTask(id: 1, title: "T", supervisorTask: "", clippedTexts: [Clip].minting(clips))
        // With no supervisorTask and no attachments, the brief is exactly the
        // shared clip sections joined — parity by construction.
        XCTAssertEqual(task.effectiveSupervisorBrief, sections.joined(separator: "\n\n"))
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
        XCTAssertTrue(result.answer.contains("## Attached File: test.txt"))
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
        XCTAssertTrue(result.answer.contains("## Attached File: good.txt"))
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
        XCTAssertTrue(result.answer.contains("Clipped Text \u{2014} 1 of 2"))
        XCTAssertTrue(result.answer.contains("Clipped Text \u{2014} 2 of 2"))
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
        XCTAssertTrue(result.answer.contains("## Attached File: notes.txt"))
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
        let clipRange = result.answer.range(of: "## Clipped Text")
        let fileRange = result.answer.range(of: "## Attached File: data.txt")

        XCTAssertNotNil(answerRange)
        XCTAssertNotNil(clipRange)
        XCTAssertNotNil(fileRange)

        // Order: text < clips < files
        XCTAssertTrue(answerRange!.lowerBound < clipRange!.lowerBound)
        XCTAssertTrue(clipRange!.lowerBound < fileRange!.lowerBound)
        XCTAssertTrue(result.failedFiles.isEmpty)
    }

    // MARK: - embedSection(url:) primitive
    // The shared read+format primitive that both build() (above) and EmbedFilesButton use.

    func testEmbedSection_textFile_returnsEmbeddedSection() {
        let url = createTempFile(name: "note.txt", content: "hello world")
        guard case .embedded(let section) = AnswerTextBuilder.embedSection(url: url) else {
            return XCTFail("expected .embedded")
        }
        XCTAssertEqual(section, "## Attached File: note.txt\nhello world")
    }

    func testEmbedSection_imageExtension_returnsSkippedBinary() {
        let url = createTempFile(name: "pic.png", content: "not really a png")
        XCTAssertEqual(AnswerTextBuilder.embedSection(url: url), .skippedBinary,
                       "image extensions are skipped before any read — they belong as paths, not inline text")
    }

    func testEmbedSection_unreadableFile_returnsFailed() {
        let url = createTempFile(name: "gone.txt", content: "temp")
        try! FileManager.default.removeItem(at: url)
        XCTAssertEqual(AnswerTextBuilder.embedSection(url: url), .failed(fileName: "gone.txt"))
    }

    func testEmbedSection_unopenableDocument_returnsFailed() {
        // A `.pdf` holding non-PDF bytes: `PDFDocument(url:)` refuses to open it, so the
        // extractor reports a genuine failure. Named for what it actually exercises — the
        // previous name claimed the failure-message check, which this fixture never reaches.
        let url = createTempFile(name: "broken.pdf", content: "[Could not extract text from broken.pdf: reason]")
        XCTAssertEqual(AnswerTextBuilder.embedSection(url: url), .failed(fileName: "broken.pdf"))
    }

    func testEmbedSection_documentFormat_embedsItsExtractedText() throws {
        // The document branch, as distinct from the UTF-8 fallback below it: a `.rtf`
        // attachment must arrive as its DECODED text, not its markup.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("memo.rtf")
        try #"{\rtf1\ansi Decoded memo body}"#.write(to: url, atomically: true, encoding: .utf8)

        guard case .embedded(let section) = AnswerTextBuilder.embedSection(url: url) else {
            return XCTFail("expected .embedded")
        }
        XCTAssertTrue(section.contains("Decoded memo body"))
        XCTAssertFalse(section.contains("\\rtf1"), "markup must not reach the prompt")
    }

    func testEmbedSection_plainTextWhoseBodyLooksLikeAFailureMessage_isEmbedded() {
        // `.txt` is not a document format, so this file is read verbatim through the UTF-8
        // fallback — no extractor ever runs. Its BODY happening to read like an extraction
        // failure says nothing about whether the read succeeded, and the file must embed.
        let body = "[Could not extract text from other.pdf: PDF has no selectable text]"
        let url = createTempFile(name: "log.txt", content: body)
        XCTAssertEqual(
            AnswerTextBuilder.embedSection(url: url),
            .embedded(section: "## Attached File: log.txt\n\(body)"),
            "a successful verbatim read must not be judged by what the bytes happen to say"
        )
    }

    func testEmbedSection_uppercaseImageExtension_returnsSkippedBinary() {
        // The image-skip check lowercases the extension, so `.PNG` is skipped just like `.png`.
        let url = createTempFile(name: "PHOTO.PNG", content: "not a real png")
        XCTAssertEqual(AnswerTextBuilder.embedSection(url: url), .skippedBinary)
    }

    func testEmbedSection_emptyFile_embedsEmptyContent() {
        // A readable 0-byte file is a valid (if empty) embed — not a failure.
        let url = createTempFile(name: "empty.txt", content: "")
        XCTAssertEqual(AnswerTextBuilder.embedSection(url: url), .embedded(section: "## Attached File: empty.txt\n"))
    }

    func testEmbedSection_noExtension_embedsAsText() {
        // No extension → not an image, not a document format → UTF-8 read succeeds.
        let url = createTempFile(name: "README", content: "plain readme body")
        XCTAssertEqual(AnswerTextBuilder.embedSection(url: url), .embedded(section: "## Attached File: README\nplain readme body"))
    }

    func testEmbedSection_markdownFile_embedsRawMarkup() {
        // Source-like formats (.md) are NOT run through DocumentTextExtractor — the raw
        // markup is embedded verbatim (headings/backticks preserved).
        let md = "# Title\n\n- `code`\n"
        let url = createTempFile(name: "spec.md", content: md)
        XCTAssertEqual(AnswerTextBuilder.embedSection(url: url), .embedded(section: "## Attached File: spec.md\n\(md)"))
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
