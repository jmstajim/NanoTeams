import Foundation

/// Routing decision for artifact content loaded from disk.
///
/// `ArtifactDetailBody` calls `decide(data:mimeType:fileExtension:)` after
/// reading the raw bytes and switches on the result. Pulled out as a stateless
/// helper so the routing logic is unit-testable without standing up a full
/// SwiftUI window.
nonisolated enum ArtifactRenderDecision: Equatable {
    case text(String)
    case binary(byteCount: Int, fileExtension: String?)
}

enum ArtifactContentDecoder {

    /// Decides how to render an artifact whose raw bytes were just loaded.
    ///
    /// Order: known binary mime/extension → binary fast path. Otherwise try
    /// UTF-8 decode; on failure fall back to binary so a corrupt or
    /// mislabelled file surfaces as a non-fatal "binary artifact" affordance
    /// instead of a generic NSError. Today every `Artifact.relativePath`
    /// points at the markdown side-car, but the ArtifactDetailWindow value
    /// type accepts any mimeType from any caller — defensive routing keeps
    /// the viewer honest if a future code path emits a non-text artifact.
    /// `nonisolated` so it can run inside `Task.detached` without hopping back
     /// to the main actor — the loader off-loads disk reads precisely to keep
     /// decoding off the UI thread.
    nonisolated static func decide(
        data: Data,
        mimeType: String,
        fileExtension: String?
    ) -> ArtifactRenderDecision {
        let normalizedExt = fileExtension?.lowercased()
        if isLikelyBinary(mimeType: mimeType, fileExtension: normalizedExt) {
            return .binary(byteCount: data.count, fileExtension: normalizedExt)
        }
        if let text = String(data: data, encoding: .utf8) {
            return .text(text)
        }
        // Mislabelled binary — UTF-8 decode failed for a "text" mime type.
        return .binary(byteCount: data.count, fileExtension: normalizedExt)
    }

    /// Mime types and file extensions that are always binary even when the
    /// caller hasn't sniffed the bytes. Conservative list: only formats the
    /// app actually produces (PDF/RTF/DOCX side-cars from `create_artifact`).
    /// Unknown mime types fall through to the UTF-8 trial decode — that's
    /// the intended default.
    nonisolated private static func isLikelyBinary(mimeType: String, fileExtension: String?) -> Bool {
        let mimeLower = mimeType.lowercased()
        if mimeLower.hasPrefix("application/pdf") { return true }
        if mimeLower.hasPrefix("application/rtf") { return true }
        if mimeLower.contains("officedocument") { return true }
        if mimeLower.hasPrefix("image/") { return true }
        if mimeLower.hasPrefix("audio/") { return true }
        if mimeLower.hasPrefix("video/") { return true }
        switch fileExtension {
        case "pdf", "rtf", "docx", "xlsx", "pptx", "odt",
             "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff",
             "mp3", "mp4", "mov", "wav", "zip":
            return true
        default:
            return false
        }
    }
}
