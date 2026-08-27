import Foundation

/// Extension for handling `exploratory: true` signals emitted by `SearchTool`.
/// Pipeline:
/// 1. Read feature gates from the delegate.
/// 2. Await the token search index (or fall back to plain search on failure).
/// 3. Call `delegate.expandSearchQuery(...)` to get semantic expansion terms
///    via the local vector index (per-token vectors + one whole-phrase
///    `/v1/embeddings` call).
/// 4. Intersect posting lists to narrow the grep scope.
/// 5. Run `SearchExecutor` over [original] + expanded terms.
/// 6. Overwrite the interim "exploring" envelope with the final result.
extension LLMExecutionService {

    func appendExploratorySearchResult(
        result: ToolExecutionResult,
        toolCallID: UUID,
        stepID: String,
        taskID: Int,
        conversationMessages: inout [ChatMessage],
        tracker: ToolCallTracker? = nil
    ) async {
        guard case .exploratorySearch(let payload) = result.signal else { return }
        guard let delegate else { return }
        guard let workFolderRoot = delegate.workFolderURL else {
            await finalizeEnvelope(
                envelope: ExploratorySearchEnvelope.make(
                    payload: payload,
                    expanded: [],
                    output: .empty,
                    hitFilesCount: 0,
                    filenameMatches: [],
                    expansionError: "no_work_folder",
                    searchError: nil,
                    exploratoryDisabled: false
                ),
                result: result,
                toolCallID: toolCallID,
                stepID: stepID,
                taskID: taskID,
                conversationMessages: &conversationMessages,
                tracker: tracker
            )
            return
        }

        let internalDir = NTMSPaths(workFolderRoot: workFolderRoot).internalDir
        let resolver = SandboxPathResolver(workFolderRoot: workFolderRoot, internalDir: internalDir)

        // Feature disabled → plain search with a marker envelope.
        if !delegate.exploratorySearchEnabled {
            let plain = await runPlainExecutor(
                workFolderRoot: workFolderRoot,
                resolver: resolver,
                internalDir: internalDir,
                payload: payload,
                constrainToFiles: nil
            )
            await finalizeEnvelope(
                envelope: ExploratorySearchEnvelope.make(
                    payload: payload,
                    expanded: [],
                    output: plain.output,
                    hitFilesCount: uniqueFiles(plain.output.matches),
                    filenameMatches: plain.output.filenameMatches,
                    expansionError: nil,
                    searchError: plain.searchError,
                    exploratoryDisabled: true
                ),
                result: result,
                toolCallID: toolCallID,
                stepID: stepID,
                taskID: taskID,
                conversationMessages: &conversationMessages,
                tracker: tracker
            )
            return
        }

        // Await the index (coordinator may be building). `nil` → fall back.
        // Distinguish "default storage, architecturally unsupported" from
        // "real folder, coordinator-returned-nil (true bug)" so the LLM can
        // see which branch fired.
        guard let index = await delegate.awaitSearchIndex() else {
            let plain = await runPlainExecutor(
                workFolderRoot: workFolderRoot,
                resolver: resolver,
                internalDir: internalDir,
                payload: payload,
                constrainToFiles: nil
            )
            let expansionReason = delegate.hasRealWorkFolder
                ? "index_unavailable"
                : "exploratory_unsupported_default_storage"
            await finalizeEnvelope(
                envelope: ExploratorySearchEnvelope.make(
                    payload: payload,
                    expanded: [],
                    output: plain.output,
                    hitFilesCount: uniqueFiles(plain.output.matches),
                    filenameMatches: plain.output.filenameMatches,
                    expansionError: expansionReason,
                    searchError: plain.searchError,
                    exploratoryDisabled: false
                ),
                result: result,
                toolCallID: toolCallID,
                stepID: stepID,
                taskID: taskID,
                conversationMessages: &conversationMessages,
                tracker: tracker
            )
            return
        }

        // Semantic expansion via the precomputed vector index. Per-token hits
        // (zero network) + whole-phrase embedding (one /v1/embeddings call)
        // surface related vocab tokens. Unlike the old LLM-based expansion,
        // failures here are mostly `unavailableReason` (index missing /
        // building / model not loaded), with the original token still
        // producing useful results via plain posting intersection.
        let queryTokens = TokenExtractor.extractTokens(from: payload.query)
        let expansion = await delegate.expandSearchQuery(
            query: payload.query,
            tokens: Array(queryTokens)
        )
        let expanded = expansion.terms
        // `ExpansionResult` is a 3-case enum; at most one of
        // `errorReason` (transient HTTP / transport) and `unavailableReason`
        // (state: missing / building / model not loaded) is non-nil by
        // construction. `??` just collapses them into the envelope's single
        // `expansion_error` field in priority order.
        let expansionError: String? = expansion.errorReason ?? expansion.unavailableReason

        // Single source of truth for "everything the search asked about"
        // — literal query plus its tokens plus expansion terms. Both
        // posting intersection and filename matching consume the same list
        // so they can never disagree on what was searched. Original query
        // first so `FilenameMatcher`'s ordered iteration attributes hits
        // to the literal term when it matches.
        let unionTerms = Self.unionSearchTerms(
            query: payload.query, tokens: queryTokens, expanded: expanded
        )

        // Both index-wide passes, off the main actor — see `narrowAndMatchNames`.
        let narrowed = await Self.narrowAndMatchNames(
            index: index, unionTerms: unionTerms, limit: payload.maxResults)
        let hitFiles = narrowed.hitFiles
        let indexFilenameMatches = narrowed.filenameMatches

        // If the posting intersection returned nothing, short-circuit.
        // We still run the executor against the original query scope so that
        // unreadable-file accounting (`skipped_files` / `skipped_binary_count`)
        // reaches the LLM — otherwise the LLM can't tell "no hits" from
        // "those files were unreadable". Constraining to an empty set returns
        // fast (executor early-exits), so the cost is just the walk.
        if hitFiles.isEmpty {
            let plain = await runPlainExecutor(
                workFolderRoot: workFolderRoot,
                resolver: resolver,
                internalDir: internalDir,
                payload: payload,
                constrainToFiles: nil
            )
            await finalizeEnvelope(
                envelope: ExploratorySearchEnvelope.make(
                    payload: payload,
                    expanded: expanded,
                    output: SearchExecutorOutput(
                        matches: [],  // posting intersection was empty — no matches
                        skipped: plain.output.skipped,
                        skippedBinaryCount: plain.output.skippedBinaryCount,
                        truncated: false
                    ),
                    hitFilesCount: 0,
                    filenameMatches: indexFilenameMatches,
                    expansionError: expansionError,
                    searchError: plain.searchError,
                    exploratoryDisabled: false
                ),
                result: result,
                toolCallID: toolCallID,
                stepID: stepID,
                taskID: taskID,
                conversationMessages: &conversationMessages,
                tracker: tracker
            )
            return
        }

        let plain = await runPlainExecutor(
            workFolderRoot: workFolderRoot,
            resolver: resolver,
            internalDir: internalDir,
            payload: payload,
            constrainToFiles: hitFiles,
            extraQueries: expanded
        )

        // `hit_files` semantics intentionally vary by branch:
        // - Success (here): posting-intersection count, i.e. "candidate
        //   files the broad query touched" — useful for the LLM to judge
        //   scope even when the grep budget truncates returned matches.
        // - Disabled / fall-back / empty-postings: unique paths in the
        //   returned matches, since no posting intersection ran.
        // Keeping both under one field name because the caller that cares
        // about distinguishing them can inspect `exploratory_disabled`
        // and `expansion_error`.
        await finalizeEnvelope(
            envelope: ExploratorySearchEnvelope.make(
                payload: payload,
                expanded: expanded,
                output: plain.output,
                hitFilesCount: hitFiles.count,
                filenameMatches: indexFilenameMatches,
                expansionError: expansionError,
                searchError: plain.searchError,
                exploratoryDisabled: false
            ),
            result: result,
            toolCallID: toolCallID,
            stepID: stepID,
            taskID: taskID,
            conversationMessages: &conversationMessages,
            tracker: tracker
        )
    }

