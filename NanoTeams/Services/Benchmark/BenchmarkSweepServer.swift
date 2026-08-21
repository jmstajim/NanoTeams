import Foundation

/// One provider's server as the sweep screen sees it: where it was looked for, what it answered,
/// and whether the user wants it touched.
///
/// There is exactly one row per `LLMProvider`, always — including a provider the app has never
/// been pointed at. That is what makes "every provider that is running" answerable at all: a
/// provider absent from the list could never be found, and a row that says *no answer* at a named
/// address is a far better answer than silence.
nonisolated struct BenchmarkSweepServer: Identifiable, Equatable, Sendable {

    /// One row per provider, so the id is the provider. The endpoint is editable and must not be
    /// part of the identity — retyping an address would otherwise destroy and recreate the row
    /// mid-edit, taking its scan result with it.
    var id: String { provider.rawValue }

    var provider: LLMProvider
    /// Where to look. Seeded from what the app knows and from the provider's documented default,
    /// and editable on screen — which is the whole licence for using a default here at all: a
    /// proposal the user can read and change before anything is sent to it is not a guess made
    /// behind their back.
    var baseURLString: String
    /// Whether this provider takes part. Untoggling means it literally, on both counts: none of
    /// its models are measured, AND nothing on it is unloaded.
    var isIncluded: Bool = true
    /// The address is the provider's documented default rather than anything the user has told the
    /// app — so the row says so.
    ///
    /// Surfaced rather than hidden because it is the difference between a fact and a proposal, and
    /// this screen is the one place a proposal is allowed to turn into a server the app sends
    /// unload commands to. A reader who cannot tell which of their two rows they configured cannot
    /// audit that.
    var isProposedAddress: Bool = false
    /// What the last scan got back. `nil` = never scanned.
    var outcome: BenchmarkDiscoveryOutcome?

    var server: BenchmarkServer {
        BenchmarkServer(provider: provider, baseURLString: baseURLString)
    }

    /// Models this server offered, empty when it has not been scanned or did not answer.
    var models: [String] {
        if case .answered(let models) = outcome { return models }
        return []
    }

    /// The server ANSWERED a read this session, so the app may write to it — the one condition
    /// under which an unload command is allowed to leave the process.
    ///
    /// Deliberately true for a server that answered with an EMPTY list. That is not a degenerate
    /// case: `fetchModels` filters out embedding-only models on both providers, so a server whose
    /// only resident model is an embedder answers `[]` while holding real memory. Deriving this
    /// from "has at least one model to measure" would silently exempt exactly the server most
    /// likely to be poisoning the numbers.
    var isVerified: Bool {
        if case .answered = outcome { return isIncluded }
        return false
    }
}

