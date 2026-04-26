import SwiftUI

// MARK: - Activity Feed Builder

/// Pure transformation layer: converts raw domain data into display-ready timeline items.
/// Stateless and testable — no environment dependencies.
enum ActivityFeedBuilder {

    // MARK: - Tagged Item

    /// A timeline item annotated with section header visibility.
    struct TaggedItem: Identifiable {
        let item: TeamActivityTimelineItem
        let showSectionHeader: Bool
        var id: String { item.id }
    }

    // MARK: - Build

    /// Builds the sorted, annotated activity timeline from domain data.
    /// - Parameters:
    ///   - steps: Pre-filtered step executions for the active team members.
    ///   - run: The active run (for meetings and change requests).
    ///   - stepArtifactContentCache: Maps step IDs to artifact file contents (for message filtering).
    ///   - debugModeEnabled: When true, includes all messages without filtering.
    ///   - isStreaming: Returns true if the message with the given ID is actively streaming.
    static func buildTimelineItems(
        steps: [StepExecution],
        run: Run?,
        teamRoles: [TeamRoleDefinition] = [],
        supervisorBrief: String? = nil,
        supervisorBriefDate: Date? = nil,
        supervisorTask: String? = nil,
        supervisorClippedTexts: [String] = [],
        supervisorAttachmentPaths: [String] = [],
        supervisorProjectFolderURL: URL? = nil,
        stepArtifactContentCache: [String: Set<String>],
        debugModeEnabled: Bool,
        isStreaming: (UUID) -> Bool
    ) -> [TaggedItem] {
        var items: [TeamActivityTimelineItem] = []

        // Step messages, tool calls, and artifacts
        for step in steps {
            let role = step.role
            // nil = cache not loaded yet → don't filter (messages stay visible until cache ready)
            let artifactContents: Set<String> = debugModeEnabled ? [] : (stepArtifactContentCache[step.id] ?? [])

            for msg in step.llmConversation where msg.role != .system && msg.role != .tool {
                let hasThinking = msg.thinking.map {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } ?? false
                let isActivelyStreaming = isStreaming(msg.id)
                if msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !hasThinking && !isActivelyStreaming
                {
                    continue
                }
                if !debugModeEnabled && msg.role == .user {
                    if msg.sourceRole == nil && msg.sourceContext == nil { continue }
                    if msg.sourceContext == .supervisorAnswer { continue }
                }
                if !debugModeEnabled && !msg.content.isEmpty
                    && artifactContents.contains(msg.content) && !hasThinking
                {
                    continue
                }
                let displayRole = msg.sourceRole ?? role
                items.append(.llmMessage(message: msg, role: displayRole, stepID: step.id))
            }

            for call in step.toolCalls {
                items.append(.toolCall(call: call, role: role, stepID: step.id))
            }

            for artifact in step.artifacts {
                items.append(.artifact(artifact: artifact, role: role, stepID: step.id))
            }
        }

        // Meeting messages
        for meeting in run?.meetings ?? [] {
            for msg in meeting.messages {
                items.append(.meetingMessage(message: msg, meetingTopic: meeting.topic))
            }
        }

        // Change requests
        for cr in run?.changeRequests ?? [] {
            let targetName = teamRoles.roleName(for: cr.targetRoleID)
            items.append(.changeRequest(request: cr, targetRoleName: targetName))
        }

        // Answered supervisor-input notifications (active questions handled separately via banner)
        for step in steps {
            let askCalls = step.toolCalls.filter { $0.name == ToolNames.askSupervisor }
            let answerMessages = step.llmConversation.filter { $0.sourceContext == .supervisorAnswer }

            for (index, call) in askCalls.enumerated() {
                let isLast = index == askCalls.count - 1
                let isActive = isLast && step.needsSupervisorInput && step.supervisorAnswer == nil

                // Active questions are shown as a banner, not in the timeline
                if isActive { continue }

                let question: String
                if let parsed = parseAskSupervisorQuestion(from: call.argumentsJSON) {
                    question = parsed
                } else if isLast {
                    question = step.supervisorQuestion
                        .flatMap { parseAskSupervisorQuestion(from: $0) }
                        ?? step.supervisorQuestion ?? "?"
                } else {
                    question = "?"
                }

                let rawAnswer: String?
                if index < answerMessages.count {
                    let content = answerMessages[index].content
                    rawAnswer = content.hasPrefix("Supervisor answer: ")
                        ? String(content.dropFirst("Supervisor answer: ".count))
                        : content
                } else if isLast {
                    rawAnswer = step.supervisorAnswer
                } else {
                    rawAnswer = "(answered)"
                }

                // Strip "--- Attached Files ---" and "--- Clipped Text ---" sections
                let answer: String?
                var attachmentPaths: [String] = []
                var answerClippedTexts: [String] = []
                if let raw = rawAnswer {
                    let stripped = stripAttachedFiles(from: raw)
                    answer = stripped.text ?? (stripped.paths.isEmpty && stripped.clippedTexts.isEmpty ? nil : "")
                    attachmentPaths = stripped.paths
                    answerClippedTexts = stripped.clippedTexts
                } else {
                    answer = nil
                }
                // For the last question, merge structured paths from step field
                if isLast {
                    let structuredPaths = step.supervisorAnswerAttachmentPaths
                    if !structuredPaths.isEmpty {
                        let existing = Set(attachmentPaths)
                        for path in structuredPaths where !existing.contains(path) {
                            attachmentPaths.append(path)
                        }
                    }
                }

                let thinking = step.llmConversation
                    .last(where: {
                        $0.role == .assistant && $0.thinking != nil && $0.createdAt <= call.createdAt
                    })?.thinking

                // Use answer timestamp (when Supervisor responded), fall back to call timestamp
                let answerTimestamp = index < answerMessages.count
                    ? answerMessages[index].createdAt
                    : call.createdAt

                items.append(.notification(
                    stepID: step.id,
                    role: step.role,
                    type: .supervisorInput(
                        question: question, answer: answer,
                        answerAttachmentPaths: attachmentPaths,
                        answerClippedTexts: answerClippedTexts,
                        toolCallID: call.id, thinking: thinking
                    ),
                    createdAt: answerTimestamp
                ))
            }

            if step.status == .failed {
                items.append(.notification(
                    stepID: step.id,
                    role: step.role,
                    type: .failed(errorMessage: nil),
                    createdAt: step.completedAt ?? step.updatedAt
                ))
            }
        }

        // Supervisor task (always first — task.createdAt predates any step execution)
        if let brief = supervisorBrief,
           !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let date = supervisorBriefDate {
            // Strip embedded file/clip sections from display text (content is inline for LLM only)
            let rawTask = supervisorTask ?? brief
            let stripped = stripAttachedFiles(from: rawTask)
            let displayTask = stripped.text ?? rawTask
            // Merge clip/attachment paths from both the stripped text and the structured fields
            let allClips = supervisorClippedTexts.isEmpty ? stripped.clippedTexts : supervisorClippedTexts
            let allPaths = supervisorAttachmentPaths.isEmpty ? stripped.paths : supervisorAttachmentPaths
            items.append(.supervisorTask(
                brief: brief,
                taskCreatedAt: date,
                supervisorTask: displayTask,
                clippedTexts: allClips,
                attachmentPaths: allPaths,
                workFolderURL: supervisorProjectFolderURL
            ))
        }

        let sorted = items.sorted { $0.createdAt < $1.createdAt }
        return annotate(sorted)
    }

