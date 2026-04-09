import Foundation

/// Stateless helper that assembles a supervisor answer from text, clips, and file attachments.
///
/// Extracted from `QuickCaptureController.submitAnswer()` so all answer surfaces
/// (QuickCapture, ActivityFeed, Watchtower) can apply the same processing.
enum AnswerTextBuilder {

    struct Result {
        let answer: String
        let failedFiles: [String]
        /// IDs of attachments whose content was successfully embedded inline.
        /// Caller should exclude these from the attachment paths sent to the LLM
        /// to avoid duplicate references.
        let embeddedAttachmentIDs: Set<String>
    }

    /// Builds the full answer string by combining user text, clipped texts, and optionally
    /// embedded file contents.
    ///
    /// - Parameters:
    ///   - text: The user-typed answer (trimmed).
    ///   - clips: Clipped text snippets (may include `SourceContext` headers).
    ///   - attachments: Staged file attachments.
    ///   - embedFiles: When `true`, reads file contents and injects inline.
    static func build(
        text: String,
        clips: [String] = [],
        attachments: [StagedAttachment] = [],
        embedFiles: Bool = false
    ) -> Result {
        var fullAnswer = text
        var failedFiles: [String] = []
        var embeddedIDs: Set<String> = []

        // Combine clipped texts (always inline in prompt)
        let nonEmptyClips = clips
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !nonEmptyClips.isEmpty {
            let clipSections: [String] = nonEmptyClips.enumerated().map { index, clip in
                let parsed = SourceContext.parse(clip)
                let header: String
                if let parsed {
                    header = nonEmptyClips.count == 1
                        ? "--- Clipped Text (\(parsed.source)) ---"
                        : "--- Clipped Text (\(index + 1) of \(nonEmptyClips.count), \(parsed.source)) ---"
                } else {
                    header = nonEmptyClips.count == 1
                        ? "--- Clipped Text ---"
                        : "--- Clipped Text (\(index + 1) of \(nonEmptyClips.count)) ---"
                }
                let body = parsed?.body ?? clip
                return "\(header)\n\(body)"
            }
            let clipsSection = clipSections.joined(separator: "\n\n")
            fullAnswer = fullAnswer.isEmpty ? clipsSection : fullAnswer + "\n\n" + clipsSection
        }

        // Embed file contents inline when requested.
        // Binary files (images, etc.) are silently skipped — they're still sent as attachment paths.
        if embedFiles && !attachments.isEmpty {
            for attachment in attachments {
                let ext = attachment.url.pathExtension.lowercased()
                if VisionConstants.supportedExtensions.contains(ext) {
                    continue
                }
                let content: String
                if let extracted = DocumentTextExtractor.extractText(from: attachment.url) {
                    content = extracted
                } else if let utf8 = try? String(contentsOf: attachment.url, encoding: .utf8) {
                    content = utf8
                } else {
                    failedFiles.append(attachment.fileName)
                    continue
                }
                if DocumentTextExtractor.isFailureMessage(content) {
                    failedFiles.append(attachment.fileName)
                    continue
                }
                embeddedIDs.insert(attachment.id)
                let section = "--- Attached File: \(attachment.fileName) ---\n\(content)"
                fullAnswer = fullAnswer.isEmpty ? section : fullAnswer + "\n\n" + section
            }
        }

        return Result(answer: fullAnswer, failedFiles: failedFiles, embeddedAttachmentIDs: embeddedIDs)
    }
}
