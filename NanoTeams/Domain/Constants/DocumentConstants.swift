import Foundation

/// Constants for document format reading and export.
enum DocumentConstants {

    /// Document extensions that `DocumentTextExtractor` converts to plain text.
    /// Source-like text formats (`.html`, `.xml`, `.md`, `.json`, source code)
    /// are deliberately absent — callers fall back to raw UTF-8 so markup
    /// stays visible verbatim for source-editing workflows.
    static let supportedReadExtensions: Set<String> = [
        "pdf", "docx", "doc", "rtf", "rtfd", "odt", "xlsx", "pptx",
    ]

    // MARK: - Limits

    /// Maximum UTF-8 bytes of extracted text returned by `extractText`.
    /// Enforced in `DocumentTextExtractor.extractText`; also drives the
    /// `ZIPReader` output cap (headroom ×2 — see comment there).
    static let maxExtractionBytes = 500_000

    /// Maximum rows extracted from a single XLSX sheet.
    static let maxXLSXRows = 200

    /// Maximum slides extracted from a PPTX file.
    static let maxPPTXSlides = 50

    /// Hard cap on `.docx`/`.xlsx`/`.pptx`/`.odt` file size before in-process ZIP parsing.
    /// Larger files are rejected outright by `ZIPReader` to avoid 100+ MB `Data` allocations.
    static let maxDocumentFileSize: Int = 50 * 1024 * 1024

    // MARK: - MIME Mapping

    static let mimeTypes: [String: String] = [
        "pdf": "application/pdf",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "doc": "application/msword",
        "rtf": "application/rtf",
        "odt": "application/vnd.oasis.opendocument.text",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ]
}
