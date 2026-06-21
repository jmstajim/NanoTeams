import Foundation

/// Extracts text from a PPTX (PresentationML) package, joining each slide's
/// `<a:t>` runs into a labelled section. Slides are ordered by their numeric
/// suffix (`slide12.xml` → 12) rather than lexically.
nonisolated struct PPTXDocumentExtractor: DocumentFormatExtractor {
    func extract(from url: URL) -> String {
        let entryNames: [String]
        do {
            entryNames = try ZIPReader.listEntries(at: url).map(\.name)
        } catch {
            return DocumentExtractionFailure.message(url, reason: String(describing: error))
        }
        let slideEntries = entryNames
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { Self.slideNumber($0) < Self.slideNumber($1) }

        guard !slideEntries.isEmpty else {
            return DocumentExtractionFailure.message(url, reason: "no slide content found")
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
            return DocumentExtractionFailure.message(url, reason: capturedError ?? "no text content in slides")
        }
        return sections.joined(separator: "\n\n")
    }

    /// Extract slide number from path like "ppt/slides/slide12.xml" → 12.
    static func slideNumber(_ path: String) -> Int {
        let name = (path as NSString).lastPathComponent
        let digits = name.filter(\.isNumber)
        return Int(digits) ?? 0
    }
}

/// Collects text content from all occurrences of a specific XML element.
nonisolated private final class XMLTextCollector: NSObject, XMLParserDelegate {
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
