import Foundation

/// How often an in-stream probe may run — and, in the case names themselves,
/// WHICH probes are allowed to ask for it.
///
/// This is the contract the two gates it replaces carried only in prose, and
/// which nothing stopped a caller from getting wrong: `StreamScanCadenceGate`
/// was used correctly in front of `LoopScanner.scanStreaming` (whose probe
/// truncates to a fixed tail window, so its cost is constant in the accumulated
/// length) and INCORRECTLY in front of the canonical duplicate-tool-call pass
/// (which re-reads the whole accumulated args blob, ~8 times). An arithmetic
/// cadence in front of an O(A) probe sums to Θ(A²/cadence); nothing in the old
/// type's API recorded which situation its caller was in, so the wrong pairing
/// type-checked. Now the case name IS the claim.
nonisolated enum StreamProbeCadence: Equatable {

    /// Probe every `n` characters of growth. **Legal only when the probe's cost
    /// is bounded independently of the accumulated buffer** — a fixed tail
    /// window, a running hash, a per-delta scan. Σ over a stream of A chars is
    /// then O(A/n) probes × O(1) each.
    case everyChars(Int)

    /// Probe when the buffer has grown by the given ratio since the last probe,
    /// or when the unit count has doubled. **Required when the probe re-reads
    /// the accumulator**: geometric spacing bounds Σ parse work at
    /// `growth/(growth-1)` × the final buffer — amortized linear — where an
    /// arithmetic cadence would be quadratic.
    ///
    /// Growth is a RATIO of integers, not a `Double`: the comparison runs per
    /// delta in the stream loop, and `length * denominator >= last * numerator`
    /// keeps it exact and branch-cheap. The unit-doubling clause exists for the
    /// shape geometric-by-bytes misses — many tiny identical envelopes grow
    /// bytes slowly but units fast. A caller with no meaningful unit passes
    /// `firstAtUnits: 0` and never calls `noteUnit()`; byte growth alone then
    /// governs, which is still amortized linear.
    case geometric(growthNumerator: Int, growthDenominator: Int, firstAtUnits: Int)
}

/// Decides *when* an in-stream probe may run, from delta sizes alone — never
/// from re-counting the accumulated buffers.
///
/// The rule every caller obeys (CLAUDE.md #106): the gate's length input is a
/// RUNNING SUM of delta counts. A `.count` of the accumulator here would BE the
/// quadratic term the gate exists to remove, and the throttle could not save it,
/// because the count would be the throttle's own input. The one whole-buffer
/// count allowed is `seed`'s, at marker adoption, which runs at most once per
/// stream.
///
/// Two calling conventions, both load-bearing and both preserved from the types
/// this replaces:
///
///  - `isDue` + `recordProbe()` — the caller may deliberately DECLINE to record,
///    which holds the window open so the signal is re-offered on the next delta.
///    The delegation-interrupt path relies on that hold while it waits for the
///    parent awaiter to register.
///  - `probeIsDue()` — the one-call composition, where answering `true` IS the
///    proof the probe ran.
nonisolated struct StreamProbeGate {

    let cadence: StreamProbeCadence

    /// Mirror of the accumulated length, maintained from deltas.
    private(set) var runningLength = 0
    /// Domain-specific countable events (Harmony close markers today).
    private(set) var unitCount = 0

    private var lengthAtLastProbe: Int?
    private var unitsAtLastProbe = 0
    /// `runningLength` at the last `recordProbe()` — the arithmetic cadence's baseline.
    private var lengthAtLastRecord = 0

    init(cadence: StreamProbeCadence) {
        self.cadence = cadence
    }

    // MARK: - Input (always O(delta))

    /// A buffer grew by `count` characters (`+=` sites).
    mutating func noteDelta(count: Int) {
        runningLength += count
    }

    /// A buffer was REPLACED rather than appended to (marker adoption truncates
    /// the assistant buffer). Keeps the mirror exact through the one non-append
    /// mutation; the two `count` reads at that call site run once per stream.
    mutating func noteReplacement(oldCount: Int, newCount: Int) {
        runningLength += newCount - oldCount
    }

    /// One countable unit observed in the current delta.
    mutating func noteUnit() {
        unitCount += 1
    }

    /// Marker adoption: accumulated prose became the envelope buffer in one
    /// assignment — absorb its length and the units it already carried.
    mutating func seed(adoptedLength: Int, units: Int) {
        runningLength = adoptedLength
        unitCount = units
    }

    // MARK: - Decision

    /// Whether a probe is due. Pure — asking does not consume the window.
    var isDue: Bool {
        switch cadence {
        case .everyChars(let n):
            return runningLength - lengthAtLastRecord >= n
        case .geometric(let numerator, let denominator, let firstAtUnits):
            guard unitCount >= firstAtUnits else { return false }
            guard let last = lengthAtLastProbe else { return true }
            // The unit-doubling clause is OPT-IN: a caller that never reports
            // units leaves `unitsAtLastProbe` at 0, and `0 >= 0` would otherwise
            // make every delta due — turning the geometric gate back into no gate
            // at all. Harmony always has units here (its first probe requires two),
            // so this guard changes nothing for it.
            return runningLength * denominator >= last * numerator
                || (unitsAtLastProbe > 0 && unitCount >= unitsAtLastProbe * 2)
        }
    }

    /// Close the window — the caller ran (or deliberately swallowed) a probe.
    /// NOT recording after a probe is the hold: the gate keeps firing so the
    /// signal is re-offered until the awaiting side registers.
    mutating func recordProbe() {
        lengthAtLastRecord = runningLength
        lengthAtLastProbe = runningLength
        unitsAtLastProbe = unitCount
    }

    /// `isDue` and `recordProbe()` in one call, for callers whose `true` answer
    /// is itself the proof the probe ran.
    mutating func probeIsDue() -> Bool {
        guard isDue else { return false }
        recordProbe()
        return true
    }
}
