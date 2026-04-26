import Foundation

/// Input bundle for a grep pass — used by both the plain `SearchTool` handler
/// and the exploratory-search processor (which constrains the walk to a posting-hit
/// set before invoking the executor).
struct SearchExecutorInput {
    let workFolderRoot: URL
    let resolver: SandboxPathResolver
    let fileManager: FileManager
    let queries: [String]
    let mode: SearchMode
    let paths: [String]?
    let fileGlob: String?
    let contextBefore: Int
    let contextAfter: Int
    let maxResults: Int
    let maxMatchLines: Int
    /// When non-nil, the executor iterates exactly this set of relative file
    /// paths instead of walking the directory tree. Used by exploratory search after
    /// posting-list intersection narrows the candidate files.
    let constrainToFiles: [String]?
    /// Optional restriction to a set of internal paths that should never be
    /// scanned (e.g. `.nanoteams/internal/`).
    let internalDir: URL?

    init(
        workFolderRoot: URL,
        resolver: SandboxPathResolver,
        fileManager: FileManager,
        queries: [String],
        mode: SearchMode = .substring,
        paths: [String]? = nil,
        fileGlob: String? = nil,
        contextBefore: Int = 0,
        contextAfter: Int = 0,
        maxResults: Int = 20,
        maxMatchLines: Int = 40,
        constrainToFiles: [String]? = nil,
        internalDir: URL? = nil
    ) {
        self.workFolderRoot = workFolderRoot
        self.resolver = resolver
        self.fileManager = fileManager
        self.queries = queries
        self.mode = mode
        self.paths = paths
        self.fileGlob = fileGlob
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.maxResults = maxResults
        self.maxMatchLines = maxMatchLines
        self.constrainToFiles = constrainToFiles
        self.internalDir = internalDir
    }
}

enum SearchMode: String {
    case substring
    case regex

    /// Parse the string that comes out of `SearchTool` arguments. Anything
    /// other than `"regex"` — including `nil`, `"substring"`, typos, or
    /// unknown modes — resolves to `.substring` (the safe default).
    init(raw: String?) {
        self = (raw == "regex") ? .regex : .substring
    }
}

/// Typed errors raised by `SearchExecutor.run`. Distinct from
/// `SandboxPathError` (path resolution) so callers can surface the specific
/// reason — without this, a malformed regex pattern silently produced zero
/// matches with no signal to the LLM that the query itself was the problem.
enum SearchExecutorError: Error, Equatable, LocalizedError {
    /// `mode == .regex` and the supplied pattern failed to compile via
    /// `NSRegularExpression(pattern:options:)`. `query` is the offending
    /// pattern; `message` carries the platform-specific failure detail.
    case regexCompileFailed(query: String, message: String)

    /// The supplied `file_glob` failed to compile after escaping. Without
    /// this throw, `GlobMatcher.matches` would fail-closed on every candidate
    /// and the envelope would carry zero hits with no signal that the glob
    /// itself was the problem — see CLAUDE.md "rename complete" review.
    case invalidFileGlob(pattern: String, message: String)

    /// `LocalizedError` conformance — `error.localizedDescription` is what
    /// reaches the envelope's `search_error` field, so it must be readable.
    var errorDescription: String? {
        switch self {
        case .regexCompileFailed(let query, let message):
            return "regex compile failed for pattern '\(query)': \(message)"
        case .invalidFileGlob(let pattern, let message):
            return "file_glob '\(pattern)' did not compile: \(message)"
        }
    }
}

/// Output of a grep pass. Mirrors `SearchData` fields used by `SearchTool` so
/// the plain path's envelope shape is preserved.
struct SearchExecutorOutput {
    var matches: [SearchMatch]
    var skipped: [SkippedFile]
    var skippedBinaryCount: Int
    /// Truncated because we hit `maxResults` or `maxMatchLines`.
    var truncated: Bool
    /// Files whose name or relative path matched the query, independent of
    /// content. Computed against the same walk that produced `matches`, so
    /// `WalkSkipRules` and `internalDir` exclusion are already applied.
    var filenameMatches: [FilenameMatch]

    init(
        matches: [SearchMatch],
        skipped: [SkippedFile],
        skippedBinaryCount: Int,
        truncated: Bool,
        filenameMatches: [FilenameMatch] = []
    ) {
        self.matches = matches
        self.skipped = skipped
        self.skippedBinaryCount = skippedBinaryCount
        self.truncated = truncated
        self.filenameMatches = filenameMatches
    }

    /// Empty output — convenience for short-circuit branches.
    static var empty: SearchExecutorOutput {
        SearchExecutorOutput(matches: [], skipped: [], skippedBinaryCount: 0, truncated: false)
    }
}

