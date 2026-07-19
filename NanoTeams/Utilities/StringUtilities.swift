import Foundation

extension String {
    /// Canonical form of an LM Studio server URL, for COMPARING or KEYING —
    /// never for building a request (that uses the value the user typed).
    /// Trims, lower-cases, and collapses ALL trailing slashes, so
    /// `http://x:1234/` and `HTTP://X:1234` key the same server.
    ///
    /// Intentionally conservative: `localhost` and `127.0.0.1` are NOT
    /// collapsed (different network identities; firewalls can route them
    /// differently), and default ports are NOT collapsed (LM Studio's `:1234`
    /// is non-standard, so the rule would buy nothing).
    ///
    /// Single source of truth: the Keychain account key
    /// (`KeychainSecureTokenStorage.normalize(baseURL:)`), the model-list cache
    /// key (`ModelCatalog.normalize`), the load-coalescing key
    /// (`ChatModelEnsurer`) and the settings-slot comparison
    /// (`StoreConfiguration.referencesModel`) must agree — a divergence would
    /// strand a stored token or silently double-load a model. Pinned by
    /// `BaseURLNormalizationTests`.
    nonisolated var normalizedBaseURL: String {
        var s = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

extension Array where Element == String {
    /// Normalize string array: trim whitespace, remove empty/duplicate entries, sort case-insensitive.
    /// Preserves first-occurrence order before sorting.
    nonisolated func normalizedUnique() -> [String] {
        var seen = Set<String>()
        return compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return nil }
            seen.insert(trimmed)
            return trimmed
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
