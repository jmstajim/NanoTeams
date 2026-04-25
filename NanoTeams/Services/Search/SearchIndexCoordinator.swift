import Foundation
import Observation

/// `@MainActor @Observable` coordinator that owns the per-work-folder
/// `SearchIndexService` actor, an `FileSystemWatcher`, and the observable UI
/// state (isBuilding / counts / lastBuiltAt / lastError) shown in the sidebar
/// pill and the Advanced settings tab.
///
/// Lifecycle: created by `NTMSOrchestrator` when a work folder opens AND
/// expanded search is enabled; torn down on folder close OR when the user flips
/// the setting off. Safe to `start()` / `stop()` repeatedly.
@Observable @MainActor
final class SearchIndexCoordinator {

    // MARK: - Observable State

    /// True while the token-index (`search_index.json`) is being rebuilt.
    /// **Not** set during the embedding phase — that has its own flag so the
    /// existing "Indexing…" card doesn't get stuck for minutes on a first
    /// full vector build.
    private(set) var isBuilding: Bool = false
    /// True while the vector index is being built (post-token-index phase).
    /// Observed by `ExpandedSearchEmbeddingsCard` to render a separate progress
    /// indicator from the token-index status.
    private(set) var isBuildingVectorIndex: Bool = false
    private(set) var tokenCount: Int? = nil
    private(set) var fileCount: Int? = nil
    private(set) var lastBuiltAt: Date? = nil
    private(set) var lastError: String? = nil
    /// Snapshot of the vector index service's state — mirrors `VocabVectorIndexState`.
    /// UI reads this directly; we don't proxy every variant to a separate field.
    private(set) var vectorIndexState: VocabVectorIndexState = .missing
    /// Live per-batch progress during a vector rebuild. `nil` when not building.
    /// Separate from `vectorIndexState` because `.building` also carries the
    /// same data — this field is a convenience for `ExpandedSearchEmbeddingsCard`.
    private(set) var vectorIndexProgress: VocabVectorIndexBuilder.BuildProgress?

    // MARK: - Dependencies

    @ObservationIgnored let workFolderRoot: URL
    @ObservationIgnored let internalDir: URL
    @ObservationIgnored let service: SearchIndexService
    @ObservationIgnored let vectorIndex: VocabVectorIndexService
    @ObservationIgnored private var watcher: FileSystemWatcher?
    /// Token-index walk task. **Cancellable on every FS event** — a stale
    /// walk is cheap to drop and re-run with the latest folder state.
    @ObservationIgnored private var currentTokenBuildTask: Task<Void, Never>?
    /// Vector-index embedding task. **Decoupled from token cancellation**
    /// because each batch of `/v1/embeddings` calls is paid network work —
    /// cancelling mid-build throws away embeddings already received from
    /// LM Studio, and the next FS-event-driven smart-diff would re-embed
    /// the same `added` set against an unchanged `cached`. Repeated
    /// FS bursts during a headless run produced an apparent "rebuild from
    /// scratch" loop. FS events now request a vector refresh AFTER the
    /// token build completes; multiple requests during an in-flight
    /// vector build coalesce into a single follow-up via
    /// `pendingVectorRefresh`. Only `stop()` legitimately cancels here.
    @ObservationIgnored private var currentVectorBuildTask: Task<Void, Never>?
    /// Coalescing flag. When a vector refresh is requested while a build
    /// is already in flight, set this so the build-completion path drains
    /// it via one follow-up build. Many FS events during a long embed →
    /// at most one extra build queued.
    @ObservationIgnored private var pendingVectorRefresh: Bool = false
    /// Snapshotted every time a vector build kicks off. `@MainActor` closure —
    /// safe to call from the coordinator's own isolation and captures any
    /// MainActor-resident `StoreConfiguration`.
    @ObservationIgnored private let embeddingConfigProvider: @MainActor () -> EmbeddingConfig

    // MARK: - Init

