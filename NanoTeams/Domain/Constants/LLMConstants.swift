import Foundation

/// LLM execution limits and retry/streaming knobs.
enum LLMConstants {
    /// Maximum tool call iterations (0 = unlimited).
    /// Producing roles terminate via artifact completion; open-ended roles via Supervisor.
    static let maxToolIterations = 0

    /// Default max consecutive LLM server error retries (0 = unlimited).
    static let defaultMaxLLMRetries = 0

    /// Default LLM streaming HTTP request timeout in seconds.
    /// `0` = no timeout (wait indefinitely). 600s (10 min) is a safe default that
    /// catches stalled connections while allowing reasoning/MoE models to finish
    /// long first-token latency on large prompts. Users can set 0 in settings to
    /// restore unlimited waiting.
    static let defaultLLMRequestTimeoutSeconds = 600

    /// Delay between LLM retry attempts in seconds.
    static let llmRetryDelaySeconds: UInt64 = 2

    /// Character threshold for batching UI flushes during streaming.
    static let uiFlushCharThreshold = 200

    /// Maximum tracked tool calls per step (oldest evicted when exceeded).
    static let maxTrackedToolCalls = 30
}
