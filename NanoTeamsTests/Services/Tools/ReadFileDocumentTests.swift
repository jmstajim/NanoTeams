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

    // MARK: - read_file with HTML

    func testReadFile_html_returnsExtractedText() throws {
        let htmlURL = tempDir.appendingPathComponent("page.html")
        try "<html><body><p>HTML paragraph</p></body></html>"
            .write(to: htmlURL, atomically: true, encoding: .utf8)

        let call = StepToolCall(
            name: "read_file",
            argumentsJSON: "{\"path\": \"page.html\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("HTML paragraph"))
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

    private func createTestXLSX() throws -> URL {
        let xlsxURL = tempDir.appendingPathComponent("data.xlsx")
        let buildDir = tempDir.appendingPathComponent("xlsx_build")

        try fm.createDirectory(
            at: buildDir.appendingPathComponent("xl/worksheets", isDirectory: true),
            withIntermediateDirectories: true
        )

        let ssXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="4" uniqueCount="4">
          <si><t>Name</t></si><si><t>City</t></si>
          <si><t>Alice</t></si><si><t>NY</t></si>
        </sst>
        """
        try ssXML.write(
            to: buildDir.appendingPathComponent("xl/sharedStrings.xml"),
            atomically: true, encoding: .utf8
        )

        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" t="s"><v>3</v></c></row>
          </sheetData>
        </worksheet>
        """
        try sheetXML.write(
            to: buildDir.appendingPathComponent("xl/worksheets/sheet1.xml"),
            atomically: true, encoding: .utf8
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", xlsxURL.path, "."]
        process.currentDirectoryURL = buildDir
        try process.run()
        process.waitUntilExit()

        return xlsxURL
    }
}
