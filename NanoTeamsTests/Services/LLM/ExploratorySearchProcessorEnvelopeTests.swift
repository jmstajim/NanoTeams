import XCTest
@testable import NanoTeams

/// Tests for the exploratory-search envelope shape produced by
/// `LLMExecutionService+ExploratorySearch`. We exercise the pure envelope writer
/// indirectly by driving `appendExploratorySearchResult` with the disabled and
/// index-missing branches — both produce final envelopes deterministically
/// without an LLM round-trip.
@MainActor
final class ExploratorySearchProcessorEnvelopeTests: XCTestCase {

    private let fm = FileManager.default
    private var tempDir: URL!
    private var service: LLMExecutionService!
    private var mock: MockLLMExecutionDelegate!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = LLMExecutionService(repository: NTMSRepository())
        mock = MockLLMExecutionDelegate()
        mock.workFolderURL = tempDir
        service.attach(delegate: mock)
    }

    override func tearDown() async throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        service = nil
        mock = nil
        try await super.tearDown()
    }

    private func makeExploratorySearchToolResult(
        query: String = "scroll",
        providerID: String = "call_abc"
    ) -> ToolExecutionResult {
        ToolExecutionResult(
            providerID: providerID,
            toolName: ToolNames.search,
            argumentsJSON: #"{"query":"\#(query)","exploratory":true}"#,
            outputJSON: #"{"ok":true,"data":{"query":"\#(query)","status":"exploring"}}"#,
            isError: false,
            signal: .exploratorySearch(try! ExploratorySearchPayload(
                query: query,
                mode: .substring,
                paths: nil,
                fileGlob: nil,
                contextBefore: 0,
                contextAfter: 0,
                maxResults: 20
            ))
        )
    }

    // MARK: - Disabled branch

    func testDisabled_envelopeMarksExpandDisabled() async {
        // Need a step registered so updateToolCallResult is a no-op safely.
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = false

        var convo: [ChatMessage] = []
        let result = makeExploratorySearchToolResult()
        await service.appendExploratorySearchResult(
            result: result,
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        XCTAssertEqual(convo.count, 1, "Processor must append exactly one tool turn.")
        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"exploratory_disabled\":true"),
            "Disabled branch must mark `exploratory_disabled: true`.")
        XCTAssertTrue(env.contains("\"expanded_terms\":[]"),
            "Disabled branch must report empty expanded_terms.")
        XCTAssertTrue(env.contains("\"query\":\"scroll\""))
    }

    // MARK: - Index unavailable branch

    func testIndexMissing_envelopeMarksExpansionError() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = true
        mock.scriptedSearchIndex = nil   // delegate.awaitSearchIndex returns nil

        var convo: [ChatMessage] = []
        let result = makeExploratorySearchToolResult()
        await service.appendExploratorySearchResult(
            result: result,
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
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
        mock.exploratorySearchEnabled = true
        mock.workFolderURL = nil   // simulate no folder open

        var convo: [ChatMessage] = []
        let result = makeExploratorySearchToolResult()
        await service.appendExploratorySearchResult(
            result: result,
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expansion_error\":\"no_work_folder\""),
            "No folder must surface as `expansion_error: no_work_folder`.")
    }

    // MARK: - Tool message attribution

    func testEnvelope_toolCallMessageRoleIsTool() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = false

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        XCTAssertEqual(convo.first?.role, .tool)
    }

    func testEnvelope_propagatesProviderID() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = false

        var convo: [ChatMessage] = []
        let result = makeExploratorySearchToolResult(providerID: "call_xyz")
        await service.appendExploratorySearchResult(
            result: result,
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        XCTAssertEqual(convo.first?.toolCallID, "call_xyz",
            "providerID must thread through to the LLM-visible tool turn.")
    }

    // MARK: - Empty postings short-circuit

    func testEmptyPostings_envelopeReportsZeroHitFiles() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = true
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

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "scroll"),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
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
        mock.exploratorySearchEnabled = true
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
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "scroll"),
            toolCallID: UUID(), stepID: "step1",
            taskID: 1,
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
            "Delegate must be called exactly once per exploratory_search invocation.")
    }

    func testUnavailable_building_envelopePropagatesReason() async {
        // T2: vector index still building → chat LLM sees the exact state
        // string so it can "retry later" rather than treat as a hard error.
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        installScriptedIndex()
        mock.scriptedExpansion = .unavailable(reason: "vector_index_building")

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "scroll"),
            toolCallID: UUID(), stepID: "step1",
            taskID: 1,
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
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "scroll"),
            toolCallID: UUID(), stepID: "step1",
            taskID: 1,
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
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "scroll"),
            toolCallID: UUID(), stepID: "step1",
            taskID: 1,
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
        mock.exploratorySearchEnabled = false  // disabled → plain-executor branch

        let payload = try ExploratorySearchPayload(
            query: "x",
            mode: .substring,
            paths: ["/etc/passwd"],  // absolute & outside the work folder → resolver throws
            fileGlob: nil,
            contextBefore: 0,
            contextAfter: 0,
            maxResults: 20
        )
        let result = ToolExecutionResult(
            providerID: "call_a",
            toolName: ToolNames.search,
            argumentsJSON: "{}",
            outputJSON: "",
            isError: false,
            signal: .exploratorySearch(payload)
        )

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: result,
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"search_error\":"),
            "Executor throw must surface a `search_error` field. Envelope: \(env)")
    }

    func testIndexUnavailable_executorThrow_surfacesSearchError() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = true
        mock.scriptedSearchIndex = nil  // awaitSearchIndex → nil → fall-back path

        let payload = try ExploratorySearchPayload(
            query: "x",
            mode: .substring,
            paths: ["/usr/local"],   // absolute → resolver throws
            fileGlob: nil,
            contextBefore: 0,
            contextAfter: 0,
            maxResults: 20
        )
        let result = ToolExecutionResult(
            providerID: "call_b",
            toolName: ToolNames.search,
            argumentsJSON: "{}",
            outputJSON: "",
            isError: false,
            signal: .exploratorySearch(payload)
        )

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: result,
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
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
        mock.exploratorySearchEnabled = true
        mock.workFolderURL = nil

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expansion_error\":\"no_work_folder\""),
            "no_work_folder is distinct from index_unavailable.")
        XCTAssertFalse(env.contains("\"expansion_error\":\"index_unavailable\""),
            "no_work_folder must NOT be labelled `index_unavailable`.")
    }

    /// Default-storage mode ("Application Support") cannot host a exploratory-search
    /// index by design. The envelope must say so explicitly — not reuse
    /// `index_unavailable`, which suggests a transient/recoverable state.
    func testDefaultStorage_distinctReason() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = true
        mock.hasRealWorkFolder = false        // default storage
        mock.scriptedSearchIndex = nil         // coordinator absent

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expansion_error\":\"exploratory_unsupported_default_storage\""),
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
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "scroll"),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"hit_files\":0"),
            "Scroll has no postings — short-circuit fires.")
        XCTAssertTrue(env.contains("\"skipped_binary_count\""),
            "Short-circuit branch must still surface skipped_binary_count. Envelope: \(env)")
    }

    // MARK: - I2: tracker records the finalized envelope, not the interim

    /// The interim `SearchTool` result carries `{"status":"exploring"}` — if
    /// that were what the ToolCallTracker captured, a subsequent
    /// `recentCalls` snapshot for the loop detector would see a placeholder
    /// instead of the real result. The fixture above emits the same
    /// `"status":"exploring"` envelope as the real `SearchTool`; the finalize
    /// path must rewrite it to the actual result envelope before recording.
    func testMemoryCache_recordsFinalizedEnvelope_notInterimPlaceholder() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = false  // deterministic: disabled → plain executor

        let tracker = ToolCallTracker()
        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo,
            tracker: tracker
        )

        // The tracker must hold a finalized envelope (contains `exploratory_disabled`
        // or `expanded_terms`), never the interim `"status":"exploring"` placeholder.
        let recorded = tracker.recentCalls(limit: .max).first(where: { $0.toolName == ToolNames.search })
        XCTAssertNotNil(recorded, "Finalize step must have recorded the call.")
        XCTAssertFalse(recorded?.resultJSON.contains("\"status\":\"exploring\"") ?? true,
            "Tracker must NOT hold the interim placeholder. Got: \(recorded?.resultJSON ?? "")")
        XCTAssertTrue(recorded?.resultJSON.contains("\"exploratory_disabled\":true") ?? false,
            "Tracker must hold the finalized disabled-branch envelope.")
    }

    // MARK: - Filename matches in expand pipeline

    /// Success branch: filename matching runs against the FULL index roster,
    /// not just `hitFiles`. A file whose basename matches the query but
    /// whose content has no posting intersection must still appear in
    /// `filename_matches`.
    func testFilenameMatches_surfacedFromIndexRoster() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = true
        // Index has a file whose name matches "scroll" but no posting for it.
        mock.scriptedSearchIndex = try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 2, maxMTime: Date(), totalSize: 2),
            files: [
                IndexedFile(path: "Views/ScrollContainer.swift", mTime: Date(), size: 1),
                IndexedFile(path: "Domain/Other.swift", mTime: Date(), size: 1),
            ],
            tokens: ["other"],
            postings: ["other": [1]]
        )
        mock.scriptedExpansion = .expanded(terms: [])

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "scroll"),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"filename_matches\""),
            "Expand pipeline must surface filename matches from the index. Envelope: \(env)")
        // Foundation escapes `/` to `\/` in JSON; assert on the basename
        // (uniquely identifying) and the matched_on tag instead.
        XCTAssertTrue(env.contains("ScrollContainer.swift"),
            "File matching the query basename must appear regardless of posting hits.")
        XCTAssertTrue(env.contains("\"matched_on\":\"basename\""))
    }

    /// Vocab expansion must apply to filename matching too — a file whose
    /// name matches an expanded term (not the original query) still surfaces.
    func testFilenameMatches_useExpandedTerms() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = true
        mock.scriptedSearchIndex = try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 2, maxMTime: Date(), totalSize: 2),
            files: [
                IndexedFile(path: "Models/UserAccount.swift", mTime: Date(), size: 1),
                IndexedFile(path: "Other.swift", mTime: Date(), size: 1),
            ],
            tokens: ["user"],
            postings: ["user": [0]]
        )
        // Original query has no filename hits; expansion adds "account"
        // which DOES match Models/UserAccount.swift's basename.
        mock.scriptedExpansion = .expanded(terms: ["account"])

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "пользователь"),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        // Foundation escapes `/` to `\/` in JSON; assert on the basename.
        XCTAssertTrue(env.contains("UserAccount.swift"),
            "Expanded vocab term must drive filename matching. Envelope: \(env)")
    }

    /// Empty postings short-circuit branch must still emit filename matches
    /// computed from the index roster — that's the most common case where
    /// filename search adds value, since posting intersection produced
    /// nothing useful.
    func testFilenameMatches_surfaceEvenWhenPostingsEmpty() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = true
        mock.scriptedSearchIndex = try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 1, maxMTime: Date(), totalSize: 1),
            files: [IndexedFile(path: "ScrollView.swift", mTime: Date(), size: 1)],
            tokens: ["other"],
            postings: ["other": [0]]   // "scroll" has no postings → empty intersection
        )
        mock.scriptedExpansion = .expanded(terms: [])

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "scroll"),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"hit_files\":0"),
            "Posting intersection is empty.")
        XCTAssertTrue(env.contains("ScrollView.swift"),
            "Filename match must surface from the index even when postings are empty. Envelope: \(env)")
    }

    /// Disabled / fall-back branches use the plain executor's filename
    /// matches (walk-collected). Pin that the wiring threads through, not
    /// just the success path.
    func testDisabled_filenameMatches_fromPlainExecutor() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = false

        let url = tempDir.appendingPathComponent("ScrollHelper.swift")
        try "// no content match\n".write(to: url, atomically: true, encoding: .utf8)

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "Scroll"),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"exploratory_disabled\":true"))
        XCTAssertTrue(env.contains("ScrollHelper.swift"),
            "Disabled branch must pipe filename matches from plain executor. Envelope: \(env)")
    }

    /// Real work folder + coordinator returned nil = actual bug. Keep the
    /// historical `index_unavailable` reason for this case.
    func testRealFolderButNoIndex_keepsIndexUnavailable() async {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = true
        mock.hasRealWorkFolder = true
        mock.scriptedSearchIndex = nil

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"expansion_error\":\"index_unavailable\""),
            "Real folder + nil coordinator still uses `index_unavailable`. Envelope: \(env)")
    }

    // MARK: - Filename matches: more expand-pipeline corner cases

    /// Empty index roster (zero indexed files) must NOT produce
    /// `filename_matches` in the envelope — there's nothing to match against.
    func testFilenameMatches_emptyIndex_omitsField() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = true
        mock.scriptedSearchIndex = try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 0, maxMTime: Date(), totalSize: 0),
            files: [],
            tokens: [],
            postings: [:]
        )
        mock.scriptedExpansion = .expanded(terms: [])

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "anything"),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertFalse(env.contains("\"filename_matches\""),
            "Empty roster must omit filename_matches entirely.")
    }

    /// Both posting hits AND filename hits surface in the same envelope —
    /// pin that the success branch carries both arrays independently.
    func testFilenameMatches_alongsideContentHits() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = true
        mock.scriptedSearchIndex = try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 1, maxMTime: Date(), totalSize: 1),
            files: [IndexedFile(path: "Sources/Search.swift", mTime: Date(), size: 1)],
            tokens: ["search"],
            postings: ["search": [0]]
        )
        mock.scriptedExpansion = .expanded(terms: [])
        // Real file on disk so the constrained executor walk produces a
        // content match too.
        let url = tempDir.appendingPathComponent("Sources/Search.swift")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let search = 1\n".write(to: url, atomically: true, encoding: .utf8)

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "search"),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("\"hit_files\":1"),
            "Posting intersection should hit Search.swift.")
        XCTAssertTrue(env.contains("\"filename_matches\""),
            "Filename match should also surface for the same file.")
    }

    /// Internal-dir entries must never reach the index — but if a buggy
    /// or stale index ever included one, the matcher would still surface
    /// it. This test pins the upstream expectation: index files reaching
    /// the matcher are sandbox-clean by construction (the index builder
    /// applies the filter, not the matcher).
    func testFilenameMatches_indexAssumedSandboxClean() async throws {
        // We simulate a "clean" index — verifies the contract that the
        // expand pipeline relies on the index being pre-filtered.
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = true
        mock.scriptedSearchIndex = try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 1, maxMTime: Date(), totalSize: 1),
            files: [IndexedFile(path: "Sources/Foo.swift", mTime: Date(), size: 1)],
            tokens: [],
            postings: [:]
        )
        mock.scriptedExpansion = .expanded(terms: [])

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "Foo"),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        XCTAssertTrue(env.contains("Foo.swift"),
            "Sandbox-clean index entries must surface in filename_matches.")
    }

    /// `filename_matches` must respect `payload.maxResults` cap even when
    /// the index roster has many matching files.
    func testFilenameMatches_respectsMaxResultsCap() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = true
        let files = (0..<100).map {
            IndexedFile(path: "Sources/Foo\($0).swift", mTime: Date(), size: 1)
        }
        mock.scriptedSearchIndex = try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 100, maxMTime: Date(), totalSize: 100),
            files: files,
            tokens: [],
            postings: [:]
        )
        mock.scriptedExpansion = .expanded(terms: [])

        // Build a payload with a tight maxResults cap.
        let payload = try ExploratorySearchPayload(
            query: "Foo",
            mode: .substring,
            paths: nil,
            fileGlob: nil,
            contextBefore: 0,
            contextAfter: 0,
            maxResults: 5
        )
        let result = ToolExecutionResult(
            providerID: "call_cap",
            toolName: ToolNames.search,
            argumentsJSON: "{}",
            outputJSON: "",
            isError: false,
            signal: .exploratorySearch(payload)
        )

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: result,
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        // Decode envelope → assert the array length is exactly 5.
        let env = convo.first?.content ?? ""
        let envData = env.data(using: .utf8) ?? Data()
        struct Outer: Decodable { let data: Inner }
        struct Inner: Decodable { let filename_matches: [FilenameMatch]? }
        let decoded = try JSONDecoder().decode(Outer.self, from: envData)
        XCTAssertEqual(decoded.data.filename_matches?.count, 5,
            "Filename matches must be capped at payload.maxResults.")
    }

    /// MatchedOn raw values must serialize as "basename" / "path" — pin
    /// the wire contract via JSON decode (not raw String contains, which
    /// would tolerate an accidental rename).
    func testFilenameMatches_matchedOnEnumDecodesCorrectly() async throws {
        service._testRegisterStepTask(stepID: "step1", taskID: 1)
        mock.exploratorySearchEnabled = true
        mock.scriptedSearchIndex = try SearchIndex(
            generatedAt: Date(),
            signature: IndexSignature(fileCount: 2, maxMTime: Date(), totalSize: 2),
            files: [
                IndexedFile(path: "Domain/Search.swift", mTime: Date(), size: 1),
                IndexedFile(path: "Services/Search/Foo.swift", mTime: Date(), size: 1),
            ],
            tokens: [],
            postings: [:]
        )
        mock.scriptedExpansion = .expanded(terms: [])

        var convo: [ChatMessage] = []
        await service.appendExploratorySearchResult(
            result: makeExploratorySearchToolResult(query: "Search"),
            toolCallID: UUID(),
            stepID: "step1",
            taskID: 1,
            conversationMessages: &convo
        )

        let env = convo.first?.content ?? ""
        let envData = env.data(using: .utf8) ?? Data()
        struct Outer: Decodable { let data: Inner }
        struct Inner: Decodable { let filename_matches: [FilenameMatch] }
        let decoded = try JSONDecoder().decode(Outer.self, from: envData)
        let kinds = Set(decoded.data.filename_matches.map(\.matched_on))
        XCTAssertTrue(kinds.contains(.basename))
        XCTAssertTrue(kinds.contains(.path))
    }
}

