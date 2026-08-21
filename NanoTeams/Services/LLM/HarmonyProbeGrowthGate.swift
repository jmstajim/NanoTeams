import Foundation

/// Growth gate in front of the in-stream Harmony duplicate probe — the
/// whole-buffer `extractAllToolCalls` + `containsDuplicateToolCalls` pass that
/// breaks a runaway stream repeating one tool call.
///
/// The probe used to run on EVERY close-marker delta once two closes had been
/// seen. "Closes are small" was never a bound: `<|end|>` terminates every
/// Harmony channel segment (analysis/commentary included), so an
/// analysis-heavy reply re-parsed the whole growing buffer once per segment —
/// O(segments × buffer) across a turn, with a real 56-call reply on record.
///
/// A CURSOR over the buffer is not the fix: channel-form envelopes carry no
/// `<|end|>` at all (the boundary is the next `<|channel|>` or end-of-text), so
/// a marker-anchored cut re-parses the same tail and a persistent signature set
/// would flag a legitimate multi-call turn as a duplicate; and either marker
/// can legally appear INSIDE a JSON string argument, silently blinding a cut
/// probe for the rest of the stream. The gate keeps the probe EXACT — whole
/// buffer, real parser, both dedup tiers — and bounds the total work instead:
///
///  - first probe exactly where today's fired: the second close marker;
///  - a re-probe is due only when the buffer has grown ×1.5 since the last
///    probe (geometric growth ⇒ Σ parse work ≤ 3 × final buffer — amortized
///    linear), or the close count has DOUBLED (many tiny identical envelopes
///    grow bytes slowly but closes fast — the 56-call shape probes at closes
///    2, 4, 8, … and is caught by #4).
///
/// The trade is bounded detection latency, not correctness: a duplicate can
/// stream at most 50% more bytes (or until closes double) before the probe
/// sees it, and dispatch is guarded regardless — the post-stream dedup runs
/// unconditionally on final content.
///
/// Same wiring rule as `StreamScanCadenceGate` (CLAUDE.md #106): the gate's
/// length input is a RUNNING sum of delta counts — never a `.count` of the
/// accumulated buffer, which would be the quadratic term the gate exists to
/// remove. The one whole-buffer count allowed is `seed`'s, at marker adoption,
/// which runs at most once per stream.
nonisolated struct HarmonyProbeGrowthGate {
    private(set) var runningLength = 0
    private(set) var closeCount = 0
    private var lengthAtLastProbe: Int?
    private var closesAtLastProbe = 0

    /// Every content delta routed into the harmony buffer, O(delta).
    mutating func noteDelta(count: Int) {
        runningLength += count
    }

    /// One close marker observed in the current delta.
    mutating func noteClose() {
        closeCount += 1
    }

    /// Marker adoption: the accumulated prose became the envelope buffer in one
    /// assignment — absorb its length and the closes it already carried. At
    /// most once per stream.
    mutating func seed(adoptedLength: Int, closes: Int) {
        runningLength = adoptedLength
        closeCount = closes
    }

    /// True when a whole-buffer probe is due; recording is the caller's
    /// PROOF-OF-PROBE — the gate assumes a `true` answer is acted on.
    mutating func probeIsDue() -> Bool {
        guard closeCount >= 2 else { return false }
        if let last = lengthAtLastProbe {
            guard runningLength * 2 >= last * 3 || closeCount >= closesAtLastProbe * 2 else {
                return false
            }
        }
        lengthAtLastProbe = runningLength
        closesAtLastProbe = closeCount
        return true
    }
}
