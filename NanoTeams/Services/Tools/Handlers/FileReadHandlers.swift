import Foundation

/// Names skipped by `list_files` and `search` directory traversal.
/// Allows useful dotfiles (.gitignore, .env, .eslintrc) while filtering noise.
/// Shared with `SearchIndexService` via `WalkSkipRules.skipped`.
private let listFilesSkippedNames: Set<String> = WalkSkipRules.skipped

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - read_file

struct ReadFileTool: ToolHandler {
    static let name = TN.readFile
    static let schema = ToolSchema(
        name: TN.readFile,
        description: "Read entire file content. The file's line count must not exceed the limit configured in Settings → Tool Behavior (default \(AppDefaults.readFileMaxLines)) — for larger files use `read_lines` with explicit ranges. Auto-extracts PDF/DOCX/RTF/RTFD/ODT/XLSX/PPTX to plain text.",
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

            let fileURL = try resolver.resolveFileURL(relativePath: path)

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .fileNotFound, message: "File not found: \(path)",
                    next: NextHint(
                        suggested_cmd: TN.listFiles,
                        suggested_args: ["path": (path as NSString).deletingLastPathComponent],
                        reason: "Check available files"
                    )
                )
            }

            // RTFD is a file-bundle directory — treat as a single document.
            let isRTFDBundle = isDir.boolValue && fileURL.pathExtension.lowercased() == "rtfd"
            guard !isDir.boolValue || isRTFDBundle else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .notAFile, message: "Path is a directory: \(path)",
                    next: NextHint(
                        suggested_cmd: TN.listFiles,
                        suggested_args: ["path": path],
                        reason: "List directory contents"
                    )
                )
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
            if let extracted = DocumentTextExtractor.extractText(from: fileURL) {
                if DocumentTextExtractor.isFailureMessage(extracted) {
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .commandFailed, message: extracted
                    )
                }
                fullContent = extracted
                encoding = "extracted_text"
            } else {
                // A nil decode here means the file is binary or non-UTF-8.
                // Returning empty content would make the LLM mistake the file
                // for genuinely empty — surface a clear error envelope instead.
                guard let utf8 = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .commandFailed,
                        message: "File is not valid UTF-8 — appears to be binary or in another encoding: \(path)"
                    )
                }
                fullContent = utf8
                encoding = "utf-8"
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
                        suggested_args: ["path": path, "start_line": "1", "end_line": "-1"],
                        reason: "Use read_lines for files larger than \(lineLimit) lines"
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

struct ReadLinesTool: ToolHandler {
    static let name = TN.readLines
    static let schema = ToolSchema(
        name: TN.readLines,
        description: "Read specific lines from a file. Use for large files instead of read_file. Pass end_line=0 or any negative value (e.g. -1) to read through end of file.",
        parameters: JS.object(
            properties: [
                "path": JS.string("Relative path to file"),
                "start_line": JS.integer("Start line number (1-based)"),
                "end_line": JS.integer("End line number (1-based, inclusive). Use 0 or -1 to read through end of file."),
            ],
            required: ["path", "start_line", "end_line"]
        )
    )
    static let category: ToolCategory = .fileRead

    let resolver: SandboxPathResolver
    let fileManager: FileManager

    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(resolver: dependencies.resolver, fileManager: dependencies.fileManager)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let path = try requiredString(args, "path")
            let startLine = try requiredInt(args, "start_line")
            let endLine = try requiredInt(args, "end_line")
            let includeLineNumbers = optionalBool(args, "include_line_numbers", default: true)

