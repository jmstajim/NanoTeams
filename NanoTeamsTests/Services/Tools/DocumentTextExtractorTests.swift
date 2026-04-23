import XCTest
import PDFKit

@testable import NanoTeams

final class DocumentTextExtractorTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("DocumentTextExtractorTests_\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try! fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - isSupported

    func testIsSupported_recognizesAllDocumentExtensions() {
        let supported = ["pdf", "docx", "doc", "rtf", "rtfd", "odt", "xlsx", "pptx"]
        for ext in supported {
            XCTAssertTrue(
                DocumentTextExtractor.isSupported(extension: ext),
                "Expected \(ext) to be supported"
            )
        }
    }

    func testIsSupported_caseInsensitive() {
        XCTAssertTrue(DocumentTextExtractor.isSupported(extension: "PDF"))
        XCTAssertTrue(DocumentTextExtractor.isSupported(extension: "Docx"))
    }

    func testIsSupported_rejectsUnsupportedExtensions() {
        // Source-code-like text formats (html/htm/xml/md/css/js/swift/py/json)
        // must NOT be claimed by the document extractor — callers read them as
        // raw UTF-8 so tags and syntax stay visible for editing.
        let unsupported = [
            "html", "htm", "xml", "md", "css", "js", "ts", "tsx",
            "swift", "py", "json", "txt", "png", "key", "pages", "",
        ]
        for ext in unsupported {
            XCTAssertFalse(
                DocumentTextExtractor.isSupported(extension: ext),
                "Expected \(ext) to NOT be supported"
            )
        }
    }

    // MARK: - extractText: nil for unsupported

    func testExtractText_returnsNilForUnsupportedExtension() {
        let txtFile = tempDir.appendingPathComponent("hello.swift")
        try! "func main() {}".write(to: txtFile, atomically: true, encoding: .utf8)
        XCTAssertNil(DocumentTextExtractor.extractText(from: txtFile))
    }

    // MARK: - PDF Extraction

    func testExtractText_pdf_extractsText() {
        let pdfURL = createTestPDF(text: "Hello from PDF document")
        let result = DocumentTextExtractor.extractText(from: pdfURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Hello from PDF document"))
    }

    func testExtractText_pdf_emptyPDF_returnsFailureMessage() {
        // Create a PDF with no text (just an empty page)
        let pdfURL = tempDir.appendingPathComponent("empty.pdf")
        let pdfDoc = PDFDocument()
        let page = PDFPage()
        pdfDoc.insert(page, at: 0)
        pdfDoc.write(to: pdfURL)

        let result = DocumentTextExtractor.extractText(from: pdfURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("[Could not extract text"))
        XCTAssertTrue(result!.contains("no selectable text"))
    }

    func testExtractText_pdf_missingFile_returnsFailureMessage() {
        let fakeURL = tempDir.appendingPathComponent("missing.pdf")
        let result = DocumentTextExtractor.extractText(from: fakeURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("[Could not extract text"))
    }

    // MARK: - RTF Extraction

    func testExtractText_rtf_extractsText() {
        let rtfURL = tempDir.appendingPathComponent("test.rtf")
        let rtfContent = #"{\rtf1\ansi Hello from RTF document}"#
        try! rtfContent.write(to: rtfURL, atomically: true, encoding: .utf8)

        let result = DocumentTextExtractor.extractText(from: rtfURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Hello from RTF document"))
    }

    // MARK: - HTML / XML / source-code: raw UTF-8 read, not extraction

    func testExtractText_html_returnsNil_soCallerReadsRawSource() {
        // HTML is source code for a coding tool — callers must read it verbatim
        // (tags visible) via the standard UTF-8 path, not the stripped-text
        // NSAttributedString rendering that used to run here.
        let htmlURL = tempDir.appendingPathComponent("index.html")
        let html = "<html><body><p>Hello from HTML</p></body></html>"
        try! html.write(to: htmlURL, atomically: true, encoding: .utf8)

        let result = DocumentTextExtractor.extractText(from: htmlURL)
        XCTAssertNil(result,
                     "extractText must return nil for .html so the caller's raw UTF-8 path handles it; got: \(String(describing: result))")
    }

    func testExtractText_htm_returnsNil() {
        let url = tempDir.appendingPathComponent("legacy.htm")
        try! "<p>hi</p>".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(DocumentTextExtractor.extractText(from: url))
    }

    // MARK: - RTFD Extraction

    func testExtractRTFD_readsInternalTXTRTF() throws {
        let rtfdURL = tempDir.appendingPathComponent("note.rtfd", isDirectory: true)
        try fm.createDirectory(at: rtfdURL, withIntermediateDirectories: true)
        let rtfContent = #"{\rtf1\ansi Hello from RTFD package}"#
        try rtfContent.write(
            to: rtfdURL.appendingPathComponent("TXT.rtf"),
            atomically: true, encoding: .utf8
        )

        let result = DocumentTextExtractor.extractText(from: rtfdURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Hello from RTFD package"),
                      "RTFD extraction should read TXT.rtf inside: got \(result ?? "nil")")
    }

    func testExtractRTFD_missingTXTRTF_returnsFailure() throws {
        let rtfdURL = tempDir.appendingPathComponent("broken.rtfd", isDirectory: true)
        try fm.createDirectory(at: rtfdURL, withIntermediateDirectories: true)
        // No TXT.rtf inside the package.

        let result = DocumentTextExtractor.extractText(from: rtfdURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(DocumentTextExtractor.isFailureMessage(result!),
                      "RTFD without TXT.rtf should return failure message: got \(result!)")
        XCTAssertTrue(result!.contains("missing TXT.rtf"))
    }

    // MARK: - XLSX Extraction

    func testExtractText_xlsx_extractsMarkdownTable() {
        let xlsxURL = createTestXLSX(
            sharedStrings: ["Name", "Age", "Alice", "30"],
            sheetRows: [
                [("s", "0"), ("s", "1")],       // Name | Age
                [("s", "2"), ("s", "3")],        // Alice | 30
            ]
        )

        let result = DocumentTextExtractor.extractText(from: xlsxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Name"), "Should contain header")
        XCTAssertTrue(result!.contains("Age"), "Should contain header")
        XCTAssertTrue(result!.contains("Alice"), "Should contain data")
        XCTAssertTrue(result!.contains("30"), "Should contain data")
        XCTAssertTrue(result!.contains("|"), "Should be markdown table format")
        XCTAssertTrue(result!.contains("---"), "Should have markdown separator")
    }

    func testExtractText_xlsx_handlesRichTextSharedStrings() {
        // Rich-text: <si><r><t>bold</t></r><r><t> normal</t></r></si> = one shared string "bold normal"
        let ssXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2">
          <si><r><rPr><b/></rPr><t>Hello</t></r><r><t> World</t></r></si>
          <si><t>Simple</t></si>
        </sst>
        """

        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
          </sheetData>
        </worksheet>
        """

        let xlsxURL = createMinimalXLSX(
            sharedStringsXML: ssXML,
            sheetXML: sheetXML
        )

        let result = DocumentTextExtractor.extractText(from: xlsxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Hello World"), "Rich-text should be concatenated: got \(result!)")
        XCTAssertTrue(result!.contains("Simple"))
    }

    // MARK: - DOCX Extraction

    func testExtractDOCX_returnsPlainTextFromSimpleDocument() throws {
        let docXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>Hello World</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let docxURL = try createDOCX(documentXML: docXML)

        let result = DocumentTextExtractor.extractText(from: docxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Hello World"),
                      "DOCX extraction should preserve <w:t> content: got \(result!)")
    }

    func testExtractDOCX_preservesMultipleParagraphs() throws {
        let docXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>First paragraph</w:t></w:r></w:p>
            <w:p><w:r><w:t>Second paragraph</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let docxURL = try createDOCX(documentXML: docXML)

        let result = DocumentTextExtractor.extractText(from: docxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("First paragraph"))
        XCTAssertTrue(result!.contains("Second paragraph"))
        // Paragraph boundaries → newline
        XCTAssertTrue(result!.contains("\n"),
                      "Expected paragraph boundary newline in output: \(result!)")
    }

    func testExtractDOCX_ignoresNonTextElements() throws {
        let docXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>Before image</w:t></w:r></w:p>
            <w:p><w:r><w:drawing><w:docPr name="Image1" descr="A picture"/></w:drawing></w:r></w:p>
            <w:p><w:r><w:t>After image</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let docxURL = try createDOCX(documentXML: docXML)

        let result = DocumentTextExtractor.extractText(from: docxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Before image"))
        XCTAssertTrue(result!.contains("After image"))
        XCTAssertFalse(result!.contains("Image1"),
                       "Drawing element name must not leak into text: \(result!)")
        XCTAssertFalse(result!.contains("A picture"),
                       "Drawing description must not leak into text: \(result!)")
    }

    // MARK: - ODT Extraction

    func testExtractODT_returnsPlainTextFromSimpleDocument() throws {
        let contentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
            xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body>
            <office:text>
              <text:p>Hello ODT</text:p>
            </office:text>
          </office:body>
        </office:document-content>
        """
        let odtURL = try createODT(contentXML: contentXML)

        let result = DocumentTextExtractor.extractText(from: odtURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Hello ODT"),
                      "ODT extraction should preserve <text:p> content: got \(result!)")
    }

    func testExtractODT_preservesHeadingsAndParagraphs() throws {
        let contentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
            xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body>
            <office:text>
              <text:h text:outline-level="1">Chapter One</text:h>
              <text:p>This is the body of chapter one.</text:p>
              <text:p>Second paragraph with a <text:span>highlighted span</text:span> inside.</text:p>
            </office:text>
          </office:body>
        </office:document-content>
        """
        let odtURL = try createODT(contentXML: contentXML)

        let result = DocumentTextExtractor.extractText(from: odtURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Chapter One"), "heading should be in output: \(result!)")
        XCTAssertTrue(result!.contains("This is the body of chapter one."))
        XCTAssertTrue(result!.contains("highlighted span"),
                      "inline span text must join surrounding paragraph text")
    }

    func testExtractODT_suppressesAnnotationMetadata() throws {
        // ODT annotations wrap their own `<text:p>` inside `<office:annotation>`.
        // Without suppression, the annotation body AND metadata (creator, date)
        // would leak into the extracted body text.
        let contentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
            xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
            xmlns:dc="http://purl.org/dc/elements/1.1/">
          <office:body><office:text>
            <text:p>Main body sentence.
              <office:annotation>
                <dc:creator>Reviewer-Only</dc:creator>
                <dc:date>2024-01-01T00:00:00</dc:date>
                <text:p>ANNOTATION-SECRET text that must not leak</text:p>
              </office:annotation>
              Continuation of main body.
            </text:p>
          </office:text></office:body>
        </office:document-content>
        """
        let odtURL = try createODT(contentXML: contentXML)

        let result = DocumentTextExtractor.extractText(from: odtURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Main body sentence"))
        XCTAssertTrue(result!.contains("Continuation of main body"))
        XCTAssertFalse(result!.contains("ANNOTATION-SECRET"),
                       "annotation body must be suppressed: \(result!)")
        XCTAssertFalse(result!.contains("Reviewer-Only"),
                       "annotation creator must not leak into body: \(result!)")
        XCTAssertFalse(result!.contains("2024-01-01"),
                       "annotation date must not leak into body: \(result!)")
    }

    func testExtractDOCX_softLineBreak_emitsNewline() throws {
        // <w:br/> is a soft line break (Shift+Enter in Word). Should become a
        // newline in extracted text, not a silent concatenation.
        let docXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>before-break</w:t><w:br/><w:t>after-break</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let docxURL = try createDOCX(documentXML: docXML)

        let result = DocumentTextExtractor.extractText(from: docxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("before-break"))
        XCTAssertTrue(result!.contains("after-break"))
        XCTAssertFalse(result!.contains("before-breakafter-break"),
                       "<w:br/> must separate runs with a newline, not concatenate: \(result!)")
    }

    func testExtractDOCX_malformedXML_truncatedMidContent_warnsWithPartialText() throws {
        // Parser reaches <w:t> contents then hits EOF mid-element. Collector
        // must flush the pending runBuffer AND append the warning.
        let docxURL = tempDir.appendingPathComponent("broken-midcontent.docx")
        let truncatedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>valid start
        """
        try ZIPArchiveWriter.write(to: docxURL, entries: [
            .init(name: "word/document.xml", data: Data(truncatedXML.utf8), method: .deflate)
        ])

        let result = DocumentTextExtractor.extractText(from: docxURL)
        XCTAssertNotNil(result)
        XCTAssertFalse(DocumentTextExtractor.isFailureMessage(result!),
                       "partial content should surface, not the generic failure: \(result!)")
        XCTAssertTrue(result!.contains("valid start"),
                      "runBuffer must flush on parse abort so mid-run text is salvaged: \(result!)")
        XCTAssertTrue(result!.contains("XML parse stopped early"),
                      "parse abort must append the warning marker: \(result!)")
    }

    func testExtractDOCX_malformedXML_truncatedBeforeContent_surfacesWarningNotBlankMessage() throws {
        // Parser aborts before reaching any <w:t>. Before the fix, the collector
        // returned "" → caller emitted the misleading "DOCX contains no text".
        // The warning must reach the caller even when text.isEmpty.
        let docxURL = tempDir.appendingPathComponent("broken-preamble.docx")
        let truncatedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.open
        """
        try ZIPArchiveWriter.write(to: docxURL, entries: [
            .init(name: "word/document.xml", data: Data(truncatedXML.utf8), method: .deflate)
        ])

        let result = DocumentTextExtractor.extractText(from: docxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("XML parse stopped early"),
                      "pre-content abort must surface the parse warning: \(result!)")
        XCTAssertFalse(result!.contains("DOCX contains no text"),
                       "must not mask parse failure as 'blank document': \(result!)")
    }

    func testExtractODT_malformedXML_truncatedBeforeContent_surfacesWarningNotBlankMessage() throws {
        // ODT analogue of the above — guards the same silent-fail in ODTTextCollector.
        let odtURL = tempDir.appendingPathComponent("broken-preamble.odt")
        let truncatedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0
        """
        try ZIPArchiveWriter.write(to: odtURL, entries: [
            .init(name: "content.xml", data: Data(truncatedXML.utf8), method: .deflate)
        ])

        let result = DocumentTextExtractor.extractText(from: odtURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("XML parse stopped early"),
                      "pre-content abort must surface the parse warning: \(result!)")
        XCTAssertFalse(result!.contains("ODT contains no text"),
                       "must not mask parse failure as 'blank document': \(result!)")
    }

    // MARK: - XLSX partial-failure error propagation

    func testExtractXLSX_sharedStringsCRCInvalid_warnsButContinues() throws {
        // Corrupt the sharedStrings entry's CRC so `ZIPReader.readEntry` throws
        // `.crcMismatch` — extractXLSX must catch it, flag sharedStringsFailed,
        // and still surface numeric sheet content with a warning prepended.
        let sharedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>hello</t></si></sst>
        """
        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1"><v>99</v></c></row>
          </sheetData>
        </worksheet>
        """
        let xlsxURL = tempDir.appendingPathComponent("bad-shared-strings.xlsx")
        try ZIPArchiveWriter.write(to: xlsxURL, entries: [
            .init(name: "xl/sharedStrings.xml",
                  data: Data(sharedXML.utf8),
                  method: .deflate,
                  overrideCRC: 0xDEADBEEF),
            .init(name: "xl/worksheets/sheet1.xml",
                  data: Data(sheetXML.utf8),
                  method: .deflate),
        ])

        let result = DocumentTextExtractor.extractText(from: xlsxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("shared string table unreadable"),
                      "sharedStrings CRC error must surface the named warning: \(result!)")
        XCTAssertTrue(result!.contains("99"),
                      "numeric cells must still appear after the warning: \(result!)")
    }

    func testExtractXLSX_sharedStringsFailure_butSheetSurvives_warnsInOutput() throws {
        // Build an XLSX where sharedStrings.xml is missing (not just empty).
        // Worksheets still parse numeric cells correctly but string cells
        // show as integer indices — we must warn the reader.
        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1"><v>42</v></c><c r="B1" t="s"><v>0</v></c></row>
          </sheetData>
        </worksheet>
        """
        let xlsxURL = tempDir.appendingPathComponent("no-shared-strings.xlsx")
        try ZIPArchiveWriter.write(to: xlsxURL, entries: [
            // Note: no xl/sharedStrings.xml entry — the lookup returns nil (not
            // a throw). This path is the "survives gracefully" case.
            .init(name: "xl/worksheets/sheet1.xml", data: Data(sheetXML.utf8), method: .deflate),
        ])

        let result = DocumentTextExtractor.extractText(from: xlsxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("42"), "numeric cell should still render: \(result!)")
        // sharedStrings entry missing is treated as empty (valid case);
        // warning is only for when reading THROWS. This is an absence-path test
        // — it should NOT warn.
        XCTAssertFalse(result!.contains("unreadable"),
                       "missing-but-not-corrupt sharedStrings should not produce warning: \(result!)")
    }

    // MARK: - PPTX Extraction

    func testExtractText_pptx_extractsSlideText() {
        let pptxURL = createTestPPTX(slides: [
            "Welcome to the presentation",
            "Second slide content here",
        ])

        let result = DocumentTextExtractor.extractText(from: pptxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Slide 1"))
        XCTAssertTrue(result!.contains("Welcome to the presentation"))
        XCTAssertTrue(result!.contains("Slide 2"))
        XCTAssertTrue(result!.contains("Second slide content here"))
    }

    // MARK: - Export

    func testExport_pdf_producesData() {
        let data = DocumentTextExtractor.export(text: "Test PDF export", to: .pdf)
        XCTAssertNotNil(data)
        XCTAssertTrue(data!.count > 0)
    }

    func testExport_rtf_producesValidRTF() {
        let data = DocumentTextExtractor.export(text: "Test RTF export", to: .rtf)
        XCTAssertNotNil(data)
        let text = String(data: data!, encoding: .utf8)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("rtf"), "Should be RTF format")
    }

    func testExport_docx_producesValidDOCX() {
        let data = DocumentTextExtractor.export(text: "Test DOCX export", to: .docx)
        XCTAssertNotNil(data)
        // DOCX is a ZIP file, starts with PK signature
        XCTAssertTrue(data!.count > 4)
        XCTAssertEqual(data![0], 0x50) // 'P'
        XCTAssertEqual(data![1], 0x4B) // 'K'
    }

    func testExport_pdf_roundtrip() {
        let original = "Roundtrip PDF test content"
        guard let pdfData = DocumentTextExtractor.export(text: original, to: .pdf) else {
            XCTFail("PDF export returned nil"); return
        }

        let pdfURL = tempDir.appendingPathComponent("roundtrip.pdf")
        try! pdfData.write(to: pdfURL)

        let extracted = DocumentTextExtractor.extractText(from: pdfURL)
        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted!.contains("Roundtrip PDF test content"))
    }

    func testExport_rtf_roundtrip() {
        let original = "Roundtrip RTF test content"
        guard let rtfData = DocumentTextExtractor.export(text: original, to: .rtf) else {
            XCTFail("RTF export returned nil"); return
        }

        let rtfURL = tempDir.appendingPathComponent("roundtrip.rtf")
        try! rtfData.write(to: rtfURL)

        let extracted = DocumentTextExtractor.extractText(from: rtfURL)
        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted!.contains("Roundtrip RTF test content"))
    }

    // MARK: - Failure Detection

    func testIsFailureMessage_detectsFailures() {
        let failure = "[Could not extract text from report.pdf: could not open PDF]"
        XCTAssertTrue(DocumentTextExtractor.isFailureMessage(failure))
    }

    func testIsFailureMessage_rejectsRealContent() {
        XCTAssertFalse(DocumentTextExtractor.isFailureMessage("Hello from PDF document"))
        XCTAssertFalse(DocumentTextExtractor.isFailureMessage(""))
    }

    // MARK: - CreateArtifactTool format threading

    func testCreateArtifactTool_passesFormatInSignal() {
        let tool = CreateArtifactTool.makeInstance(dependencies: ToolHandlerDependencies(
            workFolderRoot: tempDir,
            resolver: SandboxPathResolver(workFolderRoot: tempDir, internalDir: tempDir),
            fileManager: .default,
            internalDir: tempDir
        ))
        let context = ToolExecutionContext(workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "r")
        let args: [String: Any] = ["name": "Report", "content": "# Report", "format": "pdf"]
        let result = tool.handle(context: context, args: args)

        XCTAssertFalse(result.isError)
        if case .artifact(let name, let content, let format) = result.signal {
            XCTAssertEqual(name, "Report")
            XCTAssertEqual(content, "# Report")
            XCTAssertEqual(format, "pdf")
        } else {
            XCTFail("Expected .artifact signal, got \(String(describing: result.signal))")
        }
    }

    func testCreateArtifactTool_nilFormatWhenOmitted() {
        let tool = CreateArtifactTool.makeInstance(dependencies: ToolHandlerDependencies(
            workFolderRoot: tempDir,
            resolver: SandboxPathResolver(workFolderRoot: tempDir, internalDir: tempDir),
            fileManager: .default,
            internalDir: tempDir
        ))
        let context = ToolExecutionContext(workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "r")
        let args: [String: Any] = ["name": "Report", "content": "# Report"]
        let result = tool.handle(context: context, args: args)

        if case .artifact(_, _, let format) = result.signal {
            XCTAssertNil(format)
        } else {
            XCTFail("Expected .artifact signal")
        }
    }

    // MARK: - DocumentConstants

    func testDocumentConstants_supportedReadExtensions_containsAllExpected() {
        let expected: Set<String> = ["pdf", "docx", "doc", "rtf", "rtfd", "odt", "xlsx", "pptx"]
        XCTAssertEqual(DocumentConstants.supportedReadExtensions, expected)
    }

    func testDocumentConstants_mimeTypes_coversAllReadExtensions() {
        // Every read extension except .rtfd (package, no single MIME)
        // must have a MIME type.
        for ext in DocumentConstants.supportedReadExtensions where ext != "rtfd" {
            XCTAssertNotNil(
                DocumentConstants.mimeTypes[ext],
                "Missing MIME type for extension: \(ext)"
            )
        }
    }

    // MARK: - Helpers: Create Test Fixtures

    /// Minimal DOCX: only `word/document.xml` is required for our extractor;
    /// `[Content_Types].xml` is included for realism but not consulted.
    private func createDOCX(documentXML: String) throws -> URL {
        let url = tempDir.appendingPathComponent("test.docx")
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="xml" ContentType="application/xml"/>
        </Types>
        """
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "[Content_Types].xml", data: Data(contentTypes.utf8), method: .deflate),
            .init(name: "word/document.xml", data: Data(documentXML.utf8), method: .deflate),
        ])
        return url
    }

    /// Minimal ODT: only `content.xml` is consulted by our extractor;
    /// `mimetype` entry is included for realism.
    private func createODT(contentXML: String) throws -> URL {
        let url = tempDir.appendingPathComponent("test.odt")
        let mimetype = "application/vnd.oasis.opendocument.text"
        try ZIPArchiveWriter.write(to: url, entries: [
            // ODT spec requires `mimetype` first and stored (not compressed), but
            // our extractor doesn't care — we just need content.xml readable.
            .init(name: "mimetype", data: Data(mimetype.utf8), method: .stored),
            .init(name: "content.xml", data: Data(contentXML.utf8), method: .deflate),
        ])
        return url
    }

    private func createTestPDF(text: String) -> URL {
        let url = tempDir.appendingPathComponent("test.pdf")
        let pdfDoc = PDFDocument()
        let page = createPDFPageWithText(text)
        pdfDoc.insert(page, at: 0)
        pdfDoc.write(to: url)
        return url
    }

    private func createPDFPageWithText(_ text: String) -> PDFPage {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        var mediaBox = pageRect

        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!

        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
        ]
        let attrString = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrString)
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        let pdfDoc = PDFDocument(data: data as Data)!
        return pdfDoc.page(at: 0)!
    }

    /// Create a minimal XLSX from pre-built XML strings.
    private func createMinimalXLSX(sharedStringsXML: String, sheetXML: String) -> URL {
        let xlsxURL = tempDir.appendingPathComponent("test.xlsx")
        try! ZIPArchiveWriter.write(to: xlsxURL, entries: [
            .init(name: "xl/sharedStrings.xml", data: Data(sharedStringsXML.utf8), method: .deflate),
            .init(name: "xl/worksheets/sheet1.xml", data: Data(sheetXML.utf8), method: .deflate),
        ])
        return xlsxURL
    }

    /// Create a test XLSX with shared strings and cell data.
    private func createTestXLSX(
        sharedStrings: [String],
        sheetRows: [[(type: String, value: String)]]
    ) -> URL {
        var ssEntries = ""
        for s in sharedStrings {
            ssEntries += "<si><t>\(s)</t></si>"
        }
        let ssXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        count="\(sharedStrings.count)" uniqueCount="\(sharedStrings.count)">
        \(ssEntries)
        </sst>
        """

        var rowsXML = ""
        for (ri, row) in sheetRows.enumerated() {
            var cellsXML = ""
            for (ci, cell) in row.enumerated() {
                let colLetter = String(UnicodeScalar(65 + ci)!)
                let ref = "\(colLetter)\(ri + 1)"
                cellsXML += "<c r=\"\(ref)\" t=\"\(cell.type)\"><v>\(cell.value)</v></c>"
            }
            rowsXML += "<row r=\"\(ri + 1)\">\(cellsXML)</row>"
        }

        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>\(rowsXML)</sheetData>
        </worksheet>
        """

        return createMinimalXLSX(sharedStringsXML: ssXML, sheetXML: sheetXML)
    }

    /// Create a test PPTX with slide text.
    private func createTestPPTX(slides: [String]) -> URL {
        let pptxURL = tempDir.appendingPathComponent("test.pptx")
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
        try! ZIPArchiveWriter.write(to: pptxURL, entries: entries)
        return pptxURL
    }

    // MARK: - Truncation + RTF type verification (A1, A2)

    func testExtractText_truncationAtByteCap_emitsMarkerAndRespectsUTF8Cap() throws {
        // Reads an RTF file whose decoded UTF-8 length exceeds maxExtractionBytes.
        // Result must carry the truncation marker AND honour the byte budget
        // (allowing only the fixed marker suffix on top). RTF is the cheapest
        // extractable format to build programmatically — ASCII body inside a
        // minimal `{\rtf1\ansi ...}` wrapper round-trips through NSAttributedString.
        let oversize = String(repeating: "a", count: DocumentConstants.maxExtractionBytes + 1024)
        let rtfURL = tempDir.appendingPathComponent("big.rtf")
        let rtf = #"{\rtf1\ansi\deff0 "# + oversize + "}"
        try rtf.write(to: rtfURL, atomically: true, encoding: .utf8)

        let result = DocumentTextExtractor.extractText(from: rtfURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.hasSuffix("bytes)"),
                      "result must carry the truncation marker: …\(result!.suffix(40))")
        XCTAssertTrue(result!.contains("... (truncated at \(DocumentConstants.maxExtractionBytes) bytes)"),
                      "marker text must name the actual cap: \(result!.suffix(60))")
        let marker = "\n\n... (truncated at \(DocumentConstants.maxExtractionBytes) bytes)"
        XCTAssertLessThanOrEqual(
            result!.utf8.count,
            DocumentConstants.maxExtractionBytes + marker.utf8.count,
            "result bytes must not exceed maxExtractionBytes + marker length"
        )
    }

    func testTruncateToUTF8Bytes_multiByteGrapheme_neverExceedsCap() {
        // "a\u{0301}" (combining acute) is 3 UTF-8 bytes. Cut at 2 bytes → must
        // snap back to 0 and return an empty string, not a torn grapheme.
        let s = "a\u{0301}"
        let out = DocumentTextExtractor.truncateToUTF8Bytes(s, maxBytes: 2)
        XCTAssertLessThanOrEqual(out.utf8.count, 2)
        // Emoji clusters: "👨‍👩‍👧" is 18 bytes via ZWJ sequence — cutting at 10
        // must still snap to a Character boundary and not exceed 10 bytes.
        let emoji = "👨‍👩‍👧"
        let outEmoji = DocumentTextExtractor.truncateToUTF8Bytes(emoji, maxBytes: 10)
        XCTAssertLessThanOrEqual(outEmoji.utf8.count, 10)
    }

    func testExtractRTF_nonRTFFileWithRTFExtension_returnsFailure() throws {
        // HTML content saved under .rtf extension. Either NSAttributedString
        // throws (catch branch → "could not read RTF") or parses and the
        // documentAttributes type check rejects with "not valid RTF".
        // Either way the caller sees a failure message, NOT bogus content.
        let rtfURL = tempDir.appendingPathComponent("mislabeled.rtf")
        try "<html><body><p>not actually RTF</p></body></html>"
            .write(to: rtfURL, atomically: true, encoding: .utf8)

        let result = DocumentTextExtractor.extractText(from: rtfURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(DocumentTextExtractor.isFailureMessage(result!),
                      "non-RTF content in a .rtf file must produce a failure message: \(result!)")
        XCTAssertFalse(result!.contains("not actually RTF"),
                       "non-RTF content must not be returned as decoded text: \(result!)")
    }

    // MARK: - XLSX inline-string multi-run (B1)

    func testExtractXLSX_inlineStringSingleRun_stillWorks() throws {
        // Regression guard for the two-buffer fix: a simple single-run inline
        // string must still render correctly. Without the `inInlineT` guard,
        // the two-buffer rewrite could have lost the single-run case.
        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1">
              <c r="A1" t="inlineStr"><is><t>solo</t></is></c>
            </row>
          </sheetData>
        </worksheet>
        """
        let xlsxURL = tempDir.appendingPathComponent("inline-single-run.xlsx")
        try ZIPArchiveWriter.write(to: xlsxURL, entries: [
            .init(name: "xl/worksheets/sheet1.xml", data: Data(sheetXML.utf8), method: .deflate),
        ])

        let result = DocumentTextExtractor.extractText(from: xlsxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("solo"),
                      "single-run inline string must still render: \(result!)")
    }

    func testExtractXLSX_sheetCRCCorrupt_surfacesInErrorsButOtherSheetsRender() throws {
        // Exercises the per-sheet error-surfacing path behind the B2 fix:
        // one sheet with a bad CRC throws inside `extractXLSX`, error is
        // captured, remaining sheets still appear in the output. Before B2's
        // tightening, a missing-body path could return silently; now any
        // failure mode on a per-sheet basis lands in the `errors` list.
        let goodSheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData><row r="1"><c r="A1"><v>GOOD</v></c></row></sheetData>
        </worksheet>
        """
        let badSheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData><row r="1"><c r="A1"><v>WILL_NOT_APPEAR</v></c></row></sheetData>
        </worksheet>
        """
        let xlsxURL = tempDir.appendingPathComponent("mixed-sheets.xlsx")
        try ZIPArchiveWriter.write(to: xlsxURL, entries: [
            .init(name: "xl/worksheets/sheet1.xml",
                  data: Data(goodSheet.utf8),
                  method: .deflate),
            .init(name: "xl/worksheets/sheet2.xml",
                  data: Data(badSheet.utf8),
                  method: .deflate,
                  overrideCRC: 0xBAADF00D),
        ])

        let result = DocumentTextExtractor.extractText(from: xlsxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("GOOD"),
                      "surviving sheet must render: \(result!)")
        XCTAssertFalse(result!.contains("WILL_NOT_APPEAR"),
                       "failed sheet must not leak content: \(result!)")
    }

    func testExtractXLSX_sharedStringsRichText_richTextRunsConcatenate() throws {
        // Shared-strings side of the two-buffer pattern — mirrors B1 on the
        // sheet-level inline-string case but protects the sharedStrings parser
        // which already had the pattern. Guards against accidental regression.
        let sharedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <si><r><t>part-</t></r><r><t>one</t></r></si>
        </sst>
        """
        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row></sheetData>
        </worksheet>
        """
        let xlsxURL = tempDir.appendingPathComponent("shared-richtext.xlsx")
        try ZIPArchiveWriter.write(to: xlsxURL, entries: [
            .init(name: "xl/sharedStrings.xml", data: Data(sharedXML.utf8), method: .deflate),
            .init(name: "xl/worksheets/sheet1.xml", data: Data(sheetXML.utf8), method: .deflate),
        ])

        let result = DocumentTextExtractor.extractText(from: xlsxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("part-one"),
                      "sharedStrings rich-text runs must concatenate: \(result!)")
    }

    func testExtractRTF_validRTF_stillDecodes() throws {
        // Regression guard for A2: the documentType-verification must not
        // reject legitimate RTF content.
        let rtfURL = tempDir.appendingPathComponent("valid.rtf")
        try #"{\rtf1\ansi\deff0 Legitimate RTF content}"#
            .write(to: rtfURL, atomically: true, encoding: .utf8)

        let result = DocumentTextExtractor.extractText(from: rtfURL)
        XCTAssertNotNil(result)
        XCTAssertFalse(DocumentTextExtractor.isFailureMessage(result!),
                       "valid RTF must not be rejected by the type check: \(result!)")
        XCTAssertTrue(result!.contains("Legitimate RTF content"),
                      "valid RTF must decode: \(result!)")
    }

    func testExtractXLSX_inlineStringMultipleRuns_concatenatesAllT() throws {
        // Inline-string cell with rich-text runs: <is><r><t>hel</t></r><r><t>lo</t></r></is>.
        // Before the two-buffer fix, only the last <t> survived → cell read as "lo".
        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1">
              <c r="A1" t="inlineStr"><is><r><t>hel</t></r><r><t>lo</t></r></is></c>
            </row>
          </sheetData>
        </worksheet>
        """
        let xlsxURL = tempDir.appendingPathComponent("inline-multi-run.xlsx")
        try ZIPArchiveWriter.write(to: xlsxURL, entries: [
            .init(name: "xl/worksheets/sheet1.xml", data: Data(sheetXML.utf8), method: .deflate),
        ])

        let result = DocumentTextExtractor.extractText(from: xlsxURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("hello"),
                      "multi-run inline string must concatenate all <t> runs: \(result!)")
    }
}
