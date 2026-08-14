import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - analyze_image

nonisolated struct AnalyzeImageTool: ToolHandler {
    static let name = TN.analyzeImage
    static let schema = ToolSchema(
        name: TN.analyzeImage,
        description: "Analyze an image file with a vision model. Returns a text description. Image must be inside the work folder.",
        parameters: JS.object(
            properties: [
                "path": JS.string("Relative path to the image."),
                "prompt": JS.string("Question or instruction about the image."),
            ],
            required: ["path", "prompt"]
        )
    )
    static let category: ToolCategory = .vision
    static let excludedInMeetings = true

    let resolver: SandboxPathResolver
    let fileManager: FileManager

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(resolver: dependencies.resolver, fileManager: dependencies.fileManager)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            // Empty `path` does not "fail loudly one layer down" the way the other
            // path arguments do: `resolveFileURL("")` returns the work-folder ROOT
            // rather than throwing, so the extension check fires first and the model
            // is told its image is in an unsupported FORMAT — for a call that named
            // no file at all.
            let path = try requiredNonEmptyString(args, "path")
            // Deliberately `requiredString`, NOT `requiredNonEmptyString`: an empty
            // prompt is a DESIGNED input here. `VisionAnalysisService.systemPrompt`
            // says verbatim "If no question is given, describe the image concisely",
            // and `analyze_image` is the only caller that can produce that case —
            // the computer-use path always passes `captureDescriptionPrompt`. A
            // non-empty guard here would make that branch of the shipped system
            // prompt dead code and cost a role a turn for asking "what is in this
            // file", which is the most natural first use of the tool.
            let prompt = try requiredString(args, "prompt")

            let fileURL = try resolver.resolveFileURL(relativePath: path)

            let ext = fileURL.pathExtension.lowercased()
            guard VisionConstants.supportedExtensions.contains(ext) else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "Unsupported image format '.\(ext)'. Supported: \(VisionConstants.supportedExtensions.sorted().joined(separator: ", "))"
                )
            }

            guard fileManager.fileExists(atPath: fileURL.path) else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .fileNotFound,
                    message: "Image file not found: \(path)"
                )
            }

            return ToolExecutionResult(
                toolName: Self.name,
                argumentsJSON: encodeArgsToJSON(args),
                outputJSON: makeSuccessEnvelope(data: ["status": "analyzing", "path": path]),
                isError: false,
                signal: .visionAnalysis(imagePath: path, prompt: prompt)
            )
        }
    }
}
