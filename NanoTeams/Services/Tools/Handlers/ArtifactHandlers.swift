import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - create_artifact

struct CreateArtifactTool: ToolHandler {
    static let name = TN.createArtifact
    static let schema = ToolSchema(
        name: TN.createArtifact,
        description: "Submit a deliverable artifact. Your step ends when all expected deliverables are submitted.",
        parameters: JS.object(
            properties: [
                "name": JS.string("Artifact name — must match one of the expected artifacts (e.g., 'World Compendium')"),
                "content": JS.string("Full artifact content in markdown format"),
            ],
            required: ["name", "content"]
        )
    )
    static let category: ToolCategory = .artifact
    static let excludedInMeetings = true

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let name = try requiredString(args, "name")
            let content = resolveContentString(args, excludeKeys: ["name"]) ?? ""

            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["artifact": name, "status": "created"]),
                isError: false,
                signal: .artifact(name: name, content: content)
            )
        }
    }
}
