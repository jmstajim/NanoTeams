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

        // Extract "## Skill: <name>" sections (line-anchored). Runs AFTER the clip
        // block: skills precede clips in built strings, so cutting clips first
        // leaves [text][skills]. Each section is re-encoded as a SkillClip
        // (display form) and appended to clippedTexts, so the same cell renderers
        // that parse staged clips render feed chips — the tuple shape is unchanged.
        if let regex = try? NSRegularExpression(pattern: SkillConstants.stripPattern, options: [.anchorsMatchLines]) {
            let nsRemaining = remaining as NSString
            let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsRemaining.length))
            if !matches.isEmpty {
                for i in 0..<matches.count {
                    let headerRange = matches[i].range
                    let headerLine = nsRemaining.substring(with: headerRange)
                    let name = String(headerLine.dropFirst(SkillConstants.promptHeaderPrefix.count))
                        .trimmingCharacters(in: .whitespaces)
                    let contentStart = headerRange.upperBound
                    let contentEnd = i + 1 < matches.count
                        ? matches[i + 1].range.location
                        : nsRemaining.length
                    let body = nsRemaining
                        .substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, !body.isEmpty {
                        clippedTexts.append(SkillClip(name: name, body: body).encoded())
                    }
                }
                if let firstMatch = matches.first {
                    remaining = nsRemaining.substring(to: firstMatch.range.location)
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
    /// Per-file memo keyed by (relativePath, updatedAt): both callers — the feed
    /// view model per rebuild and `renderConversationLog` per committed turn —
    /// used to re-read EVERY artifact file of every step from disk on every
    /// invocation, O(turns x artifacts) reads across a run for bytes that only
    /// change when a revision bumps `updatedAt` (which changes the key). An
    /// external edit that rewrites the file WITHOUT a model mutation serves
    /// stale content until the next revision — acceptable for a dedup input and
    /// a debug artifact; the alternative re-reads everything per turn forever.
    /// NSCache: thread-safe, evicts under pressure (CLAUDE.md's sanctioned
    /// `nonisolated(unsafe)` static shape).
    private nonisolated(unsafe) static let artifactContentCache = NSCache<NSString, NSString>()

    static func loadArtifactContentsForStepSync(
        _ step: StepExecution,
        workFolderURL: URL?
    ) -> Set<String> {
        guard let projectURL = workFolderURL else { return [] }
        var contents: Set<String> = []
        for artifact in step.artifacts {
            guard let relativePath = artifact.relativePath else { continue }
            let cacheKey = "\(relativePath)|\(artifact.updatedAt.timeIntervalSinceReferenceDate)" as NSString
            if let cached = artifactContentCache.object(forKey: cacheKey) {
                contents.insert(cached as String)
                continue
            }
            let fileURL = projectURL
                .appendingPathComponent(".nanoteams")
                .appendingPathComponent(relativePath)
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                // Only a successful read is memoized — an unreadable file must
                // stay retryable (it may simply not have landed yet).
                artifactContentCache.setObject(content as NSString, forKey: cacheKey)
                contents.insert(content)
            } else {
                #if DEBUG
                print("[ActivityFeed] Failed to load artifact content at \(fileURL.path)")
                #endif
            }
        }
        return contents
    }

    /// Resolves the bubble inputs for a message turn. When the caller says the turn's
    /// context can embed them (`MessageSourceContext.mayEmbedAttachmentMarkers`) it strips
    /// the embedded `## Attached Files` / `## Clipped Text` markers and returns the cleaned
    /// text alongside the extracted paths/clips. For all other turns it returns `raw`
    /// verbatim with empty paths/clips.
    ///
    /// The flag is not cosmetic and must not be passed `true` speculatively: `stripAttachedFiles`
    /// TRUNCATES at the first line-anchored marker, so a turn that merely quotes the heading
    /// loses everything after it.
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
    /// That includes `.supervisorFeedback`, which shares the bubble styling but not this
    /// suppression, and the narrowing is the reason: the C4 race below is a property of the
    /// QUEUED-CHAT delivery, and revision feedback does not come through it. Its trigger
    /// sites reject a whitespace-only comment (`rawFeedback` + an `isEmpty` guard) and
    /// `resetStepForRevision` substitutes a canned sentence rather than nothing, so an empty
    /// one is a genuine defect and must stay visible.
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
}
