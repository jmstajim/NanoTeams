import Foundation
import PDFKit

/// Extracts selectable text from a PDF via `PDFKit`, joining per-page text with
/// blank-line separators. Returns a failure message when the document can't be
/// opened or carries no selectable text (scanned/image-only PDFs).
nonisolated struct PDFDocumentExtractor: DocumentFormatExtractor {
    func extract(from url: URL) -> String {
        guard let doc = PDFDocument(url: url) else {
            return DocumentExtractionFailure.message(url, reason: "could not open PDF")
        }

        var pages: [String] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let text = page.string, !text.isEmpty {
                pages.append(text)
            }
        }

        let joined = pages.joined(separator: "\n\n")
        return joined.isEmpty
            ? DocumentExtractionFailure.message(url, reason: "PDF has no selectable text")
            : joined
    }
}
