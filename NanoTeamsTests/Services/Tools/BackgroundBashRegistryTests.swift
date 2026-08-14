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

    // MARK: - Incremental UTF-8 decoding

    /// A read against a still-writing process lands wherever the process happened to flush,
    /// which for any non-ASCII output is routinely the MIDDLE of a character. The old code
    /// did `String(data:encoding:.utf8) ?? ""` and then advanced the offset by `data.count`
    /// regardless, so one straddling character nilled the decode of the whole accumulated
    /// chunk, `""` was reported as the new output, and the offset moved past bytes nobody had
    /// ever seen. Unrecoverable, and invisible: `{newOutput: "", running: true}` is exactly
    /// what "nothing new yet" looks like.
    ///
    /// `Привет` is two bytes per character, so cutting one byte short of the end splits the
    /// final `т`.
    ///
    /// RED: return `(String(data: data, encoding: .utf8) ?? "", data.count)` → text is empty
    /// and consumed is 11, i.e. the whole prefix is reported as nothing and then skipped.
    func testDecodeIncremental_splitCharacter_holdsTheTailInsteadOfDroppingTheChunk() {
        let full = Array("Привет".utf8)
        XCTAssertEqual(full.count, 12, "precondition: two bytes per Cyrillic character")
        let firstRead = Data(full.prefix(11))   // one byte short of the final `т`

        let (text, consumed) = BackgroundBashRegistry.decodeIncremental(
            firstRead, moreBytesExpected: true)

        XCTAssertEqual(text, "Приве", "everything decodable must be reported")
        XCTAssertEqual(consumed, 10, "the straddling lead byte must stay pending")

        // The next read resumes at the unconsumed byte and completes the character.
        let secondRead = Data(full.suffix(from: consumed))
        let (rest, restConsumed) = BackgroundBashRegistry.decodeIncremental(
            secondRead, moreBytesExpected: false)
        XCTAssertEqual(rest, "т")
        XCTAssertEqual(restConsumed, 2)
        XCTAssertEqual(text + rest, "Привет", "no byte may be lost across the boundary")
    }

    /// A chunk that is ENTIRELY one partial character consumes nothing, so the next read sees
    /// the same offset and finds it completed. Returning `("", 3)` here would be the original
    /// bug in miniature.
    ///
    /// RED: same mutation as above → consumed is 3 and the character is gone.
    func testDecodeIncremental_wholeChunkIsOnePartialCharacter_consumesNothing() {
        let bytes = Array("😀".utf8)          // 4 bytes
        let (text, consumed) = BackgroundBashRegistry.decodeIncremental(
            Data(bytes.prefix(3)), moreBytesExpected: true)

        XCTAssertEqual(text, "")
        XCTAssertEqual(consumed, 0, "nothing decodable, so nothing may be skipped")
    }

    /// The counterweight to holding a partial tail: once the process has exited there is no
    /// later read to complete it, so withholding would truncate the output permanently — the
    /// same silent loss, moved to the end of the stream. Flush lossily instead: U+FFFD is
    /// visible, a missing tail is not.
    ///
    /// RED: drop the `moreBytesExpected` guard (always hold the tail) → the straddle branch
    /// runs, returns `("ok", 2)`, and the 😀's two present bytes are withheld from the last
    /// read there will ever be.
    func testDecodeIncremental_partialTailOnAFinishedCommand_isFlushedNotWithheld() {
        let bytes = Array("ok😀".utf8)
        let (text, consumed) = BackgroundBashRegistry.decodeIncremental(
            Data(bytes.prefix(4)), moreBytesExpected: false)

        XCTAssertEqual(consumed, 4, "a finished command's last bytes must not be held forever")
        XCTAssertTrue(text.hasPrefix("ok"), "the decodable prefix survives: \(text)")
    }

    /// Binary on stdout is not a straddle and will never become valid. Holding it would wedge
    /// every subsequent read of that command on the same byte, so it is consumed lossily even
    /// while the process runs.
    ///
    /// RED: hold back on any decode failure → consumed is 0 and the command's output stalls.
    func testDecodeIncremental_genuinelyInvalidBytes_areConsumedNotStalled() {
        let data = Data([0x41, 0xFF, 0xFE, 0x42])   // 0xFF/0xFE are never legal UTF-8

        let (text, consumed) = BackgroundBashRegistry.decodeIncremental(
            data, moreBytesExpected: true)

        XCTAssertEqual(consumed, 4, "invalid bytes must not stall the stream")
        XCTAssertTrue(text.contains("A") && text.contains("B"),
                      "the readable bytes around it survive: \(text)")
    }

    // MARK: - The classifier's arms, one fixture each
    //
    // The six tests above exercise 2-byte and 4-byte leads only, and every one of them
    // survives a mutation to the 3-byte arm, to the `>` boundary, and to the illegal-lead
    // arm — measured. Line coverage cannot see it either: line 207 carries both the
    // condition and the assignment, and the 😀 fixture evaluates the condition on its way
    // to the 4-byte arm, so the line reads as covered while the region is dead.

    /// Two bytes of a three-byte character — the arm that protects every CJK glyph,
    /// box-drawing rule, arrow, em-dash and curly quote. Two of three present is the only
    /// arithmetic that distinguishes `declared = 3` from `declared = 2`: with one byte
    /// present both are `> present`, and the straddle is held either way.
    ///
    /// RED: `declared = 3` → `declared = 2` at the 3-byte arm → `2 > 2` is false, control
    /// breaks to the whole-chunk consume, and this returns `("A\u{FFFD}", 3)` — the split
    /// character destroyed, which is the bug the function exists to prevent.
    func testDecodeIncremental_twoBytesOfAThreeByteCharacter_areHeld() {
        let data = Data([0x41] + Array("日".utf8).prefix(2))

        let (text, consumed) = BackgroundBashRegistry.decodeIncremental(
            data, moreBytesExpected: true)

        XCTAssertEqual(consumed, 1, "only the ASCII byte may be consumed")
        XCTAssertEqual(text, "A")
    }

    /// A sequence whose bytes are all PRESENT but which UTF-8 rejects anyway (`ED A0 80`
    /// is a CESU-8 surrogate). `declared > present` is false, so it is corruption, not a
    /// straddle, and must be consumed.
    ///
    /// RED: `declared > present` → `declared >= present` → this returns `("A", 1)`, and
    /// since the same three bytes lead every subsequent read the offset never advances
    /// again: `bash_output` reports `{newOutput: "", running: true}` for the life of the
    /// process. That is the original defect, restored by one character.
    func testDecodeIncremental_completeButInvalidSequence_isConsumedNotHeldForever() {
        let data = Data([0x41, 0xED, 0xA0, 0x80])

        let (_, consumed) = BackgroundBashRegistry.decodeIncremental(
            data, moreBytesExpected: true)

        XCTAssertEqual(
            consumed, data.count,
            "a sequence that can never become valid must not stall the stream")
    }

    /// `0xF8`–`0xFF` are not lead bytes of anything. The `else { declared = 0 }` arm turns
    /// them into "nothing is outstanding", so they are consumed.
    ///
    /// RED: `declared = 0` → `declared = 2` at the illegal-lead arm → `2 > 1` holds the
    /// byte back, and the next read sees the same byte first: the same permanent stall.
    func testDecodeIncremental_illegalLeadByte_isConsumedNotHeldForever() {
        let data = Data([0x41, 0xF8])

        let (_, consumed) = BackgroundBashRegistry.decodeIncremental(
            data, moreBytesExpected: true)

        XCTAssertEqual(consumed, 2, "0xF8 declares no sequence, so nothing is outstanding")
    }

    /// A read window that contains BOTH genuinely invalid bytes and a legitimately split
    /// character at its end. The invalid byte is doomed to render as U+FFFD; the split
    /// character is not, and must still be completed by the next read.
    ///
    /// RED: restore the strict head decode
    /// (`declared > present, let head = String(data: data.prefix(i), encoding: .utf8)`)
    /// → the `0xFF` makes the head undecodable, control breaks to the whole-chunk consume,
    /// `consumed` is 12, and `т` is destroyed even though its second byte was already written.
    func testDecodeIncremental_invalidByteEarlierInTheWindow_doesNotDestroyTheSplitTail() {
        let full = Array("Привет".utf8)          // 12 bytes; the last is т's second
        let data = Data([0xFF] + full.prefix(11))

        let (text, consumed) = BackgroundBashRegistry.decodeIncremental(
            data, moreBytesExpected: true)

        XCTAssertEqual(consumed, 11, "т's first byte must be held for the next read")
        XCTAssertTrue(
            text.hasSuffix("Приве"),
            "the split character is held whole, not half-rendered as U+FFFD: \(text)")

        // And the next read completes it — the property the byte accounting exists for.
        let rest = Data(full.dropFirst(10))
        let (tail, tailConsumed) = BackgroundBashRegistry.decodeIncremental(
            rest, moreBytesExpected: false)
        XCTAssertEqual(tail, "т")
        XCTAssertEqual(tailConsumed, rest.count)
    }

    /// Anti-vacuity: the common case must not have acquired a cost. Plain ASCII, and complete
    /// multi-byte text, decode whole and consume everything.
    ///
    /// RED: return `(text, 0)` unconditionally → both assertions fail.
    func testDecodeIncremental_completeInput_consumesAllOfIt() {
        for sample in ["plain ascii", "Привет, мир", "日本語", "e\u{0301}"] {
            let data = Data(sample.utf8)
            let (text, consumed) = BackgroundBashRegistry.decodeIncremental(
                data, moreBytesExpected: true)
            XCTAssertEqual(text, sample)
            XCTAssertEqual(consumed, data.count, "sample: \(sample)")
        }
        let (emptyText, emptyConsumed) = BackgroundBashRegistry.decodeIncremental(
            Data(), moreBytesExpected: true)
        XCTAssertEqual(emptyText, "")
        XCTAssertEqual(emptyConsumed, 0)
    }

    /// End to end through `read(commandID:)`, where the offset arithmetic actually lives —
    /// the unit cases above prove the decision, this proves it is wired to the offset.
    ///
    /// Determinism comes from the command, not from sleeps: the process emits exactly 11
    /// bytes (one short of the final `т`) and then BLOCKS on a gate file, so the first read
    /// is guaranteed to land mid-character rather than racing a flush. Without the block a
    /// slow machine would hand the first read the whole string and the test would pass
    /// vacuously, which is worse than flaking.
    ///
    /// RED: restore `newOutput = String(data:encoding:.utf8) ?? ""` with
    /// `readOffset += data.count` → the first read reports "" and skips the bytes, so the
    /// concatenation is missing `Приве`.
    func testRead_splitMidCharacterAcrossReads_losesNoBytes() throws {
        let gate = tmp.appendingPathComponent("gate")
        // "Привет\n" is 13 bytes, two per Cyrillic character. Stop after 11: the lone 0xD1
        // is the lead byte of `т` with its continuation byte still unwritten.
        let head = #"\xd0\x9f\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1"#
        let tail = #"\x82\n"#
        let id = try reg.start(
            command: "printf '\(head)'; while [ ! -f '\(gate.path)' ]; do sleep 0.02; done; "
                + "printf '\(tail)'",
            directory: tmp, sandboxProfile: nil, taskID: 7)
        let url = logURL(for: id)

        try waitUntil("the blocked process has written its first 11 bytes") {
            (try? Data(contentsOf: url))?.count == 11
        }

        let first = try XCTUnwrap(reg.read(commandID: id))
        XCTAssertEqual(first.newOutput, "Приве",
                       "the complete prefix must be reported, not discarded with it")

        try Data().write(to: gate)

        var tailText = ""
        try waitUntil("the released process has written the rest") {
            tailText += (reg.read(commandID: id)?.newOutput ?? "")
            return tailText == "т\n"
        }

        XCTAssertEqual(first.newOutput + tailText, "Привет\n",
                       "the incremental reads must concatenate to exactly what was written")
    }

    /// Bounded poll for an eventual condition. Fails loudly rather than hanging, so a broken
    /// wiring shows up as a named assertion instead of a timeout.
    private func waitUntil(
        _ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            usleep(20_000)
        }
        XCTFail("timed out waiting until \(what)")
    }
}
