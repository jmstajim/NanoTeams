import Foundation

/// Maps a non-2xx HTTP status returned by an LM Studio endpoint into a
/// user-facing message. The 401 case is the load-bearing one — it's the only
/// signal the user gets that "Require Authentication" is enabled on the server
/// and they need to enter (or fix) their API token.
///
/// Stateless on purpose so any HTTP error path can call it without plumbing.
enum LLMAuthErrorClassifier {

    /// Discrimination of which auth-failure shape we got. `missingOrInvalid`
    /// (401) and `forbidden` (403) need the same user-visible message but are
    /// kept distinct so a future caller (telemetry, retry policy) can branch
    /// on them without parsing strings.
    enum AuthFailureKind {
        /// 401 — token missing or invalid.
        case missingOrInvalid
        /// 403 — token valid but lacks the required permission.
        case forbidden
    }

    /// Returns the auth-failure shape if `status` is one, otherwise `nil`.
    /// Use this when you need to branch (preflight bail vs fall-back, retry
    /// policy, telemetry classification). Call sites that only need a yes/no
    /// can use `isAuthFailure(status:)` below.
    static func authFailureKind(status: Int) -> AuthFailureKind? {
        switch status {
        case 401: return .missingOrInvalid
        case 403: return .forbidden
        default: return nil
        }
    }

    /// Convenience boolean wrapper for "this status is an auth failure".
    static func isAuthFailure(status: Int) -> Bool {
        authFailureKind(status: status) != nil
    }

    /// User-facing message. Generic for non-auth errors so we don't drown the
    /// signal: only 401/403 get the "go add a token" guidance.
    static func message(forStatus status: Int, body: String?) -> String {
        if isAuthFailure(status: status) {
            return "Authentication required — add your LM Studio API token in Settings → LLM. "
                + "(HTTP \(status))"
        }
        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            return "Server returned HTTP \(status): \(body)"
        }
        return "Server returned HTTP \(status)."
    }
}
