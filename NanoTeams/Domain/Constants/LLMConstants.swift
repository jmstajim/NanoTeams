import Foundation

/// LLM execution limits and retry/streaming knobs.
nonisolated enum LLMConstants {

    /// Seconds Ollama should keep a model — and its KV prefix cache — resident after a
    /// request. Ollama's own default is 300 s, which expires during a human's
    /// `ask_supervisor` round-trip and throws away the cache the replayed conversation
    /// depends on. 30 minutes covers a realistic answer time; `0` unloads immediately
    /// and negative values mean "keep loaded indefinitely" (Ollama's convention).
    static let defaultOllamaKeepAliveSeconds = 1800

    /// Maximum tool call iterations (0 = unlimited).
    /// Producing roles terminate via artifact completion; open-ended roles via Supervisor.
    static let maxToolIterations = 0

    /// Max consecutive in-stream thinking-loop breaks for a TOP-LEVEL step before
    /// the recovery escalates from a corrected retry to a terminal action
    /// (`LoopRecoveryPolicy`). 3 ⇒ two corrected retries, then terminal.
    ///
    /// The correction is what makes a retry meaningful: the transport is stateless,
    /// so a bare re-entry resends byte-identical bytes into the same attractor. The
    /// two retries are also deliberately UNLIKE each other — nudges accumulate, and
    /// `nudgeText(signal:attempt:)` escalates on the second — because re-sampling the
    /// same conditioning twice is one attempt, not two.
    ///
    /// Raised from 2 after 2026-07-25, where two independent roles each burned the
    /// whole budget inside ~75 s. Each attempt costs ~40 s of wall clock, which is
    /// the honest price of the third: it buys another sample, not a guarantee. What
    /// makes it worth paying is that a terminal is no longer a dead end — a loop park
    /// now rolls back the attention baseline (`noteAutovisorLoopPark`) so the manager
    /// is woken again rather than left parked until the auto-off timer.
    static let maxThinkingLoopBreaks = 3

    /// Max consecutive NON-PRODUCTIVE turns before `noteNonProductiveTurn` terminates
    /// the step. Non-productive = no tool calls at all, only `ask_supervisor`
    /// (auto-answered in autonomous mode, so the model can ping itself forever without
    /// progressing), or a batch whose every call came back an error
    /// (`ToolTurnProductivity`). 20 leaves room for 19 nudges to recover before
    /// terminating — a local model that narrates in prose routinely needs several
    /// before it remembers to call its completion tool, and the old value of 3 declared
    /// such a pass stuck.
    ///
    /// **This value IS the ceiling, and it applies to EVERY role.** Nothing else bounds
    /// a burn: `maxToolIterations` is unlimited, the Autovisor manager is excluded from
    /// its own stuck detector, and its task carries no `runTimeoutSeconds`. That claim
    /// used to be false — the counter was reachable only for an advisory role under
    /// autonomous mode, and then only produced a terminal for the manager or a chat-mode
    /// team, so five shapes bypassed it entirely (repetitive-text turns, producing roles,
    /// manual mode, an unresolved role definition, and advisory-in-a-non-chat-team).
    /// Keep the counter shape-independent: it is the only bound that survives a model
    /// varying HOW it fails.
    ///
    /// The TERMINAL is role-shaped (the manager parks for events, a chat advisory role
    /// finishes `.done`, everything else escalates to the Supervisor); the CAP
    /// deliberately is not — every terminal reads this one constant. That is a choice,
    /// not an oversight: don't "fix" it by splitting without asking. Consequence to keep
    /// in mind — for an ordinary autonomous chat advisory role this cap is the TURN
    /// TERMINATOR (prose is its answer, so hitting the cap is how a normal reply ends),
    /// which makes such a reply cost up to 20 LLM round-trips. No shipped template is
    /// autonomous + chat-mode + advisory except the Autovisor, so that path is reachable
    /// only via a custom or LLM-generated team.
    static let maxNonProductiveTurns = 20

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
