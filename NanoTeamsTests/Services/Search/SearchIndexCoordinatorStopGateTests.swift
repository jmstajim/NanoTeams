import XCTest

@testable import NanoTeams

/// `stop()`'s promise is that a torn-down coordinator does no further work against the folder it
/// is leaving. One of its four task-spawn sites kept that promise.
///
/// `startVectorBuild` carries `guard !isStopped else { return }` with a comment stating the rule
/// outright — "Once `stop()` has fired, refuse to arm any new vector task". The other three
/// (`scheduleEnsureFresh`, `runBuild`, `runSerializedVectorBuild`) had no gate, and the field doc
/// for `isStopped` records the narrowness as if it were the design: "Set by `stop()` to refuse new
/// **vector** tasks."
///
/// The gap is not theoretical, and the sibling suite's own accessor names it: the doc on
/// `_testRequestVectorRefresh` describes the race as "a `Task { @MainActor in scheduleEnsureFresh() }`
/// queued by the watcher callback before `stop()` tore the watcher down, which then ran
/// `performTokenBuild` and reached `requestVectorRefresh()` after `stop()` already returned". Every
/// step of that sentence is real; the gate only covered the last one. The queued task still ran a
/// full token walk of the closed folder and persisted `search_index.json` into it first.
///
/// Worst reachable form: `clear()` is `await stop()` then `await service.clear()`, and it is what
/// the "Exploratory Search" toggle calls when the user turns the feature OFF. A watcher event
/// queued moments earlier — an active run appending to a file, an IDE save-all — lands during
/// `clear()`'s suspensions, rebuilds, and persists. The user disabled the feature and the index
/// file reappears.
@MainActor
final class SearchIndexCoordinatorStopGateTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!
    let fm = FileManager.default

    /// Counts `embed` calls so "did a vector build actually run" is observable. The shared
    /// `StubSearchEmbeddingClient` returns vectors but records nothing.
    private final class CountingEmbeddingClient: EmbeddingClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        func embed(texts: [String], config _: EmbeddingConfig) async throws -> [[Float]] {
            lock.withLock { _calls += 1 }
            return texts.enumerated().map { (i, _) in [Float(i), 0, 0] }
        }
    }

    private var embedder: CountingEmbeddingClient!

    override func setUp() async throws {
        try await super.setUp()
        embedder = CountingEmbeddingClient()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        internalDir = tempDir.appendingPathComponent(".nanoteams/internal", isDirectory: true)
        try? fm.createDirectory(at: internalDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        internalDir = nil
        embedder = nil
        try await super.tearDown()
    }

    private var indexPath: String {
        internalDir.appendingPathComponent("search_index.json").path
    }

    private func write(_ relPath: String, _ content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeCoordinator() -> SearchIndexCoordinator {
        SearchIndexCoordinator(
            workFolderRoot: tempDir,
            internalDir: internalDir,
            embeddingClient: embedder,
            fileManager: fm,
            makeWatcher: FakeWatcherFactory.inert,
            watcherDebounce: 0.05
        )
    }

    /// Gives whatever a spawn site installed a chance to RUN, so a leak is observed rather than
    /// raced. Deliberately does not call `awaitIndex()`: that is a read API which builds on demand
    /// and would write the very file these tests assert is absent — a test artifact, not a
    /// production path (`applyExploratorySearchSettingChange` nils the coordinator on the line
    /// after `clear()`, so nothing can reach it afterwards).
    private func drain(_ c: SearchIndexCoordinator) async {
        for _ in 0..<100 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
            if c._testCurrentTokenBuildTaskIsNil, c._testCurrentVectorBuildTaskIsNil { break }
        }
    }

    /// The POSITIVE counterpart of `drain`. Draining is a give-up loop, which is the right shape
    /// for "nothing must have happened" — a short budget only ever makes those assertions weaker
    /// in the safe direction. It is the wrong shape for "this must have happened": under parallel
    /// load the ~500 ms budget is not always enough for a real walk plus a paid embedding batch,
    /// and the assertion then reads as a defect. Waits for the condition instead, with a budget
    /// wide enough that exhausting it means something is genuinely wrong.
    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        // 2000 × 5 ms ≈ 10 s.
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for: \(description)")
    }

    // MARK: - The token half

    /// The user-visible one: turning Exploratory Search off must leave the folder without an index.
    ///
    /// RED: drop `guard !isStopped` from `scheduleEnsureFresh` → the late watcher task runs
    /// `performTokenBuild(force: false)`, `loadOrBuild` finds nothing on disk, walks the folder and
    /// persists — so `search_index.json` is back moments after the user deleted it, in a folder the
    /// coordinator has been told to stop touching.
    func testStop_lateWatcherEventDoesNotResurrectTheClearedIndex() async throws {
        try write("A.swift", "class Alpha {}")
        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()
        XCTAssertTrue(
            fm.fileExists(atPath: indexPath),
            "precondition: the index was built and persisted, or the clear below proves nothing")

        await c.clear()
        XCTAssertFalse(
            fm.fileExists(atPath: indexPath), "precondition: clear() removed the index file")

        // The watcher callback's `Task { @MainActor in scheduleEnsureFresh() }`, queued before
        // `stop()` tore the watcher down, finally gets its turn.
        c._testScheduleEnsureFresh()
        await drain(c)

        XCTAssertFalse(
            fm.fileExists(atPath: indexPath),
            "a torn-down coordinator must not rebuild the index the user just cleared")
    }

    /// The mechanism behind it, asserted where the leak actually is: nothing may be ARMED, because
    /// `stop()` has already run its drain and will never run again for this instance. Anything
    /// installed after it is unowned and uncancellable for the rest of the process.
    ///
    /// RED: drop `guard !isStopped` from `scheduleEnsureFresh` → a token task is installed in a
    /// slot `stop()` nilled.
    func testStop_lateWatcherEventDoesNotArmATokenTask() async throws {
        try write("A.swift", "class Alpha {}")
        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()
        await c.stop()
        XCTAssertTrue(
            c._testCurrentTokenBuildTaskIsNil, "precondition: stop() drained the token slot")

        c._testScheduleEnsureFresh()

        XCTAssertTrue(
            c._testCurrentTokenBuildTaskIsNil,
            "a task armed after stop() returned has no owner left to cancel or await it")
    }

    /// The same gap through the other door. `rebuild()` is reachable from two buttons whose
    /// `Task { await coordinator.rebuild() }` holds the coordinator strongly, so a folder close
    /// between the tap and the resumption leaves this call running against the old folder.
    ///
    /// RED: drop `guard !isStopped` from `runBuild` → a full walk runs and re-persists.
    func testStop_rebuildAfterTeardownDoesNotWalkTheFolder() async throws {
        try write("A.swift", "class Alpha {}")
        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()
        await c.clear()
        XCTAssertFalse(fm.fileExists(atPath: indexPath), "precondition: cleared")

        await c.rebuild()

        XCTAssertFalse(
            fm.fileExists(atPath: indexPath),
            "the Rebuild button must not resurrect an index for a folder the app has left")
    }

    // MARK: - The vector half

    /// `startVectorBuild` is gated; `runSerializedVectorBuild` — which the two "Rebuild embeddings"
    /// entry points reach through `runVectorBuild` — is not. This is the expensive half: each batch
    /// is a paid `/v1/embeddings` round trip, and the task is unstructured, so nothing stops it.
    ///
    /// RED: drop `guard !isStopped` from `runSerializedVectorBuild` → the embedder is called after
    /// teardown.
    func testStop_rebuildEmbeddingsAfterTeardownDoesNotEmbed() async throws {
        try write("A.swift", "class Alpha { func beta() {} }")
        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()
        await c.stop()

        let before = embedder.calls
        await c.rebuildVectorIndexFull()
        await drain(c)

        XCTAssertEqual(
            embedder.calls, before,
            "a torn-down coordinator must not spend embedding calls on the folder it left")
    }

    // MARK: - Anti-vacuity

    /// Every assertion above passes for a coordinator that refuses to do anything at all. `start()`
    /// clears `isStopped`, so the same calls must work again after a restart — this is what makes
    /// the gate a lifecycle gate rather than a kill switch.
    ///
    /// RED: gate on something `start()` does not reset (e.g. a one-way `hasStopped` latch) → the
    /// index never comes back and the embedder is never called again.
    func testRestart_afterStop_buildsAndEmbedsAgain() async throws {
        try write("A.swift", "class Alpha { func beta() {} }")
        let c = makeCoordinator()
        await c.start()
        _ = await c.awaitIndex()
        await c.clear()
        XCTAssertFalse(fm.fileExists(atPath: indexPath), "precondition: cleared")

        await c.start()
        _ = await c.awaitIndex()
        XCTAssertTrue(
            fm.fileExists(atPath: indexPath), "start() must re-arm the pipeline it stopped")

        let before = embedder.calls
        await c.rebuildVectorIndexFull()
        await waitUntil("the restarted vector pipeline to embed") { embedder.calls > before }

        await c.stop()
    }
}
