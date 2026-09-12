import XCTest
@testable import NanoTeams

final class FileSystemWatcherTests: XCTestCase {

    var tempDir: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - I5: start() reports success/failure

    /// I5 regression: `FileSystemWatcher.start()` must surface failure so the
    /// coordinator can show the user that their index won't auto-refresh
    /// instead of silently printing to the console.
    func testStart_withEmptyPaths_returnsFalse() {
        let watcher = FileSystemWatcher(paths: [], debounce: 0.2, onChange: {})
        XCTAssertFalse(watcher.start(),
                       "Empty paths → watcher cannot subscribe → start must return false.")
        XCTAssertFalse(watcher.isRunning,
                       "isRunning must reflect the failed start so callers can branch on it.")
    }

    func testStart_withValidPath_returnsTrueAndIsRunning() {
        let watcher = FileSystemWatcher(
            paths: [tempDir], debounce: 0.2, onChange: {}
        )
        XCTAssertTrue(watcher.start(),
                      "Valid path → start must report success.")
        XCTAssertTrue(watcher.isRunning)
        watcher.stop()
    }

    // MARK: - Callback fires on change

    func testWritingFile_triggersHandler() throws {
        let fired = expectation(description: "handler fires")
        fired.assertForOverFulfill = false
        let watcher = FileSystemWatcher(
            paths: [tempDir],
            debounce: 0.2,
            onChange: { fired.fulfill() }
        )
        watcher.start()
        // Give FSEvents a moment to subscribe before writing.
        Thread.sleep(forTimeInterval: 0.3)
        let file = tempDir.appendingPathComponent("touched.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        wait(for: [fired], timeout: 5.0)
        watcher.stop()
    }

    // MARK: - Debounce coalesces bursts

    func testBurstOfWrites_coalescesIntoSingleCallback() throws {
        let expectation = expectation(description: "handler fires once")
        expectation.assertForOverFulfill = false
        let counter = CounterBox()
        let watcher = FileSystemWatcher(
            paths: [tempDir],
            debounce: 0.4,
            onChange: {
                counter.increment()
                expectation.fulfill()
            }
        )
        watcher.start()
        Thread.sleep(forTimeInterval: 0.3)
        // Fire 20 writes in quick succession. The debounce should collapse
        // these to 1 (or very few) callbacks.
        for i in 0..<20 {
            let file = tempDir.appendingPathComponent("f\(i).txt")
            try "x".write(to: file, atomically: true, encoding: .utf8)
        }
        wait(for: [expectation], timeout: 5.0)
        // Give any trailing debounce a bit more time to confirm no extra calls.
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertLessThanOrEqual(counter.value, 3,
                                 "20 concurrent writes should collapse to ≤ 3 callbacks.")
        watcher.stop()
    }

    // MARK: - Stop suppresses further events

    func testStop_suppressesFurtherEvents() throws {
        let counter = CounterBox()
        let watcher = FileSystemWatcher(
            paths: [tempDir],
            debounce: 0.2,
            onChange: { counter.increment() }
        )
        watcher.start()
        Thread.sleep(forTimeInterval: 0.3)
        // Stop before making any changes.
        watcher.stop()
        // Drop a file — watcher should not fire.
        let file = tempDir.appendingPathComponent("after-stop.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(counter.value, 0,
                       "No callbacks should arrive after stop().")
    }

    // MARK: - Double-start is idempotent

    func testDoubleStart_isSafe() throws {
        let watcher = FileSystemWatcher(paths: [tempDir], debounce: 0.2, onChange: {})
        watcher.start()
        watcher.start()
        watcher.stop()
        // No assertion — just verifying no crash / leak on repeated start.
    }

    // MARK: - Excluded prefixes

    /// Writes whose paths ALL fall under an excluded prefix must be dropped
    /// before the debounce timer arms — this is what keeps tool-call logs
    /// under `.nanoteams/internal/runs/...` from triggering a signature
    /// probe every ~2 seconds during an active run.
    func testExcludedPrefix_writeInsideExcluded_doesNotFire() throws {
        let excluded = tempDir.appendingPathComponent("internal", isDirectory: true)
        try fm.createDirectory(at: excluded, withIntermediateDirectories: true)

        let counter = CounterBox()
        let watcher = FileSystemWatcher(
            paths: [tempDir],
            excludedPrefixes: [excluded],
            debounce: 0.2,
            onChange: { counter.increment() }
        )
        watcher.start()
        Thread.sleep(forTimeInterval: 0.3)
        // Only writes INSIDE the excluded prefix — handler must stay silent.
        let file = excluded.appendingPathComponent("noisy.log")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        // Wait past the FSEvents 1.0-s buffering window + debounce.
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertEqual(counter.value, 0,
                       "Events confined to an excluded prefix must not fire the handler.")
        watcher.stop()
    }

    func testExcludedPrefix_writeOutsideExcluded_stillFires() throws {
        let excluded = tempDir.appendingPathComponent("internal", isDirectory: true)
        try fm.createDirectory(at: excluded, withIntermediateDirectories: true)

        let fired = expectation(description: "handler fires for non-excluded path")
        fired.assertForOverFulfill = false
        let watcher = FileSystemWatcher(
            paths: [tempDir],
            excludedPrefixes: [excluded],
            debounce: 0.2,
            onChange: { fired.fulfill() }
        )
        watcher.start()
        Thread.sleep(forTimeInterval: 0.3)
        // Regression guard: configuring excludedPrefixes must not suppress
        // events for OTHER paths — only the excluded subtree is dropped.
        let file = tempDir.appendingPathComponent("outside.txt")
        try "y".write(to: file, atomically: true, encoding: .utf8)
        wait(for: [fired], timeout: 5.0)
        watcher.stop()
    }

    func testExcludedPrefix_mixedBatch_fires() throws {
        // A single FSEvents batch can include paths from multiple directories.
        // The filter must fire as long as ≥ 1 event is outside the excluded
        // subtree — it's a "drop only if ALL excluded" contract.
        let excluded = tempDir.appendingPathComponent("internal", isDirectory: true)
        try fm.createDirectory(at: excluded, withIntermediateDirectories: true)

        let fired = expectation(description: "handler fires for mixed batch")
        fired.assertForOverFulfill = false
        let watcher = FileSystemWatcher(
            paths: [tempDir],
            excludedPrefixes: [excluded],
            debounce: 0.2,
            onChange: { fired.fulfill() }
        )
        watcher.start()
        Thread.sleep(forTimeInterval: 0.3)
        // Write to both sides quickly so they land in the same batch.
        try "a".write(to: excluded.appendingPathComponent("a.log"),
                      atomically: true, encoding: .utf8)
        try "b".write(to: tempDir.appendingPathComponent("b.txt"),
                      atomically: true, encoding: .utf8)
        wait(for: [fired], timeout: 5.0)
        watcher.stop()
    }

    // MARK: - Д4: the watcher asks the walk's own question

    /// The watcher used to wake the index for anything outside `.nanoteams/internal/`, and the
    /// index walk then skipped most of it — so `git status` cost a full walk of the tree that
    /// found nothing, once per debounce window, and `xcodebuild` kept the indexer busy
    /// continuously.
    ///
    /// These are pure-predicate cases: no FSEvents, no timing, one question per line.
    ///
    /// RED: delete the component scan from `isInteresting` → the first four assertions fail.
    func testIsInteresting_pathsTheWalkSkips_areNotInteresting() {
        let root = FileSystemWatcher.WatchRoot(canonicalPath: "/w")
        func interesting(_ path: String) -> Bool {
            FileSystemWatcher.isInteresting(path: path, roots: [root], excludedPrefixes: [])
        }
        XCTAssertFalse(interesting("/w/.git/index"))
        XCTAssertFalse(interesting("/w/.git/refs/heads/main"))
        XCTAssertFalse(interesting("/w/node_modules/pkg/index.js"))
        XCTAssertFalse(interesting("/w/.artifacts/DerivedData-x/Build/x.o"))
        // The extension half of the rule, not just the name half.
        XCTAssertFalse(interesting("/w/latest.xcresult/Data/x.bin"))
        // And the ordinary source file that must always wake it.
        XCTAssertTrue(interesting("/w/NanoTeams/App/NanoTeamsApp.swift"))
        XCTAssertTrue(interesting("/w/README.md"))
    }

    /// The root's OWN ancestors are not ours to judge. A work folder living under
    /// `~/.cache/projects` or `/tmp/.build/wf` is a legitimate choice by the user, and judging
    /// the absolute path would make every event inside it uninteresting — the index would then
    /// never auto-refresh, with nothing logged.
    ///
    /// RED: scan the absolute path's components instead of the relative one → both fail.
    func testIsInteresting_skipNamesAboveTheRoot_areIgnored() {
        let root = FileSystemWatcher.WatchRoot(canonicalPath: "/Users/me/.cache/projects/wf")
        XCTAssertTrue(FileSystemWatcher.isInteresting(
            path: "/Users/me/.cache/projects/wf/main.swift",
            roots: [root], excludedPrefixes: []))
        XCTAssertFalse(FileSystemWatcher.isInteresting(
            path: "/Users/me/.cache/projects/wf/.git/HEAD",
            roots: [root], excludedPrefixes: []))
    }

    /// The excluded prefix still wins, and a path under no watched root is never dropped
    /// silently — FSEvents should not deliver one, and if it does we have no rule to judge it by.
    func testIsInteresting_excludedPrefixWins_andUnknownRootsAreKept() {
        let root = FileSystemWatcher.WatchRoot(canonicalPath: "/w")
        XCTAssertFalse(FileSystemWatcher.isInteresting(
            path: "/w/.nanoteams/internal/tasks/1/x.json",
            roots: [root], excludedPrefixes: ["/w/.nanoteams/internal"]))
        XCTAssertTrue(FileSystemWatcher.isInteresting(
            path: "/elsewhere/x.swift", roots: [root], excludedPrefixes: []))
    }

    /// `kFSEventStreamEventFlagMustScanSubDirs` means the kernel dropped events it could not
    /// queue, so the paths in this batch are not the whole story. Losing a change is worse
    /// than one wasted walk — it leaves the index quietly out of date with nothing logged.
    ///
    /// RED: judge a MustScanSubDirs event by its path like any other → a dropped-event batch
    /// inside `.git/` is ignored, and every edit that came with it never reaches the index.
    func testShouldWake_mustScanSubDirs_wakesWhateverThePathSays() {
        let root = FileSystemWatcher.WatchRoot(canonicalPath: "/w")
        XCTAssertTrue(FileSystemWatcher.shouldWake(
            [.init(path: "/w/.git/index", isDirectory: false, mustScanSubDirs: true)],
            roots: [root], excludedPrefixes: []))
        // …and even with no path at all, which is how FSEvents reports a pure overflow.
        XCTAssertTrue(FileSystemWatcher.shouldWake(
            [.init(path: nil, isDirectory: false, mustScanSubDirs: true)],
            roots: [root], excludedPrefixes: []))
    }

    /// The batch contract: drop only if EVERYTHING is uninteresting.
    func testShouldWake_dropsOnlyWhenEverythingIsUninteresting() {
        let root = FileSystemWatcher.WatchRoot(canonicalPath: "/w")
        func wake(_ events: [FileSystemWatcher.Event]) -> Bool {
            FileSystemWatcher.shouldWake(events, roots: [root], excludedPrefixes: [])
        }
        XCTAssertFalse(wake([
            .init(path: "/w/.git/index", isDirectory: false, mustScanSubDirs: false),
            .init(path: "/w/node_modules/x.js", isDirectory: false, mustScanSubDirs: false),
        ]))
        XCTAssertTrue(wake([
            .init(path: "/w/.git/index", isDirectory: false, mustScanSubDirs: false),
            .init(path: "/w/main.swift", isDirectory: false, mustScanSubDirs: false),
        ]))
        XCTAssertFalse(wake([]), "an empty batch is nothing to wake for")
    }

    /// A directory-level event is metadata noise: writing a file fires mtime events on every
    /// ancestor up to the watched root, whose paths carry none of the subtree's names.
    ///
    /// RED: judge directory events like files → every write inside `.git/` also reports the
    /// root itself, which is interesting, so the `.git` filter never drops anything.
    func testShouldWake_directoryEvents_doNotDecide() {
        let root = FileSystemWatcher.WatchRoot(canonicalPath: "/w")
        XCTAssertFalse(FileSystemWatcher.shouldWake(
            [.init(path: "/w", isDirectory: true, mustScanSubDirs: false),
             .init(path: "/w/.git", isDirectory: true, mustScanSubDirs: false)],
            roots: [root], excludedPrefixes: []))
    }

    /// FSEvents can deliver a null path. It is not a reason to drop the rest of the batch.
    func testShouldWake_nullPath_isSkippedNotFatal() {
        let root = FileSystemWatcher.WatchRoot(canonicalPath: "/w")
        XCTAssertTrue(FileSystemWatcher.shouldWake(
            [.init(path: nil, isDirectory: false, mustScanSubDirs: false),
             .init(path: "/w/main.swift", isDirectory: false, mustScanSubDirs: false)],
            roots: [root], excludedPrefixes: []))
    }

    /// A burst of writes confined to `.git/` must not wake the index at all.
    ///
    /// The integration half of the pin above: it proves the predicate is actually wired into
    /// the FSEvents callback and not merely available.
    ///
    /// RED: revert `handleCallback` to the `excludedPrefixes`-only filter → this fires.
    func testGitOnlyBurst_doesNotFire() throws {
        let git = tempDir.appendingPathComponent(".git", isDirectory: true)
        try fm.createDirectory(at: git, withIntermediateDirectories: true)

        let counter = CounterBox()
        let watcher = FileSystemWatcher(
            paths: [tempDir], debounce: 0.2, onChange: { counter.increment() })
        watcher.start()
        Thread.sleep(forTimeInterval: 0.3)
        for i in 0..<5 {
            try "x".write(to: git.appendingPathComponent("obj\(i)"),
                          atomically: true, encoding: .utf8)
        }
        // Past the FSEvents 1.0-s buffering window plus the debounce.
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertEqual(counter.value, 0,
                       "a burst confined to .git/ must not wake the index — the walk skips it")
        watcher.stop()
    }

    /// …but `.git/` alongside a real edit still fires. Same "drop only if ALL uninteresting"
    /// contract the excluded-prefix filter has always had.
    func testGitPlusSourceEdit_fires() throws {
        let git = tempDir.appendingPathComponent(".git", isDirectory: true)
        try fm.createDirectory(at: git, withIntermediateDirectories: true)

        let fired = expectation(description: "handler fires for the source edit")
        fired.assertForOverFulfill = false
        let watcher = FileSystemWatcher(
            paths: [tempDir], debounce: 0.2, onChange: { fired.fulfill() })
        watcher.start()
        Thread.sleep(forTimeInterval: 0.3)
        try "a".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "b".write(to: tempDir.appendingPathComponent("main.swift"),
                      atomically: true, encoding: .utf8)
        wait(for: [fired], timeout: 5.0)
        watcher.stop()
    }
}

// MARK: - Counter Helper

/// Thread-safe counter — FSEvents callbacks run off main.
private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}
