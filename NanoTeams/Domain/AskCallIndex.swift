import Foundation
#if DEBUG
import Synchronization
#endif

/// The positions of a step's calls NAMED a parking tool — `ToolNames.supervisorAskTools`,
/// i.e. `ask_supervisor` and its structured sibling `ask_supervisor_form` — computed
/// once and EXTENDED suffix-only as the step appends more calls. Which of them actually
/// PARKED the step is read off the live array by `parkedPositions(in:)` /
/// `lastParkedPosition(in:)`: a refused ask (`StepToolCall.isRefusedAsk`) is named like
/// one and asked nobody anything.
///
/// One index answers every question the activity feed used to put to
/// `step.toolCalls` with a fresh pass each: `filter { parked }`
/// (`parkedPositions(in:)` — ascending by construction, so element-for-element the
/// same array) and `lastIndex(where: parked)` (`lastParkedPosition(in:)`). The last
/// one is the load-bearing equivalence: a step that asked, did tool work and was then
/// parked by a cap must still resolve to that EARLIER ask — a "trailing call
/// only" reading was proposed and refuted, so it is exactly
/// `toolCalls.lastIndex(where:)` and `ActivityFeedBuilderTests` pin the shape.
///
/// ## Validation is boundary-only, and that is sound under a CLOSED writer set
///
/// `isPrefix(of:)` checks `(describedCount, describedLastID)`: the described
/// prefix is trusted when the array is at least as long and the element at the
/// prefix's last position still carries the id it had. That is O(1), which is
/// the point — `TeamActivityFeedViewModel` validates this per PARKED step on
/// every `recomputeSteps` tick, before the fingerprint short-circuit, and a
/// parked step's `toolCalls` do not grow, so "same count" is the steady state
/// of every tick rather than a rare case (CLAUDE.md #106: the gate must not cost
/// the work it gates). Verifying the whole prefix positionally would reinstate
/// the O(toolCalls)-per-tick absence proof this type retires.
///
/// The check rests on the writers of `StepExecution.toolCalls`, enumerated at
/// its declaration and pinned tree-wide by
/// `AskCallIndexTests.testToolCallsWriterSet_isClosed`: the only appender is
/// `TaskMutationService.appendToolCall`; `StepExecution.reset()` and
/// `TaskStreamStore`'s log-desync truncation change the count; the hydrate
/// replay (`TaskStreamStore.replayByID`, reached through an `inout` pass the
/// pin matches by its `&`) appends unseen ids and overwrites a seen id in
/// place with the later record for the same id; four sites write `resultJSON`
/// / `isError` / `argumentsJSON` of an existing element (`updateToolCallResult`,
/// the delegation and team-generation envelope reflectors,
/// `StatusRecoveryService`), and the pin asserts that written-field set is
/// exactly those three — never `name` or `id`. No writer rewrites a prefix
/// element's `name` or reorders, so a prefix that still ends in the same id is
/// the same prefix. Consumers additionally `assert` the name at each position
/// in DEBUG, so a writer that slipped past the pin would trip in a test run
/// rather than mis-place a chip.
///
/// Purely in-memory: never persisted, never sent anywhere. Foundation-only so
/// the Domain layer stays free of SwiftUI (CLAUDE.md "Domain layer purity").
nonisolated struct AskCallIndex: Equatable, Sendable {
    /// Ascending positions in `toolCalls` whose name is in `ToolNames.supervisorAskTools` —
    /// the closed set of tools whose call parks the step. Membership, not equality: a second
    /// parking tool that this index did not recognise would be invisible to every consumer,
    /// and the failure is silent (the step still parks on the flag, but the question loses
    /// the persisted call identity its Watchtower dismissal is keyed on). A pure function of
    /// `name` — the cacheable half; whether a call PARKED is not (`parkedPositions(in:)`).
    let positions: [Int]
    /// How many leading elements of `toolCalls` this index describes.
    let describedCount: Int
    /// `toolCalls[describedCount - 1].id` at the time of the scan; nil when
    /// `describedCount == 0`.
    let describedLastID: UUID?

    /// A fresh full scan.
    init(toolCalls: [StepToolCall]) {
        self.init(toolCalls: toolCalls, extending: nil)
    }

    /// Extends `previous` over the appended suffix when it still describes a
    /// prefix of `toolCalls`; otherwise scans from the start. Every examined
    /// element is counted by `AskCallIndexProbe` in DEBUG, which is how
    /// `AskCallIndexTests` pins "suffix only".
    init(toolCalls: [StepToolCall], extending previous: AskCallIndex?) {
        var positions: [Int] = []
        var start = 0
        if let previous, previous.isPrefix(of: toolCalls) {
            positions = previous.positions
            start = previous.describedCount
        }
        for i in start..<toolCalls.count {
            #if DEBUG
            AskCallIndexProbe.noteExamined()
            #endif
            if toolCalls[i].isSupervisorAsk {
                positions.append(i)
            }
        }
        self.positions = positions
        self.describedCount = toolCalls.count
        self.describedLastID = toolCalls.last?.id
    }

    /// Whether this index still describes a leading run of `toolCalls`: at
    /// least `describedCount` elements, and the element at the prefix boundary
    /// carries the id it carried when scanned. See the type doc for why the
    /// boundary suffices.
    func isPrefix(of toolCalls: [StepToolCall]) -> Bool {
        guard describedCount <= toolCalls.count else { return false }
        guard describedCount > 0 else { return true }
        return toolCalls[describedCount - 1].id == describedLastID
    }

    // MARK: - Which of them parked

    /// The indexed calls that PARKED the step — `positions` minus every refused ask
    /// (`StepToolCall.isRefusedAsk`), read against the CURRENT array.
    ///
    /// Deliberately not folded into `positions`. A call is appended before it runs and its
    /// `isError` lands with the result (`appendToolCalls` → `updateToolCallResult`), so it is
    /// the one field of an indexed element that changes AFTER a scan — and `isPrefix` cannot
    /// see a field change: it validates by `(count, last id)`, which is the whole point of the
    /// cache. A refusal folded into the cached positions would therefore stay a park until
    /// the next full rescan. Read here, it is O(asks) on the described array and always
    /// current, while `positions` stays a pure function of `name`, which no writer rewrites.
    func parkedPositions(in toolCalls: [StepToolCall]) -> [Int] {
        positions.filter { !toolCalls[$0].isRefusedAsk }
    }

    /// `parkedPositions(in:).last`, paid for as a walk back over the TRAILING refused asks
    /// only — the per-tick reader (`SupervisorQuestionInbox`) pays nothing on a step that has
    /// none, which is every step but the one mid-repair.
    func lastParkedPosition(in toolCalls: [StepToolCall]) -> Int? {
        positions.last { !toolCalls[$0].isRefusedAsk }
    }
}

#if DEBUG
/// Work-bound seam for `AskCallIndex`'s scan: how many tool calls the
/// `init(toolCalls:extending:)` loop EXAMINED since the last reset.
///
/// Inside the loop, not beside the call (CLAUDE.md #62): the defect being pinned
/// is a wrong CADENCE — a full rescan of `toolCalls` on every recompute tick
/// returns the same positions, just O(toolCalls) per tick on an array with no
/// ceiling (`LLMConstants.maxToolIterations == 0`) — and a counter at the call
/// site would report the caller's intent, not what the scan walked.
nonisolated enum AskCallIndexProbe {
    private static let _examined = Atomic<Int>(0)
    static func noteExamined() { _examined.wrappingAdd(1, ordering: .relaxed) }
    static func examined() -> Int { _examined.load(ordering: .relaxed) }
    static func reset() { _examined.store(0, ordering: .relaxed) }
}
#endif
