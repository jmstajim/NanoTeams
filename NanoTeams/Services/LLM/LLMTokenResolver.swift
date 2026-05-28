import Foundation

/// Resolves an LM Studio bearer token from the URL of the request being built.
/// Injected into every HTTP client so the secret never has to ride on `LLMConfig`,
/// `LLMOverride`, or `EmbeddingConfig` (all of which are Codable and persist —
/// see CLAUDE.md "LM Studio Authentication" for the leak-vector reasoning).
protocol LLMTokenResolver: Sendable {
    nonisolated func token(forBaseURL urlString: String) -> String?
}

/// Production resolver — consults the secure token store keyed by normalized URL.
nonisolated struct DefaultLLMTokenResolver: LLMTokenResolver {
    let storage: any SecureTokenStorage

    init(storage: any SecureTokenStorage = KeychainSecureTokenStorage()) {
        self.storage = storage
    }

    func token(forBaseURL urlString: String) -> String? {
        let key = KeychainSecureTokenStorage.normalize(baseURL: urlString)
        return storage.token(forKey: key)
    }
}

#if DEBUG
/// Test resolver. Construct with a `[urlString: token]` dictionary; lookup
/// normalizes the URL the same way production does so tests can hit either form.
nonisolated struct StubLLMTokenResolver: LLMTokenResolver {
    let tokens: [String: String]

    init(_ tokens: [String: String] = [:]) {
        var normalized: [String: String] = [:]
        for (url, token) in tokens {
            normalized[KeychainSecureTokenStorage.normalize(baseURL: url)] = token
        }
        self.tokens = normalized
    }

    func token(forBaseURL urlString: String) -> String? {
        tokens[KeychainSecureTokenStorage.normalize(baseURL: urlString)]
    }
}
#endif

/// Resolver that lets the settings UI inject a freshly-typed token for one
/// URL (the one being tested) while still consulting the Keychain for others.
/// Empty overrides are dropped at construction so the UI can blindly forward
/// the SecureField value — an empty SecureField means "no override", not
/// "force the request to be unauthenticated".
nonisolated struct OverridingLLMTokenResolver: LLMTokenResolver {
    let overrides: [String: String]
    let fallback: any LLMTokenResolver

    init(overrides: [String: String], fallback: any LLMTokenResolver = DefaultLLMTokenResolver()) {
        // Reentrancy guard: nesting two `OverridingLLMTokenResolver`s would
        // make the outer's overrides shadow the inner's, which is almost
        // never what anyone wants. Delegate to the pure `flatten` helper —
        // tested directly without firing the assertion — and fire
        // `assertionFailure` here only when nesting was detected, so a
        // programmer error surfaces loudly in DEBUG/CI without taking
        // production down.
        let result = Self.flatten(newOverrides: overrides, fallback: fallback)
        if result.didDetectNesting {
            assertionFailure("Nested OverridingLLMTokenResolver — flatten the override maps into one resolver.")
        }
        self.overrides = result.overrides
        self.fallback = result.fallback
    }

    /// Pure flattening logic exposed for testing. Returns the merged
    /// override map, the inner-most fallback, and a flag indicating
    /// whether the input fallback was itself an
    /// `OverridingLLMTokenResolver` (i.e. caller passed a nested chain).
    /// The init wraps this and fires `assertionFailure` on the flag —
    /// keeping the assertion out of the function body lets tests verify
    /// the merge contract without crashing the test process.
    static func flatten(
        newOverrides: [String: String],
        fallback: any LLMTokenResolver
    ) -> (overrides: [String: String], fallback: any LLMTokenResolver, didDetectNesting: Bool) {
        var merged: [String: String] = [:]
        var unwrappedFallback: any LLMTokenResolver = fallback
        var didDetectNesting = false
        if let nested = fallback as? OverridingLLMTokenResolver {
            didDetectNesting = true
            // Inner overrides come first (lower priority); the loop below
            // applies the new overrides last so they win on conflict.
            merged = nested.overrides
            unwrappedFallback = nested.fallback
        }
        for (url, token) in newOverrides {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty overrides MUST fall through. If the user has typed nothing
            // into the SecureField, the request should still pick up whatever
            // the Keychain has for the same URL (e.g. a token already saved
            // from the main LLM card).
            guard !trimmed.isEmpty else { continue }
            merged[KeychainSecureTokenStorage.normalize(baseURL: url)] = trimmed
        }
        return (merged, unwrappedFallback, didDetectNesting)
    }

    func token(forBaseURL urlString: String) -> String? {
        let key = KeychainSecureTokenStorage.normalize(baseURL: urlString)
        if let override = overrides[key] { return override }
        return fallback.token(forBaseURL: urlString)
    }
}