    // MARK: - Helpers

    /// Annotates sorted items with `showSectionHeader` based on consecutive role grouping.
    private static func annotate(_ items: [TeamActivityTimelineItem]) -> [TaggedItem] {
        var tagged: [TaggedItem] = []
        tagged.reserveCapacity(items.count)
        for item in items {
            let showHeader = tagged.isEmpty
                || item.roleID == nil
                || tagged.last?.item.roleID != item.roleID
            tagged.append(TaggedItem(item: item, showSectionHeader: showHeader))
        }
        return tagged
    }

    // MARK: - Active Supervisor Questions (for banner)

    /// Data for an active (unanswered) supervisor question, displayed as a banner.
    struct ActiveSupervisorQuestion {
        let stepID: String
        let role: Role
        let question: String
        let thinking: String?
        let toolCallID: UUID
        /// Timestamp of the active `ask_supervisor` tool call (i.e. the LAST one in
        /// the step's tool-call list, not the first — a role can ask twice). Builder
        /// emits results sorted ascending by this field; UI ordering is the consumer's
        /// concern (e.g. `TeamActivityComposer.computeChipOptions` preserves order).
        let askedAt: Date
    }

    /// Extracts active (unanswered) supervisor questions from steps. Result is sorted
    /// ascending by `askedAt`, with `stepID` as a deterministic tie-breaker — two
    /// `ask_supervisor` calls landing in the same monotonic tick must produce a stable
    /// order across recomputes, otherwise the leftmost chip flips and any draft typed
    /// into the auto-selected recipient would silently retarget on the next refresh.
    static func activeSupervisorQuestions(steps: [StepExecution]) -> [ActiveSupervisorQuestion] {
        var result: [ActiveSupervisorQuestion] = []
        for step in steps where step.needsSupervisorInput && step.supervisorAnswer == nil {
            let askCalls = step.toolCalls.filter { $0.name == ToolNames.askSupervisor }
            guard let lastCall = askCalls.last else { continue }

            let question: String
            if let parsed = parseAskSupervisorQuestion(from: lastCall.argumentsJSON) {
                question = parsed
            } else {
                question = step.supervisorQuestion
                    .flatMap { parseAskSupervisorQuestion(from: $0) }
                    ?? step.supervisorQuestion ?? "?"
            }

            let thinking = step.llmConversation
                .last(where: {
                    $0.role == .assistant && $0.thinking != nil && $0.createdAt <= lastCall.createdAt
                })?.thinking

            result.append(ActiveSupervisorQuestion(
                stepID: step.id, role: step.role,
                question: question, thinking: thinking,
                toolCallID: lastCall.id,
                askedAt: lastCall.createdAt
            ))
        }
        return result.sorted { lhs, rhs in
            if lhs.askedAt != rhs.askedAt { return lhs.askedAt < rhs.askedAt }
            return lhs.stepID < rhs.stepID
        }
    }

