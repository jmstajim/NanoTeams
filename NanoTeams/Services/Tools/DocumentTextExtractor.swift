import Foundation
import PDFKit
import AppKit

/// Stateless document text extraction and export.
///
/// **Reading**: PDF (PDFKit), DOCX/DOC/RTF/RTFD/ODT/HTML (textutil), XLSX/PPTX (ZIP+XML).
/// **Export**: PDF, RTF, DOCX (NSAttributedString).
///
/// All extract methods return a silent fallback message on failure —
/// `"[Could not extract text from <filename>: <reason>]"`.
enum DocumentTextExtractor {

    /// Supported export formats for `create_artifact(format:)`.
    enum ExportFormat: String {
        case pdf, rtf, docx
    }

    // MARK: - Detection

    static func isSupported(extension ext: String) -> Bool {
        DocumentConstants.supportedReadExtensions.contains(ext.lowercased())
    }

    // MARK: - Text Extraction

    /// Returns extracted plain text, or a `[Could not extract text ...]` message on failure.
    /// Returns `nil` only if the extension is not a supported document format (caller falls back to UTF-8).
    static func extractText(from fileURL: URL) -> String? {
        let ext = fileURL.pathExtension.lowercased()
        guard DocumentConstants.supportedReadExtensions.contains(ext) else { return nil }

        let result: String
        switch ext {
        case "pdf":
            result = extractPDF(from: fileURL)
        case "xlsx":
            result = extractXLSX(from: fileURL)
        case "pptx":
            result = extractPPTX(from: fileURL)
        default:
            // DOCX, DOC, RTF, RTFD, ODT, HTML, HTM
            result = extractViaTextutil(from: fileURL)
        }

        // Enforce extraction size limit
        let maxChars = DocumentConstants.maxExtractionChars
        if result.count > maxChars {
            return String(result.prefix(maxChars)) + "\n\n... (truncated at \(maxChars) characters)"
        }
        return result
    }

    // MARK: - Export

    /// Export text content to a document format. Returns binary data or nil on failure.
    static func export(text: String, to format: ExportFormat) -> Data? {
        switch format {
        case .pdf:
            return exportPDF(text: text)
        case .rtf, .docx:
            let attr = NSAttributedString(string: text)
            let range = NSRange(location: 0, length: attr.length)
            let docType: NSAttributedString.DocumentType = format == .rtf ? .rtf : .officeOpenXML
            return try? attr.data(from: range, documentAttributes: [.documentType: docType])
        }
    }

