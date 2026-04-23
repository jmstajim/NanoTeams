import Foundation
import PDFKit
import AppKit

/// Stateless document text extraction and export.
///
/// **Reading**:
/// - PDF — `PDFKit`
/// - DOCX / ODT / XLSX / PPTX — `ZIPReader` (in-process) + `XMLParser`
/// - RTF / RTFD — `NSAttributedString`
/// - DOC (legacy Word 97-2004 binary) — rejected with failure message
///
/// Anything not in `DocumentConstants.supportedReadExtensions` returns `nil`
/// from `extractText`; callers then read the file as raw UTF-8. This is
/// intentional for source-like formats (`.html`, `.xml`, `.md`, `.json`,
/// source code) — callers need verbatim markup for source-editing workflows.
///
/// **Export**: PDF, RTF, DOCX (NSAttributedString + NSGraphicsContext, macOS-only
/// via AppKit; export is not yet iOS-compatible).
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
        case "docx":
            result = extractDOCX(from: fileURL)
        case "odt":
            result = extractODT(from: fileURL)
        case "rtf":
            result = extractRTF(from: fileURL)
        case "rtfd":
            result = extractRTFD(from: fileURL)
        case "doc":
            result = extractDOC(from: fileURL)
        default:
            result = failureMessage(fileURL, reason: "unhandled format: .\(ext)")
        }

        let maxBytes = DocumentConstants.maxExtractionBytes
        if result.utf8.count > maxBytes {
            let head = truncateToUTF8Bytes(result, maxBytes: maxBytes)
            return head + "\n\n... (truncated at \(maxBytes) bytes)"
        }
        return result
    }

    /// Truncates `s` to at most `maxBytes` UTF-8 bytes, snapping back to the
    /// last valid Character boundary. Without the Character-boundary snap, a
    /// mid-grapheme cut can produce a `String` that re-encodes longer than
    /// the cap (`String(Substring)` reinstates the cluster) — defeating the
    /// whole point of the byte budget.
    static func truncateToUTF8Bytes(_ s: String, maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        guard maxBytes > 0 else { return "" }
        var end = s.utf8.index(s.utf8.startIndex, offsetBy: maxBytes)
        while end > s.utf8.startIndex,
              String.Index(end, within: s) == nil
        {
            end = s.utf8.index(before: end)
        }
        return String(s.utf8[..<end]) ?? ""
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

    // MARK: - Private: DOC (legacy Word 97-2004 binary — rejected)

    /// Legacy `.doc` binary format has no pure-Swift reader. Reject with an
    /// actionable message — users can re-save as `.docx`.
    private static func extractDOC(from url: URL) -> String {
        failureMessage(url, reason: "legacy .doc binary format not supported — save as .docx")
    }

    // MARK: - Private: DOCX (Office Open XML)

    /// Reads `word/document.xml` from the DOCX package and concatenates text
    /// from `<w:t>` elements, with paragraph boundaries (`<w:p>`) becoming
    /// newlines. Pure Swift via `ZIPReader` + `XMLParser`.
    private static func extractDOCX(from url: URL) -> String {
        let data: Data?
        do {
            data = try ZIPReader.readEntry(named: "word/document.xml", from: url)
        } catch {
            return failureMessage(url, reason: String(describing: error))
        }
        guard let docXML = data else {
            return failureMessage(url, reason: "word/document.xml missing")
        }
        let text = DOCXTextCollector.collect(data: docXML)
        return text.isEmpty ? failureMessage(url, reason: "DOCX contains no text") : text
    }

    // MARK: - Private: ODT (OpenDocument Text)

    /// Reads `content.xml` from the ODT package and concatenates text from
    /// `<text:p>` / `<text:h>` / `<text:span>` elements, with paragraph and
    /// heading boundaries becoming newlines.
    private static func extractODT(from url: URL) -> String {
        let data: Data?
        do {
            data = try ZIPReader.readEntry(named: "content.xml", from: url)
        } catch {
            return failureMessage(url, reason: String(describing: error))
        }
        guard let contentXML = data else {
            return failureMessage(url, reason: "content.xml missing")
        }
        let text = ODTTextCollector.collect(data: contentXML)
        return text.isEmpty ? failureMessage(url, reason: "ODT contains no text") : text
    }

    // MARK: - Private: RTF / RTFD / HTML (via NSAttributedString)

    /// `NSAttributedString` treats `.documentType` as a hint, not an assertion:
    /// pointing its RTF path at an HTML/plaintext file silently succeeds. The
    /// `documentAttributes` out-pointer surfaces the type the parser actually
    /// picked so we can reject mismatches instead of returning decoded non-RTF.
    private static func extractRTF(from url: URL) -> String {
        do {
            var attrs: NSDictionary?
            let attr = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: &attrs
            )
            if let detected = attrs?[NSAttributedString.DocumentAttributeKey.documentType] as? String,
               detected != NSAttributedString.DocumentType.rtf.rawValue
            {
                return failureMessage(url, reason: "file is not valid RTF (detected: \(detected))")
            }
            let text = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? failureMessage(url, reason: "RTF contains no text") : text
        } catch {
            return failureMessage(url, reason: "could not read RTF: \(error.localizedDescription)")
        }
    }

    /// RTFD is a package directory (`foo.rtfd/` + `TXT.rtf` + resources).
    /// Read `TXT.rtf` inside and delegate to `extractRTF`. Fail if absent.
    private static func extractRTFD(from url: URL) -> String {
        let internalRTF = url.appendingPathComponent("TXT.rtf")
        guard FileManager.default.fileExists(atPath: internalRTF.path) else {
            return failureMessage(url, reason: "RTFD package missing TXT.rtf")
        }
        return extractRTF(from: internalRTF)
    }

    // MARK: - Private: XLSX

    private static func extractXLSX(from url: URL) -> String {
        // Collect ALL errors — later iterations must not mask earlier ones.
        // Even when sections parse successfully, a sharedStrings failure is
        // surfaced as a warning (string cells will show as integer indices).
        var errors: [String] = []
        var sharedStringsFailed = false

        // 1. Shared strings table (optional — some spreadsheets have only inline strings)
        let sharedStrings: [String]
        do {
            if let ssData = try ZIPReader.readEntry(named: "xl/sharedStrings.xml", from: url) {
                sharedStrings = SharedStringsParser.parse(data: ssData)
            } else {
                sharedStrings = []
            }
        } catch {
            errors.append("shared strings: \(error)")
            sharedStringsFailed = true
            sharedStrings = []
        }

        // 2. List sheets
        let entryNames: [String]
        do {
            entryNames = try ZIPReader.listEntries(at: url).map(\.name)
        } catch {
            return failureMessage(url, reason: String(describing: error))
        }
        let sheetEntries = entryNames
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted()

        guard !sheetEntries.isEmpty else {
            let reason = errors.isEmpty ? "no worksheet data found" : errors.joined(separator: "; ")
            return failureMessage(url, reason: reason)
        }

        // 3. Parse each sheet into markdown table
        var sections: [String] = []
        for (index, entry) in sheetEntries.enumerated() {
            let data: Data?
            do {
                data = try ZIPReader.readEntry(named: entry, from: url)
            } catch {
                errors.append("sheet \(index + 1): \(error)")
                continue
            }
            guard let sheetData = data else {
                errors.append("sheet \(index + 1): listed in archive but entry body missing")
                continue
            }
            let rows = XLSXSheetParser.parse(data: sheetData, sharedStrings: sharedStrings)
            guard !rows.isEmpty else { continue }

            let header = "### Sheet \(index + 1)"
            let table = formatMarkdownTable(rows: rows, maxRows: DocumentConstants.maxXLSXRows)
            sections.append(header + "\n\n" + table)
        }

        if sections.isEmpty {
            let reason = errors.isEmpty ? "empty spreadsheet" : errors.joined(separator: "; ")
            return failureMessage(url, reason: reason)
        }

        // Some content extracted, but shared strings failed — warn the reader
        // that string cells may render as integer indices instead of text.
        if sharedStringsFailed {
            let warning = "[Warning: shared string table unreadable — string cells may show as integer indices]"
            return warning + "\n\n" + sections.joined(separator: "\n\n")
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Private: PPTX

    private static func extractPPTX(from url: URL) -> String {
        let entryNames: [String]
        do {
            entryNames = try ZIPReader.listEntries(at: url).map(\.name)
        } catch {
            return failureMessage(url, reason: String(describing: error))
        }
        let slideEntries = entryNames
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { slideNumber($0) < slideNumber($1) }

        guard !slideEntries.isEmpty else {
            return failureMessage(url, reason: "no slide content found")
        }

        var sections: [String] = []
        var capturedError: String?
        for (index, entry) in slideEntries.prefix(DocumentConstants.maxPPTXSlides).enumerated() {
            let data: Data?
            do {
                data = try ZIPReader.readEntry(named: entry, from: url)
            } catch {
                capturedError = String(describing: error)
                continue
            }
            guard let slideData = data else { continue }
            let texts = XMLTextCollector.collect(data: slideData, tagName: "a:t")
            let joined = texts
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: " ")
            if !joined.isEmpty {
                sections.append("**Slide \(index + 1):** \(joined)")
            }
        }

        if sections.isEmpty {
            return failureMessage(url, reason: capturedError ?? "no text content in slides")
        }
        return sections.joined(separator: "\n\n")
    }

    /// Extract slide number from path like "ppt/slides/slide12.xml" → 12.
    private static func slideNumber(_ path: String) -> Int {
        let name = (path as NSString).lastPathComponent
        let digits = name.filter(\.isNumber)
        return Int(digits) ?? 0
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
    private var inInlineT = false
    private var currentInlineT = ""

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
            inInlineT = true
            currentInlineT = ""
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
        case "t" where inInlineT:
            inlineText += currentInlineT
            inInlineT = false
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
        if inInlineT { currentInlineT += string }
    }
}

