import Foundation

/// Extracts plain text from an ODT (OpenDocument Text) package.
///
/// Reads `content.xml` and concatenates text from `<text:p>` / `<text:h>` /
/// `<text:span>` elements, with paragraph and heading boundaries becoming
/// newlines.
nonisolated struct ODTDocumentExtractor: DocumentFormatExtractor {
    func extract(from url: URL) -> String {
        let data: Data?
        do {
            data = try ZIPReader.readEntry(named: "content.xml", from: url)
        } catch {
            return DocumentExtractionFailure.message(url, reason: String(describing: error))
        }
        guard let contentXML = data else {
            return DocumentExtractionFailure.message(url, reason: "content.xml missing")
        }
        let text = ODTTextCollector.collect(data: contentXML)
        return text.isEmpty
            ? DocumentExtractionFailure.message(url, reason: "ODT contains no text")
            : text
    }
}

/// Parses ODT `content.xml` into plain text.
///
/// Joins `<text:span>` contents inline; `<text:p>` and `<text:h>` boundaries
/// emit `"\n"`. Text inside `<office:annotation>`, `<text:tracked-changes>`,
/// `<text:notes-configuration>`, and similar metadata wrappers is suppressed
/// — their child `<text:p>` elements would otherwise mix revision/annotation
/// content into the main body.
nonisolated private final class ODTTextCollector: NSObject, XMLParserDelegate {
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