/// Stateless grep engine shared by plain `SearchTool.handle` and the broad-
/// search processor in `LLMExecutionService+ExploratorySearch`.
///
/// Round-robin fan-out across `queries`: for N terms, each query gets
/// `ceil(maxResults / N)` slots in pass 1; a second greedy pass fills any
/// leftover budget. Dedup key is `(path, line)`. Matches from the first query
/// (the original LLM query) come first, expanded terms follow in order.
enum SearchExecutor {

    static func run(_ input: SearchExecutorInput) throws -> SearchExecutorOutput {
        // Pre-validate `file_glob` once. Without this, `GlobMatcher.matches`
        // fail-closes on every candidate and the envelope carries zero hits
        // with no signal that the user's glob is the problem.
        if let glob = input.fileGlob {
            try GlobMatcher.validate(glob: glob)
        }
        // Dedup — a single source line can match multiple expanded terms.
        var dedupKeys: Set<String> = []
        // Bucket matches by query index so we can round-robin the final list.
        var perQueryMatches: [[SearchMatch]] = Array(repeating: [], count: input.queries.count)
        var totalMatchLines = 0
        // Track files that could not be indexed so the LLM/user can see WHY a
        // match might be missing, instead of interpreting silence as "no
        // documents matched".
        var skipped: [SkippedFile] = []
        // Aggregate counter for files silently skipped as "too noisy to list
        // individually" (binary blobs on unsupported extensions) — without
        // this, every `.png`/`.o` in the tree would flood `skipped_files`.
        // The count still lets the LLM tell "empty scope" from "scope had N
        // unreadable binaries".
        var skippedBinaryCount = 0

        // Cap per query = max(1, ceil(maxResults / N))
        let queryCount = max(1, input.queries.count)
        let perQueryCap = max(1, Int((Double(input.maxResults) / Double(queryCount)).rounded(.up)))

        // Pre-compile regexes (if needed) once per query. A malformed pattern
        // throws so the caller can surface the reason in the envelope's
        // `search_error` field — the prior `try?` swallowed the failure and
        // returned zero matches with no signal that the QUERY itself, not the
        // corpus, was the problem.
        let regexes: [NSRegularExpression?] = try input.queries.map { q in
            guard input.mode == .regex else { return nil }
            do {
                return try NSRegularExpression(pattern: q, options: [])
            } catch {
                throw SearchExecutorError.regexCompileFailed(
                    query: q, message: error.localizedDescription
                )
            }
        }

        // Early-return when an empty `constrainToFiles` is supplied — nothing to scan.
        if let constrained = input.constrainToFiles, constrained.isEmpty {
            return SearchExecutorOutput(matches: [], skipped: [], skippedBinaryCount: 0, truncated: false)
        }

        let fm = input.fileManager
        let workFolderRoot = input.workFolderRoot
        let internalDir = input.internalDir

        // Files we enumerated and would have grepped — fed to `FilenameMatcher`
        // after the walk so name/path matches can be returned alongside
        // content matches in one tool call. Bounded by the same content
        // budget that gates the walk, so on saturated searches the filename
        // hit list reflects "what we walked" rather than the entire tree.
        var visitedPaths: [String] = []

        func totalMatches() -> Int { perQueryMatches.reduce(0) { $0 + $1.count } }

        func budgetExhausted() -> Bool {
            totalMatches() >= input.maxResults || totalMatchLines >= input.maxMatchLines
        }

        func searchFile(at url: URL, relativePath: String) {
            guard !budgetExhausted() else { return }

            let content: String
            let ext = url.pathExtension.lowercased()
            if DocumentTextExtractor.isSupported(extension: ext) {
                guard let extracted = DocumentTextExtractor.extractText(from: url) else {
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
                    // Binary (non-UTF-8) files go into the aggregate count,
                    // not `skipped_files` — see WHY comment at the declaration.
                    skippedBinaryCount += 1
                    return
                }
                content = utf8
            }

            let lines = content.components(separatedBy: .newlines)

            for (idx, line) in lines.enumerated() {
                if budgetExhausted() { return }
                for (qIdx, query) in input.queries.enumerated() {
                    guard perQueryMatches[qIdx].count < perQueryCap else { continue }
                    let found: Bool
                    if let regex = regexes[qIdx] {
                        let range = NSRange(line.startIndex..., in: line)
                        found = regex.firstMatch(in: line, options: [], range: range) != nil
                    } else {
                        found = line.localizedCaseInsensitiveContains(query)
                    }
                    guard found else { continue }

                    let key = "\(relativePath)\0\(idx + 1)"
                    if dedupKeys.contains(key) { continue }
                    dedupKeys.insert(key)

                    var contextBeforeLines: [LineRef]?
                    var contextAfterLines: [LineRef]?
                    if input.contextBefore > 0 {
                        let startIdx = max(0, idx - input.contextBefore)
                        contextBeforeLines = (startIdx..<idx).map { i in
                            LineRef(line: i + 1, text: lines[i])
                        }
                    }
                    if input.contextAfter > 0 {
                        let endIdx = min(lines.count, idx + input.contextAfter + 1)
                        contextAfterLines = ((idx + 1)..<endIdx).map { i in
                            LineRef(line: i + 1, text: lines[i])
                        }
                    }

                    perQueryMatches[qIdx].append(SearchMatch(
                        path: relativePath,
                        line: idx + 1,
                        text: line,
                        context_before: contextBeforeLines,
                        context_after: contextAfterLines
                    ))
                    totalMatchLines += 1 + (contextBeforeLines?.count ?? 0) + (contextAfterLines?.count ?? 0)
                    // Line is consumed — don't double-count against other queries.
                    break
                }
            }
        }

        func searchDirectory(at url: URL, relativePath: String) {
            guard !budgetExhausted() else { return }
            guard let contents = try? fm.contentsOfDirectory(atPath: url.path) else { return }

            for name in contents.sorted() {
                if budgetExhausted() { return }
                guard !WalkSkipRules.skipped.contains(name) else { continue }

                let itemURL = url.appendingPathComponent(name)
                if let internalDir,
                   SandboxPathResolver.isWithin(candidate: itemURL, container: internalDir) {
                    continue
                }
                let itemPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"

                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: itemURL.path, isDirectory: &isDir) else { continue }

                // RTFD is a file-bundle directory — treat as a single document.
                if isDir.boolValue && name.hasSuffix(".rtfd") {
                    visitedPaths.append(itemPath)
                    searchFile(at: itemURL, relativePath: itemPath)
                    continue
                }

                if isDir.boolValue {
                    searchDirectory(at: itemURL, relativePath: itemPath)
                } else {
                    if !GlobMatcher.matches(name: name, glob: input.fileGlob ?? "*", caseInsensitive: false) { continue }
                    visitedPaths.append(itemPath)
                    searchFile(at: itemURL, relativePath: itemPath)
                }
            }
        }