    /// Strips the `--- Attached Files ---` section from an answer string.
    /// Returns the cleaned text (nil if empty after stripping) and extracted file paths.
    static func stripAttachedFiles(from text: String) -> (text: String?, paths: [String], clippedTexts: [String]) {
        var remaining = text
        var paths: [String] = []
        var clippedTexts: [String] = []

        // Extract "--- Attached Files ---" section
        let fileSeparator = "--- Attached Files ---"
        if let range = remaining.range(of: fileSeparator) {
            let after = String(remaining[range.upperBound...])
            remaining = String(remaining[..<range.lowerBound])
            paths = after
                .components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("- ") else { return nil }
                    let path = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    return path.isEmpty ? nil : path
                }
        }

        // Strip "--- Attached File: filename ---" sections (embedded file contents) — before clips
        // to prevent embedded file content leaking into the last clip's body.
        let embeddedFilePattern = "--- Attached File:[^\n]*---"
        if let regex = try? NSRegularExpression(pattern: embeddedFilePattern) {
            let nsRemaining = remaining as NSString
            let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsRemaining.length))
            if let firstMatch = matches.first {
                remaining = nsRemaining.substring(to: firstMatch.range.location)
            }
        }

        // Extract "--- Clipped Text ---" / "--- Clipped Text (...) ---" sections
        let clipPattern = "---\\s*Clipped Text[^\n]*---"
        if let regex = try? NSRegularExpression(pattern: clipPattern) {
            let nsRemaining = remaining as NSString
            let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsRemaining.length))
            if !matches.isEmpty {
                // Collect clip content between headers (or after last header until end)
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
                // Remove all clip sections from remaining text
                if let firstMatch = headerRanges.first {
                    remaining = nsRemaining.substring(to: firstMatch.location)
                }
            }
        }

        let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? nil : trimmed, paths, clippedTexts)
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
