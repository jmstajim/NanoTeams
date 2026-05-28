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
    mutating func applyLMStudioBearer(literal token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
    }
}
