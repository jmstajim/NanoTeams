import XCTest

@testable import NanoTeams

/// Isolation pins for `TaskStreamStore` — diff, replay, compaction and the
/// crash-window resolutions, against synthetic streams on temp files. The
/// repository wiring has its own end-to-end suites; THIS file is where the
/// delta semantics are pinned one mutation shape at a time.
final class TaskStreamStoreTests: XCTestCase {

    var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
        super.tearDown()
    }

    private func freshURL() -> URL {
        dir.appendingPathComponent("step-\(UUID().uuidString).jsonl")
    }

    private func msg(_ text: String) -> LLMMessage {
        LLMMessage(role: .assistant, content: text)
    }

    private func lineCount(_ url: URL) throws -> Int {
        let text = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private func rehydrated(_ url: URL, expected: StepLogCommit?)
        -> (streams: TaskStreamStore.StepStreams, commit: StepLogCommit)? {
        // A fresh process knows nothing — the entry reset is what makes
        // `hydrate` replay the FILE rather than answer from the warm baseline.
        TaskStreamStore._testResetEntry(for: url)
        return TaskStreamStore.hydrate(from: url, expected: expected)
    }

    // MARK: - Append growth

    /// The headline contract: appending one message costs ~one line, not a
    /// rewrite — across N appends the file carries exactly N+K lines, and every
    /// round-trip reproduces the arrays.
    func testAppendOnlyGrowth_writesOneLinePerElement_andRoundTrips() throws {
        let url = freshURL()
        var streams = TaskStreamStore.StepStreams()
        for i in 0..<20 {
            streams.conversation.append(msg("turn \(i)"))
            XCTAssertNotNil(TaskStreamStore.flush(streams, to: url))
        }
        XCTAssertEqual(try lineCount(url), 20, "one record per appended element, no rewrites")

        let back = try XCTUnwrap(rehydrated(url, expected: nil))
        XCTAssertEqual(back.streams.conversation.map(\.content), streams.conversation.map(\.content))
        XCTAssertEqual(back.commit.conversation, 20)
        XCTAssertEqual(back.commit.seq, 20)
    }

    // MARK: - Replace by id

    /// `updateToolCallResult` fills a nil result in place — ONE record, not a
    /// truncate-and-re-append of the tail (tool results are the largest records
    /// in the file).
    func testReplaceByID_emitsOneRecord_andReplayOverwrites() throws {
        let url = freshURL()
        var streams = TaskStreamStore.StepStreams()
        streams.toolCalls = [
            StepToolCall(name: "read_file", argumentsJSON: #"{"path":"a"}"#),
            StepToolCall(name: "write_file", argumentsJSON: #"{"path":"b"}"#),
        ]
        _ = TaskStreamStore.flush(streams, to: url)
        let before = try lineCount(url)

        streams.toolCalls[0].resultJSON = #"{"ok":true}"#
        _ = TaskStreamStore.flush(streams, to: url)

        XCTAssertEqual(try lineCount(url), before + 1, "an in-place edit is one record")
        let back = try XCTUnwrap(rehydrated(url, expected: nil))
        XCTAssertEqual(back.streams.toolCalls.count, 2)
        XCTAssertEqual(back.streams.toolCalls[0].resultJSON, #"{"ok":true}"#)
        XCTAssertEqual(back.streams.toolCalls[0].id, streams.toolCalls[0].id,
                       "replay overwrites by id — position and identity survive")
    }

    // MARK: - Removal / truncate

    func testTailRemoval_emitsTruncate_andReplayDropsIt() throws {
        let url = freshURL()
        var streams = TaskStreamStore.StepStreams()
        streams.conversation = [msg("keep"), msg("drop-1"), msg("drop-2")]
        _ = TaskStreamStore.flush(streams, to: url)

        streams.conversation.removeLast(2)
        streams.conversation.append(msg("replacement"))
        _ = TaskStreamStore.flush(streams, to: url)

        let back = try XCTUnwrap(rehydrated(url, expected: nil))
        XCTAssertEqual(back.streams.conversation.map(\.content), ["keep", "replacement"])
    }

    /// `StepExecution.reset()` clears all four streams — replay must yield
    /// empty arrays, not the pre-reset history.
    func testReset_truncatesToZero() throws {
        let url = freshURL()
        var streams = TaskStreamStore.StepStreams()
        streams.conversation = [msg("a"), msg("b")]
        streams.wire = [ChatMessage(role: .user, content: "u")]
        _ = TaskStreamStore.flush(streams, to: url)

        _ = TaskStreamStore.flush(TaskStreamStore.StepStreams(), to: url)

        let back = try XCTUnwrap(rehydrated(url, expected: nil))
        XCTAssertTrue(back.streams.isEmpty)
    }

    // MARK: - Wire (positional)

    /// `persistWireTranscript` replaces the whole array; prefix-diffing turns
    /// an extension into pure appends and a repair (drop tail, append repaired
    /// turn) into truncate + append.
    func testWireReplace_prefixDiffs() throws {
        let url = freshURL()
        var streams = TaskStreamStore.StepStreams()
        streams.wire = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "u1"),
        ]
        _ = TaskStreamStore.flush(streams, to: url)
        let before = try lineCount(url)

        streams.wire.append(ChatMessage(role: .assistant, content: "a1"))
        _ = TaskStreamStore.flush(streams, to: url)
        XCTAssertEqual(try lineCount(url), before + 1, "whole-array extension = one append")

        streams.wire.removeLast()
        streams.wire.append(ChatMessage(role: .assistant, content: "a1-repaired"))
        _ = TaskStreamStore.flush(streams, to: url)

        let back = try XCTUnwrap(rehydrated(url, expected: nil))
        XCTAssertEqual(back.streams.wire.map(\.content), ["sys", "u1", "a1-repaired"])
    }

    // MARK: - Hydrate seeds the baseline

    /// After a hydrate, the next flush is a DELTA — not a cold whole-file
    /// rewrite that would re-pay the task's whole history.
    ///
    /// The mutation is an in-place EDIT, deliberately: an append-only fixture
    /// cannot tell the two paths apart (a rewrite of N+1 live elements emits
    /// exactly as many lines as N lines plus one append). An edit leaves a
    /// dead line behind on the delta path (before + 1 lines) while a cold
    /// rewrite collapses to exactly `before` lines.
    func testFlushAfterHydrate_isADelta() throws {
        let url = freshURL()
        var streams = TaskStreamStore.StepStreams()
        streams.conversation = (0..<10).map { msg("t\($0)") }
        _ = TaskStreamStore.flush(streams, to: url)

        var back = try XCTUnwrap(rehydrated(url, expected: nil))
        let before = try lineCount(url)
        back.streams.conversation[0].content = "edited"
        _ = TaskStreamStore.flush(back.streams, to: url)

        XCTAssertEqual(try lineCount(url), before + 1,
                       "hydrate must seed the diff baseline — one edit, one replace record")
        let final = try XCTUnwrap(rehydrated(url, expected: nil))
        XCTAssertEqual(final.streams.conversation[0].content, "edited")
    }

    // MARK: - Compaction

    /// Dead records (replaces) pile up; past `max(64, live)` the file is
    /// rewritten from the current arrays and the dead lines vanish.
    func testCompaction_shrinksTheFile_andKeepsParity() throws {
        let url = freshURL()
        var streams = TaskStreamStore.StepStreams()
        streams.conversation = [msg("only")]
        _ = TaskStreamStore.flush(streams, to: url)

        for i in 0..<100 {
            streams.conversation[0].content = "edit \(i)"
            _ = TaskStreamStore.flush(streams, to: url)
        }

        XCTAssertLessThan(try lineCount(url), 70,
                          "a hundred in-place edits must have compacted, not accreted")
        let back = try XCTUnwrap(rehydrated(url, expected: nil))
        XCTAssertEqual(back.streams.conversation.map(\.content), ["edit 99"])
    }

    /// The two id-bearing streams the conversation tests don't reach: truncate
    /// records for `toolCalls` and `messages` must replay (prefix + index
    /// rebuild), or a tail-removal in either stream resurrects on hydrate.
    func testTruncateReplay_toolCallsAndMessages() throws {
        let url = freshURL()
        var streams = TaskStreamStore.StepStreams()
        streams.toolCalls = [
            StepToolCall(name: "read_file", argumentsJSON: #"{"path":"a"}"#),
            StepToolCall(name: "read_file", argumentsJSON: #"{"path":"b"}"#),
            StepToolCall(name: "read_file", argumentsJSON: #"{"path":"c"}"#),
        ]
        streams.messages = [
            StepMessage(role: .supervisor, content: "m1"),
            StepMessage(role: .supervisor, content: "m2"),
            StepMessage(role: .supervisor, content: "m3"),
        ]
        _ = TaskStreamStore.flush(streams, to: url)

        streams.toolCalls.removeLast(2)
        streams.toolCalls.append(StepToolCall(name: "write_file", argumentsJSON: #"{"path":"d"}"#))
        streams.messages.removeLast(2)
        streams.messages.append(StepMessage(role: .supervisor, content: "m-replacement"))
        _ = TaskStreamStore.flush(streams, to: url)

        let back = try XCTUnwrap(rehydrated(url, expected: nil))
        XCTAssertEqual(back.streams.toolCalls.map(\.name), ["read_file", "write_file"])
        XCTAssertEqual(back.streams.messages.map(\.content), ["m1", "m-replacement"])
    }

    // MARK: - Write-failure recovery (go cold, rewrite from memory)

    /// A failed APPEND poisons the seq counter for records that may not have
    /// landed — the entry must go cold (`flush` → nil) and the NEXT flush must
    /// recover by rewriting the whole file from memory.
    func testAppendFailure_goesCold_andNextFlushRewrites() throws {
        let url = freshURL()
        var streams = TaskStreamStore.StepStreams()
        streams.conversation = [msg("a")]
        XCTAssertNotNil(TaskStreamStore.flush(streams, to: url), "precondition: warm entry")

        // Make the append physically impossible: the log path becomes a
        // directory, so `FileHandle(forWritingTo:)` throws.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        streams.conversation.append(msg("b"))
        XCTAssertNil(TaskStreamStore.flush(streams, to: url),
                     "a failed append must be reported, never absorbed")

        try FileManager.default.removeItem(at: url)
        XCTAssertNotNil(TaskStreamStore.flush(streams, to: url),
                        "the cold entry recovers by whole-file rewrite")
        let back = try XCTUnwrap(rehydrated(url, expected: nil))
        XCTAssertEqual(back.streams.conversation.map(\.content), ["a", "b"],
                       "nothing was lost across the failure")
    }

    /// The cold path's failure arm: an unwritable destination makes the
    /// whole-file rewrite report nil instead of pretending the flush landed.
    func testColdFlush_unwritableParent_isNil() throws {
        let sub = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let url = sub.appendingPathComponent("step.jsonl")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: sub.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sub.path)
        }

        var streams = TaskStreamStore.StepStreams()
        streams.conversation = [msg("a")]
        XCTAssertNil(TaskStreamStore.flush(streams, to: url))
    }

    // MARK: - Crash-window resolution

    /// Log AHEAD of the metadata stamp: the extra records are real work — the
    /// log wins, and the repaired commit reflects it.
    func testHydrate_logAheadOfMetadata_trustsTheLog() throws {
        let url = freshURL()
        var streams = TaskStreamStore.StepStreams()
        streams.conversation = [msg("a"), msg("b"), msg("c")]
        _ = TaskStreamStore.flush(streams, to: url)

        let stale = StepLogCommit(seq: 1, conversation: 1, wire: 0, toolCalls: 0, messages: 0)
        let back = try XCTUnwrap(rehydrated(url, expected: stale))
        XCTAssertEqual(back.streams.conversation.count, 3)
        XCTAssertEqual(back.commit.seq, 3, "the repaired stamp reflects the log")
    }

    /// Log BEHIND the stamp (torn tail already truncated by `JSONLFileLog`):
    /// accept the log's content; loss is bounded at one flush.
    func testHydrate_logBehindMetadata_acceptsTheLog() throws {
        let url = freshURL()
        var streams = TaskStreamStore.StepStreams()
        streams.conversation = [msg("a")]
        _ = TaskStreamStore.flush(streams, to: url)

        let ahead = StepLogCommit(seq: 5, conversation: 3, wire: 0, toolCalls: 0, messages: 0)
        let back = try XCTUnwrap(rehydrated(url, expected: ahead))
        XCTAssertEqual(back.streams.conversation.map(\.content), ["a"])
        XCTAssertEqual(back.commit.seq, 1)
    }

    func testHydrate_missingFile_isNil() {
        XCTAssertNil(TaskStreamStore.hydrate(from: freshURL(), expected: nil))
    }

    /// A torn line in the middle of the crash window: the intact records
    /// replay, and the NEXT flush's append does not fuse with the torn bytes
    /// (JSONLFileLog's first-append repair owns that).
    func testHydrate_afterTornTail_replaysIntactRecords() throws {
        let url = freshURL()
        var streams = TaskStreamStore.StepStreams()
        streams.conversation = [msg("a"), msg("b")]
        _ = TaskStreamStore.flush(streams, to: url)

        var bytes = try Data(contentsOf: url)
        bytes.append(Data(#"{"seq":3,"record":{"kind":"conversation","payl"#.utf8))
        try bytes.write(to: url)

        let back = try XCTUnwrap(rehydrated(url, expected: nil))
        XCTAssertEqual(back.streams.conversation.map(\.content), ["a", "b"])
        XCTAssertEqual(back.commit.seq, 2, "the torn line is not a record")
    }
}
