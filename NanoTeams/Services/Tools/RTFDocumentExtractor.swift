import Foundation
import AppKit

/// Extracts text from RTF via `NSAttributedString`.
///
/// `NSAttributedString` treats `.documentType` as a hint, not an assertion:
/// pointing its RTF path at an HTML/plaintext file silently succeeds. The
/// `documentAttributes` out-pointer surfaces the type the parser actually
/// picked so we reject mismatches instead of returning decoded non-RTF.
nonisolated struct RTFDocumentExtractor: DocumentFormatExtractor {
    func extract(from url: URL) -> String {
        do {
            var attrs: NSDictionary?
            let attr = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: &attrs
            )
            if let detected = attrs?[NSAttributedString.DocumentAttributeKey.documentType] as? String,
               detected != NSAttributedString.DocumentType.rtf.rawValue
            {
                return DocumentExtractionFailure.message(url, reason: "file is not valid RTF (detected: \(detected))")
            }
            let text = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty
                ? DocumentExtractionFailure.message(url, reason: "RTF contains no text")
                : text
        } catch {
            return DocumentExtractionFailure.message(url, reason: "could not read RTF: \(error.localizedDescription)")
        }
    }
}

/// Extracts text from an RTFD package (`foo.rtfd/` + `TXT.rtf` + resources) by
/// reading the internal `TXT.rtf` and delegating to `RTFDocumentExtractor`.
nonisolated struct RTFDDocumentExtractor: DocumentFormatExtractor {
    func extract(from url: URL) -> String {
        let internalRTF = url.appendingPathComponent("TXT.rtf")
        guard FileManager.default.fileExists(atPath: internalRTF.path) else {
            return DocumentExtractionFailure.message(url, reason: "RTFD package missing TXT.rtf")
        }
        return RTFDocumentExtractor().extract(from: internalRTF)
    }
}

/// Legacy `.doc` binary format (Word 97-2004) has no pure-Swift reader. Reject
/// with an actionable message — users can re-save as `.docx`.
nonisolated struct LegacyDOCExtractor: DocumentFormatExtractor {
    func extract(from url: URL) -> String {
        DocumentExtractionFailure.message(url, reason: "legacy .doc binary format not supported — save as .docx")
    }
}
