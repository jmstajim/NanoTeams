import Foundation

/// Names skipped by `list_files` and `search` directory traversal.
/// Allows useful dotfiles (.gitignore, .env, .eslintrc) while filtering noise.
private let listFilesSkippedNames: Set<String> = [".DS_Store", ".git", ".svn", ".hg", ".build"]

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - read_file

struct ReadFileTool: ToolHandler {
    static let name = TN.readFile
    static let schema = ToolSchema(
        name: TN.readFile,
        description: "Read file content. Returns plain text files verbatim (source code, .html, .xml, .md, .json, etc.) and auto-extracts PDF/DOCX/RTF/RTFD/ODT/XLSX/PPTX to plain text.",
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

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(resolver: dependencies.resolver, fileManager: dependencies.fileManager)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let path = try requiredString(args, "path")
            let maxBytes = optionalInt(args, "max_bytes") ?? 200_000
            let encoding = optionalString(args, "encoding") ?? "utf-8"

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
                var size: Int
                var encoding: String
            }

            if let extracted = DocumentTextExtractor.extractText(from: fileURL) {
                // Extraction failure → error result (avoids polluting MemoryTagStore/ToolCallCache).
                if DocumentTextExtractor.isFailureMessage(extracted) {
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .commandFailed, message: extracted
                    )
                }

