import Foundation

/// Names skipped by `list_files` and `search` directory traversal.
/// Allows useful dotfiles (.gitignore, .env, .eslintrc) while filtering noise.
/// Shared with `SearchIndexService` via `WalkSkipRules.skipped`.
nonisolated private let listFilesSkippedNames: Set<String> = WalkSkipRules.skipped

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - read_file

nonisolated struct ReadFileTool: ToolHandler {
    static let name = TN.readFile
    static let schema = ToolSchema(
        name: TN.readFile,
        description: "Read entire file content. Auto-extracts PDF/DOCX/RTF/RTFD/ODT/XLSX/PPTX to plain text.",
        parameters: JS.object(
            properties: [
                "path": JS.string("Relative path to file"),
            ],
            required: ["path"]
        )
    )
    static let category: ToolCategory = .fileRead

    let resolver: SandboxPathResolver
    let fileManager: FileManager
    /// Hard line cap. `0` means unlimited (no size check).
    let lineLimit: Int

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(resolver: dependencies.resolver, fileManager: dependencies.fileManager, lineLimit: dependencies.readFileMaxLines)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let path = try requiredString(args, "path")

            // Resolve + validate (existence, RTFD-as-file, directory rejection).
            // read_file's not-found hint points at the parent directory.
            let fileURL: URL
            switch try FileReadSupport.resolveReadableFile(
                toolName: Self.name, args: args, path: path,
                resolver: resolver, fileManager: fileManager,
                notFoundNext: NextHint(
                    suggested_cmd: TN.listFiles,
                    suggested_args: ["path": (path as NSString).deletingLastPathComponent],
                    reason: "Check available files"
                )
            ) {
            case .file(let url): fileURL = url
            case .rejected(let err): return err
            }

            struct ReadFileData: Codable {
                var path: String
                var content: String
                var start_line: Int
                var end_line: Int
                var total_lines: Int
                var encoding: String
            }

            // Extract content (PDF/DOCX/RTF/etc. → plain text; otherwise raw UTF-8).
            let fullContent: String
            let encoding: String
            switch FileReadSupport.extractContent(
                toolName: Self.name, args: args, path: path, fileURL: fileURL
            ) {
            case .text(let content, let enc): fullContent = content; encoding = enc
            case .failure(let err): return err
            }

            let allLines = fullContent.components(separatedBy: .newlines)
            let totalLines = allLines.count

            // Hard block: file exceeds configured limit. `lineLimit == 0` is the
            // "unlimited" sentinel — skip the check entirely so the LLM gets the
            // full file regardless of size.
            if lineLimit > 0 && totalLines > lineLimit {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "File has \(totalLines) lines, exceeding the \(lineLimit)-line read_file limit. Use read_lines with explicit ranges.",
                    next: NextHint(
                        suggested_cmd: TN.readLines,
                        suggested_args: ["path": path, "start_line": "1", "end_line": String(lineLimit)],
                        reason: "Read first \(lineLimit) lines; paginate from end_line for the rest"
                    )
                )
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: ReadFileData(
                    path: path,
                    content: fullContent,
                    start_line: totalLines == 0 ? 0 : 1,
                    end_line: totalLines,
                    total_lines: totalLines,
                    encoding: encoding
                )
            )
        }
    }
}

// MARK: - read_lines

