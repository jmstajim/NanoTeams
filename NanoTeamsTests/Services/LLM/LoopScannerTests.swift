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

    /// The bounded suffix must still see a loop at the live TAIL of a buffer far
    /// larger than the detector window — an active loop always reaches the tail,
    /// and the bound exists to cap cost, never to move the window.
    func testScanStreaming_loopAtTailOfHugeBuffer_stillFires() {
        let hugeCleanPrefix = String(
            repeating: "Long unique reasoning sentence number one, then another different thought. ",
            count: 2_000) // ~150k chars, far past the window
        XCTAssertNotNil(LoopScanner.scanStreaming(
            thinking: hugeCleanPrefix + loop(), content: "", scope: .thinkingOnly))
        // And the verdict equals the tail scanned alone — the prefix buys nothing.
        XCTAssertNil(LoopScanner.scanStreaming(
            thinking: hugeCleanPrefix + clean(), content: "", scope: .thinkingOnly))
    }

    // MARK: - scanCommitted priority + recency

    private func toolCalls(_ n: Int, at: Date) -> [(name: String, argsJSON: String, createdAt: Date)] {
        (0..<n).map { (name: "read_file", argsJSON: #"{"path":"a"}"#, createdAt: at.addingTimeInterval(Double($0))) }
    }

    func testScanCommitted_toolCallSequence_firesFirst() {
        let signal = LoopScanner.scanCommitted(
            recentAssistant: [],
            toolCalls: toolCalls(DelegationConstants.repetitionMinIdenticalToolCalls, at: Date()),
            informationBoundary: nil, scope: .thinkingAndContent)
        guard case .identicalToolCallSequence = signal else {
            return XCTFail("Expected tool-call sequence signal, got \(String(describing: signal))")
        }
    }

    func testScanCommitted_withinMessage_onRecentTurn() {
        let msgs: [(thinking: String?, content: String, createdAt: Date)] =
            [(thinking: nil, content: loop(), createdAt: Date())]
        guard case .withinMessage = LoopScanner.scanCommitted(
            recentAssistant: msgs, toolCalls: [], informationBoundary: nil, scope: .thinkingAndContent) else {
            return XCTFail("Expected within-message signal")
        }
    }

    func testScanCommitted_acrossMessages() {
        let line = "Reading the configuration file, but it is too large to load, let me try again."
        let msgs: [(thinking: String?, content: String, createdAt: Date)] =
            (0..<3).map { _ in (thinking: nil, content: line, createdAt: Date()) }
        guard case .acrossMessages = LoopScanner.scanCommitted(
            recentAssistant: msgs, toolCalls: [], informationBoundary: nil, scope: .thinkingAndContent) else {
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
            informationBoundary: nil, scope: .thinkingAndContent)
        XCTAssertNil(signal, "Tool calls older than cutoffDate must be filtered out")
    }

    func testScanCommitted_cutoffDate_keepsFreshToolCalls() {
        let fresh = Date(timeIntervalSinceNow: -5)
        let signal = LoopScanner.scanCommitted(
            recentAssistant: [],
            toolCalls: toolCalls(DelegationConstants.repetitionMinIdenticalToolCalls, at: fresh),
            cutoffDate: Date(timeIntervalSinceNow: -120),
            informationBoundary: nil, scope: .thinkingAndContent)
        XCTAssertNotNil(signal, "Fresh tool calls (after cutoffDate) must still fire")
    }

    func testScanCommitted_thinkingOnlyScope_ignoresContentLoop() {
        // Loop lives only in content; thinkingOnly scope must not see it.
        let msgs: [(thinking: String?, content: String, createdAt: Date)] =
            [(thinking: clean(), content: loop(), createdAt: Date())]
        XCTAssertNil(LoopScanner.scanCommitted(
            recentAssistant: msgs, toolCalls: [], informationBoundary: nil, scope: .thinkingOnly))
    }

    // MARK: - Corner cases

    func testScanStreaming_empty_returnsNil() {
        XCTAssertNil(LoopScanner.scanStreaming(thinking: "", content: "", scope: .thinkingOnly))
        XCTAssertNil(LoopScanner.scanStreaming(thinking: "   \n  ", content: "", scope: .thinkingOnly))
    }

    func testScanCommitted_empty_returnsNil() {
        XCTAssertNil(LoopScanner.scanCommitted(recentAssistant: [], toolCalls: [], informationBoundary: nil, scope: .thinkingAndContent))
    }

    /// Priority: a tool-call loop AND a within-message loop both present → tool-call
    /// wins (it's the deterministic, strongest signal, checked first).
    func testScanCommitted_priority_toolCallWinsOverWithinMessage() {
        let now = Date()
        let msgs: [(thinking: String?, content: String, createdAt: Date)] =
            [(thinking: nil, content: loop(), createdAt: now)]
        guard case .identicalToolCallSequence = LoopScanner.scanCommitted(
            recentAssistant: msgs, toolCalls: toolCalls(DelegationConstants.repetitionMinIdenticalToolCalls, at: now),
            informationBoundary: nil, scope: .thinkingAndContent) else {
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
            recentAssistant: msgs, toolCalls: [], informationBoundary: nil, scope: .thinkingAndContent) else {
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
            recentAssistant: [], toolCalls: atCutoff, cutoffDate: cutoff, informationBoundary: nil, scope: .thinkingAndContent),
        "createdAt == cutoff must be excluded (strict >)")

        let afterCutoff = (0..<DelegationConstants.repetitionMinIdenticalToolCalls)
            .map { i in (name: "read_file", argsJSON: #"{"path":"a"}"#, createdAt: cutoff.addingTimeInterval(Double(i + 1))) }
        XCTAssertNotNil(LoopScanner.scanCommitted(
            recentAssistant: [], toolCalls: afterCutoff, cutoffDate: cutoff, informationBoundary: nil, scope: .thinkingAndContent),
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
            recentAssistant: [], toolCalls: calls, cutoffDate: cutoff, informationBoundary: nil, scope: .thinkingAndContent),
        "Only 1 fresh call survives the cutoff → below minRepeats → no fire")
    }

    // MARK: - Information boundary

    /// The reported incident, at the committed layer: the manager polls, an event
    /// notice arrives as an injected `.user` turn, and it polls again. Only the calls
    /// after the arrival may be counted, so the run is below threshold.
    ///
    /// RED: drop `informationBoundary` from the tool filter → fires, and the manager is
    /// told "the state isn't changing" one turn after being told the state changed.
    func testScanCommitted_informationBoundary_splitsARunOfIdenticalCalls() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let calls = toolCalls(DelegationConstants.repetitionMinIdenticalToolCalls, at: t0)
        // News lands between the first call and the rest.
        let boundary = t0.addingTimeInterval(0.5)
        XCTAssertNil(
            LoopScanner.scanCommitted(
                recentAssistant: [], toolCalls: calls,
                informationBoundary: boundary, scope: .thinkingAndContent),
            "Calls decided before the model learned something must not be counted with the ones after"
        )
    }

    /// The central property: the boundary RESETS the count, it does not grant immunity.
    /// A model that receives news and then really does spin still fires.
    ///
    /// RED: make the boundary suppress the scan outright (return nil when non-nil) →
    /// this fails, and a genuinely stuck manager becomes undetectable for as long as
    /// events keep arriving.
    func testScanCommitted_informationBoundary_isNotImmunity() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let boundary = t0
        let calls = toolCalls(
            DelegationConstants.repetitionMinIdenticalToolCalls,
            at: t0.addingTimeInterval(1)
        )
        XCTAssertNotNil(
            LoopScanner.scanCommitted(
                recentAssistant: [], toolCalls: calls,
                informationBoundary: boundary, scope: .thinkingAndContent),
            "A full run made entirely AFTER the arrival is a spin and must still fire"
        )
    }

    /// The boundary folds with `cutoffDate` by `max`, so it can only ever move the
    /// tool-call floor FORWARD — the watcher's revision-retained-history guard and the
    /// evaluator's recency gate keep working unchanged.
    func testScanCommitted_boundaryOlderThanCutoff_doesNotWidenTheWindow() {
        let stale = Date(timeIntervalSinceNow: -300)
        let signal = LoopScanner.scanCommitted(
            recentAssistant: [],
            toolCalls: toolCalls(DelegationConstants.repetitionMinIdenticalToolCalls, at: stale),
            cutoffDate: Date(timeIntervalSinceNow: -120),
            informationBoundary: Date(timeIntervalSinceNow: -600),
            scope: .thinkingAndContent)
        XCTAssertNil(signal, "An older boundary must not re-admit calls the cutoff excluded")
    }

    /// Scope pin: the boundary bounds the TOOL-CALL scan only. News arriving is no
    /// excuse for the model emitting the same paragraph again — and bounding the text
    /// detectors would blind the reasoning-model thinking loop they exist for.
    ///
    /// RED: apply `informationBoundary` to `freshMsgs` too → both of these return nil.
    func testScanCommitted_informationBoundary_doesNotSuppressTextDetectors() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let boundary = t0.addingTimeInterval(60)

        let within: [(thinking: String?, content: String, createdAt: Date)] =
            [(thinking: nil, content: loop(), createdAt: t0)]
        guard case .withinMessage = LoopScanner.scanCommitted(
            recentAssistant: within, toolCalls: [],
            informationBoundary: boundary, scope: .thinkingAndContent) else {
            return XCTFail("Within-message repetition must fire regardless of the boundary")
        }

        let line = "Reading the configuration file, but it is too large to load, let me try again."
        let across: [(thinking: String?, content: String, createdAt: Date)] =
            (0..<3).map { _ in (thinking: nil, content: line, createdAt: t0) }
        guard case .acrossMessages = LoopScanner.scanCommitted(
            recentAssistant: across, toolCalls: [],
            informationBoundary: boundary, scope: .thinkingAndContent) else {
            return XCTFail("Across-messages overlap must fire regardless of the boundary")
        }
    }

    /// Absent boundary must be byte-identical to the pre-boundary behaviour — the
    /// parameter defaults to `nil` so every existing caller and test is unaffected.
    func testScanCommitted_nilBoundary_matchesLegacyBehaviour() {
        let calls = toolCalls(DelegationConstants.repetitionMinIdenticalToolCalls, at: Date())
        XCTAssertNotNil(LoopScanner.scanCommitted(
            recentAssistant: [], toolCalls: calls,
            informationBoundary: nil, scope: .thinkingAndContent))
    }

    /// Strictness pin, mirroring `testScanCommitted_cutoffDate_isStrictlyGreater`: a
    /// call made in the SAME instant as the arrival is excluded. `MonotonicClock` is
    /// strictly increasing, so a call that truly followed the message has a strictly
    /// greater stamp; equality can only mean the two were recorded together.
    func testScanCommitted_boundaryIsStrictlyGreater() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let calls = toolCalls(DelegationConstants.repetitionMinIdenticalToolCalls, at: t0)
        XCTAssertNil(
            LoopScanner.scanCommitted(
                recentAssistant: [], toolCalls: calls,
                informationBoundary: t0, scope: .thinkingAndContent),
            "A call stamped AT the boundary is not after it"
        )
    }
}
