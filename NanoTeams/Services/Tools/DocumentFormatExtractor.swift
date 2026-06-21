import Foundation

/// Strategy for extracting plain text from one document format (PDF, DOCX, …).
///
/// Each conformer owns the format-specific decode (ZIP entry reads, XML walking,
/// `NSAttributedString` decoding, `PDFKit`). Conformers are stateless value
/// types so a single shared instance is safe to reuse across threads — hence
/// the `Sendable` requirement.
///
/// Contract: `extract(from:)` ALWAYS returns a non-`nil` `String`. On failure it
/// returns `DocumentExtractionFailure.message(_:reason:)` rather than throwing —
/// the facade (`DocumentTextExtractor`) treats any `DocumentExtractionFailure`-
/// prefixed result as a non-cacheable miss. Returned text is raw (un-truncated,
/// un-cached); the facade owns the byte cap and the process-lifetime cache.
nonisolated protocol DocumentFormatExtractor: Sendable {
    func extract(from url: URL) -> String
}

/// Single source of truth for extraction failure messages, shared by every
/// `DocumentFormatExtractor` and re-exposed on `DocumentTextExtractor` for
/// back-compat callers (`isFailureMessage`, `failurePrefix`).
nonisolated enum DocumentExtractionFailure {
    /// Prefix used in extraction failure messages. Callers check this to tell an
    /// extraction failure apart from real content (e.g. to avoid caching it).
    static let prefix = "[Could not extract text"

    static func message(_ url: URL, reason: String) -> String {
        "\(prefix) from \(url.lastPathComponent): \(reason)]"
    }

    /// Returns true if the string is an extraction failure message (not real content).
    static func isFailure(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }
}
