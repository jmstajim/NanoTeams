import Foundation

/// Strategy for extracting plain text from one document format (PDF, DOCX, …).
///
/// Each conformer owns the format-specific decode (ZIP entry reads, XML walking,
/// `NSAttributedString` decoding, `PDFKit`). Conformers are stateless value
/// types so a single shared instance is safe to reuse across threads — hence
/// the `Sendable` requirement.
///
/// Contract: `extract(from:)` classifies its own result as `DocumentExtractionOutcome`
/// rather than throwing or encoding failure into the returned text. Reasons travel
/// BARE — no filename, no brackets: the caller knows the URL and renders it
/// (`SkippedFile` already carries the path in a neighbouring field). Returned text is
/// raw (un-truncated, un-cached); the facade (`DocumentTextExtractor`) owns the byte
/// cap and the process-lifetime cache.
nonisolated protocol DocumentFormatExtractor: Sendable {
    func extract(from url: URL) -> DocumentExtractionOutcome
}

/// What a `DocumentFormatExtractor` found. Three outcomes, never simultaneously true.
///
/// This type replaced a `String` return whose failures were encoded as a sentinel
/// `"[Could not extract text from …]"` that callers detected by PREFIX. One value carried
/// two different facts — "could not read it" and "read it, there is no text" — so a caller
/// that needed to tell them apart could not: the distinction was destroyed one seam up
/// (CLAUDE.md #108). The prefix test also ran against real content, so a document whose
/// body happened to begin with that sentence was reported unreadable by every consumer.
nonisolated enum DocumentExtractionOutcome: Sendable {
    /// Extracted text, plus anything the reader wants the caller to know about how
    /// complete it is (a mid-document parse abort, an unreadable sheet, a byte cap).
    ///
    /// `warnings` exists because these facts coexist with text rather than replacing it —
    /// two fields, not two cases (CLAUDE.md #95). Before it, some were glued onto the text
    /// as a marker string and others were accumulated and then silently dropped.
    case text(String, warnings: [String])

    /// The document was read successfully and holds no extractable text.
    ///
    /// NOT a failure: nothing is wrong with the file or the reader, and a text search over
    /// it is honestly a zero-match rather than an omission. `scope` says how much of the
    /// document the reader actually saw, which is what decides whether silence is honest.
    case empty(reason: String, scope: EmptyScope)

    /// The document could not be opened or parsed.
    case failure(reason: String)

    /// How much of the document backed an `.empty` verdict.
    ///
    /// The extractors are not equally authoritative. PDFKit and `NSAttributedString` decode
    /// a whole document, so "no text" is positive evidence. The ZIP-based readers open one
    /// entry each (`word/document.xml`, `content.xml`, `ppt/slides/slide*.xml`,
    /// `xl/worksheets/sheet*.xml`), so their "no text" is evidence about OUR coverage —
    /// reporting it is the only way that gap is ever visible (CLAUDE.md #92).
    nonisolated enum EmptyScope: Sendable, Equatable {
        /// The reader saw the entire document.
        case wholeDocument
        /// The reader saw only the main part; `unread` names what it never opened.
        case mainPartOnly(unread: String)
    }
}

nonisolated extension DocumentExtractionOutcome {

    /// The extracted text — `nil` when there is none.
    ///
    /// Unlike the sentinel-string shape this replaced, "no text" is `nil` rather than a
    /// message that a caller might mistake for content, so a caller cannot accidentally
    /// treat a failure as the document.
    var extractedText: String? {
        guard case .text(let text, _) = self else { return nil }
        return text
    }

    /// Why there is no text — `nil` when there is text. Bare: no filename, no brackets.
    var reason: String? {
        switch self {
        case .text: return nil
        case .empty(let reason, _), .failure(let reason): return reason
        }
    }

    /// Caveats about text that WAS extracted (parse aborts, unreadable parts, byte cap).
    var warnings: [String] {
        guard case .text(_, let warnings) = self else { return [] }
        return warnings
    }

    /// Why a reader that found no text here should report an omission — `nil` when there is
    /// nothing to report.
    ///
    /// `nil` for `.text` (there was text) and for `.empty(.wholeDocument)` (the reader saw
    /// everything and found none, so zero matches is the whole truth). A `.mainPartOnly`
    /// emptiness names what went unexamined, because "we found nothing" and "we did not
    /// look there" are different answers.
    var omissionReason: String? {
        switch self {
        case .text:
            return nil
        case .empty(_, .wholeDocument):
            return nil
        case .empty(let reason, .mainPartOnly(let unread)):
            return "\(reason); \(unread) were not examined"
        case .failure(let reason):
            return reason
        }
    }

    /// Reader-facing sentence for an outcome that yielded no usable text — `nil` for `.text`.
    ///
    /// Rendering lives here rather than in the eight extractors so the filename is added
    /// once, by something that has the URL, and every consumer gets the same sentence.
    func message(for url: URL) -> String? {
        switch self {
        case .text:
            return nil
        case .empty(let reason, _), .failure(let reason):
            return "[Could not extract text from \(url.lastPathComponent): \(reason)]"
        }
    }
}
