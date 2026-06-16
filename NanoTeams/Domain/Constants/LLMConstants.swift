import Foundation

/// LLM execution limits and retry/streaming knobs.
nonisolated enum LLMConstants {
    /// Maximum tool call iterations (0 = unlimited).
    /// Producing roles terminate via artifact completion; open-ended roles via Supervisor.
    static let maxToolIterations = 0

    /// Max consecutive in-stream thinking-loop breaks for a TOP-LEVEL step before
    /// the recovery escalates from stateless-replay to a terminal action
    /// (`LoopRecoveryPolicy`). 2 ⇒ one stateless replay, then terminal on the
    /// next break — mirrors the 2-strike drift pattern in `handleNoToolCalls`.
    static let maxThinkingLoopBreaks = 2

    /// Combined thinking+content buffer growth (in characters) between in-stream
    /// loop scans inside `performStreamingCall`. Throttles the tail-anchored
    /// `detectTailLoop` scan — replaces the watcher's per-step 3s timestamp
    /// throttle now that streaming-loop detection lives in the stream consumer.
    static let streamLoopScanCadenceChars = 400

    /// Default max consecutive LLM server error retries (0 = unlimited).
    static let defaultMaxLLMRetries = 0

    /// Default LLM streaming HTTP request timeout in seconds.
    /// `0` = no timeout (wait indefinitely). 600s (10 min) is a safe default that
    /// catches stalled connections while allowing reasoning/MoE models to finish
    /// long first-token latency on large prompts. Users can set 0 in settings to
    /// restore unlimited waiting.
    static let defaultLLMRequestTimeoutSeconds = 600

    /// Default delay between LLM retry attempts in seconds. Injectable per
    /// `LLMExecutionService.retryDelaySeconds` (tests use a small value).
    static let llmRetryDelaySeconds: UInt64 = 10

    /// Stable prefix used to BUILD the transient retry-status note written to the
    /// step's conversation while a recoverable LLM error keeps retrying. (Collapse
    /// of consecutive notes is keyed on the message's `sourceContext == .serverError`
    /// tag, not on this prefix — see `appendOrReplaceRetryNotice`.)
    static let llmServerErrorRetryNotePrefix = "LLM server error (attempt"

    /// Character threshold for batching UI flushes during streaming.
    static let uiFlushCharThreshold = 200

    /// Maximum tracked tool calls per step (oldest evicted when exceeded).
    static let maxTrackedToolCalls = 30

    /// Timeout for `cancelStepExecution` to wait for the cancelled task's catch handler
    /// to finish committing partial streaming content + persisting token usage. The
    /// catch chain runs `commitStreamingContent` (in-memory) and `persistTokenUsage`
    /// (one disk write via `mutateTask`). Disk I/O on a healthy filesystem completes
    /// in milliseconds; this cap guards against a stalled disk / locked file leaving
    /// Pause permanently frozen.
    static let cancelHandlerTimeoutSeconds: TimeInterval = 3
}