    // MARK: - Private Helpers

    /// Single source of truth for the term list passed to BOTH posting
    /// intersection and filename matching. Keeping this in one helper
    /// guarantees the two consumers can never silently disagree on what
    /// the search asked about — a real bug we hit before the helper
    /// existed (different orderings, easy to drift).
    static func unionSearchTerms(
        query: String, tokens: Set<String>, expanded: [String]
    ) -> [String] {
        // Original query first so `FilenameMatcher`'s ordered iteration
        // attributes basename hits to the literal term when possible.
        // Tokens follow as fallback for multi-word queries that aren't
        // a posting key on their own. Expansion last (lowest priority).
        [query] + Array(tokens) + expanded
    }

    /// The two index-wide computations the exploratory path performs before it greps anything:
    /// the posting intersection that narrows the walk, and filename matching over the FULL
    /// roster.
    ///
    /// - Posting intersection is a union over the postings of every search term. The literal
    ///   query is rarely a posting key on its own (multi-word queries never are), so without the
    ///   query's TOKENS the union for "team meeting service" against a corpus holding `team`,
    ///   `meeting` and `service` postings returns zero candidate files.
    /// - Filename matching runs over the whole roster rather than just `hitFiles`, so a file
    ///   whose NAME matches an expanded vocab term still surfaces even when its content
    ///   intersected no posting list. The index builder already applied `WalkSkipRules` and the
    ///   internal-dir exclusion, so these paths are sandbox-clean.
    ///
    /// `@concurrent` rather than plain `nonisolated`: under `SWIFT_APPROACHABLE_CONCURRENCY` a
    /// `nonisolated async` function runs on the CALLER's executor (SE-0461), and every caller
    /// here is `@MainActor`. Both passes are O(index) with no upper bound — the roster on this
    /// work folder is several thousand paths — so leaving them with the caller freezes the UI
    /// for the length of a search nobody asked the main thread to do.
    @concurrent
    nonisolated static func narrowAndMatchNames(
        index: SearchIndex, unionTerms: [String], limit: Int
    ) async -> (hitFiles: [String], filenameMatches: [FilenameMatch]) {
        (
            hitFiles: index.files(containing: unionTerms),
            filenameMatches: FilenameMatcher.match(
                candidates: index.files.map(\.path), queries: unionTerms, limit: limit)
        )
    }