            guard startLine >= 1 else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs, message: "start_line must be >= 1"
                )
            }

            // end_line <= 0 is a Unix-style "read to EOF" sentinel (some models
            // routinely emit -1). Positive but < start_line is still an error,
            // with a message that teaches the sentinel so the model can self-correct.
            let readToEOF = endLine <= 0
            if !readToEOF && endLine < startLine {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .invalidArgs,
                    message: "end_line (\(endLine)) must be >= start_line (\(startLine)). To read through end of file, pass end_line=0 or -1."
                )
            }

            let fileURL = try resolver.resolveFileURL(relativePath: path)

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .fileNotFound, message: "File not found: \(path)"
                )
            }

            let isRTFDBundle = isDir.boolValue && fileURL.pathExtension.lowercased() == "rtfd"
            if isDir.boolValue && !isRTFDBundle {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .notAFile, message: "Path is a directory: \(path)",
                    next: NextHint(
                        suggested_cmd: TN.listFiles,
                        suggested_args: ["path": path],
                        reason: "List directory contents"
                    )
                )
            }

            let content: String
            if let extracted = DocumentTextExtractor.extractText(from: fileURL) {
                if DocumentTextExtractor.isFailureMessage(extracted) {
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .commandFailed, message: extracted
                    )
                }
                content = extracted
            } else {
                content = try String(contentsOf: fileURL, encoding: .utf8)
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

            let actualEndLine = readToEOF ? totalLines : min(endLine, totalLines)
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
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: ReadRangeData(
                    path: path,
                    content: resultContent,
                    start_line: startLine,
                    end_line: actualEndLine,
                    total_lines: totalLines
                )
            )
        }
    }
}

// MARK: - list_files

struct ListFilesTool: ToolHandler {
    static let name = TN.listFiles
    static let schema = ToolSchema(
        name: TN.listFiles,
        description: "List contents of a directory.",
        parameters: JS.object(
            properties: [
                "path": JS.string("Relative path to directory"),
                "depth": JS.integer("Traversal depth (1-5)"),
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
            let depth = optionalInt(args, "depth") ?? 1
            let includeFiles = optionalBool(args, "include_files", default: true)
            let includeDirs = optionalBool(args, "include_dirs", default: true)
            let sortBy = optionalString(args, "sort") ?? "name"

            let dirURL = try resolver.resolveFileURL(relativePath: path)

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .notADirectory, message: "Not a directory: \(path)"
                )
            }

            var entries: [Entry] = []
            let maxEntries = ToolConstants.maxDirectoryEntries
            let fm = fileManager
            let internalDir = self.internalDir

            func listDir(at url: URL, relativePath: String, currentDepth: Int) {
                guard currentDepth <= depth else { return }
                guard entries.count < maxEntries else { return }

                guard let contents = try? fm.contentsOfDirectory(atPath: url.path) else { return }

                for name in contents {
                    guard entries.count < maxEntries else { return }
                    guard !listFilesSkippedNames.contains(name) else { continue }

                    let itemURL = url.appendingPathComponent(name)
                    if let internalDir, SandboxPathResolver.isWithin(candidate: itemURL, container: internalDir) { continue }
                    var itemIsDir: ObjCBool = false
                    guard fm.fileExists(atPath: itemURL.path, isDirectory: &itemIsDir) else {
                        continue
                    }

                    let entryPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                    let entryType = itemIsDir.boolValue ? "dir" : "file"

                    let shouldInclude =
                        (itemIsDir.boolValue && includeDirs) || (!itemIsDir.boolValue && includeFiles)

                    if shouldInclude {
                        entries.append(Entry(path: entryPath, name: name, type: entryType))
                    }

                    if itemIsDir.boolValue && currentDepth < depth {
                        listDir(at: itemURL, relativePath: entryPath, currentDepth: currentDepth + 1)
                    }
                }
            }

            listDir(at: dirURL, relativePath: "", currentDepth: 1)

            if sortBy == "type" {
                entries.sort { ($0.type, $0.name) < ($1.type, $1.name) }
            } else {
                entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }

            let truncated = entries.count >= maxEntries

            struct ListData: Codable {
                var path: String
                var entries: [Entry]
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: ListData(path: path, entries: entries),
                meta: ToolResultMeta(truncated: truncated)
            )
        }
    }
}

// MARK: - search

