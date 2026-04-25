import Foundation
@testable import NanoTeams

/// Drives the embedding-based `expand` pipeline over a corpus of inline
/// fixtures and writes a result JSON for offline auditing.
///
/// Pipeline per case:
/// 1. Materialize inline fixture or point at a real work folder.
/// 2. Build / load the token index (`SearchIndexService`).
/// 3. Build the vector index (`VocabVectorIndexService.rebuildIfNeeded`).
/// 4. Expand the query (`VocabVectorIndexService.expand`).
/// 5. Measure recall against `expectedExpansionTerms` / `expectedHitFiles`.
///
/// Mirrors `CreateTeamTrainer` in shape so the mental model carries over.
final class ExpandedSearchTrainer {

    /// Expansion seam. Default hits a live LM Studio embedding endpoint;
    /// unit tests can inject a deterministic stub.
    typealias Expander = @Sendable (String, [String], EmbeddingConfig) async -> VocabVectorIndexService.ExpansionResult

    private let config: ExpandedSearchTrainerConfig
    private let expanderFactory: (@Sendable () -> Expander)?
    private let fileManager: FileManager

    init(
        config: ExpandedSearchTrainerConfig,
        fileManager: FileManager = .default,
        expanderFactory: (@Sendable () -> Expander)? = nil
    ) {
        self.config = config
        self.fileManager = fileManager
        self.expanderFactory = expanderFactory
    }

    // MARK: - Top-level run

    func run() async throws -> ExpandedSearchTrainerRunResult {
        let corpus = try loadCorpus()
        print("[TRAINER] Loaded \(corpus.cases.count) case(s) from \(config.corpusPath)")

        let embeddingConfig = config.toEmbeddingConfig()
        let timeout = config.resolvedTimeout

        var caseResults: [ExpandedSearchTrainerCaseResult] = []
        let runStart = MonotonicClock.shared.now()

        for (index, kase) in corpus.cases.enumerated() {
            print("[TRAINER] [\(index + 1)/\(corpus.cases.count)] \(kase.tag): \(kase.query.prefix(80))…")
            let result = await runOneCase(
                kase: kase, embeddingConfig: embeddingConfig, timeout: timeout
            )
            caseResults.append(result)
            printCaseSummary(result)
        }

        let runResult = ExpandedSearchTrainerRunResult(
            startedAt: runStart,
            durationSeconds: Date().timeIntervalSince(runStart),
            model: config.resolvedModel,
            baseURL: config.resolvedBaseURL,
            cases: caseResults
        )

        try writeOutput(runResult)
        return runResult
    }

    // MARK: - Per-case

