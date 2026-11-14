import Foundation

nonisolated extension URLRequest {
    /// Sets `Authorization: Bearer <token>` if the resolver has a token for this
    /// base URL. Whitespace-only / nil tokens are treated as "no token" so an
    /// accidental empty Keychain read can't break unauthenticated servers.
    mutating func applyLMStudioBearer(baseURL: String, resolver: any LLMTokenResolver) {
        applyLMStudioBearer(literal: resolver.token(forBaseURL: baseURL))
    }

    /// Used by UI surfaces (Test Connection / Fetch Models) where the user has
    /// typed a token into a SecureField but we have not yet committed it to the
    /// Keychain. Saves a premature write if the user cancels.
    ///
    /// Every request to an LLM server passes here — with a token or without — before its first
    /// byte goes out, which makes this the one seam where the server's port on this machine is
    /// reserved against a role's `bash` (`LoopbackPortReservations.reserve(forRequestTo:)`): a
    /// command launched before the port joined the list could be listening there, and would
    /// receive the token and the prompt. Until 2026-11-08 only a step's own requests reserved it,
    /// at step entry; the status monitor's poll, Test Connection, embeddings, the judges, vision
    /// and the benchmark did not (review 2026-11-08).
    mutating func applyLMStudioBearer(literal token: String?) {
        LoopbackPortReservations.shared.reserve(forRequestTo: url)
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
    }
}
