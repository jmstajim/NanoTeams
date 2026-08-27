import Foundation

/// Facade for document text extraction and export.
///
/// Owns the format-agnostic concerns — supported-extension detection, the
/// process-lifetime extraction cache, the UTF-8 byte cap, and failure
/// detection — and dispatches per-format decoding to a `DocumentFormatExtractor`
/// Strategy (`PDFDocumentExtractor`, `DOCXDocumentExtractor`, …). Export is
/// delegated to `DocumentExporter`.
///
/// **Reading**:
/// - PDF — `PDFDocumentExtractor` (PDFKit)
/// - DOCX / ODT / XLSX / PPTX — ZIP + XMLParser extractors (in-process)
/// - RTF / RTFD — `RTFDocumentExtractor` / `RTFDDocumentExtractor` (NSAttributedString)
/// - DOC (legacy Word 97-2004 binary) — `LegacyDOCExtractor` (rejected with message)
///
/// Anything not in `DocumentConstants.supportedReadExtensions` returns `nil`
/// from `extract`; callers then read the file as raw UTF-8. This is
/// intentional for source-like formats (`.html`, `.xml`, `.md`, `.json`,
/// source code) — callers need verbatim markup for source-editing workflows.
///
/// **Export**: PDF, RTF, DOCX (delegated to `DocumentExporter`, macOS-only).
///
/// Outcomes are classified, never encoded into the returned text — see
/// `DocumentExtractionOutcome`.
nonisolated enum DocumentTextExtractor {

    /// Supported export formats for `create_artifact(format:)`.
    enum ExportFormat: String {
        case pdf, rtf, docx
    }

    /// Per-extension Strategy registry. The single point that decides which
    /// `DocumentFormatExtractor` handles a format — extend here to add a format
    /// (Open/Closed). Conformers are stateless, so shared instances are safe.
    private static let extractors: [String: any DocumentFormatExtractor] = [
        "pdf": PDFDocumentExtractor(),
        "xlsx": XLSXDocumentExtractor(),
        "pptx": PPTXDocumentExtractor(),
        "docx": DOCXDocumentExtractor(),
        "odt": ODTDocumentExtractor(),
        "rtf": RTFDocumentExtractor(),
        "rtfd": RTFDDocumentExtractor(),
        "doc": LegacyDOCExtractor(),
    ]

    // MARK: - Detection

    static func isSupported(extension ext: String) -> Bool {
        DocumentConstants.supportedReadExtensions.contains(ext.lowercased())
    }

    // MARK: - Text Extraction

    /// Process-lifetime cache for extraction outcomes. Keyed by absolute
    /// path with a stored `(mtime, size)` so a file changed on disk reports a
    /// miss and re-extracts. `NSCache` is documented thread-safe; entries are
    /// fully immutable, so `nonisolated(unsafe)` is sound.
    ///
    /// Bounds: `countLimit=128` AND `totalCostLimit≈256MB`. Without the cost
    /// limit, 128 entries of multi-MB Office documents could pin > 2 GB of
    /// RAM — `NSCache` only enforces count when no cost is set.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedDocumentOutcome> = {
        let c = NSCache<NSString, CachedDocumentOutcome>()
        c.countLimit = 128
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()

    nonisolated private final class CachedDocumentOutcome: Sendable {
        let outcome: DocumentExtractionOutcome
        let mtime: Date
        let size: UInt64
        init(outcome: DocumentExtractionOutcome, mtime: Date, size: UInt64) {
            self.outcome = outcome
            self.mtime = mtime
            self.size = size
        }
    }

    /// Reads `(mtime, size)`. Returns `nil` on permission errors, missing files, or
    /// network-volume stalls. Loud diagnostic so a regression that silently disables the
    /// cache for a whole class of files (e.g. a new sandbox restriction) is visible in
    /// the network log.
    ///
    /// Also `nil` for a DIRECTORY, which sounds like an edge case and is not: `.rtfd` is a
    /// bundle, so the URL handed to the extractor is a directory whose mtime and size
    /// describe the folder record, not `TXT.rtf`. Rewriting the inner file in place moves
    /// neither, so the key cannot see the change — and an `.empty` verdict cached under it
    /// would be a wrong answer that produces no output to notice.
    nonisolated private static func mtimeAndSize(for url: URL) -> (mtime: Date, size: UInt64)? {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attrs[.type] as? FileAttributeType) != .typeDirectory else { return nil }
            guard let mtime = attrs[.modificationDate] as? Date else { return nil }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            return (mtime, size)
        } catch {
            // Per-call extraction still works (we just bypass the cache).
            // Surface so a stat-failing class of files is visible in logs.
            NSLog("DocumentTextExtractor: stat failed for \(url.lastPathComponent): \(error.localizedDescription) — cache disabled for this read")
            return nil
        }
    }

    /// Extracts one document, applying the byte cap and the process-lifetime cache.
    /// Returns `nil` only if the extension is not a supported document format (caller
    /// falls back to reading raw UTF-8).
    static func extract(from fileURL: URL) -> DocumentExtractionOutcome? {
        let ext = fileURL.pathExtension.lowercased()
        guard let extractor = extractors[ext] else { return nil }

        // mtime+size cache lookup. Stat lives one block up because we use the
        // same values for both the hit/miss check and the write back, so
        // there's no TOCTOU window where the file changes between miss and
        // write — even if it does, the next call will re-stat and miss again.
        let key = fileURL.path as NSString
        let stat = mtimeAndSize(for: fileURL)
        if let stat,
           let cached = cache.object(forKey: key),
           cached.mtime == stat.mtime,
           cached.size == stat.size
        {
            return cached.outcome
        }

        let outcome = capped(extractor.extract(from: fileURL))

        // `.text` and `.empty` are both deterministic for a given `(mtime, size)`, so both
        // cache: an image-only PDF re-runs PDFKit on every search otherwise. `.failure` does
        // not — those are typically transient (locked file, disk error, malformed XML at
        // boot time) and pinning one would defeat retry.
        if let stat, outcome.isCacheable {
            cache.setObject(
                CachedDocumentOutcome(outcome: outcome, mtime: stat.mtime, size: stat.size),
                forKey: key,
                // Cost is the SOURCE file's size, not the result's: it stands for the work a
                // hit avoids, and it keeps the two bounds consistent. Charging the result
                // instead would price an `.empty` verdict at ~30 bytes — invisible to
                // `totalCostLimit` while still occupying one of the 128 slots, so a folder of
                // scanned PDFs would evict precisely the expensive entries the cache exists for.
                cost: Int(min(stat.size, UInt64(Int.max)))
            )
        }

        return outcome
    }

    /// Applies `DocumentConstants.maxExtractionBytes` to extracted text.
    ///
    /// The cut is recorded as a warning rather than only as a trailing marker inside the
    /// string: the marker is prose, and the one consumer that most needs to know — the
    /// byte-level search scanner — never reads the text as prose, so a 2 MB PDF was
    /// searched through its first 500 KB in silence.
    nonisolated private static func capped(_ outcome: DocumentExtractionOutcome) -> DocumentExtractionOutcome {
        guard case .text(let text, let warnings) = outcome else { return outcome }
        let maxBytes = DocumentConstants.maxExtractionBytes
        guard text.utf8.count > maxBytes else { return outcome }
        let head = truncateToUTF8Bytes(text, maxBytes: maxBytes)
        return .text(head + "\n\n" + truncationMarker,
                     warnings: warnings + ["extracted text truncated at \(maxBytes) bytes"])
    }

    /// Trailing marker appended to capped text. A reader looking at the text alone must be
    /// able to see that it ends early.
    static var truncationMarker: String {
        "... (truncated at \(DocumentConstants.maxExtractionBytes) bytes)"
    }

    /// Truncates `s` to at most `maxBytes` UTF-8 bytes, snapping back to the
    /// last valid Character boundary. Without the Character-boundary snap, a
    /// mid-grapheme cut can produce a `String` that re-encodes longer than
    /// the cap (`String(Substring)` reinstates the cluster) — defeating the
    /// whole point of the byte budget.
    static func truncateToUTF8Bytes(_ s: String, maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        guard maxBytes > 0 else { return "" }
        var end = s.utf8.index(s.utf8.startIndex, offsetBy: maxBytes)
        while end > s.utf8.startIndex,
              String.Index(end, within: s) == nil
        {
            end = s.utf8.index(before: end)
        }
        return String(s.utf8[..<end]) ?? ""
    }

    // MARK: - Export

    /// Export text content to a document format. Returns binary data or nil on failure.
    static func export(text: String, to format: ExportFormat) -> Data? {
        DocumentExporter.export(text: text, to: format)
    }

}

nonisolated private extension DocumentExtractionOutcome {
    /// Whether this outcome is a stable property of the bytes on disk.
    var isCacheable: Bool {
        switch self {
        case .text, .empty: return true
        case .failure: return false
        }
    }
}
