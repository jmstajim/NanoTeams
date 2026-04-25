import Foundation

/// Extension for handling vision analysis tool signals.
extension LLMExecutionService {

    /// Processes a `.visionAnalysis` signal: reads the image, calls the vision model,
    /// and appends the analysis result to the conversation. Updates the tool call record
    /// with the final result (replacing the interim `{status: "analyzing"}` placeholder).
    func appendVisionResult(
        result: ToolExecutionResult,
        toolCallID: UUID,
        stepID: String,
        client: any LLMClient,
        config _: LLMConfig,
        networkLogger: NetworkLogger?,
        conversationMessages: inout [ChatMessage],
        memory: ToolCallCache? = nil
    ) async {
        guard case .visionAnalysis(let imagePath, let prompt) = result.signal else { return }

        var analysisText: String
        var isError = false
        do {
            guard let visionConfig = await delegate?.visionLLMConfig else {
                throw VisionError.notConfigured
            }
            guard let workFolderRoot = await delegate?.workFolderURL else {
                throw VisionError.noProject
            }
            let internalDir = NTMSPaths(workFolderRoot: workFolderRoot).internalDir
            let resolver = SandboxPathResolver(workFolderRoot: workFolderRoot, internalDir: internalDir)
            let fileURL = try resolver.resolveFileURL(relativePath: imagePath)
            guard let imageData = FileManager.default.contents(atPath: fileURL.path) else {
                throw VisionError.fileNotFound(imagePath)
            }
            guard imageData.count <= VisionConstants.maxImageBytes else {
                throw VisionError.fileTooLarge(imageData.count)
            }
            let ext = fileURL.pathExtension.lowercased()
            let mimeType = VisionConstants.mimeTypes[ext] ?? "image/jpeg"

            analysisText = try await VisionAnalysisService.analyze(
                prompt: prompt,
                imageBase64: imageData.base64EncodedString(),
                mimeType: mimeType,
                config: visionConfig,
                client: client,
                logger: networkLogger
            )
        } catch is CancellationError {
            // Task was paused/cancelled — propagate without recording an error
            return
        } catch let visionError as VisionError {
            analysisText = "Vision analysis failed: \(visionError.localizedDescription)"
            isError = true
        } catch {
            print("[Vision] Analysis failed for \(imagePath): \(error)")
            analysisText = "Vision analysis failed: \(error.localizedDescription)"
            isError = true
        }

        let envelope: String
        if isError {
            envelope = makeErrorEnvelope(
                code: .commandFailed, message: analysisText
            )
        } else {
            envelope = makeSuccessEnvelope(data: ["path": imagePath, "analysis": analysisText])
        }
        conversationMessages.append(ChatMessage(
            role: .tool, content: envelope, toolCallID: result.providerID
        ))
        await appendLLMMessage(stepID: stepID, role: .tool, content: """
            [CALL] \(result.toolName)
            Arguments: \(result.argumentsJSON)

            [RESULT]
            \(envelope)
            """)

        // Update the tool call record with the final result (replaces interim "analyzing" status)
        let finalResult = ToolExecutionResult(
            providerID: result.providerID,
            toolName: result.toolName,
            argumentsJSON: result.argumentsJSON,
            outputJSON: envelope,
            isError: isError
        )
        await updateToolCallResult(stepID: stepID, toolCallID: toolCallID, result: finalResult)

        // Record the FINAL vision result in the tool-call cache. The upstream
        // `processToolResults` skips `.visionAnalysis` from its pre-record
        // loop because the interim `{"status":"analyzing"}` placeholder would
        // dedup wrong on the next identical call.
        memory?.record(
            toolName: result.toolName,
            argumentsJSON: result.argumentsJSON,
            resultJSON: envelope,
            isError: isError
        )
    }
}

// MARK: - VisionError

enum VisionError: LocalizedError {
    case notConfigured
    case noProject
    case fileNotFound(String)
    case fileTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Vision model not configured. Set up a vision model in Settings → LLM."
        case .noProject:
            "No work folder available."
        case .fileNotFound(let path):
            "Image file not found: \(path)"
        case .fileTooLarge(let size):
            "Image too large (\(size / 1_048_576)MB). Maximum: 10MB."
        }
    }
}