/// Parses DOCX `word/document.xml` into plain text.
/// Joins `<w:t>` contents; `<w:p>` boundaries emit `"\n"`. `<w:br/>` emits
/// a newline inside a paragraph. Ignores drawings and everything outside `<w:t>`.
private final class DOCXTextCollector: NSObject, XMLParserDelegate {
    private var accumulator = ""
    private var inText = false
    private var runBuffer = ""

    /// Returns extracted plain text. If XML parsing failed mid-document,
    /// surfaces a warning marker — even when no text was collected. Returning
    /// `""` on parse failure would make the caller emit the generic
    /// "DOCX contains no text" message, indistinguishable from a truly
    /// blank document.
    static func collect(data: Data) -> String {
        let collector = DOCXTextCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        let parsed = parser.parse()
        if !parsed { collector.accumulator += collector.runBuffer }
        let text = collector.accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        if !parsed {
            let reason = parser.parserError?.localizedDescription ?? "malformed XML"
            let warning = "[Warning: XML parse stopped early — \(reason); content may be truncated]"
            return text.isEmpty ? warning : text + "\n\n" + warning
        }
        return text
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        if elementName == "w:t" {
            inText = true
            runBuffer = ""
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        switch elementName {
        case "w:t":
            accumulator += runBuffer
            inText = false
        case "w:p":
            accumulator += "\n"
        case "w:br":
            // Soft line break inside a paragraph (Shift+Enter in Word).
            accumulator += runBuffer
            runBuffer = ""
            accumulator += "\n"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { runBuffer += string }
    }
}

/// Parses ODT `content.xml` into plain text.
///
/// Joins `<text:span>` contents inline; `<text:p>` and `<text:h>` boundaries
/// emit `"\n"`. Text inside `<office:annotation>`, `<text:tracked-changes>`,
/// `<text:notes-configuration>`, and similar metadata wrappers is suppressed
/// — their child `<text:p>` elements would otherwise mix revision/annotation
/// content into the main body.
private final class ODTTextCollector: NSObject, XMLParserDelegate {
    private var accumulator = ""
    private var textDepth = 0         // > 0 inside text:p / text:h / text:span
    private var suppressionDepth = 0  // > 0 inside annotation / tracked-changes / notes metadata

    /// Tags whose subtree must not contribute to the extracted body text —
    /// includes the text:p children they wrap.
    private static let suppressionTags: Set<String> = [
        "office:annotation",
        "office:annotation-end",
        "text:tracked-changes",
        "text:notes-configuration",
        "text:note-citation",
    ]
    private static let textTags: Set<String> = [
        "text:p", "text:h", "text:span",
    ]

    static func collect(data: Data) -> String {
        let collector = ODTTextCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        let parsed = parser.parse()
        let text = collector.accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        if !parsed {
            let reason = parser.parserError?.localizedDescription ?? "malformed XML"
            let warning = "[Warning: XML parse stopped early — \(reason); content may be truncated]"
            return text.isEmpty ? warning : text + "\n\n" + warning
        }
        return text
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        if Self.suppressionTags.contains(elementName) {
            suppressionDepth += 1
        } else if Self.textTags.contains(elementName) {
            textDepth += 1
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        if Self.suppressionTags.contains(elementName) {
            if suppressionDepth > 0 { suppressionDepth -= 1 }
            return
        }
        switch elementName {
        case "text:p", "text:h":
            if textDepth > 0 { textDepth -= 1 }
            if suppressionDepth == 0 { accumulator += "\n" }
        case "text:span":
            if textDepth > 0 { textDepth -= 1 }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textDepth > 0 && suppressionDepth == 0 {
            accumulator += string
        }
    }
}
