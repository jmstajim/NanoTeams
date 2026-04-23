import XCTest
import PDFKit

@testable import NanoTeams

/// Integration tests: read_file and read_lines tools with document formats.
final class ReadFileDocumentTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("ReadFileDocumentTests_\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fm.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        runtime = run
        context = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - read_file with PDF

    func testReadFile_pdf_returnsExtractedText() throws {
        let pdfURL = try createPDFWithText("Hello from PDF via read_file")

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"\(pdfURL.lastPathComponent)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Hello from PDF via read_file"))
        XCTAssertTrue(results[0].outputJSON.contains("extracted_text"))
    }

    // MARK: - read_file with RTF

    func testReadFile_rtf_returnsExtractedText() throws {
        let rtfURL = tempDir.appendingPathComponent("test.rtf")
        try #"{\rtf1\ansi RTF content for read_file test}"#
            .write(to: rtfURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"test.rtf\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("RTF content for read_file test"))
    }

    // MARK: - read_file with HTML — raw source (tags preserved for editing)

    func testReadFile_html_returnsRawSourceWithTags() throws {
        // HTML is a source format for a coding tool. `read_file` must return
        // the verbatim markup so the LLM can edit `<p>`, `<div>`, attributes,
        // `<script>`, etc. Earlier builds stripped tags via NSAttributedString
        // — that was wrong for editing workflows.
        let htmlURL = tempDir.appendingPathComponent("page.html")
        let source = "<html><body><p class=\"hero\">HTML paragraph</p></body></html>"
        try source.write(to: htmlURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"page.html\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("<p class=\\\"hero\\\">"),
                      "HTML tags must be preserved verbatim: \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("HTML paragraph"),
                      "body text must still be present: \(results[0].outputJSON)")
    }

    func testReadFile_css_returnsRawSource() throws {
        // CSS is source — braces, selectors, and declarations must survive.
        let cssURL = tempDir.appendingPathComponent("style.css")
        let source = ".hero { color: red; font-size: 16px; }"
        try source.write(to: cssURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"style.css\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains(".hero"))
        XCTAssertTrue(results[0].outputJSON.contains("color: red"))
    }

    func testReadFile_js_returnsRawSource() throws {
        let jsURL = tempDir.appendingPathComponent("app.js")
        let source = "function greet(name) { return `Hello, ${name}!`; }"
        try source.write(to: jsURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"app.js\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("function greet"))
        XCTAssertTrue(results[0].outputJSON.contains("${name}"))
    }

    func testReadFile_oversizeHTML_truncatesViaMaxBytesWithTruncatedMeta() throws {
        // HTML now goes through the raw-read path (FileReadHandlers ReadFileTool
        // ~line 101-114), which applies the per-call `max_bytes` cap (default
        // 200_000) and sets `meta.truncated = true`. This is a different code
        // path than the extractor's `maxExtractionBytes` marker — pin both.
        let htmlURL = tempDir.appendingPathComponent("big.html")
        let oversize = String(repeating: "a", count: 250_000)
        let source = "<html><body><pre>" + oversize + "</pre></body></html>"
        try source.write(to: htmlURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"big.html\", \"max_bytes\": 200000}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("\"truncated\" : true")
                      || results[0].outputJSON.contains("\"truncated\":true"),
                      "oversize HTML must set meta.truncated: \(String(results[0].outputJSON.prefix(200)))")
        // The opening `<html><body><pre>` must still be present — truncation
        // cuts from the tail, not the head.
        XCTAssertTrue(results[0].outputJSON.contains("<html>") || results[0].outputJSON.contains("<pre>"),
                      "head of HTML source must survive truncation")
    }

    func testReadFile_mixedCaseHTMLExtension_stillReadsAsRawSource() throws {
        // Regression pin: both `isSupported` (DocumentTextExtractor.isSupported)
        // and the handler's routing lowercase the extension. If a future
        // refactor drops `.lowercased()` on either side, `.HTML` / `.HTM`
        // would silently start hitting the extractor again — this test fails
        // loudly in that scenario.
        let upperURL = tempDir.appendingPathComponent("page.HTML")
        try "<html><body><p>upper</p></body></html>"
            .write(to: upperURL, atomically: true, encoding: .utf8)
        let htmURL = tempDir.appendingPathComponent("legacy.HTM")
        try "<p>legacy</p>"
            .write(to: htmURL, atomically: true, encoding: .utf8)

        for path in ["page.HTML", "legacy.HTM"] {
            let call = StepToolCall(
                name: "read_file",
                argumentsJSON: "{\"path\": \"\(path)\"}"
            )
            let results = runtime.executeAll(context: context, toolCalls: [call])
            XCTAssertFalse(results[0].isError, "read_file on \(path) errored: \(results[0].outputJSON)")
            XCTAssertTrue(results[0].outputJSON.contains("<p>"),
                          "mixed-case \(path) must come back as raw source with tags: \(results[0].outputJSON)")
        }
    }

    func testReadFile_xml_returnsRawSourceNotExtracted() throws {
        // XML is not in supportedReadExtensions — must come back with tags intact.
        let xmlURL = tempDir.appendingPathComponent("config.xml")
        let source = "<?xml version=\"1.0\"?><config><key>value</key></config>"
        try source.write(to: xmlURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"config.xml\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("<config>"))
        // The wire encoder may escape `/` as `\/` in JSON — accept either form.
        let json = results[0].outputJSON
        XCTAssertTrue(json.contains("</key>") || json.contains("<\\/key>"),
                      "XML closing tag must be preserved verbatim: \(json)")
    }

    // MARK: - read_file with plain text (unchanged behavior)

    func testReadFile_plainText_stillWorksAsUTF8() throws {
        let txtURL = tempDir.appendingPathComponent("plain.txt")
        try "Just plain text".write(to: txtURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"plain.txt\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Just plain text"))
        // Plain text should NOT have "extracted_text" encoding
        XCTAssertFalse(results[0].outputJSON.contains("extracted_text"))
    }

    // MARK: - read_lines with PDF

    func testReadLines_pdf_returnsLineRange() throws {
        // Create a multi-line PDF
        let lines = (1...10).map { "Line number \($0)" }.joined(separator: "\n")
        let pdfURL = try createPDFWithText(lines)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: """
            {"path": "\(pdfURL.lastPathComponent)", "start_line": 2, "end_line": 4}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        // Should contain lines 2-4
        XCTAssertTrue(results[0].outputJSON.contains("Line number"))
    }

    // MARK: - read_file with XLSX

    func testReadFile_xlsx_returnsMarkdownTable() throws {
        let xlsxURL = try createTestXLSX()

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"\(xlsxURL.lastPathComponent)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Alice"))
        XCTAssertTrue(results[0].outputJSON.contains("|"))
    }

    // MARK: - read_file with DOCX / ODT / PPTX / RTFD / .doc

    func testReadFile_docx_returnsExtractedText() throws {
        let docxURL = try makeDOCX(
            at: "report.docx",
            body: "<w:p><w:r><w:t>Hello from DOCX read_file</w:t></w:r></w:p>"
        )

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"\(docxURL.lastPathComponent)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Hello from DOCX read_file"))
        XCTAssertTrue(results[0].outputJSON.contains("extracted_text"))
    }

    func testReadFile_odt_returnsExtractedText() throws {
        let odtURL = try makeODT(
            at: "memo.odt",
            body: "<text:p>Hello from ODT read_file</text:p>"
        )

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"\(odtURL.lastPathComponent)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Hello from ODT read_file"))
        XCTAssertTrue(results[0].outputJSON.contains("extracted_text"))
    }

    func testReadFile_pptx_returnsExtractedText() throws {
        let pptxURL = try makePPTX(at: "deck.pptx", slides: [
            "First slide intro",
            "Second slide UNIQUEPPTX content",
        ])

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"\(pptxURL.lastPathComponent)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("First slide intro"))
        XCTAssertTrue(results[0].outputJSON.contains("UNIQUEPPTX"))
        XCTAssertTrue(results[0].outputJSON.contains("Slide 2"),
                      "Expected slide numbering in output: \(results[0].outputJSON)")
    }

    func testReadFile_rtfd_readsInternalTXTRTF() throws {
        let rtfdURL = tempDir.appendingPathComponent("bundle.rtfd", isDirectory: true)
        try fm.createDirectory(at: rtfdURL, withIntermediateDirectories: true)
        try #"{\rtf1\ansi Content of RTFD package}"#
            .write(to: rtfdURL.appendingPathComponent("TXT.rtf"),
                   atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"bundle.rtfd\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Content of RTFD package"))
    }

    func testReadFile_legacyDoc_returnsErrorWithSaveAsDocxHint() throws {
        let docURL = tempDir.appendingPathComponent("legacy.doc")
        try Data("Arbitrary binary .doc payload".utf8).write(to: docURL)

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"legacy.doc\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertTrue(results[0].isError,
                      "read_file on .doc should surface extraction failure: \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("save as .docx"),
                      "Error message should carry the save-as-docx hint for users: \(results[0].outputJSON)")
    }

    // MARK: - read_lines across all document formats

    func testReadLines_docx_returnsParagraphRange() throws {
        let docxURL = try makeDOCX(at: "many-paragraphs.docx", body: """
            <w:p><w:r><w:t>paragraph one</w:t></w:r></w:p>
            <w:p><w:r><w:t>paragraph two</w:t></w:r></w:p>
            <w:p><w:r><w:t>paragraph three</w:t></w:r></w:p>
            <w:p><w:r><w:t>paragraph four</w:t></w:r></w:p>
            """)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: """
            {"path": "\(docxURL.lastPathComponent)", "start_line": 2, "end_line": 3}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("paragraph two"))
        XCTAssertTrue(results[0].outputJSON.contains("paragraph three"))
        XCTAssertFalse(results[0].outputJSON.contains("paragraph one"),
                       "read_lines should not include line 1 in 2-3 range")
    }

    func testReadLines_rtf_returnsLineRange() throws {
        let rtfURL = tempDir.appendingPathComponent("notes.rtf")
        try #"{\rtf1\ansi line alpha\line line beta\line line gamma}"#
            .write(to: rtfURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"notes.rtf\", \"start_line\": 1, \"end_line\": -1}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("line alpha"))
    }

    func testReadLines_html_returnsRawSourceWithTags() throws {
        // HTML is now read as raw source — `read_lines` must preserve tags
        // verbatim so the LLM can edit markup. Earlier builds stripped tags
        // via DocumentTextExtractor.extractHTML; that path is removed.
        let htmlURL = tempDir.appendingPathComponent("page.html")
        let source = "<html>\n<body>\n<p class=\"hero\">line one</p>\n<p>line two</p>\n</body>\n</html>"
        try source.write(to: htmlURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"page.html\", \"start_line\": 1, \"end_line\": 0}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        // Tags must survive — match the JSON-escaped form of <p class="hero">.
        XCTAssertTrue(results[0].outputJSON.contains("<p class=\\\"hero\\\">"),
                      "HTML tags must be preserved verbatim in read_lines output: \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("line one"),
                      "body text must still be present: \(results[0].outputJSON)")
    }

    func testReadLines_odt_returnsLineRange() throws {
        let odtURL = try makeODT(at: "notes.odt", body: """
            <text:p>alpha line</text:p>
            <text:p>beta line</text:p>
            <text:p>gamma line</text:p>
            """)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"\(odtURL.lastPathComponent)\", \"start_line\": 2, \"end_line\": 2}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("beta line"))
    }

    func testReadLines_pptx_returnsLineRange() throws {
        let pptxURL = try makePPTX(at: "deck.pptx", slides: [
            "slide-one-marker",
            "slide-two-marker",
        ])

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"\(pptxURL.lastPathComponent)\", \"start_line\": 1, \"end_line\": -1}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("slide-one-marker"))
        XCTAssertTrue(results[0].outputJSON.contains("slide-two-marker"))
    }

    func testReadLines_xlsx_returnsLineRange() throws {
        let xlsxURL = try createTestXLSX()
        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"\(xlsxURL.lastPathComponent)\", \"start_line\": 1, \"end_line\": -1}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Alice"),
                      "xlsx line range should include known cell value")
    }

    func testReadLines_rtfd_readsInternalTXTRTF() throws {
        let rtfdURL = tempDir.appendingPathComponent("bundle.rtfd", isDirectory: true)
        try fm.createDirectory(at: rtfdURL, withIntermediateDirectories: true)
        try #"{\rtf1\ansi first line\line second line}"#
            .write(to: rtfdURL.appendingPathComponent("TXT.rtf"),
                   atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"bundle.rtfd\", \"start_line\": 1, \"end_line\": -1}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("first line"))
    }

    func testReadLines_legacyDoc_returnsErrorWithSaveAsDocxHint() throws {
        // read_lines routes through extractText which rejects .doc same as read_file.
        let docURL = tempDir.appendingPathComponent("legacy.doc")
        try Data("binary .doc content".utf8).write(to: docURL)

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"legacy.doc\", \"start_line\": 1, \"end_line\": -1}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("save as .docx"),
                      "read_lines on .doc should propagate same actionable hint as read_file: \(results[0].outputJSON)")
    }

    func testReadLines_docx_startLinePastEOF_returnsRangeError() throws {
        let docxURL = try makeDOCX(
            at: "short.docx",
            body: "<w:p><w:r><w:t>single line</w:t></w:r></w:p>"
        )

        let call = StepToolCall(
            name: "read_lines",
            argumentsJSON: "{\"path\": \"\(docxURL.lastPathComponent)\", \"start_line\": 999, \"end_line\": 1000}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("exceeds file length"),
                      "expected range error, got: \(results[0].outputJSON)")
    }

    // MARK: - Edge: Unicode / maxBytes / empty document

    func testReadFile_docx_withUnicodeContent() throws {
        // Cyrillic, emoji, zero-width joiner — all must round-trip through
        // ZIPReader + XMLParser without re-encoding damage.
        let docxURL = try makeDOCX(
            at: "unicode.docx",
            body: "<w:p><w:r><w:t>Привет, мир! 🌍👨‍👩‍👧 тест</w:t></w:r></w:p>"
        )

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"\(docxURL.lastPathComponent)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Привет, мир!"))
        XCTAssertTrue(results[0].outputJSON.contains("🌍"))
    }

    func testReadFile_docx_truncatedByMaxBytes() throws {
        // Produce a DOCX whose extracted text exceeds a low max_bytes cap.
        let longText = String(repeating: "A", count: 5000)
        let docxURL = try makeDOCX(
            at: "long.docx",
            body: "<w:p><w:r><w:t>\(longText)</w:t></w:r></w:p>"
        )

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: """
            {"path": "\(docxURL.lastPathComponent)", "max_bytes": 500}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("\"truncated\":true"),
                      "max_bytes truncation must set truncated meta flag: \(results[0].outputJSON)")
    }

    func testReadFile_emptyDOCX_returnsFailureMessage() throws {
        // DOCX with no <w:t> → extractor returns failure message; read_file
        // surfaces it as isError.
        let docxURL = try makeDOCX(
            at: "empty.docx",
            body: "<w:p></w:p>"
        )

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"\(docxURL.lastPathComponent)\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Could not extract text"))
    }

    // MARK: - search with documents

    func testSearchDocuments_findsMatchInPDF() throws {
        let pdfURL = try createPDFWithText("Hello UNIQUETOKEN42 world")
        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"UNIQUETOKEN42\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains(pdfURL.lastPathComponent),
                      "search should find PDF: \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("UNIQUETOKEN42"))
    }

    func testSearchDocuments_findsMatchInDOCX() throws {
        let docxURL = tempDir.appendingPathComponent("report.docx")
        let docXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>Quarterly DOCXMARKER123 report</w:t></w:r></w:p></w:body>
        </w:document>
        """
        try ZIPArchiveWriter.write(to: docxURL, entries: [
            .init(name: "word/document.xml", data: Data(docXML.utf8), method: .deflate)
        ])

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"DOCXMARKER123\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("report.docx"))
    }

    func testSearchDocuments_findsMatchInRTF() throws {
        let rtfURL = tempDir.appendingPathComponent("memo.rtf")
        try #"{\rtf1\ansi RTFMARKER456 in a memo}"#
            .write(to: rtfURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"RTFMARKER456\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("memo.rtf"))
    }

    func testSearchDocuments_findsMatchInRTFD() throws {
        let rtfdURL = tempDir.appendingPathComponent("bundle.rtfd", isDirectory: true)
        try fm.createDirectory(at: rtfdURL, withIntermediateDirectories: true)
        try #"{\rtf1\ansi RTFDMARKER789 inside bundle}"#
            .write(to: rtfdURL.appendingPathComponent("TXT.rtf"),
                   atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"RTFDMARKER789\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        // Match path should be the bundle itself, not TXT.rtf inside.
        XCTAssertTrue(results[0].outputJSON.contains("bundle.rtfd"),
                      "RTFD should appear as a single entry, got: \(results[0].outputJSON)")
    }

    func testSearchDocuments_findsMatchInHTML() throws {
        let htmlURL = tempDir.appendingPathComponent("page.html")
        try "<html><body><p>HTMLMARKER321 anchor</p></body></html>"
            .write(to: htmlURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"HTMLMARKER321\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("page.html"))
    }

    func testSearchHTML_findsTagSelector_provingRawSourceIsIndexed() throws {
        // Regression pin for the .html/.htm removal: searching for a tag or
        // attribute string inside HTML now matches because the file is read
        // as raw source. Under the old stripped-text path this test would
        // fail — it only passes when HTML is indexed verbatim.
        let htmlURL = tempDir.appendingPathComponent("landing.html")
        try "<html><body><p class=\"hero\">welcome</p></body></html>"
            .write(to: htmlURL, atomically: true, encoding: .utf8)

        let tagQuery = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"<p class=\\\"hero\\\">\"}"
        )
        let tagResult = runtime.executeAll(context: context, toolCalls: [tagQuery])
        XCTAssertFalse(tagResult[0].isError)
        XCTAssertTrue(tagResult[0].outputJSON.contains("landing.html"),
                      "tag-selector query must match HTML source: \(tagResult[0].outputJSON)")

        let attrQuery = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"class=\"}"
        )
        let attrResult = runtime.executeAll(context: context, toolCalls: [attrQuery])
        XCTAssertFalse(attrResult[0].isError)
        XCTAssertTrue(attrResult[0].outputJSON.contains("landing.html"),
                      "attribute substring must match HTML source: \(attrResult[0].outputJSON)")
    }

    func testSearchDocuments_findsMatchInXLSX() throws {
        _ = try createTestXLSX() // data.xlsx with rows containing "Alice" / "NY"
        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"Alice\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("data.xlsx"))
    }

    func testSearchDocuments_findsMatchInODT() throws {
        let odtURL = tempDir.appendingPathComponent("notes.odt")
        let contentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
            xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:text>
            <text:p>Notes about ODTMARKER555 today</text:p>
          </office:text></office:body>
        </office:document-content>
        """
        try ZIPArchiveWriter.write(to: odtURL, entries: [
            .init(name: "content.xml", data: Data(contentXML.utf8), method: .deflate)
        ])

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"ODTMARKER555\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("notes.odt"))
    }

    func testSearchDocuments_respectsFileGlob_pdfOnly() throws {
        _ = try createPDFWithText("Both files contain GLOBTOKEN")
        let txtURL = tempDir.appendingPathComponent("plain.txt")
        try "Plain text with GLOBTOKEN in it".write(to: txtURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"GLOBTOKEN\", \"file_glob\": \"*.txt\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("plain.txt"),
                      "Should find plain.txt: \(results[0].outputJSON)")
        XCTAssertFalse(results[0].outputJSON.contains(".pdf"),
                       "Should NOT find PDF with *.txt glob: \(results[0].outputJSON)")
    }

    func testSearchDocuments_skipsFailedExtraction() throws {
        // Write a .pdf with garbage bytes — PDFKit will reject it; search should
        // silently skip the file, not error out.
        let badURL = tempDir.appendingPathComponent("broken.pdf")
        try Data("not actually a pdf".utf8).write(to: badURL)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"anything\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError,
                       "Broken PDF should be skipped silently, not cause tool error")
    }

    func testSearchDocuments_findsMatchInPPTX() throws {
        let pptxURL = try makePPTX(at: "slides.pptx", slides: [
            "Introduction slide",
            "Agenda PPTXMARKER777 item",
            "Conclusion",
        ])

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"PPTXMARKER777\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("slides.pptx"))
    }

    // MARK: - Edge: search regex / context / limits

    func testSearchDocuments_regexMode_onDOCX() throws {
        _ = try makeDOCX(at: "report.docx", body: """
            <w:p><w:r><w:t>error: resource not found</w:t></w:r></w:p>
            <w:p><w:r><w:t>warning: deprecated API</w:t></w:r></w:p>
            """)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: """
            {"query": "error:.*found", "mode": "regex"}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("report.docx"),
                      "regex over DOCX should match: \(results[0].outputJSON)")
    }

    func testSearchDocuments_contextLines_fromDOCX() throws {
        _ = try makeDOCX(at: "notes.docx", body: """
            <w:p><w:r><w:t>preamble alpha</w:t></w:r></w:p>
            <w:p><w:r><w:t>preamble beta</w:t></w:r></w:p>
            <w:p><w:r><w:t>TARGETPHRASE here</w:t></w:r></w:p>
            <w:p><w:r><w:t>aftermath gamma</w:t></w:r></w:p>
            <w:p><w:r><w:t>aftermath delta</w:t></w:r></w:p>
            """)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: """
            {"query": "TARGETPHRASE", "context_before": 2, "context_after": 2}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        let json = results[0].outputJSON
        XCTAssertTrue(json.contains("TARGETPHRASE"))
        XCTAssertTrue(json.contains("preamble beta"),
                      "context_before=2 should include line before match: \(json)")
        XCTAssertTrue(json.contains("aftermath gamma"),
                      "context_after=2 should include line after match: \(json)")
    }

    func testSearchDocuments_maxMatchLines_truncatesMidDocument() throws {
        // 10 paragraphs, each matching the query. With max_match_lines=3 the
        // search should truncate mid-document and return truncated=true.
        var body = ""
        for i in 0..<10 {
            body += "<w:p><w:r><w:t>SAMEPHRASE \(i)</w:t></w:r></w:p>"
        }
        _ = try makeDOCX(at: "big.docx", body: body)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: """
            {"query": "SAMEPHRASE", "max_match_lines": 3}
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("\"truncated\":true"),
                      "max_match_lines hit should mark result as truncated: \(results[0].outputJSON)")
    }

    func testSearchDocuments_noMatches_returnsEmptyResult_noSkippedFiles() throws {
        // Readable doc + query that doesn't match → count:0, NO skipped_files
        // (skipped_files is for files that couldn't be indexed, not for clean misses).
        _ = try makeDOCX(at: "report.docx", body: """
            <w:p><w:r><w:t>normal body text</w:t></w:r></w:p>
            """)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"NEVER-APPEARS-ANYWHERE\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("\"count\":0"))
        XCTAssertFalse(results[0].outputJSON.contains("skipped_files"),
                       "clean misses should NOT populate skipped_files: \(results[0].outputJSON)")
    }

    func testSearchDocuments_findsMatchInNestedSubdirectory() throws {
        let subdir = tempDir.appendingPathComponent("deep/nested/path", isDirectory: true)
        try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
        let rtfURL = subdir.appendingPathComponent("nested.rtf")
        try #"{\rtf1\ansi NESTEDTOKEN inside subdir}"#
            .write(to: rtfURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"NESTEDTOKEN\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("nested.rtf"))
        // JSON serializer escapes slashes as `\/`; assert on the escaped form.
        XCTAssertTrue(results[0].outputJSON.contains("deep\\/nested\\/path"),
                      "search must preserve nested path in results: \(results[0].outputJSON)")
    }

    func testSearchDocuments_caseInsensitive_matchInsideDOCX() throws {
        _ = try makeDOCX(at: "report.docx", body: """
            <w:p><w:r><w:t>The MixedCaseToken shows up once.</w:t></w:r></w:p>
            """)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"mixedcasetoken\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("report.docx"),
                      "substring search must be case-insensitive over extracted text: \(results[0].outputJSON)")
    }

    func testSearchDocuments_skipsLegacyDOC_withSaveAsDocxReason() throws {
        // .doc is explicitly rejected via failureMessage; search should skip
        // it BUT report it in `skipped_files` so the LLM/user sees WHY the
        // file was unreadable, not just silence.
        let docURL = tempDir.appendingPathComponent("legacy.doc")
        try Data("Some binary .doc content with LEGACYMARKER999".utf8).write(to: docURL)

        let call = StepToolCall(
            name: "search",
            argumentsJSON: "{\"query\": \"LEGACYMARKER999\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("\"count\":0"),
                      "expected zero matches for legacy .doc: \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("skipped_files"),
                      "search result should carry skipped_files meta: \(results[0].outputJSON)")
        XCTAssertTrue(results[0].outputJSON.contains("save as .docx"),
                      "skipped_files entry should surface the save-as-docx hint: \(results[0].outputJSON)")
    }

    // MARK: - Helpers

    private func createPDFWithText(_ text: String) throws -> URL {
        let url = tempDir.appendingPathComponent("test.pdf")
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)

        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!

        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        // Draw each line at decreasing Y positions
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let attrStr = NSAttributedString(string: line, attributes: attrs)
            let ctLine = CTLineCreateWithAttributedString(attrStr)
            ctx.textPosition = CGPoint(x: 72, y: 700 - CGFloat(i) * 16)
            CTLineDraw(ctLine, ctx)
        }

        ctx.endPDFPage()
        ctx.closePDF()

        try (data as Data).write(to: url)
        return url
    }

    /// Minimal DOCX built via `ZIPArchiveWriter`. `body` is the XML fragment
    /// that goes inside `<w:body>…</w:body>`.
    private func makeDOCX(at filename: String, body: String) throws -> URL {
        let url = tempDir.appendingPathComponent(filename)
        let docXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            \(body)
          </w:body>
        </w:document>
        """
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "word/document.xml", data: Data(docXML.utf8), method: .deflate)
        ])
        return url
    }

    /// Minimal ODT built via `ZIPArchiveWriter`. `body` is the XML fragment
    /// that goes inside `<office:text>…</office:text>`.
    private func makeODT(at filename: String, body: String) throws -> URL {
        let url = tempDir.appendingPathComponent(filename)
        let contentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
            xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:text>
            \(body)
          </office:text></office:body>
        </office:document-content>
        """
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "content.xml", data: Data(contentXML.utf8), method: .deflate)
        ])
        return url
    }

    /// Minimal PPTX built via `ZIPArchiveWriter`. Each entry in `slides` becomes
    /// a `<a:t>…</a:t>` run on its own slide.
    private func makePPTX(at filename: String, slides: [String]) throws -> URL {
        let url = tempDir.appendingPathComponent(filename)
        let entries: [ZIPArchiveWriter.EntrySpec] = slides.enumerated().map { i, text in
            let slideXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                    xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
              <p:cSld><p:spTree><p:sp><p:txBody>
                <a:p><a:r><a:t>\(text)</a:t></a:r></a:p>
              </p:txBody></p:sp></p:spTree></p:cSld>
            </p:sld>
            """
            return .init(
                name: "ppt/slides/slide\(i + 1).xml",
                data: Data(slideXML.utf8),
                method: .deflate
            )
        }
        try ZIPArchiveWriter.write(to: url, entries: entries)
        return url
    }

    private func createTestXLSX() throws -> URL {
        let xlsxURL = tempDir.appendingPathComponent("data.xlsx")
        let ssXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="4" uniqueCount="4">
          <si><t>Name</t></si><si><t>City</t></si>
          <si><t>Alice</t></si><si><t>NY</t></si>
        </sst>
        """
        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" t="s"><v>3</v></c></row>
          </sheetData>
        </worksheet>
        """
        try ZIPArchiveWriter.write(to: xlsxURL, entries: [
            .init(name: "xl/sharedStrings.xml", data: Data(ssXML.utf8), method: .deflate),
            .init(name: "xl/worksheets/sheet1.xml", data: Data(sheetXML.utf8), method: .deflate),
        ])
        return xlsxURL
    }
}
