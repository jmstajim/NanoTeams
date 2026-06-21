import XCTest

@testable import NanoTeams

/// Corner / boundary coverage for the pure ranking enum extracted from
/// `VocabVectorIndexService.expand`. No actor, no network, no async — every
/// scoring decision is exercised directly against a hand-built
/// `VocabVectorIndex`. Behavioural parity with the actor path is still pinned
/// by `VocabVectorIndexServiceTests`; this file isolates the math so the
/// boundaries (threshold extremes, dim mismatch on both sides, OOV tokens,
/// empty index, dedup across tiers) are testable without I/O.
final class VocabExpansionScorerTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a loaded index from `token -> raw vector`. Each vector is
    /// unit-normalized (the index stores normalized rows). `tokenMap` is a
    /// compact bijection by construction (sorted enumeration).
    private func makeIndex(_ vectorsByToken: [String: [Float]], dims: Int) throws -> VocabVectorIndex {
        let tokens = vectorsByToken.keys.sorted()
        var tokenMap: [String: Int] = [:]
        var flat: [Float] = []
        for (i, token) in tokens.enumerated() {
            tokenMap[token] = i
            flat.append(contentsOf: VectorMath.normalize(vectorsByToken[token]!))
        }
        let meta = try VocabVectorIndex.Meta(
            generatedAt: Date(),
            modelName: "test-model",
            dims: dims,
            indexSignature: IndexSignature(fileCount: 1, maxMTime: Date(), totalSize: 1),
            tokenMap: tokenMap
        )
        return try VocabVectorIndex(meta: meta, vectors: flat)
    }

    /// "user" exact axis; "account" close (cos ≈ 0.95); "widget" orthogonal (cos 0).
    private func standardIndex() throws -> VocabVectorIndex {
        try makeIndex([
            "user": [1, 0, 0],
            "account": [0.95, 0.31, 0],
            "widget": [0, 0, 1],
        ], dims: 3)
    }

    // MARK: - excludedTokens

    func testExcludedTokens_lowercasesPOSIX() {
        XCTAssertEqual(
            VocabExpansionScorer.excludedTokens(["User", "ACCOUNT"]),
            ["user", "account"]
        )
    }

    func testExcludedTokens_empty_returnsEmpty() {
        XCTAssertTrue(VocabExpansionScorer.excludedTokens([]).isEmpty)
    }

    func testExcludedTokens_dedupesCaseVariants() {
        let set = VocabExpansionScorer.excludedTokens(["user", "USER", "User"])
        XCTAssertEqual(set, ["user"])
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - tier1PerToken

    func testTier1_presentToken_returnsNeighborsAboveThreshold() throws {
        let index = try standardIndex()
        let hits = VocabExpansionScorer.tier1PerToken(
            index: index, tokens: ["user"], excluding: ["user"], threshold: 0.5
        )
        XCTAssertTrue(hits.contains("account"))
        XCTAssertFalse(hits.contains("widget"), "Orthogonal token must fall out at 0.5")
        XCTAssertFalse(hits.contains("user"), "Self must be excluded")
    }

    func testTier1_absentToken_contributesNothing() throws {
        let index = try standardIndex()
        let hits = VocabExpansionScorer.tier1PerToken(
            index: index, tokens: ["zzz_oov"], excluding: [], threshold: 0.0
        )
        XCTAssertTrue(hits.isEmpty, "Out-of-vocab token has no precomputed vector")
    }

    func testTier1_allTokensAbsent_returnsEmpty() throws {
        let index = try standardIndex()
        let hits = VocabExpansionScorer.tier1PerToken(
            index: index, tokens: ["aaa", "bbb", "ccc"], excluding: [], threshold: 0.0
        )
        XCTAssertTrue(hits.isEmpty, "All-OOV query must not crash and must return empty")
    }

    func testTier1_excludingRemovesSelf_keepsOthers() throws {
        let index = try standardIndex()
        // threshold 0.0 → everything matches; only the excluded self drops out.
        let hits = VocabExpansionScorer.tier1PerToken(
            index: index, tokens: ["user"], excluding: ["user"], threshold: 0.0
        )
        XCTAssertEqual(hits, ["account", "widget"])
        XCTAssertFalse(hits.contains("user"))
    }

    /// Boundary: threshold exactly 1.0 keeps only score-≥-1.0 matches.
    /// A token whose vector is identical to the query's stays in (cos = 1.0);
    /// the query token itself is excluded.
    func testTier1_thresholdOne_keepsOnlyExactDuplicates() throws {
        let index = try makeIndex([
            "user": [1, 0, 0],
            "login": [1, 0, 0],          // identical vector → cos 1.0
            "account": [0.95, 0.31, 0],  // cos ≈ 0.95 < 1.0
        ], dims: 3)
        let hits = VocabExpansionScorer.tier1PerToken(
            index: index, tokens: ["user"], excluding: ["user"], threshold: 1.0
        )
        XCTAssertEqual(hits, ["login"], "Only the exact-duplicate vector clears threshold 1.0")
    }

    /// Boundary: threshold exactly 0.0 admits orthogonal tokens because the
    /// comparison is `score >= threshold` and an orthogonal cosine is 0.0.
    func testTier1_thresholdZero_admitsOrthogonalToken() throws {
        let index = try standardIndex()
        let hits = VocabExpansionScorer.tier1PerToken(
            index: index, tokens: ["user"], excluding: ["user"], threshold: 0.0
        )
        XCTAssertTrue(hits.contains("widget"), "0.0 >= 0.0 admits the orthogonal token")
    }

    func testTier1_thresholdMonotonic_stricterIsSubset() throws {
        let index = try standardIndex()
        let lax = VocabExpansionScorer.tier1PerToken(
            index: index, tokens: ["user"], excluding: ["user"], threshold: 0.1
        )
        let strict = VocabExpansionScorer.tier1PerToken(
            index: index, tokens: ["user"], excluding: ["user"], threshold: 0.99
        )
        XCTAssertTrue(strict.isSubset(of: lax), "Raising the threshold can only shrink the set")
    }

    // MARK: - needsPhraseEmbedding

    func testNeedsPhrase_singleInVocabToken_false() throws {
        let index = try standardIndex()
        XCTAssertFalse(VocabExpansionScorer.needsPhraseEmbedding(index: index, tokens: ["user"]))
    }

    func testNeedsPhrase_singleOOVToken_true() throws {
        let index = try standardIndex()
        XCTAssertTrue(VocabExpansionScorer.needsPhraseEmbedding(index: index, tokens: ["zzz_oov"]))
    }

    func testNeedsPhrase_multiTokenAllInVocab_true() throws {
        let index = try standardIndex()
        XCTAssertTrue(VocabExpansionScorer.needsPhraseEmbedding(
            index: index, tokens: ["user", "account"]
        ))
    }

    /// Documented (guarded-upstream) edge: empty token list yields true here.
    func testNeedsPhrase_emptyTokens_true() throws {
        let index = try standardIndex()
        XCTAssertTrue(VocabExpansionScorer.needsPhraseEmbedding(index: index, tokens: []))
    }

    // MARK: - tier2FromPhraseVector

    func testTier2_dimMismatchTooFew_returnsDimMismatch() throws {
        let index = try standardIndex()  // dims 3
        let outcome = VocabExpansionScorer.tier2FromPhraseVector(
            rawVector: [1, 0], index: index, excluding: [], threshold: 0.5
        )
        XCTAssertEqual(outcome, .dimMismatch)
    }

    func testTier2_dimMismatchTooMany_returnsDimMismatch() throws {
        let index = try standardIndex()  // dims 3
        let outcome = VocabExpansionScorer.tier2FromPhraseVector(
            rawVector: [1, 0, 0, 0], index: index, excluding: [], threshold: 0.5
        )
        XCTAssertEqual(outcome, .dimMismatch)
    }

    /// Tier 2 must normalize the raw embedding before ranking — a non-unit
    /// vector pointing at "user" still matches at a high threshold.
    func testTier2_normalizesRawVector_beforeRanking() throws {
        let index = try standardIndex()
        let outcome = VocabExpansionScorer.tier2FromPhraseVector(
            rawVector: [2, 0, 0], index: index, excluding: [], threshold: 0.9
        )
        guard case .hits(let hits) = outcome else { return XCTFail("Expected .hits, got \(outcome)") }
        XCTAssertTrue(hits.contains("user"), "Normalized [2,0,0] == [1,0,0] → cos 1.0 with user")
        XCTAssertTrue(hits.contains("account"), "account cos ≈ 0.95 clears 0.9")
        XCTAssertFalse(hits.contains("widget"))
    }

    func testTier2_excludingApplied() throws {
        let index = try standardIndex()
        let outcome = VocabExpansionScorer.tier2FromPhraseVector(
            rawVector: [2, 0, 0], index: index, excluding: ["user"], threshold: 0.9
        )
        guard case .hits(let hits) = outcome else { return XCTFail("Expected .hits, got \(outcome)") }
        XCTAssertFalse(hits.contains("user"), "Excluded token must not appear even at cos 1.0")
        XCTAssertTrue(hits.contains("account"))
    }

    /// Degenerate: a non-empty-dims but token-less index produces `.hits([])`,
    /// not a crash or a dim mismatch (matching dims → ranking → no candidates).
    func testTier2_emptyIndex_returnsEmptyHits() throws {
        let index = try makeIndex([:], dims: 3)
        let outcome = VocabExpansionScorer.tier2FromPhraseVector(
            rawVector: [1, 0, 0], index: index, excluding: [], threshold: 0.0
        )
        XCTAssertEqual(outcome, .hits([]))
    }

    // MARK: - finalize

    func testFinalize_sortsAscending() {
        XCTAssertEqual(
            VocabExpansionScorer.finalize(["zebra", "apple", "mango"]),
            ["apple", "mango", "zebra"]
        )
    }

    func testFinalize_empty_returnsEmpty() {
        XCTAssertEqual(VocabExpansionScorer.finalize([]), [])
    }

    func testFinalize_singleton() {
        XCTAssertEqual(VocabExpansionScorer.finalize(["only"]), ["only"])
    }

    // MARK: - Cross-tier property: subset of vocab, no query tokens, dedup

    func testCombinedTiers_subsetOfVocab_excludeQuery_dedupAcrossTiers() throws {
        let index = try standardIndex()
        let excluding = VocabExpansionScorer.excludedTokens(["User"])  // → {"user"}

        var related = VocabExpansionScorer.tier1PerToken(
            index: index, tokens: ["user"], excluding: excluding, threshold: 0.5
        )
        let outcome = VocabExpansionScorer.tier2FromPhraseVector(
            rawVector: [2, 0, 0], index: index, excluding: excluding, threshold: 0.5
        )
        guard case .hits(let phraseHits) = outcome else { return XCTFail("Expected .hits") }
        related.formUnion(phraseHits)

        let terms = VocabExpansionScorer.finalize(related)
        let vocab = Set(index.meta.tokenMap.keys)

        XCTAssertTrue(Set(terms).isSubset(of: vocab), "Every term must be a real vocab token")
        XCTAssertFalse(terms.contains("user"), "Query token must never expand to itself")
        // "account" is surfaced by BOTH tiers; it must appear exactly once.
        XCTAssertEqual(terms.filter { $0 == "account" }.count, 1, "Dedup across tiers")
        XCTAssertEqual(terms, Array(Set(terms)).sorted(), "Output is a deduped, sorted set")
    }
}