    init(
        workFolderRoot: URL,
        internalDir: URL,
        embeddingConfigProvider: @escaping @MainActor () -> EmbeddingConfig = { .defaultNomicLMStudio },
        embeddingClient: any EmbeddingClient = LMStudioEmbeddingClient(),
        fileManager: FileManager = .default
    ) {
        self.workFolderRoot = workFolderRoot
        self.internalDir = internalDir
        self.embeddingConfigProvider = embeddingConfigProvider
        self.service = SearchIndexService(
            workFolderRoot: workFolderRoot,
            internalDir: internalDir,
            fileManager: fileManager
        )
        self.vectorIndex = VocabVectorIndexService(
            internalDir: internalDir,
            client: embeddingClient,
            fileManager: fileManager
        )
    }

    // MARK: - Lifecycle

    /// Spawns the watcher, seeds vector-index state from disk, and kicks off
    /// the initial `ensureFresh()` pass in a **background task** so `start()`
    /// returns promptly. Callers (including `NTMSOrchestrator` during toggle
    /// ON) must not be blocked on a multi-minute embedding build — otherwise
    /// a subsequent toggle OFF gets queued behind it and the user perceives
    /// indexing as "stuck on." `stop()` / `clear()` cancel both the token
    /// and vector tasks; `awaitIndex()` blocks on the token build only so
    /// posting-list consumers don't wait minutes for an embedding refresh.
    func start() async {
        if watcher == nil {
            let w = FileSystemWatcher(
                paths: [workFolderRoot],
                // Skip events from `.nanoteams/internal/` — every tool call
                // during an active run appends to `tool_calls.jsonl` /
                // `network_log.json` there, and those paths are already
                // excluded from the index walk, so each one would trigger
                // a wasted signature probe.
                excludedPrefixes: [internalDir],
                debounce: 2.0,
                onChange: { [weak self] in
                    Task { @MainActor in
                        self?.scheduleEnsureFresh()
                    }
                }
            )
            let started = w.start()
            watcher = w
            if !started {
                // Watcher death is rare (empty paths or kernel-level
                // FSEventStreamCreate failure) but user-visible: the index
                // will still be built once, but won't auto-refresh. Surface
                // so the user knows to hit the Rebuild button manually.
                lastError = "File-system watcher unavailable — index won't auto-refresh. "
                    + "Use Rebuild to refresh manually."
            }
        }
        // Seed the vector-index state from disk before the first build so the
        // UI card immediately reflects "ready" vs "missing" without waiting
        // for the build to complete.
        await vectorIndex.load()
        self.vectorIndexState = await vectorIndex.state
        // Fire-and-forget the initial ensure-fresh so start() returns in ms,
        // not minutes. `runBuild` installs `currentTokenBuildTask` at its top
        // so `awaitIndex()` can block on the fresh token walk, and `stop()`
        // tears down both pipelines on toggle off.
        scheduleEnsureFresh()
    }

    /// Tears down the watcher and cancels any in-flight build. This is the
    /// **only** legitimate site that cancels `currentVectorBuildTask` — FS
    /// events never do (see field doc).
    func stop() async {
        watcher?.stop()
        watcher = nil
        currentTokenBuildTask?.cancel()
        currentVectorBuildTask?.cancel()
        if let task = currentTokenBuildTask {
            _ = await task.value
        }
        if let task = currentVectorBuildTask {
            _ = await task.value
        }
        currentTokenBuildTask = nil
        currentVectorBuildTask = nil
        pendingVectorRefresh = false
    }

    func rebuild() async {
        await runBuild(force: true)
    }

    /// Signature-only freshness check — avoids rebuilding when the disk
    /// index still matches the folder on (fileCount, maxMTime, totalSize).
    func ensureFresh() async {
        await runBuild(force: false)
    }

    /// Returns `nil` only if the service can't produce an index (shouldn't
    /// normally happen — the actor always returns *something*). Awaits only
    /// the token build — callers that need the posting list don't have to
    /// wait minutes for an embedding refresh to land.
    func awaitIndex() async -> SearchIndex? {
        if let task = currentTokenBuildTask {
            _ = await task.value
        }
        return await service.loadOrBuild(force: false)
    }

