import XCTest

@testable import NanoTeams

/// The FS-watcher half of `SearchIndexCoordinator`, which had no test at all because the
/// coordinator built its own `FileSystemWatcher` inline: the watcher-death arm was
/// unreachable (the real watcher only fails on an empty path list, which the coordinator
/// never passes, or on a kernel-level `FSEventStreamCreate` failure, which cannot be induced),
/// and ~20 sibling tests each opened a real FSEvents stream on a temp directory to get past it.
///
/// The `makeWatcher` seam closes both. What it exposed on the first assertion is the reason
/// this file exists: the "watcher unavailable" message was being erased by the very build
/// `start()` schedules right after writing it.
@MainActor
final class SearchIndexCoordinatorWatcherSeamTests: XCTestCase {

    var tempDir: URL!
    var internalDir: URL!
    let fm = FileManager.default

    override func setUp() async throws {
        try await super.setUp()
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
        try await super.tearDown()
    }

    private func write(_ relPath: String, _ content: String) throws {
        let url = tempDir.appendingPathComponent(relPath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeCoordinator(watcher: @escaping FileSystemWatcherFactory) -> SearchIndexCoordinator {
        SearchIndexCoordinator(
            workFolderRoot: tempDir,
            internalDir: internalDir,
            embeddingClient: StubSearchEmbeddingClient(),
            fileManager: fm,
            makeWatcher: watcher,
            watcherDebounce: 0.05
        )
    }

    // MARK: - The defect the seam exposed

    /// A dead watcher means the index silently stops auto-refreshing: it is built once and then
    /// never again until the user presses Rebuild. Nothing else in the app notices, so the
    /// message `start()` writes is the entire signal.
    ///
    /// It did not survive. `start()` wrote `lastError`, then scheduled the initial
    /// `ensureFresh()`, whose success arm ends in `lastError = nil` — so on any folder where the
    /// index builds cleanly (i.e. all of them) the warning was erased milliseconds later, before
    /// a render could observe it. The one case where it DID survive was a folder whose build also
    /// failed, which is precisely the case where the watcher warning is the less useful message.
    ///
    /// `await awaitIndex()` is what makes this test see the bug rather than race it: it returns
    /// only after `performTokenBuild` has run its clearing arm.
    ///
    /// RED: fold `watcherError` back into `buildError` (i.e. have `start()` write `buildError`) →
    /// the initial build clears it and `lastError` is nil here.
    func testWatcherRefusesToStart_messageSurvivesTheInitialBuild() async throws {
        try write("A.swift", "class Alpha {}")
        let c = makeCoordinator(watcher: FakeWatcherFactory.failing)

        await c.start()
        _ = await c.awaitIndex()

        XCTAssertNotNil(c.tokenCount,
                        "precondition: the index still builds when the watcher is dead — "
                            + "if this is nil the test proves nothing about surviving a build")
        XCTAssertEqual(c.watcherError, SearchIndexCoordinator.watcherUnavailableMessage)
        XCTAssertEqual(c.lastError, SearchIndexCoordinator.watcherUnavailableMessage,
                       "the card reads lastError; a warning that never reaches it is not a warning")

        await c.stop()
    }

    /// The anti-vacuum companion: with a healthy watcher the same sequence must leave the card
    /// clean, or the assertion above would pass for a coordinator that always complains.
    ///
    /// RED: make `start()` write the message unconditionally (drop the `started ?` ternary) →
    /// this fails while the test above still passes.
    func testWatcherStarts_leavesNoError() async throws {
        try write("A.swift", "class Alpha {}")
        let c = makeCoordinator(watcher: FakeWatcherFactory.inert)

        await c.start()
        _ = await c.awaitIndex()

        XCTAssertNil(c.watcherError)
        XCTAssertNil(c.lastError)

        await c.stop()
    }

    /// The two conditions are independent, so both must reach the card. Before the split they
    /// shared one slot and the later writer won — which, given the ordering, was always the build.
    ///
    /// A walk warning is the realistic build-side companion: an unreadable subdirectory leaves
    /// whole subtrees out of the index, and "some files are missing" plus "and it won't refresh"
    /// are different things to do something about.
    ///
    /// RED: return only `buildError` (or only `watcherError`) from `lastError` → one half of the
    /// message disappears.
    func testBuildWarningAndWatcherDeath_bothReachTheCard() async throws {
        try write("A.swift", "class Alpha {}")
        let blocked = tempDir.appendingPathComponent("blocked", isDirectory: true)
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        try write("blocked/B.swift", "class Beta {}")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }

        let c = makeCoordinator(watcher: FakeWatcherFactory.failing)
        await c.start()
        _ = await c.awaitIndex()

        guard let buildError = c.buildError else {
            // The walk warning is the fixture, not the subject. If the platform stops reporting
            // it the coordinator has nothing to compose, and asserting on a one-part message
            // would silently stop testing composition.
            throw XCTSkip("no walk warning produced — cannot exercise the two-condition case")
        }
        let shown = try XCTUnwrap(c.lastError)
        XCTAssertTrue(shown.contains(buildError), "build diagnostics must survive; got \(shown)")
        XCTAssertTrue(shown.contains(SearchIndexCoordinator.watcherUnavailableMessage),
                      "watcher death must survive alongside it; got \(shown)")

        await c.stop()
    }

    /// `stop()` retires the warning: after a deliberate teardown there is no watcher by design,
    /// and telling the user to press Rebuild for a coordinator that is no longer running is noise.
    ///
    /// RED: drop `watcherError = nil` from `stop()` → the message outlives the coordinator that
    /// produced it and a later `start()` on a healthy watcher cannot clear it either, because the
    /// `if watcher == nil` guard is the only writer.
    func testStop_retiresTheWatcherWarning() async throws {
        try write("A.swift", "class Alpha {}")
        let c = makeCoordinator(watcher: FakeWatcherFactory.failing)
        await c.start()
        _ = await c.awaitIndex()
        XCTAssertNotNil(c.watcherError, "precondition: the warning was raised")

        await c.stop()

        XCTAssertNil(c.watcherError)
        XCTAssertNil(c.lastError)
    }

    // MARK: - What the coordinator asks of its watcher

    /// The exclusion is load-bearing, not decoration: `.nanoteams/internal/` receives an append
    /// to `tool_calls.jsonl` and `network_log.json` on every single tool call of an active run,
    /// and those paths are already outside the index walk — so without the exclusion each one
    /// arms the debounce timer and pays a full signature probe that can only conclude "nothing
    /// changed". Nothing asserted this before, because the argument went straight into a real
    /// FSEventStream where it was unobservable.
    ///
    /// RED: drop `[internalDir]` from the `makeWatcher(...)` call → the exclusion assertion fails.
    func testStart_handsTheWatcherTheWorkFolderAndExcludesTheInternalDir() async throws {
        let (factory, built) = FakeWatcherFactory.recording()
        let c = makeCoordinator(watcher: factory)

        await c.start()
        _ = await c.awaitIndex()

        let watchers = built()
        XCTAssertEqual(watchers.count, 1, "start() installs exactly one watcher")
        let w = try XCTUnwrap(watchers.first)
        XCTAssertEqual(w.paths, [tempDir])
        XCTAssertEqual(w.excludedPrefixes, [internalDir],
                       "every tool-call log write would otherwise trigger a signature probe")
        XCTAssertEqual(w.debounce, 0.05, accuracy: 0.0001,
                       "the injected debounce must reach the watcher, not just be stored")
        XCTAssertEqual(w.startCount, 1)

        await c.stop()
        XCTAssertEqual(w.stopCount, 1, "stop() must tear down the stream it opened")
    }

    /// `start()` is documented as safe to call repeatedly, and the `if watcher == nil` guard is
    /// what makes that true. A second stream on the same folder would double every event.
    ///
    /// RED: remove the `if watcher == nil` guard → two watchers are built and the first is
    /// dropped without `stop()`, orphaning its stream.
    func testDoubleStart_installsOnlyOneWatcher() async throws {
        let (factory, built) = FakeWatcherFactory.recording()
        let c = makeCoordinator(watcher: factory)

        await c.start()
        await c.start()
        _ = await c.awaitIndex()

        XCTAssertEqual(built().count, 1)
        await c.stop()
    }

    /// The watcher's whole purpose — a folder change reaches `scheduleEnsureFresh()` — driven
    /// deterministically instead of by writing a file and hoping FSEvents notices inside the
    /// debounce window. That timing dependency is why the path was previously only "simulated"
    /// via direct `rebuild()` calls in the sibling suite.
    ///
    /// RED: change the coordinator's `onChange` closure to do nothing → `fileCount` stays 1.
    func testWatcherChangeCallback_refreshesTheIndex() async throws {
        try write("A.swift", "class Alpha {}")
        let (factory, built) = FakeWatcherFactory.recording()
        let c = makeCoordinator(watcher: factory)

        await c.start()
        _ = await c.awaitIndex()
        XCTAssertEqual(c.fileCount, 1)

        try write("B.swift", "class Beta {}")
        try XCTUnwrap(built().first).fireChange()

        // `onChange` hops through `Task { @MainActor in … }`, so the refresh is QUEUED, not
        // installed — awaiting immediately would join the previous (already finished) build and
        // read the stale count. Poll until the queued task has landed and completed.
        for _ in 0..<200 where c.fileCount != 2 {
            await Task.yield()
            _ = await c.awaitIndex()
            if c.fileCount == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(c.fileCount, 2,
                       "a watcher event must drive a refresh — the coordinator's only reason to "
                           + "hold a watcher at all")
        await c.stop()
    }

    // MARK: - Production really gets the live watcher

    /// Anti-vacuity for every test above: they all inject a double, so nothing would notice if
    /// `FileSystemWatcher.live` were quietly replaced by an inert stub and the app stopped
    /// watching anything. Asserts the factory production passes builds the real class.
    ///
    /// This is the one place in the suite that opens a real FSEvents stream, and it stops it
    /// immediately.
    ///
    /// RED: point `FileSystemWatcher.live` at `FakeFileSystemWatcher` → the type check fails.
    func testLiveFactory_buildsARealFileSystemWatcher() {
        let w = FileSystemWatcher.live([tempDir], [internalDir], 0.05, {})
        XCTAssertTrue(w is FileSystemWatcher,
                      "production's factory must build the real watcher, not a stand-in")
        XCTAssertTrue(w.start(), "a real watcher on an existing directory subscribes")
        w.stop()
    }
}
