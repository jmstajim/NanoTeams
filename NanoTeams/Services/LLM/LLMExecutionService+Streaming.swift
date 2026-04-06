import Foundation

/// Extension containing LLM streaming call logic, token collection, and post-stream processing.
extension LLMExecutionService {

    // MARK: - Streaming Result

    /// Encapsulates the result of a single LLM streaming call.
    struct StreamingResult {
        var assistantContent: String
        var thinkingContent: String
        var resolvedToolCalls: [StepToolCall]
        var sawHarmonyMarker: Bool
        var harmonyBuffer: String
        var session: LLMSession?
        var tokenUsage: TokenUsage?
    }

    // MARK: - LLM Streaming

    /// Executes a single LLM streaming call and collects assistant content, thinking, and tool calls.
    /// Uses inline streaming: pre-creates an LLMMessage at stream start, streams content into it,
    /// and commits final content on completion (or partial content on cancellation).
    func performStreamingCall(
        stepID: String,
        roleForMessage: Role,
        client: any LLMClient,
        config: LLMConfig,
        tools: [ToolSchema],
        conversationMessages: [ChatMessage],
        session: LLMSession?,
        networkLogger: NetworkLogger?,
        roleName: String? = nil
    ) async throws -> StreamingResult {
        guard let delegate else {
            return StreamingResult(
                assistantContent: "", thinkingContent: "",
                resolvedToolCalls: [], sawHarmonyMarker: false, harmonyBuffer: "")
        }

        let streamingMessageID = UUID()
        var assistantCollected = ""
        var thinkingCollected = ""

        // Pre-create empty LLMMessage for inline streaming (no visual jump on commit)
        if let tid = taskIDForStep(stepID) {
            await delegate.beginStreaming(
                stepID: stepID, messageID: streamingMessageID,
                role: roleForMessage, taskID: tid)
        }

        func appendAssistant(_ text: String) {
            guard !text.isEmpty else { return }
            assistantCollected += text
            delegate.appendStreamingPreview(
                stepID: stepID, messageID: streamingMessageID, role: roleForMessage, content: text)
        }

        let uiFlushInterval: TimeInterval = 0.2
        let uiFlushCharThreshold = LLMConstants.uiFlushCharThreshold
        var pendingUI = ""
        var lastUIFlush = Date()

        func flushPendingUI(force: Bool = false) {
            guard !pendingUI.isEmpty else { return }
            let now = Date()
            if force || pendingUI.count >= uiFlushCharThreshold
                || now.timeIntervalSince(lastUIFlush) >= uiFlushInterval
            {
                appendAssistant(pendingUI)
                pendingUI.removeAll(keepingCapacity: true)
                lastUIFlush = now
            }
        }

        var toolAccumulator = ToolCallAccumulator()
        var sawHarmonyMarker = false
        var harmonyBuffer = ""
        var uiBuffer = ""
        var capturedSession: LLMSession?
        var capturedUsage: TokenUsage?

        /// Commits streaming content (final or partial on cancellation).
        func commitStreamingContent() async {
            flushPendingUI(force: true)
            if let tid = taskIDForStep(stepID) {
                let cleanedContent = ModelTokenCleaner.clean(assistantCollected)
                let thinkingToCommit = thinkingCollected.isEmpty ? nil : thinkingCollected
                await delegate.commitStreaming(
                    stepID: stepID, taskID: tid,
                    content: cleanedContent, thinking: thinkingToCommit)
            }
        }

        do {
            for try await event in client.streamChat(
                config: config, messages: conversationMessages, tools: tools,
                session: session, logger: networkLogger, stepID: stepID, roleName: roleName)
            {
                if Task.isCancelled { throw CancellationError() }

                if !event.thinkingDelta.isEmpty {
                    thinkingCollected += event.thinkingDelta
                    delegate.appendStreamingThinking(stepID: stepID, content: event.thinkingDelta)
                }

                // Forward processing progress to UI
                if let progress = event.processingProgress {
                    delegate.updateStreamingProcessingProgress(stepID: stepID, progress: progress)
                }

                if !event.contentDelta.isEmpty {
                    let delta = event.contentDelta
                    if sawHarmonyMarker {
                        harmonyBuffer += delta
                    } else {
                        uiBuffer += delta
                        pendingUI += delta
                        let harmonyMarkers = [
                            HarmonyToolCallParser.callMarker,
                            HarmonyToolCallParser.startFunctionPrefix,
                            HarmonyToolCallParser.channelMarker
                        ]
                        if harmonyMarkers.contains(where: { uiBuffer.contains($0) }) {
                            sawHarmonyMarker = true
                            harmonyBuffer = uiBuffer
                            // Truncate to content before the earliest marker.
                            // uiBuffer is the complete record of all deltas — use it as
                            // source of truth to handle markers split across flush boundaries.
                            var earliestLower: String.Index?
                            for marker in harmonyMarkers {
                                if let range = uiBuffer.range(of: marker) {
                                    if earliestLower == nil || range.lowerBound < earliestLower! {
                                        earliestLower = range.lowerBound
                                    }
                                }
                            }
                            if let lower = earliestLower {
                                assistantCollected = String(uiBuffer[..<lower])
                            }
                            pendingUI = ""
                            continue
                        }
                        flushPendingUI()
                    }
                }

                if !event.toolCallDeltas.isEmpty {
                    toolAccumulator.absorb(event.toolCallDeltas)
                }

                if let s = event.session { capturedSession = s }
                if let u = event.tokenUsage { capturedUsage = u }
            }

            if Task.isCancelled { throw CancellationError() }

            // Clear processing progress (stream completed successfully)
            delegate.clearStreamingProcessingProgress(stepID: stepID)

            // Commit final content
            await commitStreamingContent()
        } catch is CancellationError {
            // Commit partial content on cancellation
            delegate.clearStreamingProcessingProgress(stepID: stepID)
            await commitStreamingContent()
            throw CancellationError()
        }

        // Reconstruct tool calls
        var resolvedToolCalls = toolAccumulator.finalize()
        if resolvedToolCalls.isEmpty, sawHarmonyMarker {
            resolvedToolCalls = harmonyParser.extractAllToolCalls(from: harmonyBuffer)
        }

        return StreamingResult(
            assistantContent: assistantCollected,
            thinkingContent: thinkingCollected,
            resolvedToolCalls: resolvedToolCalls,
            sawHarmonyMarker: sawHarmonyMarker,
            harmonyBuffer: harmonyBuffer,
            session: capturedSession,
            tokenUsage: capturedUsage
        )
    }

