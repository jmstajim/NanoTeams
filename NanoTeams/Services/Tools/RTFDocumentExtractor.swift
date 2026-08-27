import Foundation
import AppKit

/// Extracts text from RTF via `NSAttributedString`.
///
/// `NSAttributedString` treats `.documentType` as a hint, not an assertion:
/// pointing its RTF path at an HTML/plaintext file silently succeeds. The
/// `documentAttributes` out-pointer surfaces the type the parser actually
/// picked so we reject mismatches instead of returning decoded non-RTF.
nonisolated struct RTFDocumentExtractor: DocumentFormatExtractor {
    func extract(from url: URL) -> DocumentExtractionOutcome {
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
                return .failure(reason: "file is not valid RTF (detected: \(detected))")
            }
            let text = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty
                // `NSAttributedString` decodes the whole document, so this verdict covers
                // all of it.
                ? .empty(reason: "RTF contains no text", scope: .wholeDocument)
                : .text(text, warnings: [])
        } catch {
            return .failure(reason: "could not read RTF: \(error.localizedDescription)")
        }
    }
}

/// Extracts text from an RTFD package (`foo.rtfd/` + `TXT.rtf` + resources) by
/// reading the internal `TXT.rtf` and delegating to `RTFDocumentExtractor`.
///
/// The delegation used to hand the inner URL to a renderer that stamped the filename into
/// its own message, so an unreadable bundle reported `TXT.rtf` — a name no tool can open.
/// Reasons travel bare now, and the caller names the outer `.rtfd`.
nonisolated struct RTFDDocumentExtractor: DocumentFormatExtractor {
    func extract(from url: URL) -> DocumentExtractionOutcome {
        let internalRTF = url.appendingPathComponent("TXT.rtf")
        guard FileManager.default.fileExists(atPath: internalRTF.path) else {
            return .failure(reason: "RTFD package missing TXT.rtf")
        }
        return RTFDocumentExtractor().extract(from: internalRTF)
    }
}

/// Legacy `.doc` binary format (Word 97-2004) has no pure-Swift reader. Reject
/// with an actionable message — users can re-save as `.docx`.
nonisolated struct LegacyDOCExtractor: DocumentFormatExtractor {
    func extract(from url: URL) -> DocumentExtractionOutcome {
        .failure(reason: "legacy .doc binary format not supported — save as .docx")
    }
}
