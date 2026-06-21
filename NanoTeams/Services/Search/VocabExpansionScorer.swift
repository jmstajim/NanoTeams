import Foundation

/// Pure query-time ranking math for `VocabVectorIndexService.expand(...)`.
///
/// Extracted from the actor so the three reasons-to-change stay separate:
/// the actor owns disk persistence + embedding-transport orchestration +
/// state-machine mutation; this enum owns ONLY the ranking computation over a
/// loaded `VocabVectorIndex`. No file I/O, no network, no `state`. That makes
/// every scoring decision unit-testable without spinning an actor or mocking
/// the embedding client (mirrors the pure-policy pattern of `LoopRecoveryPolicy`,
/// `DesignatedCoordinatorResolver`, `MessageKeyPolicy`, `VectorMath`).
///
/// The two tiers map 1:1 onto the original inline logic:
/// - Tier 1 (`tier1PerToken`) ranks each query token's precomputed vector
///   against the vocab — zero network.
/// - Tier 2 (`tier2FromPhraseVector`) ranks the whole-phrase embedding (fetched
///   by the actor) against the vocab; a dim mismatch is returned as a *value*
///   (`.dimMismatch`) so the actor can map it to `.transientError` rather than
///   the scorer making that call.
nonisolated enum VocabExpansionScorer {

    /// k for the per-token tier. Matches the original inline constant — small
    /// because per-token neighbourhoods are tight.
    static let perTokenK = 10
    /// k for the whole-phrase tier. Wider net than per-token: the phrase vector
    /// is a softer query so we keep more candidates above threshold.
    static let phraseK = 20

    /// Outcome of Tier-2 phrase-vector ranking. Mutually exclusive by
    /// construction. `.dimMismatch` means the live phrase vector's dimension
    /// differs from the persisted index (e.g. the embedding model was swapped
    /// mid-session) — the actor surfaces that as a distinct canonical error
    /// instead of an empty success, because the partial Tier-1 terms are still
    /// valid but the phrase tier could not run.
    enum PhraseOutcome: Equatable, Sendable {
        case dimMismatch
        case hits(Set<String>)
    }

    /// Lowercased set of the original query tokens, to be excluded from their
    /// own expansion (a query token shouldn't dominate its own neighbour list).
    /// POSIX-locale lowercasing matches the casing stored in `tokenMap`.
    static func excludedTokens(_ tokens: [String]) -> Set<String> {
        Set(tokens.map { $0.lowercased(with: Locale(identifier: "en_US_POSIX")) })
    }

    /// Tier 1 — per-token nearest-neighbour expansion over the precomputed
    /// vectors. Tokens absent from the index contribute nothing (no crash, no
    /// network). `excluding` removes self-matches.
    static func tier1PerToken(
        index: VocabVectorIndex,
        tokens: [String],
        excluding: Set<String>,
        threshold: Float
    ) -> Set<String> {
        var related = Set<String>()
        for token in tokens {
            if let vec = index.vector(for: token) {
                let hits = index.nearestTokens(
                    to: vec, k: perTokenK, threshold: threshold, excluding: excluding
                )
                related.formUnion(hits.map(\.token))
            }
        }
        return related
    }

    /// Whether the whole-phrase embedding tier should fire. Skip it only when
    /// the query is a single token that is itself in the vocab — the per-token
    /// tier already covered it, so an embedding call would be wasted. Fire it
    /// for multi-token queries and for a single out-of-vocab token.
    ///
    /// Note: an empty `tokens` array yields `true` here (`first` is nil →
    /// `flatMap` nil → `== nil`), but `expand` guards `tokens.isEmpty` upstream,
    /// so this enum is never asked to embed an empty phrase in production.
    static func needsPhraseEmbedding(index: VocabVectorIndex, tokens: [String]) -> Bool {
        tokens.count > 1 || tokens.first.flatMap { index.vector(for: $0) } == nil
    }

    /// Tier 2 — rank the vocab against a raw (un-normalized) whole-phrase
    /// vector. Normalizes before ranking (cosine needs unit vectors). A
    /// dimension mismatch is reported as `.dimMismatch` rather than silently
    /// empty hits, because that distinction drives the actor's error envelope.
    static func tier2FromPhraseVector(
        rawVector: [Float],
        index: VocabVectorIndex,
        excluding: Set<String>,
        threshold: Float
    ) -> PhraseOutcome {
        guard rawVector.count == index.meta.dims else {
            return .dimMismatch
        }
        let normalized = VectorMath.normalize(rawVector)
        let hits = index.nearestTokens(
            to: normalized, k: phraseK, threshold: threshold, excluding: excluding
        )
        return .hits(Set(hits.map(\.token)))
    }

    /// Canonical "expanded terms" contract: deduplicated (Set guarantees) and
    /// sorted ascending so the envelope and tests see a stable order.
    static func finalize(_ related: Set<String>) -> [String] {
        Array(related).sorted()
    }
}