nonisolated struct ReadLinesTool: ToolHandler {
    static let name = TN.readLines
    static let schema = ToolSchema(
        name: TN.readLines,
        description: "Read a line range from a file. When the result carries `next_start_line`, the range was capped — repeat the same call with `start_line` set to it.",
        parameters: JS.object(
            properties: [
                "path": JS.string("Relative path to file"),
                "start_line": JS.integer("Start line number (1-based)."),
                "end_line": JS.integer("End line number (1-based, inclusive). Omit to read to end of file."),
                "include_line_numbers": JS.boolean("Set false to drop the line-number gutter when you only need raw text."),
            ],
            required: ["path", "start_line"]
        )
    )
    static let category: ToolCategory = .fileRead

    let resolver: SandboxPathResolver
    let fileManager: FileManager
    /// `0` means unlimited.
    let lineLimit: Int

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(resolver: dependencies.resolver, fileManager: dependencies.fileManager, lineLimit: dependencies.readFileMaxLines)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let path = try requiredString(args, "path")
            let startLineRaw = try requiredInt(args, "start_line")
            let endLineRaw = optionalInt(args, "end_line") ?? 0
            let includeLineNumbers = optionalBool(args, "include_line_numbers", default: true)

            // `endLineRaw <= 0` is the "read to EOF" intent (omitted / 0 / -1
            // all collapse here). Per CORE_PRINCIPLES the runtime absorbs
            // LLM sloppiness silently — no error envelope.
            let readToEOF = endLineRaw <= 0

            // Transposed range (e.g. start: 100, end: 50) clearly meant 50..100.
            // Silently swap and proceed.
            let startLine: Int
            let endLine: Int
            if !readToEOF && endLineRaw < startLineRaw {
                startLine = endLineRaw
                endLine = startLineRaw
            } else {
                startLine = startLineRaw
                endLine = endLineRaw
            }

            guard startLine >= 1 else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs, message: "start_line must be >= 1"
                )
            }

            // Resolve + validate. read_lines omits the not-found hint.
            let fileURL: URL
            switch try FileReadSupport.resolveReadableFile(
                toolName: Self.name, args: args, path: path,
                resolver: resolver, fileManager: fileManager, notFoundNext: nil
            ) {
            case .file(let url): fileURL = url
            case .rejected(let err): return err
            }

            let content: String
            switch FileReadSupport.extractContent(
                toolName: Self.name, args: args, path: path, fileURL: fileURL
            ) {
            case .text(let extracted, _): content = extracted
            case .failure(let err): return err
            }
            let allLines = content.components(separatedBy: .newlines)
            let totalLines = allLines.count

            guard startLine <= totalLines else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .rangeOutOfBounds,
                    message: "start_line \(startLine) exceeds file length \(totalLines)"
                )
            }

            let requestedEndLine = readToEOF ? totalLines : min(endLine, totalLines)

            // `lineLimit == 0` is the "unlimited" sentinel. A capped read is signalled by
            // `next_start_line` in the envelope rather than by asking the model to notice
            // `end_line < total_lines` and then compute `end_line + 1` — the same arithmetic
            // instruction removed from `search`'s paging, on a much hotter path.
            let actualEndLine: Int
            if lineLimit > 0 {
                actualEndLine = min(requestedEndLine, startLine + lineLimit - 1)
            } else {
                actualEndLine = requestedEndLine
            }
            let selectedLines = Array(allLines[(startLine - 1)..<actualEndLine])

            let resultContent: String
            if includeLineNumbers {
                let maxLineNum = actualEndLine
                let padWidth = max(4, String(maxLineNum).count + 1)
                resultContent = selectedLines.enumerated().map { idx, line in
                    let num = String(startLine + idx)
                    let padded = num.padding(toLength: padWidth, withPad: " ", startingAt: 0)
                    return "\(padded)\u{2502} \(line)"
                }.joined(separator: "\n")
            } else {
                resultContent = selectedLines.joined(separator: "\n")
            }

            struct ReadRangeData: Codable {
                var path: String
                var content: String
                var start_line: Int
                var end_line: Int
                var total_lines: Int
                /// Where to resume when the range was capped, or `nil` when the file ended here.
                /// Present exactly when unread lines remain past `end_line`.
                var next_start_line: Int?
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: ReadRangeData(
                    path: path,
                    content: resultContent,
                    start_line: startLine,
                    end_line: actualEndLine,
                    total_lines: totalLines,
                    next_start_line: actualEndLine < totalLines ? actualEndLine + 1 : nil
                )
            )
        }
    }
}

// MARK: - list_files

