import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - ask_supervisor

struct AskSupervisorTool: ToolHandler {
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

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let question = try requiredString(args, "question")
            return makeSupervisorQuestionResult(
                toolName: Self.name,
                args: args,
                question: question
            )
        }
    }
}