    private func runOneCase(
        kase: ExpandedSearchTrainerCase,
        embeddingConfig: EmbeddingConfig,
        timeout: TimeInterval
    ) async -> ExpandedSearchTrainerCaseResult {
        let start = Date()

        // 1. Resolve work folder.
        let workFolderRoot: URL
        let internalDir: URL
        let cleanup: (@Sendable () -> Void)?

        if let realRoot = config.workFolderRoot {
            workFolderRoot = URL(fileURLWithPath: realRoot)
            internalDir = workFolderRoot
                .appendingPathComponent(".nanoteams/internal", isDirectory: true)
            cleanup = nil
        } else {
            let tempRoot = fileManager.temporaryDirectory
                .appendingPathComponent("expanded_search_trainer_\(UUID().uuidString)",
                                        isDirectory: true)
            let tempInternalDir = tempRoot
                .appendingPathComponent(".nanoteams/internal", isDirectory: true)
            do {
                try fileManager.createDirectory(
                    at: tempInternalDir, withIntermediateDirectories: true
                )
                for (relPath, content) in kase.files ?? [:] {
                    let url = tempRoot.appendingPathComponent(relPath)
                    try fileManager.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try content.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                return makeFailure(
                    kase: kase,
                    phase: "fixture_write",
                    message: error.localizedDescription,
                    elapsed: Date().timeIntervalSince(start)
                )
            }
            workFolderRoot = tempRoot
            internalDir = tempInternalDir
            let fm = fileManager
            cleanup = { try? fm.removeItem(at: tempRoot) }
        }
        defer { cleanup?() }

        // 2. Build (or load cached) token index.
        let service = SearchIndexService(
            workFolderRoot: workFolderRoot,
            internalDir: internalDir,
            fileManager: fileManager
        )
        let index = await service.loadOrBuild()

        // 3. Build the vector index.
        let vectorStart = Date()
        let vectorService = VocabVectorIndexService(
            internalDir: internalDir,
            client: LMStudioEmbeddingClient(),
            fileManager: fileManager
        )
        // Hydrate `cached` from any existing on-disk bin BEFORE rebuild —
        // otherwise smart-diff degrades to full re-embed for `workFolderRoot`
        // mode (the persisted index from the live app is ignored). For
        // synthetic-fixture mode this is a cheap no-op (no bin on disk).
        await vectorService.load()
        await vectorService.rebuildIfNeeded(
            searchIndex: index, config: embeddingConfig, force: false
        )
        let vectorBuildDuration = Date().timeIntervalSince(vectorStart)

        // 4. Expand the query (per-token + whole-phrase). Uses the injected
        //    expander in tests; default path goes through the live service.
        let queryTokens = TokenExtractor.extractTokens(from: kase.query)
        let expander = expanderFactory?() ?? { query, tokens, cfg in
            await vectorService.expand(
                query: query, tokens: tokens, config: cfg,
                perTokenThreshold: self.config.resolvedPerTokenThreshold,
                phraseThreshold: self.config.resolvedPhraseThreshold
            )
        }

        let expansionOutcome = await withTimeout(seconds: timeout) {
            let expansion = await expander(kase.query, Array(queryTokens), embeddingConfig)
            if let err = expansion.errorReason {
                return ExpansionOutcome.failure(
                    type: "EmbeddingError",
                    message: err
                )
            }
            if let reason = expansion.unavailableReason {
                return ExpansionOutcome.failure(
                    type: "Unavailable",
                    message: reason
                )
            }
            return ExpansionOutcome.success(terms: expansion.terms)
        } ?? .timeout

        // 5. Recall metrics.
        let expandedTerms: [String]
        switch expansionOutcome {
        case .success(let terms): expandedTerms = terms
        default: expandedTerms = []
        }
        // Mirror production: posting union over query tokens + literal
        // query string + expansion terms. Without query tokens, multi-word
        // queries can't surface their own files (the literal phrase is
        // never a posting key).
        let combinedTerms = Array(queryTokens) + [kase.query] + expandedTerms
        let hitFiles = await service.files(containing: combinedTerms)

        let expansionRecall = Self.recall(
            expected: kase.expectedExpansionTerms,
            actual: expandedTerms
        )
        let hitFilesRecall = Self.recall(
            expected: kase.expectedHitFiles,
            actual: hitFiles
        )
        let vocabularyRecall = Self.recall(
            expected: kase.expectedVocabulary,
            actual: index.tokens
        )

        return ExpandedSearchTrainerCaseResult(
            tag: kase.tag,
            query: kase.query,
            language: kase.language,
            elapsedSeconds: Date().timeIntervalSince(start),
            index: ExpandedSearchTrainerIndexSummary(
                fileCount: index.files.count,
                tokenCount: index.tokens.count,
                vocabularyRecall: vocabularyRecall
            ),
            vectorBuild: ExpandedSearchTrainerVectorBuildSummary(
                durationSeconds: vectorBuildDuration,
                vectorCount: await Self.vectorCount(vectorService),
                failedTokenCount: await Self.failedCount(vectorService)
            ),
            expansion: ExpandedSearchTrainerExpansionSummary(
                outcome: expansionOutcome,
                terms: expandedTerms,
                expectedTerms: kase.expectedExpansionTerms,
                recall: expansionRecall,
                expectsFailure: kase.expectsExpansionFailure ?? false
            ),
            posting: ExpandedSearchTrainerPostingSummary(
                combinedTerms: combinedTerms,
                hitFiles: hitFiles,
                expectedHitFiles: kase.expectedHitFiles,
                hitRecall: hitFilesRecall
            )
        )
    }

    private static func vectorCount(_ service: VocabVectorIndexService) async -> Int {
        let state = await service.state
        if case .ready(_, _, let count) = state { return count }
        return 0
    }

    private static func failedCount(_ service: VocabVectorIndexService) async -> Int {
        let state = await service.state
        if case .ready(_, let failed, _) = state { return failed }
        return 0
    }

    private func makeFailure(
        kase: ExpandedSearchTrainerCase,
        phase: String,
        message: String,
        elapsed: TimeInterval
    ) -> ExpandedSearchTrainerCaseResult {
        ExpandedSearchTrainerCaseResult(
            tag: kase.tag,
            query: kase.query,
            language: kase.language,
            elapsedSeconds: elapsed,
            index: ExpandedSearchTrainerIndexSummary(
                fileCount: 0, tokenCount: 0, vocabularyRecall: nil
            ),
            vectorBuild: ExpandedSearchTrainerVectorBuildSummary(
                durationSeconds: 0, vectorCount: 0, failedTokenCount: 0
            ),
            expansion: ExpandedSearchTrainerExpansionSummary(
                outcome: .failure(type: phase, message: message),
                terms: [],
                expectedTerms: kase.expectedExpansionTerms,
                recall: nil,
                expectsFailure: kase.expectsExpansionFailure ?? false
            ),
            posting: ExpandedSearchTrainerPostingSummary(
                combinedTerms: [kase.query],
                hitFiles: [],
                expectedHitFiles: kase.expectedHitFiles,
                hitRecall: nil
            )
        )
    }

    // MARK: - Helpers

    /// Recall = |expected ∩ actual| / |expected| (case-insensitive compare
    /// after lowercasing). Returns `nil` when `expected` is nil or empty —
    /// the auditor treats that as "no expectation, skip scoring".
    static func recall<S: Sequence>(expected: [String]?, actual: S) -> Double?
    where S.Element == String {
        guard let expected, !expected.isEmpty else { return nil }
        let actualSet: Set<String> = Set(
            actual.map { $0.lowercased(with: Locale(identifier: "en_US_POSIX")) }
        )
        let hits = expected.reduce(0) { acc, term in
            let lowered = term.lowercased(with: Locale(identifier: "en_US_POSIX"))
            return acc + (actualSet.contains(lowered) ? 1 : 0)
        }
        return Double(hits) / Double(expected.count)
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func loadCorpus() throws -> ExpandedSearchTrainerCorpus {
        let url = URL(fileURLWithPath: config.corpusPath)
        let data = try Data(contentsOf: url)
        return try JSONCoderFactory.makeWireDecoder()
            .decode(ExpandedSearchTrainerCorpus.self, from: data)
    }

    private func writeOutput(_ result: ExpandedSearchTrainerRunResult) throws {
        let url = URL(fileURLWithPath: config.outputPath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONCoderFactory.makeExportEncoder().encode(result)
        try data.write(to: url)
        print("[TRAINER] Results → \(url.path)")
    }

    private func printCaseSummary(_ r: ExpandedSearchTrainerCaseResult) {
        let hits = r.posting.hitFiles.count
        let terms = r.expansion.terms.count
        let recallStr: String = {
            if let r = r.expansion.recall {
                return String(format: "recall=%.0f%%", r * 100)
            }
            return "recall=n/a"
        }()
        switch r.expansion.outcome {
        case .success:
            print("[TRAINER]   ✓ OK   expanded=\(terms) hit_files=\(hits) \(recallStr) vec_count=\(r.vectorBuild.vectorCount) vec_build=\(String(format: "%.1f", r.vectorBuild.durationSeconds))s elapsed=\(Int(r.elapsedSeconds))s")
        case .failure(let type, let message):
            let expectedMark = r.expansion.expectsFailure ? " (expected)" : ""
            print("[TRAINER]   ✗ FAIL\(expectedMark) \(type): \(message.prefix(120))")
        case .timeout:
            print("[TRAINER]   ✗ TIMEOUT after \(Int(r.elapsedSeconds))s")
        }
    }
}

// MARK: - Outcome (sum type — illegal combinations unrepresentable)

enum ExpansionOutcome: Codable {
    case success(terms: [String])
    case failure(type: String, message: String)
    case timeout

    enum CodingKeys: String, CodingKey {
        case status, terms, errorType, errorMessage
    }

    enum Status: String, Codable {
        case success, failure, timeout
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let terms):
            try c.encode(Status.success, forKey: .status)
            try c.encode(terms, forKey: .terms)
        case .failure(let type, let message):
            try c.encode(Status.failure, forKey: .status)
            try c.encode(type, forKey: .errorType)
            try c.encode(message, forKey: .errorMessage)
        case .timeout:
            try c.encode(Status.timeout, forKey: .status)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decode(Status.self, forKey: .status)
        switch status {
        case .success:
            let terms = try c.decode([String].self, forKey: .terms)
            self = .success(terms: terms)
        case .failure:
            let type = try c.decode(String.self, forKey: .errorType)
            let message = try c.decode(String.self, forKey: .errorMessage)
            self = .failure(type: type, message: message)
        case .timeout:
            self = .timeout
        }
    }
}

// MARK: - Result Models

struct ExpandedSearchTrainerRunResult: Codable {
    var startedAt: Date
    var durationSeconds: Double
    var model: String
    var baseURL: String
    var cases: [ExpandedSearchTrainerCaseResult]
}

struct ExpandedSearchTrainerCaseResult: Codable {
    var tag: String
    var query: String
    var language: String?
    var elapsedSeconds: Double
    var index: ExpandedSearchTrainerIndexSummary
    var vectorBuild: ExpandedSearchTrainerVectorBuildSummary
    var expansion: ExpandedSearchTrainerExpansionSummary
    var posting: ExpandedSearchTrainerPostingSummary
}

struct ExpandedSearchTrainerIndexSummary: Codable {
    var fileCount: Int
    var tokenCount: Int
    var vocabularyRecall: Double?
}

/// Stats from the vector-index build phase. Separate from token-index stats
/// so the output JSON makes it obvious which phase spent how much time.
struct ExpandedSearchTrainerVectorBuildSummary: Codable {
    var durationSeconds: Double
    var vectorCount: Int
    var failedTokenCount: Int
}

struct ExpandedSearchTrainerExpansionSummary: Codable {
    var outcome: ExpansionOutcome
    var terms: [String]
    var expectedTerms: [String]?
    var recall: Double?
    var expectsFailure: Bool
}

struct ExpandedSearchTrainerPostingSummary: Codable {
    var combinedTerms: [String]
    var hitFiles: [String]
    var expectedHitFiles: [String]?
    var hitRecall: Double?
}
