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

    /// `http://127.0.0.1:1234/` → `127.0.0.1:1234`. The tmux-style short form of an endpoint, for
    /// DISPLAY only — never for keying or for building a request.
    ///
    /// Separate from `normalizedBaseURL` on purpose: that one is a comparison key and deliberately
    /// keeps the scheme, because two schemes are two servers. This one drops everything a reader
    /// does not need to tell one local server from another, and a port is exactly what does tell
    /// them apart — so the port is kept even when it is the scheme's default.
    ///
    /// One caller is close to the line this draws: the delete confirmation names its target with
    /// this label. That is deliberate — the point of the sentence is to match what the row the
    /// user clicked SHOWS, and the row shows this. The identity the delete acts on is still
    /// `BenchmarkLeaderboard.groupKey`, which keeps the scheme and the path this drops.
    ///
    /// Anything `URL` cannot parse comes back trimmed but otherwise verbatim: a string this cannot
    /// shorten is still the only name that endpoint has, and inventing a prettier one would hide
    /// which server produced a measurement.
    nonisolated var endpointHostLabel: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host else {
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }
}

extension Array {
    /// Trim → drop empty → drop duplicates → sort case-insensitively, on whatever names the element.
    ///
    /// The name projection exists because model lists are normalized in two shapes now — bare
    /// `[String]` and `[LLMModelInfo]` — and a second near-identical trim/dedupe/sort would drift
    /// from this one (CLAUDE.md #55). It is the same ordering rule either way, which is what keeps
    /// every model picker in the app rendering the order it rendered before descriptors existed.
    ///
    /// Elements are returned as given; only the NAME is trimmed for comparison. `[String]`'s
    /// wrapper below trims first so its result is trimmed, as it has always been.
    nonisolated func normalizedUnique(name: (Element) -> String) -> [Element] {
        var seen = Set<String>()
        return compactMap { element -> Element? in
            let trimmed = name(element).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return nil }
            seen.insert(trimmed)
            return element
        }.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }
}

extension Array where Element == String {
    /// Normalize string array: trim whitespace, remove empty/duplicate entries, sort case-insensitive.
    /// Preserves first-occurrence order before sorting.
    nonisolated func normalizedUnique() -> [String] {
        map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .normalizedUnique(name: { $0 })
    }
}