    /// Outcome of a plain-executor pass. When `SearchExecutor.run` throws
    /// (e.g. sandbox-reject of an absolute `paths` entry, regex compile
    /// failure raised from an upstream caller), the envelope must NOT
    /// silently collapse to empty — `searchError` carries the reason so the
    /// LLM can distinguish a clean "no matches" from a swallowed exception.
    struct PlainExecutorResult {
        let output: SearchExecutorOutput
        let searchError: String?
    }

    func runPlainExecutor(
        workFolderRoot: URL,
        resolver: SandboxPathResolver,
        internalDir: URL,
        payload: ExploratorySearchPayload,
        constrainToFiles: [String]?,
        extraQueries: [String] = []
    ) async -> PlainExecutorResult {
        let queries = [payload.query] + extraQueries
        do {
            let output = try await SearchExecutor.run(SearchExecutorInput(
                workFolderRoot: workFolderRoot,
                resolver: resolver,
                fileManager: .default,
                queries: queries,
                mode: payload.mode,
                paths: payload.paths,
                fileGlob: payload.fileGlob,
                contextBefore: payload.contextBefore,
                contextAfter: payload.contextAfter,
                maxResults: payload.maxResults,
                offset: payload.offset,
                constrainToFiles: constrainToFiles,
                internalDir: internalDir
            ))
            return PlainExecutorResult(output: output, searchError: nil)
        } catch {
            // Surface the failure to BOTH channels: the LLM gets a structured
            // `search_error` in its envelope, AND the human Supervisor sees an
            // info banner — without it, a recurring sandbox-reject / regex
            // problem would only show up as confusing empty results.
            delegate?.setLastInfoMessageForUI(
                "Search failed: \(error.localizedDescription) — falling back to limited results."
            )
            return PlainExecutorResult(
                output: .empty,
                searchError: "search_failed: \(error.localizedDescription)"
            )
        }
    }

