import Foundation

/// Artifact size/display limits and supported MIME types.
enum ArtifactConstants {
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
    ]

    /// Display names for supported MIME types (OCP dictionary).
    static let mimeTypeDisplayNames: [String: String] = [
        "text/markdown": "Markdown",
        "text/plain": "Plain Text",
        "application/json": "JSON",
        "text/html": "HTML",
        "text/css": "CSS",
        "application/pdf": "PDF",
    ]
}
