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

    /// Per-file outcome of reading + formatting one attachment for inline embedding.
    /// Used by `build(...)` (supervisor answers + goal-attachment embedding) so the
    /// `## Attached File:` format + read/skip/fail rules have a single source of truth.
    enum EmbedOutcome: Equatable {
        case embedded(section: String)
        case skippedBinary
        case failed(fileName: String)
    }

    /// Reads one file and formats it as a `## Attached File: <name>\n<content>`
    /// section, or reports why it couldn't. Image/binary extensions are skipped
    /// (they belong as attachment paths, not inline text). Extraction goes through
    /// `DocumentTextExtractor` (PDF/DOCX/…) with a UTF-8 fallback; a failure message
    /// or unreadable file yields `.failed`.
    static func embedSection(url: URL) -> EmbedOutcome {
        let ext = url.pathExtension.lowercased()
        if VisionConstants.supportedExtensions.contains(ext) {
            return .skippedBinary
        }
        let fileName = url.lastPathComponent
        let content: String
        if let extracted = DocumentTextExtractor.extractText(from: url) {
            content = extracted
        } else if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            content = utf8
        } else {
            return .failed(fileName: fileName)
        }
        if DocumentTextExtractor.isFailureMessage(content) {
            return .failed(fileName: fileName)
        }
        return .embedded(section: "## Attached File: \(fileName)\n\(content)")
    }

    /// Renders staged clip strings into prompt sections. Skill clips (see
    /// `SkillClip`) become `## Skill: <name>` sections FIRST — a skill is an
    /// instruction for handling the request, closest to the user text — then
    /// plain / `SourceContext`-enriched clips become `## Clipped Text` sections.
    /// The `N of M` numbering counts only non-skill clips.
    ///
    /// Single source of truth for the clip-section format, shared by `build(...)`
    /// (live submits + queue drains) and `NTMSTask.effectiveSupervisorBrief`
    /// (persisted task creation) so the two can never drift.
    ///
    /// `nonisolated` so the `nonisolated NTMSTask` extension can call it.
    nonisolated static func clipSections(from clips: [String]) -> [String] {
        var skillSections: [String] = []
        /// `source == nil` is a plain clip. One list, not two, because the `N of M`
        /// numbering spans both kinds and must stay in capture order.
        var textClips: [(source: String?, body: String)] = []
        // BOTH sentinels are a zero-width space, and `.whitespacesAndNewlines` REMOVES
        // U+200B on macOS 26 (swift-foundation classifies ZWSP as whitespace — measured,
        // CLAUDE.md Грабли 2026-07-11). So every sentinel-bearing clip has to be parsed
        // on the RAW string, before any trim; only the BODY is trimmed afterwards.
        //
        // Until this was fixed the skill branch did that and the `SourceContext` branch
        // did not: it trimmed first, so `parse` returned nil for every enriched clip and
        // the sourced-header arms below were dead in production. The effect was not merely
        // a plainer header — the stripped `// Source: path:start-end` line stayed at the
        // top of the BODY, where the model reads it as the first line of the snippet it
        // was asked to work on.
        for raw in clips {
            if let skill = SkillClip.parse(raw) {
                let body = skill.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty { continue }
                skillSections.append("\(SkillConstants.promptHeader(name: skill.name))\n\(body)")
                continue
            }
            if let parsed = SourceContext.parse(raw) {
                let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty { continue }
                textClips.append((parsed.source, body))
                continue
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            textClips.append((nil, trimmed))
        }
        guard !skillSections.isEmpty || !textClips.isEmpty else { return [] }

        let clipTextSections: [String] = textClips.enumerated().map { index, clip in
            let header: String
            if let source = clip.source {
                header = textClips.count == 1
                    ? "## Clipped Text — \(source)"
                    : "## Clipped Text — \(index + 1) of \(textClips.count), \(source)"
            } else {
                header = textClips.count == 1
                    ? "## Clipped Text"
                    : "## Clipped Text — \(index + 1) of \(textClips.count)"
            }
            return "\(header)\n\(clip.body)"
        }

        return skillSections + clipTextSections
    }

    /// Builds the full answer string by combining user text, clipped texts, and optionally
    /// embedded file contents.
    ///
    /// Section order: user text → `## Skill:` → `## Clipped Text` → `## Attached File:`
    /// (embedded) → (caller-appended) `## Attached Files` (path list).
    ///
    /// - Parameters:
    ///   - text: The user-typed answer (trimmed).
    ///   - clips: Clipped text snippets (may include `SourceContext` or `SkillClip` headers).
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

        // Combine clipped texts (skills + clips, always inline in prompt).
        let sections = clipSections(from: clips)
        if !sections.isEmpty {
            let joined = sections.joined(separator: "\n\n")
            fullAnswer = fullAnswer.isEmpty ? joined : fullAnswer + "\n\n" + joined
        }

        // Embed file contents inline when requested.
        // Binary files (images, etc.) are silently skipped — they're still sent as attachment paths.
        if embedFiles && !attachments.isEmpty {
            for attachment in attachments {
                switch embedSection(url: attachment.url) {
                case .skippedBinary:
                    continue
                case .failed(let fileName):
                    failedFiles.append(fileName)
                case .embedded(let section):
                    embeddedIDs.insert(attachment.id)
                    fullAnswer = fullAnswer.isEmpty ? section : fullAnswer + "\n\n" + section
                }
            }
        }

        return Result(answer: fullAnswer, failedFiles: failedFiles, embeddedAttachmentIDs: embeddedIDs)
    }
}
