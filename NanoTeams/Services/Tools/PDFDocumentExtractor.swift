import Foundation
import PDFKit

/// Extracts selectable text from a PDF via `PDFKit`, joining per-page text with
/// blank-line separators.
///
/// PDFKit owns a PDF's text layer entirely, so this reader sees the whole document —
/// which is why a scanned, image-only PDF reports `.empty(scope: .wholeDocument)`:
/// "no text" here is positive evidence, not a gap in what we looked at.
nonisolated struct PDFDocumentExtractor: DocumentFormatExtractor {
    func extract(from url: URL) -> DocumentExtractionOutcome {
        guard let doc = PDFDocument(url: url) else {
            return .failure(reason: "could not open PDF")
        }

        var pages: [String] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let text = page.string, !text.isEmpty {
                pages.append(text)
            }
        }

        let joined = pages.joined(separator: "\n\n")
        return joined.isEmpty
            ? .empty(reason: "PDF has no selectable text", scope: .wholeDocument)
            : .text(joined, warnings: [])
    }
}