        // Walk either the constrained set or the directory tree.
        if let constrained = input.constrainToFiles {
            for relative in constrained {
                if budgetExhausted() { break }
                let url = workFolderRoot.appendingPathComponent(relative)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                // Treat .rtfd bundles as single files; otherwise skip directories.
                if isDir.boolValue && !url.pathExtension.lowercased().hasSuffix("rtfd") { continue }
                if !GlobMatcher.matches(name: url.lastPathComponent, glob: input.fileGlob ?? "*", caseInsensitive: false) { continue }
                visitedPaths.append(relative)
                searchFile(at: url, relativePath: relative)
            }
        } else {
            var searchDirs: [URL] = []
            if let paths = input.paths, !paths.isEmpty {
                for p in paths {
                    let url = try input.resolver.resolveFileURL(relativePath: p)
                    searchDirs.append(url)
                }
            } else {
                searchDirs = [workFolderRoot]
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
                        // Mirror the dir-walk: also feed single-file `paths`
                        // entries into `visitedPaths` so filename matching
                        // sees them. Without this, `paths: ["foo.swift"]`
                        // would silently omit the only candidate from the
                        // filename-match scan.
                        visitedPaths.append(rel)
                        searchFile(at: dir, relativePath: rel)
                    }
                }
            }
        }

        // Round-robin assemble the final list: original query first, then
        // expansions in order, cycling through each bucket so no single query
        // monopolizes the visible slots when they all had plenty of hits.
        var combined: [SearchMatch] = []
        combined.reserveCapacity(min(totalMatches(), input.maxResults))
        var heads = Array(repeating: 0, count: perQueryMatches.count)
        outer: while combined.count < input.maxResults {
            var progress = false
            for qIdx in perQueryMatches.indices {
                if combined.count >= input.maxResults { break outer }
                guard heads[qIdx] < perQueryMatches[qIdx].count else { continue }
                combined.append(perQueryMatches[qIdx][heads[qIdx]])
                heads[qIdx] += 1
                progress = true
            }
            if !progress { break }
        }

        let truncated = totalMatches() >= input.maxResults || totalMatchLines >= input.maxMatchLines

        let filenameMatches = FilenameMatcher.match(
            candidates: visitedPaths,
            queries: input.queries,
            limit: input.maxResults
        )

        return SearchExecutorOutput(
            matches: combined,
            skipped: skipped,
            skippedBinaryCount: skippedBinaryCount,
            truncated: truncated,
            filenameMatches: filenameMatches
        )
    }
}
