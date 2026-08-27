import Foundation

/// Actor wrapping the on-disk search index. One instance per work folder.
///
/// Owns the full lifecycle: load from disk, verify signature, rebuild, save,
/// query (vocabulary + posting intersection), clear.
///
/// Concurrency: `loadOrBuild` is single-flight — a second caller arriving during a build JOINS
/// it rather than starting its own.
///
/// The actor alone used to be enough, and the note here said so: the method was synchronous, so
/// `matchesFolder` → `rebuildIndex()` → `cached = fresh` could not be interleaved. That reading
/// stops holding the moment the rebuild gains a suspension point — a second caller wedges in,
/// sees `cached == nil`, and starts a DUPLICATE full walk of the tree. Actor REENTRANCY is
/// precisely the thing "the actor serializes calls" does not buy you.
///
/// The result is strictly better than the synchronous version it replaces, not merely equal to
/// it: callers used to serialize by BLOCKING the actor for the length of a walk, so every
/// unrelated query (`files(containing:)`, `lastPersistError`) queued behind it.
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

    /// The rebuild every concurrent caller shares while it runs.
    ///
    /// Deliberately consulted only by NON-forced callers. `force: true` means "ignore what you
    /// have and go look again" — joining a walk that started before the caller's reason for
    /// asking would hand back exactly the staleness it forced past. Two concurrent forces
    /// therefore do duplicate work, which is the correct trade: `force` is user-initiated
    /// ("Rebuild"), and the coordinator serializes its own through `currentTokenBuildTask`.
    private var inFlightBuild: Task<SearchIndex, Never>?

    // MARK: - Init

    init(workFolderRoot: URL, internalDir: URL, fileManager: sending FileManager = .default) {
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
    /// was torn down mid-build because the user disabled exploratory search),
    /// the partial walk result is NOT cached or persisted — we return the
    /// prior cache if any, otherwise an empty index without writing it.
    func loadOrBuild(force: Bool = false) async -> SearchIndex {
        // `force` means "reuse NOTHING" — not the in-memory cache, not the on-disk copy, and not
        // a walk already in flight. All three live under ONE condition on purpose: written as
        // three separate `!force` clauses the rule had three homes, and only the first was
        // reachable from a test. (The in-flight window needs the actor blocked mid-build to
        // observe, which no test can arrange without a seam that exists only for it.) One
        // condition means the pin on the cache arm is a pin on the rule.
        //
        // The in-flight arm is not hypothetical: `SearchIndexCoordinator.rebuild()` cancels
        // `currentTokenBuildTask` and then forces, so the build a forced call would have joined
        // is the CANCELLED one — which returns the prior cache rather than a fresh walk.
        if !force {
            if let reused = reuseExistingIndex() { return reused }
            // Join an in-flight build rather than starting a second walk of the same tree.
            // Reaching here means both cache probes missed, and both are synchronous — so from
            // actor entry to the assignment below there is no suspension point, which is what
            // makes "check, then claim" atomic without a lock.
            //
            // A joiner must not inherit a build its INITIATOR abandoned. `scheduleEnsureFresh`
            // cancels the previous token task before installing its own, so the ordinary
            // double-`start()` sequence is exactly: task 1 claims the slot, task 2 joins it,
            // task 1 is cancelled — and the shared build dies under a caller who never asked for
            // that. A joiner that lands on a cancelled build therefore runs its own, which is
            // what the actor did before single-flight existed. Pinned by
            // `SearchIndexCoordinatorTests.testDoubleStart_isSafe`, which caught this.
            if let existing = inFlightBuild, !existing.isCancelled {
                let joined = await existing.value
                if !existing.isCancelled { return joined }
            }
        }

        let build = Task { [self] in await performRebuild() }
        inFlightBuild = build
        // An unstructured `Task` does not inherit its creator's cancellation, and
        // `SearchIndexCoordinator.stop()` depends on that inheritance: it cancels the token-build
        // task expecting the walk to abandon rather than finish against a folder being torn down.
        // The INITIATOR forwards it by hand. Joiners deliberately do not — a cancelled search
        // must not kill the index build an FS event started for everyone else.
        let fresh = await withTaskCancellationHandler {
            await build.value
        } onCancel: {
            build.cancel()
        }
        // Only if it is still OURS: a `force` caller arriving mid-build installs its own.
        if inFlightBuild == build { inFlightBuild = nil }
        return fresh
    }

    /// The cache probes, in order: in memory, then on disk. `nil` when neither still describes
    /// the folder. Split out so `loadOrBuild`'s `force` decision reads as one branch.
    private func reuseExistingIndex() -> SearchIndex? {
        if let cached, matchesFolder(signature: cached.signature) {
            // A cache that still matches the folder proves there is no
            // outstanding load problem, so retire any earlier one.
            //
            // Without this the fast path is where a load error becomes
            // IMMORTAL. `loadFromDisk` is the only other writer, and once a
            // rebuild has populated `cached` every later `loadOrBuild(force:
            // false)` returns here without re-attempting a load — so a
            // "search_index.json corrupt" set once, on the build that
            // regenerated it, was re-read by `SearchIndexCoordinator.
            // performTokenBuild` on every subsequent build and shown in the
            // Advanced-settings card for the rest of the session, against an
            // index that had been healthy on disk since the first rebuild.
            //
            // Clearing HERE rather than at the end of the rebuild is what keeps
            // the message useful: the rebuild that fixed the index still
            // reports why it happened, and the next build retires it.
            lastLoadError = nil
            return cached
        }
        if let onDisk = loadFromDisk(), matchesFolder(signature: onDisk.signature) {
            cached = onDisk
            return onDisk
        }
        return nil
    }

    /// The rebuild itself, plus the decision about whether its result may be kept.
    private func performRebuild() async -> SearchIndex {
        let fresh = await rebuildIndex()
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
    /// successful or the file genuinely didn't exist.
    ///
    /// Lifetime: set by `loadFromDisk`, and retired by the next `loadOrBuild`
    /// that either loads cleanly or serves a cache still matching the folder.
    /// It therefore SURVIVES the rebuild it triggered — that is deliberate, and
    /// is what lets the settings card say the index was regenerated *because*
    /// the previous copy was bad — but only for that one build.
    private(set) var lastLoadError: String?

    /// Populated when `clear()` failed to remove the on-disk index file
    /// (locked, read-only volume, or filesystem error). Surfaced because a
    /// silent failure here means the next `loadOrBuild` reads the stale
    /// on-disk copy after the user explicitly asked for a clear+rebuild —
    /// they'd see the OLD index and wonder why nothing changed. Cleared on
    /// a successful clear.
    private(set) var lastClearError: String?

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

    /// One file-like entry the walk found, with the two attributes the signature needs already
    /// in hand.
    ///
    /// `mTime`/`size` are read from the resource values `contentsOfDirectory(at:)` PREFETCHED,
    /// not from a separate `attributesOfItem(atPath:)` per file. That call builds an
    /// `NSDictionary` of every attribute to hand back two of them, and it ran once per file on
    /// EVERY `loadOrBuild` — cache hits included, since `matchesFolder` computes the folder
    /// signature before it can answer. Measured on this work folder: the signature probe alone
    /// cost 100 ms of every warm exploratory search.
    nonisolated struct IndexCandidate: Sendable {
        let url: URL
        let relativePath: String
        let isRTFDBundle: Bool
        let mTime: Date
        let size: Int64
    }

    /// What one file's content pass produced.
    nonisolated struct IndexFilePass: Sendable {
        let tokens: Set<String>
        let warnings: [String]
    }

    private func rebuildIndex() async -> SearchIndex {
        var walkWarnings: [String] = []
        let candidates = collectCandidates(warnings: &walkWarnings)

        // Content tokenization, fanned out. This is where a rebuild's time actually goes:
        // measured 9909 ms on this work folder, against 301 ms for a whole-tree grep — the walk
        // and the stats are noise beside reading ~30 MB and tokenising 114 000 distinct terms.
        let passes = await Self.runFilePasses(
            candidates,
            concurrency: SearchExecutor.defaultScanConcurrency)

        var files: [IndexedFile] = []
        files.reserveCapacity(candidates.count)
        var postings: [String: [Int]] = [:]
        var maxMTime = Date.distantPast
        var totalSize: Int64 = 0

        // Folded in WALK order, so `fileID` — an index into `files` — is assigned exactly as the
        // sequential version assigned it, and so warnings reach the settings card in the order
        // the user's tree produced them.
        for (candidate, pass) in zip(candidates, passes) {
            let fileID = files.count
            files.append(IndexedFile(
                path: candidate.relativePath, mTime: candidate.mTime, size: candidate.size))
            for token in pass.tokens {
                postings[token, default: []].append(fileID)
            }
            walkWarnings.append(contentsOf: pass.warnings)
            if candidate.mTime > maxMTime { maxMTime = candidate.mTime }
            totalSize += candidate.size
        }

        // Sort posting lists so intersections are simple merges; sort+dedup
        // just in case the walk revisits a file id (shouldn't, but cheap).
        //
        // `mapValues` rather than a `for key in postings.keys` loop that re-subscripts: the
        // subscript is optional, so it needed a `?? []` whose other arm no key from
        // `postings.keys` can ever take.
        postings = postings.mapValues { Array(Set($0)).sorted() }

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

    /// Reads and tokenises every candidate, `concurrency` at a time.
    ///
    /// A window rather than "add them all and let the group sort it out": every in-flight pass
    /// holds one file's bytes resident, and `maxRawTextIndexableBytes` is 1 MB, so an unbounded
    /// fan-out over a large repo is an unbounded allocation. Results are returned in CANDIDATE
    /// order, not completion order — `fileID` is an index into `files`, so a reordering here
    /// would silently rewrite every posting list.
    ///
    /// No early exit and no shared budget, which is what makes this simpler than the grep's
    /// equivalent: nothing a pass discovers can make an earlier or later pass wrong, so the
    /// merge is a plain zip and there is no speculation to account for.
    private static func runFilePasses(
        _ candidates: [IndexCandidate],
        concurrency: Int
    ) async -> [IndexFilePass] {
        guard !candidates.isEmpty else { return [] }
        // Collected as pairs and sorted, not written into a pre-sized optional array: the loop
        // adds exactly `candidates.count` tasks and drains the group, so an empty slot was
        // unreachable — and an unreachable `??` is a branch a reader has to rule out by hand.
        var collected: [(index: Int, pass: IndexFilePass)] = []
        collected.reserveCapacity(candidates.count)

        await withTaskExecutorPreference(BlockingIOTaskExecutor.shared) {
            await withTaskGroup(of: (Int, IndexFilePass).self) { group in
                var next = 0
                let window = min(max(1, concurrency), candidates.count)
                while next < window {
                    let index = next
                    group.addTask { (index, indexOne(candidates[index])) }
                    next += 1
                }
                while let (index, pass) = await group.next() {
                    collected.append((index, pass))
                    if next < candidates.count {
                        let queued = next
                        group.addTask { (queued, indexOne(candidates[queued])) }
                        next += 1
                    }
                }
            }
        }
        return collected.sorted { $0.index < $1.index }.map(\.pass)
    }

    /// One candidate's content pass: filename tokens always, content tokens when the extension
    /// says the bytes are text (or a document extractor can make them text).
    private static func indexOne(_ candidate: IndexCandidate) -> IndexFilePass {
        if Task.isCancelled { return IndexFilePass(tokens: [], warnings: []) }
        var tokens = TokenExtractor.extractFilenameTokens(from: candidate.url)
        var warnings: [String] = []

        let ext = candidate.url.pathExtension.lowercased()
        if DocumentTextExtractor.isSupported(extension: ext) {
            if case .text(let extracted, _) = DocumentTextExtractor.extract(from: candidate.url) {
                tokens.formUnion(TokenExtractor.extractTokens(from: extracted))
            }
        } else if textIndexableExtensions.contains(ext) {
            if candidate.size <= Int64(maxRawTextIndexableBytes) {
                do {
                    let data = try Data(contentsOf: candidate.url)
                    if let content = String(data: data, encoding: .utf8) {
                        tokens.formUnion(TokenExtractor.extractTokens(from: content))
                    }
                    // Non-UTF-8 bytes silently fall through — filename
                    // tokens still indexed; not a warning surface (binary
                    // file with text-y extension is benign).
                } catch {
                    warnings.append(
                        "content read failed at \(candidate.relativePath): "
                            + "\(error.localizedDescription)")
                }
            }
        }
        return IndexFilePass(tokens: tokens, warnings: warnings)
    }

    /// The folder signature, straight off the walk.
    ///
    /// No second pass: `collectCandidates` already carries every file's prefetched mTime and
    /// size, because the enumerator had them anyway. The version this replaces walked the tree
    /// and then paid one `attributesOfItem(atPath:)` per file — on EVERY `loadOrBuild`,
    /// including the cache hits that are the whole point of having a signature.
    private func computeFolderSignature() -> IndexSignature {
        var sink: [String] = []
        let candidates = collectCandidates(warnings: &sink)
        var maxMTime = Date.distantPast
        var total: Int64 = 0
        for candidate in candidates {
            if candidate.mTime > maxMTime { maxMTime = candidate.mTime }
            total += candidate.size
        }
        return IndexSignature(fileCount: candidates.count, maxMTime: maxMTime, totalSize: total)
    }

    /// Truncates a `Date` down to millisecond precision — the resolution of
    /// our `ISO-8601-with-fractional-seconds` persistence format. Without this,
    /// nanosecond-precision mTimes from the file system survive in the in-memory signature but
    /// are lost on JSON round-trip, so the fresh-walk vs disk-loaded signatures diverge and
    /// `matchesFolder` always returns false — the cache would never be reused. Rounding mode
    /// doesn't matter for correctness as long as both sides apply the same function; `.down`
    /// gives deterministic "floor to ms" which matches how the serializer clamps the fractional
    /// part.
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

    /// Walks the folder once and returns every file-like entry it found, `.rtfd` bundles
    /// included (they are single documents, not directories).
    ///
    /// `warnings` accumulates non-fatal I/O failures — an unreadable subdirectory, a symlink
    /// cycle — so callers can distinguish a partial walk from a genuinely empty tree.
    private func collectCandidates(warnings: inout [String]) -> [IndexCandidate] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: workFolderRoot.path, isDirectory: &isDir),
              isDir.boolValue
        else { return [] }
        // Cycle detection: track canonical (symlink-resolved) paths of
        // directories already entered. Without this, a symlink pointing at an
        // ancestor (`a/loop -> a/`) infinite-recurses because
        // `fileManager.fileExists(isDirectory:)` follows symlinks. Stack
        // overflow on large repos with accidental loops is a real user-facing
        // failure mode (e.g. dropbox-style synced folders).
        var visited: Set<String> = []
        var candidates: [IndexCandidate] = []
        walkRecursive(
            workFolderRoot, warnings: &warnings, visited: &visited, into: &candidates)
        return candidates
    }

    /// Resource keys prefetched during enumeration. `contentsOfDirectory(at:)` fills these from
    /// the bulk directory read the kernel already performed, so asking for four costs what
    /// asking for one does — and saves a `stat` per entry plus an `attributesOfItem` per file.
    private static let walkResourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
    ]

    private func walkRecursive(
        _ dir: URL,
        warnings: inout [String],
        visited: inout Set<String>,
        into candidates: inout [IndexCandidate]
    ) {
        // Cancellation check at each directory entry: if the enclosing Task
        // was cancelled (e.g. `coordinator.stop()` fired because the user
        // toggled exploratory-search OFF), abandon the walk immediately instead
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

        let contents: [URL]
        do {
            // Enumerate the RESOLVED directory, not `dir`. `contentsOfDirectory(at:)` returns
            // ZERO entries for a symlink URL — it is not a directory-path URL — where the
            // path-based call this replaces followed the link implicitly. A `mirror -> real/`
            // link would otherwise yield an empty subtree AND poison the cycle guard with
            // `real`'s canonical path, so the real directory would be skipped too and the whole
            // tree would index as empty. Caught by
            // `SearchIndexServiceTests.testWalk_symlinkToSibling_indexesTargetOnce`.
            contents = try fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: canonical, isDirectory: true),
                includingPropertiesForKeys: Self.walkResourceKeys, options: [])
        } catch {
            // Unreadable subdir (EACCES, EIO, broken symlink). Record and
            // move on — don't let one bad subtree silently truncate the
            // whole index.
            warnings.append("walk error at \(dir.path): \(error.localizedDescription)")
            return
        }
        // `contentsOfDirectory(at:)` does not promise an order, and the old shape sorted the
        // NAME array it got from the path-based call. `fileID` is assigned in this order, so it
        // has to stay stable across runs or two identical folders produce different postings.
        let entries = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for enumerated in entries {
            let name = enumerated.lastPathComponent
            // The LOGICAL url — built on `dir`, which may be a symlink. Paths under a linked
            // directory are reported (and indexed) under the link's name, which is what the
            // path-based walk did and what `read_file` can open.
            let itemURL = dir.appendingPathComponent(name)
            guard !WalkSkipRules.shouldSkip(name: name) else { continue }
            // Skip bookkeeping files that live directly in `.nanoteams/`
            // (e.g. `.gitignore`). User-facing content under `.nanoteams/`
            // — attachments, artifacts — still traverses.
            if dir.lastPathComponent == ".nanoteams",
               WalkSkipRules.skippedInsideNanoteamsDir.contains(name) { continue }
            // Computed once: `relativePath` normalises a URL and scans a prefix, and this loop
            // asked it three times per entry.
            let relative = relativePath(from: itemURL)
            if let prefix = internalRelPrefix,
               relative == prefix || relative.hasPrefix(prefix + "/") { continue }

            // Resource values come from the ENUMERATED url, where the directory read already
            // prefetched them; asking `itemURL` would re-stat through the link.
            //
            // ONE gate, and it warns. The shape this replaces had two — "cannot tell what it
            // is" (silent) and "know what it is, cannot read its attributes" (warned) — and the
            // second was unreachable once mTime and size came from the same prefetch that
            // reported the type. An unreachable arm on the path a reader traces to answer "what
            // happens when the walk cannot read an entry" is worse than no arm.
            guard let entry = entryAttributes(of: enumerated, name: name) else {
                // Never silent: skipping is right (a placeholder entry with a `.distantPast`
                // mTime and size 0 poisons the `IndexSignature` and rebuilds the index forever),
                // but a walk that quietly drops entries is indistinguishable from a small tree.
                warnings.append("unreadable directory entry at \(relative)")
                continue
            }
            guard case .fileLike(let mTime, let size) = entry else {
                walkRecursive(
                    itemURL, warnings: &warnings, visited: &visited, into: &candidates)
                continue
            }
            if relative.isEmpty { continue }
            candidates.append(IndexCandidate(
                url: itemURL,
                relativePath: relative,
                isRTFDBundle: name.hasSuffix(".rtfd"),
                mTime: Self.normalizedMTime(mTime),
                size: size))
        }
    }

    /// What one directory entry turned out to be.
    ///
    /// An `.rtfd` bundle is a DIRECTORY that is a file, which is why the two cases are named for
    /// what the walk does with them rather than for what the file system calls them.
    private enum WalkEntry {
        /// Descend into it.
        case directory
        /// Index it: a file, or an `.rtfd` bundle.
        case fileLike(mTime: Date, size: Int64)
    }

    /// Classifies one entry from its prefetched resource values, or `nil` when it cannot be
    /// characterised at all — it vanished between the directory read and here, or its target
    /// does not resolve.
    ///
    /// For a SYMLINK the resource values describe the LINK, while the shape this replaces asked
    /// `attributesOfItem(atPath:)` and `fileExists(atPath:isDirectory:)`, both of which FOLLOW.
    /// Resolving here keeps a symlinked file indexed with its target's size and mTime, which is
    /// what the signature has always been computed from.
    private func entryAttributes(of url: URL, name: String) -> WalkEntry? {
        guard let values = try? url.resourceValues(forKeys: Set(Self.walkResourceKeys)),
              let isDirectory = values.isDirectory
        else { return nil }
        guard values.isSymbolicLink != true else {
            let target = url.resolvingSymlinksInPath()
            guard let resolved = try? target.resourceValues(forKeys: Set(Self.walkResourceKeys)),
                  let targetIsDirectory = resolved.isDirectory
            else { return nil }
            return classify(
                url: target, name: name, isDirectory: targetIsDirectory, values: resolved)
        }
        return classify(url: url, name: name, isDirectory: isDirectory, values: values)
    }

    private func classify(
        url: URL, name: String, isDirectory: Bool, values: URLResourceValues
    ) -> WalkEntry? {
        let isRTFD = isDirectory && name.hasSuffix(".rtfd")
        if isDirectory && !isRTFD { return .directory }
        guard let mTime = values.contentModificationDate else { return nil }
        // `.fileSizeKey` is nil for a DIRECTORY, and an `.rtfd` bundle is the one file-like
        // entry that is one — so the prefetch cannot answer for it. The fallback is a single
        // `attributesOfItem` per bundle, which is what the whole walk used to pay per FILE, and
        // it keeps the signature's value identical to before.
        let size = values.fileSize.map(Int64.init)
            ?? ((try? fileManager.attributesOfItem(atPath: url.path))?[.size]
                as? NSNumber)?.int64Value
        guard let size else { return nil }
        return .fileLike(mTime: mTime, size: size)
    }

    /// `.nanoteams/internal` expressed as a work-folder-relative prefix, computed once.
    ///
    /// The walk used to call `SandboxPathResolver.isWithin` on EVERY entry — two
    /// `standardizedFileURL` normalisations plus two `pathComponents` allocations apiece. The
    /// same substitution in `SearchExecutor` was measured at 10 ms of a 25.6 ms walk.
    ///
    /// `nil` when the internal dir lies outside the root, in which case nothing the walk
    /// enumerates can be inside it and "no prefix" is the correct answer.
    private lazy var internalRelPrefix: String? = {
        let rootComponents = workFolderRoot.standardizedFileURL.pathComponents
        let dirComponents = internalDir.standardizedFileURL.pathComponents
        guard dirComponents.count > rootComponents.count,
              Array(dirComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return dirComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }()
    /// The work-folder path with a trailing separator, plus its length — both computed ONCE.
    ///
    /// `relativePath(from:)` runs per walked entry, and it used to rebuild this string and then
    /// ask it for `.count`, which is O(graphemes) on a `String`. Cheap per call and not cheap
    /// per 2 000 entries times two walks per `loadOrBuild`.
    private lazy var relativeBase: (prefix: String, length: Int) = {
        let path = workFolderRoot.path
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return (prefix, prefix.count)
    }()

    private func relativePath(from url: URL) -> String {
        let full = url.standardizedFileURL.path
        if full.hasPrefix(relativeBase.prefix) {
            return String(full.dropFirst(relativeBase.length))
        }
        return url.lastPathComponent
    }
}
