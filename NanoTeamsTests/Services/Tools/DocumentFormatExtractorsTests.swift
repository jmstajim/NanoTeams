import XCTest
import PDFKit

@testable import NanoTeams

/// Unit tests for the per-format `DocumentFormatExtractor` Strategy types and
/// the shared `DocumentExtractionFailure` helper extracted from the former
/// `DocumentTextExtractor` God enum. The facade-level integration behavior
/// (cache, truncation, dispatch) is covered by `DocumentTextExtractorTests`;
/// these exercise each strategy in isolation.
final class DocumentFormatExtractorsTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("DocFmtExtractorTests_\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try! fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - DocumentExtractionFailure

    func testFailure_messageCarriesPrefixAndFilenameAndReason() {
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        let msg = DocumentExtractionFailure.message(url, reason: "could not open PDF")
        XCTAssertTrue(msg.hasPrefix(DocumentExtractionFailure.prefix))
        XCTAssertTrue(msg.contains("report.pdf"))
        XCTAssertTrue(msg.contains("could not open PDF"))
    }

    func testFailure_isFailure_matchesPrefixOnly() {
        XCTAssertTrue(DocumentExtractionFailure.isFailure("[Could not extract text from x: y]"))
        XCTAssertFalse(DocumentExtractionFailure.isFailure("real content"))
        XCTAssertFalse(DocumentExtractionFailure.isFailure(""))
    }

    func testFailure_facadeForwardersMatchHelper() {
        // The facade must re-expose the same prefix + predicate it delegates to.
        XCTAssertEqual(DocumentTextExtractor.failurePrefix, DocumentExtractionFailure.prefix)
        let msg = DocumentExtractionFailure.message(URL(fileURLWithPath: "/a/b.pdf"), reason: "z")
        XCTAssertEqual(
            DocumentTextExtractor.isFailureMessage(msg),
            DocumentExtractionFailure.isFailure(msg)
        )
    }

    // MARK: - PDFDocumentExtractor

    func testPDF_extractsText() {
        let url = makePDF(text: "Strategy PDF body")
        let out = PDFDocumentExtractor().extract(from: url)
        XCTAssertTrue(out.contains("Strategy PDF body"))
        XCTAssertFalse(DocumentExtractionFailure.isFailure(out))
    }

    func testPDF_missingFile_returnsFailure() {
        let out = PDFDocumentExtractor().extract(from: tempDir.appendingPathComponent("nope.pdf"))
        XCTAssertTrue(DocumentExtractionFailure.isFailure(out))
    }

    // MARK: - RTFDocumentExtractor / RTFDDocumentExtractor / LegacyDOCExtractor

    func testRTF_extractsText() throws {
        let url = tempDir.appendingPathComponent("a.rtf")
        try #"{\rtf1\ansi RTF strategy body}"#.write(to: url, atomically: true, encoding: .utf8)
        let out = RTFDocumentExtractor().extract(from: url)
        XCTAssertTrue(out.contains("RTF strategy body"))
    }

    func testRTF_nonRTFContent_returnsFailure() throws {
        let url = tempDir.appendingPathComponent("fake.rtf")
        try "<html>not rtf</html>".write(to: url, atomically: true, encoding: .utf8)
        let out = RTFDocumentExtractor().extract(from: url)
        XCTAssertTrue(DocumentExtractionFailure.isFailure(out))
        XCTAssertFalse(out.contains("not rtf"))
    }

    func testRTFD_readsInternalTXTRTF() throws {
        let pkg = tempDir.appendingPathComponent("note.rtfd", isDirectory: true)
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        try #"{\rtf1\ansi inner rtfd body}"#
            .write(to: pkg.appendingPathComponent("TXT.rtf"), atomically: true, encoding: .utf8)
        let out = RTFDDocumentExtractor().extract(from: pkg)
        XCTAssertTrue(out.contains("inner rtfd body"))
    }

    func testRTFD_missingTXTRTF_returnsFailure() throws {
        let pkg = tempDir.appendingPathComponent("broken.rtfd", isDirectory: true)
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        let out = RTFDDocumentExtractor().extract(from: pkg)
        XCTAssertTrue(DocumentExtractionFailure.isFailure(out))
        XCTAssertTrue(out.contains("missing TXT.rtf"))
    }

    func testLegacyDOC_alwaysRejectsWithActionableMessage() {
        let out = LegacyDOCExtractor().extract(from: URL(fileURLWithPath: "/tmp/old.doc"))
        XCTAssertTrue(DocumentExtractionFailure.isFailure(out))
        XCTAssertTrue(out.contains("save as .docx"))
    }

    // MARK: - DOCX / ODT / XLSX / PPTX (direct strategy instantiation)

    func testDOCX_extractsParagraphText() throws {
        let docXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>docx strategy text</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let url = tempDir.appendingPathComponent("d.docx")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "word/document.xml", data: Data(docXML.utf8), method: .deflate)
        ])
        let out = DOCXDocumentExtractor().extract(from: url)
        XCTAssertTrue(out.contains("docx strategy text"))
    }

    func testODT_extractsParagraphText() throws {
        let contentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
            xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:text><text:p>odt strategy text</text:p></office:text></office:body>
        </office:document-content>
        """
        let url = tempDir.appendingPathComponent("d.odt")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "content.xml", data: Data(contentXML.utf8), method: .deflate)
        ])
        let out = ODTDocumentExtractor().extract(from: url)
        XCTAssertTrue(out.contains("odt strategy text"))
    }

    func testXLSX_extractsMarkdownTable() throws {
        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData><row r="1"><c r="A1"><v>7</v></c></row></sheetData>
        </worksheet>
        """
        let url = tempDir.appendingPathComponent("d.xlsx")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "xl/worksheets/sheet1.xml", data: Data(sheetXML.utf8), method: .deflate)
        ])
        let out = XLSXDocumentExtractor().extract(from: url)
        XCTAssertTrue(out.contains("7"))
        XCTAssertTrue(out.contains("|"))
    }

    func testPPTX_extractsSlideText() throws {
        let slideXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>slide strategy text</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
        </p:sld>
        """
        let url = tempDir.appendingPathComponent("d.pptx")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "ppt/slides/slide1.xml", data: Data(slideXML.utf8), method: .deflate)
        ])
        let out = PPTXDocumentExtractor().extract(from: url)
        XCTAssertTrue(out.contains("slide strategy text"))
        XCTAssertTrue(out.contains("Slide 1"))
    }

    // MARK: - Pure helpers newly exposed on the strategies

    func testXLSX_formatMarkdownTable_emitsHeaderSeparatorAndEscapesPipes() {
        let table = XLSXDocumentExtractor.formatMarkdownTable(
            rows: [["a|b", "c"], ["d", "e"]],
            maxRows: 200
        )
        XCTAssertTrue(table.contains("a\\|b"), "pipes inside cells must be escaped: \(table)")
        XCTAssertTrue(table.contains("---"), "first row must be followed by a separator: \(table)")
    }

    func testXLSX_formatMarkdownTable_appendsTruncationNoticeWhenOverMaxRows() {
        let rows = (0..<5).map { ["row\($0)"] }
        let table = XLSXDocumentExtractor.formatMarkdownTable(rows: rows, maxRows: 2)
        XCTAssertTrue(table.contains("3 more rows"), "truncation notice must count dropped rows: \(table)")
    }

    func testXLSX_formatMarkdownTable_emptyRows_returnsEmpty() {
        XCTAssertEqual(XLSXDocumentExtractor.formatMarkdownTable(rows: [], maxRows: 10), "")
        XCTAssertEqual(XLSXDocumentExtractor.formatMarkdownTable(rows: [[]], maxRows: 10), "")
    }

    func testPPTX_slideNumber_parsesNumericSuffix() {
        XCTAssertEqual(PPTXDocumentExtractor.slideNumber("ppt/slides/slide12.xml"), 12)
        XCTAssertEqual(PPTXDocumentExtractor.slideNumber("ppt/slides/slide1.xml"), 1)
        // Ordering correctness: slide2 must sort before slide10 numerically.
        XCTAssertLessThan(
            PPTXDocumentExtractor.slideNumber("slide2.xml"),
            PPTXDocumentExtractor.slideNumber("slide10.xml")
        )
    }

    func testPPTX_slideNumber_noDigits_returnsZero() {
        XCTAssertEqual(PPTXDocumentExtractor.slideNumber("ppt/slides/notes.xml"), 0)
    }

    // MARK: - Registry / facade dispatch parity

    func testFacade_everySupportedExtensionResolvesToAStrategy() {
        // A missing file of each supported extension must surface a failure
        // message (non-nil), proving the registry mirrors the supported set.
        for ext in DocumentConstants.supportedReadExtensions {
            let url = tempDir.appendingPathComponent("missing.\(ext)")
            let out = DocumentTextExtractor.extractText(from: url)
            XCTAssertNotNil(out, "supported ext .\(ext) must not return nil")
            XCTAssertTrue(
                DocumentTextExtractor.isFailureMessage(out!),
                "missing .\(ext) file must surface a failure message, got: \(out!)"
            )
        }
    }

    func testFacade_unsupportedExtension_returnsNil() {
        let url = tempDir.appendingPathComponent("x.swift")
        try? "code".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(DocumentTextExtractor.extractText(from: url))
    }

    // MARK: - Fixtures

    private func makePDF(text: String) -> URL {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).pdf")
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        try! (data as Data).write(to: url)
        return url
    }
}