nonisolated struct ListFilesTool: ToolHandler {
    static let name = TN.listFiles
    static let schema = ToolSchema(
        name: TN.listFiles,
        description: "List contents of a directory. Returns `files` and `dirs` as separate arrays of paths relative to the work-folder root; pass any entry straight to the other file tools.",
        parameters: JS.object(
            properties: [
                "path": JS.string("Relative path to directory ('.' or omit = work-folder root)"),
                "depth": JS.integer("Recursion depth: 0 = direct contents, 1 = one level deeper."),
                "name_glob": JS.string("Only include entries whose name matches this basename glob (e.g. *.gd). Combine with depth to list a file type recursively."),
            ]
        )
    )
    static let category: ToolCategory = .fileRead

    let resolver: SandboxPathResolver
    let fileManager: FileManager
    let internalDir: URL?

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(resolver: dependencies.resolver, fileManager: dependencies.fileManager, internalDir: dependencies.internalDir)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let path = optionalString(args, "path") ?? "."
            // `depth` is RECURSION depth counted from zero — the way models actually
            // spell it: 0 = this folder's direct contents, 1 = also one level of
            // subfolders. The walk counts LEVELS from 1, hence `levels = depth + 1`.
            //
            // The zero end used to return a successful EMPTY listing, and models open
            // a fresh work folder with exactly `depth: 0`, so the first orientation
            // call answered "your project is empty" and planning proceeded from that.
            // Same call as `read_lines` accepting `-1`/`0` as through-EOF sentinels
            // rather than rejecting: take the convention the model already holds
            // instead of burning a round-trip teaching it ours.
            //
            // Erring toward one level too many costs tokens; erring toward one too
            // few makes a populated subfolder look empty, which is the failure mode
            // worth designing against.
            //
            // Clamped below at 0 (negatives are the same nonsense as the old zero) and
            // below `Int.max` so the `+ 1` cannot overflow on a wild model-supplied value.
            let depth = min(max(0, optionalInt(args, "depth") ?? 0), Int.max - 1)
            let levels = depth + 1
            // Trim to content and treat empty/whitespace as "no filter": an
            // untrimmed `"*.gd "` anchors to `^.*\.gd $` (matches nothing) and a
            // literal `""` anchors to `^$` (matches only empty names) — both
            // silently exclude every entry.
            let nameGlob = optionalString(args, "name_glob").flatMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            // Validate up front so a bad glob surfaces as a typed error instead
            // of fail-closing on every entry. Translate the file_glob-scoped
            // SearchExecutorError into a name_glob-named message — surfacing it
            // verbatim would tell the model to fix a `file_glob` arg that
            // `list_files` doesn't have (a loop hazard for weaker models).
            // Compiling it here doubles as that validation, and is the whole point: the previous
            // shape called the now-removed `GlobMatcher.matches(name:glob:)` inside the per-entry loop, which
            // built a fresh `NSRegularExpression` for EVERY directory entry — the same defect
            // already fixed in the search walk.
            let compiledNameGlob: CompiledGlob?
            do {
                compiledNameGlob = try nameGlob.map {
                    try CompiledGlob(glob: $0, caseInsensitive: false)
                }
            } catch {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "name_glob '\(nameGlob ?? "")' is not a valid glob (only * is a wildcard)."
                )
            }

            let dirURL = try resolver.resolveFileURL(relativePath: path)

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .notADirectory, message: "Not a directory: \(path)"
                )
            }

            // Entry paths are relative to the WORK-FOLDER ROOT, not to the listed
            // directory — mirrors SearchExecutor, and makes every entry a verbatim
            // valid argument for the file tools (which all resolve from the root
            // via SandboxPathResolver). Derived from the RESOLVED url rather than
            // the raw arg so it reflects whatever the resolver actually did with
            // absolute paths and redundant work-folder-name components.
            let rootPrefix: String = {
                let rootComponents = resolver.workFolderRoot.standardizedFileURL.pathComponents
                let dirComponents = dirURL.standardizedFileURL.pathComponents
                guard dirComponents.count > rootComponents.count else { return "" }
                return dirComponents.dropFirst(rootComponents.count).joined(separator: "/")
            }()

            var entries: [(path: String, isDir: Bool)] = []
            let maxEntries = ToolConstants.maxDirectoryEntries
            let fm = fileManager
            let internalDir = self.internalDir

            // Collect ONE entry past the cap as a probe. Stopping exactly at the cap
            // cannot distinguish "the directory holds exactly `maxEntries`" from
            // "there was more", so the old `>= maxEntries` flagged a complete listing
            // as truncated and provoked a needless narrowing re-call.
            func listDir(at url: URL, relativePath: String, currentDepth: Int) {
                guard currentDepth <= levels else { return }
                guard entries.count <= maxEntries else { return }

                guard let contents = try? fm.contentsOfDirectory(atPath: url.path) else { return }

                for name in contents {
                    guard entries.count <= maxEntries else { return }
                    guard !listFilesSkippedNames.contains(name) else { continue }

                    let itemURL = url.appendingPathComponent(name)
                    if let internalDir, SandboxPathResolver.isWithin(candidate: itemURL, container: internalDir) { continue }
                    var itemIsDir: ObjCBool = false
                    guard fm.fileExists(atPath: itemURL.path, isDirectory: &itemIsDir) else {
                        continue
                    }

                    let entryPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"

                    // `name_glob` filters which entries are LISTED; recursion
                    // below is unconditional so nested matches under a non-
                    // matching subdirectory are still reachable (mirrors
                    // SearchExecutor's file-glob-filters-files / always-recurse).
                    let matchesGlob = compiledNameGlob?.matches(name) ?? true

                    if matchesGlob {
                        entries.append((path: entryPath, isDir: itemIsDir.boolValue))
                    }

                    if itemIsDir.boolValue && currentDepth < levels {
                        listDir(at: itemURL, relativePath: entryPath, currentDepth: currentDepth + 1)
                    }
                }
            }

            listDir(at: dirURL, relativePath: rootPrefix, currentDepth: 1)

            // Drop the probe BEFORE sorting: in `contentsOfDirectory` order the last
            // element is already arbitrary, whereas after sorting it would be a
            // semantically meaningful entry.
            let truncated = entries.count > maxEntries
            if truncated { entries.removeLast() }

            // Sorted by full PATH, not by basename. Basename order was a natural fit
            // while each entry carried its own `name`; against a bare path list it
            // interleaves directories (`b/apple.txt` before `a/zebra.txt`) and reads
            // as unsorted — a known trigger for re-calling the tool. Path order keeps
            // each subtree contiguous. `localizedStandardCompare` still gives natural
            // numeric ordering, so `f2.txt` precedes `f10.txt`.
            entries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

            var files: [String] = []
            var dirs: [String] = []
            for entry in entries {
                if entry.isDir { dirs.append(entry.path) } else { files.append(entry.path) }
            }

            /// Files and directories are split into two arrays rather than carried as
            /// tagged objects: the key names are self-describing, so the discriminator
            /// costs no schema text (which ships on every request), a file structurally
            /// cannot appear under `dirs`, and no marker rides inside the path string
            /// the model copies verbatim into the other file tools.
            ///
            /// Both arrays are always emitted, including empty ones — unlike
            /// `SearchData`'s nil-out of `skipped_files`, an empty `dirs` here is the
            /// real answer ("no subdirectories"), not an absent exception marker.
            ///
            /// `count` is the number of entries RETURNED, not the size of the
            /// directory: when truncated it equals the cap, and `meta` carries that
            /// fact.
            struct ListData: Codable {
                var path: String
                var count: Int
                var files: [String]
                var dirs: [String]
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: ListData(
                    path: rootPrefix.isEmpty ? "." : rootPrefix,
                    count: files.count + dirs.count,
                    files: files,
                    dirs: dirs
                ),
                meta: ToolResultMeta(
                    truncated: truncated,
                    warnings: truncated
                        ? ["Listing capped at \(maxEntries) entries. Narrow with name_glob, or list a subdirectory."]
                        : []
                )
            )
        }
    }
}

