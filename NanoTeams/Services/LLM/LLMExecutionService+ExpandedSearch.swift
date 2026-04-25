import Foundation

/// Extension for handling `expand: true` signals emitted by `SearchTool`.
/// Pipeline:
/// 1. Read feature gates from the delegate.
/// 2. Await the token search index (or fall back to plain search on failure).
/// 3. Call `delegate.expandSearchQuery(...)` to get semantic expansion terms
///    via the local vector index (per-token vectors + one whole-phrase
///    `/v1/embeddings` call).
/// 4. Intersect posting lists to narrow the grep scope.
/// 5. Run `SearchExecutor` over [original] + expanded terms.
/// 6. Overwrite the interim "expanding" envelope with the final result.
extension LLMExecutionService {

    func appendExpandedSearchResult(
        result: ToolExecutionResult,
        toolCallID: UUID,
        stepID: String,
        client: any LLMClient,
        networkLogger: NetworkLogger?,
        conversationMessages: inout [ChatMessage],
        memory: ToolCallCache? = nil
    ) async {
        guard case .expandedSearch(let payload) = result.signal else { return }
        guard let delegate else { return }
        guard let workFolderRoot = delegate.workFolderURL else {
            await finalizeEnvelope(
                envelope: ExpandedSearchEnvelope.make(
                    payload: payload,
                    expanded: [],
                    output: .empty,
                    hitFilesCount: 0,
                    expansionError: "no_work_folder",
                    searchError: nil,
                    expandDisabled: false
                ),
                result: result,
                toolCallID: toolCallID,
                stepID: stepID,
                conversationMessages: &conversationMessages,
                memory: memory
            )
            return
        }

        let internalDir = NTMSPaths(workFolderRoot: workFolderRoot).internalDir
        let resolver = SandboxPathResolver(workFolderRoot: workFolderRoot, internalDir: internalDir)

        // Feature disabled → plain search with a marker envelope.
        if !delegate.expandedSearchEnabled {
            let plain = runPlainExecutor(
                workFolderRoot: workFolderRoot,
                resolver: resolver,
                internalDir: internalDir,
                payload: payload,
                constrainToFiles: nil
            )
            await finalizeEnvelope(
                envelope: ExpandedSearchEnvelope.make(
                    payload: payload,
                    expanded: [],
                    output: plain.output,
                    hitFilesCount: uniqueFiles(plain.output.matches),
                    expansionError: nil,
                    searchError: plain.searchError,
                    expandDisabled: true
                ),
                result: result,
                toolCallID: toolCallID,
                stepID: stepID,
                conversationMessages: &conversationMessages,
                memory: memory
            )
            return
        }

        // Await the index (coordinator may be building). `nil` → fall back.
        // Distinguish "default storage, architecturally unsupported" from
        // "real folder, coordinator-returned-nil (true bug)" so the LLM can
        // see which branch fired.
        guard let index = await delegate.awaitSearchIndex() else {
            let plain = runPlainExecutor(
                workFolderRoot: workFolderRoot,
                resolver: resolver,
                internalDir: internalDir,
                payload: payload,
                constrainToFiles: nil
            )
            let expansionReason = delegate.hasRealWorkFolder
                ? "index_unavailable"
                : "expand_unsupported_default_storage"
            await finalizeEnvelope(
                envelope: ExpandedSearchEnvelope.make(
                    payload: payload,
                    expanded: [],
                    output: plain.output,
                    hitFilesCount: uniqueFiles(plain.output.matches),
                    expansionError: expansionReason,
                    searchError: plain.searchError,
                    expandDisabled: false
                ),
                result: result,
                toolCallID: toolCallID,
                stepID: stepID,
                conversationMessages: &conversationMessages,
                memory: memory
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

        // Posting intersection — union over postings for the literal query
        // string, its tokenized parts, and expansion terms. The literal
        // query is rarely a posting key on its own (multi-word queries
        // never are), so without `queryTokens` the union for "team meeting
        // service" against a corpus that contains `team`, `meeting`, and
        // `service` postings would return 0 candidate files and the
        // executor would skip files that obviously match. Tokens are
        // already extracted above for `expandSearchQuery`; reuse them here.
        let hitFiles = index.files(
            containing: Array(queryTokens) + [payload.query] + expanded
        )

        // If the posting intersection returned nothing, short-circuit.
        // We still run the executor against the original query scope so that
        // unreadable-file accounting (`skipped_files` / `skipped_binary_count`)
        // reaches the LLM — otherwise the LLM can't tell "no hits" from
        // "those files were unreadable". Constraining to an empty set returns
        // fast (executor early-exits), so the cost is just the walk.
        if hitFiles.isEmpty {
            let plain = runPlainExecutor(
                workFolderRoot: workFolderRoot,
                resolver: resolver,
                internalDir: internalDir,
                payload: payload,
                constrainToFiles: nil
            )
            await finalizeEnvelope(
                envelope: ExpandedSearchEnvelope.make(
                    payload: payload,
                    expanded: expanded,
                    output: SearchExecutorOutput(
                        matches: [],  // posting intersection was empty — no matches
                        skipped: plain.output.skipped,
                        skippedBinaryCount: plain.output.skippedBinaryCount,
                        truncated: false
                    ),
                    hitFilesCount: 0,
                    expansionError: expansionError,
                    searchError: plain.searchError,
                    expandDisabled: false
                ),
                result: result,
                toolCallID: toolCallID,
                stepID: stepID,
                conversationMessages: &conversationMessages,
                memory: memory
            )
            return
        }

        let plain = runPlainExecutor(
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
        // about distinguishing them can inspect `expand_disabled`
        // and `expansion_error`.
        await finalizeEnvelope(
            envelope: ExpandedSearchEnvelope.make(
                payload: payload,
                expanded: expanded,
                output: plain.output,
                hitFilesCount: hitFiles.count,
                expansionError: expansionError,
                searchError: plain.searchError,
                expandDisabled: false
            ),
            result: result,
            toolCallID: toolCallID,
            stepID: stepID,
            conversationMessages: &conversationMessages,
            memory: memory
        )
    }

    // MARK: - Private Helpers

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
        payload: ExpandedSearchPayload,
        constrainToFiles: [String]?,
        extraQueries: [String] = []
    ) -> PlainExecutorResult {
        let queries = [payload.query] + extraQueries
        do {
            let output = try SearchExecutor.run(SearchExecutorInput(
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
                maxMatchLines: payload.maxMatchLines,
                constrainToFiles: constrainToFiles,
                internalDir: internalDir
            ))
            return PlainExecutorResult(output: output, searchError: nil)
        } catch {
            print("[ExpandedSearch] WARNING: SearchExecutor threw: \(error)")
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
        conversationMessages: inout [ChatMessage],
        memory: ToolCallCache? = nil
    ) async {
        conversationMessages.append(ChatMessage(
            role: .tool, content: envelope, toolCallID: result.providerID
        ))
        await appendLLMMessage(stepID: stepID, role: .tool, content: """
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
        await updateToolCallResult(stepID: stepID, toolCallID: toolCallID, result: finalResult)

        // Record the FINALIZED envelope in the tool-call cache. The upstream
        // `processToolResults` skipped this call for `.expandedSearch` signals
        // because it only had the interim `{"status":"expanding"}` placeholder
        // at that point; without this record, a subsequent identical
        // `expand` call would either not dedup at all or dedup against
        // the placeholder.
        memory?.record(
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

enum ExpandedSearchEnvelope {

    /// Wire shape for the expanded-search tool result envelope. Snake-case
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
        var skipped_files: [SkippedFile]?
        var skipped_binary_count: Int?
        var expansion_error: String?
        var search_error: String?
        var expand_disabled: Bool?
    }

    static func make(
        payload: ExpandedSearchPayload,
        expanded: [String],
        output: SearchExecutorOutput,
        hitFilesCount: Int,
        expansionError: String?,
        searchError: String?,
        expandDisabled: Bool
    ) -> String {
        let body = Body(
            query: payload.query,
            expanded_terms: expanded,
            matches: output.matches,
            count: output.matches.count,
            hit_files: hitFilesCount,
            skipped_files: output.skipped.isEmpty ? nil : output.skipped,
            skipped_binary_count: output.skippedBinaryCount > 0 ? output.skippedBinaryCount : nil,
            expansion_error: expansionError,
            search_error: searchError,
            expand_disabled: expandDisabled ? true : nil
        )
        return makeSuccessEnvelope(data: body, meta: ToolResultMeta(truncated: output.truncated))
    }
}
