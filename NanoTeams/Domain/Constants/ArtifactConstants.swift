import Foundation

/// Artifact size/display limits and supported MIME types.
nonisolated enum ArtifactConstants {
    /// Maximum artifact content size in bytes (50KB).
    static let maxContentBytes = 50 * 1024

    /// Maximum artifact description length in characters.
    static let maxDescriptionChars = 2000

    /// Maximum characters of artifact content injected into consultations.
    static let maxConsultationChars = 1500

    /// Name of the auto-generated build diagnostics artifact (excluded from completeness check).
    static let buildDiagnosticsName = "Build Diagnostics"

    /// MIME types available in the artifact editor.
    static let supportedMimeTypes: [String] = [
        "text/markdown", "text/plain", "application/json",
        "text/html", "text/css", "application/pdf",
        "application/rtf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ]

    /// Display names for supported MIME types (OCP dictionary).
    static let mimeTypeDisplayNames: [String: String] = [
        "text/markdown": "Markdown",
        "text/plain": "Plain Text",
        "application/json": "JSON",
        "text/html": "HTML",
        "text/css": "CSS",
        "application/pdf": "PDF",
        "application/rtf": "RTF",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "DOCX",
    ]

    // MARK: - Artifact-name validation

    /// File extensions valid for an artifact NAME. Mirrors `create_artifact`'s
    /// `format` parameter ({markdown, pdf, rtf, docx}) — `md` and these three.
    /// Anything outside this set (`.html`, `.css`, `.js`, `.swift`, `.py`, …)
    /// signals the LLM is conflating a file-on-disk with a deliverable: those
    /// belong to `write_file`, not `create_artifact`. Conceptual names without
    /// any extension (e.g. "Product Requirements") are always valid.
    static let allowedArtifactExtensions: Set<String> = ["md", "pdf", "rtf", "docx"]

    /// True when `name` is a valid artifact name. The check is intentionally
    /// narrow:
    ///
    /// 1. No dot at all → conceptual name → valid (covers "Code Review",
    ///    "Engineering Notes", etc.).
    /// 2. The trailing token after the LAST dot must be 1–5 chars and *all
    ///    letters* to be treated as a file extension. This filters false-positives
    ///    like "version 2.0", "Spec v1.5 final", "report 1.5" — none of those
    ///    should be rejected.
    /// 3. A recognised extension is valid only if it's in `allowedArtifactExtensions`.
    ///    `index.html` → `html` (4 alpha) → not allowed → INVALID.
    ///    `report.md` → `md` (2 alpha) → allowed → VALID.
    static func isValidArtifactName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let dotIdx = trimmed.lastIndex(of: ".") else { return true }
        let ext = trimmed[trimmed.index(after: dotIdx)...]
        guard ext.count >= 1, ext.count <= 5,
              ext.allSatisfy({ $0.isLetter })
        else { return true }  // not a file-extension shape — accept
        return allowedArtifactExtensions.contains(String(ext).lowercased())
    }
}
