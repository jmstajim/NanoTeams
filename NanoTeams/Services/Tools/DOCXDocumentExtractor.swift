import Foundation

/// Extracts plain text from a DOCX (Office Open XML) package.
///
/// Reads `word/document.xml` and concatenates text from `<w:t>` elements, with
/// paragraph boundaries (`<w:p>`) becoming newlines. Pure Swift via `ZIPReader`
/// + `XMLParser`.
nonisolated struct DOCXDocumentExtractor: DocumentFormatExtractor {
    func extract(from url: URL) -> DocumentExtractionOutcome {
        let data: Data?
        do {
            data = try ZIPReader.readEntry(named: "word/document.xml", from: url)
        } catch {
            return .failure(reason: String(describing: error))
        }
        guard let docXML = data else {
            return .failure(reason: "word/document.xml missing")
        }
        let collected = DOCXTextCollector.collect(data: docXML)
        if collected.text.isEmpty {
            // A parse that aborted before any content is a FAILURE, not a blank document —
            // the two were indistinguishable while both returned "".
            if let parseError = collected.parseError {
                return .failure(reason: parseError)
            }
            // Only `word/document.xml` was opened, so "no text" is a fact about what we
            // read, not about the document — the parts below can hold text we never saw.
            return .empty(reason: "DOCX contains no text",
                          scope: .mainPartOnly(unread: "headers, footers, footnotes and comments"))
        }
        return .text(collected.text, warnings: collected.parseError.map { [$0] } ?? [])
    }
}

/// Parses DOCX `word/document.xml` into plain text.
/// Joins `<w:t>` contents; `<w:p>` boundaries emit `"\n"`. `<w:br/>` emits
/// a newline inside a paragraph. Ignores drawings and everything outside `<w:t>`.
nonisolated private final class DOCXTextCollector: NSObject, XMLParserDelegate {
    private var accumulator = ""
    private var inText = false
    private var runBuffer = ""

    /// Returns extracted plain text alongside the parse abort, if any, as separate
    /// values. They are reported separately because they coexist: an abort partway
    /// through leaves real text AND a caveat about it, and a caller told only "here is
    /// a string" cannot tell a truncation notice from the document's own words.
    static func collect(data: Data) -> (text: String, parseError: String?) {
        let collector = DOCXTextCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        let parsed = parser.parse()
        if !parsed { collector.accumulator += collector.runBuffer }
        let text = collector.accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parsed else { return (text, nil) }
        let reason = parser.parserError?.localizedDescription ?? "malformed XML"
        return (text, "XML parse stopped early — \(reason); content may be truncated")
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
