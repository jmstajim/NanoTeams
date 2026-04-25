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
