import Foundation

/// Immutable result of one agent-instruction discovery pass over a work folder:
/// auto-discovered well-known files (CLAUDE.md, AGENTS.md, …) composed with the
/// user's per-folder overrides (manually attached files + exclusions from
/// `ProjectSettings`). Produced by `AgentInstructionsScanner.scan`, consumed by
/// the prompt builder (injected content + path list ride the
/// `{workFolderContext}` placeholder) and the Settings grid.
///
/// Content is read exactly once at scan time and never re-read at prompt-build
/// time, so the bytes a role sees are pinned per step (same semantics as
/// `settings.context`: each step's first LLM call reads the then-current
/// snapshot and its stateful chain keeps those bytes for the whole step).
nonisolated struct AgentInstructionsSnapshot: Hashable, Sendable {
    nonisolated enum ItemSource: Hashable, Sendable {
        /// Auto-discovered well-known instruction file.
        case discovered
        /// User-attached via Settings (persisted in
        /// `ProjectSettings.agentInstructionExtraPaths`).
        case manual
    }

    nonisolated struct Item: Hashable, Sendable, Identifiable {
        /// Path relative to the work-folder root, original case.
        let relativePath: String
        let source: ItemSource
        /// Discovered file the user X'd out of CONTENT injection. It is NOT
        /// removed from the instruction set: it stays in the Settings grid
        /// (dimmed, restorable) and in the prompt's path list — roles can still
        /// read it on demand; only its content stops riding the system prompt.
        let isExcluded: Bool
        /// Trimmed FULL content when this item is content-injected (the
        /// discovered main file + every manual UTF-8 text file) — no size cap
        /// (explicit product decision). `nil` for path-listed items (discovered
        /// non-main files, manual images/binaries).
        let injectedContent: String?

        var id: String { relativePath }
    }

    /// Display order: discovered main first, remaining discovered files sorted,
    /// then manual files in the order the user attached them.
    let items: [Item]

    static let empty = AgentInstructionsSnapshot(items: [])

    var isEmpty: Bool { items.isEmpty }

    /// Content-injected files in injection order (discovered main first, then
    /// manual text files). Every element has non-nil `injectedContent`.
    var injectedFiles: [Item] {
        items.filter { !$0.isExcluded && $0.injectedContent != nil }
    }

    /// Path-listed files for the "read on demand" prompt list — everything that
    /// is not content-injected, INCLUDING excluded files (exclusion demotes a
    /// file from content injection to path listing, it never hides the file).
    var listedPaths: [String] {
        items.filter { $0.isExcluded || $0.injectedContent == nil }.map(\.relativePath)
    }

    /// The auto-discovered main instruction file, when one qualified.
    var mainFile: Item? {
        injectedFiles.first { $0.source == .discovered }
    }
}