    /// Stops the watcher, deletes the on-disk index (token and vector),
    /// resets observable state. Surfaces clear failures so the user knows
    /// their "Clear → Rebuild" didn't actually clear (e.g. locked file).
    func clear() async {
        await stop()
        await service.clear()
        await vectorIndex.clear()
        isBuilding = false
        isBuildingVectorIndex = false
        tokenCount = nil
        fileCount = nil
        lastBuiltAt = nil
        // Surface clear failures from either subsystem. Token clear takes
        // priority because the user-visible action ("Clear index") talks
        // about the token index. Vector clear errors fall to lastError below.
        let tokenClearError = await service.lastClearError
        let vectorClearError = await vectorIndex.lastClearError
        if let tokenClearError {
            lastError = "Failed to clear search index: \(tokenClearError)"
        } else if let vectorClearError {
            lastError = "Failed to clear vector index: \(vectorClearError)"
        } else {
            lastError = nil
        }
        vectorIndexState = .missing
        vectorIndexProgress = nil
    }

    /// Smart-diff rebuild of the vector index against the currently loaded
    /// token index. Invoked by the "Rebuild embeddings" button in Advanced
    /// Settings — distinct from `rebuild()` which regenerates the token
    /// index too.
    func rebuildVectorIndex() async {
        await runVectorBuild(force: false)
    }

    /// Full vector rebuild — discards every existing embedding and re-embeds
    /// the whole filtered vocab. Overflow-menu action on the card; used when
    /// the user suspects data drift or wants to re-embed with a new model.
    func rebuildVectorIndexFull() async {
        await runVectorBuild(force: true)
    }

    // MARK: - Private