// MARK: - search

nonisolated struct SearchTool: ToolHandler {
    static let name = TN.search
    static let schema = ToolSchema(
        name: TN.search,
        description: "Search the work folder for text, or list files when `query` is omitted. Auto-extracts PDF/DOCX/RTF/RTFD/ODT/XLSX/PPTX. Returns `matches` (the matching line) and `filename_matches` (basename hits first). Results are paged: when `has_more` is true, repeat the same call with `offset` set to `next_offset`.",
        parameters: JS.object(
            properties: [
                "query": JS.string("Case-insensitive literal substring; one keyword per call for distinct concepts. Omit to list all files matching file_glob or paths."),
                "paths": JS.array(items: JS.string("Relative path under the work folder"), description: "Restrict scope. Folders walked recursively; files scanned in place."),
                "file_glob": JS.string("Basename glob (e.g. *.swift, test_*.md)."),
                "max_results": JS.integer("Page size, max \(AppDefaults.searchMaxResultsMax)."),
                "offset": JS.integer("Matches to skip."),
                "context_before": JS.integer("Lines of context before each match. Omit for the matching line alone."),
                "context_after": JS.integer("Lines of context after each match. Omit for the matching line alone."),
                "exploratory": JS.boolean("Set true when a literal `query` found nothing and the wording may differ: adds a vector-index pass over synonyms, cross-language, and camel/snake variants."),
            ]
        )
    )
    static let category: ToolCategory = .fileRead

    let resolver: SandboxPathResolver
    let fileManager: FileManager
    let workFolderRoot: URL
    let internalDir: URL?
    let exploratoryByDefault: Bool
    let defaultMaxResults: Int
    let defaultContextBefore: Int
    let defaultContextAfter: Int


    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(
            resolver: dependencies.resolver,
            fileManager: dependencies.fileManager,
            workFolderRoot: dependencies.workFolderRoot,
            internalDir: dependencies.internalDir,
            exploratoryByDefault: dependencies.searchExploratoryByDefault,
            defaultMaxResults: dependencies.searchMaxResults,
            defaultContextBefore: dependencies.searchContextBefore,
            defaultContextAfter: dependencies.searchContextAfter
        )
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        // Resolve `exploratory` against the default-on setting and write it back into args
        // before any throwing call, so error envelopes (e.g. missing query) also reflect
        // the actual branch taken rather than the verbatim LLM input.
        let exploratory = optionalBool(args, "exploratory", default: exploratoryByDefault)
        var canonicalArgs = args
        canonicalArgs["exploratory"] = exploratory

        return ToolErrorHandler.execute(toolName: Self.name, args: canonicalArgs) {
            // `query` is optional: an empty/omitted query is the "list files"
            // trigger (paired with file_glob or paths). `requiredString` would
            // reject an omitted key and block that path.
            let query = optionalString(canonicalArgs, "query") ?? ""
            let mode = SearchMode(raw: optionalString(canonicalArgs, "mode"))
            // Normalize constraints so a present-but-empty value can't pose as a
            // real one: drop blank/whitespace `paths` entries and treat an empty
            // `file_glob` as absent. Otherwise `paths: [""]` (which resolves to
            // the work-folder root) or `file_glob: ""` (which compiles to `^$`,
            // matching nothing) would slip an empty query past the constraint
            // guard below into a whole-tree walk / silent zero — the exact two
            // outcomes that guard exists to prevent. The normalized values flow
            // to the executor too, so the guard and the walk stay consistent.
            let paths = optionalStringArray(canonicalArgs, "paths")?
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            // Trim the glob to its content: `CompiledGlob` anchors with `^…$`, so
            // a padded `"*.gd "` compiles to `^.*\.gd $` and matches nothing —
            // a silent zero. Store the trimmed value (nil when empty).
            let fileGlob = optionalString(canonicalArgs, "file_glob").flatMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            let maxResults = optionalInt(canonicalArgs, "max_results") ?? defaultMaxResults
            let offset = optionalInt(canonicalArgs, "offset") ?? 0
            let contextBefore = optionalInt(canonicalArgs, "context_before") ?? defaultContextBefore
            let contextAfter = optionalInt(canonicalArgs, "context_after") ?? defaultContextAfter

            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasConstraint = fileGlob != nil || (paths?.isEmpty == false)

            // Empty query + a narrowing constraint = "list matching files".
            // Handled here, BEFORE the exploratory branch, because an empty
            // query has nothing to expand semantically — it must reach the
            // plain executor's list mode (`queries: [""]`) even when
            // `exploratory` is the default-on setting, not hit the exploratory
            // `emptyQuery` throw. Empty query with NO constraint is a typed
            // error — never a silent zero, never a whole-tree dump.
            if trimmedQuery.isEmpty {
                guard hasConstraint else {
                    return makeErrorResult(
                        toolName: Self.name, args: canonicalArgs,
                        code: .invalidArgs,
                        message: "empty query requires file_glob or paths to list files; otherwise provide a search keyword"
                    )
                }
                // Falls through to the plain executor below in list mode.
            } else if exploratory {
                // Exploratory-search mode: hand off to the processor via a
                // signal. Body of the final result is produced in
                // `appendExploratorySearchResult`. Payload init throws on empty
                // query and clamps out-of-range numerics — `ToolErrorHandler`
                // turns the throw into a standard error envelope for the LLM.
                let payload = try ExploratorySearchPayload(
                    query: query,
                    mode: mode,
                    paths: paths,
                    fileGlob: fileGlob,
                    contextBefore: contextBefore,
                    contextAfter: contextAfter,
                    maxResults: maxResults,
                    offset: offset
                )
                return ToolExecutionResult(
                    toolName: Self.name,
                    argumentsJSON: encodeArgsToJSON(canonicalArgs),
                    outputJSON: makeSuccessEnvelope(
                        data: ["query": query, "status": "exploring"]
                    ),
                    isError: false,
                    signal: .exploratorySearch(payload)
                )
            }

            // Plain search path: delegate to SearchExecutor.
            let output = try SearchExecutor.run(SearchExecutorInput(
                workFolderRoot: workFolderRoot,
                resolver: resolver,
                fileManager: fileManager,
                queries: [query],
                mode: mode,
                paths: paths,
                fileGlob: fileGlob,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                maxResults: maxResults,
                offset: offset,
                constrainToFiles: nil,
                internalDir: internalDir
            ))

            struct SearchData: Codable {
                var query: String
                var matches: [SearchMatch]
                /// Results on this page that `offset` advances over — `matches` normally, or
                /// `filename_matches` in list mode (no `query`), where the file roster IS the
                /// result. Sourced from `output.pageCount`, never `matches.count`: in list mode
                /// there are no content matches, so `matches.count` is 0 and "advance `offset`
                /// by `count`" would re-request the same page forever.
                var count: Int
                /// Echoed so a paging caller can see which slice it got back.
                var offset: Int?
                /// Another page exists. Repeat the call with `offset: next_offset`.
                var has_more: Bool?
                /// Where the next page starts. Present exactly when `has_more` is.
                ///
                /// Carried rather than described because the alternative was an instruction to
                /// compute `offset + count` — arithmetic a 7–32B model performs on every page,
                /// where a wrong sum silently re-reads or skips results. Costs nothing: the walk
                /// already knows both terms. NOT a total and not a page count (those would need
                /// the whole corpus scanned); just the cursor for the next call.
                var next_offset: Int?
                /// Exact total for the paged list, present only when it is actually known — the
                /// walk finished, everything fit on this page, and nothing was capped. Never
                /// present together with `has_more`.
                var total_matches: Int?
                var filename_matches: [FilenameMatch]?
                var skipped_files: [SkippedFile]?
                var skipped_binary_count: Int?
            }

            return makeSuccessResult(
                toolName: Self.name, args: canonicalArgs,
                data: SearchData(
                    query: query,
                    matches: output.matches,
                    count: output.pageCount,
                    offset: offset > 0 ? offset : nil,
                    has_more: output.truncated ? true : nil,
                    next_offset: output.truncated ? offset + output.pageCount : nil,
                    total_matches: output.totalMatches,
                    filename_matches: output.filenameMatches.isEmpty ? nil : output.filenameMatches,
                    skipped_files: output.skipped.isEmpty ? nil : output.skipped,
                    skipped_binary_count: output.skippedBinaryCount > 0 ? output.skippedBinaryCount : nil
                ),
                meta: ToolResultMeta(truncated: output.truncated, warnings: output.warnings)
            )
        }
    }
}