/// Pure folder-input scanner that discovers well-known agent-instruction files
/// anywhere under a work folder and composes them with user overrides. Sibling
/// of `WorkFolderContextBuilder` — same "pure recursive folder walk" category.
///
/// Walk semantics mirror `SearchIndexService.walkRecursive` (`contentsOfDirectory`
/// visits hidden entries — unlike `WorkFolderContextBuilder`'s `.skipsHiddenFiles`
/// enumerator — plus `WalkSkipRules` and a symlink-cycle guard), with two
/// deliberate deltas:
/// - `.nanoteams/` is skipped WHOLESALE: app storage (task attachments, run
///   artifacts) must never be promoted to a folder-governing instruction file.
/// - symlinks that resolve OUTSIDE the work folder are skipped (dirs and files)
///   so the prompt can never inject content the sandboxed `read_file` tool
///   would refuse to serve.
nonisolated enum AgentInstructionsScanner {
    /// Single source of truth for the well-known instruction files, in MAIN
    /// priority order. `basename` drives case-insensitive discovery at any
    /// depth + nested-tier ranking; `canonicalRootPath` is the root-tier
    /// relative path that outranks any nested hit (copilot's canonical home is
    /// `.github/copilot-instructions.md`).
    nonisolated struct WellKnownFile: Hashable, Sendable {
        let basename: String          // lowercased
        let canonicalRootPath: String // lowercased, relative
    }

    static let wellKnown: [WellKnownFile] = [
        .init(basename: "claude.md", canonicalRootPath: "claude.md"),
        .init(basename: "agents.md", canonicalRootPath: "agents.md"),
        .init(basename: "gemini.md", canonicalRootPath: "gemini.md"),
        .init(basename: ".cursorrules", canonicalRootPath: ".cursorrules"),
        .init(basename: "copilot-instructions.md", canonicalRootPath: ".github/copilot-instructions.md"),
        .init(basename: ".windsurfrules", canonicalRootPath: ".windsurfrules"),
    ]

    /// Bytes probed before committing to a full candidate read — rejects
    /// binary/mislabeled candidates without loading them whole. NOT a content
    /// cap: a qualifying text file is then read in full.
    private static let probeBytes = 8192

    private struct Hit {
        let relativePath: String   // original case
        let url: URL
        let lowerPath: String
        let priorityRank: Int      // index in `wellKnown`
        let depth: Int
    }

    static func scan(
        workFolderRoot: URL,
        manualPaths: [String] = [],
        excludedPaths: [String] = [],
        injectedPaths: [String] = [],
        fileManager: FileManager = .default
    ) -> AgentInstructionsSnapshot {
        let root = workFolderRoot.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let paths = NTMSPaths(workFolderRoot: root)

        var rawHits: [Hit] = []
        var visited: Set<String> = []
        walk(dir: root, resolvedRoot: resolvedRoot, paths: paths,
             fileManager: fileManager, visited: &visited, hits: &rawHits)

        // Dedup by relativePath: an in-root symlink with a well-known name
        // resolves to its target's path (NTMSPaths resolves symlinks), so the
        // alias and the real file collapse to one identity — two items with
        // the same relativePath would break grid `Identifiable` uniqueness.
        // The better (lower) priority rank wins.
        var bestByPath: [String: Hit] = [:]
        for hit in rawHits {
            if let existing = bestByPath[hit.relativePath], existing.priorityRank <= hit.priorityRank {
                continue
            }
            bestByPath[hit.relativePath] = hit
        }
        let hits = Array(bestByPath.values)

        let excluded = Set(excludedPaths)

        // MAIN selection among non-excluded discovered hits: root tier (by
        // canonicalRootPath order), then nested tier by (rank, depth, path).
        let selectable = hits.filter { !excluded.contains($0.relativePath) }
        let rootTier: [Hit] = wellKnown.compactMap { entry in
            selectable.first { $0.lowerPath == entry.canonicalRootPath }
        }
        let rootTierPaths = Set(rootTier.map(\.relativePath))
        let nestedTier: [Hit] = selectable
            .filter { !rootTierPaths.contains($0.relativePath) }
            .sorted { a, b in
                if a.priorityRank != b.priorityRank { return a.priorityRank < b.priorityRank }
                if a.depth != b.depth { return a.depth < b.depth }
                return a.relativePath < b.relativePath
            }

        var mainPath: String?
        var mainContent: String?
        for candidate in rootTier + nestedTier {
            guard let content = readInjectableText(at: candidate.url) else { continue }
            mainPath = candidate.relativePath
            mainContent = content
            break
        }

        // Assemble items: discovered main first, remaining discovered sorted,
        // then manual attachments in stored order.
        let injectedSet = Set(injectedPaths)
        var items: [AgentInstructionsSnapshot.Item] = []
        if let mainPath, let mainContent {
            items.append(.init(relativePath: mainPath, source: .discovered,
                               isExcluded: false, injectedContent: mainContent))
        }
        for hit in hits.sorted(by: { $0.relativePath < $1.relativePath }) where hit.relativePath != mainPath {
            let isExcluded = excluded.contains(hit.relativePath)
            // User-promoted listed file → content-injected too (readable text
            // only; a binary silently stays listed). Exclusion wins.
            let content: String? = (!isExcluded && injectedSet.contains(hit.relativePath))
                ? readInjectableText(at: hit.url)
                : nil
            items.append(.init(relativePath: hit.relativePath, source: .discovered,
                               isExcluded: isExcluded,
                               injectedContent: content))
        }

        let discoveredPaths = Set(hits.map(\.relativePath))
        for manual in manualPaths {
            guard !discoveredPaths.contains(manual), !items.contains(where: { $0.relativePath == manual }) else { continue }
            let url = root.appendingPathComponent(manual)
            // Defense in depth (the add API validates too): the file must still
            // exist, resolve inside the folder, and stay out of `internal/`.
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard SandboxPathResolver.isWithin(candidate: resolved, container: resolvedRoot),
                  !paths.isInternalURL(resolved) else { continue }
            // Text → content-injected (unless the user toggled injection off);
            // image/binary/empty → path-listed.
            let isExcluded = excluded.contains(manual)
            let content = isExcluded ? nil : readInjectableText(at: url)
            items.append(.init(relativePath: manual, source: .manual,
                               isExcluded: isExcluded, injectedContent: content))
        }

        return AgentInstructionsSnapshot(items: items)
    }

    /// Re-reads the CONTENT of an existing snapshot's items without walking the
    /// folder, dropping any whose file has since disappeared.
    ///
    /// The split this exists for: `scan` answers "which instruction files are
    /// there", which changes when someone creates or deletes one; a run start needs
    /// "what do they say right now", which changes every time the user saves. Only
    /// the second is on the path to a first prompt, and it costs one read per
    /// injected file instead of a recursive walk of the whole work folder.
    ///
    /// Identity, order, `source` and `isExcluded` are preserved exactly — this is
    /// the same snapshot with fresh bytes. A file that has become unreadable (turned
    /// binary, emptied) demotes from content-injected to path-listed, which is what
    /// a full `scan` would also produce for it; a file that is GONE is dropped
    /// entirely, because listing a path the role cannot read is a lie the prompt
    /// would carry until the next walk.
    static func reread(
        _ snapshot: AgentInstructionsSnapshot,
        workFolderRoot: URL,
        fileManager: FileManager = .default
    ) -> AgentInstructionsSnapshot {
        let root = workFolderRoot.standardizedFileURL
        var items: [AgentInstructionsSnapshot.Item] = []
        for item in snapshot.items {
            let url = root.appendingPathComponent(item.relativePath)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            // Only files that WERE content-injected get re-read: a path-listed item
            // carries no bytes, and promoting one here would inject content the user
            // never asked for (that decision belongs to `injectedPaths`, an input of
            // the walk).
            let content = item.injectedContent == nil
                ? nil
                : readInjectableText(at: url)
            items.append(.init(relativePath: item.relativePath, source: item.source,
                               isExcluded: item.isExcluded, injectedContent: content))
        }
        return AgentInstructionsSnapshot(items: items)
    }

    // MARK: - Candidate reading

    /// Returns the file's trimmed full content when it reads as non-empty UTF-8
    /// text, else `nil`. Probes the first `probeBytes` before committing to the
    /// full read so large binaries misnamed as instruction files aren't loaded
    /// whole just to fail decoding.
    private static func readInjectableText(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let prefix = (try? handle.read(upToCount: probeBytes)) ?? Data()
        try? handle.close()
        guard let probe = decodeUTF8Prefix(prefix), !isAllWhitespace(probe) else { return nil }

        // Short file: the probe WAS the whole file — no second read.
        if prefix.count < probeBytes {
            let trimmed = probe.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Decodes a byte prefix as UTF-8, tolerating a multi-byte character cut at
    /// the end (drops up to 3 trailing bytes before giving up).
    private static func decodeUTF8Prefix(_ data: Data) -> String? {
        var slice = data
        for _ in 0...3 {
            if let s = String(data: slice, encoding: .utf8) { return s }
            guard !slice.isEmpty else { return nil }
            slice = slice.dropLast()
        }
        return nil
    }

    private static func isAllWhitespace(_ s: String) -> Bool {
        s.allSatisfy { $0.isWhitespace }
    }

    // MARK: - Walk

    private static func walk(
        dir: URL,
        resolvedRoot: URL,
        paths: NTMSPaths,
        fileManager: FileManager,
        visited: inout Set<String>,
        hits: inout [Hit]
    ) {
        // Symlink-cycle guard: track canonical (symlink-resolved) dir paths.
        let canonical = dir.resolvingSymlinksInPath().standardizedFileURL.path
        guard !visited.contains(canonical) else { return }
        visited.insert(canonical)

        let contents: [String]
        do {
            contents = try fileManager.contentsOfDirectory(atPath: dir.path)
        } catch {
            // Unreadable subdir (EACCES, EIO): skip this subtree, don't crash.
            return
        }

        for name in contents {
            guard !WalkSkipRules.shouldSkip(name: name) else { continue }
            // App storage is never an instruction source (a CLAUDE.md attached
            // to a task must not govern the folder).
            guard name != ".nanoteams" else { continue }
            let itemURL = dir.appendingPathComponent(name)

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDir) else { continue }

            // Symlink-escape guard: skip anything whose resolved location is
            // outside the work folder — the sandbox would refuse `read_file`
            // on it, so the prompt must not inject or list it either.
            let resolved = itemURL.resolvingSymlinksInPath().standardizedFileURL
            guard SandboxPathResolver.isWithin(candidate: resolved, container: resolvedRoot) else { continue }

            if isDir.boolValue {
                walk(dir: itemURL, resolvedRoot: resolvedRoot, paths: paths,
                     fileManager: fileManager, visited: &visited, hits: &hits)
            } else {
                let lowerName = name.lowercased()
                guard let rank = wellKnown.firstIndex(where: { $0.basename == lowerName }) else { continue }
                let rel = paths.relativePathFromProjectRoot(for: itemURL)
                guard !rel.isEmpty else { continue }
                hits.append(Hit(
                    relativePath: rel,
                    url: itemURL,
                    lowerPath: rel.lowercased(),
                    priorityRank: rank,
                    depth: rel.count { $0 == "/" }
                ))
            }
        }
    }
}
