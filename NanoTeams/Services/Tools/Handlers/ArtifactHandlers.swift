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
                "format": JS.string("Output format: 'markdown' (default), 'pdf', 'rtf', 'docx'. Non-markdown formats produce binary document files alongside the markdown."),
            ],
            required: ["name", "content"]
        )
    )
    static let category: ToolCategory = .artifact
    static let excludedInMeetings = true

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self()
    }

    /// Accepted `format` values. `markdown`/`md` are no-op pass-throughs
    /// (markdown is the primary artifact body); the other three map to
    /// `DocumentTextExtractor.ExportFormat` for optional binary side-cars.
    private static let allowedFormats: Set<String> = [
        "markdown", "md", "pdf", "rtf", "docx",
    ]

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let name = try requiredString(args, "name")
            let content = resolveContentString(args, excludeKeys: ["name"]) ?? ""

            if let format = optionalString(args, "format"),
               !Self.allowedFormats.contains(format.lowercased()) {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "Unsupported format '\(format)'. Supported: markdown, pdf, rtf, docx. Omit for markdown."
                )
            }

            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["artifact": name, "status": "created"]),
                isError: false,
                signal: .artifact(name: name, content: content, format: optionalString(args, "format"))
            )
        }
    }
}
