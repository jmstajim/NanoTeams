import XCTest
@testable import NanoTeams

/// Tests for the expanded-search envelope shape produced by
/// `LLMExecutionService+ExpandedSearch`. We exercise the pure envelope writer
/// indirectly by driving `appendExpandedSearchResult` with the disabled and
/// index-missing branches — both produce final envelopes deterministically
/// without an LLM round-trip.
@MainActor
final class ExpandedSearchProcessorEnvelopeTests: XCTestCase {

    private let fm = FileManager.default
    private var tempDir: URL!
    private var service: LLMExecutionService!
    private var mock: MockLLMExecutionDelegate!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = LLMExecutionService(repository: NTMSRepository())
        mock = MockLLMExecutionDelegate()
        mock.workFolderURL = tempDir
        service.attach(delegate: mock)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        service = nil
        mock = nil
        try super.tearDownWithError()
    }

    private func makeExpandedSearchToolResult(
        query: String = "scroll",
        providerID: String = "call_abc"
    ) -> ToolExecutionResult {
        ToolExecutionResult(
            providerID: providerID,
            toolName: ToolNames.search,
            argumentsJSON: #"{"query":"\#(query)","expand":true}"#,
            outputJSON: #"{"ok":true,"data":{"query":"\#(query)","status":"expanding"}}"#,
            isError: false,
            signal: .expandedSearch(try! ExpandedSearchPayload(
                query: query,
                mode: .substring,
                paths: nil,
                fileGlob: nil,
                contextBefore: 0,
                contextAfter: 0,
                maxResults: 20,
                maxMatchLines: 40
            ))
        )
    }

    // MARK: - Disabled branch

    func testDisabled_envelopeMarksExpandDisabled() async {
        // Need a step registered so updateToolCallResult is a no-op safely.
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.expandedSearchEnabled = false

        let stub = StubLLMClient()
        var convo: [ChatMessage] = []
        let result = makeExpandedSearchToolResult()
        await service.appendExpandedSearchResult(
            result: result,
            toolCallID: UUID(),
            stepID: "step1",
            client: stub,
            networkLogger: nil,
            conversationMessages: &convo
        )

        XCTAssertEqual(convo.count, 1, "Processor must append exactly one tool turn.")
        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expand_disabled\":true"),
            "Disabled branch must mark `expand_disabled: true`.")
        XCTAssertTrue(env.contains("\"expanded_terms\":[]"),
            "Disabled branch must report empty expanded_terms.")
        XCTAssertTrue(env.contains("\"query\":\"scroll\""))
    }

    // MARK: - Index unavailable branch

    func testIndexMissing_envelopeMarksExpansionError() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.expandedSearchEnabled = true
        mock.scriptedSearchIndex = nil   // delegate.awaitSearchIndex returns nil

        var convo: [ChatMessage] = []
        let result = makeExpandedSearchToolResult()
        await service.appendExpandedSearchResult(
            result: result,
            toolCallID: UUID(),
            stepID: "step1",
            client: StubLLMClient(),
            networkLogger: nil,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expansion_error\":\"index_unavailable\""),
            "Missing index must surface as `expansion_error: index_unavailable`.")
        // Even on the failure path, the tool result must NOT be marked as error.
        XCTAssertEqual(mock.awaitSearchIndexCallCount, 1)
    }

    // MARK: - No work folder branch

    func testNoWorkFolder_envelopeMarksNoWorkFolder() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.expandedSearchEnabled = true
        mock.workFolderURL = nil   // simulate no folder open

        var convo: [ChatMessage] = []
        let result = makeExpandedSearchToolResult()
        await service.appendExpandedSearchResult(
            result: result,
            toolCallID: UUID(),
            stepID: "step1",
            client: StubLLMClient(),
            networkLogger: nil,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expansion_error\":\"no_work_folder\""),
            "No folder must surface as `expansion_error: no_work_folder`.")
    }

    // MARK: - Tool message attribution

    func testEnvelope_toolCallMessageRoleIsTool() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.expandedSearchEnabled = false

        var convo: [ChatMessage] = []
        await service.appendExpandedSearchResult(
            result: makeExpandedSearchToolResult(),
            toolCallID: UUID(),
            stepID: "step1",
            client: StubLLMClient(),
            networkLogger: nil,
            conversationMessages: &convo
        )

        XCTAssertEqual(convo.first?.role, .tool)
    }

    func testEnvelope_propagatesProviderID() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.expandedSearchEnabled = false

        var convo: [ChatMessage] = []
        let result = makeExpandedSearchToolResult(providerID: "call_xyz")
        await service.appendExpandedSearchResult(
            result: result,
            toolCallID: UUID(),
            stepID: "step1",
            client: StubLLMClient(),
            networkLogger: nil,
            conversationMessages: &convo
        )

        XCTAssertEqual(convo.first?.toolCallID, "call_xyz",
            "providerID must thread through to the LLM-visible tool turn.")
    }

    // MARK: - Empty postings short-circuit

    func testEmptyPostings_envelopeReportsZeroHitFiles() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.expandedSearchEnabled = true
        // Index has no postings for the query.
        mock.scriptedSearchIndex = try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(
                fileCount: 1, maxMTime: Date(), totalSize: 1
            ),
            files: [IndexedFile(path: "A.swift", mTime: Date(), size: 1)],
            tokens: ["other"],
            postings: ["other": [0]]
        )

        // Stub LLM returns a synonym that ALSO doesn't exist in postings,
        // so the union is still empty.
        let stub = StubLLMClient(content: #"["nothere", "alsonothere"]"#)

        var convo: [ChatMessage] = []
        await service.appendExpandedSearchResult(
            result: makeExpandedSearchToolResult(query: "scroll"),
            toolCallID: UUID(),
            stepID: "step1",
            client: stub,
            networkLogger: nil,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"hit_files\":0"),
            "Empty posting intersection must short-circuit with hit_files: 0.")
        XCTAssertTrue(env.contains("\"matches\":[]"),
            "No file matches the query terms.")
    }

    // MARK: - T1-T4: delegate.expandSearchQuery → envelope round-trip

    /// Builds a minimal search index with three files whose postings contain
    /// the tokens we'll exercise. Used by T1-T4 to make posting intersection
    /// a real operation (not a pre-determined short-circuit).
    private func installScriptedIndex() {
        mock.expandedSearchEnabled = true
        // `try!` is deliberate — the literal invariants above are valid.
        // swiftlint:disable:next force_try
        mock.scriptedSearchIndex = try! SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 3, maxMTime: Date(), totalSize: 3),
            files: [
                IndexedFile(path: "UserManager.swift", mTime: Date(), size: 1),
                IndexedFile(path: "AccountService.swift", mTime: Date(), size: 1),
                IndexedFile(path: "Widget.swift", mTime: Date(), size: 1),
            ],
            tokens: ["user", "account", "widget", "scroll"],
            postings: [
                "scroll": [],
                "user": [0],
                "account": [1],
                "widget": [2],
            ]
        )
    }

    func testExpanded_envelopeContainsTermsAndHitFiles() async {
        // T1: happy path — `.expanded` case → envelope has the expansion
        // terms AND the posting intersection surfaces the right files.
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        installScriptedIndex()
        // Scripted expansion: query "scroll" maps to "user" (which IS in
        // postings → file 0). This confirms the envelope wires expansion
        // terms into `index.files(containing:)` not just into the JSON.
        mock.scriptedExpansion = .expanded(terms: ["user"])

        var convo: [ChatMessage] = []
        await service.appendExpandedSearchResult(
            result: makeExpandedSearchToolResult(query: "scroll"),
            toolCallID: UUID(), stepID: "step1",
            client: StubLLMClient(), networkLogger: nil,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expanded_terms\":[\"user\"]"),
            "Envelope must surface `.expanded` terms verbatim.")
        XCTAssertFalse(env.contains("\"expansion_error\""),
            "`.expanded` must not write an `expansion_error` field.")
        XCTAssertTrue(env.contains("\"hit_files\":1"),
            "Posting intersection for scroll + user must hit UserManager.swift.")
        XCTAssertEqual(mock.expandSearchQueryCallCount, 1,
            "Delegate must be called exactly once per expanded_search invocation.")
    }

    func testUnavailable_building_envelopePropagatesReason() async {
        // T2: vector index still building → chat LLM sees the exact state
        // string so it can "retry later" rather than treat as a hard error.
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        installScriptedIndex()
        mock.scriptedExpansion = .unavailable(reason: "vector_index_building")

        var convo: [ChatMessage] = []
        await service.appendExpandedSearchResult(
            result: makeExpandedSearchToolResult(query: "scroll"),
            toolCallID: UUID(), stepID: "step1",
            client: StubLLMClient(), networkLogger: nil,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expansion_error\":\"vector_index_building\""),
            "Envelope must propagate `unavailableReason` as `expansion_error`.")
        // Expansion terms empty but posting intersection still runs on the
        // original query token. `scroll` has no postings → 0 hits.
        XCTAssertTrue(env.contains("\"expanded_terms\":[]"))
    }

    func testUnavailable_modelNotLoaded_envelopePropagatesReason() async {
        // T3: embedding model not loaded → canonical string flows through.
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        installScriptedIndex()
        mock.scriptedExpansion = .unavailable(reason: "embedding_model_not_loaded")

        var convo: [ChatMessage] = []
        await service.appendExpandedSearchResult(
            result: makeExpandedSearchToolResult(query: "scroll"),
            toolCallID: UUID(), stepID: "step1",
            client: StubLLMClient(), networkLogger: nil,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expansion_error\":\"embedding_model_not_loaded\""),
            "Exact canonical string must reach the chat LLM envelope.")
    }

    func testTransientError_envelopeHasBothTermsAndError() async {
        // T4: whole-phrase embed failed mid-query, but per-token tier produced
        // results. Envelope must surface BOTH — terms for the partial answer
        // AND error so the LLM can decide whether to retry.
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        installScriptedIndex()
        mock.scriptedExpansion = .transientError(
            terms: ["user", "account"],
            reason: "embedding_http_error"
        )

        var convo: [ChatMessage] = []
        await service.appendExpandedSearchResult(
            result: makeExpandedSearchToolResult(query: "scroll"),
            toolCallID: UUID(), stepID: "step1",
            client: StubLLMClient(), networkLogger: nil,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expansion_error\":\"embedding_http_error\""),
            "Transient error reason must land in `expansion_error`.")
        XCTAssertTrue(env.contains("\"user\""),
            "Partial per-token terms must survive in `expanded_terms`.")
        XCTAssertTrue(env.contains("\"account\""))
        // Two hits — UserManager.swift (for "user") + AccountService.swift.
        XCTAssertTrue(env.contains("\"hit_files\":2"),
            "Posting intersection must treat `.transientError` terms the same as `.expanded`.")
    }

    // MARK: - B1: search_error surfaces executor throws

    /// When `SearchExecutor.run` throws (e.g. sandbox-reject of an absolute
    /// path), the envelope must NOT silently collapse to an empty result —
    /// the LLM needs a `search_error` field so it can distinguish "no
    /// matches" from "the search engine couldn't run".
    func testDisabled_executorThrow_surfacesSearchError() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.expandedSearchEnabled = false  // disabled → plain-executor branch

        let payload = try ExpandedSearchPayload(
            query: "x",
            mode: .substring,
            paths: ["/etc/passwd"],  // absolute → resolver throws
            fileGlob: nil,
            contextBefore: 0,
            contextAfter: 0,
            maxResults: 20,
            maxMatchLines: 40
        )
        let result = ToolExecutionResult(
            providerID: "call_a",
            toolName: ToolNames.search,
            argumentsJSON: "{}",
            outputJSON: "",
            isError: false,
            signal: .expandedSearch(payload)
        )

        var convo: [ChatMessage] = []
        await service.appendExpandedSearchResult(
            result: result,
            toolCallID: UUID(),
            stepID: "step1",
            client: StubLLMClient(),
            networkLogger: nil,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"search_error\":"),
            "Executor throw must surface a `search_error` field. Envelope: \(env)")
    }

    func testIndexUnavailable_executorThrow_surfacesSearchError() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.expandedSearchEnabled = true
        mock.scriptedSearchIndex = nil  // awaitSearchIndex → nil → fall-back path

        let payload = try ExpandedSearchPayload(
            query: "x",
            mode: .substring,
            paths: ["/usr/local"],   // absolute → resolver throws
            fileGlob: nil,
            contextBefore: 0,
            contextAfter: 0,
            maxResults: 20,
            maxMatchLines: 40
        )
        let result = ToolExecutionResult(
            providerID: "call_b",
            toolName: ToolNames.search,
            argumentsJSON: "{}",
            outputJSON: "",
            isError: false,
            signal: .expandedSearch(payload)
        )

        var convo: [ChatMessage] = []
        await service.appendExpandedSearchResult(
            result: result,
            toolCallID: UUID(),
            stepID: "step1",
            client: StubLLMClient(),
            networkLogger: nil,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"search_error\":"),
            "Executor throw in fall-back path must also surface `search_error`. Envelope: \(env)")
    }

    // MARK: - B4: distinct `index_unavailable` causes

    /// Fall-back path triggered by "no work folder" must NOT collapse to
    /// the same `expansion_error: index_unavailable` as a real coordinator
    /// bug — they are semantically distinct and the LLM should see that.
    func testNoWorkFolder_distinctReason() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.expandedSearchEnabled = true
        mock.workFolderURL = nil

        var convo: [ChatMessage] = []
        await service.appendExpandedSearchResult(
            result: makeExpandedSearchToolResult(),
            toolCallID: UUID(),
            stepID: "step1",
            client: StubLLMClient(),
            networkLogger: nil,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expansion_error\":\"no_work_folder\""),
            "no_work_folder is distinct from index_unavailable.")
        XCTAssertFalse(env.contains("\"expansion_error\":\"index_unavailable\""),
            "no_work_folder must NOT be labelled `index_unavailable`.")
    }

    /// Default-storage mode ("Application Support") cannot host a expanded-search
    /// index by design. The envelope must say so explicitly — not reuse
    /// `index_unavailable`, which suggests a transient/recoverable state.
    func testDefaultStorage_distinctReason() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.expandedSearchEnabled = true
        mock.hasRealWorkFolder = false        // default storage
        mock.scriptedSearchIndex = nil         // coordinator absent

        var convo: [ChatMessage] = []
        await service.appendExpandedSearchResult(
            result: makeExpandedSearchToolResult(),
            toolCallID: UUID(),
            stepID: "step1",
            client: StubLLMClient(),
            networkLogger: nil,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expansion_error\":\"expand_unsupported_default_storage\""),
            "Default storage must surface its own distinct reason. Envelope: \(env)")
    }

    // MARK: - B3: short-circuit preserves `skipped_*` accounting

    /// When the posting intersection is empty, the envelope still runs the
    /// executor to collect `skipped_files` / `skipped_binary_count` from the
    /// work-folder walk — otherwise the LLM can't tell "no matches" from
    /// "matching content lives in unreadable binaries".
    func testShortCircuit_surfacesSkippedBinaryCount() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        installScriptedIndex()                       // scroll has no postings
        mock.scriptedExpansion = .expanded(terms: [])

        // Drop a non-UTF-8 binary into the work folder — the executor's
        // full walk will count it via `skippedBinaryCount`.
        let binary = tempDir.appendingPathComponent("payload.o")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]).write(to: binary)

        var convo: [ChatMessage] = []
        await service.appendExpandedSearchResult(
            result: makeExpandedSearchToolResult(query: "scroll"),
            toolCallID: UUID(),
            stepID: "step1",
            client: StubLLMClient(),
            networkLogger: nil,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"hit_files\":0"),
            "Scroll has no postings — short-circuit fires.")
        XCTAssertTrue(env.contains("\"skipped_binary_count\""),
            "Short-circuit branch must still surface skipped_binary_count. Envelope: \(env)")
    }

    // MARK: - I2: memory cache records the finalized envelope, not the interim

    /// The interim `SearchTool` result carries `{"status":"expanding"}` — if
    /// that were what the ToolCallCache captured, a subsequent identical
    /// `expand` call would dedup against a placeholder and the LLM
    /// would be served garbage. The finalize path must record the real
    /// envelope after rewriting.
    func testMemoryCache_recordsFinalizedEnvelope_notInterimPlaceholder() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.expandedSearchEnabled = false  // deterministic: disabled → plain executor

        let cache = ToolCallCache()
        var convo: [ChatMessage] = []
        await service.appendExpandedSearchResult(
            result: makeExpandedSearchToolResult(),
            toolCallID: UUID(),
            stepID: "step1",
            client: StubLLMClient(),
            networkLogger: nil,
            conversationMessages: &convo,
            memory: cache
        )

        // The cache must hold a finalized envelope (contains `expand_disabled`
        // or `expanded_terms`), never the interim `"status":"expanding"` placeholder.
        let recorded = cache.calls.first(where: { $0.toolName == ToolNames.search })
        XCTAssertNotNil(recorded, "Finalize step must have recorded the call.")
        XCTAssertFalse(recorded?.resultJSON.contains("\"status\":\"expanding\"") ?? true,
            "Cache must NOT hold the interim placeholder. Got: \(recorded?.resultJSON ?? "")")
        XCTAssertTrue(recorded?.resultJSON.contains("\"expand_disabled\":true") ?? false,
            "Cache must hold the finalized disabled-branch envelope.")
    }

    /// Real work folder + coordinator returned nil = actual bug. Keep the
    /// historical `index_unavailable` reason for this case.
    func testRealFolderButNoIndex_keepsIndexUnavailable() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.expandedSearchEnabled = true
        mock.hasRealWorkFolder = true
        mock.scriptedSearchIndex = nil

        var convo: [ChatMessage] = []
        await service.appendExpandedSearchResult(
            result: makeExpandedSearchToolResult(),
            toolCallID: UUID(),
            stepID: "step1",
            client: StubLLMClient(),
            networkLogger: nil,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expansion_error\":\"index_unavailable\""),
            "Real folder + nil coordinator still uses `index_unavailable`. Envelope: \(env)")
    }
}

// MARK: - StubLLMClient

private struct StubLLMClient: LLMClient {
    var content: String = #"["scroll", "scrollView"]"#

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        session: LLMSession?,
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let captured = content
        return AsyncThrowingStream { continuation in
            continuation.yield(StreamEvent(contentDelta: captured))
            continuation.finish()
        }
    }

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
}
