import XCTest

@testable import NanoTeams

final class VocabVectorIndexServiceTests: XCTestCase {

    // MARK: - Mock embedding client

    /// Fake embedding client. Default behaviour: returns a 3-dim vector per
    /// input, encoding the batch offset and call index so tests can tell
    /// vectors apart. Override `scriptedResponses`/`errorsOnCall` to script
    /// specific scenarios.
    private final class MockEmbeddingClient: EmbeddingClient, @unchecked Sendable {
        private let lock = NSLock()
        var callCount = 0
        var capturedTexts: [[String]] = []
        var scriptedResponses: [[[Float]]] = []
        var errorsOnCall: [Int: Error] = [:]

        func embed(texts: [String], config: EmbeddingConfig) async throws -> [[Float]] {
            lock.lock()
            let idx = callCount
            callCount += 1
            capturedTexts.append(texts)
            let maybeError = errorsOnCall[idx]
            let maybeScripted = scriptedResponses.isEmpty ? nil : scriptedResponses.removeFirst()
            lock.unlock()

            if let err = maybeError { throw err }
            if let scripted = maybeScripted {
                XCTAssertEqual(scripted.count, texts.count,
                               "Scripted response count must match input count")
                return scripted
            }
            return texts.enumerated().map { (i, _) -> [Float] in
                let seed = Float(idx) + Float(i) * 0.01
                return [seed, 0, 0]
            }
        }
    }

    /// Variant that sleeps `perCallDelayNanos` between its enter-critical-
    /// section and its return. Used by the cancellation regression to give
    /// the outer `Task.cancel()` time to fire mid-build.
    private final class SlowMockEmbeddingClient: EmbeddingClient, @unchecked Sendable {
        private let lock = NSLock()
        var callCount = 0
        var perCallDelayNanos: UInt64 = 0

        func embed(texts: [String], config: EmbeddingConfig) async throws -> [[Float]] {
            lock.lock()
            callCount += 1
            let delay = perCallDelayNanos
            lock.unlock()

            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            try Task.checkCancellation()
            return texts.map { _ in [Float(callCount), 0, 0] }
        }
    }

    // MARK: - Fixtures

