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
        let supported = ["pdf", "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "xlsx", "pptx"]
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
        let unsupported = ["swift", "py", "json", "txt", "png", "key", "pages", ""]
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

    // MARK: - HTML Extraction

    func testExtractText_html_extractsText() {
        let htmlURL = tempDir.appendingPathComponent("test.html")
        let html = "<html><body><p>Hello from HTML</p></body></html>"
        try! html.write(to: htmlURL, atomically: true, encoding: .utf8)

        let result = DocumentTextExtractor.extractText(from: htmlURL)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Hello from HTML"))
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
        let expected: Set<String> = ["pdf", "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "xlsx", "pptx"]
        XCTAssertEqual(DocumentConstants.supportedReadExtensions, expected)
    }

    func testDocumentConstants_mimeTypes_coversAllReadExtensions() {
        // Every read extension except htm (alias for html) should have a MIME type
        for ext in DocumentConstants.supportedReadExtensions where ext != "htm" && ext != "rtfd" {
            XCTAssertNotNil(
                DocumentConstants.mimeTypes[ext],
                "Missing MIME type for extension: \(ext)"
            )
        }
    }

    // MARK: - Helpers: Create Test Fixtures

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
        let buildDir = tempDir.appendingPathComponent("xlsx_build")

        try! fm.createDirectory(
            at: buildDir.appendingPathComponent("xl/worksheets", isDirectory: true),
            withIntermediateDirectories: true
        )

        try! sharedStringsXML.write(
            to: buildDir.appendingPathComponent("xl/sharedStrings.xml"),
            atomically: true, encoding: .utf8
        )
        try! sheetXML.write(
            to: buildDir.appendingPathComponent("xl/worksheets/sheet1.xml"),
            atomically: true, encoding: .utf8
        )

        // Create the ZIP
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", xlsxURL.path, "."]
        process.currentDirectoryURL = buildDir
        try! process.run()
        process.waitUntilExit()

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
        let buildDir = tempDir.appendingPathComponent("pptx_build")

        try! fm.createDirectory(
            at: buildDir.appendingPathComponent("ppt/slides", isDirectory: true),
            withIntermediateDirectories: true
        )

        for (i, text) in slides.enumerated() {
            let slideXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                    xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
              <p:cSld><p:spTree><p:sp><p:txBody>
                <a:p><a:r><a:t>\(text)</a:t></a:r></a:p>
              </p:txBody></p:sp></p:spTree></p:cSld>
            </p:sld>
            """
            try! slideXML.write(
                to: buildDir.appendingPathComponent("ppt/slides/slide\(i + 1).xml"),
                atomically: true, encoding: .utf8
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", pptxURL.path, "."]
        process.currentDirectoryURL = buildDir
        try! process.run()
        process.waitUntilExit()

        return pptxURL
    }
}
