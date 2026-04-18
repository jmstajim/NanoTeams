import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - analyze_image

struct AnalyzeImageTool: ToolHandler {
    static let name = TN.analyzeImage
    static let schema = ToolSchema(
        name: TN.analyzeImage,
        description: "Analyze an image file using a vision model. Returns a text description. Use for screenshots, diagrams, UI mockups. The image must be inside the work folder. Supported formats: PNG, JPEG, GIF, WebP, BMP.",
        parameters: JS.object(
            properties: [
                "path": JS.string("Relative path to the image file (png, jpg, jpeg, gif, webp, bmp)"),
                "prompt": JS.string("Question or instruction about the image"),
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
            let path = try requiredString(args, "path")
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
