import XCTest
@testable import NanoTeams

/// Pins `LoopScanner` — the shared pure orchestration that both
/// `DelegationLoopWatcher` (child interrupts) and `AutovisorStuckEvaluator`
/// (manager monitoring) plus the in-stream top-level scan funnel through.
final class LoopScannerTests: XCTestCase {

    /// "Oh, wait! " is 10 substantive chars; 8 repeats > minRepeats(5).
    private func loop() -> String { String(repeating: "Oh, wait! ", count: 8) }
    private func clean() -> String {
        "The implementation reads the file, validates the schema, and writes the result."
    }

    // MARK: - scanStreaming

    func testScanStreaming_thinkingOnly_firesOnThinkingLoop() {
        XCTAssertNotNil(LoopScanner.scanStreaming(thinking: loop(), content: "", scope: .thinkingOnly))
    }

    func testScanStreaming_thinkingOnly_ignoresContentLoop() {
        // A loop ONLY in content must NOT fire under thinkingOnly (the top-level
        // abort path scans thinking only to avoid false positives on code/tables).
        XCTAssertNil(LoopScanner.scanStreaming(thinking: clean(), content: loop(), scope: .thinkingOnly))
    }

    func testScanStreaming_thinkingAndContent_firesOnContentLoop() {
        XCTAssertNotNil(LoopScanner.scanStreaming(thinking: clean(), content: loop(), scope: .thinkingAndContent))
    }

    func testScanStreaming_clean_returnsNil() {
        XCTAssertNil(LoopScanner.scanStreaming(thinking: clean(), content: "", scope: .thinkingOnly))
    }

    // MARK: - scanCommitted priority + recency

