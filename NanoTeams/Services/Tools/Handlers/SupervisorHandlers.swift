import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - ask_supervisor

nonisolated struct AskSupervisorTool: ToolHandler {
    static let name = TN.askSupervisor
    static let schema = ToolSchema(
        name: TN.askSupervisor,
        description: "Ask the Supervisor a question. The step will pause until the Supervisor answers.",
        parameters: JS.object(
            properties: [
                "question": JS.string("The question to ask"),
            ],
            required: ["question"]
        )
    )
    static let category: ToolCategory = .supervisor
    static let excludedInMeetings = true

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // Non-empty, because the dispatcher's own `!trimmed.isEmpty` guard
            // (`+ToolResultDispatching`) silently declines to park on an empty
            // question — so accepting one here reports `ok: true` for a step that
            // never stops, and the model waits for an answer nobody was asked for
            // until the non-productive-turn ceiling ends the step.
            let question = try requiredNonEmptyString(args, "question")
            return makeSupervisorQuestionResult(
                toolName: Self.name,
                args: args,
                question: question
            )
        }
    }
}
