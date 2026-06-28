import XCTest

@testable import NanoTeams

/// Exercises the process-wide background-command registry: incremental reads
/// (single-lock offset advancement), and the lifecycle cleanup
/// (`terminate(taskID:)` / `terminateAll()`) that `stopEngine` / `stopAllEngines`
/// now invoke so detached commands + their log files don't leak.
final class BackgroundBashRegistryTests: XCTestCase {

    private var reg: BackgroundBashRegistry { .shared }
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        reg.terminateAll() // isolate from other suites sharing the singleton
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nanoteams-bgreg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        reg.terminateAll()
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        tmp = nil
        super.tearDown()
    }

    private func logURL(for id: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nanoteams-bg", isDirectory: true)
            .appendingPathComponent("\(id).log")
    }

    func testIncrementalRead_advancesOffsetAndReportsExit() throws {
        let id = try reg.start(
            command: "echo HELLO_BG", directory: tmp, sandboxProfile: nil, taskID: 7)

        // Awaiting a real detached subprocess inherently requires polling; the
        // budget is generous (≈10s) so a loaded CI host can't expire it for an
        // `echo` that completes in milliseconds.
        var combined = ""
        var finished = false
        var exit: Int32?
        for _ in 0..<200 {
            guard let r = reg.read(commandID: id) else { return XCTFail("entry vanished") }
            combined += r.newOutput
            if !r.running { finished = true; exit = r.exitCode; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(finished, "background command should finish")
        XCTAssertEqual(exit, 0)
        XCTAssertTrue(combined.contains("HELLO_BG"))
        // Offset advanced past EOF → a subsequent read returns no new bytes.
        XCTAssertEqual(reg.read(commandID: id)?.newOutput, "")
    }

    func testTerminate_removesEntryAndDeletesLog() throws {
        let id = try reg.start(
            command: "echo bye", directory: tmp, sandboxProfile: nil, taskID: 42)
        // Deterministic: terminate works whether or not the process has exited
        // (SIGTERM a still-running one; unlink the log either way), so no wait/poll.
        reg.terminate(taskID: 42)
        XCTAssertNil(reg.read(commandID: id), "terminate must forget the entry")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL(for: id).path),
                       "terminate must delete the command's log file")
    }

    func testTerminateAll_clearsEveryTask() throws {
        let a = try reg.start(command: "echo a", directory: tmp, sandboxProfile: nil, taskID: 1)
        let b = try reg.start(command: "echo b", directory: tmp, sandboxProfile: nil, taskID: 2)
        reg.terminateAll()
        XCTAssertNil(reg.read(commandID: a))
        XCTAssertNil(reg.read(commandID: b))
    }

    func testTerminate_unknownTaskID_isNoOp() {
        reg.terminate(taskID: 999_999) // must not crash
    }

    func testStop_unknownID_returnsFalse() {
        XCTAssertFalse(reg.stop(commandID: "bg_nope"))
    }

    // MARK: - Eviction policy (pure)

    private func entry(_ id: String, running: Bool, seq: Int, taskID: Int = 1)
        -> (id: String, running: Bool, seq: Int, taskID: Int) {
        (id: id, running: running, seq: seq, taskID: taskID)
    }

    func testOverflow_underCap_evictsNothing() {
        let e = [entry("a", running: false, seq: 1), entry("b", running: true, seq: 2)]
        XCTAssertEqual(BackgroundBashRegistry.overflowFinishedIDs(entries: e, cap: 2, taskID: 1), [])
        XCTAssertEqual(BackgroundBashRegistry.overflowFinishedIDs(entries: e, cap: 5, taskID: 1), [])
    }

    func testOverflow_evictsOldestFinishedFirst() {
        let e = [
            entry("old", running: false, seq: 1),
            entry("mid", running: false, seq: 2),
            entry("new", running: true, seq: 3),
        ]
        // cap 2, one over → drop the single oldest FINISHED ("old"), not "mid"/"new".
        XCTAssertEqual(BackgroundBashRegistry.overflowFinishedIDs(entries: e, cap: 2, taskID: 1), ["old"])
    }

    func testOverflow_sortsBySeqNotArrayPosition() {
        // seq deliberately OUT of array order — policy must evict by seq (oldest),
        // not by array index. Array order [b3, a1, c2]; oldest finished = a1.
        let e = [
            entry("b3", running: false, seq: 3),
            entry("a1", running: false, seq: 1),
            entry("c2", running: false, seq: 2),
        ]
        XCTAssertEqual(BackgroundBashRegistry.overflowFinishedIDs(entries: e, cap: 2, taskID: 1), ["a1"])
    }

    func testOverflow_neverEvictsRunning() {
        let e = [
            entry("r1", running: true, seq: 1),
            entry("r2", running: true, seq: 2),
            entry("r3", running: true, seq: 3),
        ]
        // Over cap but all running → nothing can be dropped.
        XCTAssertEqual(BackgroundBashRegistry.overflowFinishedIDs(entries: e, cap: 1, taskID: 1), [])
    }

    func testOverflow_dropsAllFinishedWhenStillOverCap() {
        let e = [
            entry("f1", running: false, seq: 1),
            entry("r1", running: true, seq: 2),
            entry("r2", running: true, seq: 3),
        ]
        // cap 1 → overflow 2, but only 1 finished → drop that one (best-effort).
        XCTAssertEqual(BackgroundBashRegistry.overflowFinishedIDs(entries: e, cap: 1, taskID: 1), ["f1"])
    }

    func testOverflow_isPerTask_neverEvictsAnotherTask() {
        // Task 2 is way over cap; evicting for task 1 must NOT touch task 2, and
        // task 1 (under its own cap) loses nothing.
        let e = [
            entry("t1a", running: false, seq: 1, taskID: 1),
            entry("t2a", running: false, seq: 2, taskID: 2),
            entry("t2b", running: false, seq: 3, taskID: 2),
            entry("t2c", running: false, seq: 4, taskID: 2),
        ]
        // Inserting for task 1 with cap 1: task 1 has only 1 entry → nothing evicted,
        // and task 2's entries are never candidates.
        XCTAssertEqual(BackgroundBashRegistry.overflowFinishedIDs(entries: e, cap: 1, taskID: 1), [])
        // Inserting for task 2 with cap 1: only task 2's oldest finished evicted.
        XCTAssertEqual(
            BackgroundBashRegistry.overflowFinishedIDs(entries: e, cap: 1, taskID: 2), ["t2a", "t2b"])
    }
}
