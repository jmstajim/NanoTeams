import XCTest

@testable import NanoTeams

/// Pure-function tests for the streaming-time loop detection helpers in
/// `LLMExecutionService+Streaming.swift`. These run the canonical signature /
/// duplicate-set / dedup logic in isolation; the integration with the for-await
/// stream loop is covered indirectly by the existing streaming test surface.
final class StreamingDuplicateToolCallDetectionTests: XCTestCase {

    private typealias TN = ToolNames

    // MARK: - canonicalToolCallSignature

    func testCanonicalSignature_ignoresKeyOrder() {
        let a = StepToolCall(
            name: TN.writeFile,
            argumentsJSON: #"{"path":"script.js","content":"x"}"#
        )
        let b = StepToolCall(
            name: TN.writeFile,
            argumentsJSON: #"{"content":"x","path":"script.js"}"#
        )
        XCTAssertEqual(
            LLMExecutionService.canonicalToolCallSignature(a),
            LLMExecutionService.canonicalToolCallSignature(b),
            "Same fields with different key order must produce identical signatures"
        )
    }

    func testCanonicalSignature_returnsNil_whenJSONIncomplete() {
        // Mid-stream args buffer that hasn't closed yet should not be comparable.
        let partial = StepToolCall(
            name: TN.writeFile,
            argumentsJSON: #"{"path":"scr"#
        )
        XCTAssertNil(LLMExecutionService.canonicalToolCallSignature(partial))
    }

