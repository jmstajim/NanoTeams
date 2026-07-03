import AppKit
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
        taskID: Int,
        client: any LLMClient,
        config: LLMConfig,
        networkLogger: NetworkLogger?,
        conversationMessages: inout [ChatMessage],
        tracker: ToolCallTracker? = nil
    ) async {
        guard case .visionAnalysis(let imagePath, let prompt) = result.signal else { return }

        // Unified in-chat vision: when Computer Use is enabled AND the main model is
        // AUTO-DETECTED as vision-capable (`mainModelSeesImages`, replacing the manual
        // toggle), feed the file image straight into the MAIN chat so the reasoning model
        // answers in context — one brain, no second model. Only kicks in when Computer Use
        // is on, so the default `analyze_image` sub-model behavior is unchanged for
        // everyone else. Falls through to the sub-model path if the file can't be read.
        if delegate?.computerUsePolicy.isEnabled == true,
           await mainModelSeesImages(config: config, client: client),
           let loaded = try? loadVisionImage(imagePath: imagePath) {
            let rep = NSBitmapImageRep(data: loaded.data)
            let envelope = makeSuccessEnvelope(data: [
                "path": imagePath,
                "status": "Image attached below — inspect it and answer.",
            ])
            await appendImageToMainChat(
                envelope: envelope,
                imageBase64: loaded.data.base64EncodedString(), imageMime: loaded.mimeType,
                pixelWidth: rep?.pixelsWide ?? 0, pixelHeight: rep?.pixelsHigh ?? 0,
                userCaption: "[Image for tool_call \(result.providerID ?? "")] \(prompt)",
                result: result, toolCallID: toolCallID, stepID: stepID, taskID: taskID,
                conversationMessages: &conversationMessages, tracker: tracker)
            return
        }

        var analysisText: String
        var isError = false
        do {
            guard let visionConfig = delegate?.visionLLMConfig else {
                throw VisionError.notConfigured
            }
            let loaded = try loadVisionImage(imagePath: imagePath)
            analysisText = try await VisionAnalysisService.analyze(
                prompt: prompt,
                imageBase64: loaded.data.base64EncodedString(),
                mimeType: loaded.mimeType,
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

        let envelope = isError
            ? makeErrorEnvelope(code: .commandFailed, message: analysisText)
            : makeSuccessEnvelope(data: ["path": imagePath, "analysis": analysisText])

        // Shared tool-result commit (append tool message, persist [CALL]/[RESULT], update the
        // tool card, record the tracker). The tracker record matters because upstream
        // `processToolResults` skips `.visionAnalysis` in its pre-record loop (it only has the
        // interim `{"status":"analyzing"}` placeholder then), so without it the loop detector's
        // next `recentCalls` snapshot would see the placeholder instead of the real envelope.
        await finalizeToolResult(
            envelope: envelope, isError: isError, result: result, toolCallID: toolCallID,
            stepID: stepID, taskID: taskID, conversationMessages: &conversationMessages, tracker: tracker)
    }

    /// Resolves + reads an image file inside the work folder for vision, enforcing the size cap
    /// and resolving the MIME type. Shared by the in-chat and sub-model paths. Throws the typed
    /// `VisionError` cases (`.noProject` / `.fileNotFound` / `.fileTooLarge`) so the sub-model
    /// path surfaces an accurate reason; the in-chat path uses `try?` and falls through on any
    /// failure.
    private func loadVisionImage(imagePath: String) throws -> (data: Data, mimeType: String) {
        guard let workFolderRoot = delegate?.workFolderURL else { throw VisionError.noProject }
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
        return (imageData, VisionConstants.mimeTypes[ext] ?? "image/jpeg")
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
