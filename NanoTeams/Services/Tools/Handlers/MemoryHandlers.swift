import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - update_scratchpad

struct UpdateScratchpadTool: ToolHandler {
    static let name = TN.updateScratchpad
    static let schema = ToolSchema(
        name: TN.updateScratchpad,
        description: "Update your working scratchpad with a plan and progress notes. Use ~~strikethrough~~ for completed items. Plan at the START of your step (single call). Then execute all actions. Only update again when marking items ~~strikethrough~~ complete. Each call costs tokens — avoid calling more than twice per step.",
        parameters: JS.object(
            properties: [
                "content": JS.string(
                    "Full scratchpad content in markdown. Use numbered list with ~~strikethrough~~ for done items. Add notes about findings."
                ),
            ],
            required: ["content"]
        )
    )
    static let category: ToolCategory = .memory

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    func handle(context: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
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