    private func uniqueFiles(_ matches: [SearchMatch]) -> Int {
        Set(matches.map(\.path)).count
    }

    private func finalizeEnvelope(
        envelope: String,
        result: ToolExecutionResult,
        toolCallID: UUID,
        stepID: String,
        taskID: Int,
        conversationMessages: inout [ChatMessage],
        tracker: ToolCallTracker? = nil
    ) async {
        conversationMessages.append(ChatMessage(
            role: .tool, content: envelope, toolCallID: result.providerID
        ))
        await appendLLMMessage(stepID: stepID, taskID: taskID, role: .tool, content: """
        [CALL] \(result.toolName)
        Arguments: \(result.argumentsJSON)
        
        [RESULT]
        \(envelope)
        """)

        let finalResult = ToolExecutionResult(
            providerID: result.providerID,
            toolName: result.toolName,
            argumentsJSON: result.argumentsJSON,
            outputJSON: envelope,
            isError: false
        )
        await updateToolCallResult(stepID: stepID, taskID: taskID, toolCallID: toolCallID, result: finalResult)

        // Record the FINALIZED envelope in the tool-call tracker. The upstream
        // `processToolResults` skipped this call for `.exploratorySearch` signals
        // because it only had the interim `{"status":"exploring"}` placeholder
        // at that point — without this record, the next iteration's
        // `recentCalls` snapshot for the loop detector would see the placeholder
        // instead of the real envelope.
        tracker?.record(
            toolName: result.toolName,
            argumentsJSON: result.argumentsJSON,
            resultJSON: envelope,
            isError: false
        )
    }
}

// MARK: - Envelope Builder
//
// Stateless namespace so the envelope shape is a single function with clear
// inputs, not a service method threading many positional args.

enum ExploratorySearchEnvelope {

    /// Wire shape for the exploratory-search tool result envelope. Snake-case
    /// field names match what the LLM sees (hot path for model parsing).
    ///
    /// `expansion_error` and `search_error` are orthogonal: the first signals
    /// that the semantic-expansion layer couldn't contribute (index missing,
    /// embedding model not loaded, transient HTTP); the second signals that
    /// the underlying grep executor itself threw. Both can fire in the same
    /// envelope — the LLM sees them as independent degrade signals.
    struct Body: Codable {
        var query: String
        var expanded_terms: [String]
        var matches: [SearchMatch]
        var count: Int
        var hit_files: Int
        var filename_matches: [FilenameMatch]?
        var skipped_files: [SkippedFileGroup]?
        var skipped_binary_count: Int?
        var expansion_error: String?
        var search_error: String?
        var exploratory_disabled: Bool?
    }

    static func make(
        payload: ExploratorySearchPayload,
        expanded: [String],
        output: SearchExecutorOutput,
        hitFilesCount: Int,
        filenameMatches: [FilenameMatch],
        expansionError: String?,
        searchError: String?,
        exploratoryDisabled: Bool
    ) -> String {
        let body = Body(
            query: payload.query,
            expanded_terms: expanded,
            matches: output.matches,
            count: output.matches.count,
            hit_files: hitFilesCount,
            filename_matches: filenameMatches.isEmpty ? nil : filenameMatches,
            skipped_files: output.skipped.isEmpty ? nil : SkippedFileGroup.group(output.skipped),
            skipped_binary_count: output.skippedBinaryCount > 0 ? output.skippedBinaryCount : nil,
            expansion_error: expansionError,
            search_error: searchError,
            exploratory_disabled: exploratoryDisabled ? true : nil
        )
        return makeSuccessEnvelope(data: body, meta: ToolResultMeta(truncated: output.truncated))
    }
}