    private func toolCalls(_ n: Int, at: Date) -> [(name: String, argsJSON: String, createdAt: Date)] {
        (0..<n).map { (name: "read_file", argsJSON: #"{"path":"a"}"#, createdAt: at.addingTimeInterval(Double($0))) }
    }

    func testScanCommitted_toolCallSequence_firesFirst() {
        let signal = LoopScanner.scanCommitted(
            recentAssistant: [],
            toolCalls: toolCalls(DelegationConstants.repetitionMinIdenticalToolCalls, at: Date()),
            scope: .thinkingAndContent)
        guard case .identicalToolCallSequence = signal else {
            return XCTFail("Expected tool-call sequence signal, got \(String(describing: signal))")
        }
    }

    func testScanCommitted_withinMessage_onRecentTurn() {
        let msgs: [(thinking: String?, content: String, createdAt: Date)] =
            [(thinking: nil, content: loop(), createdAt: Date())]
        guard case .withinMessage = LoopScanner.scanCommitted(
            recentAssistant: msgs, toolCalls: [], scope: .thinkingAndContent) else {
            return XCTFail("Expected within-message signal")
        }
    }

    func testScanCommitted_acrossMessages() {
        let line = "Reading the configuration file, but it is too large to load, let me try again."
        let msgs: [(thinking: String?, content: String, createdAt: Date)] =
            (0..<3).map { _ in (thinking: nil, content: line, createdAt: Date()) }
        guard case .acrossMessages = LoopScanner.scanCommitted(
            recentAssistant: msgs, toolCalls: [], scope: .thinkingAndContent) else {
            return XCTFail("Expected across-messages signal")
        }
    }

    func testScanCommitted_cutoffDate_filtersStaleToolCalls() {
        // All calls older than the cutoff → filtered out → no signal. This is the
        // watcher's revision-retained-history guard AND the evaluator's recency gate.
        let stale = Date(timeIntervalSinceNow: -300)
        let signal = LoopScanner.scanCommitted(
            recentAssistant: [],
            toolCalls: toolCalls(DelegationConstants.repetitionMinIdenticalToolCalls, at: stale),
            cutoffDate: Date(timeIntervalSinceNow: -120),
            scope: .thinkingAndContent)
        XCTAssertNil(signal, "Tool calls older than cutoffDate must be filtered out")
    }

    func testScanCommitted_cutoffDate_keepsFreshToolCalls() {
        let fresh = Date(timeIntervalSinceNow: -5)
        let signal = LoopScanner.scanCommitted(
            recentAssistant: [],
            toolCalls: toolCalls(DelegationConstants.repetitionMinIdenticalToolCalls, at: fresh),
            cutoffDate: Date(timeIntervalSinceNow: -120),
            scope: .thinkingAndContent)
        XCTAssertNotNil(signal, "Fresh tool calls (after cutoffDate) must still fire")
    }

    func testScanCommitted_thinkingOnlyScope_ignoresContentLoop() {
        // Loop lives only in content; thinkingOnly scope must not see it.
        let msgs: [(thinking: String?, content: String, createdAt: Date)] =
            [(thinking: clean(), content: loop(), createdAt: Date())]
        XCTAssertNil(LoopScanner.scanCommitted(
            recentAssistant: msgs, toolCalls: [], scope: .thinkingOnly))
    }

    // MARK: - Corner cases

    func testScanStreaming_empty_returnsNil() {
        XCTAssertNil(LoopScanner.scanStreaming(thinking: "", content: "", scope: .thinkingOnly))
        XCTAssertNil(LoopScanner.scanStreaming(thinking: "   \n  ", content: "", scope: .thinkingOnly))
    }

    func testScanCommitted_empty_returnsNil() {
        XCTAssertNil(LoopScanner.scanCommitted(recentAssistant: [], toolCalls: [], scope: .thinkingAndContent))
    }

    /// Priority: a tool-call loop AND a within-message loop both present → tool-call
    /// wins (it's the deterministic, strongest signal, checked first).
    func testScanCommitted_priority_toolCallWinsOverWithinMessage() {
        let now = Date()
        let msgs: [(thinking: String?, content: String, createdAt: Date)] =
            [(thinking: nil, content: loop(), createdAt: now)]
        guard case .identicalToolCallSequence = LoopScanner.scanCommitted(
            recentAssistant: msgs, toolCalls: toolCalls(DelegationConstants.repetitionMinIdenticalToolCalls, at: now),
            scope: .thinkingAndContent) else {
            return XCTFail("tool-call sequence must win over a co-occurring within-message loop")
        }
    }

    /// Priority: within-message beats across-messages when no tool-call loop exists.
    /// Three identical messages → the LAST one repeats internally (within fires first).
    func testScanCommitted_priority_withinMessageWinsOverAcross() {
        let now = Date()
        let msgs: [(thinking: String?, content: String, createdAt: Date)] =
            (0..<3).map { _ in (thinking: nil, content: loop(), createdAt: now) }
        guard case .withinMessage = LoopScanner.scanCommitted(
            recentAssistant: msgs, toolCalls: [], scope: .thinkingAndContent) else {
            return XCTFail("within-message must win over across-messages when both could fire")
        }
    }

    /// `cutoffDate` is STRICT `>`: a call created exactly AT the cutoff is excluded;
    /// one a hair after is included. Pins the boundary the watcher's revision guard
    /// and the evaluator's recency gate both depend on.
    func testScanCommitted_cutoffDate_isStrictlyGreater() {
        let cutoff = Date()
        let atCutoff = (0..<DelegationConstants.repetitionMinIdenticalToolCalls)
            .map { _ in (name: "read_file", argsJSON: #"{"path":"a"}"#, createdAt: cutoff) }
        XCTAssertNil(LoopScanner.scanCommitted(
            recentAssistant: [], toolCalls: atCutoff, cutoffDate: cutoff, scope: .thinkingAndContent),
            "createdAt == cutoff must be excluded (strict >)")

        let afterCutoff = (0..<DelegationConstants.repetitionMinIdenticalToolCalls)
            .map { i in (name: "read_file", argsJSON: #"{"path":"a"}"#, createdAt: cutoff.addingTimeInterval(Double(i + 1))) }
        XCTAssertNotNil(LoopScanner.scanCommitted(
            recentAssistant: [], toolCalls: afterCutoff, cutoffDate: cutoff, scope: .thinkingAndContent),
            "createdAt > cutoff must be included")
    }

    /// Mixed history: stale identical calls (pre-cutoff) + too few fresh ones → the
    /// fresh suffix is below minRepeats → no fire. Guards the "don't re-count
    /// pre-fire history" property at the boundary where the loop straddles the cutoff.
    func testScanCommitted_mixedFreshStale_freshSuffixBelowThreshold_noFire() {
        let cutoff = Date()
        var calls: [(name: String, argsJSON: String, createdAt: Date)] = []
        // 4 stale identical (pre-cutoff)
        for i in 0..<4 { calls.append((name: "read_file", argsJSON: #"{"path":"a"}"#, createdAt: cutoff.addingTimeInterval(-Double(10 - i)))) }
        // 1 fresh identical (post-cutoff) — below minRepeats(3) on its own
        calls.append((name: "read_file", argsJSON: #"{"path":"a"}"#, createdAt: cutoff.addingTimeInterval(5)))
        XCTAssertNil(LoopScanner.scanCommitted(
            recentAssistant: [], toolCalls: calls, cutoffDate: cutoff, scope: .thinkingAndContent),
            "Only 1 fresh call survives the cutoff → below minRepeats → no fire")
    }
}
