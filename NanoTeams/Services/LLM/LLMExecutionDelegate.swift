import Foundation

// MARK: - TaskMutationDelegate

/// Atomic mutate-and-persist operation on a task.
///
/// Services that only need to mutate task state (without reading project-wide
/// settings) should depend on this narrow protocol rather than the full
/// `LLMStateDelegate`. `TaskMutationService` composes its pure inout helpers
/// inside the closure passed to `mutateTask` — the delegate guarantees atomic
/// persistence of the combined mutation.
@MainActor
protocol TaskMutationDelegate: AnyObject {
    /// Mutates a specific task and persists changes to disk.
    /// Returns `true` if the mutation persisted successfully.
    @discardableResult
    func mutateTask(taskID: Int, _ mutate: (inout NTMSTask) -> Void) async -> Bool
}

// MARK: - LLMStateDelegate

/// Read-only access to project/task state plus task mutation.
/// Used by all LLMExecutionService extensions that read or mutate task state.
@MainActor
protocol LLMStateDelegate: TaskMutationDelegate {
    var workFolderURL: URL? { get }
    /// The global LLM configuration — provider, URL, model, maxTokens, temperature.
    var globalLLMConfig: LLMConfig { get }
    /// Maximum consecutive LLM server error retries (0 = unlimited).
    var maxLLMRetries: Int { get }
    /// Vision model configuration (nil = vision not configured).
    var visionLLMConfig: LLMConfig? { get }
    /// Returns the project snapshot (for project-level reads like settings, targets).
    var snapshot: WorkFolderContext? { get }
    /// Whether logging (network_log.json, conversation_log.md, tool_calls.jsonl) is enabled.
    var loggingEnabled: Bool { get }
    /// Loads a task by ID (active or background).
    func loadedTask(_ taskID: Int) -> NTMSTask?
}

// MARK: - LLMStreamingDelegate

/// Real-time streaming display and processing progress.
/// Used by LLMExecutionService streaming extensions only.
@MainActor
protocol LLMStreamingDelegate: AnyObject {
    /// Pre-creates an empty LLMMessage in the step's conversation at stream start.
    /// This allows the timeline to render the message immediately (with spinner)
    /// and stream content into it inline, avoiding visual jumps on commit.
    func beginStreaming(stepID: String, messageID: UUID, role: Role, taskID: Int) async
    /// Appends content to the streaming preview for a step.
    func appendStreamingPreview(stepID: String, messageID: UUID, role: Role, content: String)
    /// Appends thinking content to the streaming preview for a step.
    func appendStreamingThinking(stepID: String, content: String)
    /// Commits streaming: updates the pre-created LLMMessage with final content and thinking,
    /// and updates/creates the corresponding StepMessage.
    func commitStreaming(stepID: String, taskID: Int, content: String, thinking: String?) async
    /// Clears the streaming preview for a step without committing.
    func clearStreamingPreview(stepID: String)
    /// Updates prompt processing progress for a step (0.0–1.0).
    func updateStreamingProcessingProgress(stepID: String, progress: Double)
    /// Clears prompt processing progress for a step.
    func clearStreamingProcessingProgress(stepID: String)
}

// MARK: - LLMMeetingDelegate

/// Meeting participant UI signals.
/// Used by LLMExecutionService team collaboration extensions.
@MainActor
protocol LLMMeetingDelegate: AnyObject {
    /// Signals that the given roles are currently participating in a meeting for this task.
    func setActiveMeetingParticipants(_ participantIDs: Set<String>, for taskID: Int)
    /// Clears the active meeting participant signal for this task.
    func clearActiveMeetingParticipants(for taskID: Int)
}

// MARK: - LLMExecutionDelegate

/// Composed delegate — full conformance for NTMSOrchestrator.
/// Individual LLMExecutionService extensions declare the narrower sub-protocol
/// they actually need (LLMStateDelegate, LLMStreamingDelegate, or LLMMeetingDelegate).
typealias LLMExecutionDelegate = LLMStateDelegate & LLMStreamingDelegate & LLMMeetingDelegate
