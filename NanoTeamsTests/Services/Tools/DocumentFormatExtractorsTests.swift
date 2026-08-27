import XCTest
import PDFKit

@testable import NanoTeams

/// Unit tests for the per-format `DocumentFormatExtractor` Strategy types and the
/// `DocumentExtractionOutcome` they classify their results as. The facade-level
/// integration behavior (cache, truncation, dispatch) is covered by
/// `DocumentTextExtractorTests`; these exercise each strategy in isolation.
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

    // MARK: - DocumentExtractionOutcome

    func testOutcome_messageCarriesPrefixAndFilenameAndReason() {
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        let msg = DocumentExtractionOutcome.failure(reason: "could not open PDF").message(for: url)
        XCTAssertEqual(msg, "[Could not extract text from report.pdf: could not open PDF]")
    }

    func testOutcome_textOutcome_hasNoMessageEvenWhenItsBodyReadsLikeOne() {
        // The predicate this replaced was `hasPrefix("[Could not extract text")` run over the
        // RESULT, so a document whose own body opened with that sentence was reported
        // unreadable. A classified outcome cannot make that mistake: what the bytes say and
        // whether the read succeeded are different questions.
        let sentinel = "[Could not extract text from elsewhere.pdf: PDF has no selectable text]"
        let outcome = DocumentExtractionOutcome.text(sentinel, warnings: [])
        XCTAssertNil(outcome.message(for: URL(fileURLWithPath: "/tmp/quoted.docx")))
        XCTAssertNil(outcome.omissionReason)
        XCTAssertEqual(outcome.extractedText, sentinel)
    }

    func testOutcome_omissionReason_isNilOnlyForAWholeDocumentEmptiness() {
        // The single decision behind "should `search` report this file". It lives on the
        // value so the surfaces that render it cannot disagree.
        XCTAssertNil(DocumentExtractionOutcome.empty(reason: "r", scope: .wholeDocument).omissionReason)
        XCTAssertEqual(
            DocumentExtractionOutcome.empty(reason: "r", scope: .mainPartOnly(unread: "footnotes")).omissionReason,
            "r; footnotes were not examined"
        )
        XCTAssertEqual(DocumentExtractionOutcome.failure(reason: "r").omissionReason, "r")
    }

    // MARK: - SkippedFileGroup folding

    func testSkippedGroup_foldsByReason_mostCommonFirst() {
        let groups = SkippedFileGroup.group([
            SkippedFile(path: "a.rtf", reason: "not valid RTF"),
            SkippedFile(path: "b.doc", reason: "save as .docx"),
            SkippedFile(path: "c.doc", reason: "save as .docx"),
            SkippedFile(path: "d.doc", reason: "save as .docx"),
        ])
        XCTAssertEqual(groups.map(\.reason), ["save as .docx", "not valid RTF"])
        XCTAssertEqual(groups.map(\.count), [3, 1])
        XCTAssertEqual(groups[0].paths, ["b.doc", "c.doc", "d.doc"],
                       "paths keep walk order, which is already sorted")
    }

    func testSkippedGroup_equalCounts_orderByReason_soTwoRunsAgree() {
        // Determinism is not cosmetic: an envelope that reorders between identical runs
        // moves the prompt prefix and costs a cache miss for nothing.
        let forward = SkippedFileGroup.group([
            SkippedFile(path: "a", reason: "zebra"),
            SkippedFile(path: "b", reason: "alpha"),
        ])
        let reversed = SkippedFileGroup.group([
            SkippedFile(path: "b", reason: "alpha"),
            SkippedFile(path: "a", reason: "zebra"),
        ])
        XCTAssertEqual(forward.map(\.reason), ["alpha", "zebra"])
        XCTAssertEqual(forward, reversed, "input order must not reach the output")
    }

    func testSkippedGroup_empty_producesNoGroups() {
        XCTAssertTrue(SkippedFileGroup.group([]).isEmpty)
    }

    // MARK: - PDFDocumentExtractor

    func testPDF_extractsText() {
        let url = makePDF(text: "Strategy PDF body")
        let out = PDFDocumentExtractor().extract(from: url)
        XCTAssertEqual(out.extractedText?.contains("Strategy PDF body"), true)
    }

    func testPDF_missingFile_returnsFailure() {
        let out = PDFDocumentExtractor().extract(from: tempDir.appendingPathComponent("nope.pdf"))
        guard case .failure = out else { return XCTFail("expected .failure, got \(out)") }
    }

    // MARK: - RTFDocumentExtractor / RTFDDocumentExtractor / LegacyDOCExtractor

    func testRTF_extractsText() throws {
        let url = tempDir.appendingPathComponent("a.rtf")
        try #"{\rtf1\ansi RTF strategy body}"#.write(to: url, atomically: true, encoding: .utf8)
        let out = RTFDocumentExtractor().extract(from: url)
        XCTAssertEqual(out.extractedText?.contains("RTF strategy body"), true)
    }

    func testRTF_nonRTFContent_returnsFailure() throws {
        let url = tempDir.appendingPathComponent("fake.rtf")
        try "<html>not rtf</html>".write(to: url, atomically: true, encoding: .utf8)
        let out = RTFDocumentExtractor().extract(from: url)
        guard case .failure = out else { return XCTFail("expected .failure, got \(out)") }
        XCTAssertNil(out.extractedText, "mislabeled HTML must not come back as document text")
    }

    func testRTFD_readsInternalTXTRTF() throws {
        let pkg = tempDir.appendingPathComponent("note.rtfd", isDirectory: true)
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        try #"{\rtf1\ansi inner rtfd body}"#
            .write(to: pkg.appendingPathComponent("TXT.rtf"), atomically: true, encoding: .utf8)
        let out = RTFDDocumentExtractor().extract(from: pkg)
        XCTAssertEqual(out.extractedText?.contains("inner rtfd body"), true)
    }

    func testRTFD_missingTXTRTF_returnsFailure() throws {
        let pkg = tempDir.appendingPathComponent("broken.rtfd", isDirectory: true)
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        let out = RTFDDocumentExtractor().extract(from: pkg)
        guard case .failure = out else { return XCTFail("expected .failure, got \(out)") }
        // The reason travels BARE — no filename. The renderer names the outer `.rtfd`, so a
        // caller can no longer be handed `TXT.rtf`, a path no tool accepts.
        XCTAssertEqual(out.reason, "RTFD package missing TXT.rtf")
    }

    func testLegacyDOC_alwaysRejectsWithActionableMessage() {
        let out = LegacyDOCExtractor().extract(from: URL(fileURLWithPath: "/tmp/old.doc"))
        guard case .failure = out else { return XCTFail("expected .failure, got \(out)") }
        XCTAssertEqual(out.reason?.contains("save as .docx"), true)
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
        XCTAssertEqual(out.extractedText?.contains("docx strategy text"), true)
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
        XCTAssertEqual(out.extractedText?.contains("odt strategy text"), true)
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
        XCTAssertEqual(out.extractedText?.contains("7"), true)
        XCTAssertEqual(out.extractedText?.contains("|"), true)
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
        XCTAssertEqual(out.extractedText?.contains("slide strategy text"), true)
        XCTAssertEqual(out.extractedText?.contains("Slide 1"), true)
    }

    // MARK: - Emptiness, and how much of the document backs it

    /// The ZIP readers open ONE entry each, so their "no text" is a statement about what
    /// they read — not about the document. `scope` carries that, and it is what keeps the
    /// silence granted to a scanned PDF from spreading to formats that never earned it.
    func testODT_noText_isEmptyOverTheMainPartOnly() throws {
        let contentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
            xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:text></office:text></office:body>
        </office:document-content>
        """
        let url = tempDir.appendingPathComponent("blank.odt")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "content.xml", data: Data(contentXML.utf8), method: .deflate)
        ])

        guard case .empty(_, .mainPartOnly) = ODTDocumentExtractor().extract(from: url) else {
            return XCTFail("expected a main-part-only emptiness, got \(ODTDocumentExtractor().extract(from: url))")
        }
    }

    /// PPTX sibling: slides that parse cleanly and carry no text. Speaker notes live in
    /// `notesSlide*.xml`, which this reader never opens — so silence here would be a claim
    /// it cannot support.
    func testPPTX_slidesWithoutText_isEmptyOverTheSlidesOnly() throws {
        let slideXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld><p:spTree/></p:cSld>
        </p:sld>
        """
        let url = tempDir.appendingPathComponent("pictures.pptx")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "ppt/slides/slide1.xml", data: Data(slideXML.utf8), method: .deflate)
        ])

        let out = PPTXDocumentExtractor().extract(from: url)
        guard case .empty(let reason, .mainPartOnly(let unread)) = out else {
            return XCTFail("expected a main-part-only emptiness, got \(out)")
        }
        XCTAssertEqual(reason, "no text content in slides")
        XCTAssertTrue(unread.contains("speaker notes"),
                      "the unread parts must be named so the reader knows what was missed: \(unread)")
    }

    /// The ODT sibling of the DOCX partial-salvage case: the parse aborts AFTER collecting
    /// text, so there is real content and a caveat about it at the same time. They travel as
    /// two values — glueing the caveat into the string made it indistinguishable from the
    /// document's own words to every byte-level reader downstream.
    func testODT_parseAbortAfterContent_keepsTextAndReportsTheAbort() throws {
        let truncatedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
            xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:text><text:p>salvaged body
        """
        let url = tempDir.appendingPathComponent("cut.odt")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "content.xml", data: Data(truncatedXML.utf8), method: .deflate)
        ])

        let out = ODTDocumentExtractor().extract(from: url)
        XCTAssertEqual(out.extractedText?.contains("salvaged body"), true,
                       "text collected before the abort must survive: \(out)")
        XCTAssertEqual(out.warnings.contains { $0.contains("XML parse stopped early") }, true,
                       "the abort must ride alongside the text: \(out)")
    }

    /// One slide unreadable, another fine. The readable text still comes back — and the
    /// unreadable slide is named, which it was not before: the captured error was consulted
    /// only when NO slide produced text, so a partial deck read as a complete one.
    func testPPTX_oneCorruptSlideBesideAGoodOne_keepsTextAndNamesTheLoss() throws {
        let slideXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>readable slide</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
        </p:sld>
        """
        let url = tempDir.appendingPathComponent("partial.pptx")
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "ppt/slides/slide1.xml", data: Data(slideXML.utf8), method: .deflate),
            .init(name: "ppt/slides/slide2.xml", data: Data("<p:sld/>".utf8),
                  method: .stored, overrideCRC: 0xDEAD_BEEF),
        ])

        let out = PPTXDocumentExtractor().extract(from: url)
        XCTAssertEqual(out.extractedText?.contains("readable slide"), true,
                       "the good slide must still be extracted: \(out)")
        XCTAssertEqual(out.warnings.contains { $0.lowercased().contains("crc") }, true,
                       "a deck read only in part must say so: \(out)")
    }

    /// The PDF/RTF half of the same rule — these readers decode a whole document, so their
    /// emptiness is positive evidence and `search` is entitled to stay quiet about it.
    func testRTF_noText_isEmptyOverTheWholeDocument() throws {
        let url = tempDir.appendingPathComponent("blank.rtf")
        try #"{\rtf1\ansi }"#.write(to: url, atomically: true, encoding: .utf8)

        guard case .empty(_, .wholeDocument) = RTFDocumentExtractor().extract(from: url) else {
            return XCTFail("expected a whole-document emptiness")
        }
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
        // A missing file of each supported extension must classify as a FAILURE (non-nil),
        // proving the registry mirrors the supported set. Re-aimed off the retired
        // `isFailureMessage`: the property that outlives it is the outcome itself, and
        // asserting the case is strictly stronger than matching a rendered prefix.
        for ext in DocumentConstants.supportedReadExtensions {
            let url = tempDir.appendingPathComponent("missing.\(ext)")
            guard let out = DocumentTextExtractor.extract(from: url) else {
                return XCTFail("supported ext .\(ext) must resolve to a strategy, got nil")
            }
            guard case .failure = out else {
                return XCTFail("missing .\(ext) file must classify as .failure, got: \(out)")
            }
        }
    }

    func testFacade_unsupportedExtension_returnsNil() {
        let url = tempDir.appendingPathComponent("x.swift")
        try? "code".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(DocumentTextExtractor.extract(from: url))
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
