import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - update_scratchpad

struct UpdateScratchpadTool: ToolHandler {
    static let name = TN.updateScratchpad
    static let schema = ToolSchema(
        name: TN.updateScratchpad,
        description: "Working scratchpad for plan + progress. Markdown numbered list; mark done items with ~~strikethrough~~. Call once at step start to plan, then again only to update progress. Max ~2 calls per step (each call costs tokens).",
        parameters: JS.object(
            properties: [
                "content": JS.string("Full scratchpad markdown."),
            ],
            required: ["content"]
        )
    )
    static let category: ToolCategory = .memory

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            guard let content = resolveContentString(args) else {
                throw ToolArgumentError.missingRequired("content")
            }

            return makeSuccessResult(
                toolName: Self.name,
                args: args,
                data: ScratchpadUpdateData(
                    updated: true,
                    contentLength: content.count
                )
            )
        }
    }
}

private struct ScratchpadUpdateData: Codable {
    var updated: Bool
    var contentLength: Int

    enum CodingKeys: String, CodingKey {
        case updated
        case contentLength = "content_length"
    }
}
