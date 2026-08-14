import Foundation

/// Service for generating work-folder context using LLM.
nonisolated final class WorkFolderContextService: @unchecked Sendable {

    private let client: any LLMClient

    init(client: any LLMClient = LLMClientRouter()) {
        self.client = client
    }

    /// Generates work-folder context by analyzing the folder contents via an LLM.
    /// - Parameters:
    ///   - workFolderRoot: The work folder root URL.
    ///   - config: The LLM configuration.
    ///   - customPrompt: Optional override for `AppDefaults.workFolderContextPrompt`.
    /// - Returns: The trimmed generated context, or `nil` when the LLM produced
    ///   only whitespace. Callers must distinguish "nil from empty content" from
    ///   "nil from cancellation" via `Task.isCancelled` at the call site.
    /// - Throws: Transport / decoding errors from `client.streamChat` and
    ///   `CancellationError` if the surrounding `Task` is cancelled mid-stream.
    func generate(
        workFolderRoot: URL,
        config: LLMConfig,
        customPrompt: String? = nil
    ) async throws -> String? {
        // Walk the disk exactly once — retries re-compose from this in-memory
        // input, they never re-scan.
        let input = await Task.detached {
            WorkFolderContextBuilder.buildInput(workFolderRoot: workFolderRoot)
        }.value

        let trimmedCustom = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let system = trimmedCustom.isEmpty
            ? AppDefaults.workFolderContextPrompt
            : trimmedCustom

        // Size the prompt to the model's context window (nil probe → conservative
        // fallback inside the planner).
        let contextTokens = await client.modelContextLength(config: config)
        var budget = WorkFolderContextPromptPlanner.inputTokenBudget(
            contextTokens: contextTokens,
            systemPromptChars: system.count
        )

        // Self-correcting backstop: if the token estimate undershot and the
        // server still reports a context overflow, halve the budget and retry
        // once — unless the composition is already at its irreducible floor
        // (halving can't shrink a mandatory 50-line excerpt), in which case the
        // window is genuinely too small and we surface an actionable error.
        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            let composition = WorkFolderContextPromptPlanner.compose(input: input, tokenBudget: budget)
            do {
                return try await stream(system: system, userMessage: composition.userMessage, config: config)
            } catch {
                guard ContextOverflowClassifier.isContextOverflow(error) else { throw error }
                if attempt < maxAttempts && !composition.atFloor {
                    budget = max(1, budget / 2)
                    continue
                }
                throw WorkFolderContextError.contextWindowTooSmall(
                    modelName: config.modelName,
                    contextTokens: contextTokens
                )
            }
        }
        return nil // unreachable (loop returns or throws)
    }

    /// Streams one context-generation request and returns the trimmed content,
    /// or `nil` when the model produced only whitespace.
    private func stream(system: String, userMessage: String, config: LLMConfig) async throws -> String? {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: system),
            ChatMessage(role: .user, content: userMessage),
        ]

        var collected = ""
        var reasoning = ""
        // prefix-cache-owner: registered by the caller —
        // `NTMSOrchestrator+WorkFolderManagement` notes `.oneShot("work folder context")`.
        for try await event in client.streamChat(
            config: config,
            messages: messages,
            tools: [],
            logger: nil,
            stepID: nil
        ) {
            if !event.contentDelta.isEmpty {
                collected += event.contentDelta
            }
            if !event.thinkingDelta.isEmpty {
                reasoning += event.thinkingDelta
            }
        }

        // Cleaned, and cleaned HERE, because nothing downstream does it: the return value
        // travels `WorkFolderManagementService` → `generateWorkFolderContext` →
        // `updateWorkFolderContext` → `repository`, which only trims, and lands in
        // `settings.context` — which `PromptBuilder.buildWorkFolderContextMessage` renders
        // into the system prompt of EVERY role on EVERY request. A leaked `<|channel|>final`
        // would sit in segment 0 for the life of the work folder, invalidating nothing and
        // fixable only by hand-editing the field.
        // `cleanHarmonyTokens`, not the bare `ModelTokenCleaner.clean`: the latter strips
        // `<|channel|>` and leaves the glued protocol keyword behind, so a reasoning model's
        // reply arrives as "finalA Swift package." — and THAT is the string that becomes the
        // first line of every role's work-folder section. The keywords it removes
        // (`final`/`commentary`/`message`/…) are Harmony header syntax, never prose.
        let answer = ModelReplyChannels.answer(
            content: collected,
            reasoning: reasoning,
            prepare: {
                ConversationRepairService.cleanHarmonyTokens($0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            })
        return answer.isEmpty ? nil : answer
    }
    nonisolated deinit {}
}

/// Errors surfaced by `WorkFolderContextService` that carry an actionable
/// remedy (kept next to the single consumer per Information Expert).
nonisolated enum WorkFolderContextError: LocalizedError {
    /// Even the minimally-trimmed prompt (header + a 50-line-floor excerpt)
    /// did not fit the model's context window across the bounded retries.
    case contextWindowTooSmall(modelName: String, contextTokens: Int?)

    var errorDescription: String? {
        switch self {
        case let .contextWindowTooSmall(modelName, contextTokens):
            let ctx = contextTokens.map { " (\($0) tokens)" } ?? ""
            return "The model’s context window\(ctx) is too small to summarize this folder, even after trimming. "
                + "Increase the context length in LM Studio (model load settings) or load a larger-context model. "
                + "Model: \(modelName)."
        }
    }
}
