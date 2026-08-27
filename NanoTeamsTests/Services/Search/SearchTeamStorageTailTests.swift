import XCTest
import PDFKit

@testable import NanoTeams

// ============================================================================
// MARK: - Shared file-private doubles
// ============================================================================

/// Deterministic embedding client. Never touches the network.
///
/// Distinct from `VocabVectorIndexServiceTests.MockEmbeddingClient` (file-private
/// there) and from `SearchIndexCoordinatorTests.RecordingEmbedClient`: this one
/// fails by INPUT CONTENT rather than by call index, which is what lets a test
/// fail exactly one token's batch without depending on `Set.sorted()` landing it
/// at a particular call number.
private final class TailEmbedClient: EmbeddingClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0

    /// A batch containing a text whose SUFFIX is one of these throws `.timeout`
    /// (a transient classification, so the builder retries then gives up on the
    /// batch rather than aborting the whole build).
    var failTokens: Set<String> = []
    /// Thrown on every call; takes priority over `failTokens`.
    var alwaysThrow: Error?
    /// Dimension of every returned vector.
    var dims: Int = 3

    var callCount: Int { lock.withLock { _callCount } }

    func embed(texts: [String], config: EmbeddingConfig) async throws -> [[Float]] {
        let (idx, shouldFail, always): (Int, Bool, Error?) = lock.withLock {
            let i = _callCount
            _callCount += 1
            let fail = texts.contains { text in failTokens.contains { text.hasSuffix($0) } }
            return (i, fail, alwaysThrow)
        }
        if let always { throw always }
        if shouldFail { throw EmbeddingClientError.timeout }
        // Non-zero, mutually distinct vectors — a zero vector would normalize to
        // NaN and make any similarity assertion meaningless.
        return texts.enumerated().map { (j, _) -> [Float] in
            var v = [Float](repeating: 0, count: dims)
            v[0] = 1
            if dims > 1 { v[1] = Float(idx) * 0.1 + Float(j) * 0.01 }
            return v
        }
    }
}

// MARK: - Index fixtures

/// Search index whose every token appears in 2 of `fileCount` files, so it
/// survives `VocabFilter.default` (`minPostingCount: 2`, near-universal cap).
private func makeTailSearchIndex(tokens: [String], fileCount: Int = 10) -> SearchIndex {
    var postings: [String: [Int]] = [:]
    for token in tokens { postings[token] = [0, 1] }
    let files = (0..<fileCount).map {
        IndexedFile(path: "f\($0).swift", mTime: Date(timeIntervalSince1970: 1_700_000_000), size: 100)
    }
    // swiftlint:disable:next force_try
    return try! SearchIndex(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        signature: IndexSignature(
            fileCount: fileCount,
            maxMTime: Date(timeIntervalSince1970: 1_700_000_000),
            totalSize: Int64(fileCount * 100)
        ),
        files: files,
        tokens: tokens.sorted(),
        postings: postings
    )
}

/// Every token appears in exactly ONE file on a corpus large enough
/// (`fileCount > nearUniversalSkipBelowFileCount`) that `minPostingCount: 2`
/// stays active — so the filtered vocab comes out EMPTY.
private func makeTailSparseSearchIndex(tokens: [String], fileCount: Int = 30) -> SearchIndex {
    var postings: [String: [Int]] = [:]
    for (i, token) in tokens.enumerated() { postings[token] = [i % fileCount] }
    let files = (0..<fileCount).map {
        IndexedFile(path: "s\($0).swift", mTime: Date(timeIntervalSince1970: 1_700_000_000), size: 100)
    }
    // swiftlint:disable:next force_try
    return try! SearchIndex(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        signature: IndexSignature(
            fileCount: fileCount,
            maxMTime: Date(timeIntervalSince1970: 1_700_000_000),
            totalSize: Int64(fileCount * 100)
        ),
        files: files,
        tokens: tokens.sorted(),
        postings: postings
    )
}

private func makeTailEmbeddingConfig(batchSize: Int = 2) -> EmbeddingConfig {
    EmbeddingConfig(
        baseURLString: "http://127.0.0.1:1234",
        modelName: "tail-test-model",
        batchSize: batchSize,
        requestTimeout: 5
    )
}

// MARK: - Team fixtures

private func makeTailSupervisorRole(
    id: String = "tail-supervisor",
    requiredArtifacts: [String] = ["Final Deliverable"]
) -> TeamRoleDefinition {
    TeamRoleDefinition(
        id: id,
        name: "Supervisor",
        prompt: "You are the Supervisor.",
        toolIDs: [],
        usePlanningPhase: false,
        dependencies: RoleDependencies(
            requiredArtifacts: requiredArtifacts,
            producesArtifacts: ["Supervisor Task"]
        ),
        isSystemRole: true,
        systemRoleID: "supervisor"
    )
}

private func makeTailWorkerRole(
    id: String,
    name: String,
    requiredArtifacts: [String] = ["Supervisor Task"],
    producesArtifacts: [String] = []
) -> TeamRoleDefinition {
    TeamRoleDefinition(
        id: id,
        name: name,
        prompt: "You are \(name).",
        toolIDs: ["read_file"],
        usePlanningPhase: false,
        dependencies: RoleDependencies(
            requiredArtifacts: requiredArtifacts,
            producesArtifacts: producesArtifacts
        )
    )
}

private func makeTailTeam(
    roles: [TeamRoleDefinition],
    settings: TeamSettings = .default,
    name: String = "Tail Test Team"
) -> Team {
    Team(
        name: name,
        roles: roles,
        artifacts: [],
        settings: settings,
        graphLayout: TeamGraphLayout()
    )
}

// ============================================================================
// MARK: - Search: actors + pure builder + per-file scanner
// ============================================================================

