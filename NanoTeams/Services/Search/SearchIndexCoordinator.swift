import Foundation
import Observation

/// `@MainActor @Observable` coordinator that owns the per-work-folder
/// `SearchIndexService` actor, an `FileSystemWatcher`, and the observable UI
/// state (isBuilding / counts / lastBuiltAt / lastError) shown in the sidebar
/// pill and the Advanced settings tab.
///
/// Lifecycle: created by `NTMSOrchestrator` when a work folder opens AND
/// exploratory search is enabled; torn down on folder close OR when the user flips
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
    /// Observed by `ExploratorySearchEmbeddingsCard` to render a separate progress
    /// indicator from the token-index status.
    private(set) var isBuildingVectorIndex: Bool = false
    private(set) var tokenCount: Int? = nil
    private(set) var fileCount: Int? = nil
    private(set) var lastBuiltAt: Date? = nil

    /// Diagnostics about the index **as it stands on disk right now** — a persist or load
    /// failure, non-fatal walk warnings, or a failed clear. Correctly cleared by the next
    /// successful build, because a fresh successful build makes all three obsolete.
    private(set) var buildError: String? = nil

    /// Set when the FS watcher refuses to subscribe, cleared only by `stop()`.
    ///
    /// Kept in its own slot because the two conditions have different lifetimes and the
    /// build's success arm writes `nil`. Until 2026-08-09 both shared `lastError`, so the
    /// watcher-death message `start()` wrote was erased milliseconds later by the initial
    /// `ensureFresh()` it goes on to schedule — the message existed, was documented as
    /// "user-visible", and never reached a render. That is the worst version of this bug:
    /// auto-refresh is off, the index quietly serves stale results, and the one signal saying
    /// so is destroyed by the very build that proves the index still works.
    private(set) var watcherError: String? = nil

    /// What the Advanced settings card shows. Derived rather than stored so neither condition
    /// can clobber the other: they are independent, and whichever wrote last would otherwise win.
    var lastError: String? {
        let parts = [buildError, watcherError].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
    /// Snapshot of the vector index service's state — mirrors `VocabVectorIndexState`.
    /// UI reads this directly; we don't proxy every variant to a separate field.
    private(set) var vectorIndexState: VocabVectorIndexState = .missing
    /// Live per-batch progress during a vector rebuild. `nil` when not building.
    /// Separate from `vectorIndexState` because `.building` also carries the
    /// same data — this field is a convenience for `ExploratorySearchEmbeddingsCard`.
    private(set) var vectorIndexProgress: VocabVectorIndexBuilder.BuildProgress?

    // MARK: - Dependencies

    @ObservationIgnored let workFolderRoot: URL
    @ObservationIgnored let internalDir: URL
    @ObservationIgnored let service: SearchIndexService
    @ObservationIgnored let vectorIndex: VocabVectorIndexService
    @ObservationIgnored private var watcher: (any FileSystemWatching)?
    /// Builds the watcher `start()` installs. See `FileSystemWatcherFactory` for why this
    /// has no default: production hands in `FileSystemWatcher.live`, tests hand in an inert
    /// or scripted double, and neither is reachable by forgetting an argument.
    @ObservationIgnored private let makeWatcher: FileSystemWatcherFactory
    /// FSEvents debounce window. Production default 2.0s coalesces bursty
    /// writes (e.g. `git checkout`, IDE save-all) into a single rebuild.
    /// Tests override to ~0.05s so they don't pay multi-second waits per
    /// `rebuild()`/`ensureFresh()` cycle.
    @ObservationIgnored private let watcherDebounce: TimeInterval
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
    /// Set by `stop()` to refuse new work of ANY kind; cleared by `start()`.
    /// See `stop()`'s doc for the cancellation-tail race it closes.
    ///
    /// Until 2026-08-10 this read "refuse new **vector** tasks", and that was the literal truth:
    /// of the four sites that install a `Task`, only `startVectorBuild` consulted it. The other
    /// three ran full folder walks and embedding batches against a folder the coordinator had
    /// been torn down for, installed in slots `stop()`'s drain had already passed — so nothing
    /// could cancel or await them for the rest of the process. Every site now gates, and re-gates
    /// after any suspension, because `stop()` can run to completion inside one.
    @ObservationIgnored private var isStopped: Bool = false
    /// Snapshotted every time a vector build kicks off. `@MainActor` closure —
    /// safe to call from the coordinator's own isolation and captures any
    /// MainActor-resident `StoreConfiguration`.
    @ObservationIgnored private let embeddingConfigProvider: @MainActor () -> EmbeddingConfig

    /// Named so the test that proves the message survives the initial build compares against
    /// the same string production emits, rather than re-typing a substring that would keep
    /// passing after a reword.
    static let watcherUnavailableMessage =
        "File-system watcher unavailable — index won't auto-refresh. Use Rebuild to refresh manually."

    // MARK: - Init

    init(
        workFolderRoot: URL,
        internalDir: URL,
        embeddingConfigProvider: @escaping @MainActor () -> EmbeddingConfig = { .defaultNomicLMStudio },
        embeddingClient: any EmbeddingClient = LMStudioEmbeddingClient(),
        fileManager: FileManager = .default,
        makeWatcher: @escaping FileSystemWatcherFactory,
        watcherDebounce: TimeInterval = AppDefaults.searchIndexWatcherDebounceSeconds
    ) {
        self.workFolderRoot = workFolderRoot
        self.internalDir = internalDir
        self.embeddingConfigProvider = embeddingConfigProvider
        self.makeWatcher = makeWatcher
        self.watcherDebounce = watcherDebounce
        // FileManager isn't `Sendable`, and a `sending` parameter is consumed on
        // the first hand-off. Construct fresh `.default` references for each
        // actor so the original `fileManager` parameter (preserved for future
        // injection / API compatibility) doesn't get sent twice.
        _ = fileManager
        self.service = SearchIndexService(
            workFolderRoot: workFolderRoot,
            internalDir: internalDir,
            fileManager: .default
        )
        self.vectorIndex = VocabVectorIndexService(
            internalDir: internalDir,
            client: embeddingClient,
            fileManager: .default
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
        isStopped = false
        if watcher == nil {
            let w = makeWatcher(
                [workFolderRoot],
                // Skip events from `.nanoteams/internal/` — every tool call
                // during an active run appends to `tool_calls.jsonl` /
                // `network_log.json` there, and those paths are already
                // excluded from the index walk, so each one would trigger
                // a wasted signature probe.
                [internalDir],
                watcherDebounce,
                { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.scheduleEnsureFresh()
                    }
                }
            )
            let started = w.start()
            watcher = w
            // Watcher death is rare (empty paths or kernel-level
            // FSEventStreamCreate failure) but user-visible: the index
            // will still be built once, but won't auto-refresh. Surface
            // so the user knows to hit the Rebuild button manually.
            //
            // Written to `watcherError`, NOT `lastError` — the initial
            // `scheduleEnsureFresh()` below ends in `buildError = nil` on
            // success, which used to erase this before anything could render it.
            watcherError = started ? nil : Self.watcherUnavailableMessage
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
    ///
    /// Lifecycle ordering matters here. `isStopped = true` and
    /// `pendingVectorRefresh = false` are set BEFORE any cancel/await so that:
    /// (a) any stale FS-event-driven `Task { @MainActor }` already queued by
    ///     the watcher hits `scheduleEnsureFresh`'s `isStopped` gate and no-ops
    ///     instead of walking the folder and spawning a successor. That clause
    ///     used to name `startVectorBuild` — the LAST step of the path — while
    ///     its first step, the token walk, ran ungated;
    /// (b) the in-flight vector task's tail respawn check
    ///     (`if pendingVectorRefresh, !isStopped`) sees both flags false.
    /// The vector await is a drain LOOP rather than a single `if let` as
    /// belt-and-suspenders: a vector task that read its tail's flags BEFORE
    /// `stop()` set them, but hadn't yet hopped through the call to
    /// `startVectorBuild`, would still install a successor. The loop catches
    /// that successor and any further chain. Empirically the loop runs at
    /// most once after the fix; keeping it eliminates a regression class
    /// where someone re-introduces a flag-read-without-gate path.
    func stop() async {
        isStopped = true
        pendingVectorRefresh = false
        watcher?.stop()
        watcher = nil
        // The watcher is gone by intent now, so the "unavailable" warning no longer
        // describes anything the user can act on. `start()` re-decides it.
        watcherError = nil

        currentTokenBuildTask?.cancel()
        if let task = currentTokenBuildTask {
            _ = await task.value
        }
        currentTokenBuildTask = nil

        // `Task` is a struct, so `===` doesn't compile; `==` compares the
        // underlying task handle by identity. The check is required because
        // the awaited task itself never nils the slot — its tail may have
        // replaced it with a successor. Nil only when no successor attached.
        while let task = currentVectorBuildTask {
            task.cancel()
            _ = await task.value
            if currentVectorBuildTask == task {
                currentVectorBuildTask = nil
            }
        }
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
            buildError = "Failed to clear search index: \(tokenClearError)"
        } else if let vectorClearError {
            buildError = "Failed to clear vector index: \(vectorClearError)"
        } else {
            buildError = nil
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
        // The watcher is torn down by `stop()`, but a callback it already fired hops through
        // `Task { @MainActor in … }` and can land here afterwards. Without this the queued event
        // walks and re-persists a folder the coordinator has been told to leave — and installs
        // that walk in a slot `stop()`'s drain has already passed.
        guard !isStopped else { return }
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
        // Both callers are buttons whose `Task { await coordinator.rebuild() }` holds this
        // instance strongly, so a folder close between the tap and the resumption arrives here.
        guard !isStopped else { return }
        // Token phase: wait for any in-flight FS-event-driven walk, then
        // run our own. A user-initiated rebuild deserves the freshest walk.
        if let task = currentTokenBuildTask, !task.isCancelled {
            _ = await task.value
        }
        // Re-check: that await is a suspension `stop()` can run to completion inside.
        guard !isStopped else { return }
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
            buildError = persistError
        } else if let loadError {
            buildError = loadError
        } else if !warnings.isEmpty {
            buildError = "Index built with \(warnings.count) walk warning(s). "
                + "Some files may be missing from the index."
        } else {
            buildError = nil
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
        // Once `stop()` has fired, refuse to arm any new vector task — a
        // cancelled task's tail must not respawn a fresh successor.
        guard !isStopped else { return }
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
            // Suppressed once `stop()` has set the gate so a cancellation
            // handoff doesn't leak an uncancelled successor.
            if self.pendingVectorRefresh, !self.isStopped {
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
        // Same gate as `startVectorBuild`, for the same reason and at the more expensive door:
        // every batch here is a paid `/v1/embeddings` round trip, and the task is unstructured,
        // so one armed after `stop()`'s drain runs to completion with nothing able to stop it.
        guard !isStopped else { return }
        if let task = currentVectorBuildTask, !task.isCancelled {
            _ = await task.value
        }
        // Re-check: that await is a suspension `stop()` can run to completion inside.
        guard !isStopped else { return }
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
            Task { @MainActor [weak self] in
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

    #if DEBUG
    /// Test-only accessor: simulates an FS-event-driven vector refresh
    /// arriving while a build is in flight, without depending on watcher
    /// timing. Used by `testStop_disarmsPendingRespawn` to prove that
    /// `stop()` disarms the respawn even when the flag is set.
    func _testForcePendingVectorRefresh() {
        pendingVectorRefresh = true
    }

    /// Test-only accessor: lets stop-related tests assert the drain loop's
    /// post-condition (slot is nil) without exposing the task reference.
    var _testCurrentVectorBuildTaskIsNil: Bool {
        currentVectorBuildTask == nil
    }

    /// Test-only accessor: simulates a late FS-event-driven refresh request
    /// that races `stop()` — i.e. a `Task { @MainActor in scheduleEnsureFresh() }`
    /// queued by the watcher callback before `stop()` tore the watcher down,
    /// which then ran `performTokenBuild` and reached `requestVectorRefresh()`
    /// after `stop()` already returned. Used by `testStop_blocksLateRefreshRequest`.
    func _testRequestVectorRefresh() {
        requestVectorRefresh()
    }

    /// Test-only accessor: the HEAD of the very race the accessor above describes.
    /// `_testRequestVectorRefresh` simulates that queued task's *tail*; this one
    /// simulates the queued task itself finally running. Used by
    /// `SearchIndexCoordinatorStopGateTests`.
    func _testScheduleEnsureFresh() {
        scheduleEnsureFresh()
    }

    /// Test-only accessor: token-side companion to `_testCurrentVectorBuildTaskIsNil`.
    var _testCurrentTokenBuildTaskIsNil: Bool {
        currentTokenBuildTask == nil
    }
    #endif
}