    /// Export text to PDF using NSTextView rendering into a PDF graphics context.
    private static func exportPDF(text: String) -> Data? {
        let textStorage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let pageSize = CGSize(width: 612, height: 792) // US Letter
        let textInset = CGSize(width: 72, height: 72) // 1-inch margins
        let textContainerSize = CGSize(
            width: pageSize.width - textInset.width * 2,
            height: pageSize.height - textInset.height * 2
        )

        let textContainer = NSTextContainer(size: textContainerSize)
        layoutManager.addTextContainer(textContainer)

        // Force layout
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)

        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: CGSize(
            width: pageSize.width,
            height: max(usedRect.height + textInset.height * 2, pageSize.height)
        ))

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }

        context.beginPDFPage(nil)
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        // Draw text
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let origin = CGPoint(x: textInset.width, y: mediaBox.height - textInset.height - usedRect.height)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)

        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        return pdfData as Data
    }

    // MARK: - Private: PDF

    private static func extractPDF(from url: URL) -> String {
        guard let doc = PDFDocument(url: url) else {
            return failureMessage(url, reason: "could not open PDF")
        }

        var pages: [String] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let text = page.string, !text.isEmpty {
                pages.append(text)
            }
        }

        let joined = pages.joined(separator: "\n\n")
        return joined.isEmpty ? failureMessage(url, reason: "PDF has no selectable text") : joined
    }

    // MARK: - Private: textutil

    private static func extractViaTextutil(from url: URL) -> String {
        do {
            let result = try ProcessRunner.run(
                executable: DocumentConstants.textutilPath,
                arguments: ["-convert", "txt", "-stdout", url.path],
                currentDirectory: nil,
                timeout: DocumentConstants.textutilTimeout
            )
            let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.success, !text.isEmpty {
                return text
            }
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return failureMessage(url, reason: reason.isEmpty ? "textutil returned empty output" : reason)
        } catch {
            return failureMessage(url, reason: error.localizedDescription)
        }
    }

    // MARK: - Private: XLSX

    private static func extractXLSX(from url: URL) -> String {
        lastZIPError = nil

        // 1. Shared strings table
        let sharedStrings: [String]
        if let ssData = extractZIPEntry(url, entry: "xl/sharedStrings.xml") {
            sharedStrings = SharedStringsParser.parse(data: ssData)
        } else {
            sharedStrings = []
        }

        // 2. List sheets
        let entries = listZIPEntries(url)
        let sheetEntries = entries
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted()

        guard !sheetEntries.isEmpty else {
            let reason = lastZIPError ?? "no worksheet data found"
            return failureMessage(url, reason: reason)
        }

        // 3. Parse each sheet into markdown table
        var sections: [String] = []
        for (index, entry) in sheetEntries.enumerated() {
            guard let data = extractZIPEntry(url, entry: entry) else { continue }
            let rows = XLSXSheetParser.parse(data: data, sharedStrings: sharedStrings)
            guard !rows.isEmpty else { continue }

            let header = "### Sheet \(index + 1)"
            let table = formatMarkdownTable(rows: rows, maxRows: DocumentConstants.maxXLSXRows)
            sections.append(header + "\n\n" + table)
        }

        return sections.isEmpty
            ? failureMessage(url, reason: "empty spreadsheet")
            : sections.joined(separator: "\n\n")
    }

    // MARK: - Private: PPTX

    private static func extractPPTX(from url: URL) -> String {
        lastZIPError = nil

        let entries = listZIPEntries(url)
        let slideEntries = entries
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { slideNumber($0) < slideNumber($1) }

        guard !slideEntries.isEmpty else {
            let reason = lastZIPError ?? "no slide content found"
            return failureMessage(url, reason: reason)
        }

        var sections: [String] = []
        for (index, entry) in slideEntries.prefix(DocumentConstants.maxPPTXSlides).enumerated() {
            guard let data = extractZIPEntry(url, entry: entry) else { continue }
            let texts = XMLTextCollector.collect(data: data, tagName: "a:t")
            let joined = texts
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: " ")
            if !joined.isEmpty {
                sections.append("**Slide \(index + 1):** \(joined)")
            }
        }

        return sections.isEmpty
            ? failureMessage(url, reason: "no text content in slides")
            : sections.joined(separator: "\n\n")
    }

    /// Extract slide number from path like "ppt/slides/slide12.xml" → 12.
    private static func slideNumber(_ path: String) -> Int {
        let name = (path as NSString).lastPathComponent
        let digits = name.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    // MARK: - Private: ZIP Helpers

    /// Last error from ZIP operations — set when extractZIPEntry/listZIPEntries fail.
    /// Used by callers to include diagnostics in failure messages instead of generic "empty" text.
    private static var lastZIPError: String?

    /// Extract a single entry from a ZIP archive as raw Data.
    /// Uses a temp file to avoid the ProcessRunner String→Data round-trip
    /// that would silently drop non-ASCII content.
    private static func extractZIPEntry(_ zipURL: URL, entry: String) -> Data? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntms_zip_\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            lastZIPError = "could not create temp directory: \(error.localizedDescription)"
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            let result = try ProcessRunner.run(
                executable: DocumentConstants.unzipPath,
                arguments: ["-o", "-d", tempDir.path, zipURL.path, entry],
                currentDirectory: nil,
                timeout: DocumentConstants.unzipTimeout
            )
            guard result.success else {
                lastZIPError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return nil
            }
        } catch {
            lastZIPError = error.localizedDescription
            return nil
        }

        let extractedFile = tempDir.appendingPathComponent(entry)
        return try? Data(contentsOf: extractedFile)
    }

    /// List all file entries in a ZIP archive. Uses `unzip -Z1` for clean one-path-per-line output.
    private static func listZIPEntries(_ zipURL: URL) -> [String] {
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(
                executable: DocumentConstants.unzipPath,
                arguments: ["-Z1", zipURL.path],
                currentDirectory: nil,
                timeout: DocumentConstants.unzipTimeout
            )
        } catch {
            lastZIPError = error.localizedDescription
            return []
        }

        guard result.success else {
            lastZIPError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return []
        }

        return result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasSuffix("/") }
    }

    // MARK: - Private: Markdown Table Formatter

    private static func formatMarkdownTable(rows: [[String]], maxRows: Int) -> String {
        let limited = Array(rows.prefix(maxRows))
        let colCount = limited.map(\.count).max() ?? 0
        guard colCount > 0 else { return "" }

        var lines: [String] = []
        for (i, row) in limited.enumerated() {
            let padded = (0..<colCount).map { col in
                col < row.count ? row[col].replacingOccurrences(of: "|", with: "\\|") : ""
            }
            lines.append("| " + padded.joined(separator: " | ") + " |")
            if i == 0 {
                lines.append("|" + String(repeating: " --- |", count: colCount))
            }
        }

        if rows.count > maxRows {
            lines.append("\n... (\(rows.count - maxRows) more rows)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Failure Detection

    /// Prefix used in extraction failure messages. Callers can check this to distinguish
    /// extraction failures from real content (e.g., to avoid caching failures as valid reads).
    static let failurePrefix = "[Could not extract text"

    /// Returns true if the string is an extraction failure message (not real content).
    static func isFailureMessage(_ text: String) -> Bool {
        text.hasPrefix(failurePrefix)
    }

    private static func failureMessage(_ url: URL, reason: String) -> String {
        "\(failurePrefix) from \(url.lastPathComponent): \(reason)]"
    }
}

// MARK: - XML Parsers

/// Collects text content from all occurrences of a specific XML element.
private final class XMLTextCollector: NSObject, XMLParserDelegate {
    private let targetTag: String
    private(set) var texts: [String] = []
    private var isInTag = false
    private var buffer = ""

    private init(tagName: String) { self.targetTag = tagName; super.init() }

    static func collect(data: Data, tagName: String) -> [String] {
        let collector = XMLTextCollector(tagName: tagName)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.texts
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        if elementName == targetTag { isInTag = true; buffer = "" }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        if elementName == targetTag { texts.append(buffer); isInTag = false }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInTag { buffer += string }
    }
}

/// Parses XLSX `sharedStrings.xml` into an array of string values.
/// Handles rich-text entries (`<si><r><t>bold</t></r><r><t> normal</t></r></si>`)
/// by concatenating all `<t>` text within each `<si>` element.
private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var inSI = false
    private var inT = false
    private var currentString = ""
    private var currentT = ""

    static func parse(data: Data) -> [String] {
        let p = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.strings
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        if elementName == "si" { inSI = true; currentString = "" }
        if elementName == "t" && inSI { inT = true; currentT = "" }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        if elementName == "t" && inT { currentString += currentT; inT = false }
        if elementName == "si" && inSI { strings.append(currentString); inSI = false }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT { currentT += string }
    }
}

/// Parses XLSX worksheet XML into a 2D array of cell display strings.
private final class XLSXSheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private(set) var rows: [[String]] = []
    private var currentRow: [String] = []
    private var cellType = ""
    private var cellValue = ""
    private var inValue = false
    private var inInlineString = false
    private var inlineText = ""

    private init(sharedStrings: [String]) { self.sharedStrings = sharedStrings; super.init() }

    static func parse(data: Data, sharedStrings: [String]) -> [[String]] {
        let p = XLSXSheetParser(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.rows
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        switch elementName {
        case "row":
            currentRow = []
        case "c":
            cellType = attributes["t"] ?? ""
            cellValue = ""
            inlineText = ""
        case "v":
            inValue = true
        case "is":
            inInlineString = true
        case "t" where inInlineString:
            inlineText = ""
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        switch elementName {
        case "v":
            inValue = false
        case "is":
            inInlineString = false
        case "c":
            if cellType == "inlineStr" {
                currentRow.append(inlineText)
            } else if cellType == "s", let idx = Int(cellValue), sharedStrings.indices.contains(idx) {
                currentRow.append(sharedStrings[idx])
            } else {
                currentRow.append(cellValue)
            }
        case "row":
            if !currentRow.isEmpty { rows.append(currentRow) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { cellValue += string }
        if inInlineString { inlineText += string }
    }
}