/// Tail coverage for `SearchIndexService`, `VocabVectorIndexService`,
/// `VocabVectorIndexBuilder` and `SearchFileScanner`.
///
/// Nonisolated on purpose: every subject here is either an `actor` (awaited) or a
/// `nonisolated` value type. `SearchIndexCoordinator` is `@MainActor` and lives in
/// its own class below.
final class SearchTeamStorageSearchTailTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!
    var resolver: SandboxPathResolver!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        MonotonicClock.shared.reset()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
        resolver = SandboxPathResolver(workFolderRoot: tempDir, internalDir: internalDir)
    }

    override func tearDownWithError() throws {
        // Restore permissions before delete — a chmod'd 0o000 subdir survives
        // `removeItem` and leaks the temp tree across the whole suite.
        if let tempDir {
            chmod(tempDir.appendingPathComponent("blocked").path, 0o700)
            chmod(internalDir.path, 0o700)
            try? fm.removeItem(at: tempDir)
        }
        tempDir = nil
        internalDir = nil
        resolver = nil
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeBytes(_ relPath: String, bytes: [UInt8]) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(bytes).write(to: url)
    }

    /// A minimal DOCX whose `word/document.xml` carries `body`.
    private func writeDOCX(_ relPath: String, body: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let docXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>\(body)</w:body>
        </w:document>
        """
        try ZIPArchiveWriter.write(to: url, entries: [
            .init(name: "word/document.xml", data: Data(docXML.utf8), method: .deflate)
        ])
    }

    /// A structurally valid PDF with one blank page and no text layer — the shape a
    /// scanner produces. `PDFPage.string` is nil for it, which is what PDFKit also
    /// reports for a page holding only a scanned image.
    private func writeImageOnlyPDF(_ relPath: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)
        XCTAssertTrue(doc.write(to: url), "fixture must produce a readable PDF")
    }

    private func makeSearchIndexService() -> SearchIndexService {
        SearchIndexService(
            workFolderRoot: tempDir,
            internalDir: internalDir,
            fileManager: .default
        )
    }

    private func makeVectorService(client: any EmbeddingClient) -> VocabVectorIndexService {
        VocabVectorIndexService(
            internalDir: internalDir,
            client: client,
            fileManager: .default
        )
    }

    private var vectorBinURL: URL {
        internalDir.appendingPathComponent("vocab_vectors.bin", isDirectory: false)
    }

    private var vectorMetaURL: URL {
        internalDir.appendingPathComponent("vocab_vectors.meta.json", isDirectory: false)
    }

    private func runSearch(
        _ queries: [String],
        maxResults: Int = 20,
        contextBefore: Int = 0,
        contextAfter: Int = 0
    ) async throws -> SearchExecutorOutput {
        try await SearchExecutor.run(SearchExecutorInput(
            workFolderRoot: tempDir,
            resolver: resolver,
            fileManager: fm,
            queries: queries,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            maxResults: maxResults,
            internalDir: internalDir
        ))
    }

    // ------------------------------------------------------------------
    // MARK: - SearchIndexService: query wrappers with no index at all
    // ------------------------------------------------------------------

    /// `files(containing:)` short-circuits on `cached ?? loadFromDisk()`. With
    /// neither, it must return empty rather than triggering a build — a query is
    /// not a build request, and building here would make an exploratory-search
    /// lookup pay a full walk on a folder the user never indexed.
    func testQuery_noCacheNoDiskIndex_returnsEmptyWithoutBuilding() async throws {
        try write("A.swift", content: "class ScrollViewController {}")
        let service = makeSearchIndexService()

        let hits = await service.files(containing: ["scroll"])
        XCTAssertTrue(hits.isEmpty,
                      "No cache and no on-disk index must yield [], not a lazy rebuild.")

        let indexFile = internalDir.appendingPathComponent("search_index.json")
        XCTAssertFalse(fm.fileExists(atPath: indexFile.path),
                       "A query must not persist an index as a side effect.")
    }

    func testFilesContaining_noCacheNoDiskIndex_returnsEmpty() async throws {
        try write("A.swift", content: "class Foo {}")
        let service = makeSearchIndexService()

        let files = await service.files(containing: ["foo"])
        XCTAssertTrue(files.isEmpty)
    }

    // ------------------------------------------------------------------
    // MARK: - SearchIndexService: on-disk version drift
    // ------------------------------------------------------------------

    /// A stored index from an older schema is not corrupt — it decodes fine — so
    /// the version guard is the only thing that rejects it. `lastLoadError` must
    /// name the drift so the settings card can say WHY the index regenerated.
    func testLoadFromDisk_versionDrift_surfacesLoadErrorAndRebuilds() async throws {
        try write("A.swift", content: "class Alpha {}")
        let service = makeSearchIndexService()
        _ = await service.loadOrBuild()

        let indexFile = internalDir.appendingPathComponent("search_index.json")
        let raw = try Data(contentsOf: indexFile)
        guard var obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return XCTFail("search_index.json is not a JSON object")
        }
        obj["version"] = SearchIndex.currentVersion + 99
        try JSONSerialization.data(withJSONObject: obj).write(to: indexFile)

        // Fresh actor so the in-memory cache can't mask the disk read.
        let reopened = makeSearchIndexService()
        let index = await reopened.loadOrBuild()
        let loadError = await reopened.lastLoadError

        XCTAssertEqual(index.files.count, 1, "Version drift must rebuild, not fail.")
        // NOTE — this pins the CODE, and the code and its doc comment disagree.
        // `lastLoadError`'s doc says "Cleared on a clean load or a successful
        // rebuild", but `rebuildIndex()` never touches the field; only a clean
        // `loadFromDisk` clears it. So the reason survives the rebuild that it
        // caused, which is arguably the more useful behaviour (the settings card
        // can say WHY the index regenerated) — and it self-heals on the next
        // call, when `loadFromDisk` succeeds. If the doc wins instead, this
        // assertion is the one line to flip.
        XCTAssertNotNil(loadError, "Version drift must be surfaced, not swallowed.")
        XCTAssertTrue(loadError?.contains("version") ?? false,
                      "Drift message must name the version mismatch — got: \(loadError ?? "nil")")
    }

    // ------------------------------------------------------------------
    // MARK: - SearchIndexService: .rtfd bundles are files, not directories
    // ------------------------------------------------------------------

    /// `.rtfd` is a DIRECTORY on disk but one document to the user. The walk must
    /// visit it as a single entry and must NOT descend into it — otherwise the
    /// package's internal `TXT.rtf` shows up as its own indexed file and the
    /// bundle itself never appears.
    func testWalk_rtfdBundle_indexedAsOneFileAndNotDescendedInto() async throws {
        let bundle = tempDir.appendingPathComponent("Notes.rtfd", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "{\\rtf1\\ansi hello}".write(
            to: bundle.appendingPathComponent("TXT.rtf"), atomically: true, encoding: .utf8
        )

        let service = makeSearchIndexService()
        let index = await service.loadOrBuild()
        let paths = Set(index.files.map(\.path))

        XCTAssertTrue(paths.contains("Notes.rtfd"),
                      "The bundle itself must be indexed — got: \(paths.sorted())")
        XCTAssertFalse(paths.contains("Notes.rtfd/TXT.rtf"),
                       "The walk must not descend into an .rtfd package.")
    }

    // ------------------------------------------------------------------
    // MARK: - VocabVectorIndexService: load() failure modes
    // ------------------------------------------------------------------

    func testVectorLoad_noFilesOnDisk_isMissingNotError() async {
        let service = makeVectorService(client: TailEmbedClient())
        await service.load()
        let state = await service.state
        XCTAssertEqual(state, .missing,
                       "Absent files are first-launch, not corruption.")
    }

    /// Meta version drift is a clean regenerate signal, NOT an error: `load()`
    /// drops to `.missing` so the next `rebuildIfNeeded` rebuilds from scratch.
    func testVectorLoad_metaVersionDrift_fallsBackToMissing() async throws {
        let client = TailEmbedClient()
        let service = makeVectorService(client: client)
        let cfg = makeTailEmbeddingConfig()
        await service.rebuildIfNeeded(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta"]),
            config: cfg, force: false
        )
        XCTAssertTrue(fm.fileExists(atPath: vectorMetaURL.path))

        let raw = try Data(contentsOf: vectorMetaURL)
        guard var obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return XCTFail("vocab_vectors.meta.json is not a JSON object")
        }
        obj["version"] = VocabVectorIndex.Meta.currentVersion + 42
        try JSONSerialization.data(withJSONObject: obj).write(to: vectorMetaURL)

        let reopened = makeVectorService(client: TailEmbedClient())
        await reopened.load()
        let state = await reopened.state
        XCTAssertEqual(state, .missing,
                       "A version-drifted meta must read as missing so it regenerates.")
    }

    /// A bin whose byte count disagrees with `meta.dims * tokenMap.count` means
    /// the two files were written by different runs (crash between the two atomic
    /// writes). That IS corruption and must surface as `.error` so the card can
    /// say so — `cached` stays nil, so the next rebuild recovers automatically.
    func testVectorLoad_truncatedBin_surfacesErrorState() async throws {
        let service = makeVectorService(client: TailEmbedClient())
        await service.rebuildIfNeeded(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta", "gamma"]),
            config: makeTailEmbeddingConfig(), force: false
        )
        XCTAssertTrue(fm.fileExists(atPath: vectorBinURL.path))

        try Data([0x01, 0x02, 0x03]).write(to: vectorBinURL)

        let reopened = makeVectorService(client: TailEmbedClient())
        await reopened.load()
        let state = await reopened.state
        guard case .error = state else {
            return XCTFail("Truncated bin must load as .error — got \(state)")
        }
    }

    // ------------------------------------------------------------------
    // MARK: - VocabVectorIndexService: clear() failure surfacing
    // ------------------------------------------------------------------

    /// Silent clear failure is the worst outcome: the next `load()` resurrects the
    /// stale index after the user explicitly asked for a clear.
    func testVectorClear_unwritableDirectory_surfacesLastClearError() async {
        let service = makeVectorService(client: TailEmbedClient())
        await service.rebuildIfNeeded(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta"]),
            config: makeTailEmbeddingConfig(), force: false
        )
        XCTAssertTrue(fm.fileExists(atPath: vectorBinURL.path))

        // Strip the write bit on the parent so `removeItem` fails with EACCES.
        chmod(internalDir.path, 0o500)
        defer { chmod(internalDir.path, 0o700) }

        await service.clear()
        let clearError = await service.lastClearError
        XCTAssertNotNil(clearError,
                        "A failed removeItem must surface, never report a clean clear.")
    }

    func testVectorClear_nothingOnDisk_isNotAnError() async {
        let service = makeVectorService(client: TailEmbedClient())
        await service.clear()
        let clearError = await service.lastClearError
        let state = await service.state
        XCTAssertNil(clearError)
        XCTAssertEqual(state, .missing)
    }

    // ------------------------------------------------------------------
    // MARK: - VocabVectorIndexService: rebuild error classification
    // ------------------------------------------------------------------

    /// `.serverUnreachable` is TERMINAL, so the builder rethrows instead of
    /// burning `batchRetries` against a closed port. The service must translate
    /// that into `.modelUnavailable` (actionable: "start LM Studio"), not the
    /// generic `.error`.
    func testRebuild_serverUnreachable_setsModelUnavailableNotError() async {
        let client = TailEmbedClient()
        client.alwaysThrow = EmbeddingClientError.serverUnreachable("connection refused")
        let service = makeVectorService(client: client)

        await service.rebuildIfNeeded(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta"]),
            config: makeTailEmbeddingConfig(), force: false
        )

        let state = await service.state
        guard case .modelUnavailable(let reason) = state else {
            return XCTFail("serverUnreachable must map to .modelUnavailable — got \(state)")
        }
        XCTAssertTrue(reason.lowercased().contains("connect"),
                      "Reason must point at connectivity — got: \(reason)")
        XCTAssertEqual(client.callCount, 1,
                       "A terminal classification must not be retried.")
    }

    /// `.dimensionMismatch` is terminal too, but it is NOT a connectivity problem
    /// — it must land in `.error` with the decoded description rather than being
    /// mislabelled "model not loaded".
    func testRebuild_dimensionMismatch_setsErrorState() async {
        let client = TailEmbedClient()
        client.alwaysThrow = EmbeddingClientError.dimensionMismatch(expected: 768, got: 3)
        let service = makeVectorService(client: client)

        await service.rebuildIfNeeded(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta"]),
            config: makeTailEmbeddingConfig(), force: false
        )

        let state = await service.state
        guard case .error(let message) = state else {
            return XCTFail("dimensionMismatch must map to .error — got \(state)")
        }
        XCTAssertTrue(message.lowercased().contains("dimension"),
                      "Message must name the mismatch — got: \(message)")
    }

    /// `.modelNotLoaded` names the model so the UI can tell the user exactly what
    /// to load.
    func testRebuild_modelNotLoaded_namesTheModelInTheReason() async {
        let client = TailEmbedClient()
        client.alwaysThrow = EmbeddingClientError.modelNotLoaded("nomic-embed-text")
        let service = makeVectorService(client: client)

        await service.rebuildIfNeeded(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta"]),
            config: makeTailEmbeddingConfig(), force: false
        )

        let state = await service.state
        guard case .modelUnavailable(let reason) = state else {
            return XCTFail("modelNotLoaded must map to .modelUnavailable — got \(state)")
        }
        XCTAssertTrue(reason.contains("nomic-embed-text"),
                      "Reason must name the model — got: \(reason)")
    }

    // ------------------------------------------------------------------
    // MARK: - VocabVectorIndexService: expand() guards
    // ------------------------------------------------------------------

    /// Whitespace-only queries must not reach `/v1/embeddings`. Without this
    /// guard the phrase tier ships the (empty) prefix and gets a garbage vector
    /// back that pollutes nearest-neighbour matching.
    func testExpand_whitespaceOnlyQuery_returnsEmptyWithoutEmbedding() async {
        let client = TailEmbedClient()
        let service = makeVectorService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta"]),
            config: makeTailEmbeddingConfig(), force: false
        )
        let callsAfterBuild = client.callCount

        let result = await service.expand(
            query: "   \n\t ", tokens: ["alpha"],
            config: makeTailEmbeddingConfig(),
            perTokenThreshold: 0.1, phraseThreshold: 0.1
        )

        XCTAssertEqual(result, .expanded(terms: []))
        XCTAssertEqual(client.callCount, callsAfterBuild,
                       "A blank query must burn zero embedding calls.")
    }

    /// A punctuation-only query tokenizes to `[]`. Per-token is a no-op and the
    /// phrase tier would embed junk — same `.empty` answer as a blank query.
    func testExpand_emptyTokenList_returnsEmptyWithoutEmbedding() async {
        let client = TailEmbedClient()
        let service = makeVectorService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta"]),
            config: makeTailEmbeddingConfig(), force: false
        )
        let callsAfterBuild = client.callCount

        let result = await service.expand(
            query: "??? !!!", tokens: [],
            config: makeTailEmbeddingConfig(),
            perTokenThreshold: 0.1, phraseThreshold: 0.1
        )

        XCTAssertEqual(result, .expanded(terms: []))
        XCTAssertEqual(client.callCount, callsAfterBuild)
    }

    /// `.missing` is structural unavailability, and the canonical envelope reason
    /// is what the chat LLM reads to decide whether expansion is worth retrying.
    func testExpand_missingState_returnsCanonicalUnavailableReason() async {
        let service = makeVectorService(client: TailEmbedClient())

        let result = await service.expand(
            query: "scroll view", tokens: ["scroll", "view"],
            config: makeTailEmbeddingConfig(),
            perTokenThreshold: 0.1, phraseThreshold: 0.1
        )

        XCTAssertEqual(result, .unavailable(reason: VocabVectorIndexService.reasonMissing))
        XCTAssertTrue(result.terms.isEmpty)
        XCTAssertNil(result.errorReason, ".unavailable carries no transient reason")
        XCTAssertEqual(result.unavailableReason, VocabVectorIndexService.reasonMissing)
    }

    /// A corrupt on-disk index leaves the actor in `.error`; expansion must report
    /// that distinctly from "missing" so the UI prompts a rebuild rather than a
    /// first build.
    func testExpand_errorState_returnsInternalErrorReason() async throws {
        let service = makeVectorService(client: TailEmbedClient())
        await service.rebuildIfNeeded(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta"]),
            config: makeTailEmbeddingConfig(), force: false
        )
        try Data([0x09]).write(to: vectorBinURL)

        let reopened = makeVectorService(client: TailEmbedClient())
        await reopened.load()

        let result = await reopened.expand(
            query: "alpha beta", tokens: ["alpha", "beta"],
            config: makeTailEmbeddingConfig(),
            perTokenThreshold: 0.1, phraseThreshold: 0.1
        )

        XCTAssertEqual(result, .unavailable(reason: VocabVectorIndexService.reasonInternalError))
    }

    /// A `.modelUnavailable` service must refuse expansion up front rather than
    /// firing a doomed `/v1/embeddings` call per query.
    func testExpand_modelUnavailableState_shortCircuitsBeforeEmbedding() async {
        let client = TailEmbedClient()
        client.alwaysThrow = EmbeddingClientError.serverUnreachable("refused")
        let service = makeVectorService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta"]),
            config: makeTailEmbeddingConfig(), force: false
        )
        let callsAfterBuild = client.callCount

        let result = await service.expand(
            query: "alpha beta", tokens: ["alpha", "beta"],
            config: makeTailEmbeddingConfig(),
            perTokenThreshold: 0.1, phraseThreshold: 0.1
        )

        guard case .unavailable = result else {
            return XCTFail("modelUnavailable state must gate expansion — got \(result)")
        }
        XCTAssertEqual(client.callCount, callsAfterBuild,
                       "State gate must run BEFORE the phrase-embed call.")
    }

    /// An index that filtered down to zero vectors is `.ready` with `dims == 0`.
    /// That is "no close matches", NOT a dim mismatch — the guard exists so the
    /// live phrase vector isn't compared against a zero-dim index.
    func testExpand_readyButEmptyIndex_returnsEmptyRatherThanDimMismatch() async {
        let client = TailEmbedClient()
        let service = makeVectorService(client: client)
        // Sparse corpus: every token has postingCount 1 on 30 files, so
        // `VocabFilter.default` rejects all of them and the vocab is empty.
        await service.rebuildIfNeeded(
            searchIndex: makeTailSparseSearchIndex(tokens: ["aa", "bb", "cc"]),
            config: makeTailEmbeddingConfig(), force: false
        )
        let state = await service.state
        guard case .ready = state else {
            return XCTFail("Empty-vocab build must still land .ready — got \(state)")
        }
        let callsAfterBuild = client.callCount

        let result = await service.expand(
            query: "alpha beta", tokens: ["alpha", "beta"],
            config: makeTailEmbeddingConfig(),
            perTokenThreshold: 0.1, phraseThreshold: 0.1
        )

        XCTAssertEqual(result, .expanded(terms: []),
                       "Zero-vector index is a clean no-match, not an error.")
        XCTAssertEqual(client.callCount, callsAfterBuild,
                       "No candidates ⇒ no phrase embed.")
    }

    /// A mid-query `.serverUnreachable` must ALSO update the actor's state — the
    /// card would otherwise keep claiming `.ready` while every query fails.
    func testExpand_serverUnreachableMidQuery_flipsStateToModelUnavailable() async {
        let client = TailEmbedClient()
        let service = makeVectorService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta", "gamma"]),
            config: makeTailEmbeddingConfig(), force: false
        )
        client.alwaysThrow = EmbeddingClientError.serverUnreachable("refused")

        let result = await service.expand(
            // Multi-token phrase that isn't itself a single vocab token, so the
            // phrase tier definitely fires.
            query: "alpha gamma delta", tokens: ["alpha", "gamma", "delta"],
            config: makeTailEmbeddingConfig(),
            perTokenThreshold: 0.1, phraseThreshold: 0.1
        )

        guard case .unavailable = result else {
            return XCTFail("Mid-query serverUnreachable must return .unavailable — got \(result)")
        }
        let state = await service.state
        guard case .modelUnavailable = state else {
            return XCTFail("State must follow the failure, not stay .ready — got \(state)")
        }
    }

    /// A NON-terminal live failure keeps whatever the per-token tier already
    /// found (those came off the persisted index and are still valid) and reports
    /// the reason as transient.
    func testExpand_transientLiveFailure_returnsTransientErrorAndKeepsReadyState() async {
        let client = TailEmbedClient()
        let service = makeVectorService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta", "gamma"]),
            config: makeTailEmbeddingConfig(), force: false
        )
        client.alwaysThrow = EmbeddingClientError.httpError(status: 503, message: "busy")

        let result = await service.expand(
            query: "alpha gamma delta", tokens: ["alpha", "gamma", "delta"],
            config: makeTailEmbeddingConfig(),
            perTokenThreshold: 0.1, phraseThreshold: 0.1
        )

        guard case .transientError(_, let reason) = result else {
            return XCTFail("A 503 is retryable — expected .transientError, got \(result)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNotNil(result.errorReason)
        XCTAssertNil(result.unavailableReason)

        let state = await service.state
        guard case .ready = state else {
            return XCTFail("A transient failure must NOT demote the index — got \(state)")
        }
    }

    /// A non-`EmbeddingClientError` escaping the client is classified as a
    /// transport problem rather than being allowed to propagate.
    func testExpand_unknownErrorType_classifiedAsTransportTransient() async {
        struct TailOpaqueError: Error {}
        let client = TailEmbedClient()
        let service = makeVectorService(client: client)
        await service.rebuildIfNeeded(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta", "gamma"]),
            config: makeTailEmbeddingConfig(), force: false
        )
        client.alwaysThrow = TailOpaqueError()

        let result = await service.expand(
            query: "alpha gamma delta", tokens: ["alpha", "gamma", "delta"],
            config: makeTailEmbeddingConfig(),
            perTokenThreshold: 0.1, phraseThreshold: 0.1
        )

        guard case .transientError(_, let reason) = result else {
            return XCTFail("Unknown errors must not escape as .expanded — got \(result)")
        }
        XCTAssertEqual(reason, EmbeddingClientError.transportError("").envelopeReason)
    }

    // ------------------------------------------------------------------
    // MARK: - VocabVectorIndexBuilder (driven directly)
    // ------------------------------------------------------------------

    /// A terminal classification must abort the build immediately. Retrying a
    /// "model not loaded" burns `batchRetries × batches` round-trips for an answer
    /// that cannot change without human action.
    func testBuilder_terminalError_throwsWithoutRetrying() async {
        let client = TailEmbedClient()
        client.alwaysThrow = EmbeddingClientError.modelNotLoaded("nomic")
        let builder = VocabVectorIndexBuilder(
            client: client, batchRetries: 2, retryBackoffSeconds: [0, 0]
        )

        do {
            _ = try await builder.build(
                searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta", "gamma", "delta"]),
                current: nil, config: makeTailEmbeddingConfig(batchSize: 1), force: false
            )
            XCTFail("A terminal EmbeddingClientError must propagate out of build()")
        } catch let err as EmbeddingClientError {
            XCTAssertEqual(err, .modelNotLoaded("nomic"))
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertEqual(client.callCount, 1, "Terminal ⇒ exactly one attempt.")
    }

    /// A transient failure is retried `batchRetries` times, then the batch is
    /// abandoned into `failedTokens` and the build CONTINUES — one 5xx in the
    /// middle must not throw away every successful batch before it.
    func testBuilder_transientFailure_retriesThenFailsOnlyThatBatch() async throws {
        let client = TailEmbedClient()
        client.failTokens = ["beta"]
        let builder = VocabVectorIndexBuilder(
            client: client, batchRetries: 2, retryBackoffSeconds: [0, 0]
        )

        let result = try await builder.build(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta", "gamma"]),
            current: nil, config: makeTailEmbeddingConfig(batchSize: 1), force: false
        )

        XCTAssertEqual(result.failedCount, 1, "Only the poisoned batch fails.")
        XCTAssertTrue(result.index.meta.failedTokens.contains("beta"))
        XCTAssertEqual(result.addedCount, 2, "alpha + gamma must survive.")
        XCTAssertTrue(result.needsPersist)
        XCTAssertFalse(result.index.meta.tokenMap.keys.contains("beta"),
                       "A failed token must not enter the token map.")
        // 3 batches; the "beta" batch is attempted 1 + batchRetries times.
        XCTAssertEqual(client.callCount, 2 + 3)
    }

    /// A failed token is NOT in `tokenMap`, so it reappears in `added` on the next
    /// run — that is how transient failures self-heal without a retry queue.
    func testBuilder_failedTokenIsRetriedOnNextBuild() async throws {
        let client = TailEmbedClient()
        client.failTokens = ["beta"]
        let builder = VocabVectorIndexBuilder(
            client: client, batchRetries: 0, retryBackoffSeconds: [0]
        )
        let index = makeTailSearchIndex(tokens: ["alpha", "beta"])
        let cfg = makeTailEmbeddingConfig(batchSize: 1)

        let first = try await builder.build(
            searchIndex: index, current: nil, config: cfg, force: false
        )
        XCTAssertEqual(first.index.meta.failedTokens, ["beta"])

        client.failTokens = []
        let second = try await builder.build(
            searchIndex: index, current: first.index, config: cfg, force: false
        )

        XCTAssertTrue(second.index.meta.tokenMap.keys.contains("beta"),
                      "The previously failed token must be re-attempted.")
        XCTAssertTrue(second.index.meta.failedTokens.isEmpty)
        XCTAssertTrue(second.needsPersist)
    }

    /// Stale `failedTokens` — failures for tokens that have since left the vocab —
    /// must force a persist ON THEIR OWN, even when nothing was added and nothing
    /// was removed from `tokenMap`. Otherwise the list grows without bound on a
    /// long-lived project.
    func testBuilder_staleFailedTokensAlonePruneAndForcePersist() async throws {
        let client = TailEmbedClient()
        client.failTokens = ["ghost"]
        let builder = VocabVectorIndexBuilder(
            client: client, batchRetries: 0, retryBackoffSeconds: [0]
        )
        let cfg = makeTailEmbeddingConfig(batchSize: 1)

        let first = try await builder.build(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta", "ghost"]),
            current: nil, config: cfg, force: false
        )
        XCTAssertEqual(first.index.meta.failedTokens, ["ghost"])
        XCTAssertEqual(Set(first.index.meta.tokenMap.keys), ["alpha", "beta"])

        client.failTokens = []
        // "ghost" is gone from the corpus. `added` is empty (alpha/beta already
        // embedded) and `goneCount` is 0 (ghost was never in tokenMap), so
        // `staleFailedCount` is the ONLY reason left to persist.
        let second = try await builder.build(
            searchIndex: makeTailSearchIndex(tokens: ["alpha", "beta"]),
            current: first.index, config: cfg, force: false
        )

        XCTAssertTrue(second.needsPersist,
                      "Pruning a stale failed token must be persisted.")
        XCTAssertEqual(second.addedCount, 0)
        XCTAssertEqual(second.removedCount, 0)
        XCTAssertTrue(second.index.meta.failedTokens.isEmpty,
                      "The stale entry must be dropped — got \(second.index.meta.failedTokens)")
        XCTAssertEqual(Set(second.index.meta.tokenMap.keys), ["alpha", "beta"])
    }

    /// A no-op run (same vocab, same model, nothing failed) must report
    /// `needsPersist == false` so the caller skips the atomic write entirely.
    func testBuilder_noDiffAtAll_shortCircuitsWithoutPersist() async throws {
        let client = TailEmbedClient()
        let builder = VocabVectorIndexBuilder(
            client: client, batchRetries: 0, retryBackoffSeconds: [0]
        )
        let index = makeTailSearchIndex(tokens: ["alpha", "beta"])
        let cfg = makeTailEmbeddingConfig(batchSize: 2)

        let first = try await builder.build(
            searchIndex: index, current: nil, config: cfg, force: false
        )
        let callsAfterFirst = client.callCount

        let second = try await builder.build(
            searchIndex: index, current: first.index, config: cfg, force: false
        )

        XCTAssertFalse(second.needsPersist)
        XCTAssertEqual(second.addedCount, 0)
        XCTAssertEqual(second.removedCount, 0)
        XCTAssertEqual(client.callCount, callsAfterFirst,
                       "A no-op diff must issue zero embedding calls.")
    }

    /// Empty vocab and no existing index: there is no dimension to infer, so the
    /// builder returns an empty skeleton flagged "nothing to persist".
    func testBuilder_emptyVocabNoCurrent_returnsZeroDimSkeletonWithoutPersist() async throws {
        let client = TailEmbedClient()
        let builder = VocabVectorIndexBuilder(client: client)

        let result = try await builder.build(
            searchIndex: makeTailSparseSearchIndex(tokens: ["aa", "bb", "cc"]),
            current: nil, config: makeTailEmbeddingConfig(), force: false
        )

        XCTAssertFalse(result.needsPersist)
        XCTAssertEqual(result.index.meta.dims, 0)
        XCTAssertTrue(result.index.meta.tokenMap.isEmpty)
        XCTAssertTrue(result.index.vectors.isEmpty)
        XCTAssertEqual(client.callCount, 0, "Nothing to embed ⇒ no network calls.")
    }

    /// A model change invalidates every stored vector even though the token set is
    /// identical — the diff must fall to the "re-embed everything" branch.
    func testBuilder_modelNameChange_reEmbedsEveryToken() async throws {
        let client = TailEmbedClient()
        let builder = VocabVectorIndexBuilder(
            client: client, batchRetries: 0, retryBackoffSeconds: [0]
        )
        let index = makeTailSearchIndex(tokens: ["alpha", "beta"])

        let first = try await builder.build(
            searchIndex: index, current: nil,
            config: makeTailEmbeddingConfig(batchSize: 2), force: false
        )
        let callsAfterFirst = client.callCount

        let otherModel = EmbeddingConfig(
            baseURLString: "http://127.0.0.1:1234",
            modelName: "some-other-model", batchSize: 2, requestTimeout: 5
        )
        let second = try await builder.build(
            searchIndex: index, current: first.index, config: otherModel, force: false
        )

        XCTAssertEqual(second.addedCount, 2, "Both tokens must be re-embedded.")
        XCTAssertTrue(second.needsPersist)
        XCTAssertEqual(second.index.meta.modelName, "some-other-model")
        XCTAssertGreaterThan(client.callCount, callsAfterFirst)
    }

    /// `VocabFilter.default` deliberately accepts everything below the
    /// skip-threshold file count — on a tiny corpus `minPostingCount: 2` would
    /// otherwise empty the vocab entirely.
    func testVocabFilter_belowSkipThreshold_acceptsSingletons() {
        let filter = VocabVectorIndexBuilder.VocabFilter.default
        XCTAssertTrue(filter.accepts(token: "x", postingCount: 1, fileCount: 4))
        XCTAssertTrue(filter.accepts(token: "x", postingCount: 1,
                                     fileCount: filter.nearUniversalSkipBelowFileCount))
    }

    func testVocabFilter_aboveSkipThreshold_rejectsSingletonsAndStopwords() {
        let filter = VocabVectorIndexBuilder.VocabFilter.default
        XCTAssertFalse(filter.accepts(token: "x", postingCount: 1, fileCount: 100),
                       "postingCount 1 is noise on a real corpus.")
        XCTAssertFalse(filter.accepts(token: "the", postingCount: 95, fileCount: 100),
                       "A near-universal token is a stopword-equivalent.")
        XCTAssertTrue(filter.accepts(token: "scroll", postingCount: 10, fileCount: 100))
    }

    // ------------------------------------------------------------------
    // MARK: - SearchFileScanner (through SearchExecutor.run)
    // ------------------------------------------------------------------

    /// Context windows must clamp at both file edges rather than reaching past
    /// them — a match on line 1 has nothing before it.
    func testScanFile_contextWindow_clampsAtBothFileEdges() async throws {
        try write("edges.txt", content: "NEEDLE\nb\nc\nd\nNEEDLE\n")

        let out = try await runSearch(["NEEDLE"], contextBefore: 3, contextAfter: 3)
        XCTAssertEqual(out.matches.count, 2)

        let first = try XCTUnwrap(out.matches.first { $0.line == 1 })
        XCTAssertTrue((first.context_before ?? []).isEmpty,
                      "Nothing precedes line 1 — got \(first.context_before ?? [])")
        XCTAssertEqual((first.context_after ?? []).map(\.line), [2, 3, 4],
                       "context_after must stop before the second match's line.")

        let last = try XCTUnwrap(out.matches.first { $0.line == 5 })
        XCTAssertEqual((last.context_before ?? []).map(\.line), [2, 3, 4])
        // Trailing "\n" makes line 6 an empty final line; the window clamps to
        // whatever exists rather than running past `lineIndex.count`.
        XCTAssertLessThanOrEqual((last.context_after ?? []).count, 3)
    }

    /// NUL bytes trip the binary sniff. Binaries are COUNTED, never listed —
    /// otherwise every `.png` in a tree floods `skipped`.
    func testScanFile_nulBytes_countedAsBinaryNotListedAsSkipped() async throws {
        try writeBytes("blob.txt", bytes: [0x41, 0x00, 0x42, 0x4E, 0x45])

        let out = try await runSearch(["NEEDLE"])
        XCTAssertEqual(out.skippedBinaryCount, 1)
        XCTAssertTrue(out.skipped.isEmpty,
                      "Binaries must aggregate into a count, not the skipped list.")
        XCTAssertTrue(out.matches.isEmpty)
    }

    /// A file with no NUL byte survives the sniff but can still be invalid UTF-8.
    /// `LineScanner.buildIndex` is the second gate — a decode failure there must
    /// also register as binary rather than silently scanning garbage.
    func testScanFile_invalidUTF8WithoutNuls_stillCountedAsBinary() async throws {
        // 0xFF / 0xFE are never valid UTF-8 lead bytes, and neither is NUL.
        try writeBytes("latin.txt", bytes: [0xFF, 0xFE, 0xFF, 0xFE, 0xFF, 0xFE])

        let out = try await runSearch(["NEEDLE"])
        XCTAssertEqual(out.skippedBinaryCount, 1,
                       "Invalid UTF-8 must be classified binary, not scanned.")
        XCTAssertTrue(out.matches.isEmpty)
    }

    /// A document whose extension promises structure but whose bytes are garbage
    /// must be REPORTED, not silently absent — "no hits" and "could not read"
    /// are different answers for the model.
    func testScanFile_unreadableDocumentExtension_landsInSkippedWithReason() async throws {
        try writeBytes("broken.pdf", bytes: Array("not a pdf at all".utf8))

        let out = try await runSearch(["NEEDLE"])
        XCTAssertEqual(out.skipped.count, 1,
                       "An unreadable document must surface — got \(out.skipped)")
        let entry = try XCTUnwrap(out.skipped.first)
        XCTAssertEqual(entry.path, "broken.pdf")
        XCTAssertFalse(entry.reason.isEmpty, "The skip must carry a reason.")
    }

    /// A scanned, image-only PDF was read end to end and holds no text. Zero matches is
    /// the whole truth about it, so it is NOT an omission and must not be listed: a folder
    /// of scans otherwise emits one `skipped_files` entry per file and buries the answer.
    ///
    /// The pin sits on the SCANNER's routing, not on `PDFDocumentExtractor`: the change is
    /// a condition around the extractor call, so a test that invokes the extractor directly
    /// would be green either way (CLAUDE.md #57).
    func testScanFile_imageOnlyPDF_isNotListedAsSkipped() async throws {
        try writeImageOnlyPDF("scan.pdf")

        let out = try await runSearch(["NEEDLE"])
        XCTAssertTrue(out.skipped.isEmpty,
                      "A fully-read PDF that holds no text is not an omission: \(out.skipped)")
        XCTAssertTrue(out.matches.isEmpty)
    }

    /// The companion to the above, and the reason it is not simply "stop reporting PDFs":
    /// a PDF that could not be OPENED is still an omission. Both files sit in one tree so
    /// a fix that silences the whole format fails here.
    func testScanFile_imageOnlyPDFBesideBrokenPDF_reportsOnlyTheBrokenOne() async throws {
        try writeImageOnlyPDF("scan.pdf")
        try writeBytes("broken.pdf", bytes: Array("not a pdf at all".utf8))

        let out = try await runSearch(["NEEDLE"])
        XCTAssertEqual(out.skipped.map(\.path), ["broken.pdf"],
                       "only the unreadable file is an omission: \(out.skipped)")
    }

    /// The boundary of the silence. A DOCX with no text is NOT the same claim as a scanned
    /// PDF: this reader opens `word/document.xml` alone, so text in a header or a footnote
    /// would never have been seen. That is a gap in our coverage, and `skipped_files` is the
    /// only channel where it is visible — so it is still reported, and the reason says what
    /// went unexamined.
    func testScanFile_docxWithNoText_isStillReported_becauseOnlyTheBodyWasRead() async throws {
        try writeDOCX("empty.docx", body: "<w:p></w:p>")

        let out = try await runSearch(["NEEDLE"])
        let entry = try XCTUnwrap(out.skipped.first, "a partial read must stay visible")
        XCTAssertEqual(entry.path, "empty.docx")
        XCTAssertTrue(entry.reason.contains("were not examined"),
                      "the reason must name what went unread: \(entry.reason)")
    }

    /// An empty needle alongside a real one must never match. ICU reports no
    /// match for an empty needle; a raw byte scan would claim a hit at offset 0
    /// on every single line, so the ICU answer is the one that is kept.
    func testScanFile_emptyNeedleBesideRealOne_neverMatches() async throws {
        try write("mixed.txt", content: "alpha\nNEEDLE\nbeta\n")

        let out = try await runSearch(["", "NEEDLE"])
        XCTAssertEqual(out.matches.count, 1,
                       "Only the real needle may match — got \(out.matches.map(\.text))")
        XCTAssertEqual(out.matches.first?.line, 2)
    }

    /// One line is consumed by at most one query (`break` after a hit), so two
    /// queries that both match the same line yield ONE match, not two.
    func testScanFile_lineMatchingTwoQueries_isReportedOnce() async throws {
        try write("both.txt", content: "alpha beta\ngamma\n")

        let out = try await runSearch(["alpha", "beta"])
        XCTAssertEqual(out.matches.count, 1,
                       "A line must not be double-counted across queries.")
        XCTAssertEqual(out.matches.first?.line, 1)
    }

    /// Zero context is the documented default — one line per match, like `grep`.
    func testScanFile_defaultContext_isOneLinePerMatch() async throws {
        try write("plain.txt", content: "a\nNEEDLE\nb\n")

        let out = try await runSearch(["NEEDLE"])
        let match = try XCTUnwrap(out.matches.first)
        XCTAssertNil(match.context_before)
        XCTAssertNil(match.context_after)
        XCTAssertEqual(match.text, "NEEDLE")
    }

    /// The whole-buffer prefilter is an optimisation, not a semantic change: a
    /// file that cannot contain the needle contributes no matches and is counted
    /// as prefiltered rather than line-scanned.
    func testScanFile_prefilterEliminatesFileWithoutPerLinePass() async throws {
        try write("nohit.txt", content: "alpha\nbeta\ngamma\n")

        let out = try await runSearch(["ZZZZZ"])
        XCTAssertTrue(out.matches.isEmpty)
        XCTAssertEqual(out.stats.filesPrefiltered, 1,
                       "A pure-ASCII miss must be eliminated by the whole-buffer scan.")
        XCTAssertEqual(out.stats.icuComparisons, 0,
                       "The prefiltered file must not reach the ICU path.")
    }
}

// ============================================================================
// MARK: - Search: the @MainActor coordinator
// ============================================================================

/// `SearchIndexCoordinator` is `@MainActor @Observable`, so it gets its own class
/// with `async` test methods — matching `SearchIndexCoordinatorTests` exactly.
/// A synchronous test method on a `@MainActor` class that constructs a
/// `@MainActor` type in its body aborts under the Xcode 26.3 protocol-witness
/// path (see CLAUDE.md "Common API pitfalls").
@MainActor
final class SearchTeamStorageCoordinatorTailTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!
    let fm = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            chmod(tempDir.appendingPathComponent("blocked").path, 0o700)
            chmod(internalDir.path, 0o700)
            try? fm.removeItem(at: tempDir)
        }
        tempDir = nil
        internalDir = nil
        try await super.tearDown()
    }

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeCoordinator() -> SearchIndexCoordinator {
        SearchIndexCoordinator(
            workFolderRoot: tempDir,
            internalDir: internalDir,
            embeddingClient: TailEmbedClient(),
            fileManager: fm,
            makeWatcher: FakeWatcherFactory.inert,
            watcherDebounce: 0.05
        )
    }

    /// A partial walk must reach `lastError`. Without it the settings card shows a
    /// clean index while whole subtrees are silently missing from it.
    func testCoordinator_walkWarnings_surfaceInLastError() async throws {
        try write("A.swift", content: "class Alpha {}")
        let blocked = tempDir.appendingPathComponent("blocked", isDirectory: true)
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        try "secret".write(to: blocked.appendingPathComponent("x.txt"),
                           atomically: true, encoding: .utf8)
        chmod(blocked.path, 0o000)
        defer { chmod(blocked.path, 0o700) }

        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()

        let error = c.lastError
        XCTAssertNotNil(error, "An unreadable subtree must not report a clean build.")
        XCTAssertTrue(error?.lowercased().contains("warning") ?? false,
                      "lastError must name the walk warnings — got: \(error ?? "nil")")
        await c.stop()
    }

    /// A clean build must leave `lastError` nil — otherwise a stale warning from a
    /// previous pass pins a permanent red state on the card.
    func testCoordinator_cleanRebuild_clearsPriorLastError() async throws {
        let blocked = tempDir.appendingPathComponent("blocked", isDirectory: true)
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        try "secret".write(to: blocked.appendingPathComponent("x.txt"),
                           atomically: true, encoding: .utf8)
        chmod(blocked.path, 0o000)

        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()
        XCTAssertNotNil(c.lastError)

        // Make the subtree readable again and force a fresh walk.
        chmod(blocked.path, 0o700)
        await c.rebuild()
        _ = await c.awaitIndex()

        XCTAssertNil(c.lastError,
                     "A clean walk must clear the prior warning — got: \(c.lastError ?? "nil")")
        await c.stop()
    }

    /// `clear()` must report a failed removal. A silent failure means the next
    /// `loadOrBuild` reads the stale copy right after the user asked to clear.
    func testCoordinator_clearFailure_surfacesInLastError() async throws {
        try write("A.swift", content: "class Alpha {}")
        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()
        XCTAssertEqual(c.fileCount, 1)

        chmod(internalDir.path, 0o500)
        defer { chmod(internalDir.path, 0o700) }

        await c.clear()

        XCTAssertNotNil(c.lastError,
                        "A failed clear must be visible, not reported as success.")
        XCTAssertNil(c.fileCount, "Observable counters still reset on a failed clear.")
        XCTAssertEqual(c.vectorIndexState, .missing)
    }

    /// `stop()` must leave no successor vector task armed, even when an FS-event
    /// refresh was already pending — the flag is cleared BEFORE any await so the
    /// in-flight task's tail sees it.
    func testCoordinator_stopWithPendingRefresh_leavesNoArmedVectorTask() async throws {
        try write("A.swift", content: "class Alpha {}")
        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()

        c._testForcePendingVectorRefresh()
        await c.stop()

        XCTAssertTrue(c._testCurrentVectorBuildTaskIsNil,
                      "stop() must drain the vector chain, not leave a successor.")
    }

    /// A refresh request that races `stop()` (a watcher callback already queued
    /// when the folder closed) must be refused rather than resurrecting the
    /// pipeline the user just turned off.
    func testCoordinator_lateRefreshAfterStop_isRefused() async throws {
        try write("A.swift", content: "class Alpha {}")
        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()
        await c.stop()

        c._testRequestVectorRefresh()

        XCTAssertTrue(c._testCurrentVectorBuildTaskIsNil,
                      "A post-stop refresh must not arm a new vector task.")
    }
}

// ============================================================================
// MARK: - Team: engine run loop, role tasks, import/export, builder, parser
// ============================================================================

/// `TeamEngine` and `MockTeamEngineStore` are both `@MainActor`. The construction
/// happens in `setUp` (dispatched on main by XCTest); every test that races the
/// run loop is `async` and waits with `await fulfillment(of:timeout:)`.
@MainActor
final class SearchTeamStorageTeamTailTests: XCTestCase {

    var sut: TeamEngine!
    var mockStore: MockTeamEngineStore!

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
        mockStore = MockTeamEngineStore()
        sut = TeamEngine(store: mockStore)
    }

    override func tearDown() async throws {
        // Always cancel the run loop and any role task — a survivor keeps
        // mutating shared state into the next class on this worker.
        sut?.stop()
        sut = nil
        mockStore = nil
        try await super.tearDown()
    }

    // MARK: Helpers

    /// Waits for the engine to reach `target`, or fails the test.
    private func awaitState(
        _ target: TeamEngineState,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        if sut.state == target { return }
        let expectation = expectation(description: "engine reaches \(target.rawValue)")
        var fulfilled = false
        sut.onStateChanged = { state in
            guard state == target, !fulfilled else { return }
            fulfilled = true
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: timeout)
        XCTAssertEqual(sut.state, target, file: file, line: line)
    }

    private func seed(
        team: Team,
        roleStatuses: [String: RoleExecutionStatus],
        steps: [StepExecution] = [],
        produced: Set<String> = []
    ) {
        mockStore.activeTeam = team
        mockStore.teamSettings = team.settings
        mockStore.producedArtifactNamesResult = produced
        mockStore.activeTask = NTMSTask(
            id: 0, title: "Tail", supervisorTask: "Do it",
            runs: [Run(id: 0, steps: steps, roleStatuses: roleStatuses, teamID: team.id)],
            preferredTeamID: team.id
        )
    }

    // ------------------------------------------------------------------
    // MARK: - TeamEngine+RunLoop
    // ------------------------------------------------------------------

    /// The run loop's very first guard. A detached engine can only fail — it has
    /// no task to read and no store to report through.
    func testRunLoop_noStore_transitionsToFailed() async {
        let detached = TeamEngine()
        let expectation = expectation(description: "failed")
        detached.onStateChanged = { if $0 == .failed { expectation.fulfill() } }
        detached.start()
        await fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(detached.state, .failed)
        detached.stop()
    }

    /// A store whose task has no runs cannot be reconciled or advanced.
    func testRunLoop_taskWithNoRuns_transitionsToFailed() async {
        let team = makeTailTeam(roles: [makeTailSupervisorRole()])
        mockStore.activeTeam = team
        mockStore.activeTask = NTMSTask(id: 0, title: "Tail", supervisorTask: "Do it", runs: [])

        sut.start()
        await awaitState(.failed)
    }

    /// The iteration cap is a safety net against a loop that can never make
    /// progress. It must PAUSE (resumable) and say why, not fail.
    func testRunLoop_iterationLimit_pausesWithActionableMessage() async {
        let supervisor = makeTailSupervisorRole()
        let worker = makeTailWorkerRole(id: "w", name: "Worker", producesArtifacts: ["Final Deliverable"])
        let team = makeTailTeam(roles: [supervisor, worker])
        // `.working` with no step keeps the loop in its wait-and-retry branch.
        seed(team: team, roleStatuses: ["w": .working])

        sut.setAutoIterationLimitForTesting(2)
        sut.start()
        await awaitState(.paused)

        XCTAssertTrue(
            mockStore.setLastErrorMessageCalls.contains { $0.contains("iteration limit") },
            "The pause must explain itself — got \(mockStore.setLastErrorMessageCalls)"
        )
        XCTAssertTrue(
            mockStore.setLastErrorMessageCalls.contains { $0.contains("Resume") },
            "The message must tell the Supervisor how to continue."
        )
    }

    /// A `.failed` role short-circuits the whole run — downstream work on a broken
    /// upstream artifact is worse than stopping.
    func testRunLoop_failedRole_transitionsToFailedImmediately() async {
        let supervisor = makeTailSupervisorRole()
        let worker = makeTailWorkerRole(id: "w", name: "Worker", producesArtifacts: ["Final Deliverable"])
        let team = makeTailTeam(roles: [supervisor, worker])
        seed(team: team, roleStatuses: ["w": .failed])

        sut.start()
        await awaitState(.failed)
    }

    /// Nothing ready, nothing working, nothing to accept: a genuine dependency
    /// dead-end. It must fail loudly and NAME the blocked roles rather than
    /// spinning to the iteration cap.
    func testRunLoop_unsatisfiableDependency_failsAndNamesTheBlockedRole() async {
        let supervisor = makeTailSupervisorRole()
        let worker = makeTailWorkerRole(
            id: "w", name: "Worker",
            requiredArtifacts: ["Never Produced"],
            producesArtifacts: ["Final Deliverable"]
        )
        let team = makeTailTeam(roles: [supervisor, worker])
        seed(team: team, roleStatuses: ["w": .idle], produced: [])

        sut.start()
        await awaitState(.failed)

        XCTAssertTrue(
            mockStore.setLastErrorMessageCalls.contains { $0.contains("Execution stalled") },
            "A deadlock must be reported — got \(mockStore.setLastErrorMessageCalls)"
        )
        XCTAssertTrue(
            mockStore.setLastErrorMessageCalls.contains { $0.contains("w") },
            "The message must name the blocked role."
        )
    }

    /// Two mutually-dependent revision roles can never unblock each other. The
    /// loop must diagnose the cycle rather than busy-loop: `startableRevisionRoleIDs`
    /// returns empty and nothing is `.working`.
    func testRunLoop_mutualRevisionDependency_failsWithCycleMessage() async {
        let supervisor = makeTailSupervisorRole()
        // A requires X and produces Y; B requires Y and produces X.
        let roleA = makeTailWorkerRole(
            id: "a", name: "A", requiredArtifacts: ["X"], producesArtifacts: ["Y"]
        )
        let roleB = makeTailWorkerRole(
            id: "b", name: "B", requiredArtifacts: ["Y"], producesArtifacts: ["X"]
        )
        let team = makeTailTeam(roles: [supervisor, roleA, roleB])
        seed(team: team, roleStatuses: ["a": .revisionRequested, "b": .revisionRequested])

        sut.start()
        await awaitState(.failed)

        XCTAssertTrue(
            mockStore.setLastErrorMessageCalls.contains { $0.contains("dependency cycle") },
            "A mutually-blocked revision set must be diagnosed — got \(mockStore.setLastErrorMessageCalls)"
        )
    }

    /// `.needsSupervisorInput` on ANY step parks the run in every supervisor mode.
    /// A parked step is only ever written at stop time, so it is always a real
    /// wait — busy-burning the iteration budget instead was the pre-fix bug.
    func testRunLoop_parkedStep_transitionsToNeedsSupervisorInputInAutonomousMode() async {
        var settings = TeamSettings.default
        settings.supervisorMode = .autonomous
        let supervisor = makeTailSupervisorRole()
        let worker = makeTailWorkerRole(id: "w", name: "Worker", producesArtifacts: ["Final Deliverable"])
        let team = makeTailTeam(roles: [supervisor, worker], settings: settings)
        let step = StepExecution(
            id: "w", role: .softwareEngineer, title: "Worker", status: .needsSupervisorInput
        )
        seed(team: team, roleStatuses: ["w": .working], steps: [step])

        sut.start()
        await awaitState(.needsSupervisorInput)
    }

    /// `markObserversComplete` is the reason an observer shows as done when the
    /// run finishes — it never executes a step of its own.
    func testMarkObserversComplete_setsEveryObserverToDone() async {
        let supervisor = makeTailSupervisorRole()
        let observer = makeTailWorkerRole(
            id: "obs", name: "Observer", requiredArtifacts: [], producesArtifacts: []
        )
        XCTAssertTrue(observer.isObserver, "Fixture precondition: no inputs, no outputs.")
        let team = makeTailTeam(roles: [supervisor, observer])
        seed(team: team, roleStatuses: ["obs": .idle])

        await sut.markObserversComplete()

        XCTAssertTrue(
            mockStore.updateRoleStatusCalls.contains { $0.roleID == "obs" && $0.status == .done },
            "Observers must be settled to .done — got \(mockStore.updateRoleStatusCalls)"
        )
    }

    /// Chat-mode teams never auto-complete: their advisory roles run until the
    /// Supervisor finishes them.
    func testAllRolesComplete_chatMode_alwaysFalse() {
        let supervisor = makeTailSupervisorRole(requiredArtifacts: [])
        let advisory = makeTailWorkerRole(
            id: "a", name: "Advisor",
            requiredArtifacts: ["Supervisor Task"], producesArtifacts: []
        )
        let team = makeTailTeam(roles: [supervisor, advisory])
        XCTAssertTrue(team.isChatMode, "Fixture precondition: Supervisor requires nothing.")

        XCTAssertFalse(
            sut.allRolesComplete(roleStatuses: ["a": .done], roles: team.roles, isChatMode: true),
            "Chat mode must hard-return false regardless of role statuses."
        )
        XCTAssertTrue(
            sut.allRolesComplete(roleStatuses: ["a": .done], roles: team.roles, isChatMode: false),
            "Outside chat mode the same statuses are complete."
        )
    }

    // ------------------------------------------------------------------
    // MARK: - TeamEngine+RoleTasks
    // ------------------------------------------------------------------

    /// `acceptanceGate()` needs a task; without one it must return nil so the
    /// reconcile pass skips rather than inventing a default gate.
    func testAcceptanceGate_noActiveTask_returnsNil() {
        mockStore.activeTask = nil
        XCTAssertNil(sut.acceptanceGate())
    }

    func testAcceptanceGate_withTask_derivesModeFromTeamSettings() {
        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .finalOnly
        let team = makeTailTeam(roles: [makeTailSupervisorRole()], settings: settings)
        seed(team: team, roleStatuses: [:])

        let gate = sut.acceptanceGate()
        XCTAssertEqual(gate?.mode, .finalOnly)
    }

    /// `.settle` writes; anything else must not. A write on `.inFlight` would
    /// stamp a status while the step is still mid-flight.
    func testReconcileRole_settleWrites_inFlightDoesNot() async {
        let team = makeTailTeam(roles: [makeTailSupervisorRole()])
        seed(team: team, roleStatuses: ["w": .working])
        let gate = AcceptanceService.Gate(mode: .finalOnly)

        let settled = await sut.reconcileRole(
            roleID: "w", roleStatus: .working, stepStatus: .done, gate: gate
        )
        XCTAssertTrue(settled, "A finished step under a working role must settle.")
        XCTAssertEqual(mockStore.updateRoleStatusCalls.count, 1)

        mockStore.updateRoleStatusCalls.removeAll()
        let inFlight = await sut.reconcileRole(
            roleID: "w", roleStatus: .working, stepStatus: .running, gate: gate
        )
        XCTAssertFalse(inFlight, "A running step must not be settled.")
        XCTAssertTrue(mockStore.updateRoleStatusCalls.isEmpty)
    }

    /// `handleRoleCompleted` must be idempotent — `waitForStepCompletion` and the
    /// run loop's reconcile pass can both reach it for the same role.
    func testHandleRoleCompleted_calledTwice_writesOnlyOnce() async {
        let supervisor = makeTailSupervisorRole()
        let worker = makeTailWorkerRole(id: "w", name: "Worker", producesArtifacts: ["Final Deliverable"])
        var settings = TeamSettings.default
        settings.defaultAcceptanceMode = .finalOnly
        let team = makeTailTeam(roles: [supervisor, worker], settings: settings)
        seed(team: team, roleStatuses: ["w": .working])

        await sut.handleRoleCompleted(roleID: "w")
        let afterFirst = mockStore.updateRoleStatusCalls.count
        XCTAssertEqual(afterFirst, 1)
        XCTAssertEqual(mockStore.updateRoleStatusCalls.first?.status, .done)

        // The mock mirrors the write back into `activeTask`, so the second call
        // sees `.done` — which `RoleStepReconciler` answers `.noAction` for.
        await sut.handleRoleCompleted(roleID: "w")
        XCTAssertEqual(mockStore.updateRoleStatusCalls.count, afterFirst,
                       "A second completion must be a no-op, not a re-write.")
    }

    /// A role whose step cannot be created is a configuration failure, and the
    /// role must land `.failed` rather than sitting `.working` forever.
    func testStartRoles_stepCreationReturnsNil_marksRoleFailed() async {
        let supervisor = makeTailSupervisorRole()
        let worker = makeTailWorkerRole(id: "w", name: "Worker", producesArtifacts: ["Final Deliverable"])
        let team = makeTailTeam(roles: [supervisor, worker])
        seed(team: team, roleStatuses: ["w": .ready], produced: ["Supervisor Task"])
        // findOrCreateStepResults deliberately left empty → nil.

        await sut.startRoles(roleIDs: ["w"])

        // The spawned task is unstructured; poll briefly for its effect.
        for _ in 0..<50 where !mockStore.updateRoleStatusCalls.contains(where: { $0.status == .failed }) {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(
            mockStore.updateRoleStatusCalls.contains { $0.roleID == "w" && $0.status == .working },
            "The role is marked working before its step is attempted."
        )
        XCTAssertTrue(
            mockStore.updateRoleStatusCalls.contains { $0.roleID == "w" && $0.status == .failed },
            "A nil step id must fail the role — got \(mockStore.updateRoleStatusCalls)"
        )
    }

    /// The same failure on the REVISION path additionally reports to the UI —
    /// a revision that silently never starts is invisible to the Supervisor.
    func testStartRevisionRoles_stepCreationFails_reportsToUI() async {
        let supervisor = makeTailSupervisorRole()
        let worker = makeTailWorkerRole(id: "w", name: "Worker", producesArtifacts: ["Final Deliverable"])
        let team = makeTailTeam(roles: [supervisor, worker])
        seed(team: team, roleStatuses: ["w": .revisionRequested])

        let started = await sut.startRevisionRoles(roleStatuses: ["w": .revisionRequested])
        XCTAssertEqual(started, 1, "An unblocked revision role is startable.")

        for _ in 0..<50 where mockStore.setLastErrorMessageCalls.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(
            mockStore.setLastErrorMessageCalls.contains { $0.contains("Revision failed") },
            "A revision that cannot start must surface — got \(mockStore.setLastErrorMessageCalls)"
        )
    }

    /// The happy revision path resets the step before re-running it, so the role
    /// re-executes against fresh state rather than its stale `.done` step.
    func testStartRevisionRoles_resetsStepBeforeRunning() async {
        let supervisor = makeTailSupervisorRole()
        let worker = makeTailWorkerRole(id: "w", name: "Worker", producesArtifacts: ["Final Deliverable"])
        let team = makeTailTeam(roles: [supervisor, worker])
        seed(team: team, roleStatuses: ["w": .revisionRequested])
        mockStore.findOrCreateStepResults = ["w": "w"]
        mockStore.stepStatusResults = ["w": .done]

        _ = await sut.startRevisionRoles(roleStatuses: ["w": .revisionRequested])

        for _ in 0..<50 where mockStore.runStepCalls.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(mockStore.resetStepForRevisionCalls, ["w"])
        XCTAssertEqual(mockStore.prepareStepCalls, ["w"])
        XCTAssertEqual(mockStore.runStepCalls, ["w"])
    }

    /// A step that failed must fail its role — the run loop reads role statuses,
    /// not step statuses, when deciding to abort.
    func testWaitForStepCompletion_failedStep_marksRoleFailed() async {
        let team = makeTailTeam(roles: [makeTailSupervisorRole()])
        seed(team: team, roleStatuses: ["w": .working])
        mockStore.stepStatusResults = ["w": .failed]

        await sut.waitForStepCompletion(stepID: "w", roleID: "w")

        XCTAssertTrue(
            mockStore.updateRoleStatusCalls.contains { $0.roleID == "w" && $0.status == .failed },
            "A failed step must fail its role."
        )
    }

    /// An unknown step id is a torn state, not a failure to report — return
    /// quietly so the loop's own reconcile pass decides.
    func testWaitForStepCompletion_unknownStep_returnsWithoutWriting() async {
        let team = makeTailTeam(roles: [makeTailSupervisorRole()])
        seed(team: team, roleStatuses: ["w": .working])
        mockStore.stepStatusResults = [:]

        await sut.waitForStepCompletion(stepID: "missing", roleID: "w")

        XCTAssertTrue(mockStore.updateRoleStatusCalls.isEmpty)
    }

    /// A parked step ends the wait without a write — the run loop, not this
    /// helper, owns the `.needsSupervisorInput` transition.
    func testWaitForStepCompletion_parkedStep_returnsWithoutWriting() async {
        let team = makeTailTeam(roles: [makeTailSupervisorRole()])
        seed(team: team, roleStatuses: ["w": .working])
        mockStore.stepStatusResults = ["w": .needsSupervisorInput]

        await sut.waitForStepCompletion(stepID: "w", roleID: "w")

        XCTAssertTrue(mockStore.updateRoleStatusCalls.isEmpty)
    }

    // MARK: startableRevisionRoleIDs (pure)

    func testStartableRevisionRoleIDs_noRevisionRoles_returnsEmpty() {
        let roles = [
            makeTailSupervisorRole(),
            makeTailWorkerRole(id: "a", name: "A", producesArtifacts: ["Y"]),
        ]
        XCTAssertTrue(
            TeamEngine.startableRevisionRoleIDs(roleStatuses: ["a": .done], roles: roles).isEmpty
        )
    }

    /// Independent revision roles start together — serialization is per-chain,
    /// not global.
    func testStartableRevisionRoleIDs_independentRoles_bothStartable() {
        let roles = [
            makeTailSupervisorRole(),
            makeTailWorkerRole(id: "a", name: "A",
                               requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Y"]),
            makeTailWorkerRole(id: "b", name: "B",
                               requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Z"]),
        ]
        let startable = TeamEngine.startableRevisionRoleIDs(
            roleStatuses: ["a": .revisionRequested, "b": .revisionRequested], roles: roles
        )
        XCTAssertEqual(Set(startable), ["a", "b"])
    }

    /// A downstream revision role waits for its upstream, so it re-runs against
    /// the FRESH artifact rather than the stale one.
    func testStartableRevisionRoleIDs_downstreamWaitsForUpstreamRevision() {
        let roles = [
            makeTailSupervisorRole(),
            makeTailWorkerRole(id: "up", name: "Up",
                               requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Mid"]),
            makeTailWorkerRole(id: "down", name: "Down",
                               requiredArtifacts: ["Mid"], producesArtifacts: ["Final Deliverable"]),
        ]
        let startable = TeamEngine.startableRevisionRoleIDs(
            roleStatuses: ["up": .revisionRequested, "down": .revisionRequested], roles: roles
        )
        XCTAssertEqual(startable, ["up"], "Only the chain root may start.")
    }

    /// A `.working` upstream also blocks — it is still producing the artifact the
    /// downstream revision would consume.
    func testStartableRevisionRoleIDs_workingUpstreamBlocksDownstream() {
        let roles = [
            makeTailSupervisorRole(),
            makeTailWorkerRole(id: "up", name: "Up",
                               requiredArtifacts: ["Supervisor Task"], producesArtifacts: ["Mid"]),
            makeTailWorkerRole(id: "down", name: "Down",
                               requiredArtifacts: ["Mid"], producesArtifacts: ["Final Deliverable"]),
        ]
        let startable = TeamEngine.startableRevisionRoleIDs(
            roleStatuses: ["up": .working, "down": .revisionRequested], roles: roles
        )
        XCTAssertTrue(startable.isEmpty)
    }

    // MARK: findReadyRoles

    /// Observers execute no steps and the Supervisor is the user — neither can
    /// ever be "ready".
    func testFindReadyRoles_excludesObserversAndSupervisor() {
        let supervisor = makeTailSupervisorRole(id: "sup")
        let observer = makeTailWorkerRole(
            id: "obs", name: "Obs", requiredArtifacts: [], producesArtifacts: []
        )
        let worker = makeTailWorkerRole(id: "w", name: "W", producesArtifacts: ["Final Deliverable"])
        let roles = [supervisor, observer, worker]

        let ready = sut.findReadyRoles(
            roles: roles,
            producedArtifacts: ["Supervisor Task"],
            roleStatuses: ["sup": .idle, "obs": .idle, "w": .idle]
        )
        XCTAssertEqual(ready, ["w"], "Only the real worker is startable — got \(ready)")
    }

    /// Every in-progress or terminal status excludes a role from a fresh start.
    func testFindReadyRoles_excludesEveryNonIdleNonReadyStatus() {
        let supervisor = makeTailSupervisorRole(id: "sup")
        let worker = makeTailWorkerRole(id: "w", name: "W", producesArtifacts: ["Final Deliverable"])
        let roles = [supervisor, worker]

        for status in [RoleExecutionStatus.working, .done, .accepted,
                       .needsAcceptance, .failed, .skipped, .revisionRequested] {
            let ready = sut.findReadyRoles(
                roles: roles,
                producedArtifacts: ["Supervisor Task"],
                roleStatuses: ["w": status]
            )
            XCTAssertTrue(ready.isEmpty, "\(status) must not be re-started — got \(ready)")
        }

        for status in [RoleExecutionStatus.idle, .ready] {
            let ready = sut.findReadyRoles(
                roles: roles,
                producedArtifacts: ["Supervisor Task"],
                roleStatuses: ["w": status]
            )
            XCTAssertEqual(ready, ["w"], "\(status) must remain startable.")
        }
    }

    // ------------------------------------------------------------------
    // MARK: - TeamImportExportService
    // ------------------------------------------------------------------

    private func makeExportableTeam() -> Team {
        var settings = TeamSettings.default
        settings.hierarchy = TeamHierarchy(reportsTo: ["worker-id": "sup-id"])
        settings.meetingCoordinatorRoleID = "worker-id"
        settings.invitableRoles = ["worker-id"]
        settings.acceptanceCheckpoints = ["worker-id"]

        var team = Team(
            name: "Origin",
            templateID: "faang",
            roles: [
                makeTailSupervisorRole(id: "sup-id"),
                makeTailWorkerRole(id: "worker-id", name: "Worker",
                                   producesArtifacts: ["Final Deliverable"]),
            ],
            artifacts: [
                TeamArtifact(id: "final_deliverable", name: "Final Deliverable",
                             icon: "doc", mimeType: "text/markdown",
                             description: "The output", isSystemArtifact: true,
                             systemArtifactName: "Final Deliverable"),
            ],
            settings: settings,
            graphLayout: TeamGraphLayout(),
            deletedSystemRoleIDs: ["ghost-role"],
            deletedSystemArtifactIDs: ["ghost-artifact"]
        )
        team.graphLayout.hiddenRoleIDs = ["worker-id"]
        return team
    }

    /// Both deletion lists describe a template. An import has no template, so
    /// keeping them would leave tombstones pointing at nothing.
    func testImportTeam_clearsTombstoneListsAndTemplateID() throws {
        let data = try TeamImportExportService.exportTeam(makeExportableTeam())
        let imported = try TeamImportExportService.importTeam(from: data, newName: "Copy")

        XCTAssertNil(imported.templateID,
                     "An import is a CUSTOM team — reconcile must never claim it.")
        XCTAssertTrue(imported.deletedSystemRoleIDs.isEmpty)
        XCTAssertTrue(imported.deletedSystemArtifactIDs.isEmpty)
    }

    /// With no template there are no system artifacts, and ids must be re-derived
    /// from the (possibly renamed) artifact names.
    func testImportTeam_artifactsBecomeCustomWithRegeneratedIDs() throws {
        let data = try TeamImportExportService.exportTeam(makeExportableTeam())
        let imported = try TeamImportExportService.importTeam(from: data, newName: "Copy")

        let artifact = try XCTUnwrap(imported.artifacts.first)
        XCTAssertFalse(artifact.isSystemArtifact,
                       "No template ⇒ nothing is a system artifact.")
        XCTAssertEqual(artifact.id, Artifact.slugify(artifact.name))
    }

    /// Every stored role reference has to follow the regenerated ids, or the
    /// imported team's hierarchy, coordinator and checkpoints all dangle.
    func testImportTeam_remapsEverySettingsRoleReference() throws {
        let origin = makeExportableTeam()
        let data = try TeamImportExportService.exportTeam(origin)
        let imported = try TeamImportExportService.importTeam(from: data, newName: "Copy")

        let newWorkerID = try XCTUnwrap(imported.roles.first { $0.name == "Worker" }?.id)
        let newSupervisorID = try XCTUnwrap(imported.roles.first { $0.isSupervisor }?.id)
        XCTAssertNotEqual(newWorkerID, "worker-id", "Ids must be regenerated.")

        XCTAssertEqual(imported.settings.hierarchy.reportsTo[newWorkerID], newSupervisorID)
        XCTAssertNil(imported.settings.hierarchy.reportsTo["worker-id"],
                     "The stale key must not survive.")
        XCTAssertEqual(imported.settings.meetingCoordinatorRoleID, newWorkerID)
        XCTAssertEqual(imported.settings.invitableRoles, [newWorkerID])
        XCTAssertEqual(imported.settings.acceptanceCheckpoints, [newWorkerID])
        XCTAssertEqual(imported.graphLayout.hiddenRoleIDs, [newWorkerID])
    }

    /// `systemRoleID` is deliberately KEPT on a whole-team import: `isSupervisor`
    /// is derived from it, and clearing it would leave the team with no
    /// Supervisor — taking `isChatMode` and the hierarchy wiring with it.
    func testImportTeam_keepsSystemRoleIDSoTheSupervisorSurvives() throws {
        let data = try TeamImportExportService.exportTeam(makeExportableTeam())
        let imported = try TeamImportExportService.importTeam(from: data, newName: "Copy")

        let supervisor = try XCTUnwrap(imported.roles.first { $0.isSupervisor })
        XCTAssertEqual(supervisor.systemRoleID, "supervisor")
        XCTAssertFalse(supervisor.isSystemRole,
                       "isSystemRole is what gates the reconcile overwrite — it must be off.")
    }

    /// The single-role import DOES clear `systemRoleID` — it lands in a team that
    /// already has its own Supervisor.
    func testImportRole_clearsSystemRoleIDUnlikeWholeTeamImport() throws {
        let role = makeTailSupervisorRole(id: "orig")
        let data = try TeamImportExportService.exportRole(role)
        var target = makeTailTeam(roles: [makeTailSupervisorRole(id: "existing")])

        try TeamImportExportService.importRole(from: data, into: &target)

        let imported = try XCTUnwrap(target.roles.last)
        XCTAssertNil(imported.systemRoleID,
                     "A role imported INTO a team must not become a second Supervisor.")
        XCTAssertFalse(imported.isSystemRole)
    }

    func testImportArtifact_unsupportedVersion_throws() throws {
        let artifact = TeamArtifact(
            id: "a", name: "A", icon: "doc", mimeType: "text/markdown", description: ""
        )
        let data = try TeamImportExportService.exportArtifact(artifact)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("artifact export is not a JSON object")
        }
        obj["version"] = 99
        let bumped = try JSONSerialization.data(withJSONObject: obj)

        var team = makeTailTeam(roles: [])
        XCTAssertThrowsError(
            try TeamImportExportService.importArtifact(from: bumped, into: &team)
        ) { error in
            guard case ImportExportError.unsupportedVersion(let v) = error else {
                return XCTFail("Expected .unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(v, 99)
        }
        XCTAssertTrue(team.artifacts.isEmpty, "A rejected import must not mutate the team.")
    }

    /// A round trip must be lossless in role/artifact COUNT even though every id
    /// is regenerated.
    func testExportThenImportTeam_preservesRosterShape() throws {
        let origin = makeExportableTeam()
        let data = try TeamImportExportService.exportTeam(origin)
        let imported = try TeamImportExportService.importTeam(from: data)

        XCTAssertEqual(imported.roles.count, origin.roles.count)
        XCTAssertEqual(imported.artifacts.count, origin.artifacts.count)
        XCTAssertEqual(imported.name, "Origin (Imported)",
                       "The default rename must be applied when no name is given.")
        XCTAssertEqual(imported.id, NTMSID.from(name: "Origin (Imported)"))
    }

    // MARK: suggestedFileName

    /// Punctuation is dropped, spaces become underscores, digits survive.
    func testSuggestedFileName_dropsPunctuationAndKeepsDigits() {
        let role = makeTailWorkerRole(id: "x", name: "Tech-Lead #2")
        XCTAssertEqual(TeamImportExportService.suggestedFileName(for: role), "techlead_2_role.json")
    }

    /// The sanitizer's character class is ASCII-only, so a fully non-ASCII name
    /// reduces to the suffix. Worth pinning because `Artifact.slugify` — the
    /// sibling name-normaliser — uses `isLetter` and KEEPS Cyrillic, so the two
    /// deliberately disagree and neither should be "fixed" to match the other.
    func testSuggestedFileName_nonASCIIName_reducesToSuffix() {
        let role = makeTailWorkerRole(id: "x", name: "Ярослав")
        XCTAssertEqual(TeamImportExportService.suggestedFileName(for: role), "_role.json")
        XCTAssertEqual(Artifact.slugify("Ярослав"), "ярослав",
                       "slugify keeps non-ASCII letters — the two normalisers differ by design.")
    }

    func testSuggestedFileName_emptyName_stillProducesAValidFileName() {
        let team = makeTailTeam(roles: [], name: "")
        XCTAssertEqual(TeamImportExportService.suggestedFileName(for: team), "_team.json")
    }

    func testSuggestedFileName_artifactSpacesBecomeUnderscores() {
        let artifact = TeamArtifact(
            id: "x", name: "Release Notes", icon: "doc",
            mimeType: "text/markdown", description: ""
        )
        XCTAssertEqual(
            TeamImportExportService.suggestedFileName(for: artifact), "release_notes_artifact.json"
        )
    }

    // ------------------------------------------------------------------
    // MARK: - GeneratedTeamBuilder
    // ------------------------------------------------------------------

    private func makeSeedTeam() -> Team {
        makeTailTeam(roles: [
            makeTailSupervisorRole(id: "sup"),
            makeTailWorkerRole(id: "ready", name: "Ready",
                               requiredArtifacts: ["Supervisor Task"],
                               producesArtifacts: ["Mid"]),
            makeTailWorkerRole(id: "blocked", name: "Blocked",
                               requiredArtifacts: ["Mid"],
                               producesArtifacts: ["Final Deliverable"]),
        ])
    }

    /// Supervisor is already done, a role whose inputs exist is `.ready`, one
    /// whose inputs don't is `.idle`.
    func testSeedRoleStatuses_assignsPerDependencySatisfaction() {
        var run = Run(id: 0)
        GeneratedTeamBuilder.seedRoleStatuses(
            for: makeSeedTeam(), existingRun: &run, producedArtifacts: ["Supervisor Task"]
        )

        XCTAssertEqual(run.roleStatuses["sup"], .done)
        XCTAssertEqual(run.roleStatuses["ready"], .ready)
        XCTAssertEqual(run.roleStatuses["blocked"], .idle)
    }

    /// A pre-set entry (notably the Supervisor's `.done` from `runTeamGeneration`)
    /// must survive — seeding is additive, not authoritative.
    func testSeedRoleStatuses_preservesPreExistingEntries() {
        var run = Run(id: 0, roleStatuses: ["ready": .working])
        GeneratedTeamBuilder.seedRoleStatuses(
            for: makeSeedTeam(), existingRun: &run, producedArtifacts: ["Supervisor Task"]
        )

        XCTAssertEqual(run.roleStatuses["ready"], .working,
                       "An existing status must not be clobbered by seeding.")
        XCTAssertEqual(run.roleStatuses["blocked"], .idle)
    }

    /// A role with NO required artifacts is vacuously satisfied — `allSatisfy`
    /// over an empty list is true — so it seeds `.ready`.
    func testSeedRoleStatuses_roleWithNoDependencies_isReady() {
        let team = makeTailTeam(roles: [
            makeTailSupervisorRole(id: "sup"),
            makeTailWorkerRole(id: "free", name: "Free",
                               requiredArtifacts: [], producesArtifacts: ["Final Deliverable"]),
        ])
        var run = Run(id: 0)
        GeneratedTeamBuilder.seedRoleStatuses(
            for: team, existingRun: &run, producedArtifacts: []
        )
        XCTAssertEqual(run.roleStatuses["free"], .ready)
    }

    /// "Auto / Auto" must be a true identity — including no `updatedAt` bump, so
    /// a settings pass that changes nothing cannot look like an edit.
    func testApplyForcedDefaults_bothNil_leavesTeamByteIdentical() {
        let team = makeTailTeam(roles: [makeTailSupervisorRole()])
        let original = GeneratedTeamBuilder.BuildResult(team: team, warnings: ["w"])

        let out = GeneratedTeamBuilder.applyForcedDefaults(
            to: original, supervisorMode: nil, acceptanceMode: nil
        )

        XCTAssertEqual(out.team.updatedAt, team.updatedAt,
                       "Auto/Auto must not touch updatedAt.")
        XCTAssertEqual(out.team.settings.supervisorMode, team.settings.supervisorMode)
        XCTAssertEqual(out.warnings, ["w"], "Warnings must pass through untouched.")
    }

    func testApplyForcedDefaults_partialOverride_appliesOnlyTheGivenOne() {
        var settings = TeamSettings.default
        settings.supervisorMode = .manual
        settings.defaultAcceptanceMode = .afterEachRole
        let team = makeTailTeam(roles: [makeTailSupervisorRole()], settings: settings)
        let original = GeneratedTeamBuilder.BuildResult(team: team, warnings: [])

        let out = GeneratedTeamBuilder.applyForcedDefaults(
            to: original, supervisorMode: .autonomous, acceptanceMode: nil
        )

        XCTAssertEqual(out.team.settings.supervisorMode, .autonomous)
        XCTAssertEqual(out.team.settings.defaultAcceptanceMode, .afterEachRole,
                       "A nil argument means Auto — leave the existing value alone.")
    }

    // ------------------------------------------------------------------
    // MARK: - TeamConfigParser
    // ------------------------------------------------------------------

    /// A fenced block is a stronger signal of intent than the first balanced
    /// object, because models wrap JSON in explanatory prose.
    func testExtractJSONObject_prefersFencedBlockOverSurroundingProse() {
        let text = """
        Sure! Here is the team {not: this one}
        
        ```json
        {"name": "Real Team"}
        ```
        
        Let me know if you want changes.
        """
        let extracted = TeamConfigParser.extractJSONObject(from: text)
        XCTAssertEqual(extracted, "{\"name\": \"Real Team\"}")
    }

    func testExtractJSONObject_unfencedObject_isStillFound() {
        let extracted = TeamConfigParser.extractJSONObject(
            from: "prefix {\"a\": 1} suffix"
        )
        XCTAssertEqual(extracted, "{\"a\": 1}")
    }

    func testExtractJSONObject_noBraceAtAll_returnsNil() {
        XCTAssertNil(TeamConfigParser.extractJSONObject(from: "I cannot help with that."))
        XCTAssertNil(TeamConfigParser.extractJSONObject(from: ""))
    }

    /// Braces inside string literals must not perturb the depth counter.
    func testExtractJSONObject_bracesInsideStringsDoNotUnbalance() {
        let extracted = TeamConfigParser.extractJSONObject(
            from: "{\"prompt\": \"use {curly} braces\"} trailing"
        )
        XCTAssertEqual(extracted, "{\"prompt\": \"use {curly} braces\"}")
    }

    /// A decoding failure has to name the field. A bare `localizedDescription`
    /// ("The data couldn’t be read") tells the Supervisor nothing about which key
    /// the model got wrong.
    func testDescribeDecodingError_keyNotFound_namesTheMissingKey() {
        struct Probe: Codable { let requiredField: String }
        let data = Data("{}".utf8)
        do {
            _ = try JSONDecoder().decode(Probe.self, from: data)
            XCTFail("Expected a decode failure")
        } catch {
            let described = TeamConfigParser.describeDecodingError(error)
            XCTAssertTrue(described.contains("requiredField"),
                          "The message must name the key — got: \(described)")
            XCTAssertTrue(described.contains("Key not found"))
        }
    }

    func testDescribeDecodingError_typeMismatch_namesThePath() {
        struct Probe: Codable { let count: Int }
        let data = Data("{\"count\": \"not a number\"}".utf8)
        do {
            _ = try JSONDecoder().decode(Probe.self, from: data)
            XCTFail("Expected a decode failure")
        } catch {
            let described = TeamConfigParser.describeDecodingError(error)
            XCTAssertTrue(described.contains("Type mismatch"),
                          "Got: \(described)")
            XCTAssertTrue(described.contains("count"),
                          "The coding path must be reported — got: \(described)")
        }
    }

    /// Non-`DecodingError` values fall through to `localizedDescription` rather
    /// than being dressed up as a schema problem.
    func testDescribeDecodingError_nonDecodingError_fallsThrough() {
        struct TailPlainError: LocalizedError {
            var errorDescription: String? { "a plain failure" }
        }
        XCTAssertEqual(
            TeamConfigParser.describeDecodingError(TailPlainError()), "a plain failure"
        )
    }
}

// ============================================================================
// MARK: - Storage: repository bootstrap, reconcile, task ops, step artifacts
// ============================================================================

/// `NTMSRepository` is a `nonisolated struct`, so this class stays nonisolated and
/// drives it directly against a temp folder.
final class SearchTeamStorageStorageTailTests: XCTestCase {

    var sut: NTMSRepository!
    var tempDir: URL!
    var root: URL!
    private let fm = FileManager.default
    private var paths: NTMSPaths { NTMSPaths(workFolderRoot: root) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        MonotonicClock.shared.reset()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        root = tempDir.appendingPathComponent("proj", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        sut = NTMSRepository()
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        sut = nil
        tempDir = nil
        root = nil
        try super.tearDownWithError()
    }

    // ------------------------------------------------------------------
    // MARK: - NTMSRepository+StepArtifacts
    // ------------------------------------------------------------------

    /// `ancestorChain` must tolerate a folder with no `tasks_index.json` at all —
    /// that is exactly the shape a unit test (or a half-bootstrapped folder) has,
    /// and treating it as top-level keeps artifact writing working.
    func testPersistStepArtifactFile_noTasksIndex_writesAtTopLevelPath() throws {
        XCTAssertFalse(fm.fileExists(atPath: paths.tasksIndexJSON.path),
                       "Precondition: no index on a bare folder.")

        let rel = try sut.persistStepArtifactFile(
            at: root, taskID: 7, runID: 0, roleID: "engineer",
            artifactName: "Release Notes", content: "shipped"
        )

        XCTAssertTrue(rel.hasSuffix("artifact_release_notes.md"),
                      "The file name must be the slugified artifact name — got \(rel)")
        XCTAssertFalse(rel.contains("subtasks"),
                       "An unknown task id behaves as top-level.")
        let onDisk = root.appendingPathComponent(".nanoteams").appendingPathComponent(rel)
        XCTAssertEqual(try String(contentsOf: onDisk, encoding: .utf8), "shipped")
    }

    /// Artifact bodies are model output, so the Harmony/`<|...|>` token cleaner
    /// runs on the way to disk — a stored artifact must never carry them.
    func testPersistStepArtifactFile_stripsModelTokensBeforeWriting() throws {
        let rel = try sut.persistStepArtifactFile(
            at: root, taskID: 1, runID: 0, roleID: "engineer",
            artifactName: "Notes", content: "before<|channel|>after"
        )

        let onDisk = root.appendingPathComponent(".nanoteams").appendingPathComponent(rel)
        let written = try String(contentsOf: onDisk, encoding: .utf8)
        XCTAssertFalse(written.contains("<|channel|>"),
                       "Model tokens must be cleaned — got: \(written)")
        XCTAssertTrue(written.contains("before"))
        XCTAssertTrue(written.contains("after"))
    }

    /// The binary side-car sits beside the markdown original under the same slug,
    /// differing only in extension — that is how the UI finds the pair.
    func testPersistStepArtifactBinary_writesSideCarBesideMarkdown() throws {
        let mdRel = try sut.persistStepArtifactFile(
            at: root, taskID: 1, runID: 0, roleID: "engineer",
            artifactName: "Design Spec", content: "# Spec"
        )
        let payload = Data([0x25, 0x50, 0x44, 0x46])
        let binRel = try sut.persistStepArtifactBinary(
            at: root, taskID: 1, runID: 0, roleID: "engineer",
            artifactName: "Design Spec", data: payload, fileExtension: "pdf"
        )

        XCTAssertEqual(
            (mdRel as NSString).deletingPathExtension,
            (binRel as NSString).deletingPathExtension,
            "The side-car must share the markdown's slug."
        )
        XCTAssertTrue(binRel.hasSuffix(".pdf"))
        let onDisk = root.appendingPathComponent(".nanoteams").appendingPathComponent(binRel)
        XCTAssertEqual(try Data(contentsOf: onDisk), payload,
                       "Binary bytes must round-trip verbatim.")
    }

    /// A delegated child's artifacts must land under its parent's `subtasks/`
    /// subtree, resolved from the index — not flat beside the parent.
    func testPersistStepArtifactFile_childTask_nestsUnderParentSubtasks() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let parent = try sut.createTask(at: root, title: "Parent", supervisorTask: "p")
        let child = try sut.createTask(
            at: root, title: "Child", supervisorTask: "c",
            parentTaskID: parent.taskID, parentRoleID: "coding-agent",
            delegationDepth: 1, makeActive: false
        )

        let rel = try sut.persistStepArtifactFile(
            at: root, taskID: child.taskID, runID: 0, roleID: "engineer",
            artifactName: "Result", content: "done"
        )

        XCTAssertTrue(rel.contains("subtasks"),
                      "A child artifact must nest under the parent — got \(rel)")
        XCTAssertTrue(rel.contains("tasks/\(parent.taskID)"),
                      "The parent's id must appear in the path — got \(rel)")
        let onDisk = root.appendingPathComponent(".nanoteams").appendingPathComponent(rel)
        XCTAssertTrue(fm.fileExists(atPath: onDisk.path))
    }

    /// Two artifacts whose names slugify identically share a file. Pinned so the
    /// collision is a known property of name-derived ids rather than a surprise.
    func testPersistStepArtifactFile_namesSlugifyingAlike_shareOneFile() throws {
        let a = try sut.persistStepArtifactFile(
            at: root, taskID: 1, runID: 0, roleID: "r",
            artifactName: "Release Notes", content: "first"
        )
        let b = try sut.persistStepArtifactFile(
            at: root, taskID: 1, runID: 0, roleID: "r",
            artifactName: "release notes", content: "second"
        )
        XCTAssertEqual(a, b, "Slugified names collide by design.")
        let onDisk = root.appendingPathComponent(".nanoteams").appendingPathComponent(b)
        XCTAssertEqual(try String(contentsOf: onDisk, encoding: .utf8), "second",
                       "The later write wins.")
    }

    // ------------------------------------------------------------------
    // MARK: - NTMSRepository+TaskOperations
    // ------------------------------------------------------------------

    func testLoadTask_unknownID_throwsTaskNotFound() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)

        XCTAssertThrowsError(try sut.loadTask(at: root, taskID: 999)) { error in
            guard case NTMSRepositoryError.taskNotFound(let id) = error else {
                return XCTFail("Expected .taskNotFound, got \(error)")
            }
            XCTAssertEqual(id, 999)
        }
    }

    /// Writing a task that was never created must fail loudly. A silent create
    /// here would resurrect a deleted task from a stale in-memory copy.
    func testUpdateTaskOnly_taskNeverCreated_throwsTaskNotFound() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let orphan = NTMSTask(id: 4242, title: "Ghost", supervisorTask: "boo")

        XCTAssertThrowsError(try sut.updateTaskOnly(at: root, task: orphan)) { error in
            guard case NTMSRepositoryError.taskNotFound(let id) = error else {
                return XCTFail("Expected .taskNotFound, got \(error)")
            }
            XCTAssertEqual(id, 4242)
        }
    }

    /// The tasks index must move in lockstep with `task.json`, or every
    /// background-mutating task shows a stale status in the sidebar.
    func testUpdateTaskOnly_refreshesTheIndexSummary() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let created = try sut.createTask(at: root, title: "Original", supervisorTask: "s")

        var task = try sut.loadTask(at: root, taskID: created.taskID)
        task.title = "Renamed"
        try sut.updateTaskOnly(at: root, task: task)

        let index = try AtomicJSONStore().read(TasksIndex.self, from: paths.tasksIndexJSON)
        let summary = try XCTUnwrap(index.tasks.first { $0.id == created.taskID })
        XCTAssertEqual(summary.title, "Renamed",
                       "The index summary must follow the task, not lag it.")

        let reloaded = try sut.loadTask(at: root, taskID: created.taskID)
        XCTAssertEqual(reloaded.title, "Renamed")
    }

    /// A child task must never steal focus from the Supervisor's parent.
    func testCreateTask_childWithMakeActiveFalse_doesNotMoveActiveTaskID() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let parent = try sut.createTask(at: root, title: "Parent", supervisorTask: "p")

        let before = try AtomicJSONStore().read(WorkFolderState.self, from: paths.workFolderJSON)
        XCTAssertEqual(before.activeTaskID, parent.taskID)

        _ = try sut.createTask(
            at: root, title: "Child", supervisorTask: "c",
            parentTaskID: parent.taskID, parentRoleID: "agent",
            delegationDepth: 1, makeActive: false
        )

        let after = try AtomicJSONStore().read(WorkFolderState.self, from: paths.workFolderJSON)
        XCTAssertEqual(after.activeTaskID, parent.taskID,
                       "A delegated child must leave the Supervisor on the parent.")
    }

    /// Ids come from a persisted counter, so they are sequential and never reused.
    func testCreateTask_allocatesSequentialIDsFromTheIndexCounter() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let first = try sut.createTask(at: root, title: "A", supervisorTask: "a")
        let second = try sut.createTask(at: root, title: "B", supervisorTask: "b")

        XCTAssertEqual(second.taskID, first.taskID + 1)
        let index = try AtomicJSONStore().read(TasksIndex.self, from: paths.tasksIndexJSON)
        XCTAssertEqual(index.nextTaskID, second.taskID + 1,
                       "The counter must advance past the last allocation.")
    }

    // ------------------------------------------------------------------
    // MARK: - NTMSRepository+Bootstrap
    // ------------------------------------------------------------------

    /// A corrupt file is preserved as a `.bak` and reset to defaults. Deleting it
    /// outright would destroy the only forensic copy of the user's data.
    func testLoadOrRecoverFile_corruptSettings_backsUpAndResetsToDefaults() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        try Data("{ this is not json".utf8).write(to: paths.settingsJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        let internalDir = paths.settingsJSON.deletingLastPathComponent()
        let contents = try fm.contentsOfDirectory(atPath: internalDir.path)
        XCTAssertTrue(
            contents.contains { $0.hasPrefix("settings.json.corrupt-") && $0.hasSuffix(".bak") },
            "The damaged file must be preserved — got \(contents)"
        )
        // And the live file is valid again.
        let recovered = try AtomicJSONStore().read(ProjectSettings.self, from: paths.settingsJSON)
        XCTAssertEqual(recovered.schemaVersion, ProjectSettings.defaults.schemaVersion)
    }

    /// A missing file is a first launch, not corruption: write the default and
    /// leave no `.bak` behind.
    func testLoadOrRecoverFile_missingFile_writesDefaultWithoutBackup() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        try fm.removeItem(at: paths.settingsJSON)

        _ = try sut.openOrCreateWorkFolder(at: root)

        XCTAssertTrue(fm.fileExists(atPath: paths.settingsJSON.path))
        let internalDir = paths.settingsJSON.deletingLastPathComponent()
        let contents = try fm.contentsOfDirectory(atPath: internalDir.path)
        XCTAssertFalse(contents.contains { $0.contains(".corrupt-") },
                       "An absent file must not be treated as damage.")
    }

    /// A dangling `activeTeamID` (teams.json recovered while workfolder.json still
    /// points at a pre-corruption team) must be repaired to the first team, or the
    /// stored state disagrees with what the UI actually shows.
    func testLoadOrRecoverFiles_danglingActiveTeamID_repairedToFirstTeam() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let store = AtomicJSONStore()
        var state = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        state.activeTeamID = NTMSID.from(name: "a team that no longer exists")
        try store.write(state, to: paths.workFolderJSON)

        let ctx = try sut.openOrCreateWorkFolder(at: root)

        let repaired = try store.read(WorkFolderState.self, from: paths.workFolderJSON)
        let teams = try store.read(TeamsFile.self, from: paths.teamsJSON)
        XCTAssertEqual(repaired.activeTeamID, teams.teams.first?.id,
                       "A dangling id must be repaired, not left to dangle.")
        XCTAssertNotNil(ctx.projection.activeTeam)
    }

    /// Orphan `.tmp` files are leftovers from an interrupted atomic write. They
    /// are swept so they don't accumulate — and only dot-prefixed `.tmp` names
    /// are eligible, so real data is never at risk.
    func testSweepOrphanTempFiles_removesOnlyDotPrefixedTempFiles() throws {
        _ = try sut.openOrCreateWorkFolder(at: root)
        let internalDir = paths.settingsJSON.deletingLastPathComponent()

        let orphan = internalDir.appendingPathComponent(".workfolder.json.abc123.tmp")
        let notDotted = internalDir.appendingPathComponent("report.tmp")
        let notTemp = internalDir.appendingPathComponent(".hidden.json")
        try Data("x".utf8).write(to: orphan)
        try Data("x".utf8).write(to: notDotted)
        try Data("x".utf8).write(to: notTemp)

        sut.sweepOrphanTempFiles(under: internalDir)

        XCTAssertFalse(fm.fileExists(atPath: orphan.path), "The orphan temp must be swept.")
        XCTAssertTrue(fm.fileExists(atPath: notDotted.path),
                      "A non-dotted .tmp is user data — leave it alone.")
        XCTAssertTrue(fm.fileExists(atPath: notTemp.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.settingsJSON.path),
                      "The sweep must never touch live state files.")
    }

    /// Delegation tools auto-inject from the role's delegation settings; they are
    /// never stored. A legacy or hand-edited `teams.json` carrying them must be
    /// healed on load, and the legacy `list_teams` literal stripped with them.
    func testNormalizeDelegationToolset_stripsDelegationToolsAndLegacyListTeams() {
        var role = makeTailWorkerRole(id: "r", name: "R", producesArtifacts: ["Out"])
        role.toolIDs = [
            "read_file", ToolNames.delegateToTeam, "list_teams",
            ToolNames.cancelDelegation, ToolNames.resumeDelegation,
            ToolNames.forwardToTeam, "write_file",
        ]
        var teams = [makeTailTeam(roles: [makeTailSupervisorRole(), role])]

        let changed = sut.normalizeDelegationToolset(teams: &teams)

        XCTAssertTrue(changed)
        XCTAssertEqual(teams[0].roles[1].toolIDs, ["read_file", "write_file"],
                       "Only the auto-injected pack and the dead literal come out.")
    }

    /// Idempotence matters: this runs on EVERY work-folder open, and a
    /// false "changed" would rewrite `teams.json` (and bump `updatedAt`) forever.
    func testNormalizeDelegationToolset_alreadyClean_reportsNoChange() {
        var teams = [makeTailTeam(roles: [
            makeTailSupervisorRole(),
            makeTailWorkerRole(id: "r", name: "R", producesArtifacts: ["Out"]),
        ])]
        let before = teams[0].updatedAt

        XCTAssertFalse(sut.normalizeDelegationToolset(teams: &teams))
        XCTAssertEqual(teams[0].updatedAt, before,
                       "A no-op pass must not bump updatedAt.")
    }

    /// The toolset↔peer-status invariant: a role with delegation configured is a
    /// peer of the Supervisor and must have NO upstream entry, or
    /// `delegate_to_team` rejects every call.
    func testNormalizeDelegatorPeerStatus_stripsUpstreamForConfiguredDelegators() {
        var delegator = makeTailWorkerRole(id: "agent", name: "Agent", producesArtifacts: ["Out"])
        delegator.allowDelegationToGeneratedTeams = true
        XCTAssertTrue(delegator.hasDelegationConfigured, "Fixture precondition.")

        var settings = TeamSettings.default
        settings.hierarchy = TeamHierarchy(reportsTo: ["agent": "sup", "plain": "sup"])
        var teams = [makeTailTeam(
            roles: [
                makeTailSupervisorRole(id: "sup"),
                delegator,
                makeTailWorkerRole(id: "plain", name: "Plain", producesArtifacts: ["Other"]),
            ],
            settings: settings
        )]

        let changed = sut.normalizeDelegatorPeerStatus(teams: &teams)

        XCTAssertTrue(changed)
        XCTAssertNil(teams[0].settings.hierarchy.reportsTo["agent"],
                     "A delegator must be peer-level with the Supervisor.")
        XCTAssertEqual(teams[0].settings.hierarchy.reportsTo["plain"], "sup",
                       "A non-delegating role keeps its upstream.")
    }

    func testNormalizeDelegatorPeerStatus_noDelegators_reportsNoChange() {
        var settings = TeamSettings.default
        settings.hierarchy = TeamHierarchy(reportsTo: ["plain": "sup"])
        var teams = [makeTailTeam(
            roles: [
                makeTailSupervisorRole(id: "sup"),
                makeTailWorkerRole(id: "plain", name: "Plain", producesArtifacts: ["Other"]),
            ],
            settings: settings
        )]

        XCTAssertFalse(sut.normalizeDelegatorPeerStatus(teams: &teams))
        XCTAssertEqual(teams[0].settings.hierarchy.reportsTo["plain"], "sup")
    }

    // ------------------------------------------------------------------
    // MARK: - NTMSRepository+Reconcile: orphan artifact prune
    // ------------------------------------------------------------------

    private func makeArtifact(_ name: String, isSystem: Bool) -> TeamArtifact {
        TeamArtifact(
            id: Artifact.slugify(name), name: name, icon: "doc",
            mimeType: "text/markdown", description: "",
            isSystemArtifact: isSystem,
            systemArtifactName: isSystem ? name : nil
        )
    }

    /// A renamed bundled artifact leaves a ghost behind that is still selectable
    /// in the UI. It must be pruned — but ONLY when nothing references it.
    func testPruneOrphanSystemArtifacts_removesUnreferencedRenamedGhost() {
        var team = makeTailTeam(roles: [makeTailSupervisorRole(requiredArtifacts: ["Code Review Summary"])])
        team.artifacts = [
            makeArtifact("Code Review", isSystem: true),          // the ghost
            makeArtifact("Code Review Summary", isSystem: true),  // the current name
        ]
        var bundled = makeTailTeam(roles: [])
        bundled.artifacts = [makeArtifact("Code Review Summary", isSystem: true)]

        let pruned = NTMSRepository.pruneOrphanSystemArtifacts(in: &team, bundled: bundled)

        XCTAssertTrue(pruned)
        XCTAssertEqual(team.artifacts.map(\.name), ["Code Review Summary"])
    }

    /// A custom artifact the user added is never a reconcile's business, no
    /// matter what the bundled team says.
    func testPruneOrphanSystemArtifacts_neverTouchesCustomArtifacts() {
        var team = makeTailTeam(roles: [makeTailSupervisorRole(requiredArtifacts: [])])
        team.artifacts = [makeArtifact("My Own Doc", isSystem: false)]
        var bundled = makeTailTeam(roles: [])
        bundled.artifacts = []

        let pruned = NTMSRepository.pruneOrphanSystemArtifacts(in: &team, bundled: bundled)

        XCTAssertFalse(pruned)
        XCTAssertEqual(team.artifacts.map(\.name), ["My Own Doc"])
    }

    /// A custom role that still depends on the legacy name protects it — the
    /// reference scan is what keeps the prune from breaking a user's team.
    func testPruneOrphanSystemArtifacts_keepsGhostStillReferencedByARole() {
        var team = makeTailTeam(roles: [
            makeTailSupervisorRole(requiredArtifacts: []),
            makeTailWorkerRole(id: "custom", name: "Custom",
                               requiredArtifacts: ["Code Review"],
                               producesArtifacts: ["Out"]),
        ])
        team.artifacts = [makeArtifact("Code Review", isSystem: true)]
        var bundled = makeTailTeam(roles: [])
        bundled.artifacts = []

        let pruned = NTMSRepository.pruneOrphanSystemArtifacts(in: &team, bundled: bundled)

        XCTAssertFalse(pruned, "A referenced artifact is not an orphan.")
        XCTAssertEqual(team.artifacts.map(\.name), ["Code Review"])
    }

    /// The Supervisor's own required artifact is a reference too — pruning it
    /// would leave the team unable to finish.
    func testPruneOrphanSystemArtifacts_keepsSupervisorRequiredArtifact() {
        var team = makeTailTeam(roles: [makeTailSupervisorRole(requiredArtifacts: ["Legacy Final"])])
        team.artifacts = [makeArtifact("Legacy Final", isSystem: true)]
        var bundled = makeTailTeam(roles: [])
        bundled.artifacts = []

        XCTAssertFalse(NTMSRepository.pruneOrphanSystemArtifacts(in: &team, bundled: bundled))
        XCTAssertEqual(team.artifacts.map(\.name), ["Legacy Final"])
    }

    // ------------------------------------------------------------------
    // MARK: - NTMSRepository+Reconcile: busy-role predicate
    // ------------------------------------------------------------------
    //
    // These complement `ReconcileDeferralEquivalenceTests`, which pins the whole
    // (roleStatus, stepStatus) grid as a subset relation. Here we pin the two
    // structural gates that grid does not reach: `closedAt` and "only runs.last".

    private func makeBusyTask(
        roleStatuses: [String: RoleExecutionStatus],
        steps: [StepExecution],
        closedAt: Date? = nil,
        extraEarlierRun: Run? = nil
    ) -> NTMSTask {
        var runs: [Run] = []
        if let extraEarlierRun { runs.append(extraEarlierRun) }
        runs.append(Run(id: runs.count, steps: steps, roleStatuses: roleStatuses, teamID: "team"))
        return NTMSTask(
            id: 1, title: "t", supervisorTask: "t",
            runs: runs, closedAt: closedAt, preferredTeamID: "team"
        )
    }

    /// A closed task cannot be executing — `closeTask` is the only writer of
    /// `closedAt`, and both `createNewRun` and `restartRole` clear it before
    /// anything goes live. Legacy files can strand a `.working` role behind it
    /// where nothing ever sweeps, so the gate must come first.
    func testBusyRoleIDs_closedTask_isNeverBusy() {
        let steps = [StepExecution(id: "r", role: .softwareEngineer, title: "R", status: .running)]
        let open = makeBusyTask(roleStatuses: ["r": .working], steps: steps)
        XCTAssertEqual(NTMSRepository.busyRoleIDs(open), ["r"],
                       "Precondition: this shape IS busy while open.")

        let closed = makeBusyTask(
            roleStatuses: ["r": .working], steps: steps, closedAt: Date()
        )
        XCTAssertTrue(NTMSRepository.busyRoleIDs(closed).isEmpty,
                      "A closed task must never pin its team.")
        XCTAssertFalse(NTMSRepository.pinsTeamAsBusy(closed))
    }

    /// Only `runs.last` is examined. Earlier runs legitimately retain live-looking
    /// statuses forever, so scanning them would MANUFACTURE permanent deferrals.
    func testBusyRoleIDs_earlierRunIsIgnored() {
        let staleRun = Run(
            id: 0,
            steps: [StepExecution(id: "old", role: .softwareEngineer, title: "Old", status: .running)],
            roleStatuses: ["old": .working],
            teamID: "team"
        )
        let task = makeBusyTask(
            roleStatuses: ["r": .done],
            steps: [StepExecution(id: "r", role: .softwareEngineer, title: "R", status: .done)],
            extraEarlierRun: staleRun
        )

        XCTAssertTrue(NTMSRepository.busyRoleIDs(task).isEmpty,
                      "A historical run must not pin the team forever.")
    }

    /// `roleStatuses` is a Dictionary, so iteration order varies per process.
    /// Sorting keeps the deferral banner stable across launches.
    func testBusyRoleIDs_multipleBusyRoles_areSorted() {
        let steps = [
            StepExecution(id: "zulu", role: .softwareEngineer, title: "Z", status: .running),
            StepExecution(id: "alpha", role: .softwareEngineer, title: "A",
                          status: .needsSupervisorInput),
            StepExecution(id: "mike", role: .softwareEngineer, title: "M", status: .running),
        ]
        let task = makeBusyTask(
            roleStatuses: ["zulu": .working, "alpha": .working, "mike": .working],
            steps: steps
        )

        XCTAssertEqual(NTMSRepository.busyRoleIDs(task), ["alpha", "mike", "zulu"])
    }

    /// A task with no runs at all cannot be busy.
    func testBusyRoleIDs_noRuns_isNotBusy() {
        let task = NTMSTask(id: 1, title: "t", supervisorTask: "t", runs: [])
        XCTAssertTrue(NTMSRepository.busyRoleIDs(task).isEmpty)
        XCTAssertFalse(NTMSRepository.pinsTeamAsBusy(task))
    }

    // ------------------------------------------------------------------
    // MARK: - NTMSRepository+Reconcile: running-role scan
    // ------------------------------------------------------------------

    /// A `task.json` that will not DECODE cannot be executing, so the scan fails
    /// OPEN for it. Poisoning the whole pass would freeze bundled updates for
    /// EVERY team in the folder — permanently, since nothing auto-recovers an
    /// individual task file.
    func testScanRunningTeamRoles_undecodableTaskJSON_failsOpenAndKeepsScanning() throws {
        let ctx = try sut.openOrCreateWorkFolder(at: root)
        let broken = try sut.createTask(at: root, title: "Broken", supervisorTask: "b")
        try Data("{\"id\": \"not an int\"}".utf8).write(
            to: paths.taskJSON(taskID: broken.taskID)
        )

        let index = try AtomicJSONStore().read(TasksIndex.self, from: paths.tasksIndexJSON)
        let result = sut.scanRunningTeamRoles(
            tasksIndex: index,
            teams: ctx.projection.teams,
            activeTeamID: ctx.projection.activeTeamID,
            paths: paths
        )

        guard case .clean(let running) = result else {
            return XCTFail("An undecodable task must not make the scan inconclusive — got \(result)")
        }
        XCTAssertTrue(running.isEmpty,
                      "No task is actually running — got \(running)")
    }

    /// An index entry whose file is gone is simply skipped; nothing about a
    /// missing file says a role is live.
    func testScanRunningTeamRoles_missingTaskFile_isSkipped() throws {
        let ctx = try sut.openOrCreateWorkFolder(at: root)
        let created = try sut.createTask(at: root, title: "Gone", supervisorTask: "g")
        try fm.removeItem(at: paths.taskJSON(taskID: created.taskID))

        let index = try AtomicJSONStore().read(TasksIndex.self, from: paths.tasksIndexJSON)
        let result = sut.scanRunningTeamRoles(
            tasksIndex: index,
            teams: ctx.projection.teams,
            activeTeamID: ctx.projection.activeTeamID,
            paths: paths
        )

        guard case .clean(let running) = result else {
            return XCTFail("A missing file must not stall the scan — got \(result)")
        }
        XCTAssertTrue(running.isEmpty)
    }

    /// The happy path: a genuinely live role is attributed to its team with
    /// enough detail for the deferral banner.
    func testScanRunningTeamRoles_liveRole_isAttributedToItsTeam() throws {
        let ctx = try sut.openOrCreateWorkFolder(at: root)
        let teamID = try XCTUnwrap(ctx.projection.activeTeam?.id)
        let created = try sut.createTask(at: root, title: "Live", supervisorTask: "l")

        var task = try sut.loadTask(at: root, taskID: created.taskID)
        task.runs = [Run(
            id: 0,
            steps: [StepExecution(id: "worker", role: .softwareEngineer,
                                  title: "Worker", status: .running)],
            roleStatuses: ["worker": .working],
            teamID: teamID
        )]
        try sut.updateTaskOnly(at: root, task: task)

        let index = try AtomicJSONStore().read(TasksIndex.self, from: paths.tasksIndexJSON)
        let result = sut.scanRunningTeamRoles(
            tasksIndex: index,
            teams: ctx.projection.teams,
            activeTeamID: ctx.projection.activeTeamID,
            paths: paths
        )

        guard case .clean(let running) = result else {
            return XCTFail("Expected a clean scan — got \(result)")
        }
        let evidence = try XCTUnwrap(running[teamID]?.first,
                                     "The live role must pin its own team — got \(running)")
        XCTAssertEqual(evidence.taskID, created.taskID)
        XCTAssertEqual(evidence.taskTitle, "Live")
        XCTAssertEqual(evidence.roleIDs, ["worker"])
    }

    /// An idle folder must pin nothing, or the very first open would defer every
    /// team's bundled content for no reason.
    func testScanRunningTeamRoles_idleFolder_isCleanAndEmpty() throws {
        let ctx = try sut.openOrCreateWorkFolder(at: root)
        _ = try sut.createTask(at: root, title: "Idle", supervisorTask: "i")

        let index = try AtomicJSONStore().read(TasksIndex.self, from: paths.tasksIndexJSON)
        let result = sut.scanRunningTeamRoles(
            tasksIndex: index,
            teams: ctx.projection.teams,
            activeTeamID: ctx.projection.activeTeamID,
            paths: paths
        )

        guard case .clean(let running) = result else {
            return XCTFail("Expected a clean scan — got \(result)")
        }
        XCTAssertTrue(running.isEmpty)
    }
}