    /// Non-blocking entry point used by the FS watcher callback. Cancels
    /// only the token-build task (cheap walk; safe to drop and restart on
    /// every event). The vector pipeline is **not** cancelled here — see
    /// `requestVectorRefresh` for the coalescing path that follows token
    /// completion.
    private func scheduleEnsureFresh() {
        currentTokenBuildTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performTokenBuild(force: false)
            // Don't trigger vector refresh on a cancelled walk — the token
            // index didn't actually update. The next `scheduleEnsureFresh`
            // call (or the next FS event) will run vector refresh after
            // its own successful token build.
            if Task.isCancelled { return }
            self.requestVectorRefresh()
        }
        currentTokenBuildTask = task
    }

    /// Serial entry point for user-initiated rebuilds (`rebuild` button,
    /// `ensureFresh`). Awaits both the token build AND the vector build so
    /// callers that asked for a full refresh actually get one.
    private func runBuild(force: Bool) async {
        // Token phase: wait for any in-flight FS-event-driven walk, then
        // run our own. A user-initiated rebuild deserves the freshest walk.
        if let task = currentTokenBuildTask, !task.isCancelled {
            _ = await task.value
        }
        let tokenTask = Task { [weak self] in
            guard let self else { return }
            await self.performTokenBuild(force: force)
        }
        currentTokenBuildTask = tokenTask
        _ = await tokenTask.value
        if currentTokenBuildTask == tokenTask {
            currentTokenBuildTask = nil
        }

        // Vector phase: serialize via the existing helper. If an FS-event
        // vector build is in flight, we wait for it first (it may already
        // have done most of the embed work we'd otherwise repeat).
        let idx = await service.loadOrBuild(force: false)
        await runSerializedVectorBuild(searchIndex: idx, force: force)
    }

    private func performTokenBuild(force: Bool) async {
        isBuilding = true
        let idx = await service.loadOrBuild(force: force)
        tokenCount = idx.tokens.count
        fileCount = idx.files.count
        lastBuiltAt = idx.generatedAt
        // Surface persistence / load failures AND non-fatal walk warnings so
        // the Advanced settings status card can show the user why their index
        // didn't stick on disk, was regenerated because the prior copy was
        // corrupt, or isn't comprehensive. Priority: persist > load > walk.
        let persistError = await service.lastPersistError
        let loadError = await service.lastLoadError
        let warnings = await service.lastIndexWarnings
        if let persistError {
            lastError = persistError
        } else if let loadError {
            lastError = loadError
        } else if !warnings.isEmpty {
            lastError = "Index built with \(warnings.count) walk warning(s). "
                + "Some files may be missing from the index."
        } else {
            lastError = nil
        }
        isBuilding = false
    }

    /// FS-event-driven vector refresh entry point. **Coalesces** instead of
    /// cancelling: if a vector build is already in flight, mark a deferred
    /// follow-up and return. The completion path of `startVectorBuild`
    /// drains the flag with one extra build. This preserves embeddings
    /// already received from LM Studio in the in-flight build instead of
    /// throwing them away each time a new artifact is written.
    private func requestVectorRefresh() {
        if let task = currentVectorBuildTask, !task.isCancelled {
            pendingVectorRefresh = true
            return
        }
        startVectorBuild()
    }

    private func startVectorBuild() {
        pendingVectorRefresh = false
        // `Task { ... }` is unstructured — not a child of any enclosing
        // task — so a future cancellation of `currentTokenBuildTask`
        // does NOT propagate here. This is the architectural boundary
        // between the cancellable token domain and the work-preserving
        // vector domain.
        let task = Task { [weak self] in
            guard let self else { return }
            let idx = await self.service.loadOrBuild(force: false)
            await self.performVectorBuild(searchIndex: idx, force: false)
            // Drain any FS events that arrived while we were building.
            if self.pendingVectorRefresh {
                self.startVectorBuild()
            }
        }
        currentVectorBuildTask = task
    }

    /// Entry point for the "Rebuild embeddings" button. Reuses the current
    /// token index (no token-level rebuild) and runs smart-diff or full
    /// rebuild depending on `force`. Awaits completion so the user-facing
    /// progress UI tracks accurately.
    private func runVectorBuild(force: Bool) async {
        let idx = await service.loadOrBuild(force: false)
        await runSerializedVectorBuild(searchIndex: idx, force: force)
    }

    /// Serialized wrapper: token-index rebuild, FS-watcher-driven vector
    /// refresh, and menu-driven "Rebuild embeddings" all funnel through here.
    /// A prior in-flight vector build is awaited (not cancelled) so the
    /// atomic persist of the earlier build lands cleanly before the next one
    /// reads its bin. Without this, two concurrent vector builds race on
    /// `isBuildingVectorIndex` and the progress handler installation on the
    /// actor.
    private func runSerializedVectorBuild(searchIndex: SearchIndex, force: Bool) async {
        if let task = currentVectorBuildTask, !task.isCancelled {
            _ = await task.value
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performVectorBuild(searchIndex: searchIndex, force: force)
        }
        currentVectorBuildTask = task
        _ = await task.value
        if currentVectorBuildTask == task {
            currentVectorBuildTask = nil
        }
    }

    private func performVectorBuild(searchIndex: SearchIndex, force: Bool) async {
        isBuildingVectorIndex = true
        defer {
            isBuildingVectorIndex = false
            vectorIndexProgress = nil
        }
        // Bridge builder progress into observable state. The handler fires
        // on the actor's isolation context — hop to MainActor to mutate the
        // published field.
        await vectorIndex.setProgressHandler { [weak self] progress in
            Task { @MainActor in
                self?.vectorIndexProgress = progress
                self?.vectorIndexState = .building(progress: progress)
            }
        }
        await vectorIndex.rebuildIfNeeded(
            searchIndex: searchIndex,
            config: embeddingConfigProvider(),
            force: force
        )
        vectorIndexState = await vectorIndex.state
        await vectorIndex.setProgressHandler(nil)
    }

    nonisolated deinit {}
}
