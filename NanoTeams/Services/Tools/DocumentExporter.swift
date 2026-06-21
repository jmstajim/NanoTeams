import Foundation
import AppKit

/// Renders plain text into a binary document format for `create_artifact(format:)`.
///
/// PDF goes through an `NSTextView`/`NSLayoutManager` layout pass into a
/// `CGContext` PDF page; RTF / DOCX go through `NSAttributedString` document
/// serialization. macOS-only via AppKit (not yet iOS-compatible).
nonisolated enum DocumentExporter {

    /// Export text content to a document format. Returns binary data or nil on failure.
    static func export(text: String, to format: DocumentTextExtractor.ExportFormat) -> Data? {
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
}
