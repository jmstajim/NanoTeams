import Foundation

/// Extracts text from an XLSX (SpreadsheetML) package, rendering each worksheet
/// as a markdown table. Resolves shared-string references; surfaces a warning
/// (instead of failing) when the shared-string table is unreadable but cells
/// still parse.
nonisolated struct XLSXDocumentExtractor: DocumentFormatExtractor {
    func extract(from url: URL) -> String {
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
            return DocumentExtractionFailure.message(url, reason: String(describing: error))
        }
        let sheetEntries = entryNames
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted()

        guard !sheetEntries.isEmpty else {
            let reason = errors.isEmpty ? "no worksheet data found" : errors.joined(separator: "; ")
            return DocumentExtractionFailure.message(url, reason: reason)
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
            let table = Self.formatMarkdownTable(rows: rows, maxRows: DocumentConstants.maxXLSXRows)
            sections.append(header + "\n\n" + table)
        }

        if sections.isEmpty {
            let reason = errors.isEmpty ? "empty spreadsheet" : errors.joined(separator: "; ")
            return DocumentExtractionFailure.message(url, reason: reason)
        }

        // Some content extracted, but shared strings failed — warn the reader
        // that string cells may render as integer indices instead of text.
        if sharedStringsFailed {
            let warning = "[Warning: shared string table unreadable — string cells may show as integer indices]"
            return warning + "\n\n" + sections.joined(separator: "\n\n")
        }
        return sections.joined(separator: "\n\n")
    }

    static func formatMarkdownTable(rows: [[String]], maxRows: Int) -> String {
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
}

/// Parses XLSX `sharedStrings.xml` into an array of string values.
/// Handles rich-text entries (`<si><r><t>bold</t></r><r><t> normal</t></r></si>`)
/// by concatenating all `<t>` text within each `<si>` element.
nonisolated private final class SharedStringsParser: NSObject, XMLParserDelegate {
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
nonisolated private final class XLSXSheetParser: NSObject, XMLParserDelegate {
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
