import Foundation

/// Service for generating teammate responses to consultation requests.
/// Uses the LLM to role-play as a teammate and provide expertise-based answers.
struct TeammateConsultationService {

    /// Context required to generate a teammate response
    struct ConsultationContext {
        let consultedRole: Role
        let requestingRole: Role
        let question: String
        let additionalContext: String?
        let task: NTMSTask
        let availableArtifacts: [Artifact]
        let artifactReader: (Artifact) -> String?
        let consultationHistory: [TeammateConsultation]
        let team: Team?
    }

    /// Generate a response from a teammate
    /// - Parameters:
    ///   - context: The consultation context
    ///   - client: The LLM client
    ///   - config: The LLM configuration
    ///   - logger: Optional network logger
    /// - Returns: The teammate's response as a string
    static func generateResponse(
        context: ConsultationContext,
        client: any LLMClient,
        config: LLMConfig,
        logger: NetworkLogger? = nil
    ) async throws -> String {
        let messages = buildMessages(context: context)

        // Use streaming but collect the full response
        var fullResponse = ""
        let stream = client.streamChat(
            config: config,
            messages: messages,
            tools: [],  // Teammates don't use tools in consultations
            session: nil,
            logger: logger,
            stepID: nil
        )

        for try await event in stream {
            fullResponse += event.contentDelta
        }

        return fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the chat messages for the teammate consultation
    private static func buildMessages(
        context: ConsultationContext
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = []

        // Build system prompt for the teammate
        let systemPrompt = buildSystemPrompt(context: context)
        messages.append(ChatMessage(role: .system, content: systemPrompt))

        // Add task context
        let taskContext = buildTaskContext(context: context)
        messages.append(ChatMessage(role: .user, content: taskContext))

        // Add available artifacts
        let artifactContext = buildArtifactContext(context: context)
        if !artifactContext.isEmpty {
            messages.append(ChatMessage(role: .user, content: artifactContext))
        }

        // Add consultation history if relevant
        let historyContext = buildHistoryContext(context: context)
        if !historyContext.isEmpty {
            messages.append(ChatMessage(role: .user, content: historyContext))
        }

        // Add the actual question
        let questionMessage = buildQuestionMessage(context: context)
        messages.append(ChatMessage(role: .user, content: questionMessage))

        return messages
    }

    /// Build the system prompt for the teammate using the team's consultation template
    private static func buildSystemPrompt(context: ConsultationContext) -> String {
        let template = context.team?.consultationPromptTemplate ?? SystemTemplates.genericConsultationTemplate
        let roleGuidance = getRolePrompt(role: context.consultedRole, team: context.team)
        let teamDescription = context.team?.description ?? ""

        let placeholders: [String: String] = [
            "consultedRoleName": roleName(context.consultedRole, team: context.team),
            "requestingRoleName": roleName(context.requestingRole, team: context.team),
            "roleGuidance": roleGuidance,
            "teamDescription": teamDescription,
        ]

        return TemplateResolver.resolve(template, placeholders: placeholders)
    }

    /// Build the task context message
    private static func buildTaskContext(context: ConsultationContext) -> String {
        var lines: [String] = []
        lines.append("Current Task:")
        lines.append("Title: \(context.task.title)")
        lines.append("Supervisor Task: \(context.task.effectiveSupervisorBrief)")
        return lines.joined(separator: "\n")
    }

    /// Build context from available artifacts
    private static func buildArtifactContext(context: ConsultationContext) -> String {
        guard !context.availableArtifacts.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("Available Artifacts:")

        for artifact in context.availableArtifacts {
            lines.append("")
            lines.append("[\(artifact.name)]:")

            if let content = context.artifactReader(artifact) {
                let maxChars = ArtifactConstants.maxConsultationChars
                if content.count > maxChars {
                    let truncated = String(content.prefix(maxChars))
                    lines.append("```")
                    lines.append(truncated)
                    lines.append("... (truncated)")
                    lines.append("```")
                } else {
                    lines.append("```")
                    lines.append(content)
                    lines.append("```")
                }
            } else {
                lines.append("(content not available)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Build context from previous consultations in this run
    private static func buildHistoryContext(context: ConsultationContext) -> String {
        let relevantHistory = context.consultationHistory.filter { consultation in
            // Show consultations involving this teammate or the requester
            consultation.consultedRole == context.consultedRole ||
            consultation.requestingRole == context.consultedRole ||
            consultation.consultedRole == context.requestingRole ||
            consultation.requestingRole == context.requestingRole
        }.prefix(5)  // Limit to last 5 relevant consultations

        guard !relevantHistory.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("Recent Consultations:")

        for consultation in relevantHistory {
            lines.append("")
            lines.append("\(roleName(consultation.requestingRole, team: context.team)) asked \(roleName(consultation.consultedRole, team: context.team)):")
            lines.append("Q: \(consultation.question)")
            if let response = consultation.response {
                lines.append("A: \(response)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Build the question message
    private static func buildQuestionMessage(context: ConsultationContext) -> String {
        var lines: [String] = []
        lines.append("Question from \(roleName(context.requestingRole, team: context.team)):")
        lines.append(context.question)

        if let additionalContext = context.additionalContext,
           !additionalContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("Additional context:")
            lines.append(additionalContext)
        }

        lines.append("")
        lines.append("Please provide your response as \(roleName(context.consultedRole, team: context.team)).")

        return lines.joined(separator: "\n")
    }

    /// Resolve a role's display name using team context when available.
    private static func roleName(_ role: Role, team: Team?) -> String {
        if let def = team?.findRole(byIdentifier: role.baseID) { return def.name }
        return role.displayName
    }

    /// Get the role prompt for a role
    private static func getRolePrompt(role: Role, team: Team?) -> String {
        if let roleDefinition = team?.findRole(byIdentifier: role.baseID) {
            return roleDefinition.prompt
        }
        return SystemTemplates.roles[role.baseID]?.prompt ?? ""
    }
}

// MARK: - Consultation Management

extension TeammateConsultationService {

    /// Check if a consultation limit has been reached
    static func hasReachedLimit(
        consultations: [TeammateConsultation],
        limits: TeamLimits
    ) -> Bool {
        consultations.count >= limits.maxConsultationsPerStep
    }

    /// Check if a consultation to the same teammate would exceed the limit
    static func wouldExceedSameTeammateLimit(
        consultations: [TeammateConsultation],
        targetTeammate: Role,
        limits: TeamLimits
    ) -> Bool {
        let countToTeammate = consultations.filter { $0.consultedRole == targetTeammate }.count
        return countToTeammate >= limits.maxSameTeammateAsks
    }

    /// Check if this is a duplicate question
    static func isDuplicateQuestion(
        consultations: [TeammateConsultation],
        targetTeammate: Role,
        question: String
    ) -> Bool {
        let normalizedQuestion = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return consultations.contains { consultation in
            consultation.consultedRole == targetTeammate &&
            consultation.question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedQuestion
        }
    }

    /// Create a new consultation record
    static func createConsultation(
        requestingRole: Role,
        consultedRole: Role,
        question: String,
        context: String?
    ) -> TeammateConsultation {
        TeammateConsultation(
            requestingRole: requestingRole,
            consultedRole: consultedRole,
            question: question,
            context: context,
            status: .pending
        )
    }
}