    private var tempRoot: URL!
    private var internalDir: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvi_tests_\(UUID().uuidString)", isDirectory: true)
        internalDir = tempRoot.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: internalDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        internalDir = nil
        super.tearDown()
    }

    private func makeConfig(batchSize: Int = 2) -> EmbeddingConfig {
        EmbeddingConfig(
            baseURLString: "http://127.0.0.1:1234",
            modelName: "test-model",
            batchSize: batchSize,
            requestTimeout: 10
        )
    }

    private func makeService(client: any EmbeddingClient) -> VocabVectorIndexService {
        VocabVectorIndexService(
            internalDir: internalDir,
            client: client,
            fileManager: .default
        )
    }

    /// Like `makeSearchIndex` but every token has `posting.count == 1`
    /// (token T appears only in file T-mod-fileCount). Used to exercise the
    /// empty-after-filter path on a corpus large enough to keep the
    /// `minPostingCount` filter active.
    private func makeSparseSearchIndex(tokens: [String], fileCount: Int) -> SearchIndex {
        var postings: [String: [Int]] = [:]
        for (i, token) in tokens.enumerated() {
            postings[token] = [i % fileCount]
        }
        let files = (0..<fileCount).map {
            IndexedFile(path: "f\($0).swift", mTime: Date(), size: 100)
        }
        // swiftlint:disable:next force_try
        return try! SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(
                fileCount: fileCount,
                maxMTime: Date(),
                totalSize: Int64(fileCount * 100)
            ),
            files: files,
            tokens: tokens.sorted(),
            postings: postings
        )
    }

    private func makeSearchIndex(tokens: [String], fileCount: Int = 10) -> SearchIndex {
        // Every token appears in 2 files so it survives `minPostingCount: 2`.
        // `fileCount` governs the "near-universal" filter — 10 files × 0.8
        // threshold gives 8 as the cap. 2 files per token → well under.
        var postings: [String: [Int]] = [:]
        for token in tokens {
            postings[token] = [0, 1]
        }
        let files = (0..<fileCount).map {
            IndexedFile(path: "f\($0).swift", mTime: Date(), size: 100)
        }
        // swiftlint:disable:next force_try
        return try! SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(
                fileCount: fileCount,
                maxMTime: Date(),
                totalSize: Int64(fileCount * 100)
            ),
            files: files,
            tokens: tokens.sorted(),
            postings: postings
        )
    }

    // MARK: - Rebuild — happy path

    func testFirstRebuild_embedsAllVocabTokens_persistsToDisk() async {
        let client = MockEmbeddingClient()
        let service = makeService(client: client)
        let cfg = makeConfig()

        let searchIndex = makeSearchIndex(tokens: ["user", "account", "delete"])
        await service.rebuildIfNeeded(searchIndex: searchIndex, config: cfg, force: false)

        let state = await service.state
        if case .ready(_, let failed, let vectorsCount) = state {
            XCTAssertEqual(vectorsCount, 3, "All 3 tokens should be embedded")
            XCTAssertEqual(failed, 0)
        } else {
            XCTFail("Expected .ready, got \(state)")
        }

        // Three tokens + batchSize 2 → 2 HTTP calls.
        XCTAssertEqual(client.callCount, 2)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: internalDir.appendingPathComponent("vocab_vectors.bin").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: internalDir.appendingPathComponent("vocab_vectors.meta.json").path
        ))
    }

    func testSmartDiff_sameSearchIndex_noNewEmbedCalls() async {
        let client = MockEmbeddingClient()
        let service = makeService(client: client)
        let cfg = makeConfig()
        let searchIndex = makeSearchIndex(tokens: ["user", "account"])

        await service.rebuildIfNeeded(searchIndex: searchIndex, config: cfg, force: false)
        XCTAssertEqual(client.callCount, 1)

        await service.rebuildIfNeeded(searchIndex: searchIndex, config: cfg, force: false)
        XCTAssertEqual(client.callCount, 1,
                       "Idempotent rebuild must not hit the network again")
    }

    func testSmartDiff_newTokensOnly_embedsOnlyDelta() async {
        let client = MockEmbeddingClient()
        let service = makeService(client: client)
        let cfg = makeConfig()

        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account"]),
            config: cfg, force: false
        )
        XCTAssertEqual(client.callCount, 1)

        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account", "delete"]),
            config: cfg, force: false
        )

        XCTAssertEqual(client.callCount, 2)
        let lastCall = client.capturedTexts.last ?? []
        XCTAssertEqual(lastCall.count, 1)
        XCTAssertTrue(lastCall[0].contains("delete"))
    }

    func testForceRebuild_reEmbedsAll() async {
        let client = MockEmbeddingClient()
        let service = makeService(client: client)
        let cfg = makeConfig()
        let searchIndex = makeSearchIndex(tokens: ["user", "account"])

        await service.rebuildIfNeeded(searchIndex: searchIndex, config: cfg, force: false)
        let firstBuildCalls = client.callCount

        await service.rebuildIfNeeded(searchIndex: searchIndex, config: cfg, force: true)

        XCTAssertGreaterThan(client.callCount, firstBuildCalls,
                             "force: true must re-embed existing tokens")
    }

    func testGoneTokens_droppedOnRebuild() async {
        let client = MockEmbeddingClient()
        let service = makeService(client: client)
        let cfg = makeConfig()

        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account", "delete"]),
            config: cfg, force: false
        )
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account"]),
            config: cfg, force: false
        )

        let state = await service.state
        guard case .ready(_, _, let vectorsCount) = state else {
            XCTFail("Expected .ready"); return
        }
        XCTAssertEqual(vectorsCount, 2, "Gone token 'delete' must be pruned")
    }

    // MARK: - Partial failure

    func testBatchFailure_addsToFailedTokens_continuesRemainingBatches() async {
        let client = MockEmbeddingClient()
        // Fail the very first batch (every retry). Later batches succeed
        // with defaults. With batchSize 2 and 4 tokens → 2 batches total.
        // Builder retries up to 2 times = 3 attempts on batch 0 (calls 0,1,2).
        // Then batch 1 (call 3) succeeds.
        client.errorsOnCall = [
            0: EmbeddingClientError.httpError(status: 500, message: "oom"),
            1: EmbeddingClientError.httpError(status: 500, message: "oom"),
            2: EmbeddingClientError.httpError(status: 500, message: "oom"),
        ]

        let service = makeService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["aa", "bb", "cc", "dd"]),
            config: makeConfig(), force: false
        )

        let state = await service.state
        guard case .ready(_, let failed, let vectorsCount) = state else {
            XCTFail("Expected .ready, got \(state)"); return
        }
        XCTAssertEqual(vectorsCount, 2)
        XCTAssertEqual(failed, 2)
    }

    // MARK: - Load from disk

    func testLoad_afterPersist_restoresIndex() async {
        let client = MockEmbeddingClient()
        let service1 = makeService(client: client)
        await service1.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account"]),
            config: makeConfig(), force: false
        )

        let service2 = makeService(client: client)
        await service2.load()

        let state = await service2.state
        guard case .ready(_, _, let vectorsCount) = state else {
            XCTFail("Expected .ready, got \(state)"); return
        }
        XCTAssertEqual(vectorsCount, 2)
    }

    func testLoad_whenNoFiles_staysMissing() async {
        let service = makeService(client: MockEmbeddingClient())
        await service.load()
        let state = await service.state
        guard case .missing = state else {
            XCTFail("Expected .missing, got \(state)"); return
        }
    }

    // MARK: - VocabFilter — tiny-corpus behavior

    func testVocabFilter_default_acceptsSingletonsBelowSkipThreshold() {
        // On corpora with `fileCount <= nearUniversalSkipBelowFileCount`,
        // every token appears in exactly one file by construction (a 4-file
        // fixture can't have token coverage of 2+). `minPostingCount: 2`
        // would empty the vocab; the filter must be a no-op below the
        // threshold so the vector index has any candidates to match.
        let filter = VocabVectorIndexBuilder.VocabFilter.default
        XCTAssertTrue(filter.accepts(token: "scroll", postingCount: 1, fileCount: 4))
        XCTAssertTrue(filter.accepts(token: "view", postingCount: 1, fileCount: 20))
    }

    func testVocabFilter_default_filtersAtScale() {
        // Above the skip threshold the filter actively drops noise:
        // singletons (`< minPostingCount`) and near-universal tokens.
        let filter = VocabVectorIndexBuilder.VocabFilter.default
        XCTAssertFalse(filter.accepts(token: "uniqueid", postingCount: 1, fileCount: 100))
        XCTAssertTrue(filter.accepts(token: "view", postingCount: 5, fileCount: 100))
        // 90 of 100 files = 0.9 > 0.8 ratio → near-universal, drop.
        XCTAssertFalse(filter.accepts(token: "import", postingCount: 90, fileCount: 100))
    }

    // MARK: - Expand — guards

    func testExpand_emptyQuery_returnsEmpty() async {
        let service = makeService(client: MockEmbeddingClient())
        let expansion = await service.expand(
            query: "   ", tokens: [], config: makeConfig(),
            perTokenThreshold: 0.5, phraseThreshold: 0.5
        )
        XCTAssertEqual(expansion, .empty)
        XCTAssertEqual(expansion, .expanded(terms: []))
    }

    func testExpand_emptyIndex_returnsEmptyWithoutEmbeddingCall() async {
        // Index with `fileCount = 30` (above the near-universal skip
        // threshold) and every token at posting count 1 → entire vocab
        // dropped by `VocabFilter.default.minPostingCount`. The persisted
        // index has zero vectors. expand() must short-circuit to `.empty`
        // without firing a phrase embedding call (which would otherwise
        // mis-fire as `vector_index_dim_mismatch` against dims=0).
        let client = MockEmbeddingClient()
        let service = makeService(client: client)
        let cfg = makeConfig()
        let bigIndex = makeSparseSearchIndex(
            tokens: ["alpha", "beta", "gamma"], fileCount: 30
        )
        await service.rebuildIfNeeded(searchIndex: bigIndex, config: cfg, force: false)
        let buildCalls = client.callCount

        let expansion = await service.expand(
            query: "alpha", tokens: ["alpha"], config: cfg,
            perTokenThreshold: 0.5, phraseThreshold: 0.5
        )
        XCTAssertEqual(expansion, .empty)
        XCTAssertEqual(client.callCount, buildCalls,
                       "Empty index must skip the phrase embedding call")
    }

    func testExpand_whenMissing_returnsUnavailable() async {
        let service = makeService(client: MockEmbeddingClient())
        let expansion = await service.expand(
            query: "user", tokens: ["user"], config: makeConfig(),
            perTokenThreshold: 0.5, phraseThreshold: 0.5
        )
        XCTAssertEqual(expansion.unavailableReason, VocabVectorIndexService.reasonMissing)
        XCTAssertTrue(expansion.terms.isEmpty)
    }

    // MARK: - Expand — per-token path

    func testExpand_singleVocabToken_doesNotHitNetwork() async {
        let client = MockEmbeddingClient()
        // Batch size 1 so each scripted response maps to exactly one call.
        client.scriptedResponses = [
            [[1.0, 0.0, 0.0]],
            [[0.95, 0.3, 0.0]],
            [[0.0, 0.0, 1.0]],
        ]
        let cfg = makeConfig(batchSize: 1)
        let service = makeService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account", "widget"]),
            config: cfg, force: false
        )
        let buildCalls = client.callCount

        let expansion = await service.expand(
            query: "user", tokens: ["user"], config: cfg,
            perTokenThreshold: 0.5, phraseThreshold: 0.5
        )

        XCTAssertEqual(client.callCount, buildCalls,
                       "Single-token vocab-hit must skip the whole-phrase network call")
        XCTAssertTrue(expansion.terms.contains("account"))
        XCTAssertFalse(expansion.terms.contains("user"))
    }

    func testExpand_multiWordQuery_firesPhraseEmbed() async {
        let client = MockEmbeddingClient()
        client.scriptedResponses = [
            [[1.0, 0.0, 0.0]],
            [[0.9, 0.1, 0.0]],
        ]
        let cfg = makeConfig(batchSize: 1)
        let service = makeService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account"]),
            config: cfg, force: false
        )
        let buildCalls = client.callCount

        _ = await service.expand(
            query: "delete user account", tokens: ["delete", "user", "account"],
            config: cfg, perTokenThreshold: 0.99, phraseThreshold: 0.0
        )

        XCTAssertGreaterThan(client.callCount, buildCalls,
                             "Multi-word query must call /v1/embeddings once for the phrase")
    }

    /// I1: live-model dim mismatch vs persisted index MUST NOT silently
    /// collapse to `.expanded(terms: [])`. The user (and LLM) need to see
    /// the mismatch so they can rebuild embeddings.
    func testExpand_dimMismatch_surfacesAsTransientError() async {
        let client = MockEmbeddingClient()
        let cfg = makeConfig(batchSize: 2)
        let service = makeService(client: client)

        // Build at 3 dims (MockEmbeddingClient's default).
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account"]),
            config: cfg, force: false
        )

        // Script the phrase embed to return a vector with the WRONG dim count —
        // simulates a live model swap after the index was built.
        client.scriptedResponses = [
            [[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]]  // 8 dims, not 3
        ]

        let expansion = await service.expand(
            query: "completely novel phrase",
            tokens: ["completely", "novel", "phrase"],
            config: cfg, perTokenThreshold: 0.99, phraseThreshold: 0.5
        )

        XCTAssertEqual(
            expansion.errorReason ?? expansion.unavailableReason,
            "vector_index_dim_mismatch",
            "Dim mismatch must surface as a distinct canonical error reason — not an empty success."
        )
    }

    func testExpand_modelNotLoadedDuringPhraseEmbed_transitionsState() async {
        let client = MockEmbeddingClient()
        let cfg = EmbeddingConfig(
            baseURLString: "http://x", modelName: "nomic", batchSize: 2, requestTimeout: 10
        )
        let service = makeService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account"]),
            config: cfg, force: false
        )
        let buildCalls = client.callCount
        client.errorsOnCall = [buildCalls: EmbeddingClientError.modelNotLoaded("nomic")]

        let expansion = await service.expand(
            query: "completely novel phrase", tokens: ["completely", "novel", "phrase"],
            config: cfg, perTokenThreshold: 0.9, phraseThreshold: 0.5
        )

        XCTAssertEqual(expansion.unavailableReason,
                       EmbeddingClientError.modelNotLoaded("").envelopeReason)
        let state = await service.state
        guard case .modelUnavailable = state else {
            XCTFail("Expected .modelUnavailable, got \(state)"); return
        }
    }

    // MARK: - Regression: I5–I10

    // I5: cancellation mid-build does NOT persist partial state.
    func testRebuild_cancelledMidBatch_doesNotOverwriteBin() async throws {
        let slowClient = SlowMockEmbeddingClient()
        let service = makeService(client: slowClient)
        let cfg = makeConfig()

        // First build completes normally — writes bin + meta.
        slowClient.perCallDelayNanos = 0
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account"]),
            config: cfg, force: false
        )
        let binURL = internalDir.appendingPathComponent("vocab_vectors.bin")
        let mtime1 = try FileManager.default
            .attributesOfItem(atPath: binURL.path)[.modificationDate] as! Date

        // Second build slow — we cancel mid-way. The task-wrapped rebuild
        // sees CancellationError, returns early, does NOT persist.
        slowClient.perCallDelayNanos = 200_000_000  // 200ms per call
        let newSearchIndex = makeSearchIndex(
            tokens: ["user", "account", "widget", "gadget", "delete", "remove"]
        )
        let task = Task {
            await service.rebuildIfNeeded(
                searchIndex: newSearchIndex, config: cfg, force: false
            )
        }
        // Give it time to start at least one embedding call, then cancel.
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        await task.value

        // bin file mtime must be unchanged — partial state didn't land.
        let mtime2 = try FileManager.default
            .attributesOfItem(atPath: binURL.path)[.modificationDate] as! Date
        XCTAssertEqual(
            mtime1.timeIntervalSince1970, mtime2.timeIntervalSince1970,
            accuracy: 0.001,
            "Cancelled build must not rewrite the bin file"
        )

        // State reverts to the pre-cancel .ready (not .missing / .error).
        let state = await service.state
        guard case .ready(_, _, let vectorsCount) = state else {
            XCTFail("Expected .ready after cancellation, got \(state)"); return
        }
        XCTAssertEqual(vectorsCount, 2, "Vector count must reflect the pre-cancel snapshot")
    }

    // I6: rebuild-time `.modelNotLoaded` transitions state to `.modelUnavailable`.
    // This is the regression for C1 — before the terminal-error fix, the
    // builder's retry loop would eat the error and report `.ready(failed: N)`.
    func testRebuild_modelNotLoaded_transitionsToModelUnavailable() async {
        let client = MockEmbeddingClient()
        client.errorsOnCall = [0: EmbeddingClientError.modelNotLoaded("nomic")]
        let service = makeService(client: client)

        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["aa", "bb"]),
            config: makeConfig(), force: false
        )

        let state = await service.state
        guard case .modelUnavailable(let reason) = state else {
            XCTFail("Expected .modelUnavailable, got \(state)"); return
        }
        XCTAssertTrue(reason.contains("nomic"), "Reason should name the model")
        // Retry budget was NOT exhausted — exactly 1 call, not 3.
        XCTAssertEqual(client.callCount, 1, "Terminal errors must short-circuit retries")
    }

    // I7: rebuild-time `.dimensionMismatch` transitions state to `.error`.
    func testRebuild_dimensionMismatch_transitionsToError() async {
        let client = MockEmbeddingClient()
        client.errorsOnCall = [
            0: EmbeddingClientError.dimensionMismatch(expected: 768, got: 384)
        ]
        let service = makeService(client: client)

        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["aa", "bb"]),
            config: makeConfig(), force: false
        )

        let state = await service.state
        guard case .error(let message) = state else {
            XCTFail("Expected .error, got \(state)"); return
        }
        XCTAssertTrue(message.contains("dimensions") || message.contains("768"),
                      "Error message should mention dimension mismatch, got: \(message)")
        XCTAssertEqual(client.callCount, 1, "dimensionMismatch is terminal — no retries")
    }

    // I8: transient HTTP error in the whole-phrase tier surfaces via
    // `errorReason`, with any per-token hits still returned.
    func testExpand_httpErrorOnPhraseEmbed_populatesErrorReason() async {
        let client = MockEmbeddingClient()
        client.scriptedResponses = [
            [[1.0, 0.0, 0.0]], [[0.9, 0.1, 0.0]],
        ]
        let cfg = makeConfig(batchSize: 1)
        let service = makeService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account"]),
            config: cfg, force: false
        )
        let buildCalls = client.callCount
        // Next call (whole-phrase) fails with a transient 500.
        client.errorsOnCall = [
            buildCalls: EmbeddingClientError.httpError(status: 500, message: "oom")
        ]

        let expansion = await service.expand(
            query: "delete user account", tokens: ["delete", "user", "account"],
            config: cfg, perTokenThreshold: 0.0, phraseThreshold: 0.0
        )

        // errorReason must match the canonical envelopeReason for HTTP.
        XCTAssertEqual(
            expansion.errorReason,
            EmbeddingClientError.httpError(status: 500, message: nil).envelopeReason
        )
        XCTAssertNil(expansion.unavailableReason, "Transient error must not set unavailable")
        // State stays .ready — transient errors don't corrupt the cached index.
        let state = await service.state
        guard case .ready = state else {
            XCTFail("Expected .ready after transient HTTP failure, got \(state)"); return
        }
    }

    // I9: persist atomicity — if the bin gets corrupted (e.g. process killed
    // mid-write), `load()` surfaces it as `.error` via codec validation.
    // Guarantees no silently-corrupt index.
    func testLoad_binTruncated_transitionsToError() async throws {
        let client = MockEmbeddingClient()
        let service1 = makeService(client: client)
        await service1.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account"]),
            config: makeConfig(), force: false
        )

        // Simulate mid-write crash: truncate the bin to just its header.
        let binURL = internalDir.appendingPathComponent("vocab_vectors.bin")
        let fullData = try Data(contentsOf: binURL)
        let truncated = fullData.prefix(16)  // header only, no vectors
        try truncated.write(to: binURL)

        // Fresh service reads the corrupted file → .error state.
        let service2 = makeService(client: client)
        await service2.load()
        let state = await service2.state
        guard case .error = state else {
            XCTFail("Expected .error after bin truncation, got \(state)"); return
        }
    }

    // I10: canonical envelope strings produced by expand() MUST match the
    // `EmbeddingClientError.envelopeReason` and `VocabVectorIndexService.reason*`
    // single source of truth. A rename in the enum without updating the hard-
    // coded strings would break the chat-LLM consumer of the envelope.
    func testExpand_unavailableStrings_pinnedToSSOT() async {
        let service = makeService(client: MockEmbeddingClient())

        // State = .missing → reasonMissing.
        let e1 = await service.expand(
            query: "x", tokens: ["x"], config: makeConfig(),
            perTokenThreshold: 0.5, phraseThreshold: 0.5
        )
        XCTAssertEqual(e1.unavailableReason, VocabVectorIndexService.reasonMissing)

        // Build and unload model (script modelNotLoaded) → .modelUnavailable.
        let client = MockEmbeddingClient()
        let svc = makeService(client: client)
        await svc.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account"]),
            config: makeConfig(), force: false
        )
        client.errorsOnCall = [
            client.callCount: EmbeddingClientError.modelNotLoaded("nomic")
        ]
        let e2 = await svc.expand(
            query: "novel phrase query", tokens: ["novel", "phrase", "query"],
            config: makeConfig(), perTokenThreshold: 0.99, phraseThreshold: 0.5
        )
        XCTAssertEqual(
            e2.unavailableReason,
            EmbeddingClientError.modelNotLoaded("").envelopeReason,
            "expand must read the model-not-loaded reason from the enum SSOT"
        )
    }

    // C2 regression: force-full-rebuild actually re-embeds, doesn't silently
    // reuse old vectors when the token string is unchanged.
    func testForceFullRebuild_actuallyReEmbedsTokens() async {
        let client = MockEmbeddingClient()
        client.scriptedResponses = [
            [[1.0, 0.0, 0.0]], [[0.0, 1.0, 0.0]],
        ]
        let cfg = makeConfig(batchSize: 1)
        let service = makeService(client: client)
        let searchIndex = makeSearchIndex(tokens: ["user"])

        await service.rebuildIfNeeded(
            searchIndex: searchIndex, config: cfg, force: false
        )
        let callsAfterFirst = client.callCount
        XCTAssertEqual(callsAfterFirst, 1)

        // Force-rebuild with a DIFFERENT scripted vector. If the builder
        // erroneously reuses the first vector (the bug fixed by C2), the
        // second rebuild would show the old [1,0,0] in the stored index.
        client.scriptedResponses = [[[0.0, 1.0, 0.0]]]
        await service.rebuildIfNeeded(
            searchIndex: searchIndex, config: cfg, force: true
        )
        XCTAssertEqual(client.callCount, callsAfterFirst + 1,
                       "force rebuild must hit the embedder again")
    }

    // MARK: - Q1-Q2: Threshold sensitivity

    /// Q1: raising the per-token threshold strictly reduces (or preserves)
    /// the expansion result set. Same service, same vocab, two expansions
    /// back-to-back — the stricter threshold's output must be a subset.
    func testExpand_thresholdStrictness_isMonotonic() async {
        let client = MockEmbeddingClient()
        // user = [1,0,0]; account close (cos ≈ 0.95); widget far (cos ≈ 0).
        client.scriptedResponses = [
            [[1.0, 0.0, 0.0]],
            [[0.95, 0.3, 0.0]],
            [[0.0, 0.0, 1.0]],
        ]
        let cfg = makeConfig(batchSize: 1)
        let service = makeService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account", "widget"]),
            config: cfg, force: false
        )

        let lax = await service.expand(
            query: "user", tokens: ["user"], config: cfg,
            perTokenThreshold: 0.1, phraseThreshold: 0.1
        )
        let strict = await service.expand(
            query: "user", tokens: ["user"], config: cfg,
            perTokenThreshold: 0.99, phraseThreshold: 0.99
        )

        let laxSet = Set(lax.terms)
        let strictSet = Set(strict.terms)
        XCTAssertTrue(strictSet.isSubset(of: laxSet),
            "Stricter threshold must produce a subset: lax=\(laxSet), strict=\(strictSet)")
        XCTAssertTrue(laxSet.contains("account"))
        XCTAssertFalse(strictSet.contains("widget"),
            "Widget (cos ≈ 0) must fall out at threshold 0.99")
    }

    // MARK: - X1-X2: Cross-language / OOV expansion via deterministic mock

    /// X1: a Russian query embedding clusters near English tokens because
    /// the mock places them in the same region of vector space. Verifies
    /// the whole-phrase tier actually uses the phrase vector for retrieval
    /// (not just the per-token tier).
    func testExpand_cyrillicQuery_surfacesEnglishTokensViaPhraseEmbed() async {
        let client = MockEmbeddingClient()
        // Place "user" and "account" in a "person" cluster; "widget" elsewhere.
        // Build vectors (per-token embed, batchSize=1 → 3 calls).
        client.scriptedResponses = [
            [[0.9, 0.1, 0.0]],  // user
            [[0.85, 0.15, 0.0]],  // account (near user)
            [[0.0, 0.0, 1.0]],  // widget (far)
        ]
        let cfg = makeConfig(batchSize: 1)
        let service = makeService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account", "widget"]),
            config: cfg, force: false
        )
        let buildCalls = client.callCount

        // Whole-phrase embed for "пользователь" — mock returns a vector
        // close to the "person" cluster.
        client.scriptedResponses = [[[0.88, 0.12, 0.0]]]
        let expansion = await service.expand(
            query: "пользователь", tokens: ["пользователь"], config: cfg,
            // High per-token threshold so per-token tier (which finds nothing
            // because OOV) can't carry the test; forces phrase-tier.
            perTokenThreshold: 0.99, phraseThreshold: 0.5
        )

        XCTAssertEqual(client.callCount, buildCalls + 1,
            "One whole-phrase embed call for the Cyrillic OOV query")
        let surfaced = Set(expansion.terms)
        XCTAssertTrue(surfaced.contains("user"),
            "Phrase embed must surface the English translation via cosine")
        XCTAssertTrue(surfaced.contains("account"),
            "Near-cluster member `account` must also surface")
        XCTAssertFalse(surfaced.contains("widget"),
            "Far-cluster `widget` must NOT surface at threshold 0.5")
    }

    /// X2: mixed-script query where one token is in vocab and another is
    /// OOV. Per-token tier covers the known token; phrase tier covers the
    /// OOV via semantic neighbour.
    func testExpand_mixedScriptQuery_combinesBothTiers() async {
        let client = MockEmbeddingClient()
        // delete [1,0,0]; remove close; аккаунт cluster.
        client.scriptedResponses = [
            [[1.0, 0.0, 0.0]],   // delete
            [[0.95, 0.2, 0.0]],  // remove
            [[0.0, 0.9, 0.1]],   // аккаунт
        ]
        let cfg = makeConfig(batchSize: 1)
        let service = makeService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["delete", "remove", "аккаунт"]),
            config: cfg, force: false
        )
        let buildCalls = client.callCount

        // Phrase vector near the "аккаунт" cluster (OOV token's semantic home).
        client.scriptedResponses = [[[0.0, 0.85, 0.1]]]
        let expansion = await service.expand(
            query: "delete пользователя",
            tokens: ["delete", "пользователя"],
            config: cfg,
            perTokenThreshold: 0.9,  // catches remove (cos ≈ 0.95) from delete
            phraseThreshold: 0.5
        )

        XCTAssertEqual(client.callCount, buildCalls + 1,
            "Multi-token query with OOV must fire exactly one phrase embed")
        let surfaced = Set(expansion.terms)
        XCTAssertTrue(surfaced.contains("remove"),
            "Per-token tier from `delete` must find `remove`")
        XCTAssertTrue(surfaced.contains("аккаунт"),
            "Phrase tier must find `аккаунт` via the OOV token's semantic home")
    }

    // MARK: - Cfg1-Cfg2: Config change mid-session

    /// Cfg1: model name mismatch forces the builder to treat every vocab
    /// token as added (effective full rebuild). Without that, a model swap
    /// would silently reuse stale embeddings from a different model's space.
    func testRebuild_modelNameChanged_reEmbedsEverything() async {
        let client = MockEmbeddingClient()
        let service = makeService(client: client)
        let cfg1 = EmbeddingConfig(baseURLString: "http://x", modelName: "model-a",
                                   batchSize: 2, requestTimeout: 5)
        let cfg2 = EmbeddingConfig(baseURLString: "http://x", modelName: "model-b",
                                   batchSize: 2, requestTimeout: 5)

        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account"]),
            config: cfg1, force: false
        )
        let buildCallsA = client.callCount
        XCTAssertEqual(buildCallsA, 1)

        // Swap the model — same vocab, but the builder now sees modelName
        // mismatch and re-embeds every token.
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account"]),
            config: cfg2, force: false
        )
        XCTAssertGreaterThan(client.callCount, buildCallsA,
            "Model swap must invalidate the old embeddings")
    }

    // MARK: - F1-F2: Failure recovery

    /// F1: tokens from a permanent-failed batch end up in `failedTokens`.
    /// On the next rebuild (healthy mock) they're automatically retried.
    func testFailedTokens_retriedOnNextRebuild() async {
        let client = MockEmbeddingClient()
        // Batch 0 fails 3 times with non-terminal HTTP 500 (retry budget 2 →
        // 3 total attempts). Batch 1 succeeds with default response.
        client.errorsOnCall = [
            0: EmbeddingClientError.httpError(status: 500, message: "oom"),
            1: EmbeddingClientError.httpError(status: 500, message: "oom"),
            2: EmbeddingClientError.httpError(status: 500, message: "oom"),
        ]
        let service = makeService(client: client)
        let cfg = makeConfig(batchSize: 2)  // 4 tokens → 2 batches

        // Sorted vocab is ["aa", "bb", "cc", "dd"]. Batch 0 = [aa, bb], Batch 1 = [cc, dd].
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["aa", "bb", "cc", "dd"]),
            config: cfg, force: false
        )
        // State after first build: 2 in tokenMap, 2 in failedTokens.
        guard case .ready(_, let failed1, let count1) = await service.state else {
            XCTFail("Expected .ready after first build"); return
        }
        XCTAssertEqual(count1, 2)
        XCTAssertEqual(failed1, 2)
        let callsAfterFirst = client.callCount

        // Second build with a healthy client — failed tokens come back as
        // `addedTokens` (they're not in tokenMap) and get re-embedded.
        client.errorsOnCall = [:]
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["aa", "bb", "cc", "dd"]),
            config: cfg, force: false
        )

        guard case .ready(_, let failed2, let count2) = await service.state else {
            XCTFail("Expected .ready after recovery"); return
        }
        XCTAssertEqual(count2, 4, "Failed tokens must be retried and land in tokenMap")
        XCTAssertEqual(failed2, 0, "failedTokens must clear on successful retry")

        // Only one new network call — the retry was for the failed batch
        // only (the other two tokens were reused from the first build).
        XCTAssertEqual(client.callCount, callsAfterFirst + 1,
            "Recovery must diff to exactly the previously-failed batch")
    }

    /// F2: a token in `failedTokens` that's also NO LONGER in vocab (gone)
    /// doesn't resurrect. The retry path only runs for tokens that are
    /// BOTH previously-failed AND still in the current search index.
    func testFailedTokens_goneTokensNotResurrected() async {
        let client = MockEmbeddingClient()
        client.errorsOnCall = [
            0: EmbeddingClientError.httpError(status: 500, message: "oom"),
            1: EmbeddingClientError.httpError(status: 500, message: "oom"),
            2: EmbeddingClientError.httpError(status: 500, message: "oom"),
        ]
        let service = makeService(client: client)
        let cfg = makeConfig(batchSize: 2)

        // Batch 0 fails → "aa" and "bb" land in failedTokens.
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["aa", "bb", "cc", "dd"]),
            config: cfg, force: false
        )

        // Rebuild with searchIndex that DROPS aa and bb — they're now gone
        // from both vocab AND failedTokens should NOT retry them.
        client.errorsOnCall = [:]
        let callsBeforeSecond = client.callCount
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["cc", "dd"]),
            config: cfg, force: false
        )

        guard case .ready(_, let failed, let count) = await service.state else {
            XCTFail("Expected .ready"); return
        }
        XCTAssertEqual(count, 2, "Only cc + dd survive")
        XCTAssertEqual(failed, 0, "Gone tokens must be dropped from failedTokens too")
        XCTAssertEqual(client.callCount, callsBeforeSecond,
            "No retries for tokens that are no longer in vocab")
    }

    // MARK: - S_R1-S_R2: Storage roundtrip

    /// S_R1: Float16 precision roundtrip preserves cosine ranking. Writing
    /// a vector set to disk, re-reading it, and doing kNN must return the
    /// same ordering (small drift from the Float32→Float16→Float32 trip is
    /// well below cosine-threshold granularity).
    func testStorageRoundtrip_preservesRankingWithinFloat16Precision() async {
        let client = MockEmbeddingClient()
        // Three vectors with distinct cosines vs. the query "user".
        // delta = 0.01 is resolvable at Float16 precision (~3 decimal digits).
        client.scriptedResponses = [
            [[1.0, 0.0, 0.0]],          // user
            [[0.90, 0.44, 0.0]],        // account (cos ≈ 0.90)
            [[0.70, 0.71, 0.0]],        // profile (cos ≈ 0.70)
            [[0.0, 0.0, 1.0]],          // widget  (cos ≈ 0.00)
        ]
        let cfg = makeConfig(batchSize: 1)
        let service1 = makeService(client: client)
        await service1.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account", "profile", "widget"]),
            config: cfg, force: false
        )

        // Ranking from in-memory index.
        let e1 = await service1.expand(
            query: "user", tokens: ["user"], config: cfg,
            perTokenThreshold: 0.1, phraseThreshold: 0.99
        )
        XCTAssertEqual(e1.terms, ["account", "profile"].sorted(),
            "Pre-roundtrip ranking at threshold 0.1 excludes widget")

        // Fresh service reads from disk, runs the same query.
        let service2 = makeService(client: client)
        await service2.load()
        let e2 = await service2.expand(
            query: "user", tokens: ["user"], config: cfg,
            perTokenThreshold: 0.1, phraseThreshold: 0.99
        )
        XCTAssertEqual(Set(e1.terms), Set(e2.terms),
            "Float16 roundtrip must not drop terms at threshold 0.1")
    }

    /// S_R2: repeated rebuildIfNeeded with the same searchIndex reuses the
    /// in-memory cache — no additional HTTP calls. Smart-diff.
    func testRebuild_sameInputTwice_zeroAdditionalNetworkCalls() async {
        let client = MockEmbeddingClient()
        let service = makeService(client: client)
        let idx = makeSearchIndex(tokens: ["user", "account"])
        let cfg = makeConfig()

        await service.rebuildIfNeeded(searchIndex: idx, config: cfg, force: false)
        let warmCalls = client.callCount

        // Three more rebuilds, same input.
        for _ in 0..<3 {
            await service.rebuildIfNeeded(searchIndex: idx, config: cfg, force: false)
        }
        XCTAssertEqual(client.callCount, warmCalls,
            "Smart-diff must produce zero network calls on no-op rebuilds")
    }

    // MARK: - Clear

    func testClear_removesFilesAndTransitionsToMissing() async {
        let service = makeService(client: MockEmbeddingClient())
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user", "account"]),
            config: makeConfig(), force: false
        )
        await service.clear()

        let state = await service.state
        guard case .missing = state else {
            XCTFail("Expected .missing, got \(state)"); return
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: internalDir.appendingPathComponent("vocab_vectors.bin").path
        ))
        let clearError = await service.lastClearError
        XCTAssertNil(clearError, "Successful clear must leave lastClearError nil.")
    }

    /// Without surfaced clear errors, a locked / RO bin or meta file silently
    /// survives `clear()` and the next `load()` resurrects it as `.ready`
    /// while the user thought they wiped the index. Regression test.
    func testClear_persistFailure_surfacesLastClearError() async {
        let service = makeService(client: MockEmbeddingClient())
        await service.rebuildIfNeeded(
            searchIndex: makeSearchIndex(tokens: ["user"]),
            config: makeConfig(), force: false
        )
        // Lock the parent directory so removeItem fails with EACCES.
        chmod(internalDir.path, 0o500)
        defer { chmod(internalDir.path, 0o700) }

        await service.clear()

        let clearError = await service.lastClearError
        XCTAssertNotNil(clearError,
            "Failed bin/meta removal must surface via lastClearError.")
    }

    // MARK: - Persist failure after build

    /// When persist throws AFTER a successful build (e.g. disk full, RO
    /// volume, parent dir unwritable), the service must transition to
    /// `.error` rather than reporting `.ready` against an in-memory index
    /// that was never durably stored. Without the test, a regression that
    /// caches the index before persisting could silently advertise stale
    /// state across restart.
    func testRebuildIfNeeded_persistFailureAfterBuild_setsErrorState() async {
        let client = MockEmbeddingClient()
        let service = makeService(client: client)
        let cfg = makeConfig()
        let searchIndex = makeSearchIndex(tokens: ["user", "account"])

        // Lock the parent directory so the atomic-write inside persist()
        // fails. createDirectory(withIntermediateDirectories:) is a no-op on
        // an existing dir, so we don't need to remove the dir — we just
        // strip its write permission.
        chmod(internalDir.path, 0o500)
        defer { chmod(internalDir.path, 0o700) }

        await service.rebuildIfNeeded(searchIndex: searchIndex, config: cfg, force: false)

        let state = await service.state
        guard case .error = state else {
            XCTFail("Expected .error after persist failure, got \(state)")
            return
        }

        // Embedding succeeded — at least one HTTP call happened — so the
        // failure is genuinely on the persist side, not the upstream embed.
        XCTAssertGreaterThanOrEqual(client.callCount, 1,
            "Test only meaningful when embedding succeeded but persist failed.")

        // On-disk state must NOT be present (write failed). A subsequent
        // load() on a fresh service should report .missing — guards against
        // the stale-served-from-cache regression call-out in the review.
        chmod(internalDir.path, 0o700) // re-enable so a fresh service can probe
        let fresh = makeService(client: MockEmbeddingClient())
        await fresh.load()
        let freshState = await fresh.state
        if case .ready = freshState {
            XCTFail("Persist-failed index must not be readable from disk; got .ready")
        }
    }
}
