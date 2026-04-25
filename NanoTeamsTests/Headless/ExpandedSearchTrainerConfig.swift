import Foundation
@testable import NanoTeams

/// Configuration for the expanded-search trainer. Loaded from a JSON file at
/// `.nanoteams/expanded_search_trainer.json` by `ExpandedSearchTrainerTests`.
///
/// Shape mirrors `CreateTeamTrainerConfig` so operators have one mental
/// model for all trainers.
struct ExpandedSearchTrainerConfig: Codable {
    // MARK: - Embedding endpoint

    /// OpenAI-compatible embedding endpoint. Default: LM Studio on 127.0.0.1:1234.
    var baseURL: String?

    /// Embedding model id. Default: `text-embedding-nomic-embed-text-v1.5`.
    var model: String?

    /// Texts per outbound /v1/embeddings call. Default from `EmbeddingConfig`.
    var batchSize: Int?

    /// Per-call HTTP timeout in seconds. Default from `EmbeddingConfig`.
    var requestTimeoutSeconds: Int?

    // MARK: - Corpus & Output

    /// Absolute path to the corpus JSON file.
    var corpusPath: String

    /// Absolute path where the trainer writes `expanded_search_results.json`.
    var outputPath: String

    /// Per-case budget (indexing + embedding + expansion + hit check). Default 60s.
    var caseTimeoutSeconds: Int?

    /// Absolute path to a REAL work folder whose existing
    /// `.nanoteams/internal/search_index.json` the trainer should reuse for
    /// every case. When set, the trainer skips inline fixture materialization
    /// entirely — `ExpandedSearchTrainerCase.files` is ignored, and the index is
    /// loaded via `SearchIndexService.loadOrBuild(force: false)` so a rebuilt
    /// index on disk is picked up without re-indexing.
    ///
    /// Leave `nil` to use the default fixture-per-case flow.
    var workFolderRoot: String?

    // MARK: - Thresholds

    /// Per-token cosine threshold. Default 0.75.
    var perTokenThreshold: Double?

    /// Whole-phrase cosine threshold. Default 0.70.
    var phraseThreshold: Double?

    // MARK: - Resolved Helpers

    var resolvedBaseURL: String { baseURL ?? EmbeddingConfig.defaultNomicLMStudio.baseURLString }
    var resolvedModel: String { model ?? EmbeddingConfig.defaultNomicLMStudio.modelName }
    var resolvedTimeout: TimeInterval { TimeInterval(caseTimeoutSeconds ?? 60) }
    var resolvedPerTokenThreshold: Float { Float(perTokenThreshold ?? 0.75) }
    var resolvedPhraseThreshold: Float { Float(phraseThreshold ?? 0.70) }

    func toEmbeddingConfig() -> EmbeddingConfig {
        EmbeddingConfig(
            baseURLString: resolvedBaseURL,
            modelName: resolvedModel,
            batchSize: batchSize ?? EmbeddingConfig.defaultNomicLMStudio.batchSize,
            requestTimeout: TimeInterval(requestTimeoutSeconds ?? Int(EmbeddingConfig.defaultNomicLMStudio.requestTimeout))
        )
    }
}

/// One entry in the corpus JSON. Each case describes an inline fixture
/// (files to write into a temp folder) plus the query we're expanding +
/// what we hope to see in the result.
struct ExpandedSearchTrainerCase: Codable {
    /// Short tag for the case (e.g. `"ru-scroll"`).
    var tag: String

    /// The user's search query — fed to `VocabVectorIndexService.expand`.
    var query: String

    /// Language classification for audit purposes. Free-form; typical values:
    /// `"en"`, `"ru"`, `"mixed"`.
    var language: String?

    /// Inline fixture — map of `relativePath -> content`. Written verbatim
    /// into the trainer's temp folder before indexing. Optional because
    /// real-workspace runs (`config.workFolderRoot` set) skip fixture
    /// materialization entirely.
    var files: [String: String]?

    /// Tokens that SHOULD appear in the work folder's vocabulary after
    /// indexing (smoke check — exercises the tokenizer too).
    var expectedVocabulary: [String]?

    /// Tokens the expansion ideally surfaces. Auditor uses this to compute a
    /// recall score against `expansion.terms`. Field name preserved across
    /// the LLM→embedding pivot — semantically "terms we expect in expansion
    /// output" regardless of the underlying mechanism (see CLAUDE.md).
    var expectedExpansionTerms: [String]?

    /// Relative paths the posting intersection of `[query] + expansion`
    /// should recall. Primary quality signal.
    var expectedHitFiles: [String]?

    /// When `true`, this case is expected to EMPTY out the expanded list
    /// (query is gibberish; embedding should return mostly-noise neighbors
    /// that are excluded by threshold). Adversarial / nonsense queries.
    var expectsExpansionFailure: Bool?
}

struct ExpandedSearchTrainerCorpus: Codable {
    var cases: [ExpandedSearchTrainerCase]
}