    func testCanonicalSignature_differsByToolName() {
        let write = StepToolCall(name: TN.writeFile, argumentsJSON: #"{"path":"a"}"#)
        let read = StepToolCall(name: TN.readFile, argumentsJSON: #"{"path":"a"}"#)
        XCTAssertNotEqual(
            LLMExecutionService.canonicalToolCallSignature(write),
            LLMExecutionService.canonicalToolCallSignature(read)
        )
    }

    // MARK: - containsDuplicateToolCalls

    func testContainsDuplicates_falseForSingleCall() {
        let call = StepToolCall(name: TN.writeFile, argumentsJSON: #"{"path":"a","content":"x"}"#)
        XCTAssertFalse(LLMExecutionService.containsDuplicateToolCalls([call]))
    }

    func testContainsDuplicates_trueForTwoIdentical() {
        let a = StepToolCall(name: TN.writeFile, argumentsJSON: #"{"path":"a","content":"x"}"#)
        let b = StepToolCall(name: TN.writeFile, argumentsJSON: #"{"path":"a","content":"x"}"#)
        XCTAssertTrue(LLMExecutionService.containsDuplicateToolCalls([a, b]))
    }

    func testContainsDuplicates_falseForSamePathDifferentContent() {
        let a = StepToolCall(name: TN.writeFile, argumentsJSON: #"{"path":"a","content":"v1"}"#)
        let b = StepToolCall(name: TN.writeFile, argumentsJSON: #"{"path":"a","content":"v2"}"#)
        XCTAssertFalse(LLMExecutionService.containsDuplicateToolCalls([a, b]))
    }

    func testContainsDuplicates_ignoresPartialIncompleteCalls() {
        // While the second call's args are still being streamed, it is not yet
        // comparable — detection must NOT fire prematurely.
        let complete = StepToolCall(name: TN.writeFile, argumentsJSON: #"{"path":"a","content":"x"}"#)
        let partial = StepToolCall(name: TN.writeFile, argumentsJSON: #"{"path":"a","content":"x"#)
        XCTAssertFalse(LLMExecutionService.containsDuplicateToolCalls([complete, partial]))
    }

    func testContainsDuplicates_isGenericAcrossTools() {
        // Detection isn't write_file-specific — any repeated (name, args) tool call
        // is treated as a loop signal.
        let r1 = StepToolCall(name: TN.readFile, argumentsJSON: #"{"path":"a"}"#)
        let r2 = StepToolCall(name: TN.readFile, argumentsJSON: #"{"path":"a"}"#)
        XCTAssertTrue(LLMExecutionService.containsDuplicateToolCalls([r1, r2]))
    }

    // MARK: - deduplicateToolCalls

    func testDedup_keepsFirstOccurrence() {
        let a1 = StepToolCall(name: TN.writeFile, argumentsJSON: #"{"path":"a","content":"x"}"#)
        let a2 = StepToolCall(name: TN.writeFile, argumentsJSON: #"{"content":"x","path":"a"}"#)
        let b = StepToolCall(name: TN.writeFile, argumentsJSON: #"{"path":"b","content":"y"}"#)
        let result = LLMExecutionService.deduplicateToolCalls([a1, a2, b])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].argumentsJSON, a1.argumentsJSON)  // first wins
        XCTAssertEqual(result[1].argumentsJSON, b.argumentsJSON)
    }

    func testDedup_passesThroughUnparseableArgs() {
        // Calls with non-parseable args can't be proven duplicate — pass through.
        let partial1 = StepToolCall(name: TN.writeFile, argumentsJSON: #"{"path":"a"#)
        let partial2 = StepToolCall(name: TN.writeFile, argumentsJSON: #"{"path":"a"#)
        let result = LLMExecutionService.deduplicateToolCalls([partial1, partial2])
        XCTAssertEqual(result.count, 2, "Unparseable args should not be dedup'd")
    }

    func testDedup_emptyInputReturnsEmpty() {
        XCTAssertTrue(LLMExecutionService.deduplicateToolCalls([]).isEmpty)
    }

    // MARK: - Hot-path regression tests
    //
    // These guard the Quick Capture freeze incident: an unoptimized
    // `containsDuplicateToolCalls` was re-parsing and re-canonicalizing the
    // entire growing argumentsJSON of every active tool call on every
    // streaming delta, on the main actor. With a 100KB `content` field that
    // becomes hundreds of MB of JSON work per stream, blocking NSPanel.show
    // (Quick Capture) for 12+ seconds. Any change here must keep the cheap
    // path (1 call, or byte-identical args) free of `JSONSerialization` work.

    func testContainsDuplicates_singleCallWithHugePayload_shortCircuits() {
        // count<2 short-circuit MUST fire before any JSON parsing — a single
        // tool call cannot be a duplicate of itself. We pass intentionally
        // garbage JSON (would otherwise parse-fail, but harmlessly) to make
        // the intent explicit: the function should not try to parse at all.
        let bigContent = String(repeating: "a", count: 100_000)
        let call = StepToolCall(
            name: TN.writeFile,
            argumentsJSON: "{\"path\":\"big.txt\",\"content\":\"\(bigContent)\""  // intentionally truncated
        )
        XCTAssertFalse(LLMExecutionService.containsDuplicateToolCalls([call]))
    }

    func testContainsDuplicates_byteIdenticalArgsCaughtByRawFastPath() {
        // Raw-string fast path runs BEFORE canonical (JSON) comparison.
        // Verified by passing args that aren't valid JSON — if we fell through
        // to the canonical path, both signatures would be nil and the dup
        // would NOT be detected. With the raw fast path, byte-identical args
        // are caught without any JSON parsing.
        let invalid = "{ this is intentionally not valid JSON"
        let a = StepToolCall(name: TN.writeFile, argumentsJSON: invalid)
        let b = StepToolCall(name: TN.writeFile, argumentsJSON: invalid)
        XCTAssertTrue(LLMExecutionService.containsDuplicateToolCalls([a, b]))
    }

    func testContainsDuplicates_perfBound_singleCallLargePayload() {
        // The exact regression: Gemma-4 emitting a write_file with a 100KB
        // body. During streaming this check is invoked once per delta —
        // simulate ~1000 deltas. With the count<2 short-circuit this must be
        // near-instant; without it, parseJSON on growing 100KB of content runs
        // on every iteration on the main actor and blocks Quick Capture.
        let bigContent = String(repeating: "x", count: 100_000)
        let call = StepToolCall(
            name: TN.writeFile,
            argumentsJSON: "{\"path\":\"big.txt\",\"content\":\"\(bigContent)\"}"
        )
        let start = Date()
        for _ in 0..<1000 {
            _ = LLMExecutionService.containsDuplicateToolCalls([call])
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, 0.1,
            "1000 single-call dedup checks on a 100KB payload must complete in <100ms (took \(elapsed)s) — count<2 short-circuit regression"
        )
    }

    func testContainsDuplicates_perfBound_byteIdenticalDuplicatesAreCheap() {
        // The actual loop case: two identical 100KB writes. Raw fast path
        // catches them via plain string Set insert — no JSON work needed.
        // 1000 iterations must complete well under 1 second.
        let bigContent = String(repeating: "y", count: 100_000)
        let json = "{\"path\":\"big.txt\",\"content\":\"\(bigContent)\"}"
        let a = StepToolCall(name: TN.writeFile, argumentsJSON: json)
        let b = StepToolCall(name: TN.writeFile, argumentsJSON: json)
        let start = Date()
        for _ in 0..<1000 {
            _ = LLMExecutionService.containsDuplicateToolCalls([a, b])
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, 0.5,
            "1000 byte-identical-duplicate detections on 100KB payloads must complete in <500ms via raw fast path (took \(elapsed)s)"
        )
    }

    func testCanonicalSignature_perfBound_singleInvocationOnLargePayload() {
        // Lower bound: even one canonical encoding of a 100KB JSON object
        // should be sub-50ms. If this drifts above ~100ms the streaming hot
        // path needs additional gating.
        let bigContent = String(repeating: "z", count: 100_000)
        let call = StepToolCall(
            name: TN.writeFile,
            argumentsJSON: "{\"path\":\"big.txt\",\"content\":\"\(bigContent)\"}"
        )
        let start = Date()
        _ = LLMExecutionService.canonicalToolCallSignature(call)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, 0.1,
            "Single canonical signature on 100KB payload took \(elapsed)s — JSON pipeline regression"
        )
    }
}
