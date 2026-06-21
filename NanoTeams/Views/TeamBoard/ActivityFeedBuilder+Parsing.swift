import Foundation

// Attachment/clip stripping, artifact-content loading, and ask_supervisor
// question parsing. Pure static string helpers split out of ActivityFeedBuilder.
nonisolated extension ActivityFeedBuilder {

    /// Strips the `## Attached Files` section from an answer string.
    /// Returns the cleaned text (nil if empty after stripping) and extracted file paths.
    /// All header patterns are line-anchored — bare phrases inside body text don't trigger.
    static func stripAttachedFiles(from text: String) -> (text: String?, paths: [String], clippedTexts: [String]) {
        var remaining = text
        var paths: [String] = []
        var clippedTexts: [String] = []

        // Extract "## Attached Files" section (line-anchored).
        let fileSepPattern = "^## Attached Files$"
        if let regex = try? NSRegularExpression(pattern: fileSepPattern, options: [.anchorsMatchLines]) {
            let nsRemaining = remaining as NSString
            let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsRemaining.length))
            if let firstMatch = matches.first {
                let after = nsRemaining.substring(from: firstMatch.range.upperBound)
                remaining = nsRemaining.substring(to: firstMatch.range.location)
                paths = after
                    .components(separatedBy: .newlines)
                    .compactMap { line -> String? in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("- ") else { return nil }
                        let path = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        return path.isEmpty ? nil : path
                    }
            }
        }

        // Strip "## Attached File: filename" sections (embedded file contents) — before clips
        // so embedded file content doesn't leak into the last clip's body.
        let embeddedFilePattern = "^## Attached File: [^\n]+$"
        if let regex = try? NSRegularExpression(pattern: embeddedFilePattern, options: [.anchorsMatchLines]) {
            let nsRemaining = remaining as NSString
            let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsRemaining.length))
            if let firstMatch = matches.first {
                remaining = nsRemaining.substring(to: firstMatch.range.location)
            }
        }

        // Extract "## Clipped Text" / "## Clipped Text — metadata" sections (line-anchored).
        let clipPattern = "^## Clipped Text(?: \u{2014} [^\n]+)?$"
        if let regex = try? NSRegularExpression(pattern: clipPattern, options: [.anchorsMatchLines]) {
            let nsRemaining = remaining as NSString
            let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsRemaining.length))
            if !matches.isEmpty {
                // Collect clip content between headers (or after last header until end).
                let headerRanges = matches.map { $0.range }
                for i in 0..<headerRanges.count {
                    let contentStart = headerRanges[i].upperBound
                    let contentEnd = i + 1 < headerRanges.count
                        ? headerRanges[i + 1].location
                        : nsRemaining.length
                    let clip = nsRemaining.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clip.isEmpty {
                        clippedTexts.append(clip)
                    }
                }
                // Remove all clip sections from remaining text.
                if let firstMatch = headerRanges.first {
                    remaining = nsRemaining.substring(to: firstMatch.location)
                }
            }
        }

        let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? nil : trimmed, paths, clippedTexts)
    }

    /// Reads a step's persisted artifact file contents into a set (untruncated, raw
    /// `String(contentsOf:)`). Shared by the live feed's
    /// `TeamActivityFeedViewModel.refreshStepArtifactContentCacheAsync` and the
    /// conversation-log render path (`NTMSOrchestrator+ConversationLog`) so the
    /// message↔artifact dedup matches in both. NOT `ArtifactService.readContent` (it
    /// truncates at 50 KB, which would break content-equality dedup). `nonisolated` so
    /// it runs off the main actor.
    static func loadArtifactContentsForStepSync(
        _ step: StepExecution,
        workFolderURL: URL?
    ) -> Set<String> {
        guard let projectURL = workFolderURL else { return [] }
        var contents: Set<String> = []
        for artifact in step.artifacts {
            guard let relativePath = artifact.relativePath else { continue }
            let fileURL = projectURL
                .appendingPathComponent(".nanoteams")
                .appendingPathComponent(relativePath)
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                contents.insert(content)
            } else {
                #if DEBUG
                print("[ActivityFeed] Failed to load artifact content at \(fileURL.path)")
                #endif
            }
        }
        return contents
    }

    /// Resolves the bubble inputs for a message turn. For
    /// `.supervisorMessage` turns it strips the embedded `## Attached Files`
    /// / `## Clipped Text` markers and returns the cleaned text alongside
    /// the extracted paths/clips. For all other turns it returns `raw`
    /// verbatim with empty paths/clips.
    ///
    /// The non-obvious bit: when `isSupervisorMessage` is true and the user
    /// attached a file but typed nothing, `stripAttachedFiles` returns
    /// `text == nil`. The caller (and this helper) must treat that as
    /// "the cleaned text is empty" — falling back to `raw` here would
    /// re-render the marker section the strip just removed.
    static func bubbleDisplayInputs(
        raw: String,
        isSupervisorMessage: Bool
    ) -> (text: String, paths: [String], clippedTexts: [String]) {
        guard isSupervisorMessage else { return (raw, [], []) }
        let stripped = stripAttachedFiles(from: raw)
        return (stripped.text ?? "", stripped.paths, stripped.clippedTexts)
    }

    /// Whether a `.supervisorMessage` turn has nothing committed-side to
    /// render — no body, no thinking, no attachments, no clips. The C4
    /// atomicity race (queued chat / `forward_to_team`) can briefly emit
    /// a turn whose raw `content` is just `"Supervisor:\n"` plus an empty
    /// marker section; after `displayContent` strips the prefix and
    /// `stripAttachedFiles` removes the section, every channel resolves
    /// to empty.
    ///
    /// Predicate is narrowed to `.supervisorMessage` on purpose: empty
    /// content from any other source context indicates a real bug
    /// upstream and should surface as a visible avatar-only bubble so
    /// the regression doesn't get swallowed.
    ///
    /// Filtering at the builder (rather than the dispatcher) keeps the
    /// feed dispatcher's `MessageBubbleView` slot at one structural
    /// position — preserving SwiftUI view identity for the underlying
    /// `NSTextView` across the streaming → committed flip. Branching at
    /// the dispatcher between `EmptyView()` and `MessageBubbleView` would
    /// cross `_ConditionalContent` arms and remount the text view.
    static func shouldSuppressEmptySupervisorMessage(_ msg: LLMMessage) -> Bool {
        guard msg.sourceContext == .supervisorMessage else { return false }
        let hasThinking = msg.thinking
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? false
        if hasThinking { return false }
        let inputs = bubbleDisplayInputs(raw: msg.displayContent, isSupervisorMessage: true)
        let textEmpty = inputs.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return textEmpty && inputs.paths.isEmpty && inputs.clippedTexts.isEmpty
    }

    /// Extracts the question string from an `ask_supervisor` tool call's argumentsJSON.
    /// Handles both valid JSON and malformed/truncated JSON from streaming.
    static func parseAskSupervisorQuestion(from text: String) -> String? {
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let question = json["question"] as? String,
           !question.isEmpty
        {
            return question
        }

        guard let prefixRange = text.range(
            of: #""question"\s*:\s*""#, options: .regularExpression
        ) else { return nil }

        var extracted = String(text[prefixRange.upperBound...])
        if extracted.hasSuffix("\"}") {
            extracted = String(extracted.dropLast(2))
        } else if extracted.hasSuffix("\"") {
            extracted = String(extracted.dropLast(1))
        }
        extracted = extracted
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
        return extracted.isEmpty ? nil : extracted
    }
}
