import XCTest
@testable import NanoTeams

/// Behavioral tests for `SearchIndexCoordinator` — observable state and
/// lifecycle. Complements `SearchIndexServiceTests` (actor) and
/// `FileSystemWatcherTests` (FSEvents).
@MainActor
final class SearchIndexCoordinatorTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!
    let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        internalDir = nil
        super.tearDown()
    }

    private func write(_ relPath: String, content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeCoordinator() -> SearchIndexCoordinator {
        SearchIndexCoordinator(
            workFolderRoot: tempDir, internalDir: internalDir, fileManager: fm
        )
    }

    // MARK: - Initial state

    // `async` is load-bearing: sync test methods on a `@MainActor` class that
    // construct a `@MainActor` type in the body trip the Xcode 26.3 protocol-
    // witness abort (see CLAUDE.md "Common API pitfalls when writing tests").
    // `makeCoordinator()` allocates `SearchIndexCoordinator`, which is
    // `@MainActor`-isolated.
    func testInitial_allCountersNil() async {
        let c = makeCoordinator()
        XCTAssertFalse(c.isBuilding)
        XCTAssertNil(c.tokenCount)
        XCTAssertNil(c.fileCount)
        XCTAssertNil(c.lastBuiltAt)
        XCTAssertNil(c.lastError)
    }

    // MARK: - start() populates counters

    func testStart_populatesObservableCounters() async throws {
        try write("A.swift", content: "class ScrollView {}")
        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()
        XCTAssertNotNil(c.tokenCount)
        XCTAssertGreaterThan(c.tokenCount ?? 0, 0)
        XCTAssertEqual(c.fileCount, 1)
        XCTAssertNotNil(c.lastBuiltAt)
        XCTAssertFalse(c.isBuilding,
                       "After await, build must be complete → isBuilding == false")
        await c.stop()
    }

    // MARK: - stop() is safe before start()

    func testStop_beforeStart_isSafe() async {
        let c = makeCoordinator()
        await c.stop()
        XCTAssertFalse(c.isBuilding)
    }

    // MARK: - Double-start is safe

    func testDoubleStart_isSafe() async throws {
        try write("A.swift", content: "class Foo {}")
        let c = makeCoordinator()
        await c.start()
        await c.start()
        _ = await c.awaitIndex()
        XCTAssertEqual(c.fileCount, 1)
        await c.stop()
    }

    // MARK: - Rebuild after folder change

    func testRebuild_picksUpNewFile() async throws {
        try write("A.swift", content: "alpha")
        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()
        XCTAssertEqual(c.fileCount, 1)

        try write("B.swift", content: "beta")
        await c.rebuild()
        _ = await c.awaitIndex()
        XCTAssertEqual(c.fileCount, 2)
        await c.stop()
    }

    // MARK: - Clear resets observable state

    func testClear_resetsAllCounters() async throws {
        try write("A.swift", content: "alpha")
        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()
        XCTAssertEqual(c.fileCount, 1)

        await c.clear()
        XCTAssertNil(c.fileCount)
        XCTAssertNil(c.tokenCount)
        XCTAssertNil(c.lastBuiltAt)
        XCTAssertFalse(c.isBuilding)

        let indexFile = internalDir.appendingPathComponent("search_index.json")
        XCTAssertFalse(fm.fileExists(atPath: indexFile.path),
                       "clear() must delete the on-disk index")
    }

    // MARK: - awaitIndex when no build ran

    func testAwaitIndex_coldStart_triggersInitialBuild() async throws {
        try write("A.swift", content: "gamma")
        let c = makeCoordinator()
        // No start() — just await.
        let idx = await c.awaitIndex()
        XCTAssertNotNil(idx)
        XCTAssertEqual(idx?.files.count, 1)
        await c.stop()
    }

    // MARK: - Signature-based fast path

    func testReopen_signatureMatches_reusesCacheWithoutRebuild() async throws {
        try write("A.swift", content: "alpha")
        let c = makeCoordinator()
        await c.start()
        let first = await c.awaitIndex()
        await c.stop()

        // Same folder, fresh coordinator — should reuse on-disk file.
        let c2 = makeCoordinator()
        await c2.start()
        let second = await c2.awaitIndex()
        XCTAssertEqual(first?.generatedAt, second?.generatedAt,
                       "Signature match → cache reused (same generatedAt).")
        await c2.stop()
    }

    func testReopen_folderMutated_rebuildsOnEnsureFresh() async throws {
        try write("A.swift", content: "alpha")
        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()
        await c.stop()

        // Mutate the folder (add a file) so the signature differs.
        try write("B.swift", content: "beta")

        let c2 = makeCoordinator()
        await c2.start()
        let rebuilt = await c2.awaitIndex()
        XCTAssertEqual(rebuilt?.files.count, 2,
                       "Folder drift must trigger rebuild on start()/ensureFresh.")
        await c2.stop()
    }

    // MARK: - Regression: FS-watcher-path must not self-deadlock
    //
    // `scheduleEnsureFresh` sets `currentBuildTask` to the Task that will
    // invoke the build. A previous revision routed through `runBuild`, which
    // awaited `currentBuildTask.value` — the Task was awaiting itself, a
    // hard deadlock that would hang every indexing update after the first
    // folder change. Simulate the FS-watcher path via repeated rebuilds
    // and ensure each one actually completes within the timeout.

    func testRapidRebuilds_completeWithoutDeadlock() async throws {
        try write("A.swift", content: "alpha")
        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()

        // Fire multiple rebuilds in quick succession. Each must complete;
        // if any self-awaits we'd time out the test.
        for _ in 0..<5 {
            await c.rebuild()
        }
        // After all builds finish, the counter observable must be populated.
        XCTAssertEqual(c.fileCount, 1)
        XCTAssertFalse(c.isBuilding)
        await c.stop()
    }

    func testConcurrentEnsureFresh_andAwaitIndex_doNotDeadlock() async throws {
        try write("A.swift", content: "alpha")
        let c = makeCoordinator()
        await c.start()

        // Dispatch concurrent ensureFresh + awaitIndex calls. If the
        // coalescing logic routed through `runBuild` on a self-referential
        // task handle, this would hang indefinitely.
        async let a: Void = c.ensureFresh()
        async let b: Void = c.ensureFresh()
        async let idx = c.awaitIndex()
        _ = await (a, b)
        let built = await idx
        XCTAssertEqual(built?.files.count, 1)
        await c.stop()
    }

    // MARK: - L1-L4: Vector-index lifecycle (mock-embed)

    /// Coordinator with a recording mock embedder — used by L/C_R tests that
    /// need to drive the vector-index path end-to-end without a live
    /// LM Studio.
    private func makeCoordinatorWithMockEmbedder(
        _ client: any EmbeddingClient,
        modelName: String = "test-model"
    ) -> SearchIndexCoordinator {
        SearchIndexCoordinator(
            workFolderRoot: tempDir,
            internalDir: internalDir,
            embeddingConfigProvider: {
                EmbeddingConfig(
                    baseURLString: "http://x",
                    modelName: modelName,
                    batchSize: 4,
                    requestTimeout: 5
                )
            },
            embeddingClient: client,
            fileManager: fm
        )
    }

    func testVectorLifecycle_enable_buildsVectorsToDisk() async throws {
        // L1: feature enabled + token index built → vector index also builds
        // and lands on disk (bin + meta).
        // Two files with overlapping tokens so each token has posting-count
        // ≥ 2 and survives `VocabFilter.default.minPostingCount`.
        try write("A.swift", content: "class ScrollView { func makeScroll() {} }")
        try write("B.swift", content: "class ScrollView { func renderScroll() {} }")
        let client = RecordingEmbedClient()
        let c = makeCoordinatorWithMockEmbedder(client)
        await c.start()
        _ = await c.awaitIndex()

        // Vector index build runs inside the same performBuild — give it
        // a moment by polling `isBuildingVectorIndex`.
        await waitUntilVectorReady(c, timeoutSeconds: 2.0)

        // Bin + meta on disk.
        let bin = internalDir.appendingPathComponent("vocab_vectors.bin").path
        let meta = internalDir.appendingPathComponent("vocab_vectors.meta.json").path
        XCTAssertTrue(fm.fileExists(atPath: bin))
        XCTAssertTrue(fm.fileExists(atPath: meta))

        // State = .ready with non-zero count.
        guard case .ready(_, _, let count) = c.vectorIndexState else {
            XCTFail("Expected .ready, got \(c.vectorIndexState)"); return
        }
        XCTAssertGreaterThan(count, 0,
            "Building on a non-empty corpus must produce vectors")
        XCTAssertGreaterThan(client.callCount, 0)
        await c.stop()
    }

    func testVectorLifecycle_clear_removesVectorFilesFromDisk() async throws {
        // L2: `clear()` removes BOTH token and vector files. This is what
        // `onExpandedSearchSettingChanged(false)` ultimately does.
        try write("A.swift", content: "class ScrollView {}")
        try write("B.swift", content: "class ScrollView {}")
        let c = makeCoordinatorWithMockEmbedder(RecordingEmbedClient())
        await c.start()
        await waitUntilVectorReady(c, timeoutSeconds: 2.0)

        let bin = internalDir.appendingPathComponent("vocab_vectors.bin").path
        let meta = internalDir.appendingPathComponent("vocab_vectors.meta.json").path
        XCTAssertTrue(fm.fileExists(atPath: bin))

        await c.clear()

        XCTAssertFalse(fm.fileExists(atPath: bin),
            "clear() must delete vocab_vectors.bin")
        XCTAssertFalse(fm.fileExists(atPath: meta),
            "clear() must delete vocab_vectors.meta.json")
        XCTAssertEqual(c.vectorIndexState, .missing)
    }

    func testVectorLifecycle_rebuildAfterClear_isFullBuild() async throws {
        // L3: off → on cycle rebuilds from scratch. After clear, a fresh
        // coordinator must embed the vocab again.
        try write("A.swift", content: "class ScrollView {}")
        try write("B.swift", content: "class ScrollView {}")
        let client1 = RecordingEmbedClient()
        let c1 = makeCoordinatorWithMockEmbedder(client1)
        await c1.start()
        await waitUntilVectorReady(c1, timeoutSeconds: 2.0)
        let firstBuildCalls = client1.callCount
        XCTAssertGreaterThan(firstBuildCalls, 0)
        await c1.clear()

        // Fresh coordinator (simulates off → on toggle).
        let client2 = RecordingEmbedClient()
        let c2 = makeCoordinatorWithMockEmbedder(client2)
        await c2.start()
        await waitUntilVectorReady(c2, timeoutSeconds: 2.0)

        XCTAssertGreaterThan(client2.callCount, 0,
            "Fresh coordinator post-clear must re-embed from scratch")
        await c2.stop()
    }

    func testVectorLifecycle_reopen_reusesDiskIndex() async throws {
        // L4: coordinator stops (folder close) but bin+meta stay. Second
        // coordinator reads them via load() — no new embed calls.
        try write("A.swift", content: "class ScrollView {}")
        try write("B.swift", content: "class ScrollView {}")
        let client1 = RecordingEmbedClient()
        let c1 = makeCoordinatorWithMockEmbedder(client1)
        await c1.start()
        await waitUntilVectorReady(c1, timeoutSeconds: 2.0)
        let firstBuildCalls = client1.callCount
        await c1.stop()

        // Second coordinator — same tempDir, same internalDir, files still
        // on disk. `start()` calls `vectorIndex.load()` first, then
        // `ensureFresh` → diff finds empty delta → zero embed calls.
        let client2 = RecordingEmbedClient()
        let c2 = makeCoordinatorWithMockEmbedder(client2)
        await c2.start()
        await waitUntilVectorReady(c2, timeoutSeconds: 2.0)

        XCTAssertEqual(client2.callCount, 0,
            "Reopening a folder with on-disk vectors must not re-embed")
        guard case .ready(_, _, let count) = c2.vectorIndexState else {
            XCTFail("Expected .ready from disk, got \(c2.vectorIndexState)"); return
        }
        XCTAssertGreaterThan(count, 0)
        await c2.stop()
        _ = firstBuildCalls
    }

    // MARK: - C_R1-C_R3: Vector-index concurrency

    func testRebuildVectorIndex_concurrent_serializesThroughTask() async throws {
        // C_R1: two concurrent rebuildVectorIndex() calls must serialize.
        // After the first build the vocab is covered — the second call sees
        // an empty diff (no new tokens) and makes ZERO embed calls.
        try write("A.swift", content: "class ScrollView {}")
        try write("B.swift", content: "class ScrollView {}")
        let client = RecordingEmbedClient()
        let c = makeCoordinatorWithMockEmbedder(client)
        await c.start()
        await waitUntilVectorReady(c, timeoutSeconds: 2.0)
        let warmCalls = client.callCount

        async let a: Void = c.rebuildVectorIndex()
        async let b: Void = c.rebuildVectorIndex()
        _ = await (a, b)

        // Serialized: both awaited the same underlying task's result via
        // `currentVectorBuildTask`. Second call saw empty diff.
        XCTAssertEqual(client.callCount, warmCalls,
            "Concurrent rebuilds must not double-embed — serializer + smart-diff")
        XCTAssertFalse(c.isBuildingVectorIndex,
            "Both builds must have finished cleanly")
        await c.stop()
    }

    func testStop_duringVectorBuild_awaitsInFlightTask() async throws {
        // C_R3: stop() cancels the in-flight vector task and awaits its
        // exit. After stop() returns, `isBuildingVectorIndex` must be false
        // and no additional progress events fire.
        try write("A.swift", content: "alpha beta gamma delta epsilon")
        try write("B.swift", content: "alpha zeta eta theta iota")
        let client = SlowRecordingEmbedClient()
        client.delayNanos = 100_000_000  // 100ms per batch
        let c = makeCoordinatorWithMockEmbedder(client)

        let startTask = Task { await c.start() }
        // Wait until vector-build is underway, then stop.
        try await Task.sleep(nanoseconds: 50_000_000)
        await c.stop()
        await startTask.value

        XCTAssertFalse(c.isBuildingVectorIndex,
            "stop() must leave isBuildingVectorIndex=false")
    }

    // MARK: - Regression: start() must return promptly (non-blocking on build)

    /// User bug: "выключение не останавливает индексацию". If `start()`
    /// awaited the initial `ensureFresh()` through to completion, the
    /// orchestrator's serial toggle chain would queue OFF behind a multi-
    /// minute embedding pass. `start()` must now schedule the build as a
    /// detached Task and return in milliseconds so toggle OFF can reach
    /// `stop()` and cancel the in-flight build.
    func testStart_returnsBeforeVectorBuildCompletes() async throws {
        try write("A.swift", content: "class ScrollView { func makeScrollView() {} }")
        try write("B.swift", content: "class ScrollView { func renderScroll() {} }")
        let client = SlowRecordingEmbedClient()
        client.delayNanos = 300_000_000  // 300ms per batch — long enough to dominate start()

        let c = makeCoordinatorWithMockEmbedder(client)

        let started = Date()
        await c.start()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.25,
            "start() must return before the first embed batch finishes (\(elapsed)s).")
        // Build might not even have reached the vector phase yet — that's the
        // whole point. Drain by cancelling to release the slow client.
        await c.stop()
    }

    /// Companion regression: after `start()` returns, the build is still in
    /// flight and `isBuilding` / `isBuildingVectorIndex` eventually flip on.
    /// Without this guarantee the UI would never see "indexing in progress"
    /// because start() returned before the build even started.
    func testStart_returnsQuickly_butBuildStillRunsInBackground() async throws {
        try write("A.swift", content: "class ScrollView { func makeScrollView() {} }")
        try write("B.swift", content: "class ScrollView { func renderScroll() {} }")
        let client = SlowRecordingEmbedClient()
        client.delayNanos = 100_000_000

        let c = makeCoordinatorWithMockEmbedder(client)
        await c.start()

        // Poll up to 1s for the build to actually have started (either token
        // flag or vector flag should flip true at some point).
        var observedBuilding = false
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if c.isBuilding || c.isBuildingVectorIndex {
                observedBuilding = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(observedBuilding,
            "Background build must be observable via isBuilding/isBuildingVectorIndex after start() returns.")

        await c.stop()
    }

    /// User bug: toggle OFF mid-build must cancel the build and settle all
    /// observable flags off within a reasonable window — users click OFF
    /// and expect indexing to stop immediately, not finish first.
    func testStop_duringBuild_settlesFlagsOffPromptly() async throws {
        try write("A.swift", content: "alpha beta gamma delta")
        try write("B.swift", content: "alpha epsilon zeta eta")
        let client = SlowRecordingEmbedClient()
        client.delayNanos = 200_000_000
        let c = makeCoordinatorWithMockEmbedder(client)

        await c.start()
        // Let the build actually enter its embed loop.
        try await Task.sleep(nanoseconds: 80_000_000)

        let stopStart = Date()
        await c.stop()
        let stopElapsed = Date().timeIntervalSince(stopStart)

        XCTAssertLessThan(stopElapsed, 1.0,
            "stop() must interrupt the build — not wait for all embed batches (\(stopElapsed)s).")
        XCTAssertFalse(c.isBuilding,
            "Token-build flag must be off after stop().")
        XCTAssertFalse(c.isBuildingVectorIndex,
            "Vector-build flag must be off after stop().")
    }

    /// Helper: poll `vectorIndexState` until `.ready` or timeout. Used by
    /// lifecycle tests where the build completes asynchronously inside
    /// `start()`.
    private func waitUntilVectorReady(
        _ c: SearchIndexCoordinator, timeoutSeconds: Double
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if case .ready = c.vectorIndexState { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

// MARK: - File-private mock embed clients

/// Deterministic embedding client that records calls. Returns one 3-dim
/// vector per input, encoding the call index so tests can tell calls apart.
private final class RecordingEmbedClient: EmbeddingClient, @unchecked Sendable {
    private let lock = NSLock()
    var callCount = 0

    func embed(texts: [String], config: EmbeddingConfig) async throws -> [[Float]] {
        lock.lock()
        let idx = callCount
        callCount += 1
        lock.unlock()
        return texts.enumerated().map { (i, _) in
            [Float(idx) + Float(i) * 0.01, 0, 0]
        }
    }
}

/// Variant that sleeps before returning so a concurrent `stop()` /
/// `Task.cancel()` has time to fire.
private final class SlowRecordingEmbedClient: EmbeddingClient, @unchecked Sendable {
    private let lock = NSLock()
    var callCount = 0
    var delayNanos: UInt64 = 0

    func embed(texts: [String], config: EmbeddingConfig) async throws -> [[Float]] {
        lock.lock()
        callCount += 1
        let delay = delayNanos
        lock.unlock()
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        try Task.checkCancellation()
        return texts.map { _ in [1, 0, 0] }
    }
}
