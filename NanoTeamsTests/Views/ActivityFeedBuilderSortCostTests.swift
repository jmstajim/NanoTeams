import XCTest
@testable import NanoTeams

/// The feed's pin-to-bottom sort must ask `isStreaming` a number of times that
/// grows with the item COUNT, not with the comparison count.
///
/// The closure the feed passes is `{ streamingManager.isStreaming(messageID: $0) }`
/// — an `@Observable` accessor over a Set. Until 2026-08-25 the comparator called
/// it for BOTH sides of every comparison, so a rebuild asked it `2 · N · log₂N`
/// times on top of the one legitimate ask per message in `emitItems`; the feed
/// rebuilds four times per model turn (`TimelineRebuildProbe`, DEBTS D-24 §3).
///
/// Expressed as work done rather than wall-clock, per
/// `Ratchet/WallClockPerformancePinTests`: the counter is
/// `ActivityFeedBuilder.StreamQueryProbe`, a `#if DEBUG` seam.
///
/// RED: restore the two `isStreamingItem(isStreaming:)` calls inside the
/// `items.sorted { }` comparator → the ratio assertion fails, and it fails
/// harder as N grows, which is the property under test.
@MainActor
final class ActivityFeedBuilderSortCostTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        MonotonicClock.shared.reset()
    }

    /// Timestamps are deliberately SCRAMBLED, and that is load-bearing.
    ///
    /// Swift's `sort` is an adaptive merge sort: on an already-sorted input it
    /// performs ~N comparisons, not N·log N. A fixture emitting messages in
    /// increasing `createdAt` order therefore hides the very cost this suite
    /// measures — measured 2026-08-25: with sorted input the per-comparison
    /// comparator scaled at 4.0×, indistinguishable from the linear one, and
    /// `testQueryCountScalesLinearly` passed against the defect. That is
    /// reading #3 of CLAUDE.md #56 — the fixture never selects the branch.
    ///
    /// A fixed odd-stride permutation, not a shuffle: the repo forbids
    /// `Math.random`-style nondeterminism in fixtures, and a stride coprime
    /// with the count visits every index exactly once.
    private func scrambledOffsets(_ n: Int) -> [Int] {
        let stride = 7  // coprime with every power-of-two count used below
        return (0..<n).map { ($0 * stride) % n }
    }

    private func makeStep(messageCount: Int) -> StepExecution {
        let offsets = scrambledOffsets(messageCount)
        let messages = (0..<messageCount).map { i in
            LLMMessage(
                createdAt: Date(timeIntervalSinceReferenceDate: Double(offsets[i])),
                role: .assistant,
                content: "turn \(i)"
            )
        }
        return StepExecution(
            id: Role.softwareEngineer.baseID,
            role: .softwareEngineer,
            title: "SWE Step",
            status: .done,
            llmConversation: messages
        )
    }

    private func buildCountingQueries(messageCount: Int) -> (items: Int, queries: Int) {
        StreamQueryProbe.reset()
        let tagged = ActivityFeedBuilder.buildTimelineItems(
            steps: [makeStep(messageCount: messageCount)],
            run: nil,
            stepArtifactContentCache: [:],
            debugModeEnabled: false,
            isStreaming: { _ in false }
        )
        return (tagged.count, StreamQueryProbe.queries())
    }

    /// Anti-vacuum: the probe must actually be reached, or the bound below is
    /// asserted over a zero that no sort could exceed (CLAUDE.md #57).
    func testTheProbeCountsTheBuildersQueries() {
        let small = buildCountingQueries(messageCount: 8)
        XCTAssertEqual(small.items, 8, "fixture should yield one timeline item per message")
        XCTAssertGreaterThan(
            small.queries, 0,
            "the probe recorded no query at all — the seam is not wired, so every "
                + "bound in this suite would pass vacuously")
    }

    /// The bound itself. `emitItems` legitimately asks once per message; the sort
    /// must add at most one more ask per item, never one per comparison.
    func testStreamQueriesGrowWithItemCountNotComparisonCount() {
        for n in [16, 64, 256] {
            let run = buildCountingQueries(messageCount: n)
            XCTAssertEqual(run.items, n)
            XCTAssertLessThanOrEqual(
                run.queries, 2 * n,
                "building a feed of \(n) items asked isStreaming \(run.queries) times. "
                    + "At most one ask per item in emitItems plus one in the sort decoration "
                    + "is \(2 * n); anything above that means the comparator is asking, which "
                    + "is Θ(N log N) and grows without bound as a conversation lengthens.")
        }
    }

    /// The ratio, which is what distinguishes Θ(N) from Θ(N log N): quadrupling N
    /// must roughly quadruple the asks. It only discriminates over the SCRAMBLED
    /// fixture above — see `scrambledOffsets` for why, and for the measurement
    /// that proved a sorted fixture makes this test vacuous.
    func testQueryCountScalesLinearly() {
        let small = buildCountingQueries(messageCount: 256)
        let large = buildCountingQueries(messageCount: 1024)
        XCTAssertGreaterThan(small.queries, 0)
        let ratio = Double(large.queries) / Double(small.queries)
        XCTAssertLessThanOrEqual(
            ratio, 4.2,
            "4× the items asked \(ratio)× the queries (\(small.queries) -> \(large.queries)). "
                + "A linear ask scales at 4.0; a per-comparison ask scales faster and keeps "
                + "diverging, so the generous 4.2 ceiling separates the two without pinning "
                + "an exact count.")
    }

    // MARK: - Order is unchanged by the decoration

    /// The decoration must not reorder anything: the comparator stays a pure
    /// function of the same two values, so the permutation is identical by
    /// construction. DEBTS D-24 required the equal-key order be pinned before
    /// this sort was touched, because `continuesTurn` derives turn grouping from
    /// adjacency in the sorted array — this is that pin.
    func testEqualTimestampsKeepTheirEmissionOrder() {
        let shared = Date(timeIntervalSinceReferenceDate: 500)
        let messages = (0..<6).map { i in
            LLMMessage(createdAt: shared, role: .assistant, content: "same-instant \(i)")
        }
        let step = StepExecution(
            id: Role.softwareEngineer.baseID, role: .softwareEngineer,
            title: "SWE Step", status: .done, llmConversation: messages
        )
        let tagged = ActivityFeedBuilder.buildTimelineItems(
            steps: [step], run: nil, stepArtifactContentCache: [:],
            debugModeEnabled: false, isStreaming: { _ in false }
        )
        let rendered: [String] = tagged.compactMap {
            if case .llmMessage(let m, _, _, _) = $0.item { return m.content }
            return nil
        }
        XCTAssertEqual(
            rendered, messages.map(\.content),
            "six items share one timestamp, so only the sort's behaviour on equal keys "
                + "decides their order — it must stay emission order, or continuesTurn "
                + "regroups turns that never moved.")
    }

    /// And the pin-to-bottom behaviour the sort exists for still holds.
    func testStreamingItemOfTheActiveTaskStillPinsToTheEnd() {
        let early = LLMMessage(
            createdAt: Date(timeIntervalSinceReferenceDate: 1), role: .assistant, content: "streaming")
        let late = LLMMessage(
            createdAt: Date(timeIntervalSinceReferenceDate: 9), role: .assistant, content: "later")
        let step = StepExecution(
            id: Role.softwareEngineer.baseID, role: .softwareEngineer,
            title: "SWE Step", status: .running, llmConversation: [early, late]
        )
        let tagged = ActivityFeedBuilder.buildTimelineItems(
            steps: [step], run: nil, stepArtifactContentCache: [:],
            debugModeEnabled: false, isStreaming: { $0 == early.id }
        )
        let rendered: [String] = tagged.compactMap {
            if case .llmMessage(let m, _, _, _) = $0.item { return m.content }
            return nil
        }
        XCTAssertEqual(
            rendered, ["later", "streaming"],
            "the streaming bubble pins to the bottom even though its createdAt is earlier")
    }
}
