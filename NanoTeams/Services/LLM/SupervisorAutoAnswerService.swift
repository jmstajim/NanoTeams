import Foundation

/// Service for generating automatic Supervisor answers to questions during LLM execution.
enum SupervisorAutoAnswerService {

    /// The default fallback answer when generation fails.
    static let fallbackAnswer = "Proceed with the most reasonable assumption and document the decision."

    /// Generates an automatic Supervisor answer for a question.
    /// - Parameters:
    ///   - question: The question to answer.
    ///   - task: The current task context.
    ///   - runIndex: The index of the current run.
    ///   - stepIndex: The index of the current step.
    ///   - client: The LLM client to use.
    ///   - config: The LLM configuration.
    ///   - artifactReader: Closure to read artifact content.
    /// - Returns: The generated answer, or the fallback answer if generation fails.
    static func generateAnswer(
        question: String,
        task: NTMSTask,
        runIndex: Int,
        stepIndex: Int,
        client: any LLMClient,
        config: LLMConfig,
        artifactReader: @escaping (Artifact) -> String?
    ) async -> String {
        guard task.runs.indices.contains(runIndex),
            task.runs[runIndex].steps.indices.contains(stepIndex)
        else {
            return fallbackAnswer
        }

        let run = task.runs[runIndex]
        let step = run.steps[stepIndex]
        let taskBrief = task.effectiveSupervisorBrief.trimmingCharacters(in: .whitespacesAndNewlines)

        var context = PromptBuilder.buildPipelineContext(
            run: run,
            upToStepIndex: stepIndex,
            artifactReader: artifactReader
        )
        if context.count > ArtifactConstants.maxDescriptionChars {
            context = String(context.prefix(ArtifactConstants.maxDescriptionChars)) + "..."
        }

        let system = """
            You are the Supervisor. Provide the best decision for the team.
            Be concise and actionable. If information is missing, make a reasonable assumption and state it.
            """

        var user = "Task: \(task.title)\n"
        if !taskBrief.isEmpty {
            user += "Supervisor Task: \(taskBrief)\n"
        }
        user += "Current role: \(step.role.displayName)\n"
        user += "Question: \(question)\n"
        if !context.isEmpty {
            user += "\nContext:\n\(context)\n"
        }
        user += "\nAnswer as the Supervisor."

        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: system),
            ChatMessage(role: .user, content: user),
        ]

        var collected = ""
        do {
            for try await event in client.streamChat(
                config: config, messages: messages, tools: [],
                session: nil, logger: nil, stepID: nil)
            {
                if !event.contentDelta.isEmpty {
                    collected += event.contentDelta
                }
            }
        } catch {
            return fallbackAnswer
        }

        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackAnswer : trimmed
    }
}
