import Foundation

/// Constants for document format reading and export.
enum DocumentConstants {

    /// All document extensions that `DocumentTextExtractor` can convert to plain text.
    static let supportedReadExtensions: Set<String> = [
        "pdf", "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "xlsx", "pptx",
    ]

    // MARK: - Limits

    /// Maximum characters of extracted text returned by `extractText`.
    static let maxExtractionChars = 500_000

    /// Maximum rows extracted from a single XLSX sheet.
    static let maxXLSXRows = 200

    /// Maximum slides extracted from a PPTX file.
    static let maxPPTXSlides = 50

    // MARK: - External Tool Paths

    static let textutilPath = "/usr/bin/textutil"
    static let unzipPath = "/usr/bin/unzip"
    static let textutilTimeout: TimeInterval = 30
    static let unzipTimeout: TimeInterval = 15

    // MARK: - MIME Mapping

    static let mimeTypes: [String: String] = [
        "pdf": "application/pdf",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "doc": "application/msword",
        "rtf": "application/rtf",
        "odt": "application/vnd.oasis.opendocument.text",
        "html": "text/html",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ]
}
