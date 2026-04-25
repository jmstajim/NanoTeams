import Foundation

/// Actor wrapping the on-disk search index. One instance per work folder.
///
/// Owns the full lifecycle: load from disk, verify signature, rebuild, save,
/// query (vocabulary + posting intersection), clear.
///
/// Concurrency: the actor naturally serializes calls — a second `loadOrBuild`
/// during an in-flight build awaits the first via Swift's actor reentrancy
/// queue. No explicit locking needed.
actor SearchIndexService {

    // MARK: - File Scope Constants

    /// Text extensions we read as raw UTF-8 during indexing. Anything outside
    /// this set AND outside `DocumentTextExtractor.supportedReadExtensions`
    /// contributes only its filename tokens (no content scan).
    static let textIndexableExtensions: Set<String> = [
        "swift", "md", "txt", "json", "yml", "yaml",
        "js", "ts", "tsx", "jsx",
        "py", "rs", "go", "c", "cpp", "cc", "h", "hpp",
        "m", "mm", "java", "kt", "rb", "php",
        "html", "htm", "css", "scss",
        "xml", "toml", "plist",
        "sh", "bash", "zsh", "fish",
        "ini", "cfg", "conf", "sql", "graphql", "proto",
    ]

    /// Hard cap on raw-UTF-8 text file size before we skip indexing the body
    /// (filename tokens still land in the index).
    static let maxRawTextIndexableBytes: Int = 1_048_576 // 1 MB

    // MARK: - State

    private let workFolderRoot: URL
    private let internalDir: URL
    private let fileManager: FileManager
    private let indexFileURL: URL

    /// In-memory copy of the most recent index. Loaded lazily; updated
    /// atomically on rebuild.
    private var cached: SearchIndex?

    // MARK: - Init

    init(workFolderRoot: URL, internalDir: URL, fileManager: FileManager = .default) {
        self.workFolderRoot = workFolderRoot.standardizedFileURL
        self.internalDir = internalDir.standardizedFileURL
        self.fileManager = fileManager
        self.indexFileURL = internalDir.appendingPathComponent("search_index.json", isDirectory: false)
    }

    // MARK: - Public API

    /// Returns a current index. If a cached instance is available and its
    /// signature still matches the folder, returns the cache; otherwise
    /// rebuilds (or loads from disk if that matches).
    ///
    /// Cancellation: `rebuildIndex` checks `Task.isCancelled` between
    /// directories. If the caller's Task was cancelled (e.g. the coordinator
    /// was torn down mid-build because the user disabled expanded search),
    /// the partial walk result is NOT cached or persisted — we return the
    /// prior cache if any, otherwise an empty index without writing it.
    func loadOrBuild(force: Bool = false) -> SearchIndex {
        if !force, let cached, matchesFolder(signature: cached.signature) {
            return cached
        }
        if !force,
           let onDisk = loadFromDisk(),
           matchesFolder(signature: onDisk.signature) {
            cached = onDisk
            return onDisk
        }
        let fresh = rebuildIndex()
        if Task.isCancelled {
            // Partial walk — don't cache/persist. Return the prior cache
            // if we have one; otherwise the in-memory fresh (but don't
            // cache it) so callers get a consistent shape.
            return cached ?? fresh
        }
        cached = fresh
        persist(fresh)
        return fresh
    }

    /// Current cached index without triggering a build.
    func peek() -> SearchIndex? {
        cached
    }

    /// Last persistence error, if any. Cleared on successful persist. The
    /// coordinator reads this after every build so the Advanced settings
    /// status card can surface disk-write failures to the user.
    private(set) var lastPersistError: String?

    /// Non-fatal warnings accumulated during the most recent walk (e.g.
    /// unreadable subdir, attributesOfItem failure). Distinct from
    /// `lastPersistError` because the index can still be built and cached
    /// successfully while partial — the coordinator surfaces this so the user
    /// knows the index isn't comprehensive. Cleared at the start of every
    /// `rebuildIndex`.
    private(set) var lastIndexWarnings: [String] = []

    /// Populated when `loadFromDisk` encounters a corrupt on-disk payload
    /// (malformed JSON, version drift, or a validating-init invariant
    /// violation from `SearchIndex.init(from:)`). Distinct from "file not
    /// present on first launch" — nil means the last load was either
    /// successful or the file genuinely didn't exist. Cleared on a clean
    /// load or a successful rebuild.
    private(set) var lastLoadError: String?

    /// Populated when `clear()` failed to remove the on-disk index file
    /// (locked, read-only volume, or filesystem error). Surfaced because a
    /// silent failure here means the next `loadOrBuild` reads the stale
    /// on-disk copy after the user explicitly asked for a clear+rebuild —
    /// they'd see the OLD index and wonder why nothing changed. Cleared on
    /// a successful clear.
    private(set) var lastClearError: String?

    /// Vocabulary candidates ranked by relevance tiers.
    /// Thin wrapper — the ranking lives on `SearchIndex` (Information Expert).
    func vocabulary(matching query: String, limit: Int) -> [String] {
        guard let index = cached ?? loadFromDisk() else { return [] }
        return index.vocabulary(matching: query, limit: limit)
    }

    /// Files whose postings contain ANY of `terms` (union).
    /// Thin wrapper — the intersection lives on `SearchIndex`.
    func files(containing terms: [String]) -> [String] {
        guard let index = cached ?? loadFromDisk() else { return [] }
        return index.files(containing: terms)
    }

    /// Deletes the on-disk index and drops the in-memory cache. Surfaces any
    /// removeItem failure via `lastClearError` so the coordinator can show the
    /// user that their "Clear → Rebuild" didn't actually clear (locked file,
    /// frozen volume, etc.) — without this, the next `loadOrBuild` would
    /// silently return the stale on-disk copy.
    func clear() {
        cached = nil
        guard fileManager.fileExists(atPath: indexFileURL.path) else {
            lastClearError = nil
            return
        }
        do {
            try fileManager.removeItem(at: indexFileURL)
            lastClearError = nil
        } catch {
            lastClearError = error.localizedDescription
        }
    }

    // MARK: - Signature

    /// Fast check: walk the tree, compute a fresh signature, compare.
    /// Cheaper than a full rebuild because it only stats files.
    func matchesFolder(signature: IndexSignature) -> Bool {
        let fresh = computeFolderSignature()
        return fresh == signature
    }

    /// Exposed for the coordinator's "ensure fresh" path — it can cheaply
    /// detect drift by comparing the disk signature to the folder signature.
    func folderSignature() -> IndexSignature {
        computeFolderSignature()
    }

    // MARK: - Private: Persistence

    private func loadFromDisk() -> SearchIndex? {
        guard fileManager.fileExists(atPath: indexFileURL.path) else {
            // No file on disk = first launch or cleared; NOT an error.
            lastLoadError = nil
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: indexFileURL)
        } catch {
            lastLoadError = "search_index.json unreadable: \(error.localizedDescription)"
            return nil
        }
        let decoder = JSONCoderFactory.makeDateDecoder()
        let index: SearchIndex
        do {
            index = try decoder.decode(SearchIndex.self, from: data)
        } catch {
            // Corrupt JSON or invariant violation thrown by
            // `SearchIndex.init(from:)` (see `SearchIndex.ValidationError`).
            // Surfaced so the UI pill can tell the user their index was
            // regenerated because the on-disk copy was bad.
            lastLoadError = "search_index.json corrupt: \(error.localizedDescription)"
            return nil
        }
        guard index.version == SearchIndex.currentVersion else {
            lastLoadError = "search_index.json version \(index.version) != current "
                + "\(SearchIndex.currentVersion); rebuilding."
            return nil
        }
        lastLoadError = nil
        return index
    }

    private func persist(_ index: SearchIndex) {
        do {
            try fileManager.createDirectory(
                at: indexFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONCoderFactory.makePersistenceEncoder()
            let data = try encoder.encode(index)
            try data.write(to: indexFileURL, options: .atomic)
            lastPersistError = nil
        } catch {
            // Best effort — search still works off the in-memory cache; next
            // launch just rebuilds. Surface to the coordinator AND log for
            // diagnostics.
            lastPersistError = error.localizedDescription
            print("[SearchIndexService] WARNING: failed to persist index: \(error)")
        }
    }

    // MARK: - Private: Walk & Build

    private func rebuildIndex() -> SearchIndex {
        var files: [IndexedFile] = []
        var postings: [String: [Int]] = [:]
        var maxMTime = Date.distantPast
        var totalSize: Int64 = 0
        var walkWarnings: [String] = []

        // Walk visitor trusts `walkRecursive` to filter the internal dir and
        // skip rules. It only needs to care about what to do with a visited
        // file-like entry. Per-file I/O failures (attributesOfItem, Data read)
        // are appended to `warnings` so the coordinator can surface them —
        // otherwise an unreadable file would silently contribute filename-only
        // tokens AND a stale mTime / size of zero, masking real changes from
        // the signature check on the next walk.
        walk(workFolderRoot, warnings: &walkWarnings) { url, isRTFDBundle, warnings in
            let relative = relativePath(from: url)
            if relative.isEmpty { return }

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
            if isDir.boolValue && !isRTFDBundle { return }

            let mTime: Date
            let size: Int64
            do {
                let attrs = try fileManager.attributesOfItem(atPath: url.path)
                mTime = Self.normalizedMTime(
                    (attrs[.modificationDate] as? Date) ?? Date.distantPast
                )
                size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            } catch {
                warnings.append("attribute read failed at \(relative): \(error.localizedDescription)")
                // Skip the file entirely on attribute failure — we'd otherwise
                // store a `.distantPast` mTime + 0 size, which silently
                // poisons the IndexSignature on the next walk.
                return
            }

            let fileID = files.count
            let entry = IndexedFile(path: relative, mTime: mTime, size: size)
            files.append(entry)

            var tokens = TokenExtractor.extractFilenameTokens(from: url)

            // Content tokenization — pick path by extension.
            let ext = url.pathExtension.lowercased()
            if DocumentTextExtractor.isSupported(extension: ext) {
                if let extracted = DocumentTextExtractor.extractText(from: url),
                   !DocumentTextExtractor.isFailureMessage(extracted) {
                    tokens.formUnion(TokenExtractor.extractTokens(from: extracted))
                }
            } else if Self.textIndexableExtensions.contains(ext) {
                if size <= Int64(Self.maxRawTextIndexableBytes) {
                    do {
                        let data = try Data(contentsOf: url)
                        if let content = String(data: data, encoding: .utf8) {
                            tokens.formUnion(TokenExtractor.extractTokens(from: content))
                        }
                        // Non-UTF-8 bytes silently fall through — filename
                        // tokens still indexed; not a warning surface (binary
                        // file with text-y extension is benign).
                    } catch {
                        warnings.append("content read failed at \(relative): \(error.localizedDescription)")
                    }
                }
            }

            for token in tokens {
                postings[token, default: []].append(fileID)
            }

            if mTime > maxMTime { maxMTime = mTime }
            totalSize += size
        }

        // Sort posting lists so intersections are simple merges; sort+dedup
        // just in case the walk revisits a file id (shouldn't, but cheap).
        for key in postings.keys {
            let sorted = Array(Set(postings[key] ?? [])).sorted()
            postings[key] = sorted
        }

        let tokens = Array(postings.keys).sorted()
        let signature = IndexSignature(
            fileCount: files.count,
            maxMTime: maxMTime,
            totalSize: totalSize
        )
        // Publish accumulated walk warnings so the coordinator can forward
        // them to the UI `lastError` pill. Without this, partial walks look
        // like clean empty/sparse roots.
        self.lastIndexWarnings = walkWarnings
        // `try!` is safe here: the builder above constructs tokens from
        // `postings.keys`, sorts/dedups posting lists, and assigns file IDs
        // sequentially — every SearchIndex invariant holds by construction.
        // If it doesn't, that's a builder bug worth crashing on.
        // CLAUDE.md mandates `MonotonicClock.shared.now()` for model
        // timestamps — `generatedAt` is persisted, surfaced as `lastBuiltAt`,
        // and used in tests, so it qualifies. (mTime stays as the real
        // filesystem mtime; durationMs elapsed times stay as `Date()`.)
        // swiftlint:disable:next force_try
        return try! SearchIndex(
            generatedAt: Self.normalizedMTime(MonotonicClock.shared.now()),
            signature: signature,
            files: files,
            tokens: tokens,
            postings: postings
        )
    }

    private func computeFolderSignature() -> IndexSignature {
        var count = 0
        var maxMTime = Date.distantPast
        var total: Int64 = 0
        var sink: [String] = []
        walk(workFolderRoot, warnings: &sink) { url, isRTFDBundle, _ in
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
            if isDir.boolValue && !isRTFDBundle { return }
            // Attribute failures here go to `sink` (discarded) — the signature
            // is a coarse drift probe, not a freshness guarantee. A file whose
            // attributes cannot be read this run will still trigger a rebuild
            // because either it gets a different size in another run, or it
            // was already excluded from the signature on the prior walk.
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            let mTime = Self.normalizedMTime(
                (attrs?[.modificationDate] as? Date) ?? Date.distantPast
            )
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            count += 1
            if mTime > maxMTime { maxMTime = mTime }
            total += size
        }
        return IndexSignature(fileCount: count, maxMTime: maxMTime, totalSize: total)
    }

    /// Truncates a `Date` down to millisecond precision — the resolution of
    /// our `ISO-8601-with-fractional-seconds` persistence format. Without this,
    /// nanosecond-precision mTimes from `FileManager.attributesOfItem` survive
    /// in the in-memory signature but are lost on JSON round-trip, so the
    /// fresh-walk vs disk-loaded signatures diverge and `matchesFolder` always
    /// returns false — the cache would never be reused. Rounding mode doesn't
    /// matter for correctness as long as both sides apply the same function;
    /// `.down` gives deterministic "floor to ms" which matches how the
    /// serializer clamps the fractional part.
    ///
    /// Trade-off: two edits of the same file within a single millisecond that
    /// ALSO preserve the file size will produce an identical `IndexSignature`
    /// and the walker will skip the rebuild. In practice most edits change
    /// the file size too (also tracked in the signature), so the miss surface
    /// is "same-byte-count content swap within 1 ms" — rare enough to live
    /// with in exchange for stable cache reuse.
    private static func normalizedMTime(_ date: Date) -> Date {
        let ms = (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000
        return Date(timeIntervalSince1970: ms)
    }

    /// Recursive directory walker. Calls `visit(url, isRTFDBundle, warnings)`
    /// for each file-like entry (including `.rtfd` bundle directories, which
    /// are treated as single files). `warnings` accumulates non-fatal I/O
    /// failures (e.g. unreadable subdirectories, attribute reads) so callers
    /// can distinguish a partial walk from a genuinely empty tree. The
    /// visitor receives `inout [String]` so per-file failures (attribute
    /// query, content read) land in the same accumulator without a separate
    /// closure plumbing pass.
    private func walk(
        _ root: URL,
        warnings: inout [String],
        visit: (URL, Bool, inout [String]) -> Void
    ) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        // Cycle detection: track canonical (symlink-resolved) paths of
        // directories already entered. Without this, a symlink pointing at an
        // ancestor (`a/loop -> a/`) infinite-recurses because
        // `fileManager.fileExists(isDirectory:)` follows symlinks. Stack
        // overflow on large repos with accidental loops is a real user-facing
        // failure mode (e.g. dropbox-style synced folders).
        var visited: Set<String> = []
        walkRecursive(root, warnings: &warnings, visited: &visited, visit: visit)
    }

    private func walkRecursive(
        _ dir: URL,
        warnings: inout [String],
        visited: inout Set<String>,
        visit: (URL, Bool, inout [String]) -> Void
    ) {
        // Cancellation check at each directory entry: if the enclosing Task
        // was cancelled (e.g. `coordinator.stop()` fired because the user
        // toggled expanded-search OFF), abandon the walk immediately instead
        // of finishing it synchronously on the actor. Without this, OFF
        // would wait for the full walk to complete before teardown proceeds.
        if Task.isCancelled { return }

        // Resolve symlinks to detect cycles. `resolvingSymlinksInPath()`
        // resolves every symlink in the path; `standardizedFileURL` removes
        // `.`/`..`/duplicate slashes. If we've already entered this canonical
        // dir during this walk, a symlink loop just brought us back — record
        // and skip.
        let canonical = dir.resolvingSymlinksInPath().standardizedFileURL.path
        guard !visited.contains(canonical) else {
            warnings.append("symlink cycle skipped at \(dir.path) → \(canonical)")
            return
        }
        visited.insert(canonical)

        let contents: [String]
        do {
            contents = try fileManager.contentsOfDirectory(atPath: dir.path)
        } catch {
            // Unreadable subdir (EACCES, EIO, broken symlink). Record and
            // move on — don't let one bad subtree silently truncate the
            // whole index.
            warnings.append("walk error at \(dir.path): \(error.localizedDescription)")
            return
        }
        for name in contents {
            guard !WalkSkipRules.skipped.contains(name) else { continue }
            // Skip bookkeeping files that live directly in `.nanoteams/`
            // (e.g. `.gitignore`). User-facing content under `.nanoteams/`
            // — attachments, artifacts — still traverses.
            if dir.lastPathComponent == ".nanoteams",
               WalkSkipRules.skippedInsideNanoteamsDir.contains(name) { continue }
            let itemURL = dir.appendingPathComponent(name)
            if SandboxPathResolver.isWithin(candidate: itemURL, container: internalDir) { continue }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDir) else { continue }
            let isRTFD = isDir.boolValue && name.hasSuffix(".rtfd")
            if isRTFD {
                visit(itemURL, true, &warnings)
            } else if isDir.boolValue {
                walkRecursive(itemURL, warnings: &warnings, visited: &visited, visit: visit)
            } else {
                visit(itemURL, false, &warnings)
            }
        }
    }

    private func relativePath(from url: URL) -> String {
        let base = workFolderRoot.path.hasSuffix("/") ? workFolderRoot.path : (workFolderRoot.path + "/")
        let full = url.standardizedFileURL.path
        if full.hasPrefix(base) {
            return String(full.dropFirst(base.count))
        }
        return url.lastPathComponent
    }
}
