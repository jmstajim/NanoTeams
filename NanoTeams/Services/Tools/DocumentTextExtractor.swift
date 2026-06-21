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
/// from `extractText`; callers then read the file as raw UTF-8. This is
/// intentional for source-like formats (`.html`, `.xml`, `.md`, `.json`,
/// source code) — callers need verbatim markup for source-editing workflows.
///
/// **Export**: PDF, RTF, DOCX (delegated to `DocumentExporter`, macOS-only).
///
/// All extract methods return a silent fallback message on failure —
/// `"[Could not extract text from <filename>: <reason>]"`.
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

    /// Process-lifetime cache for extracted document text. Keyed by absolute
    /// path with a stored `(mtime, size)` so a file changed on disk reports a
    /// miss and re-extracts. `NSCache` is documented thread-safe; entries are
    /// fully immutable, so `nonisolated(unsafe)` is sound.
    ///
    /// Bounds: `countLimit=128` AND `totalCostLimit≈256MB`. Without the cost
    /// limit, 128 entries of multi-MB Office documents could pin > 2 GB of
    /// RAM — `NSCache` only enforces count when no cost is set.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedDocumentText> = {
        let c = NSCache<NSString, CachedDocumentText>()
        c.countLimit = 128
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()

    nonisolated private final class CachedDocumentText: Sendable {
        let text: String
        let mtime: Date
        let size: UInt64
        init(text: String, mtime: Date, size: UInt64) {
            self.text = text
            self.mtime = mtime
            self.size = size
        }
    }

    /// Reads `(mtime, size)` via `lstat`. Returns `nil` on permission errors,
    /// missing files, or network-volume stalls. Loud diagnostic so a regression
    /// that silently disables the cache for a whole class of files (e.g. a
    /// new sandbox restriction) is visible in the network log.
    nonisolated private static func mtimeAndSize(for url: URL) -> (mtime: Date, size: UInt64)? {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
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

    /// Returns extracted plain text, or a `[Could not extract text ...]` message on failure.
    /// Returns `nil` only if the extension is not a supported document format (caller falls back to UTF-8).
    static func extractText(from fileURL: URL) -> String? {
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
            return cached.text
        }

        let result = extractor.extract(from: fileURL)

        let maxBytes = DocumentConstants.maxExtractionBytes
        let finalResult: String
        if result.utf8.count > maxBytes {
            let head = truncateToUTF8Bytes(result, maxBytes: maxBytes)
            finalResult = head + "\n\n... (truncated at \(maxBytes) bytes)"
        } else {
            finalResult = result
        }

        // Only cache successful extractions. Failure messages are typically
        // transient (locked file, disk error, malformed XML at boot time) —
        // pinning them would defeat retry.
        if let stat, !isFailureMessage(finalResult) {
            cache.setObject(
                CachedDocumentText(text: finalResult, mtime: stat.mtime, size: stat.size),
                forKey: key,
                // Cost = UTF-8 byte count; pairs with `totalCostLimit`. NSCache
                // evicts least-recently-used entries when the sum exceeds the
                // cap, so an unexpectedly large doc can't pin the cache.
                cost: finalResult.utf8.count
            )
        }

        return finalResult
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

    // MARK: - Failure Detection

    /// Prefix used in extraction failure messages. Callers can check this to distinguish
    /// extraction failures from real content (e.g., to avoid caching failures as valid reads).
    static let failurePrefix = DocumentExtractionFailure.prefix

    /// Returns true if the string is an extraction failure message (not real content).
    static func isFailureMessage(_ text: String) -> Bool {
        DocumentExtractionFailure.isFailure(text)
    }
}
