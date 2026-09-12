import Foundation

/// Actor wrapping the work folder's vocabulary index. One instance per work folder.
///
/// Owns the lifecycle: walk, diff, read only what changed, fold, save, clear. The DECISIONS
/// live in `SearchIndexPlanner` (pure) and the walk in `SearchIndexWalker` (I/O, no policy);
/// what is left here is the actor state — the cache, the single-flight build, the error slots —
/// and persistence.
///
/// **The index lives in memory and is written at closing time.** A build produces a new
/// vocabulary in memory and marks it unsaved; `flush()` writes it, and the coordinator calls
/// that from `stop()` (folder close, setting off) and the app from `applicationShouldTerminate`.
/// The one exception is a FULL rebuild, which checkpoints immediately: it costs seconds of
/// tokenization and losing that to a crash would be paid again on the next launch. A crash
/// otherwise loses nothing that matters — the file is a cache, so files changed since the last
/// save simply read as dirty against the saved roster and are re-tokenized.
///
/// Concurrency: `loadOrBuild` is single-flight — a second caller arriving during a build JOINS
/// it rather than starting its own.
///
/// The actor alone used to be enough, and the note here said so: the method was synchronous, so
/// the freshness check and the rebuild could not be interleaved. That reading stops holding the
/// moment the rebuild gains a suspension point — a second caller wedges in, sees no cache, and
/// starts a DUPLICATE full walk of the tree. Actor REENTRANCY is precisely the thing "the actor
/// serializes calls" does not buy you.
actor SearchIndexService {

    // MARK: - File Scope Constants

    /// Text extensions we read as raw UTF-8 during indexing. Anything outside
    /// this set AND outside `DocumentTextExtractor.supportedReadExtensions`
    /// contributes only its filename tokens (no content scan).
    ///
    /// Changing this changes what a file tokenizes into — bump
    /// `SearchIndex.currentVersion` with it, or half the vocabulary stays in the old shape
    /// until the churn budget happens to force a full rebuild.
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

    private let indexFileURL: URL
    private let fileManager: FileManager
    private let walker: SearchIndexWalker
    private let vocabularyFilter: SearchIndexPlanner.VocabularyFilter

    /// In-memory index — the source of truth while a folder is open.
    private var cached: SearchIndex?

    /// True when `cached` is ahead of the file on disk. The one condition `flush()` acts on.
    private(set) var hasUnsavedChanges: Bool = false

    /// Whether the on-disk file has been consulted yet. It is read ONCE per folder, on the
    /// first build; after that memory is authoritative and re-reading it could only regress.
    private var didProbeDisk: Bool = false

    /// The rebuild every concurrent caller shares while it runs.
    ///
    /// Deliberately consulted only by NON-forced callers. `force: true` means "ignore what you
    /// have and go look again" — joining a walk that started before the caller's reason for
    /// asking would hand back exactly the staleness it forced past. Two concurrent forces
    /// therefore do duplicate work, which is the correct trade: `force` is user-initiated
    /// ("Rebuild"), and the coordinator serializes its own through `currentTokenBuildTask`.
    private var inFlightBuild: Task<SearchIndex, Never>?

    // MARK: - Init

    init(
        workFolderRoot: URL,
        internalDir: URL,
        fileManager: sending FileManager = .default,
        vocabularyFilter: SearchIndexPlanner.VocabularyFilter = .default
    ) {
        let root = workFolderRoot.standardizedFileURL
        let internalRoot = internalDir.standardizedFileURL
        self.fileManager = fileManager
        self.indexFileURL = internalRoot.appendingPathComponent(
            "search_index.json", isDirectory: false)
        self.walker = SearchIndexWalker(
            workFolderRoot: root, internalDir: internalRoot, fileManager: fileManager)
        self.vocabularyFilter = vocabularyFilter
    }

    // MARK: - Diagnostics

    /// Last persistence error, if any. Cleared on successful persist. The coordinator reads it
    /// after every build so the Advanced settings card can surface disk-write failures.
    private(set) var lastPersistError: String?

    /// Non-fatal warnings from the most recent `loadOrBuild`: unreadable subdirectories,
    /// symlinks pointing outside the folder, files whose content could not be read.
    ///
    /// Recomputed from scratch every time, never persisted — the walk runs on every call and
    /// unreadable files are retried on every call (Д6), so the list is always current and
    /// complete. It is published on the `.reuse` path too, which fixes a standing bug: a fresh
    /// process serving a disk index used to report a clean build for a walk that had warnings.
    private(set) var lastIndexWarnings: [String] = []

    /// Populated when `loadFromDisk` hits a corrupt payload (malformed JSON, version drift, or
    /// the duplicate-path invariant from `SearchIndex.init(from:)`). Distinct from "no file on
    /// first launch" — nil means the last load either succeeded or found nothing.
    ///
    /// It SURVIVES the rebuild it triggered, which is what lets the settings card say the index
    /// was regenerated *because* the previous copy was bad — but only for that one build.
    private(set) var lastLoadError: String?

    /// Populated when `clear()` failed to remove the on-disk file (locked, read-only volume).
    /// Surfaced because a silent failure means the next launch reads the stale copy after the
    /// user explicitly asked for a clear+rebuild.
    private(set) var lastClearError: String?

    // MARK: - Public API

    /// Returns a current index, re-reading only the files whose `(mTime, size)` moved.
    ///
    /// Cancellation: the walk checks `Task.isCancelled` between directories and every content
    /// pass checks it before reading. A cancelled walk produces NOTHING — no diff, no cache, no
    /// write — because a truncated candidate list is indistinguishable from a mass deletion. A
    /// cancelled content pass leaves its file unstamped, so the next call finishes the job.
    func loadOrBuild(force: Bool = false) async -> SearchIndex {
        if !force {
            // Join an in-flight build rather than starting a second walk of the same tree.
            // From actor entry to the assignment below there is no suspension point, which is
            // what makes "check, then claim" atomic without a lock.
            //
            // A joiner must not inherit a build its INITIATOR abandoned.
            // `scheduleEnsureFresh` cancels the previous token task before installing its own,
            // so the ordinary double-`start()` sequence is exactly: task 1 claims the slot,
            // task 2 joins it, task 1 is cancelled — and the shared build dies under a caller
            // who never asked for that. A joiner that lands on a cancelled build therefore runs
            // its own. Pinned by `SearchIndexCoordinatorTests.testDoubleStart_isSafe`.
            if let existing = inFlightBuild, !existing.isCancelled {
                let joined = await existing.value
                if !existing.isCancelled { return joined }
            }
        }

        let build = Task { [self] in await performRebuild(force: force) }
        inFlightBuild = build
        // An unstructured `Task` does not inherit its creator's cancellation, and
        // `SearchIndexCoordinator.stop()` depends on that inheritance: it cancels the
        // token-build task expecting the walk to abandon rather than finish against a folder
        // being torn down. The INITIATOR forwards it by hand. Joiners deliberately do not — a
        // cancelled search must not kill the index build an FS event started for everyone else.
        let fresh = await withTaskCancellationHandler {
            await build.value
        } onCancel: {
            build.cancel()
        }
        // Only if it is still OURS: a `force` caller arriving mid-build installs its own.
        if inFlightBuild == build { inFlightBuild = nil }
        return fresh
    }

    /// Writes the in-memory index if it is ahead of disk. The closing half of the lifecycle —
    /// called by `SearchIndexCoordinator.stop()` and by the app's termination delegate.
    ///
    /// A no-op when nothing changed, so closing a folder nobody edited does not rewrite a
    /// megabyte, and `clear()` can skip it entirely rather than write what it is about to
    /// delete.
    func flush() {
        guard hasUnsavedChanges, let cached else { return }
        persist(cached)
        if lastPersistError == nil { hasUnsavedChanges = false }
    }

    /// Deletes the on-disk index and drops the in-memory one. Surfaces any removeItem failure
    /// via `lastClearError` so the coordinator can show the user that their "Clear → Rebuild"
    /// didn't actually clear — without this, the next launch silently returns the stale copy.
    func clear() {
        cached = nil
        hasUnsavedChanges = false
        didProbeDisk = false
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

    // MARK: - Private: the build

    /// The base for this build's diff: memory first, then disk — and disk exactly once.
    private func currentBase() -> SearchIndex? {
        if let cached {
            // A cache we built ourselves proves any earlier load problem is behind us. Retiring
            // it HERE rather than at the end of the rebuild is what keeps the message useful:
            // the rebuild that fixed the index still reports why it happened, and the next one
            // retires it. Without this the error became IMMORTAL — every later build re-read it
            // and the settings card showed it for the rest of the session.
            lastLoadError = nil
            return cached
        }
        guard !didProbeDisk else { return nil }
        didProbeDisk = true
        let onDisk = loadFromDisk()
        cached = onDisk
        return onDisk
    }

    private func performRebuild(force: Bool) async -> SearchIndex {
        let base = currentBase()
        let walk = walker.walk()
        guard walk.isComplete else {
            // Д2: a cancelled walk earns no right to a diff and no right to persist. Its
            // truncated candidate list would read as a mass deletion, and the vocabulary of
            // every "deleted" file would be dropped at the next full rebuild.
            return abandoned(base: base)
        }
        // The roster invariant, enforced where it is PRODUCED. Once here, `plan`, `merge` and
        // `build` all see a duplicate-free list by construction — which is the only way a walk
        // defect stops being able to mint an index that no later launch can decode.
        let roster = SearchIndexPlanner.deduplicated(walk.candidates)
        // Concatenated, not branched on: `roster.warnings` is empty on every healthy walk, so
        // there is no arm here that only a defect could reach.
        var warnings = walk.warnings + roster.warnings

        switch (SearchIndexPlanner.plan(candidates: roster.candidates,
                                        base: force ? nil : base), base) {
        case (.reuse, .some(let base)):
            // Byte-identical to what the caller had, `generatedAt` included: the settings
            // card's "last built" must not tick for a build that read nothing, and the churn
            // budget must not grow.
            lastIndexWarnings = warnings
            return base

        case (.incremental(let diff), .some(let base)):
            let dirtyCandidates = diff.dirty.map { roster.candidates[$0] }
            let passes = await Self.runFilePasses(
                dirtyCandidates, concurrency: SearchExecutor.defaultScanConcurrency)
            warnings.append(contentsOf: Self.warnings(from: passes))
            lastIndexWarnings = warnings
            let merged = SearchIndexPlanner.merge(
                base: base, candidates: roster.candidates, diff: diff, passes: passes,
                generatedAt: Self.now())
            cached = merged
            // In memory only. The write happens at closing time — that is the whole point of
            // reading just the dirty files: an edit costs milliseconds, not a megabyte of I/O.
            hasUnsavedChanges = true
            return merged

        // Everything else is a full rebuild — including the structurally impossible pairs
        // (`.reuse` or `.incremental` without a base), for which rebuilding is the safe answer.
        default:
            let passes = await Self.runFilePasses(
                roster.candidates, concurrency: SearchExecutor.defaultScanConcurrency)
            warnings.append(contentsOf: Self.warnings(from: passes))
            guard let built = SearchIndexPlanner.build(
                candidates: roster.candidates, passes: passes, filter: vocabularyFilter,
                generatedAt: Self.now())
            else {
                // A cancelled pass. Applying the document-frequency filter to a subset of the
                // tree would drop shared words as singletons, so a partial full build is worse
                // than none.
                return abandoned(base: base)
            }
            lastIndexWarnings = warnings
            cached = built
            // Checkpoint. Everything else waits for `flush()`, but a full rebuild is the
            // expensive one — seconds of tokenization — and re-paying it after a crash is the
            // one loss worth a write.
            persist(built)
            hasUnsavedChanges = lastPersistError != nil
            return built
        }
    }

    /// What a build hands back when it may not keep its own result: whatever was already
    /// true. Nothing is cached and nothing is written — the two ways to abandon a build (a
    /// cancelled walk, a cancelled content pass) answer identically, so they say so in one
    /// place.
    private func abandoned(base: SearchIndex?) -> SearchIndex {
        cached ?? base ?? Self.emptyIndex()
    }

    /// CLAUDE.md mandates `MonotonicClock.shared.now()` for model timestamps — `generatedAt` is
    /// persisted, surfaced as `lastBuiltAt`, and read by tests, so it qualifies. Floored to the
    /// millisecond the persistence format carries, so an in-memory index compares equal to its
    /// own round-trip.
    private static func now() -> Date {
        SearchIndexWalker.normalizedMTime(MonotonicClock.shared.now())
    }

    private static func emptyIndex() -> SearchIndex {
        SearchIndex(generatedAt: now(), files: [], vocabulary: [])
    }

    private static func warnings(from passes: [SearchIndexPlanner.IndexFilePass]) -> [String] {
        passes.compactMap {
            if case .unreadable(let warning) = $0 { return warning }
            return nil
        }
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
            // Corrupt JSON or the duplicate-path invariant thrown by `SearchIndex.init(from:)`.
            // Surfaced so the UI pill can tell the user their index was regenerated because the
            // on-disk copy was bad.
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
            let encoder = JSONCoderFactory.makeCompactPersistenceEncoder()
            let data = try encoder.encode(index)
            try data.write(to: indexFileURL, options: .atomic)
            lastPersistError = nil
        } catch {
            // Best effort — search still works off the in-memory index; the next launch just
            // rebuilds. Surface to the coordinator AND log for diagnostics.
            lastPersistError = error.localizedDescription
            print("[SearchIndexService] WARNING: failed to persist index: \(error)")
        }
    }

    // MARK: - Private: Content passes

    /// Reads and tokenises every candidate, `concurrency` at a time.
    ///
    /// A window rather than "add them all and let the group sort it out": every in-flight pass
    /// holds one file's bytes resident, and `maxRawTextIndexableBytes` is 1 MB, so an unbounded
    /// fan-out over a large repo is an unbounded allocation. Results are returned in CANDIDATE
    /// order — the caller zips them against the list it passed in.
    ///
    /// No early exit and no shared budget, which is what makes this simpler than the grep's
    /// equivalent: nothing a pass discovers can make an earlier or later pass wrong.
    private static func runFilePasses(
        _ candidates: [SearchIndexPlanner.IndexCandidate],
        concurrency: Int
    ) async -> [SearchIndexPlanner.IndexFilePass] {
        guard !candidates.isEmpty else { return [] }
        // Collected as pairs and sorted, not written into a pre-sized optional array: the loop
        // adds exactly `candidates.count` tasks and drains the group, so an empty slot was
        // unreachable — and an unreachable `??` is a branch a reader has to rule out by hand.
        var collected: [(index: Int, pass: SearchIndexPlanner.IndexFilePass)] = []
        collected.reserveCapacity(candidates.count)

        await withTaskExecutorPreference(BlockingIOTaskExecutor.shared) {
            await withTaskGroup(of: (Int, SearchIndexPlanner.IndexFilePass).self) { group in
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
    private static func indexOne(
        _ candidate: SearchIndexPlanner.IndexCandidate
    ) -> SearchIndexPlanner.IndexFilePass {
        // Д1: `.cancelled`, not an empty token set. An empty set would stamp the file into the
        // roster with a fresh `(mTime, size)` and none of its words, and the next diff would
        // call it clean forever.
        if Task.isCancelled { return .cancelled }
        var tokens = TokenExtractor.extractFilenameTokens(from: candidate.url)

        let ext = candidate.url.pathExtension.lowercased()
        if DocumentTextExtractor.isSupported(extension: ext) {
            if case .text(let extracted, _) = DocumentTextExtractor.extract(from: candidate.url) {
                tokens.formUnion(TokenExtractor.extractTokens(from: extracted))
            }
        } else if textIndexableExtensions.contains(ext),
                  candidate.size <= Int64(maxRawTextIndexableBytes) {
            do {
                let data = try Data(contentsOf: candidate.url)
                if let content = String(data: data, encoding: .utf8) {
                    tokens.formUnion(TokenExtractor.extractTokens(from: content))
                }
                // Non-UTF-8 bytes silently fall through — filename tokens still indexed; not a
                // warning surface (a binary file with a text-y extension is benign).
            } catch {
                // Д6: unreadable is a fact about the FILE, not about this build. Reporting it
                // as `.unreadable` keeps the file out of the roster, so it is retried and
                // re-warned every time — and a `chmod` that restores access heals it, which a
                // warning remembered in the roster never could (chmod does not move mtime).
                return .unreadable(
                    warning: "content read failed at \(candidate.relativePath): "
                        + "\(error.localizedDescription)")
            }
        }
        return .indexed(tokens)
    }
}
