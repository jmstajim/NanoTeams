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
                let hasThinking = msg.thinking.map { !$0.isEmpty } ?? false
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

                let answer: String?
                if index < answerMessages.count {
                    let content = answerMessages[index].content
                    answer = content.hasPrefix("Supervisor answer: ")
                        ? String(content.dropFirst("Supervisor answer: ".count))
                        : content
                } else if isLast {
                    answer = step.supervisorAnswer
                } else {
                    answer = "(answered)"
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
            items.append(.supervisorTask(
                brief: brief,
                taskCreatedAt: date,
                supervisorTask: supervisorTask ?? brief,
                clippedTexts: supervisorClippedTexts,
                attachmentPaths: supervisorAttachmentPaths,
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
    }

    /// Extracts active (unanswered) supervisor questions from steps for banner display.
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
                toolCallID: lastCall.id
            ))
        }
        return result
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
