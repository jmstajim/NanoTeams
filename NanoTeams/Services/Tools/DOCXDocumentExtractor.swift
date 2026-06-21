import Foundation

/// Extracts plain text from a DOCX (Office Open XML) package.
///
/// Reads `word/document.xml` and concatenates text from `<w:t>` elements, with
/// paragraph boundaries (`<w:p>`) becoming newlines. Pure Swift via `ZIPReader`
/// + `XMLParser`.
nonisolated struct DOCXDocumentExtractor: DocumentFormatExtractor {
    func extract(from url: URL) -> String {
        let data: Data?
        do {
            data = try ZIPReader.readEntry(named: "word/document.xml", from: url)
        } catch {
            return DocumentExtractionFailure.message(url, reason: String(describing: error))
        }
        guard let docXML = data else {
            return DocumentExtractionFailure.message(url, reason: "word/document.xml missing")
        }
        let text = DOCXTextCollector.collect(data: docXML)
        return text.isEmpty
            ? DocumentExtractionFailure.message(url, reason: "DOCX contains no text")
            : text
    }
}

/// Parses DOCX `word/document.xml` into plain text.
/// Joins `<w:t>` contents; `<w:p>` boundaries emit `"\n"`. `<w:br/>` emits
/// a newline inside a paragraph. Ignores drawings and everything outside `<w:t>`.
nonisolated private final class DOCXTextCollector: NSObject, XMLParserDelegate {
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