struct SearchTool: ToolHandler {
    static let name = TN.search
    static let schema = ToolSchema(
        name: TN.search,
        description: "Search for text across the work folder. Reads plain text (including .html/.xml/.md source) plus PDF/DOCX/RTF/RTFD/ODT/XLSX/PPTX (auto-extracted to plain text). Returns matching content lines in `matches` AND files whose name or relative path contains the query in `filename_matches` (basename hits sort first, then by path). Use `context_before` / `context_after` to widen each match with surrounding source lines. Narrow with file_glob for large doc-heavy folders. exploratory=true also applies vocab expansion to filename matching.",
        parameters: JS.object(
            properties: [
                "query": JS.string("Search query (substring match)"),
                "max_results": JS.integer("Max number of results returned. Defaults to the user-configured value in Settings → Tool Behavior (default \(AppDefaults.searchMaxResults))."),
                "context_before": JS.integer("Number of source lines to include before each match. Defaults to the user-configured value in Settings → Tool Behavior (default \(AppDefaults.searchContextBefore)). Use 2-5 when you need surrounding context (function signatures, imports, comment headers)."),
                "context_after": JS.integer("Number of source lines to include after each match. Defaults to the user-configured value in Settings → Tool Behavior (default \(AppDefaults.searchContextAfter)). Use 2-5 to see what follows a hit."),
                "exploratory": JS.boolean("Run an exploratory pass via a local vocab vector index — surfaces synonyms, cross-language translations (e.g. Russian↔English), and camelCase/snake_case variants of each token. SET TO TRUE whenever any of these holds: (1) the query is in a different language than the codebase, (2) you don't know the project's exact naming for the concept, (3) a previous plain search returned 0 or very few hits. Always retry with exploratory=true before falling back to list_files/read_file or escalating to ask_supervisor."),
            ],
            required: ["query"]
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
            let query = try requiredString(canonicalArgs, "query")
            let mode = SearchMode(raw: optionalString(canonicalArgs, "mode"))
            let paths = optionalStringArray(canonicalArgs, "paths")
            let fileGlob = optionalString(canonicalArgs, "file_glob")
            let maxResults = optionalInt(canonicalArgs, "max_results") ?? defaultMaxResults
            let contextBefore = optionalInt(canonicalArgs, "context_before") ?? defaultContextBefore
            let contextAfter = optionalInt(canonicalArgs, "context_after") ?? defaultContextAfter
            let maxMatchLines = optionalInt(canonicalArgs, "max_match_lines") ?? 40

            // Exploratory-search mode: hand off to the processor via a signal.
            // Body of the final result is produced in `appendExploratorySearchResult`.
            // Payload init throws on empty query and clamps out-of-range
            // numerics — `ToolErrorHandler.execute` turns the throw into a
            // standard error envelope for the LLM.
            if exploratory {
                let payload = try ExploratorySearchPayload(
                    query: query,
                    mode: mode,
                    paths: paths,
                    fileGlob: fileGlob,
                    contextBefore: contextBefore,
                    contextAfter: contextAfter,
                    maxResults: maxResults,
                    maxMatchLines: maxMatchLines
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
                maxMatchLines: maxMatchLines,
                constrainToFiles: nil,
                internalDir: internalDir
            ))

            struct SearchData: Codable {
                var query: String
                var matches: [SearchMatch]
                var count: Int
                var filename_matches: [FilenameMatch]?
                var skipped_files: [SkippedFile]?
                var skipped_binary_count: Int?
            }

            return makeSuccessResult(
                toolName: Self.name, args: canonicalArgs,
                data: SearchData(
                    query: query,
                    matches: output.matches,
                    count: output.matches.count,
                    filename_matches: output.filenameMatches.isEmpty ? nil : output.filenameMatches,
                    skipped_files: output.skipped.isEmpty ? nil : output.skipped,
                    skipped_binary_count: output.skippedBinaryCount > 0 ? output.skippedBinaryCount : nil
                ),
                meta: ToolResultMeta(truncated: output.truncated)
            )
        }
    }
}