    // MARK: - Post-Stream Processing

    /// Appends the assistant/tool-call messages to the conversation and persisted LLM log.
    /// Returns `.completed` if the LLM signaled task completion, `nil` otherwise.
    func processStreamingResult(
        _ result: StreamingResult,
        stepID: String,
        conversationMessages: inout [ChatMessage]
    ) async -> LLMStepStop? {
        let hasContent = !result.assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasThinking = !result.thinkingContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasToolCalls = !result.resolvedToolCalls.isEmpty

        // Append assistant message to in-memory conversation for session slicing.
        // NOTE: The LLMMessage and StepMessage are already committed by commitStreaming()
        // in performStreamingCall(), so we only update conversationMessages here.
        if hasContent || hasToolCalls {
            let cleanedContent = hasContent ? ModelTokenCleaner.clean(result.assistantContent) : nil
            if hasToolCalls {
                let toolCallMessages = result.resolvedToolCalls.map { call in
                    ChatToolCall(
                        id: call.providerID ?? UUID().uuidString,
                        name: call.name,
                        argumentsJSON: call.argumentsJSON
                    )
                }
                conversationMessages.append(
                    ChatMessage(
                        role: .assistant,
                        content: cleanedContent,
                        toolCalls: toolCallMessages
                    ))
            } else {
                conversationMessages.append(
                    ChatMessage(role: .assistant, content: cleanedContent))
            }
        }

        if hasToolCalls {
            // Re-stamp so tool calls appear after the assistant/thinking message in timeline
            let restamped = result.resolvedToolCalls.map { call in
                var c = call
                c.createdAt = MonotonicClock.shared.now()
                return c
            }
            await appendToolCalls(stepID: stepID, toolCalls: restamped)
        }

        return nil
    }

}
