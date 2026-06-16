import Foundation

/// Decides whether a thrown LLM error is worth retrying, or is permanent and
/// should fail the step immediately.
///
/// The step-execution retry loop ([`LLMExecutionService+StepLifecycle`]) used to
/// retry *every* thrown error, bounded only by `maxLLMRetries` (default `0` =
/// unlimited). A permanent error — a wrong model identifier (HTTP 404
/// `model_not_found`), an auth failure (401/403), or an invalid base URL — would
/// then spin forever, appending a noisy "attempt N" bubble each pass and never
/// reaching `.failed`, so the user never got an error bubble. This policy lets
/// the loop short-circuit those: permanent → throw now → step fails → bubble.
///
/// Stateless on purpose (mirrors `LLMAuthErrorClassifier` / `LoopRecoveryPolicy`)
/// so the retry loop can consult it without plumbing.
nonisolated enum LLMRetryPolicy {

    /// `false` for permanent errors that cannot recover by retrying (wrong model,
    /// auth, malformed URL). `true` for transient/recoverable errors (network,
    /// rate limit, 5xx, poisoned-chain 400). Non-`LLMClientError` errors
    /// (URLError, transport) default to retryable.
    static func isRetryable(_ error: Error) -> Bool {
        guard let clientError = error as? LLMClientError else {
            return true // network / transport / unknown → transient, retry
        }
        switch clientError {
        case .invalidBaseURL:
            // A malformed/empty server URL won't fix itself by retrying — the
            // user has to correct the configuration.
            return false
        case .rateLimited:
            // Throttling is transient; the loop backs off and retries.
            return true
        case .missingResponse, .providerError:
            // Could be a transient server hiccup — retry.
            return true
        case .badHTTPStatus(let code, _):
            // 4xx are client errors and permanent EXCEPT:
            //   400 — poisoned-chain recovery: the loop clears the session and
            //         rebuilds the conversation statelessly, which can succeed.
            //   408 — request timeout (transient).
            //   429 — rate limit (normally surfaced as `.rateLimited`, guarded here too).
            // Everything else 4xx (401/403/404/405/409/410/422/…) is permanent.
            // 5xx are transient server errors → retry.
            if (400..<500).contains(code) {
                return code == 400 || code == 408 || code == 429
            }
            return true
        }
    }
}