                let byteCount = extracted.utf8.count
                let truncated = byteCount > maxBytes
                let content = truncated
                    ? DocumentTextExtractor.truncateToUTF8Bytes(extracted, maxBytes: maxBytes)
                    : extracted
                return makeSuccessResult(
                    toolName: Self.name, args: args,
                    data: ReadFileData(
                        path: path, content: content,
                        size: byteCount, encoding: "extracted_text"
                    ),
                    meta: ToolResultMeta(truncated: truncated)
                )
            }

            // Standard UTF-8 text path
            let data = try Data(contentsOf: fileURL)
            var truncated = false
            let contentData: Data
            if data.count > maxBytes {
                contentData = data.prefix(maxBytes)
                truncated = true
            } else {
                contentData = data
            }

            let content = String(data: contentData, encoding: .utf8) ?? ""
            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: ReadFileData(path: path, content: content, size: data.count, encoding: encoding),
                meta: ToolResultMeta(truncated: truncated)
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
        description: "Search for text across the work folder. Reads plain text (including .html/.xml/.md source) plus PDF/DOCX/RTF/RTFD/ODT/XLSX/PPTX (auto-extracted to plain text). Returns matching lines with file paths. Narrow with file_glob for large doc-heavy folders.",
        parameters: JS.object(
            properties: [
                "query": JS.string("Search query (substring match)"),
                "max_results": JS.integer("Max number of results"),
            ],
            required: ["query"]
        )
    )
    static let category: ToolCategory = .fileRead

    let resolver: SandboxPathResolver
    let fileManager: FileManager
    let workFolderRoot: URL
    let internalDir: URL?

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(resolver: dependencies.resolver, fileManager: dependencies.fileManager, workFolderRoot: dependencies.workFolderRoot, internalDir: dependencies.internalDir)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let query = try requiredString(args, "query")
            let mode = optionalString(args, "mode") ?? "substring"
            let paths = optionalStringArray(args, "paths")
            let fileGlob = optionalString(args, "file_glob")
            let maxResults = optionalInt(args, "max_results") ?? 20
            let contextBefore = optionalInt(args, "context_before") ?? 0
            let contextAfter = optionalInt(args, "context_after") ?? 0
            let maxMatchLines = optionalInt(args, "max_match_lines") ?? 40

            let fm = fileManager
            let workFolderRoot = self.workFolderRoot
            let internalDir = self.internalDir

            var searchDirs: [URL] = []
            if let paths = paths, !paths.isEmpty {
                for p in paths {
                    let url = try resolver.resolveFileURL(relativePath: p)
                    searchDirs.append(url)
                }
            } else {
                searchDirs = [workFolderRoot]
            }

            let regex: NSRegularExpression?
            if mode == "regex" {
                regex = try? NSRegularExpression(pattern: query, options: [])
            } else {
                regex = nil
            }

            var matches: [SearchMatch] = []
            var totalMatchLines = 0
            // Track files that could not be indexed so the LLM/user can see
            // WHY a match might be missing, instead of interpreting silence as
            // "no documents matched".
            var skipped: [SkippedFile] = []
            // Aggregate counter for files silently skipped under the "too noisy
            // to list individually" rule below — lets the LLM tell "empty scope"
            // from "scope had N unreadable binaries".
            var skippedBinaryCount = 0

            func searchFile(at url: URL, relativePath: String) {
                guard matches.count < maxResults && totalMatchLines < maxMatchLines else { return }

                let content: String
                let ext = url.pathExtension.lowercased()
                if DocumentTextExtractor.isSupported(extension: ext) {
                    guard let extracted = DocumentTextExtractor.extractText(from: url) else {
                        // isSupported promised a known format; a nil return means
                        // the document type was supported on paper but the file
                        // itself wasn't actually openable as that type.
                        skipped.append(SkippedFile(
                            path: relativePath,
                            reason: "document extractor could not open file as .\(ext)"
                        ))
                        return
                    }
                    if DocumentTextExtractor.isFailureMessage(extracted) {
                        skipped.append(SkippedFile(path: relativePath, reason: extracted))
                        return
                    }
                    content = extracted
                } else {
                    guard let utf8 = try? String(contentsOf: url, encoding: .utf8) else {
                        // Binary-or-non-UTF8 file on an unsupported extension —
                        // intentionally NOT added to `skipped` (too noisy; every
                        // `.png`/`.o` in the tree would show up). Counted so the
                        // LLM can tell "empty scope" from "scope had N binaries".
                        skippedBinaryCount += 1
                        return
                    }
                    content = utf8
                }
                let lines = content.components(separatedBy: .newlines)

                for (idx, line) in lines.enumerated() {
                    guard matches.count < maxResults && totalMatchLines < maxMatchLines else { return }

                    let found: Bool
                    if let regex = regex {
                        let range = NSRange(line.startIndex..., in: line)
                        found = regex.firstMatch(in: line, options: [], range: range) != nil
                    } else {
                        found = line.localizedCaseInsensitiveContains(query)
                    }

                    if found {
                        var contextBeforeLines: [LineRef]?
                        var contextAfterLines: [LineRef]?

                        if contextBefore > 0 {
                            let startIdx = max(0, idx - contextBefore)
                            contextBeforeLines = (startIdx..<idx).map { i in
                                LineRef(line: i + 1, text: lines[i])
                            }
                        }

                        if contextAfter > 0 {
                            let endIdx = min(lines.count, idx + contextAfter + 1)
                            contextAfterLines = ((idx + 1)..<endIdx).map { i in
                                LineRef(line: i + 1, text: lines[i])
                            }
                        }

                        matches.append(
                            SearchMatch(
                                path: relativePath,
                                line: idx + 1,
                                text: line,
                                context_before: contextBeforeLines,
                                context_after: contextAfterLines
                            ))
                        totalMatchLines +=
                            1 + (contextBeforeLines?.count ?? 0) + (contextAfterLines?.count ?? 0)
                    }
                }
            }

            func searchDirectory(at url: URL, relativePath: String) {
                guard matches.count < maxResults && totalMatchLines < maxMatchLines else { return }

                guard let contents = try? fm.contentsOfDirectory(atPath: url.path) else { return }

                for name in contents.sorted() {
                    guard matches.count < maxResults && totalMatchLines < maxMatchLines else { return }
                    guard !listFilesSkippedNames.contains(name) else { continue }

                    let itemURL = url.appendingPathComponent(name)
                    if let internalDir, SandboxPathResolver.isWithin(candidate: itemURL, container: internalDir) { continue }
                    let itemPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"

                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: itemURL.path, isDirectory: &isDir) else { continue }

                    // RTFD is a file-bundle directory — treat as a single document.
                    if isDir.boolValue && name.hasSuffix(".rtfd") {
                        searchFile(at: itemURL, relativePath: itemPath)
                        continue
                    }

                    if isDir.boolValue {
                        searchDirectory(at: itemURL, relativePath: itemPath)
                    } else {
                        if let glob = fileGlob {
                            let escaped = NSRegularExpression.escapedPattern(for: glob)
                            let pattern = escaped.replacingOccurrences(of: "\\*", with: ".*")
                            if let regex = try? NSRegularExpression(
                                pattern: "^\(pattern)$", options: [])
                            {
                                let range = NSRange(name.startIndex..., in: name)
                                if regex.firstMatch(in: name, options: [], range: range) == nil {
                                    continue
                                }
                            }
                        }
                        searchFile(at: itemURL, relativePath: itemPath)
                    }
                }
            }

            for dir in searchDirs {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        let rel = dir.path.replacingOccurrences(
                            of: workFolderRoot.path + "/", with: "")
                        searchDirectory(at: dir, relativePath: rel == dir.path ? "" : rel)
                    } else {
                        let rel = dir.path.replacingOccurrences(
                            of: workFolderRoot.path + "/", with: "")
                        searchFile(at: dir, relativePath: rel)
                    }
                }
            }

            let truncated = matches.count >= maxResults || totalMatchLines >= maxMatchLines

            struct SearchData: Codable {
                var query: String
                var matches: [SearchMatch]
                var count: Int
                var skipped_files: [SkippedFile]?
                var skipped_binary_count: Int?
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: SearchData(
                    query: query,
                    matches: matches,
                    count: matches.count,
                    skipped_files: skipped.isEmpty ? nil : skipped,
                    skipped_binary_count: skippedBinaryCount > 0 ? skippedBinaryCount : nil
                ),
                meta: ToolResultMeta(truncated: truncated)
            )
        }
    }
}
